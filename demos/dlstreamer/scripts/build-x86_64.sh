#!/usr/bin/env bash
#
# Clone, patch, and build DL Streamer 2026.1 for x86-64.
#
# Usage:
#   ./scripts/build-x86_64.sh
#
# Clean Docker rebuild:
#   CLEAN=1 ./scripts/build-x86_64.sh
#
# Delete and re-clone source:
#   RESET_SOURCE=1 ./scripts/build-x86_64.sh
#
# Build without a TEAR patch:
#   APPLY_PATCH=0 ./scripts/build-x86_64.sh
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

THIRD_PARTY_DIR="${THIRD_PARTY_DIR:-${REPO_ROOT}/third_party}"
DLSTREAMER_DIR="${DLSTREAMER_DIR:-${THIRD_PARTY_DIR}/dlstreamer}"
PATCH_FILE="${PATCH_FILE:-${REPO_ROOT}/patches/dlstreamer-tear.patch}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/out/x86_64}"

DLSTREAMER_URL="${DLSTREAMER_URL:-https://github.com/open-edge-platform/dlstreamer.git}"

# Exact DL Streamer 2026.1 revision already resolved successfully.
DLSTREAMER_REF="${DLSTREAMER_REF:-728189a0c5e3d8ee386d9673d0bc50761c2259dc}"

IMAGE_NAME="${IMAGE_NAME:-tear-demo-dlstreamer}"
IMAGE_TAG="${IMAGE_TAG:-2026.1-x86_64}"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

DOCKER_TARGET="${DOCKER_TARGET:-dlstreamer}"

APPLY_PATCH="${APPLY_PATCH:-1}"
RESET_SOURCE="${RESET_SOURCE:-0}"
CLEAN="${CLEAN:-0}"

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

run()
{
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
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

install_buildx()
{
    if docker buildx version >/dev/null 2>&1; then
        return 0
    fi

    warn "Docker Buildx is not installed."
    info "Attempting to install docker-buildx-plugin"

    if ! command -v apt-get >/dev/null 2>&1; then
        fatal "Buildx is missing and apt-get is unavailable"
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        fatal "Buildx is missing and sudo is unavailable"
    fi

    run sudo apt-get update

    if sudo apt-get install -y docker-buildx-plugin; then
        :
    elif sudo apt-get install -y docker-buildx; then
        :
    else
        fatal "Could not install Docker Buildx"
    fi

    docker buildx version >/dev/null 2>&1 ||
        fatal "Buildx installation completed, but 'docker buildx' still does not work"
}

find_ubuntu_dockerfile()
{
    local candidate

    # Explicit override has priority.
    if [[ -n "${DOCKERFILE:-}" ]]; then
        printf '%s\n' "${DOCKERFILE}"
        return 0
    fi

    # Known and likely upstream locations.
    for candidate in \
        "${DLSTREAMER_DIR}/docker/ubuntu24/ubuntu24.Dockerfile" \
        "${DLSTREAMER_DIR}/docker/ubuntu24/Dockerfile" \
        "${DLSTREAMER_DIR}/docker/ubuntu24/Dockerfile.ubuntu24" \
        "${DLSTREAMER_DIR}/docker/ubuntu24.04/ubuntu24.04.Dockerfile" \
        "${DLSTREAMER_DIR}/docker/ubuntu24.04/Dockerfile" \
        "${DLSTREAMER_DIR}/docker/ubuntu/ubuntu24.Dockerfile" \
        "${DLSTREAMER_DIR}/docker/ubuntu/Dockerfile.ubuntu24"
    do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    # Flexible fallback, but still restricted to Ubuntu 24.
    find "${DLSTREAMER_DIR}/docker" \
        -type f \
        \( \
            -iname 'Dockerfile' \
            -o -iname '*.Dockerfile' \
            -o -iname 'Dockerfile.*' \
        \) \
        \( \
            -ipath '*ubuntu24*' \
            -o -ipath '*ubuntu-24*' \
            -o -ipath '*ubuntu_24*' \
        \) \
        2>/dev/null |
        sort |
        head -1
}

show_available_dockerfiles()
{
    warn "Dockerfiles available in this checkout:"

    find "${DLSTREAMER_DIR}/docker" \
        -type f \
        \( \
            -iname 'Dockerfile' \
            -o -iname '*.Dockerfile' \
            -o -iname 'Dockerfile.*' \
        \) \
        2>/dev/null |
        sort |
        sed 's/^/  /' >&2 || true
}

show_docker_stages()
{
    local dockerfile="$1"

    awk '
        BEGIN {
            IGNORECASE = 1
        }

        /^[[:space:]]*FROM[[:space:]]/ {
            for (i = 1; i <= NF; ++i) {
                if (toupper($i) == "AS" && i < NF) {
                    print $(i + 1)
                }
            }
        }
    ' "${dockerfile}"
}

command -v git >/dev/null 2>&1 ||
    fatal "git was not found in PATH"

command -v docker >/dev/null 2>&1 ||
    fatal "docker was not found in PATH"

command -v sha256sum >/dev/null 2>&1 ||
    fatal "sha256sum was not found in PATH"

docker info >/dev/null 2>&1 ||
    fatal "Docker daemon is not accessible"

case "$(uname -m)" in
    x86_64 | amd64)
        ;;
    *)
        fatal "This script builds only x86-64 images"
        ;;
