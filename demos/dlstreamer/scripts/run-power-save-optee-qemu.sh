#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

IMAGE_NAME="${IMAGE_NAME:-tear-demo-dlstreamer:2026.1-aarch64}"
AARCH64_BUILD_SCRIPT="${AARCH64_BUILD_SCRIPT:-${SCRIPT_DIR}/build-aarch64.sh}"
OPTEE_BUILD_SCRIPT="${OPTEE_BUILD_SCRIPT:-${SCRIPT_DIR}/build-optee-qemu.sh}"
EDGE_AI_COMMIT="${EDGE_AI_COMMIT:-5ce5aa03c2fec59dd2e2bbde2153c30a5925b531}"
OPTEE_QEMU_DIR="${OPTEE_QEMU_DIR:-${REPO_ROOT}/third_party/optee-qemu-v8}"
TARGET="${TARGET:-${OPTEE_QEMU_DIR}/out-br/target}"
RUNTIME_ROOT="${RUNTIME_ROOT:-${REPO_ROOT}/out/aarch64/qemu-runtime}"
MODELS_SOURCE="${MODELS_SOURCE:-${REPO_ROOT}/out/models}"
MODELS_TARGET="${MODELS_TARGET:-${TARGET}/opt/tear/models}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

QEMU_MEMORY_MB="${QEMU_MEMORY_MB:-6144}"
QEMU_SMP="${QEMU_SMP:-2}"
QEMU_LOG="${QEMU_LOG:-${REPO_ROOT}/out/aarch64/tear-optee-qemu-demo.log}"

DEMO_FRAMES="${DEMO_FRAMES:-300}"
DEMO_FRAMERATE="${DEMO_FRAMERATE:-30/1}"
DEMO_GST_DEBUG="${DEMO_GST_DEBUG:-3}"
DEMO_EXPECTED_TRANSITION_FRAME="${DEMO_EXPECTED_TRANSITION_FRAME:-30}"
DEMO_EXPECTED_RENDERED="${DEMO_EXPECTED_RENDERED:-57}"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fatal() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

run()
{
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

[[ "$#" -eq 0 ]] || fatal "This script takes no command-line options"

for name in BUILD_JOBS QEMU_MEMORY_MB QEMU_SMP DEMO_FRAMES \
            DEMO_GST_DEBUG DEMO_EXPECTED_TRANSITION_FRAME \
            DEMO_EXPECTED_RENDERED; do
    value="${!name}"
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || fatal "${name} must be a positive integer"
done

for command_name in awk basename cp dirname docker find grep make mkdir \
                    readelf readlink rm sed tar tee; do
    command -v "${command_name}" >/dev/null 2>&1 ||
        fatal "Required command not found: ${command_name}"
done

docker info >/dev/null 2>&1 || fatal "Docker daemon is not accessible"

[[ -x "${AARCH64_BUILD_SCRIPT}" ]] ||
    fatal "AArch64 build script is missing or not executable: ${AARCH64_BUILD_SCRIPT}"
[[ -x "${OPTEE_BUILD_SCRIPT}" ]] ||
    fatal "OP-TEE build script is missing or not executable: ${OPTEE_BUILD_SCRIPT}"

if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    info "Docker image is missing; building it"
    run "${AARCH64_BUILD_SCRIPT}"
fi

docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1 ||
    fatal "AArch64 build completed but Docker image is still missing: ${IMAGE_NAME}"

MODEL_DIR="${MODELS_SOURCE}/pallet_defect_detection" \
EDGE_AI_COMMIT="${EDGE_AI_COMMIT}" \
    "${SCRIPT_DIR}/download-pallet-model.sh"

copy_tree()
{
    local source_root="$1" destination_root="$2" relative_path="$3"
    if [[ ! -e "${source_root}/${relative_path}" ]]; then
        info "Optional path absent: /${relative_path}"
        return 0
    fi
    mkdir -p "${destination_root}/$(dirname "${relative_path}")"
    cp -a "${source_root}/${relative_path}" "${destination_root}/${relative_path}"
}

copy_all_runtime_shared_libraries()
{
    local source_dir="$1" destination_dir="$2"
    [[ -d "${source_dir}" ]] || return 0
    mkdir -p "${destination_dir}"

    while IFS= read -r -d '' path; do
        local relative_path="${path#${source_dir}/}"
        local base_name
        base_name="$(basename "${path}")"
        case "${base_name}" in
            ld-linux-*.so*|libc.so*|libm.so*|libpthread.so*|librt.so*|\
            libdl.so*|libresolv.so*|libutil.so*|libanl.so*|libnss_*.so*|\
            libBrokenLocale.so*)
                continue
                ;;
        esac
        mkdir -p "${destination_dir}/$(dirname "${relative_path}")"
        cp -a "${path}" "${destination_dir}/${relative_path}"
    done < <(
        find "${source_dir}" \( -type f -o -type l \) -name '*.so*' -print0
    )
}

