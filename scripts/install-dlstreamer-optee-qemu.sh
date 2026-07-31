#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

IMAGE_NAME="${IMAGE_NAME:-tear-demo-dlstreamer:2026.1-aarch64}"
OPTEE_QEMU_DIR="${OPTEE_QEMU_DIR:-${REPO_ROOT}/third_party/optee-qemu-v8}"
TARGET="${TARGET:-${OPTEE_QEMU_DIR}/out-br/target}"
RUNTIME_ROOT="${RUNTIME_ROOT:-${REPO_ROOT}/out/aarch64/qemu-runtime}"

MODELS_SOURCE="${MODELS_SOURCE:-${REPO_ROOT}/out/models}"
MODELS_TARGET="${MODELS_TARGET:-${TARGET}/opt/tear/models}"

BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

RESET_RUNTIME=0
REBUILD_QEMU=0

info()
{
    printf '[INFO] %s\n' "$*"
}

warn()
{
    printf '[WARN] %s\n' "$*" >&2
}

fatal()
{
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage()
{
    cat <<EOF
Usage:
  $0 [--reset-runtime] [--rebuild-qemu]

Options:
  --reset-runtime
      Remove the cached exported AArch64 runtime first.

  --rebuild-qemu
      Rebuild the OP-TEE QEMU/Buildroot images after installation.

  -h, --help
      Show this help.

Environment:
  IMAGE_NAME
      Docker image to export.

      Default:
        ${IMAGE_NAME}

  OPTEE_QEMU_DIR
      OP-TEE QEMU checkout.

      Default:
        ${OPTEE_QEMU_DIR}

  TARGET
      Buildroot target root filesystem.

      Default:
        ${TARGET}

  RUNTIME_ROOT
      Host-side exported runtime cache.

      Default:
        ${RUNTIME_ROOT}

  MODELS_SOURCE
      Host directory containing inference models.

      Default:
        ${MODELS_SOURCE}

  MODELS_TARGET
      Destination directory inside the Buildroot target filesystem.

      Default:
        ${MODELS_TARGET}

  BUILD_JOBS
      Parallel jobs for the OP-TEE QEMU rebuild.

      Default:
        ${BUILD_JOBS}
EOF
}

while (($#)); do
    case "$1" in
        --reset-runtime)
            RESET_RUNTIME=1
            ;;

        --rebuild-qemu)
            REBUILD_QEMU=1
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            fatal "Unknown option: $1"
            ;;
    esac

    shift
done

[[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] ||
    fatal "BUILD_JOBS must be a positive integer"

for command_name in \
    basename \
    cp \
    dirname \
    docker \
    find \
    grep \
    make \
    mkdir \
    readelf \
    readlink \
    rm \
    tar
do
    command -v "${command_name}" >/dev/null 2>&1 ||
        fatal "Required command not found: ${command_name}"
done

docker info >/dev/null 2>&1 ||
    fatal "Docker daemon is not accessible"

docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1 ||
    fatal "Docker image is missing: ${IMAGE_NAME}"

[[ -d "${OPTEE_QEMU_DIR}" ]] ||
    fatal "OP-TEE QEMU directory is missing: ${OPTEE_QEMU_DIR}"

[[ -d "${TARGET}" ]] ||
    fatal "Buildroot target directory is missing: ${TARGET}"

[[ -d "${MODELS_SOURCE}" ]] ||
    fatal "Model source directory is missing: ${MODELS_SOURCE}"

copy_tree()
{
    local source_root="$1"
    local destination_root="$2"
    local relative_path="$3"

    if [[ ! -e "${source_root}/${relative_path}" ]]; then
        info "Optional path absent: /${relative_path}"
        return 0
    fi

    mkdir -p \
        "${destination_root}/$(dirname "${relative_path}")"

    cp -a \
        "${source_root}/${relative_path}" \
        "${destination_root}/${relative_path}"
}

copy_all_runtime_shared_libraries()
{
    local source_dir="$1"
    local destination_dir="$2"

    [[ -d "${source_dir}" ]] ||
        return 0

    mkdir -p "${destination_dir}"

    #
    # Copy every shared-library file and symlink recursively while preserving
    # subdirectories such as:
    #
    #   gstreamer-1.0/
    #   blas/
    #   lapack/
    #   dri/
    #   qt5/
    #   sasl2/
    #
    # Do not import the container's glibc or dynamic-loader family. The
    # Buildroot guest must retain its own libc and loader. Mixing Ubuntu glibc
    # with the Buildroot loader can make the guest unbootable.
    #
    while IFS= read -r -d '' path; do
        local relative_path
        local base_name

        relative_path="${path#${source_dir}/}"
        base_name="$(basename "${path}")"

        case "${base_name}" in
            ld-linux-*.so*|\
            libc.so*|\
            libm.so*|\
            libpthread.so*|\
            librt.so*|\
            libdl.so*|\
            libresolv.so*|\
            libutil.so*|\
            libanl.so*|\
            libnss_*.so*|\
            libBrokenLocale.so*)
                continue
                ;;
        esac

        mkdir -p \
            "${destination_dir}/$(dirname "${relative_path}")"

        cp -a \
            "${path}" \
            "${destination_dir}/${relative_path}"
    done < <(
        find "${source_dir}" \
            \( -type f -o -type l \) \
            -name '*.so*' \
            -print0
    )
}

promote_debian_alternative_library()
{
    local root="$1"
    local family="$2"
    local soname="$3"

    local architecture_lib_dir
    local family_dir
    local source_library
    local destination_library
    local destination_soname
    local family_soname

    architecture_lib_dir="${root}/usr/lib/aarch64-linux-gnu"
    family_dir="${architecture_lib_dir}/${family}"
    destination_soname="${architecture_lib_dir}/${soname}"

    if [[ ! -d "${family_dir}" ]]; then
        info "Optional ${family} library directory absent: ${family_dir}"
        return 0
    fi

    #
    # Debian and Ubuntu expose BLAS/LAPACK through links such as:
    #
    #   /usr/lib/aarch64-linux-gnu/liblapack.so.3
    #       -> /etc/alternatives/liblapack.so.3-aarch64-linux-gnu
    #
    # Buildroot does not provide Debian's /etc/alternatives infrastructure.
    # Find the real versioned library, place it into the normal architecture
    # directory and create a direct relative SONAME link.
    #
    source_library="$(
        find "${family_dir}" \
            -maxdepth 1 \
            -type f \
            -name "${soname}.*" \
            -print \
            -quit
    )"

    if [[ -z "${source_library}" ]]; then
        family_soname="${family_dir}/${soname}"

        if [[ -L "${family_soname}" ]]; then
            source_library="$(
                readlink -f "${family_soname}" ||
                    true
            )"
        fi
    fi

    if [[ -z "${source_library}" || ! -f "${source_library}" ]]; then
        warn "Could not find a real ${soname} library below ${family_dir}"
        return 0
    fi

    destination_library="${architecture_lib_dir}/$(basename "${source_library}")"

    mkdir -p "${architecture_lib_dir}"

    cp -a \
        "${source_library}" \
        "${destination_library}"

    ln -sfn \
        "$(basename "${destination_library}")" \
        "${destination_soname}"

    info "Replaced Debian alternatives link:"
    info "  ${destination_soname}"
    info "  -> $(basename "${destination_library}")"
}