esac

install_buildx

mkdir -p "${THIRD_PARTY_DIR}"
mkdir -p "${REPO_ROOT}/patches"
mkdir -p "${OUTPUT_DIR}"

###############################################################################
# Clone or reuse DL Streamer
###############################################################################

if [[ "${RESET_SOURCE}" == "1" && -e "${DLSTREAMER_DIR}" ]]; then
    info "Removing existing DL Streamer checkout"
    run rm -rf "${DLSTREAMER_DIR}"
fi

if [[ ! -d "${DLSTREAMER_DIR}/.git" ]]; then
    info "Cloning standalone DL Streamer repository"

    run git clone \
        --filter=blob:none \
        --no-checkout \
        "${DLSTREAMER_URL}" \
        "${DLSTREAMER_DIR}"
else
    info "Using existing DL Streamer checkout:"
    info "  ${DLSTREAMER_DIR}"
fi

###############################################################################
# Fetch and reset to pinned revision
###############################################################################

info "Fetching DL Streamer revision:"
info "  ${DLSTREAMER_REF}"

run git -C "${DLSTREAMER_DIR}" fetch \
    --force \
    --tags \
    origin

if ! git -C "${DLSTREAMER_DIR}" rev-parse \
    --verify "${DLSTREAMER_REF}^{commit}" >/dev/null 2>&1; then

    run git -C "${DLSTREAMER_DIR}" fetch \
        --force \
        origin \
        "${DLSTREAMER_REF}"
fi

RESOLVED_COMMIT="$(
    git -C "${DLSTREAMER_DIR}" rev-parse \
        "${DLSTREAMER_REF}^{commit}"
)"

info "Resolved commit:"
info "  ${RESOLVED_COMMIT}"

run git -C "${DLSTREAMER_DIR}" checkout \
    --force \
    --detach \
    "${RESOLVED_COMMIT}"

run git -C "${DLSTREAMER_DIR}" reset \
    --hard \
    "${RESOLVED_COMMIT}"

run git -C "${DLSTREAMER_DIR}" clean -ffdx

###############################################################################
# Required DL Streamer submodules only
###############################################################################

info "Updating DL Streamer submodules"

run git -C "${DLSTREAMER_DIR}" submodule sync --recursive

run git -C "${DLSTREAMER_DIR}" submodule update \
    --init \
    --recursive

###############################################################################
# Apply optional TEAR patch
###############################################################################

PATCH_APPLIED="false"
PATCH_SHA256="none"

if [[ "${APPLY_PATCH}" == "1" ]]; then
    if [[ -f "${PATCH_FILE}" ]]; then
        info "Applying TEAR patch:"
        info "  ${PATCH_FILE}"

        PATCH_SHA256="$(
            sha256sum "${PATCH_FILE}" |
                awk '{print $1}'
        )"

        if ! git -C "${DLSTREAMER_DIR}" apply \
            --check \
            "${PATCH_FILE}"; then

            fatal "The TEAR patch does not apply to DL Streamer ${RESOLVED_COMMIT}"
        fi

        run git -C "${DLSTREAMER_DIR}" apply \
            --whitespace=nowarn \
            "${PATCH_FILE}"

        PATCH_APPLIED="true"
    else
        warn "TEAR patch was not found:"
        warn "  ${PATCH_FILE}"
        warn "Building unmodified DL Streamer."
    fi