promote_debian_alternative_library()
{
    local root="$1" family="$2" soname="$3"
    local arch_dir="${root}/usr/lib/aarch64-linux-gnu"
    local family_dir="${arch_dir}/${family}"
    local source_library=""

    [[ -d "${family_dir}" ]] || return 0

    source_library="$(find "${family_dir}" -maxdepth 1 -type f -name "${soname}.*" -print -quit)"
    if [[ -z "${source_library}" && -L "${family_dir}/${soname}" ]]; then
        source_library="$(readlink -f "${family_dir}/${soname}" || true)"
    fi
    [[ -n "${source_library}" && -f "${source_library}" ]] ||
        fatal "Could not resolve ${soname} below ${family_dir}"

    mkdir -p "${arch_dir}"
    cp -a "${source_library}" "${arch_dir}/$(basename "${source_library}")"
    ln -sfn "$(basename "${source_library}")" "${arch_dir}/${soname}"
}

fix_debian_alternatives()
{
    promote_debian_alternative_library "$1" lapack liblapack.so.3
    promote_debian_alternative_library "$1" blas libblas.so.3
}

validate_aarch64_elf()
{
    local path="$1" description="$2"
    [[ -e "${path}" ]] || fatal "${description} not found: ${path}"
    readelf -h "${path}" 2>/dev/null | grep -q 'Machine:.*AArch64' ||
        fatal "${description} is not AArch64: ${path}"
}

validate_library()
{
    local root="$1" soname="$2"
    local path="${root}/usr/lib/aarch64-linux-gnu/${soname}"
    local resolved
    resolved="$(readlink -f "${path}" || true)"
    [[ -n "${resolved}" && -f "${resolved}" ]] || fatal "Broken library: ${path}"
    validate_aarch64_elf "${resolved}" "${soname}"
}

validate_models_source()
{
    local model_dir="${MODELS_SOURCE}/pallet_defect_detection"
    [[ -s "${model_dir}/model.xml" ]] || fatal "Missing model.xml: ${model_dir}"
    [[ -s "${model_dir}/model.bin" ]] || fatal "Missing model.bin: ${model_dir}"
}

install_models()
{
    validate_models_source
    info "Installing models into ${MODELS_TARGET}"
    mkdir -p "$(dirname "${MODELS_TARGET}")"
    rm -rf "${MODELS_TARGET}"
    cp -a "${MODELS_SOURCE}" "${MODELS_TARGET}"
}

