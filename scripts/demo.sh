#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)"

REPO_ROOT="$(
    cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1
    pwd
)"

EDGE_AI_COMMIT="${EDGE_AI_COMMIT:-5ce5aa03c2fec59dd2e2bbde2153c30a5925b531}"

MODEL_NAME="pallet_defect_detection"
MODEL_DIR="${MODEL_DIR:-${REPO_ROOT}/out/models/${MODEL_NAME}}"

MODEL_BASE_URL="$(
    printf '%s' \
        "https://raw.githubusercontent.com/open-edge-platform/edge-ai-libraries" \
        "/${EDGE_AI_COMMIT}" \
        "/microservices/dlstreamer-pipeline-server/resources/models/geti" \
        "/pallet_defect_detection/deployment/Detection/model"
)"

info()
{
    printf '[INFO] %s\n' "$*"
}

fatal()
{
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

download_file()
{
    local filename="$1"
    local destination="${MODEL_DIR}/${filename}"
    local temporary="${destination}.tmp"
    local url="${MODEL_BASE_URL}/${filename}"

    if [[ -s "${destination}" ]]; then
        info "Using cached model file: ${destination}"
        return 0
    fi

    info "Downloading ${filename}"

    rm -f "${temporary}"

    if command -v curl >/dev/null 2>&1; then
        curl \
            --fail \
            --location \
            --retry 3 \
            --retry-delay 2 \
            --output "${temporary}" \
            "${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget \
            --tries=3 \
            --output-document="${temporary}" \
            "${url}"
    else
        fatal "Neither curl nor wget is available"
    fi

    [[ -s "${temporary}" ]] ||
        fatal "Downloaded file is empty: ${filename}"

    mv "${temporary}" "${destination}"
}

mkdir -p "${MODEL_DIR}"

download_file config.json
download_file model.xml
download_file model.bin

[[ -f "${MODEL_DIR}/model.xml" ]] ||
    fatal "Missing downloaded model.xml"

[[ -f "${MODEL_DIR}/model.bin" ]] ||
    fatal "Missing downloaded model.bin"

info "Model ready:"
info "  ${MODEL_DIR}"

"${SCRIPT_DIR}/build-x86_64.sh"
"${SCRIPT_DIR}/run-power-save-demo.sh" "${MODEL_DIR}"
