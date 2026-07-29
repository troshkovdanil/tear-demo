#!/usr/bin/env bash
#
# Clone, patch, and build the TEAR DL Streamer AArch64 image from an x86-64
# host. Docker Buildx runs the AArch64 build through QEMU binfmt.
#
# Default behavior:
#   - reuse the Docker/BuildKit cache;
#   - reuse the existing DL Streamer checkout;
#   - apply the TEAR patch;
#   - load the resulting image into Docker.
#
# Usage:
#   ./scripts/build-aarch64.sh [options]
#
# Options:
#   --clean          Disable the BuildKit cache for this build.
#   --pull           Always check for a newer base image.
#   --reset-source   Remove and re-clone the DL Streamer checkout.
#   --no-patch       Build without applying the TEAR patch.
#   --no-load        Do not load the resulting image into Docker.
#   --export-oci     Export an OCI archive under out/aarch64/.
#   --jobs N         Use N parallel jobs for GStreamer and DL Streamer.
#   -h, --help       Show this help.
#
# Environment-variable compatibility:
#   CLEAN=1
#   PULL=1
#   RESET_SOURCE=1
#   APPLY_PATCH=0
#   LOAD_IMAGE=0
#   EXPORT_OCI=1
#   BUILD_JOBS=N
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

THIRD_PARTY_DIR="${THIRD_PARTY_DIR:-${REPO_ROOT}/third_party}"
DLSTREAMER_DIR="${DLSTREAMER_DIR:-${THIRD_PARTY_DIR}/dlstreamer}"
PATCH_FILE="${PATCH_FILE:-${REPO_ROOT}/patches/dlstreamer-tear.patch}"
DOCKERFILE_PATH="${DOCKERFILE:-${REPO_ROOT}/docker/aarch64.Dockerfile}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/out/aarch64}"

DLSTREAMER_URL="${DLSTREAMER_URL:-https://github.com/open-edge-platform/dlstreamer.git}"
DLSTREAMER_REF="${DLSTREAMER_REF:-728189a0c5e3d8ee386d9673d0bc50761c2259dc}"

IMAGE_NAME="${IMAGE_NAME:-tear-demo-dlstreamer}"
IMAGE_TAG="${IMAGE_TAG:-2026.1-aarch64}"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
TARGET_PLATFORM="${TARGET_PLATFORM:-linux/arm64}"
BUILDER_NAME="${BUILDER_NAME:-tear-demo-builder}"

APPLY_PATCH="${APPLY_PATCH:-1}"
RESET_SOURCE="${RESET_SOURCE:-0}"
CLEAN="${CLEAN:-0}"
PULL="${PULL:-0}"
LOAD_IMAGE="${LOAD_IMAGE:-1}"
EXPORT_OCI="${EXPORT_OCI:-0}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fatal() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
run() { printf '+'; printf ' %q' "$@"; printf '\n'; "$@"; }

usage()
{
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" |
        sed -e 's/^# \{0,1\}//'
}

require_boolean()
{
    local name="$1"
    local value="$2"

    case "${value}" in
        0 | 1)
            ;;
        *)
            fatal "${name} must be 0 or 1, got: ${value}"
            ;;
    esac
}

on_error()
{
    local status=$?
    local line="${1:-unknown}"

    printf '\n[ERROR] Command failed at line %s with status %s\n' \
        "${line}" "${status}" >&2
    exit "${status}"
}
trap 'on_error ${LINENO}' ERR

