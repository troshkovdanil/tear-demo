#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${DEMO_DIR}/out"
IMAGE_DIR="${OUT_DIR}/images"
BUNDLE_DIR="${OUT_DIR}/bundles"
KEY_DIR="${OUT_DIR}/keys"
RUNTIME_DIR="${OUT_DIR}/runtime"

CERT="${KEY_DIR}/demo.cert.pem"
V1_IMAGE="${IMAGE_DIR}/appfs-v1.ext4"
V2_BUNDLE="${BUNDLE_DIR}/tear-demo-v2.raucb"

ROOTFS_A_IMAGE="${RUNTIME_DIR}/rootfs-a.img"
ROOTFS_B_IMAGE="${RUNTIME_DIR}/rootfs-b.img"
APPFS_A_IMAGE="${RUNTIME_DIR}/appfs-a.ext4"
APPFS_B_IMAGE="${RUNTIME_DIR}/appfs-b.ext4"

CONFIG="${RUNTIME_DIR}/system.conf"
SERVICE_LOG="${RUNTIME_DIR}/rauc-service.log"

MOUNT_A="${RUNTIME_DIR}/mnt-a"
MOUNT_B="${RUNTIME_DIR}/mnt-b"

ROOTFS_SIZE_MB=8

LOOP_ROOTFS_A=""
LOOP_ROOTFS_B=""
LOOP_APPFS_A=""
LOOP_APPFS_B=""

RAUC_SERVICE_PID=""

SYSTEM_RAUC_WAS_ACTIVE=0

cleanup()
{
    set +e

    echo
    echo "[rauc-demo] Cleaning up..."

    if mountpoint -q "${MOUNT_A}" 2>/dev/null; then
        sudo umount "${MOUNT_A}"
    fi

    if mountpoint -q "${MOUNT_B}" 2>/dev/null; then
        sudo umount "${MOUNT_B}"
    fi

    if [[ -n "${RAUC_SERVICE_PID}" ]]; then
        sudo kill "${RAUC_SERVICE_PID}" >/dev/null 2>&1 || true

        for _ in $(seq 1 20); do
            if ! sudo kill -0 "${RAUC_SERVICE_PID}" >/dev/null 2>&1; then
                break
            fi

            sleep 0.1
        done
    fi

    for dev in \
        "${LOOP_ROOTFS_A}" \
        "${LOOP_ROOTFS_B}" \
        "${LOOP_APPFS_A}" \
        "${LOOP_APPFS_B}"
    do
        if [[ -n "${dev}" ]]; then
            sudo losetup -d "${dev}" >/dev/null 2>&1 || true
        fi
    done

    if [[ "${SYSTEM_RAUC_WAS_ACTIVE}" -eq 1 ]]; then
        echo "[rauc-demo] Restoring system RAUC service..."
        sudo systemctl start rauc.service >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT


require_command()
{
    local command="$1"

    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 1
    fi
}


for command in \
    rauc \
    losetup \
    mount \
    umount \
    mountpoint \
    truncate \
    systemctl
do
    require_command "${command}"
done


if [[ ! -f "${V1_IMAGE}" ]]; then
    echo "error: ${V1_IMAGE} does not exist" >&2
    echo "run first:" >&2
    echo "  ./scripts/build.sh" >&2
    exit 1
fi

if [[ ! -f "${V2_BUNDLE}" ]]; then
    echo "error: ${V2_BUNDLE} does not exist" >&2
    echo "run first:" >&2
    echo "  ./scripts/build.sh" >&2
    exit 1
fi

if [[ ! -f "${CERT}" ]]; then
    echo "error: ${CERT} does not exist" >&2
    exit 1
fi


echo "[rauc-demo] Preparing runtime directory..."

rm -rf "${RUNTIME_DIR}"

mkdir -p \
    "${RUNTIME_DIR}" \
    "${MOUNT_A}" \
    "${MOUNT_B}" \
    "${RUNTIME_DIR}/rauc-data"


#
# Create two dummy bootable parent slots.
#
# RAUC will not install anything into these because our bundle contains
# only an appfs image. They exist to model the normal A/B slot groups.
#

echo "[rauc-demo] Creating dummy rootfs A/B images..."

truncate \
    -s "${ROOTFS_SIZE_MB}M" \
    "${ROOTFS_A_IMAGE}"

truncate \
    -s "${ROOTFS_SIZE_MB}M" \
    "${ROOTFS_B_IMAGE}"


#
# Both application slots initially contain version 1.
#

echo "[rauc-demo] Creating appfs A/B from application v1..."

cp \
    "${V1_IMAGE}" \
    "${APPFS_A_IMAGE}"

cp \
    "${V1_IMAGE}" \
    "${APPFS_B_IMAGE}"


#
# Attach all four images as block devices.
#

echo "[rauc-demo] Attaching loop devices..."

LOOP_ROOTFS_A="$(
    sudo losetup \
        --find \
        --show \
        "${ROOTFS_A_IMAGE}"
)"

