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

ROOTFS_SIZE_MB=8

LOOP_ROOTFS_A=""
LOOP_ROOTFS_B=""
LOOP_APPFS_A=""
LOOP_APPFS_B=""

RAUC_SERVICE_PID=""
SYSTEM_RAUC_WAS_ACTIVE=0


cleanup()
{
    local exit_code=$?

    set +e

    echo
    echo "[rauc-demo] Cleaning up..."

    if [[ -n "${RAUC_SERVICE_PID}" ]]; then
        sudo kill "${RAUC_SERVICE_PID}" >/dev/null 2>&1 || true
        wait "${RAUC_SERVICE_PID}" >/dev/null 2>&1 || true
        RAUC_SERVICE_PID=""
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

    exit "${exit_code}"
}

trap cleanup EXIT INT TERM


require_command()
{
    local command="$1"

    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 1
    fi
}


read_ext4_file()
{
    local device="$1"
    local path="$2"

    sudo debugfs \
        -R "cat ${path}" \
        "${device}" \
        2>/dev/null
}


for command in \
    rauc \
    losetup \
    truncate \
    debugfs \
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


#
# Previous runs must have detached their loop devices before this point.
# Do not recursively remove a directory containing mounted filesystems.
#

if [[ -d "${RUNTIME_DIR}" ]]; then
    while read -r loop_device backing_file; do
        if [[ "${backing_file}" == "${RUNTIME_DIR}"/* ]]; then
            echo "error: stale loop device detected:" >&2
            echo "  ${loop_device} -> ${backing_file}" >&2
            echo >&2
            echo "run:" >&2
            echo "  ./scripts/clean.sh" >&2
            exit 1
        fi
    done < <(
        losetup \
            --list \
            --noheadings \
            --output NAME,BACK-FILE
    )
fi


echo "[rauc-demo] Preparing runtime directory..."

rm -rf "${RUNTIME_DIR}"

mkdir -p \
    "${RUNTIME_DIR}" \
    "${RUNTIME_DIR}/rauc-data"


#
# Dummy bootable parent slots.
#
# The bundle contains no rootfs image, so RAUC does not write these.
# They exist only to model the normal A/B slot relationship.
#

echo "[rauc-demo] Creating dummy rootfs A/B images..."

truncate \
    -s "${ROOTFS_SIZE_MB}M" \
    "${ROOTFS_A_IMAGE}"

truncate \
    -s "${ROOTFS_SIZE_MB}M" \
    "${ROOTFS_B_IMAGE}"


#
# Both application slots start from application version 1.
#

echo "[rauc-demo] Creating appfs A/B from application v1..."

cp \
    "${V1_IMAGE}" \
    "${APPFS_A_IMAGE}"

cp \
    "${V1_IMAGE}" \
    "${APPFS_B_IMAGE}"


#
# Expose the image files as real Linux block devices.
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
# A/B RAUC configuration.
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
# Read both ext4 filesystems directly.
# No mount is necessary.
#

echo
echo "[rauc-demo] Checking application slots before update..."

VERSION_A_BEFORE="$(
    read_ext4_file \
        "${LOOP_APPFS_A}" \
        "/www/version"
)"

VERSION_B_BEFORE="$(
    read_ext4_file \
        "${LOOP_APPFS_B}" \
        "/www/version"
)"

echo
echo "appfs A: ${VERSION_A_BEFORE}"
echo "appfs B: ${VERSION_B_BEFORE}"


#
# Avoid colliding with Ubuntu's normal D-Bus-activated RAUC service.
#

if systemctl is-active --quiet rauc.service; then
    SYSTEM_RAUC_WAS_ACTIVE=1

    echo
    echo "[rauc-demo] Stopping system RAUC service..."

    sudo systemctl stop rauc.service
fi


#
# Start a real RAUC service and tell it that A is currently booted.
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
# Wait until the service is actually available through D-Bus.
#

SERVICE_READY=0

for _ in $(seq 1 50); do
    if ! sudo kill -0 "${RAUC_SERVICE_PID}" >/dev/null 2>&1; then
        echo
        echo "error: RAUC service terminated unexpectedly" >&2
        echo >&2
        cat "${SERVICE_LOG}" >&2
        exit 1
    fi

    if sudo rauc status >/dev/null 2>&1; then
        SERVICE_READY=1
        break
    fi

    sleep 0.1
done


if [[ "${SERVICE_READY}" -ne 1 ]]; then
    echo
    echo "error: RAUC service did not become ready" >&2
    echo >&2
    cat "${SERVICE_LOG}" >&2
    exit 1
fi


echo
echo "[rauc-demo] RAUC status before installation:"
echo

sudo rauc status


#
# Independent bundle inspection/signature verification.
#

echo
echo "[rauc-demo] Verifying v2 bundle:"
echo

rauc \
    --keyring="${CERT}" \
    info \
    "${V2_BUNDLE}"


#
# Normal RAUC installation through the running service.
#
# A is active.
# Therefore group B is the inactive target.
# The bundle contains image.appfs only, so RAUC writes appfs.1.
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
# Stop RAUC before inspecting the updated filesystem.
#

echo
echo "[rauc-demo] Stopping RAUC service..."

sudo kill "${RAUC_SERVICE_PID}"
wait "${RAUC_SERVICE_PID}" 2>/dev/null || true

RAUC_SERVICE_PID=""


#
# Inspect both ext4 filesystems without mounting them.
#

echo
echo "[rauc-demo] Checking application slots after update..."

VERSION_A_AFTER="$(
    read_ext4_file \
        "${LOOP_APPFS_A}" \
        "/www/version"
)"

VERSION_B_AFTER="$(
    read_ext4_file \
        "${LOOP_APPFS_B}" \
        "/www/version"
)"

echo
echo "appfs A: ${VERSION_A_AFTER}"
echo "appfs B: ${VERSION_B_AFTER}"


echo
echo "[rauc-demo] HTTP content:"
echo
echo "--- A ---"

read_ext4_file \
    "${LOOP_APPFS_A}" \
    "/www/index.html"

echo
echo "--- B ---"

read_ext4_file \
    "${LOOP_APPFS_B}" \
    "/www/index.html"


#
# Validate the actual result.
#

if [[ "${VERSION_A_BEFORE}" != "1.0" ]]; then
    echo
    echo "error: appfs A did not start at version 1.0" >&2
    exit 1
fi

if [[ "${VERSION_B_BEFORE}" != "1.0" ]]; then
    echo
    echo "error: appfs B did not start at version 1.0" >&2
    exit 1
fi

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