export_runtime()
{
    local container_id=""
    local rootfs_tar="${RUNTIME_ROOT}/container-rootfs.tar"
    local unpack_dir="${RUNTIME_ROOT}/.container-rootfs"

    cleanup_export()
    {
        [[ -z "${container_id}" ]] || docker rm -f "${container_id}" >/dev/null 2>&1 || true
        rm -rf "${unpack_dir}"
        rm -f "${rootfs_tar}"
    }
    trap cleanup_export RETURN

    info "Exporting runtime from ${IMAGE_NAME}"
    rm -rf "${RUNTIME_ROOT}"
    mkdir -p "${RUNTIME_ROOT}" "${unpack_dir}"

    container_id="$(docker create --platform linux/arm64 "${IMAGE_NAME}")"
    [[ -n "${container_id}" ]] || fatal "docker create returned no container ID"

    docker export --output="${rootfs_tar}" "${container_id}"
    [[ -s "${rootfs_tar}" ]] || fatal "docker export produced an empty archive"
    tar -tf "${rootfs_tar}" >/dev/null || fatal "Invalid exported tar archive"
    tar -xf "${rootfs_tar}" -C "${unpack_dir}"

    local gst_source="${unpack_dir}/src/dlstreamer/build-aarch64/deps/gstreamer-bin"
    local gst_destination="${RUNTIME_ROOT}/opt/tear/gstreamer"
    [[ -d "${gst_source}" ]] || fatal "GStreamer prefix not found: ${gst_source}"

    mkdir -p "$(dirname "${gst_destination}")"
    cp -a "${gst_source}" "${gst_destination}"
    copy_tree "${unpack_dir}" "${RUNTIME_ROOT}" opt/intel/dlstreamer
    copy_tree "${unpack_dir}" "${RUNTIME_ROOT}" opt/intel/openvino
    copy_all_runtime_shared_libraries \
        "${unpack_dir}/usr/lib/aarch64-linux-gnu" \
        "${RUNTIME_ROOT}/usr/lib/aarch64-linux-gnu"
    copy_all_runtime_shared_libraries \
        "${unpack_dir}/lib/aarch64-linux-gnu" \
        "${RUNTIME_ROOT}/lib/aarch64-linux-gnu"
    fix_debian_alternatives "${RUNTIME_ROOT}"

    validate_aarch64_elf "${gst_destination}/bin/gst-launch-1.0" gst-launch-1.0
    validate_aarch64_elf "${gst_destination}/bin/gst-inspect-1.0" gst-inspect-1.0
    validate_aarch64_elf \
        "${RUNTIME_ROOT}/opt/intel/dlstreamer/lib/gstreamer-1.0/libgstvideoanalytics.so" \
        "DL Streamer videoanalytics plugin"
    validate_aarch64_elf \
        "${RUNTIME_ROOT}/opt/intel/openvino/runtime/lib/aarch64/libopenvino.so" \
        "OpenVINO core"
    validate_aarch64_elf \
        "${RUNTIME_ROOT}/opt/intel/openvino/runtime/lib/aarch64/libopenvino_arm_cpu_plugin.so" \
        "OpenVINO ARM CPU plugin"
    validate_library "${RUNTIME_ROOT}" liblapack.so.3
    validate_library "${RUNTIME_ROOT}" libblas.so.3

    grep -aqF 'POWER_SAVE profile activated' \
        "${RUNTIME_ROOT}/opt/intel/dlstreamer/lib/gstreamer-1.0/libgstvideoanalytics.so" ||
        fatal "POWER_SAVE marker is absent from the plugin"

    cleanup_export
    trap - RETURN
    info "AArch64 runtime export completed"
}