LOOP_ROOTFS_B="$(
    sudo losetup \
        --find \
        --show \
        "${ROOTFS_B_IMAGE}"
)"

LOOP_APPFS_A="$(
    sudo losetup \
        --find \
        --show \
        "${APPFS_A_IMAGE}"
)"

LOOP_APPFS_B="$(
    sudo losetup \
        --find \
        --show \
        "${APPFS_B_IMAGE}"
)"

echo
echo "rootfs A: ${LOOP_ROOTFS_A}"
echo "appfs  A: ${LOOP_APPFS_A}"
echo "rootfs B: ${LOOP_ROOTFS_B}"
echo "appfs  B: ${LOOP_APPFS_B}"


#
# RAUC configuration.
#
# A and B are bootable parent slots.
# Each appfs belongs to its corresponding rootfs.
#
# We use bootloader=noop because the host demo has no real bootloader.
# activate-installed=false prevents this mock demo from pretending that
# it actually switched a hardware bootloader after installation.
#

cat > "${CONFIG}" <<EOF
[system]
compatible=tear-demo-rauc
bootloader=noop
activate-installed=false
data-directory=${RUNTIME_DIR}/rauc-data

[keyring]
path=${CERT}

[slot.rootfs.0]
device=${LOOP_ROOTFS_A}
type=raw
bootname=A

[slot.appfs.0]
device=${LOOP_APPFS_A}
type=ext4
parent=rootfs.0

[slot.rootfs.1]
device=${LOOP_ROOTFS_B}
type=raw
bootname=B

[slot.appfs.1]
device=${LOOP_APPFS_B}
type=ext4
parent=rootfs.1
EOF


echo
echo "[rauc-demo] RAUC configuration:"
echo
cat "${CONFIG}"


#
# Verify initial contents.
#

echo
echo "[rauc-demo] Checking application slots before update..."

sudo mount \
    "${LOOP_APPFS_A}" \
    "${MOUNT_A}"

sudo mount \
    "${LOOP_APPFS_B}" \
    "${MOUNT_B}"

VERSION_A_BEFORE="$(
    cat "${MOUNT_A}/www/version"
)"

VERSION_B_BEFORE="$(
    cat "${MOUNT_B}/www/version"
)"

echo
echo "appfs A: ${VERSION_A_BEFORE}"
echo "appfs B: ${VERSION_B_BEFORE}"

sudo umount "${MOUNT_A}"
sudo umount "${MOUNT_B}"


#
# We want our explicitly configured service, not Ubuntu's normally
# D-Bus-activated service using /etc/rauc/system.conf.
#

if systemctl is-active --quiet rauc.service; then
    SYSTEM_RAUC_WAS_ACTIVE=1

    echo
    echo "[rauc-demo] Stopping system RAUC service..."

    sudo systemctl stop rauc.service
fi