while (($# > 0)); do
    case "$1" in
        --clean)
            CLEAN=1
            ;;
        --pull)
            PULL=1
            ;;
        --reset-source)
            RESET_SOURCE=1
            ;;
        --no-patch)
            APPLY_PATCH=0
            ;;
        --no-load)
            LOAD_IMAGE=0
            ;;
        --export-oci)
            EXPORT_OCI=1
            ;;
        --jobs)
            (($# >= 2)) || fatal "--jobs requires a positive integer"
            BUILD_JOBS="$2"
            shift
            ;;
        --jobs=*)
            BUILD_JOBS="${1#*=}"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            fatal "Unknown option: $1. Use --help for usage."
            ;;
    esac
    shift
done

(($# == 0)) || fatal "Unexpected positional arguments: $*"

require_boolean APPLY_PATCH "${APPLY_PATCH}"
require_boolean RESET_SOURCE "${RESET_SOURCE}"
require_boolean CLEAN "${CLEAN}"
require_boolean PULL "${PULL}"
require_boolean LOAD_IMAGE "${LOAD_IMAGE}"
require_boolean EXPORT_OCI "${EXPORT_OCI}"

[[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] ||
    fatal "BUILD_JOBS must be a positive integer, got: ${BUILD_JOBS}"

install_buildx()
{
    if docker buildx version >/dev/null 2>&1; then
        return 0
    fi

    warn "Docker Buildx is not installed"
    command -v apt-get >/dev/null 2>&1 ||
        fatal "Buildx is missing and apt-get is unavailable"
    command -v sudo >/dev/null 2>&1 ||
        fatal "Buildx is missing and sudo is unavailable"

    run sudo apt-get update

    if sudo apt-get install -y docker-buildx-plugin; then
        :
    elif sudo apt-get install -y docker-buildx; then
        :
    else
        fatal "Could not install Docker Buildx"
    fi

    docker buildx version >/dev/null 2>&1 ||
        fatal "Buildx installation completed, but docker buildx still fails"
}

ensure_arm64_emulation()
{
    case "$(uname -m)" in
        aarch64 | arm64)
            info "Native AArch64 host detected; binfmt installation is unnecessary"
            return 0
            ;;
        x86_64 | amd64)
            ;;
        *)
            warn "Unrecognized host architecture: $(uname -m)"
            ;;
    esac

    if [[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] &&
        grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64; then
        info "AArch64 binfmt emulation is already enabled"
        return 0
    fi

    info "Installing AArch64 binfmt emulation"
    run docker run --privileged --rm tonistiigi/binfmt --install arm64
}

ensure_builder()
{
    if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
        info "Creating Docker Buildx builder: ${BUILDER_NAME}"
        run docker buildx create \
            --name "${BUILDER_NAME}" \
            --driver docker-container \
            --use
    else
        run docker buildx use "${BUILDER_NAME}"
    fi

    run docker buildx inspect --builder "${BUILDER_NAME}" --bootstrap

    if ! docker buildx inspect "${BUILDER_NAME}" |
        grep -q 'linux/arm64'; then
        warn "Builder does not explicitly report linux/arm64 support"
        warn "The build will nevertheless be attempted"
    fi
}

command -v git >/dev/null 2>&1 || fatal "git was not found in PATH"
command -v docker >/dev/null 2>&1 || fatal "docker was not found in PATH"
command -v sha256sum >/dev/null 2>&1 || fatal "sha256sum was not found in PATH"
command -v nproc >/dev/null 2>&1 || fatal "nproc was not found in PATH"

docker info >/dev/null 2>&1 ||
    fatal "Docker daemon is not accessible"

[[ -f "${DOCKERFILE_PATH}" ]] ||
    fatal "AArch64 Dockerfile not found: ${DOCKERFILE_PATH}"

install_buildx
ensure_arm64_emulation
ensure_builder

mkdir -p "${THIRD_PARTY_DIR}" "${REPO_ROOT}/patches" "${OUTPUT_DIR}"

if [[ "${RESET_SOURCE}" == "1" && -e "${DLSTREAMER_DIR}" ]]; then
    info "Removing existing DL Streamer checkout"
    run rm -rf "${DLSTREAMER_DIR}"
fi

if [[ ! -d "${DLSTREAMER_DIR}/.git" ]]; then
    info "Cloning standalone DL Streamer repository"
    run git clone --filter=blob:none --no-checkout \
        "${DLSTREAMER_URL}" "${DLSTREAMER_DIR}"
else
    info "Using existing DL Streamer checkout:"
    info "  ${DLSTREAMER_DIR}"
fi

info "Fetching DL Streamer revision:"
info "  ${DLSTREAMER_REF}"
run git -C "${DLSTREAMER_DIR}" fetch --force --tags origin

if ! git -C "${DLSTREAMER_DIR}" rev-parse \
    --verify "${DLSTREAMER_REF}^{commit}" >/dev/null 2>&1; then
    run git -C "${DLSTREAMER_DIR}" fetch --force origin "${DLSTREAMER_REF}"
fi

RESOLVED_COMMIT="$(
    git -C "${DLSTREAMER_DIR}" rev-parse "${DLSTREAMER_REF}^{commit}"
)"

info "Resolved commit:"
info "  ${RESOLVED_COMMIT}"

run git -C "${DLSTREAMER_DIR}" checkout \
    --force \
    --detach \
    "${RESOLVED_COMMIT}"

run git -C "${DLSTREAMER_DIR}" reset --hard "${RESOLVED_COMMIT}"
run git -C "${DLSTREAMER_DIR}" clean -ffdx

info "Updating DL Streamer submodules"
run git -C "${DLSTREAMER_DIR}" submodule sync --recursive
run git -C "${DLSTREAMER_DIR}" submodule update --init --recursive

PATCH_APPLIED="false"
PATCH_SHA256="none"

if [[ "${APPLY_PATCH}" == "1" ]]; then
    [[ -f "${PATCH_FILE}" ]] ||
        fatal "TEAR patch not found: ${PATCH_FILE}"

    info "Applying TEAR patch:"
    info "  ${PATCH_FILE}"

    PATCH_SHA256="$(sha256sum "${PATCH_FILE}" | awk '{print $1}')"

    git -C "${DLSTREAMER_DIR}" apply --check "${PATCH_FILE}" ||
        fatal "The TEAR patch does not apply to ${RESOLVED_COMMIT}"

    run git -C "${DLSTREAMER_DIR}" apply \
        --whitespace=nowarn \
        "${PATCH_FILE}"

    PATCH_APPLIED="true"

    grep -q 'TEAR_POWER_SAVE_TRANSITION_FRAME = 300' \
        "${DLSTREAMER_DIR}/src/monolithic/gst/inference_elements/base/inference_impl.h" ||
        fatal "The patch does not configure the production transition at frame 300"

    grep -q 'GST_BASE_TRANSFORM_FLOW_DROPPED' \
        "${DLSTREAMER_DIR}/src/monolithic/gst/inference_elements/base/inference_impl.cpp" ||
        fatal "The patch does not drop skipped buffers"
else
    warn "TEAR patch application is disabled"
fi

DOCKER_CONTEXT="${DOCKER_CONTEXT:-${REPO_ROOT}}"

[[ -d "${DOCKER_CONTEXT}" ]] ||
    fatal "Docker build context does not exist: ${DOCKER_CONTEXT}"

# Use a stable OCI creation timestamp for reproducible builds and cache reuse.
# It changes only when the pinned DL Streamer commit changes.
IMAGE_CREATED_TIMESTAMP="$(
    git -C "${DLSTREAMER_DIR}" show \
        -s \
        --format=%cI \
        "${RESOLVED_COMMIT}"
)"