install_guest_files()
{
    mkdir -p "${TARGET}/etc/profile.d" "${TARGET}/etc/init.d" "${TARGET}/usr/bin"

    cat >"${TARGET}/etc/profile.d/tear-dlstreamer.sh" <<'PROFILE'
#!/bin/sh
TEAR_ROOT=/opt/tear
TEAR_GSTREAMER_ROOT=${TEAR_ROOT}/gstreamer
TEAR_MODELS_ROOT=${TEAR_ROOT}/models
DLSTREAMER_ROOT=/opt/intel/dlstreamer
DLSTREAMER_PLUGIN_DIR=${DLSTREAMER_ROOT}/lib/gstreamer-1.0
OPENVINO_ROOT=/opt/intel/openvino
OPENVINO_LIB_DIR=${OPENVINO_ROOT}/runtime/lib/aarch64
export TEAR_ROOT TEAR_GSTREAMER_ROOT TEAR_MODELS_ROOT
export DLSTREAMER_ROOT DLSTREAMER_PLUGIN_DIR OPENVINO_ROOT OPENVINO_LIB_DIR
export PATH="${TEAR_GSTREAMER_ROOT}/bin:${DLSTREAMER_ROOT}/bin:${PATH}"
export LD_LIBRARY_PATH="${TEAR_GSTREAMER_ROOT}/lib:${DLSTREAMER_ROOT}/lib:${DLSTREAMER_PLUGIN_DIR}:${OPENVINO_LIB_DIR}:/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export GST_PLUGIN_PATH="${DLSTREAMER_PLUGIN_DIR}:${TEAR_GSTREAMER_ROOT}/lib/gstreamer-1.0"
export GST_PLUGIN_SYSTEM_PATH_1_0=""
export GST_REGISTRY=/tmp/gst-registry-aarch64.bin
export OpenVINO_DIR="${OPENVINO_ROOT}/runtime/cmake"
PROFILE
    chmod +x "${TARGET}/etc/profile.d/tear-dlstreamer.sh"

    cat >"${TARGET}/usr/bin/tear-check-dlstreamer" <<'CHECK'
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
echo "BLAS and LAPACK:"
ls -l /usr/lib/aarch64-linux-gnu/libblas.so.3 \
      /usr/lib/aarch64-linux-gnu/liblapack.so.3

echo
echo "GStreamer:"
gst-launch-1.0 --version

echo
echo "DL Streamer plugin:"
rm -f "${GST_REGISTRY}"
gst-inspect-1.0 gvadetect | grep -E 'Filename|Version|Long-name|Description'

echo
echo "OpenVINO ARM CPU plugin:"
ls -l /opt/intel/openvino/runtime/lib/aarch64/libopenvino_arm_cpu_plugin.so

echo
echo "POWER_SAVE marker:"
grep -aF 'POWER_SAVE profile activated' \
    /opt/intel/dlstreamer/lib/gstreamer-1.0/libgstvideoanalytics.so >/dev/null
echo "PASS: POWER_SAVE marker is present"

echo
echo "Installed model:"
ls -lh "${MODEL_XML}" "${MODEL_BIN}"
[ ! -f "${MODEL_CONFIG}" ] || ls -lh "${MODEL_CONFIG}"
test -s "${MODEL_XML}"
test -s "${MODEL_BIN}"

echo
echo "Minimal GStreamer pipeline:"
gst-launch-1.0 videotestsrc num-buffers=10 ! fakesink

echo
echo "PASS: DL Streamer basic runtime validation completed"
CHECK
    chmod +x "${TARGET}/usr/bin/tear-check-dlstreamer"

    cat >"${TARGET}/usr/bin/tear-run-pallet-detection" <<'INFERENCE'
#!/bin/sh
set -eu
. /etc/profile.d/tear-dlstreamer.sh
MODEL_DIR="${TEAR_MODELS_ROOT}/pallet_defect_detection"
MODEL_XML="${MODEL_DIR}/model.xml"
MODEL_BIN="${MODEL_DIR}/model.bin"
FRAMES="${FRAMES:-300}"
FRAMERATE="${FRAMERATE:-30/1}"
GST_DEBUG_LEVEL="${GST_DEBUG_LEVEL:-3}"
INFERENCE_PRECISION_HINT="${INFERENCE_PRECISION_HINT:-f32}"
test -s "${MODEL_XML}"
test -s "${MODEL_BIN}"
rm -f "${GST_REGISTRY}"
echo "Running pallet defect detection"
echo "Model: ${MODEL_XML}"
echo "Frames: ${FRAMES}"
echo "Framerate: ${FRAMERATE}"
echo "GST_DEBUG: ${GST_DEBUG_LEVEL}"
echo "Inference precision: ${INFERENCE_PRECISION_HINT}"
GST_DEBUG_NO_COLOR=1 GST_DEBUG="${GST_DEBUG_LEVEL}" \
gst-launch-1.0 -v \
    videotestsrc num-buffers="${FRAMES}" is-live=true \
    ! video/x-raw,framerate="${FRAMERATE}" \
    ! videoconvert \
    ! video/x-raw,format=BGRx \
    ! gvadetect model="${MODEL_XML}" device=CPU \
        ie-config="INFERENCE_PRECISION_HINT=${INFERENCE_PRECISION_HINT}" \
    ! fpsdisplaysink video-sink=fakesink text-overlay=false sync=false
INFERENCE
    chmod +x "${TARGET}/usr/bin/tear-run-pallet-detection"

    cat >"${TARGET}/etc/init.d/S99tear-dlstreamer-demo" <<AUTORUN
#!/bin/sh
case "\${1:-start}" in
    start) ;;
    *) exit 0 ;;
