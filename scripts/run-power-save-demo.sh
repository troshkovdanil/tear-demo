#!/usr/bin/env bash
#
# Run the TEAR DL Streamer POWER_SAVE enforcement test.
#
# Usage:
#   ./scripts/run-power-save-demo.sh /path/to/model-directory
#
# Or:
#   MODEL_DIR=/path/to/model-directory ./scripts/run-power-save-demo.sh
#
# Optional:
#   CLEAN=1 ./scripts/run-power-save-demo.sh /path/to/model-directory
#   NUM_BUFFERS=900 ./scripts/run-power-save-demo.sh /path/to/model-directory
#

set -Eeuo pipefail

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)"

REPO_ROOT="$(
    cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1
    pwd
)"

IMAGE_NAME="${IMAGE_NAME:-tear-demo-dlstreamer:2026.1-x86_64}"
MODEL_DIR="${MODEL_DIR:-${1:-}}"

NUM_BUFFERS="${NUM_BUFFERS:-600}"
INPUT_FPS="${INPUT_FPS:-30}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
DEVICE="${DEVICE:-CPU}"

BUILD_IF_MISSING="${BUILD_IF_MISSING:-1}"
CLEAN="${CLEAN:-0}"

LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/x86_64}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/power-save-demo.log}"

EXPECTED_MARKER="[TEAR] POWER_SAVE profile activated at frame 300"

info()
{
    printf '[INFO] %s\n' "$*"
}

fatal()
{
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

run()
{
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

command -v docker >/dev/null 2>&1 ||
    fatal "docker was not found in PATH"

docker info >/dev/null 2>&1 ||
    fatal "Docker daemon is not accessible"

if [[ -z "${MODEL_DIR}" ]]; then
    cat >&2 <<EOF
Usage:
  $0 /path/to/model-directory

The model directory must contain:
  model.xml
  model.bin

It can also be supplied through MODEL_DIR.
EOF
    exit 2
fi

MODEL_DIR="$(
    cd -- "${MODEL_DIR}" >/dev/null 2>&1 &&
    pwd
)" || fatal "Model directory does not exist: ${MODEL_DIR}"

[[ -f "${MODEL_DIR}/model.xml" ]] ||
    fatal "Missing model file: ${MODEL_DIR}/model.xml"

[[ -f "${MODEL_DIR}/model.bin" ]] ||
    fatal "Missing model file: ${MODEL_DIR}/model.bin"

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    if [[ "${BUILD_IF_MISSING}" != "1" ]]; then
        fatal "Docker image does not exist: ${IMAGE_NAME}"
    fi

    info "Docker image is missing; building it first"

    if [[ "${CLEAN}" == "1" ]]; then
        run env CLEAN=1 "${SCRIPT_DIR}/build-x86_64.sh"
    else
        run "${SCRIPT_DIR}/build-x86_64.sh"
    fi
fi

mkdir -p "${LOG_DIR}"
rm -f "${LOG_FILE}"

info "TEAR POWER_SAVE inference test"
info "  Image:       ${IMAGE_NAME}"
info "  Model:       ${MODEL_DIR}/model.xml"
info "  Device:      ${DEVICE}"
info "  Input:       ${INPUT_FPS} FPS"
info "  Buffers:     ${NUM_BUFFERS}"
info "  Transition:  frame 300"
info "  Enforcement: process one of every 10 frames"
info "  Log:         ${LOG_FILE}"

printf '\n'
info "Expected behavior:"
info "  Before frame 300: normal inference throughput"
info "  At frame 300:     POWER_SAVE activation warning"
info "  After frame 300:  approximately 10x lower output throughput"
printf '\n'

set +e

docker run --rm \
    --volume "${MODEL_DIR}:/models:ro" \
    "${IMAGE_NAME}" \
    bash -lc '
        set -o pipefail

        grep -aqF "POWER_SAVE profile activated" \
            /opt/intel/dlstreamer/lib/libgstvideoanalytics.so || {
                printf "[ERROR] Patched POWER_SAVE marker is absent from the runtime library\n" >&2
                exit 20
            }

        GST_DEBUG=2 gst-launch-1.0 -v \
            videotestsrc \
                num-buffers='"${NUM_BUFFERS}"' \
                is-live=true \
            ! video/x-raw,format=BGR,width='"${WIDTH}"',height='"${HEIGHT}"',framerate='"${INPUT_FPS}"'/1 \
            ! gvadetect \
                model=/models/model.xml \
                device='"${DEVICE}"' \
            ! fpsdisplaysink \
                video-sink=fakesink \
                text-overlay=false \
                signal-fps-measurements=true \
                sync=false
    ' 2>&1 | tee "${LOG_FILE}"

pipeline_status=${PIPESTATUS[0]}

set -e

if [[ "${pipeline_status}" -ne 0 ]]; then
    fatal "Pipeline failed with status ${pipeline_status}; see ${LOG_FILE}"
fi

if ! grep -Fq "${EXPECTED_MARKER}" "${LOG_FILE}"; then
    fatal "POWER_SAVE transition was not observed; see ${LOG_FILE}"
fi

if ! grep -Fq "Got EOS from element" "${LOG_FILE}"; then
    fatal "Pipeline did not complete normally; see ${LOG_FILE}"
fi

printf '\n'
info "PASS: POWER_SAVE enforcement was activated at frame 300"
info "PASS: The inference pipeline completed successfully"
info "Log saved to:"
info "  ${LOG_FILE}"
