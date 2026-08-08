#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_DIR="${DEMO_DIR}/app"
BUNDLE_DIR="${DEMO_DIR}/bundle"

OUT_DIR="${DEMO_DIR}/out"
IMAGE_DIR="${OUT_DIR}/images"
BUNDLES_OUT_DIR="${OUT_DIR}/bundles"
KEY_DIR="${OUT_DIR}/keys"

IMAGE_SIZE_MB=64

mkdir -p \
    "${IMAGE_DIR}" \
    "${BUNDLES_OUT_DIR}" \
    "${KEY_DIR}"

for command in rauc openssl mkfs.ext4; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 1
    fi
done

CERT="${KEY_DIR}/demo.cert.pem"
KEY="${KEY_DIR}/demo.key.pem"

if [[ ! -f "${CERT}" || ! -f "${KEY}" ]]; then
    echo "[rauc-demo] Generating development signing key..."

    openssl req \
        -x509 \
        -newkey rsa:4096 \
        -nodes \
        -keyout "${KEY}" \
        -out "${CERT}" \
        -days 3650 \
        -subj "/O=TEAR Demo/CN=tear-demo-rauc"
fi

build_image()
{
    local version="$1"
    local source_dir="${APP_DIR}/v${version}"
    local image="${IMAGE_DIR}/appfs-v${version}.ext4"

    echo "[rauc-demo] Building appfs v${version}..."

    rm -f "${image}"

    truncate \
        -s "${IMAGE_SIZE_MB}M" \
        "${image}"

    mkfs.ext4 \
        -q \
        -F \
        -L "tear-app-v${version}" \
        -d "${source_dir}" \
        "${image}"
}

build_bundle()
{
    local version="$1"
    local source_bundle_dir="${BUNDLE_DIR}/v${version}"
    local work_dir="${OUT_DIR}/bundle-v${version}"
    local image="${IMAGE_DIR}/appfs-v${version}.ext4"
    local bundle="${BUNDLES_OUT_DIR}/tear-demo-v${version}.raucb"

    echo "[rauc-demo] Building signed RAUC bundle v${version}..."

    rm -rf "${work_dir}"
    mkdir -p "${work_dir}"

    cp \
        "${source_bundle_dir}/manifest.raucm" \
        "${work_dir}/manifest.raucm"

    cp \
        "${image}" \
        "${work_dir}/appfs.ext4"

    rm -f "${bundle}"

    rauc bundle \
        --cert="${CERT}" \
        --key="${KEY}" \
        "${work_dir}" \
        "${bundle}"
}

build_image "1"
build_image "2"

build_bundle "1"
build_bundle "2"

cp \
    "${IMAGE_DIR}/appfs-v1.ext4" \
    "${IMAGE_DIR}/target.ext4"

echo
echo "[rauc-demo] Build complete."
echo
echo "Images:"
ls -lh "${IMAGE_DIR}"

echo
echo "Bundles:"
ls -lh "${BUNDLES_OUT_DIR}"

echo
echo "Certificate:"
echo "  ${CERT}"

echo
echo "Initial target:"
echo "  ${IMAGE_DIR}/target.ext4"