fix_debian_alternatives()
{
    local root="$1"

    promote_debian_alternative_library \
        "${root}" \
        "lapack" \
        "liblapack.so.3"

    promote_debian_alternative_library \
        "${root}" \
        "blas" \
        "libblas.so.3"
}

validate_aarch64_elf()
{
    local path="$1"
    local description="$2"

    [[ -e "${path}" ]] ||
        fatal "${description} not found: ${path}"

    readelf -h "${path}" 2>/dev/null |
        grep -q 'Machine:.*AArch64' ||
        fatal "${description} is not AArch64: ${path}"
}

validate_promoted_library()
{
    local root="$1"
    local soname="$2"

    local path
    local resolved_path

    path="${root}/usr/lib/aarch64-linux-gnu/${soname}"

    [[ -L "${path}" || -f "${path}" ]] ||
        fatal "Required runtime library is absent: ${path}"

    resolved_path="$(
        readlink -f "${path}" ||
            true
    )"

    [[ -n "${resolved_path}" && -f "${resolved_path}" ]] ||
        fatal "Runtime library link is broken: ${path}"

    validate_aarch64_elf \
        "${resolved_path}" \
        "${soname}"
}

validate_models_source()
{
    local model_dir="${MODELS_SOURCE}/pallet_defect_detection"
    local model_xml="${model_dir}/model.xml"
    local model_bin="${model_dir}/model.bin"

    [[ -d "${model_dir}" ]] ||
        fatal "Pallet defect detection model directory is absent: ${model_dir}"

    [[ -s "${model_xml}" ]] ||
        fatal "OpenVINO model XML is absent or empty: ${model_xml}"

    [[ -s "${model_bin}" ]] ||
        fatal "OpenVINO model BIN is absent or empty: ${model_bin}"

    info "Validated model:"
    info "  ${model_xml}"
    info "  ${model_bin}"

    if [[ -f "${model_dir}/config.json" ]]; then
        info "Found model configuration:"
        info "  ${model_dir}/config.json"
    else
        warn "No config.json found in ${model_dir}"
    fi
}