esac
[ ! -e /tmp/tear-demo-ran ] || exit 0
touch /tmp/tear-demo-ran
LOG=/tmp/tear-inference.log
FRAMES=${DEMO_FRAMES}
EXPECTED_TRANSITION=${DEMO_EXPECTED_TRANSITION_FRAME}
EXPECTED_RENDERED=${DEMO_EXPECTED_RENDERED}
finish() { sync; poweroff -f; }
fail() {
    echo
    echo "=========================================================="
    echo "TEAR QEMU DEMO FAILED"
    echo "Reason: \$1"
    echo "=========================================================="
    echo "TEAR_QEMU_DEMO_FAIL"
    finish
}

echo
echo "=========================================================="
echo "TEAR OP-TEE QEMU automated demo"
echo "=========================================================="
echo
echo "[1/2] Runtime validation"
/usr/bin/tear-check-dlstreamer || fail "runtime validation failed"

echo
echo "[2/2] Inference and POWER_SAVE validation"
rm -f "\${LOG}"
FRAMES=${DEMO_FRAMES} FRAMERATE=${DEMO_FRAMERATE} \
GST_DEBUG_LEVEL=${DEMO_GST_DEBUG} \
/usr/bin/tear-run-pallet-detection 2>&1 | tee "\${LOG}"

grep -Fq "[TEAR] POWER_SAVE profile activated at frame \${EXPECTED_TRANSITION}" "\${LOG}" ||
    fail "POWER_SAVE transition marker was not observed"
grep -Fq 'Got EOS from element "pipeline0".' "\${LOG}" ||
    fail "inference pipeline did not reach EOS"
rendered="\$(sed -n 's/.*last-message = rendered: \([0-9][0-9]*\),.*/\1/p' "\${LOG}" | tail -1)"
[ -n "\${rendered}" ] || fail "could not determine rendered-frame count"
[ "\${rendered}" -eq "\${EXPECTED_RENDERED}" ] ||
    fail "rendered \${rendered} frames; expected \${EXPECTED_RENDERED}"
skipped=\$((FRAMES - rendered))

echo
echo "=========================================================="
echo "TEAR Demo Summary"
echo "=========================================================="
echo "Model              : pallet_defect_detection"
echo "Input frames       : \${FRAMES}"
echo "Profile switch     : frame \${EXPECTED_TRANSITION}"
echo "Frames rendered    : \${rendered}"
echo "Frames suppressed  : \${skipped}"
echo "POWER_SAVE         : ACTIVE"
echo "Result             : PASS"
echo "=========================================================="
echo "TEAR_QEMU_DEMO_PASS"
finish
AUTORUN
    chmod +x "${TARGET}/etc/init.d/S99tear-dlstreamer-demo"
}

install_runtime()
{
    info "Installing runtime into ${TARGET}"
    fix_debian_alternatives "${RUNTIME_ROOT}"
    validate_library "${RUNTIME_ROOT}" liblapack.so.3
    validate_library "${RUNTIME_ROOT}" libblas.so.3

    mkdir -p "${TARGET}/opt/tear" "${TARGET}/opt/intel" \
        "${TARGET}/usr/lib/aarch64-linux-gnu" "${TARGET}/lib/aarch64-linux-gnu"
    rm -rf "${TARGET}/opt/tear/gstreamer" \
           "${TARGET}/opt/intel/dlstreamer" \
           "${TARGET}/opt/intel/openvino"
    cp -a "${RUNTIME_ROOT}/opt/tear/gstreamer" "${TARGET}/opt/tear/gstreamer"
    cp -a "${RUNTIME_ROOT}/opt/intel/dlstreamer" "${TARGET}/opt/intel/dlstreamer"
    cp -a "${RUNTIME_ROOT}/opt/intel/openvino" "${TARGET}/opt/intel/openvino"
    [[ ! -d "${RUNTIME_ROOT}/usr/lib/aarch64-linux-gnu" ]] ||
        cp -a "${RUNTIME_ROOT}/usr/lib/aarch64-linux-gnu/." "${TARGET}/usr/lib/aarch64-linux-gnu/"
    [[ ! -d "${RUNTIME_ROOT}/lib/aarch64-linux-gnu" ]] ||
        cp -a "${RUNTIME_ROOT}/lib/aarch64-linux-gnu/." "${TARGET}/lib/aarch64-linux-gnu/"

    fix_debian_alternatives "${TARGET}"
    validate_library "${TARGET}" liblapack.so.3
    validate_library "${TARGET}" libblas.so.3
    install_models
    install_guest_files
    info "Runtime and automated guest demo installed"
}

