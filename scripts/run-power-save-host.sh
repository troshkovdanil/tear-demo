#!/usr/bin/env bash
#
# Export the patched DL Streamer runtime from Docker and run the
# POWER_SAVE test directly on the x86-64 host.
#
# Usage:
#   ./scripts/run-power-save-host.sh
#
# Force runtime re-export:
#   RESET_RUNTIME=1 ./scripts/run-power-save-host.sh
#
# Rebuild the Docker image first:
#   REBUILD=1 ./scripts/run-power-save-host.sh
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

RUNTIME_ROOT="${RUNTIME_ROOT:-${REPO_ROOT}/out/x86_64/host-runtime}"
MODEL_DIR="${MODEL_DIR:-${REPO_ROOT}/out/models/pallet_defect_detection}"

LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/x86_64}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/power-save-host.log}"

EDGE_AI_COMMIT="${EDGE_AI_COMMIT:-5ce5aa03c2fec59dd2e2bbde2153c30a5925b531}"

NUM_BUFFERS="${NUM_BUFFERS:-600}"
INPUT_FPS="${INPUT_FPS:-30}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
DEVICE="${DEVICE:-CPU}"

RESET_RUNTIME="${RESET_RUNTIME:-0}"
REBUILD="${REBUILD:-0}"

EXPECTED_MARKER="[TEAR] POWER_SAVE profile activated at frame 300"

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

run()
{
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
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

create_environment()
{
    cat >"${RUNTIME_ROOT}/env.sh" <<'EOF'
#!/usr/bin/env bash

RUNTIME_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)"

DLS_ROOT="${RUNTIME_ROOT}/opt/intel/dlstreamer"
OPENCV_ROOT="${RUNTIME_ROOT}/opt/opencv"
OPENVINO_PLUGIN_ROOT="${RUNTIME_ROOT}/usr/lib/openvino-2026.1.0"

prepend_path()
{
    local variable="$1"
    local value="$2"

    [[ -d "${value}" ]] || return 0

    local current="${!variable:-}"

    if [[ -n "${current}" ]]; then
        export "${variable}=${value}:${current}"
    else
        export "${variable}=${value}"
    fi
}

prepend_path PATH \
    "${DLS_ROOT}/gstreamer/bin"

prepend_path PATH \
    "${DLS_ROOT}/bin"

prepend_path LD_LIBRARY_PATH \
    "${DLS_ROOT}/lib"

prepend_path LD_LIBRARY_PATH \
    "${DLS_ROOT}/gstreamer/lib"

prepend_path LD_LIBRARY_PATH \
    "${RUNTIME_ROOT}/usr/lib"

prepend_path LD_LIBRARY_PATH \
    "${OPENVINO_PLUGIN_ROOT}"

prepend_path LD_LIBRARY_PATH \
    "${RUNTIME_ROOT}/usr/lib/x86_64-linux-gnu"

prepend_path LD_LIBRARY_PATH \
    "${OPENCV_ROOT}"

prepend_path PYTHONPATH \
    "${DLS_ROOT}/python"

export GST_PLUGIN_PATH="$(
    printf '%s' \
        "${DLS_ROOT}/lib:" \
        "${DLS_ROOT}/gstreamer/lib/gstreamer-1.0"
)"

export GST_PLUGIN_SYSTEM_PATH_1_0=""
export GST_REGISTRY="${RUNTIME_ROOT}/gst-registry-x86_64.bin"
EOF

    chmod +x "${RUNTIME_ROOT}/env.sh"

    info "Created host environment:"
    info "  ${RUNTIME_ROOT}/env.sh"
}