install_models()
{
    validate_models_source

    info "Installing models:"
    info "  source:      ${MODELS_SOURCE}"
    info "  destination: ${MODELS_TARGET}"

    mkdir -p "$(dirname "${MODELS_TARGET}")"

    rm -rf "${MODELS_TARGET}"

    cp -a \
        "${MODELS_SOURCE}" \
        "${MODELS_TARGET}"

    local installed_model_dir
    local installed_model_xml
    local installed_model_bin

    installed_model_dir="${MODELS_TARGET}/pallet_defect_detection"
    installed_model_xml="${installed_model_dir}/model.xml"
    installed_model_bin="${installed_model_dir}/model.bin"

    [[ -s "${installed_model_xml}" ]] ||
        fatal "Installed OpenVINO model XML is absent: ${installed_model_xml}"

    [[ -s "${installed_model_bin}" ]] ||
        fatal "Installed OpenVINO model BIN is absent: ${installed_model_bin}"

    info "Models installed successfully"
}

export_runtime()
{
    local container_id=""
    local rootfs_tar="${RUNTIME_ROOT}/container-rootfs.tar"
    local unpack_dir="${RUNTIME_ROOT}/.container-rootfs"

    cleanup_export()
    {
        if [[ -n "${container_id}" ]]; then
            docker rm -f \
                "${container_id}" \
                >/dev/null 2>&1 ||
                true
        fi

        rm -rf "${unpack_dir}"
        rm -f "${rootfs_tar}"
    }

    trap cleanup_export RETURN

    info "Exporting runtime from ${IMAGE_NAME}"
    info "The AArch64 container is not executed; docker export reads its filesystem."

    rm -rf "${RUNTIME_ROOT}"

    mkdir -p \
        "${RUNTIME_ROOT}" \
        "${unpack_dir}"

    container_id="$(
        docker create \
            --platform linux/arm64 \
            "${IMAGE_NAME}"
    )"

    [[ -n "${container_id}" ]] ||
        fatal "docker create did not return a container ID"

    info "Temporary container: ${container_id}"

    docker export \
        --output="${rootfs_tar}" \
        "${container_id}"

    [[ -s "${rootfs_tar}" ]] ||
        fatal "docker export produced an empty archive"

    tar -tf "${rootfs_tar}" >/dev/null ||
        fatal "docker export produced an invalid tar archive"

    info "Extracting exported container filesystem"

    tar \
        -xf "${rootfs_tar}" \
        -C "${unpack_dir}"

    #
    # Runtime layout in the AArch64 image:
    #
    # GStreamer:
    #   /src/dlstreamer/build-aarch64/deps/gstreamer-bin
    #
    # DL Streamer:
    #   /opt/intel/dlstreamer
    #
    # OpenVINO:
    #   /opt/intel/openvino
    #
    # OpenCV and system dependencies:
    #   /usr/lib/aarch64-linux-gnu
    #   /lib/aarch64-linux-gnu
    #

    local gst_source
    local gst_destination

    gst_source="${unpack_dir}/src/dlstreamer/build-aarch64/deps/gstreamer-bin"
    gst_destination="${RUNTIME_ROOT}/opt/tear/gstreamer"

    [[ -d "${gst_source}" ]] ||
        fatal "GStreamer runtime prefix not found: ${gst_source}"

    mkdir -p "$(dirname "${gst_destination}")"

    cp -a \
        "${gst_source}" \
        "${gst_destination}"

    copy_tree \
        "${unpack_dir}" \
        "${RUNTIME_ROOT}" \
        "opt/intel/dlstreamer"

    copy_tree \
        "${unpack_dir}" \
        "${RUNTIME_ROOT}" \
        "opt/intel/openvino"

    copy_all_runtime_shared_libraries \
        "${unpack_dir}/usr/lib/aarch64-linux-gnu" \
        "${RUNTIME_ROOT}/usr/lib/aarch64-linux-gnu"

    copy_all_runtime_shared_libraries \
        "${unpack_dir}/lib/aarch64-linux-gnu" \
        "${RUNTIME_ROOT}/lib/aarch64-linux-gnu"

    fix_debian_alternatives "${RUNTIME_ROOT}"

    local gst_launch
    local gst_inspect
    local plugin
    local openvino_core
    local cpu_plugin

    gst_launch="${RUNTIME_ROOT}/opt/tear/gstreamer/bin/gst-launch-1.0"
    gst_inspect="${RUNTIME_ROOT}/opt/tear/gstreamer/bin/gst-inspect-1.0"
    plugin="${RUNTIME_ROOT}/opt/intel/dlstreamer/lib/gstreamer-1.0/libgstvideoanalytics.so"
    openvino_core="${RUNTIME_ROOT}/opt/intel/openvino/runtime/lib/aarch64/libopenvino.so"
    cpu_plugin="${RUNTIME_ROOT}/opt/intel/openvino/runtime/lib/aarch64/libopenvino_arm_cpu_plugin.so"

    validate_aarch64_elf \
        "${gst_launch}" \
        "gst-launch-1.0"

    validate_aarch64_elf \
        "${gst_inspect}" \
        "gst-inspect-1.0"

    validate_aarch64_elf \
        "${plugin}" \
        "DL Streamer videoanalytics plugin"

    validate_aarch64_elf \
        "${openvino_core}" \
        "OpenVINO core"

    validate_aarch64_elf \
        "${cpu_plugin}" \
        "OpenVINO ARM CPU plugin"

    validate_promoted_library \
        "${RUNTIME_ROOT}" \
        "liblapack.so.3"

    validate_promoted_library \
        "${RUNTIME_ROOT}" \
        "libblas.so.3"

    grep -aqF \
        'POWER_SAVE profile activated' \
        "${plugin}" ||
        fatal "POWER_SAVE marker is absent from ${plugin}"

    cleanup_export
    trap - RETURN

    info "AArch64 runtime export completed successfully"
}