#
# Start a real RAUC service and explicitly tell it that slot A is the
# currently booted slot.
#

echo
echo "[rauc-demo] Starting RAUC service with booted slot A..."

sudo rauc \
    --conf="${CONFIG}" \
    service \
    --override-boot-slot=A \
    >"${SERVICE_LOG}" \
    2>&1 &

RAUC_SERVICE_PID=$!


#
# Give the service a moment to acquire its D-Bus name.
#

for _ in $(seq 1 30); do
    if ! sudo kill -0 "${RAUC_SERVICE_PID}" >/dev/null 2>&1; then
        echo
        echo "error: RAUC service terminated unexpectedly" >&2
        echo >&2
        cat "${SERVICE_LOG}" >&2
        exit 1
    fi

    if sudo rauc status >/dev/null 2>&1; then
        break
    fi

    sleep 0.2
done


if ! sudo kill -0 "${RAUC_SERVICE_PID}" >/dev/null 2>&1; then
    echo "error: RAUC service failed to start" >&2
    cat "${SERVICE_LOG}" >&2
    exit 1
fi


echo
echo "[rauc-demo] RAUC status before installation:"
echo

sudo rauc status


#
# Verify the bundle before installation.
#

echo
echo "[rauc-demo] Verifying v2 bundle:"
echo

rauc \
    --keyring="${CERT}" \
    info \
    "${V2_BUNDLE}"


#
# Perform a normal RAUC install through the running service.
#
# Because A is active, RAUC must choose the inactive group B.
# The bundle contains only image.appfs, therefore appfs.1 is updated.
#

echo
echo "[rauc-demo] Installing application v2..."
echo

sudo rauc \
    install \
    "${V2_BUNDLE}"


echo
echo "[rauc-demo] RAUC status after installation:"
echo

sudo rauc status


#
# Stop the RAUC service before mounting and inspecting the devices.
#

echo
echo "[rauc-demo] Stopping RAUC service..."

sudo kill "${RAUC_SERVICE_PID}"

wait "${RAUC_SERVICE_PID}" 2>/dev/null || true

RAUC_SERVICE_PID=""


#
# Inspect both filesystems.
#

echo
echo "[rauc-demo] Checking application slots after update..."

sudo mount \
    "${LOOP_APPFS_A}" \
    "${MOUNT_A}"

sudo mount \
    "${LOOP_APPFS_B}" \
    "${MOUNT_B}"

VERSION_A_AFTER="$(
    cat "${MOUNT_A}/www/version"
)"

VERSION_B_AFTER="$(
    cat "${MOUNT_B}/www/version"
)"

echo
echo "appfs A: ${VERSION_A_AFTER}"
echo "appfs B: ${VERSION_B_AFTER}"


echo
echo "[rauc-demo] HTTP content:"
echo
echo "--- A ---"
cat "${MOUNT_A}/www/index.html"

echo
echo "--- B ---"
cat "${MOUNT_B}/www/index.html"


#
# Verify expected result.
#

if [[ "${VERSION_A_AFTER}" != "1.0" ]]; then
    echo
    echo "error: active appfs A was unexpectedly modified" >&2
    exit 1
fi

if [[ "${VERSION_B_AFTER}" != "2.0" ]]; then
    echo
    echo "error: inactive appfs B was not updated to version 2.0" >&2
    exit 1
fi


echo
echo "============================================================"
echo "RAUC Milestone 1 PASSED"
echo "============================================================"
echo
echo "Booted group: A"
echo
echo "Before:"
echo "  appfs A = ${VERSION_A_BEFORE}"
echo "  appfs B = ${VERSION_B_BEFORE}"
echo
echo "After:"
echo "  appfs A = ${VERSION_A_AFTER}"
echo "  appfs B = ${VERSION_B_AFTER}"
echo
echo "RAUC correctly preserved active slot A and installed"
echo "the signed v2 application image into inactive slot B."
echo