[[ -n "${IMAGE_CREATED_TIMESTAMP}" ]] ||
    fatal "Could not derive the image creation timestamp"

# Record the actual wrapper invocation time only in the external manifest.
# Do not pass this value to Docker because it would invalidate the build cache.
BUILD_RUN_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

info "AArch64 build configuration"
info "  DL Streamer:   ${DLSTREAMER_DIR}"
info "  Commit:        ${RESOLVED_COMMIT}"
info "  Dockerfile:    ${DOCKERFILE_PATH}"
info "  Context:       ${DOCKER_CONTEXT}"
info "  Platform:      ${TARGET_PLATFORM}"
info "  Image:         ${FULL_IMAGE_NAME}"
info "  Image created: ${IMAGE_CREATED_TIMESTAMP}"
info "  Patch applied: ${PATCH_APPLIED}"
info "  Clean build:   ${CLEAN}"
info "  Pull base:     ${PULL}"
info "  Load image:    ${LOAD_IMAGE}"
info "  Export OCI:    ${EXPORT_OCI}"
info "  Parallel jobs: ${BUILD_JOBS}"

COMMON_BUILD_ARGS=(
    --builder "${BUILDER_NAME}"
    --platform "${TARGET_PLATFORM}"
    --progress plain
    --file "${DOCKERFILE_PATH}"
    --tag "${FULL_IMAGE_NAME}"
    --build-arg "DLSTREAMER_COMMIT=${RESOLVED_COMMIT}"
    --build-arg "BUILD_TIMESTAMP=${IMAGE_CREATED_TIMESTAMP}"
    --build-arg "BUILD_JOBS=${BUILD_JOBS}"
)

if [[ "${CLEAN}" == "1" ]]; then
    COMMON_BUILD_ARGS+=(--no-cache)
fi

if [[ "${PULL}" == "1" ]]; then
    COMMON_BUILD_ARGS+=(--pull)
fi

BUILD_COMMAND=(
    docker buildx build
    "${COMMON_BUILD_ARGS[@]}"
)