install_runtime()
{
    info "Installing runtime into ${TARGET}"

    #
    # Repair an existing cached runtime too. This supports rerunning the
    # script without --reset-runtime after an older export created dangling
    # Debian /etc/alternatives links.
    #
    fix_debian_alternatives "${RUNTIME_ROOT}"

    validate_promoted_library \
        "${RUNTIME_ROOT}" \
        "liblapack.so.3"

    validate_promoted_library \
        "${RUNTIME_ROOT}" \
        "libblas.so.3"

    mkdir -p \
        "${TARGET}/opt/tear" \
        "${TARGET}/opt/intel" \
        "${TARGET}/usr/lib/aarch64-linux-gnu" \
        "${TARGET}/lib/aarch64-linux-gnu" \
        "${TARGET}/usr/bin" \
        "${TARGET}/etc/profile.d"

    rm -rf \
        "${TARGET}/opt/tear/gstreamer" \
        "${TARGET}/opt/intel/dlstreamer" \
        "${TARGET}/opt/intel/openvino"

    cp -a \
        "${RUNTIME_ROOT}/opt/tear/gstreamer" \
        "${TARGET}/opt/tear/gstreamer"

    cp -a \
        "${RUNTIME_ROOT}/opt/intel/dlstreamer" \
        "${TARGET}/opt/intel/dlstreamer"

    cp -a \
        "${RUNTIME_ROOT}/opt/intel/openvino" \
        "${TARGET}/opt/intel/openvino"

    if [[ -d "${RUNTIME_ROOT}/usr/lib/aarch64-linux-gnu" ]]; then
        cp -a \
            "${RUNTIME_ROOT}/usr/lib/aarch64-linux-gnu/." \
            "${TARGET}/usr/lib/aarch64-linux-gnu/"
    fi

    if [[ -d "${RUNTIME_ROOT}/lib/aarch64-linux-gnu" ]]; then
        cp -a \
            "${RUNTIME_ROOT}/lib/aarch64-linux-gnu/." \
            "${TARGET}/lib/aarch64-linux-gnu/"
    fi

    fix_debian_alternatives "${TARGET}"

    validate_promoted_library \
        "${TARGET}" \
        "liblapack.so.3"

    validate_promoted_library \
        "${TARGET}" \
        "libblas.so.3"

    install_models

    cat >"${TARGET}/etc/profile.d/tear-dlstreamer.sh" <<'EOF'
#!/bin/sh

TEAR_ROOT=/opt/tear
TEAR_GSTREAMER_ROOT=${TEAR_ROOT}/gstreamer
TEAR_MODELS_ROOT=${TEAR_ROOT}/models

DLSTREAMER_ROOT=/opt/intel/dlstreamer
DLSTREAMER_PLUGIN_DIR=${DLSTREAMER_ROOT}/lib/gstreamer-1.0

OPENVINO_ROOT=/opt/intel/openvino
OPENVINO_LIB_DIR=${OPENVINO_ROOT}/runtime/lib/aarch64

export TEAR_ROOT
export TEAR_GSTREAMER_ROOT
export TEAR_MODELS_ROOT
export DLSTREAMER_ROOT
export DLSTREAMER_PLUGIN_DIR
export OPENVINO_ROOT
export OPENVINO_LIB_DIR

export PATH="${TEAR_GSTREAMER_ROOT}/bin:${DLSTREAMER_ROOT}/bin:${PATH}"

export LD_LIBRARY_PATH="${TEAR_GSTREAMER_ROOT}/lib:${DLSTREAMER_ROOT}/lib:${DLSTREAMER_PLUGIN_DIR}:${OPENVINO_LIB_DIR}:/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

export GST_PLUGIN_PATH="${DLSTREAMER_PLUGIN_DIR}:${TEAR_GSTREAMER_ROOT}/lib/gstreamer-1.0"

export GST_PLUGIN_SYSTEM_PATH_1_0=""
export GST_REGISTRY=/tmp/gst-registry-aarch64.bin

export OpenVINO_DIR="${OPENVINO_ROOT}/runtime/cmake"
EOF

    chmod +x \
        "${TARGET}/etc/profile.d/tear-dlstreamer.sh"

    cat >"${TARGET}/usr/bin/tear-check-dlstreamer" <<'EOF'
#!/bin/sh
set -eu

. /etc/profile.d/tear-dlstreamer.sh

MODEL_DIR="${TEAR_MODELS_ROOT}/pallet_defect_detection"
MODEL_XML="${MODEL_DIR}/model.xml"
MODEL_BIN="${MODEL_DIR}/model.bin"
MODEL_CONFIG="${MODEL_DIR}/config.json"

echo "Architecture:"
uname -m

echo
echo "Dynamic loader:"
readelf -l \
    /opt/tear/gstreamer/bin/gst-launch-1.0 \
    2>/dev/null |
    grep 'Requesting program interpreter' ||
    true

echo
echo "BLAS and LAPACK:"
ls -l \
    /usr/lib/aarch64-linux-gnu/libblas.so.3 \
    /usr/lib/aarch64-linux-gnu/liblapack.so.3

test -e /usr/lib/aarch64-linux-gnu/libblas.so.3
test -e /usr/lib/aarch64-linux-gnu/liblapack.so.3

echo
echo "GStreamer:"
gst-launch-1.0 --version

echo
echo "DL Streamer plugin:"

rm -f "${GST_REGISTRY}"

gst-inspect-1.0 gvadetect |
    grep -E 'Filename|Version|Long-name|Description'

echo
echo "OpenVINO ARM CPU plugin:"
ls -l \
    /opt/intel/openvino/runtime/lib/aarch64/libopenvino_arm_cpu_plugin.so

echo
echo "POWER_SAVE marker:"
grep -aF \
    'POWER_SAVE profile activated' \
    /opt/intel/dlstreamer/lib/gstreamer-1.0/libgstvideoanalytics.so \
    >/dev/null

echo "PASS: POWER_SAVE marker is present"

echo
echo "Installed model:"
ls -lh \
    "${MODEL_XML}" \
    "${MODEL_BIN}"

test -s "${MODEL_XML}"
test -s "${MODEL_BIN}"

if [ -f "${MODEL_CONFIG}" ]; then
    ls -lh "${MODEL_CONFIG}"
fi

echo
echo "Model environment:"
echo "TEAR_MODELS_ROOT=${TEAR_MODELS_ROOT}"
echo "MODEL_XML=${MODEL_XML}"
echo "MODEL_BIN=${MODEL_BIN}"

echo
echo "Minimal GStreamer pipeline:"
gst-launch-1.0 \
    videotestsrc num-buffers=10 \
    ! fakesink

echo
echo "PASS: DL Streamer basic runtime validation completed"
EOF

    chmod +x \
        "${TARGET}/usr/bin/tear-check-dlstreamer"

    cat >"${TARGET}/usr/bin/tear-run-pallet-detection" <<'EOF'
#!/bin/sh
set -eu

. /etc/profile.d/tear-dlstreamer.sh

MODEL_DIR="${TEAR_MODELS_ROOT}/pallet_defect_detection"
MODEL_XML="${MODEL_DIR}/model.xml"
MODEL_BIN="${MODEL_DIR}/model.bin"

FRAMES="${FRAMES:-300}"
FRAMERATE="${FRAMERATE:-30/1}"
GST_DEBUG_LEVEL="${GST_DEBUG_LEVEL:-3}"

test -s "${MODEL_XML}"
test -s "${MODEL_BIN}"

rm -f "${GST_REGISTRY}"

echo "Running pallet defect detection"
echo "Model: ${MODEL_XML}"
echo "Frames: ${FRAMES}"
echo "Framerate: ${FRAMERATE}"
echo "GST_DEBUG: ${GST_DEBUG_LEVEL}"

GST_DEBUG_NO_COLOR=1 \
GST_DEBUG="${GST_DEBUG_LEVEL}" \
gst-launch-1.0 -v \
    videotestsrc \
        num-buffers="${FRAMES}" \
        is-live=true \
    ! video/x-raw,framerate="${FRAMERATE}" \
    ! videoconvert \
    ! video/x-raw,format=BGRx \
    ! gvadetect \
        model="${MODEL_XML}" \
        device=CPU \
        ie-config="INFERENCE_PRECISION_HINT=f32" \
    ! fpsdisplaysink \
        video-sink=fakesink \
        text-overlay=false \
        sync=false
EOF

    chmod +x \
        "${TARGET}/usr/bin/tear-run-pallet-detection"

    info "Runtime installed into the Buildroot target"
    info "Models installed into:"
    info "  /opt/tear/models"
    info "Guest validation command:"
    info "  /usr/bin/tear-check-dlstreamer"
    info "Guest inference command:"
    info "  /usr/bin/tear-run-pallet-detection"
}

if [[ "${RESET_RUNTIME}" == "1" ]]; then
    info "Removing cached runtime: ${RUNTIME_ROOT}"
    rm -rf "${RUNTIME_ROOT}"
fi

if [[ ! -x "${RUNTIME_ROOT}/opt/tear/gstreamer/bin/gst-launch-1.0" ]]; then
    export_runtime
else
    info "Using cached runtime: ${RUNTIME_ROOT}"
fi

install_runtime

if [[ "${REBUILD_QEMU}" == "1" ]]; then
    info "Rebuilding OP-TEE QEMU with ${BUILD_JOBS} jobs"

    make \
        -C "${OPTEE_QEMU_DIR}/build" \
        -j "${BUILD_JOBS}" \
        all
else
    info "QEMU image was not rebuilt"
fi

printf '\n'

info "Completed"
info "After QEMU boots, run:"
info "  /usr/bin/tear-check-dlstreamer"
info "Then run actual inference with:"
info "  /usr/bin/tear-run-pallet-detection"