export_runtime()
{
    info "Exporting runtime from Docker image:"
    info "  ${IMAGE_NAME}"

    rm -rf "${RUNTIME_ROOT}"
    mkdir -p "${RUNTIME_ROOT}"

    docker run --rm \
        "${IMAGE_NAME}" \
        bash -lc '
            set -Eeuo pipefail

            paths_file="$(mktemp)"
            trap "rm -f ${paths_file}" EXIT

            printf "%s\0" \
                /opt/intel/dlstreamer \
                /opt/opencv \
                /usr/lib/openvino-2026.1.0 \
                >"${paths_file}"

            find /usr/lib \
                -maxdepth 1 \
                \( \
                    -name "libopenvino*.so*" \
                    -o -name "libopenvino*.xml" \
                \) \
                -print0 \
                >>"${paths_file}"

            find /usr/lib/x86_64-linux-gnu \
                -maxdepth 1 \
                \( \
                    -name "libtbb*.so*" \
                    -o -name "libhwloc.so*" \
                    -o -name "libva.so*" \
                    -o -name "libva-drm.so*" \
                    -o -name "libva-x11.so*" \
                    -o -name "libva-wayland.so*" \
                    -o -name "libdrm.so*" \
                \) \
                -print0 \
                >>"${paths_file}"

            tar \
                --null \
                --files-from="${paths_file}" \
                --create \
                --file=- \
                --absolute-names
        ' |
        tar \
            --extract \
            --file=- \
            --directory="${RUNTIME_ROOT}"

    [[ -x "${RUNTIME_ROOT}/opt/intel/dlstreamer/gstreamer/bin/gst-launch-1.0" ]] ||
        fatal "Exported runtime does not contain gst-launch-1.0"

    [[ -f "${RUNTIME_ROOT}/opt/intel/dlstreamer/lib/libgstvideoanalytics.so" ]] ||
        fatal "Exported runtime does not contain libgstvideoanalytics.so"

    [[ -f "${RUNTIME_ROOT}/usr/lib/libopenvino.so.2610" ]] ||
        fatal "Exported runtime does not contain OpenVINO core"

    [[ -f "${RUNTIME_ROOT}/usr/lib/openvino-2026.1.0/libopenvino_intel_cpu_plugin.so" ]] ||
        fatal "Exported runtime does not contain the OpenVINO CPU plugin"

    [[ -f "${RUNTIME_ROOT}/opt/opencv/libopencv_core.so.413" ]] ||
        fatal "Exported runtime does not contain OpenCV"

    create_environment
}

###############################################################################
# Validate host
###############################################################################

command -v docker >/dev/null 2>&1 ||
    fatal "docker was not found in PATH"

command -v tar >/dev/null 2>&1 ||
    fatal "tar was not found in PATH"

command -v ldd >/dev/null 2>&1 ||
    fatal "ldd was not found in PATH"

docker info >/dev/null 2>&1 ||
    fatal "Docker daemon is not accessible"

case "$(uname -m)" in
    x86_64 | amd64)
        ;;
    *)
        fatal "This script currently supports only an x86-64 host"
        ;;
esac

###############################################################################
# Build image when requested or missing
###############################################################################

if [[ "${REBUILD}" == "1" ]]; then
    info "Rebuilding Docker image"
    run "${SCRIPT_DIR}/build-x86_64.sh"
fi

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    info "Docker image is missing; building it"
    run "${SCRIPT_DIR}/build-x86_64.sh"
fi

###############################################################################
# Download model
###############################################################################

mkdir -p "${MODEL_DIR}"

download_file config.json
download_file model.xml
download_file model.bin

###############################################################################
# Export runtime
###############################################################################

if [[ "${RESET_RUNTIME}" == "1" ]]; then
    rm -rf "${RUNTIME_ROOT}"
fi

if [[ ! -f "${RUNTIME_ROOT}/env.sh" ]]; then
    export_runtime
else
    info "Using cached host runtime:"
    info "  ${RUNTIME_ROOT}"
fi

###############################################################################
# Load isolated exported environment
###############################################################################

# shellcheck source=/dev/null
source "${RUNTIME_ROOT}/env.sh"

rm -f "${GST_REGISTRY}"

GST_LAUNCH="${RUNTIME_ROOT}/opt/intel/dlstreamer/gstreamer/bin/gst-launch-1.0"
GST_INSPECT="${RUNTIME_ROOT}/opt/intel/dlstreamer/gstreamer/bin/gst-inspect-1.0"

VIDEOANALYTICS_LIB="$(
    printf '%s' \
        "${RUNTIME_ROOT}" \
        "/opt/intel/dlstreamer/lib/libgstvideoanalytics.so"
)"