ensure_optee_qemu()
{
    if [[ -f "${OPTEE_QEMU_DIR}/build/Makefile" && -d "${TARGET}" ]]; then
        info "Using existing OP-TEE QEMU checkout:"
        info "  ${OPTEE_QEMU_DIR}"
        return 0
    fi

    info "OP-TEE QEMU dependency is missing or incomplete; restoring it"
    BUILD_JOBS="${BUILD_JOBS}" \
    OPTEE_QEMU_DIR="${OPTEE_QEMU_DIR}" \
        run "${OPTEE_BUILD_SCRIPT}" all

    [[ -f "${OPTEE_QEMU_DIR}/build/Makefile" ]] ||
        fatal "OP-TEE build Makefile is still missing after restore"
    [[ -d "${TARGET}" ]] ||
        fatal "Buildroot target is still missing after OP-TEE build: ${TARGET}"
}

rebuild_qemu()
{
    info "Rebuilding OP-TEE QEMU image after installing TEAR runtime"
    BUILD_JOBS="${BUILD_JOBS}" \
    OPTEE_QEMU_DIR="${OPTEE_QEMU_DIR}" \
        run "${OPTEE_BUILD_SCRIPT}" all
}

run_qemu()
{
    local out_bin="${OPTEE_QEMU_DIR}/out/bin"
    local qemu="${OPTEE_QEMU_DIR}/qemu/build/qemu-system-aarch64"
    [[ -x "${qemu}" ]] || fatal "QEMU executable not found: ${qemu}"
    for image in bl1.bin rootfs.cpio.gz Image; do
        [[ -s "${out_bin}/${image}" ]] || fatal "Missing QEMU artifact: ${out_bin}/${image}"
    done

    mkdir -p "$(dirname "${QEMU_LOG}")"
    rm -f "${QEMU_LOG}"
    info "Starting automated QEMU demo; log: ${QEMU_LOG}"

    set +e
    (
        cd "${out_bin}"
        "${qemu}" \
            -nographic \
            -smp "${QEMU_SMP}" \
            -cpu max,sme=on,pauth-impdef=on \
            -d unimp \
            -semihosting-config enable=on,target=native \
            -m "${QEMU_MEMORY_MB}" \
            -bios bl1.bin \
            -initrd rootfs.cpio.gz \
            -kernel Image \
            -append 'console=ttyAMA0,38400 keep_bootcon root=/dev/vda2 ' \
            -machine virt,acpi=off,secure=on,mte=off,gic-version=3,virtualization=false \
            -object rng-random,filename=/dev/urandom,id=rng0 \
            -device virtio-rng-pci,rng=rng0,max-bytes=1024,period=1000 \
            -netdev user,id=vmnic \
            -device virtio-net-device,netdev=vmnic
    ) 2>&1 | tee "${QEMU_LOG}"
    qemu_status=${PIPESTATUS[0]}
    set -e

    grep -Fq TEAR_QEMU_DEMO_FAIL "${QEMU_LOG}" &&
        fatal "Guest reported failure; see ${QEMU_LOG}"
    grep -Fq TEAR_QEMU_DEMO_PASS "${QEMU_LOG}" ||
        fatal "Guest PASS marker missing; QEMU status=${qemu_status}; see ${QEMU_LOG}"
    [[ "${qemu_status}" -eq 0 ]] ||
        warn "QEMU exited with status ${qemu_status}, but guest PASS was observed"

    info "TEAR OP-TEE QEMU demo PASSED"
}

info "Removing cached runtime: ${RUNTIME_ROOT}"
rm -rf "${RUNTIME_ROOT}"

ensure_optee_qemu
export_runtime
install_runtime
rebuild_qemu
run_qemu

printf '\n'
info "Completed"
