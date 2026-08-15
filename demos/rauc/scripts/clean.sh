#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${DEMO_DIR}/out"


echo "[rauc-demo] Unmounting stale demo mounts..."

while read -r target source; do
    if [[ "${target}" == "${OUT_DIR}"/* ]]; then
        echo "[rauc-demo] Unmounting ${target}"

        sudo umount \
            "${target}" \
            2>/dev/null || \
        sudo umount \
            -l \
            "${target}" \
            2>/dev/null || true
    fi
done < <(
    findmnt \
        --raw \
        --noheadings \
        --output TARGET,SOURCE \
        2>/dev/null || true
)


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
