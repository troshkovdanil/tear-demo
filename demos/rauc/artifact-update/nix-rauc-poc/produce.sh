#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WORK="$ROOT/work"
INPUT="$WORK/bundle-input"
BUNDLES="$WORK/server/bundles"
KEYS="$WORK/keys"

APP_V2_FILE="$WORK/app-v2.path"
RAUC_CERT="$KEYS/rauc.cert.pem"
RAUC_KEY="$KEYS/rauc.key.pem"
BUNDLE="$BUNDLES/hello-rauc-v2.raucb"

echo "=== RAUC release producer ==="
echo

echo "=== check prerequisites ==="

if ! command -v rauc >/dev/null 2>&1; then
    echo "ERROR: rauc not found"
    echo "Run:"
    echo "  ./install-prerequisites.sh"
    exit 1
fi

echo "rauc: $(command -v rauc)"
rauc --version

echo
echo "=== check setup state ==="

if [[ ! -f "$APP_V2_FILE" ]]; then
    echo "ERROR: V2 metadata not found:"
    echo "  $APP_V2_FILE"
    echo
    echo "Run:"
    echo "  ./setup.sh"
    exit 1
fi

if [[ ! -f "$RAUC_CERT" ]]; then
    echo "ERROR: RAUC certificate not found:"
    echo "  $RAUC_CERT"
    echo
    echo "Run:"
    echo "  ./setup.sh"
    exit 1
fi

if [[ ! -f "$RAUC_KEY" ]]; then
    echo "ERROR: RAUC private key not found:"
    echo "  $RAUC_KEY"
    echo
    echo "Run:"
    echo "  ./setup.sh"
    exit 1
fi

APP_V2="$(cat "$APP_V2_FILE")"

if [[ "$APP_V2" != /nix/store/* ]]; then
    echo "ERROR: invalid V2 Nix store path:"
    echo "  $APP_V2"
    exit 1
fi

echo "V2 desired root:"
echo "  $APP_V2"

echo
echo "=== prepare bundle input ==="

rm -rf "$INPUT"
mkdir -p "$INPUT" "$BUNDLES"

echo
echo "=== create release metadata ==="

#
# This is deliberately the only application-specific information
# carried by RAUC.
#
# RAUC does NOT carry the Nix application closure.
# It carries the signed release intent:
#
#     desired application root = /nix/store/...-hello-rauc
#
# The post-install updater will later resolve this root against the
# signed Nix binary cache.
#
printf '%s\n' "$APP_V2" > "$INPUT/hello-rauc.release"

echo "Release descriptor:"
cat "$INPUT/hello-rauc.release"

echo
echo "Descriptor size:"
du -h "$INPUT/hello-rauc.release"

echo
echo "=== add bundle padding ==="

#
# RAUC verity bundles need enough filesystem content to produce a
# usable bundle image. The padding is unrelated to the application.
#
dd \
    if=/dev/urandom \
    of="$INPUT/padding.bin" \
    bs=1024 \
    count=16 \
    status=none

echo "Padding:"
du -h "$INPUT/padding.bin"

echo
echo "=== create RAUC manifest ==="

cat > "$INPUT/manifest.raucm" <<'EOF'
[update]
compatible=nix-rauc-lab
version=2

[bundle]
format=verity

[image.nix-releases/hello-rauc]
filename=hello-rauc.release
EOF

cat "$INPUT/manifest.raucm"

echo
echo "=== build signed RAUC bundle ==="

rm -f "$BUNDLE"

rauc bundle \
    --cert="$RAUC_CERT" \
    --key="$RAUC_KEY" \
    "$INPUT" \
    "$BUNDLE"

if [[ ! -f "$BUNDLE" ]]; then
    echo "ERROR: RAUC bundle was not created"
    exit 1
fi

echo
echo "=== verify signed bundle ==="

rauc info \
    --keyring="$RAUC_CERT" \
    "$BUNDLE"

echo
echo "=== payload versus application ==="

printf "%-25s %s\n" \
    "Release descriptor:" \
    "$(du -h "$INPUT/hello-rauc.release" | cut -f1)"

printf "%-25s %s\n" \
    "RAUC bundle:" \
    "$(du -h "$BUNDLE" | cut -f1)"

echo
echo "=== verify server-side Nix closure ==="

CACHE="$WORK/server/nix-cache"

if [[ ! -d "$CACHE" ]]; then
    echo "ERROR: Nix binary cache does not exist:"
    echo "  $CACHE"
    exit 1
fi

if ! nix path-info \
    --store "file://$CACHE" \
    "$APP_V2" >/dev/null 2>&1
then
    echo "ERROR: V2 root is not available from binary cache:"
    echo "  $APP_V2"
    exit 1
fi

echo "OK: V2 root exists in signed binary cache"

echo
echo "=== PRODUCE COMPLETE ==="
echo
echo "RAUC bundle:"
echo "  $BUNDLE"
echo
echo "RAUC carries only this desired Nix root:"
echo "  $APP_V2"
echo
echo "The application closure remains in:"
echo "  $CACHE"

echo
echo "Architecture:"
echo
echo "  signed RAUC bundle"
echo "         |"
echo "         | release intent"
echo "         v"
echo "  $APP_V2"
echo "         |"
echo "         | resolve closure"
echo "         v"
echo "  signed Nix binary cache"
echo "         |"
echo "         | copy only missing paths"
echo "         v"
echo "  simulated device store"

echo
echo "Next:"
echo
echo "  Terminal 2:"
echo "    sudo rauc -c \"$WORK/config/system.conf\" \\"
echo "        service --override-boot-slot=_external_"
echo
echo "  Terminal 1:"
echo "    sudo ./consume.sh"