OPENVINO_CPU_PLUGIN="$(
    printf '%s' \
        "${RUNTIME_ROOT}" \
        "/usr/lib/openvino-2026.1.0/libopenvino_intel_cpu_plugin.so"
)"

###############################################################################
# Validate exported runtime
###############################################################################

grep -aqF "POWER_SAVE profile activated" \
    "${VIDEOANALYTICS_LIB}" ||
    fatal "POWER_SAVE marker is absent from exported libgstvideoanalytics.so"

info "Checking videoanalytics shared-library dependencies"

missing_dependencies="$(
    ldd "${VIDEOANALYTICS_LIB}" |
        awk '/not found/ { print }'
)"

if [[ -n "${missing_dependencies}" ]]; then
    printf '%s\n' "${missing_dependencies}" >&2
    fatal "The exported videoanalytics plugin has unresolved dependencies"
fi

info "Checking OpenVINO CPU plugin dependencies"

missing_cpu_dependencies="$(
    ldd "${OPENVINO_CPU_PLUGIN}" |
        awk '/not found/ { print }'
)"

if [[ -n "${missing_cpu_dependencies}" ]]; then
    printf '%s\n' "${missing_cpu_dependencies}" >&2
    fatal "The exported OpenVINO CPU plugin has unresolved dependencies"
fi

info "Checking gvadetect plugin"

inspect_output="$(
    "${GST_INSPECT}" gvadetect 2>&1
)" || {
    printf '%s\n' "${inspect_output}" >&2
    fatal "gvadetect could not be loaded on the host"
}

printf '%s\n' "${inspect_output}" |
    grep -E 'Filename|Version' || true

loaded_plugin="$(
    printf '%s\n' "${inspect_output}" |
        sed -n 's/^[[:space:]]*Filename[[:space:]]*//p' |
        head -1
)"

case "${loaded_plugin}" in
    "${RUNTIME_ROOT}"/*)
        info "Confirmed exported plugin:"
        info "  ${loaded_plugin}"
        ;;
    *)
        fatal "gvadetect was not loaded from the exported runtime: ${loaded_plugin}"
        ;;
esac

###############################################################################
# Run host pipeline
###############################################################################

mkdir -p "${LOG_DIR}"
rm -f "${LOG_FILE}"

info "TEAR POWER_SAVE host test"
info "  Runtime:     ${RUNTIME_ROOT}"
info "  Model:       ${MODEL_DIR}/model.xml"
info "  Device:      ${DEVICE}"
info "  Input:       ${INPUT_FPS} FPS"
info "  Buffers:     ${NUM_BUFFERS}"
info "  Transition:  frame 300"
info "  Log:         ${LOG_FILE}"

printf '\n'

set +e

GST_DEBUG=2 \
"${GST_LAUNCH}" -v \
    videotestsrc \
        num-buffers="${NUM_BUFFERS}" \
        is-live=true \
    ! "video/x-raw,format=BGR,width=${WIDTH},height=${HEIGHT},framerate=${INPUT_FPS}/1" \
    ! gvadetect \
        model="${MODEL_DIR}/model.xml" \
        device="${DEVICE}" \
    ! fpsdisplaysink \
        video-sink=fakesink \
        text-overlay=false \
        signal-fps-measurements=true \
        sync=false \
    2>&1 |
    tee "${LOG_FILE}"

pipeline_status=${PIPESTATUS[0]}

set -e

if [[ "${pipeline_status}" -ne 0 ]]; then
    fatal "Host pipeline failed with status ${pipeline_status}; see ${LOG_FILE}"
fi

if ! grep -Fq "${EXPECTED_MARKER}" "${LOG_FILE}"; then
    fatal "POWER_SAVE transition was not observed; see ${LOG_FILE}"
fi

if ! grep -Fq 'Got EOS from element' "${LOG_FILE}"; then
    fatal "Host pipeline did not reach EOS; see ${LOG_FILE}"
fi

printf '\n'
info "PASS: exported DL Streamer runtime works directly on the host"
info "PASS: POWER_SAVE enforcement activated at frame 300"
info "PASS: host inference pipeline completed successfully"
info "Log saved to:"
info "  ${LOG_FILE}"
