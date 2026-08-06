#!/usr/bin/env bash
#
# Fetch and build the OP-TEE QEMU v8 reference platform used by the TEAR demo.
#
# Default behavior:
#   - keep the existing OP-TEE checkout;
#   - reuse downloaded toolchains and previous build outputs;
#   - build in parallel;
#   - avoid re-running repo sync unless requested.
#
# Usage:
#   ./scripts/build-optee-qemu.sh [action] [options]
#
# Actions:
#   all          Fetch (if missing), install toolchains, and build (default).
#   prepare      Fetch (if missing) and install toolchains.
#   sync         Fetch if missing, then update all manifest projects.
#   build        Build the existing checkout.
#   clean        Run the OP-TEE build-system clean target.
#   distclean    Remove the complete OP-TEE QEMU checkout.
#
# Options:
#   --jobs N         Use N parallel jobs.
#   --sync           Run repo sync before prepare/build.
#   --clean-first    Run make clean before building.
#   --reset          Remove and fetch the complete checkout again.
#   -h, --help       Show this help.
#
# Environment-variable equivalents:
#   OPTEE_QEMU_DIR=/path/to/optee-qemu-v8
#   OPTEE_MANIFEST_URL=https://github.com/OP-TEE/manifest.git
#   OPTEE_MANIFEST_FILE=qemu_v8.xml
#   BUILD_JOBS=20
#   SYNC_SOURCE=1
#   CLEAN_FIRST=1
#   RESET_SOURCE=1
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

OPTEE_QEMU_DIR="${OPTEE_QEMU_DIR:-${REPO_ROOT}/third_party/optee-qemu-v8}"
OPTEE_MANIFEST_URL="${OPTEE_MANIFEST_URL:-https://github.com/OP-TEE/manifest.git}"
OPTEE_MANIFEST_FILE="${OPTEE_MANIFEST_FILE:-qemu_v8.xml}"

BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
SYNC_SOURCE="${SYNC_SOURCE:-0}"
CLEAN_FIRST="${CLEAN_FIRST:-0}"
RESET_SOURCE="${RESET_SOURCE:-0}"

ACTION="all"

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

