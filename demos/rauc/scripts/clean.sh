#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${DEMO_DIR}/out"

echo "[rauc-demo] Unmounting demo filesystems..."

if [[ -d "${OUT_DIR}/runtime" ]]; then
    while read -r mountpoint; do
        if [[ -n "${mountpoint}" ]]; then
            echo "[rauc-demo] Unmounting ${mountpoint}"
            sudo umount "${mountpoint}" 2>/dev/null || true
        fi
    done < <(
        findmnt \
            --raw \
            --noheadings \
            --output TARGET \
            | grep "^${OUT_DIR}/runtime/" \
            || true
    )
fi


echo "[rauc-demo] Detaching demo loop devices..."

while read -r loop_device backing_file; do
    if [[ "${backing_file}" == "${OUT_DIR}"/* ]]; then
        echo "[rauc-demo] Detaching ${loop_device}"
        sudo losetup \
            -d \
            "${loop_device}" \
            2>/dev/null || true
    fi
done < <(
    losetup \
        --list \
        --noheadings \
        --output NAME,BACK-FILE
)


echo "[rauc-demo] Removing generated output..."

rm -rf "${OUT_DIR}"

echo "[rauc-demo] Clean."