else
    info "TEAR patch application is disabled"
fi

###############################################################################
# Select Ubuntu 24 Dockerfile
###############################################################################

DOCKERFILE_PATH="$(find_ubuntu_dockerfile)"

if [[ -z "${DOCKERFILE_PATH}" || ! -f "${DOCKERFILE_PATH}" ]]; then
    show_available_dockerfiles
    fatal "Could not locate an Ubuntu 24 DL Streamer Dockerfile"
fi

DOCKER_CONTEXT="${DOCKER_CONTEXT:-${DLSTREAMER_DIR}}"

###############################################################################
# Validate requested build stage
###############################################################################

TARGET_ARGS=()

if [[ -n "${DOCKER_TARGET}" ]]; then
    if show_docker_stages "${DOCKERFILE_PATH}" |
        grep -Fxq "${DOCKER_TARGET}"; then

        TARGET_ARGS=(
            --target "${DOCKER_TARGET}"
        )
    else
        warn "Docker stage '${DOCKER_TARGET}' is not present."
        warn "Available stages:"

        show_docker_stages "${DOCKERFILE_PATH}" |
            sed 's/^/  /' >&2

        warn "Building the final Dockerfile stage instead."
    fi
fi

BUILD_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

info "Build configuration"
info "  Commit:        ${RESOLVED_COMMIT}"
info "  Dockerfile:    ${DOCKERFILE_PATH}"
info "  Context:       ${DOCKER_CONTEXT}"
info "  Target:        ${DOCKER_TARGET}"
info "  Image:         ${FULL_IMAGE_NAME}"
info "  Patch applied: ${PATCH_APPLIED}"

###############################################################################
# Create or select a Buildx builder
###############################################################################

BUILDER_NAME="${BUILDER_NAME:-tear-demo-builder}"

if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    info "Creating Docker Buildx builder: ${BUILDER_NAME}"

    run docker buildx create \
        --name "${BUILDER_NAME}" \
        --driver docker-container
fi

run docker buildx inspect \
    --builder "${BUILDER_NAME}" \
    --bootstrap

###############################################################################
# Build and load image into the normal local Docker image store
###############################################################################

BUILD_COMMAND=(
    docker buildx build
    --builder "${BUILDER_NAME}"
    --platform linux/amd64
    --progress plain
    --file "${DOCKERFILE_PATH}"
    --tag "${FULL_IMAGE_NAME}"
    --load
)

if (( ${#TARGET_ARGS[@]} > 0 )); then
    BUILD_COMMAND+=("${TARGET_ARGS[@]}")
fi

if [[ "${CLEAN}" == "1" ]]; then
    BUILD_COMMAND+=(
        --no-cache
        --pull
    )
fi

BUILD_COMMAND+=(
    "${DOCKER_CONTEXT}"
)

run "${BUILD_COMMAND[@]}"

###############################################################################
# Save build metadata
###############################################################################

MANIFEST_PATH="${OUTPUT_DIR}/build-manifest.txt"

cat >"${MANIFEST_PATH}" <<EOF
image=${FULL_IMAGE_NAME}
platform=linux/amd64
architecture=x86_64
dlstreamer_url=${DLSTREAMER_URL}
dlstreamer_ref=${DLSTREAMER_REF}
dlstreamer_commit=${RESOLVED_COMMIT}
dockerfile=${DOCKERFILE_PATH}
docker_context=${DOCKER_CONTEXT}
docker_target=${DOCKER_TARGET}
patch_file=${PATCH_FILE}
patch_enabled=${APPLY_PATCH}
patch_applied=${PATCH_APPLIED}
patch_sha256=${PATCH_SHA256}
build_timestamp=${BUILD_TIMESTAMP}
EOF

docker image inspect "${FULL_IMAGE_NAME}" \
    >"${OUTPUT_DIR}/docker-image-inspect.json"

printf '\n'
info "Build completed successfully"
info "Image:"
info "  ${FULL_IMAGE_NAME}"
info "Manifest:"
info "  ${MANIFEST_PATH}"

printf '\n'
info "Run it with:"
printf '\n'

printf 'docker run --rm -it \\\n'
printf '    --device /dev/dri:/dev/dri \\\n'
printf '    %q bash\n' "${FULL_IMAGE_NAME}"
