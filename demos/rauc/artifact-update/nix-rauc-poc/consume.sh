#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG="$ROOT/work/config/system.conf"
BUNDLE="$ROOT/work/server/bundles/hello-rauc-v2.raucb"

echo "=== install RAUC metadata bundle ==="

sudo "$(which rauc)" \
    -c "$CONFIG" \
    install "$BUNDLE"

echo
echo "=== done ==="

