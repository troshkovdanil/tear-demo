#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)"

exec "${REPO_ROOT}/scripts/run-power-save-mock-host.sh"