require_positive_integer()
{
    local name="$1"
    local value="$2"

    [[ "${value}" =~ ^[1-9][0-9]*$ ]] ||
        fatal "${name} must be a positive integer, got: ${value}"
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

if (($# > 0)); then
    case "$1" in
        all | prepare | sync | build | clean | distclean)
            ACTION="$1"
            shift
            ;;
    esac
fi

while (($# > 0)); do
    case "$1" in
        --jobs)
            (($# >= 2)) || fatal "--jobs requires a value"
            BUILD_JOBS="$2"
            shift 2
            ;;
        --sync)
            SYNC_SOURCE=1
            shift
            ;;
        --clean-first)
            CLEAN_FIRST=1
            shift
            ;;
        --reset)
            RESET_SOURCE=1
            shift
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
done

(($# == 0)) || fatal "Unexpected positional arguments: $*"

require_positive_integer BUILD_JOBS "${BUILD_JOBS}"
require_boolean SYNC_SOURCE "${SYNC_SOURCE}"
require_boolean CLEAN_FIRST "${CLEAN_FIRST}"
require_boolean RESET_SOURCE "${RESET_SOURCE}"

command -v git >/dev/null 2>&1 || fatal "git was not found in PATH"
command -v make >/dev/null 2>&1 || fatal "make was not found in PATH"
command -v repo >/dev/null 2>&1 ||
    fatal "'repo' was not found in PATH; install the Android repo tool first"

fetch_optee_qemu()
{
    if [[ "${RESET_SOURCE}" == "1" && -e "${OPTEE_QEMU_DIR}" ]]; then
        info "Removing existing OP-TEE QEMU checkout"
        run rm -rf "${OPTEE_QEMU_DIR}"
    fi

    if [[ -d "${OPTEE_QEMU_DIR}/.repo" ]]; then
        info "Using existing OP-TEE QEMU checkout:"
        info "  ${OPTEE_QEMU_DIR}"
        return 0
    fi

    if [[ -e "${OPTEE_QEMU_DIR}" ]] &&
        [[ -n "$(find "${OPTEE_QEMU_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        fatal "Directory exists but is not a repo checkout: ${OPTEE_QEMU_DIR}"
    fi

    info "Initializing OP-TEE QEMU v8 manifest"
    run mkdir -p "${OPTEE_QEMU_DIR}"

    (
        cd "${OPTEE_QEMU_DIR}"

        run repo init \
            -u "${OPTEE_MANIFEST_URL}" \
            -m "${OPTEE_MANIFEST_FILE}" \
            < /dev/null

        run repo sync \
            -c \
            --no-clone-bundle \
            --fail-fast \
            -j "${BUILD_JOBS}"
    )
}

sync_optee_qemu()
{
    fetch_optee_qemu

    info "Synchronizing OP-TEE QEMU sources"

    (
        cd "${OPTEE_QEMU_DIR}"

        run repo sync \
            -c \
            --no-clone-bundle \
            --fail-fast \
            -j "${BUILD_JOBS}"
    )
}

validate_checkout()
{
    [[ -d "${OPTEE_QEMU_DIR}/.repo" ]] ||
        fatal "OP-TEE QEMU checkout is missing: ${OPTEE_QEMU_DIR}"

    [[ -d "${OPTEE_QEMU_DIR}/build" ]] ||
        fatal "OP-TEE build directory is missing: ${OPTEE_QEMU_DIR}/build"

    [[ -f "${OPTEE_QEMU_DIR}/build/Makefile" ]] ||
        fatal "OP-TEE build Makefile is missing"
}

prepare_optee_qemu()
{
    fetch_optee_qemu

    if [[ "${SYNC_SOURCE}" == "1" ]]; then
        sync_optee_qemu
    fi

    validate_checkout

    info "Installing or reusing OP-TEE toolchains"
    run make \
        -C "${OPTEE_QEMU_DIR}/build" \
        -j "${BUILD_JOBS}" \
        toolchains
}

clean_optee_qemu()
{
    validate_checkout

    info "Cleaning OP-TEE QEMU build outputs"
    run make \
        -C "${OPTEE_QEMU_DIR}/build" \
        -j "${BUILD_JOBS}" \
        clean
}

build_optee_qemu()
{
    validate_checkout

    if [[ "${CLEAN_FIRST}" == "1" ]]; then
        clean_optee_qemu
    fi

    info "Building OP-TEE QEMU with ${BUILD_JOBS} parallel jobs"
    run make \
        -C "${OPTEE_QEMU_DIR}/build" \
        -j "${BUILD_JOBS}" \
        all
}

print_summary()
{
    printf '\n'
    info "OP-TEE QEMU operation completed"
    info "  Action:        ${ACTION}"
    info "  Checkout:      ${OPTEE_QEMU_DIR}"
    info "  Manifest:      ${OPTEE_MANIFEST_FILE}"
    info "  Parallel jobs: ${BUILD_JOBS}"
}

case "${ACTION}" in
    prepare)
        prepare_optee_qemu
        ;;

    sync)
        sync_optee_qemu
        ;;

    build)
        if [[ "${SYNC_SOURCE}" == "1" ]]; then
            sync_optee_qemu
        fi
        build_optee_qemu
        ;;

    clean)
        clean_optee_qemu
        ;;

    distclean)
        if [[ -e "${OPTEE_QEMU_DIR}" ]]; then
            info "Removing complete OP-TEE QEMU checkout"
            run rm -rf "${OPTEE_QEMU_DIR}"
        else
            info "Nothing to remove: ${OPTEE_QEMU_DIR}"
        fi
        ;;

    all)
        prepare_optee_qemu
        build_optee_qemu
        ;;

    *)
        fatal "Unsupported action: ${ACTION}"
        ;;
esac

print_summary