if [[ "${LOAD_IMAGE}" == "1" ]]; then
    BUILD_COMMAND+=(--load)
fi

BUILD_COMMAND+=("${DOCKER_CONTEXT}")
run "${BUILD_COMMAND[@]}"

IMAGE_ARCHITECTURE="not-loaded"

if [[ "${LOAD_IMAGE}" == "1" ]]; then
    IMAGE_ARCHITECTURE="$(
        docker image inspect \
            --format '{{.Architecture}}' \
            "${FULL_IMAGE_NAME}"
    )"

    [[ "${IMAGE_ARCHITECTURE}" == "arm64" ]] ||
        fatal "Built image architecture is '${IMAGE_ARCHITECTURE}', expected arm64"

    info "Validating the AArch64 runtime image"

    run docker run \
        --rm \
        --platform "${TARGET_PLATFORM}" \
        "${FULL_IMAGE_NAME}" \
        bash -lc '
            set -Eeuo pipefail

            test "$(uname -m)" = "aarch64"

            plugin=/src/dlstreamer/build-aarch64/intel64/Release/lib/libgstvideoanalytics.so

            test -f "${plugin}"
            readelf -h "${plugin}" | grep -q "Machine:.*AArch64"
            grep -aqF "POWER_SAVE profile activated" "${plugin}"

            gst-launch-1.0 --version

            inspect_output="$(gst-inspect-1.0 gvadetect)"
            printf "%s\n" "${inspect_output}" | grep -E "Filename|Version"

            loaded_plugin="$(
                printf "%s\n" "${inspect_output}" |
                    sed -n \
                        "s/^[[:space:]]*Filename[[:space:]]*//p" |
                    head -1
            )"

            test "${loaded_plugin}" = "${plugin}"
        '
fi

OCI_ARCHIVE="${OUTPUT_DIR}/${IMAGE_NAME}-${IMAGE_TAG}.oci.tar"

if [[ "${EXPORT_OCI}" == "1" ]]; then
    info "Exporting OCI archive:"
    info "  ${OCI_ARCHIVE}"

    OCI_COMMAND=(
        docker buildx build
        "${COMMON_BUILD_ARGS[@]}"
        --output "type=oci,dest=${OCI_ARCHIVE}"
        "${DOCKER_CONTEXT}"
    )

    run "${OCI_COMMAND[@]}"
fi

MANIFEST_PATH="${OUTPUT_DIR}/build-manifest.txt"

cat >"${MANIFEST_PATH}" <<MANIFEST
image=${FULL_IMAGE_NAME}
platform=${TARGET_PLATFORM}
docker_image_architecture=${IMAGE_ARCHITECTURE}
dlstreamer_url=${DLSTREAMER_URL}
dlstreamer_ref=${DLSTREAMER_REF}
dlstreamer_commit=${RESOLVED_COMMIT}
dockerfile=${DOCKERFILE_PATH}
docker_context=${DOCKER_CONTEXT}
patch_file=${PATCH_FILE}
patch_enabled=${APPLY_PATCH}
patch_applied=${PATCH_APPLIED}
patch_sha256=${PATCH_SHA256}
image_created_timestamp=${IMAGE_CREATED_TIMESTAMP}
build_run_timestamp=${BUILD_RUN_TIMESTAMP}
clean_build=${CLEAN}
pull_base_image=${PULL}
build_jobs=${BUILD_JOBS}
load_image=${LOAD_IMAGE}
export_oci=${EXPORT_OCI}
oci_archive=${OCI_ARCHIVE}
MANIFEST

if [[ "${LOAD_IMAGE}" == "1" ]]; then
    docker image inspect "${FULL_IMAGE_NAME}" \
        >"${OUTPUT_DIR}/docker-image-inspect.json"
fi

printf '\n'
info "AArch64 build completed successfully"
info "Image:"
info "  ${FULL_IMAGE_NAME}"
info "Manifest:"
info "  ${MANIFEST_PATH}"

if [[ "${EXPORT_OCI}" == "1" ]]; then
    info "OCI archive:"
    info "  ${OCI_ARCHIVE}"
fi

if [[ "${LOAD_IMAGE}" == "1" ]]; then
    printf '\n'
    info "Open an AArch64 shell through QEMU user-mode emulation:"
    printf '\n'
    printf 'docker run --rm -it \\\n'
    printf '    --platform linux/arm64 \\\n'
    printf '    %q\n' "${FULL_IMAGE_NAME}"
fi
