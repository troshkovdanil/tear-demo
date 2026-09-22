#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WORK="$ROOT/work"
SERVER="$WORK/server"
CACHE="$SERVER/nix-cache"
DEVICE="$WORK/device-store"
RAUC_DATA="$WORK/rauc-data"
RAUC_REPO="$WORK/rauc-releases"
KEYS="$WORK/keys"
CONFIG="$WORK/config"

echo "=== host environment ==="

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "OS: ${PRETTY_NAME:-unknown}"
else
    echo "OS: unknown Linux"
fi

echo "Kernel: $(uname -srmo)"
echo

echo "=== check prerequisites ==="

missing=0

for cmd in nix nix-store openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd"
        missing=1
    else
        printf '%-10s %s\n' "$cmd:" "$(command -v "$cmd")"
    fi
done

if (( missing != 0 )); then
    cat <<'EOF'

Required tools are missing.

On Ubuntu, install Nix first.

After installing Nix, make sure your shell has the Nix environment loaded.
For a standard multi-user installation this is typically:

  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

You will also need OpenSSL:

  sudo apt update
  sudo apt install -y openssl

RAUC is required later by produce.sh / consume.sh, but setup.sh itself
does not need to execute RAUC.
EOF
    exit 1
fi

echo
echo "Nix version:"
nix --version

echo
echo "=== check Nix store ==="

if [[ ! -d /nix/store ]]; then
    cat <<'EOF'
ERROR: /nix/store does not exist.

This PoC expects a normal Linux Nix installation using /nix/store.
EOF
    exit 1
fi

echo "Nix store: /nix/store"

echo
echo "=== check flakes / nix-command ==="

if ! nix \
    --extra-experimental-features "nix-command flakes" \
    flake --help >/dev/null 2>&1
then
    cat <<'EOF'
ERROR: this Nix installation cannot use flakes.

The PoC requires:

  experimental-features = nix-command flakes

You can enable them permanently in ~/.config/nix/nix.conf:

  experimental-features = nix-command flakes

or in /etc/nix/nix.conf for a system-wide installation.
EOF
    exit 1
fi

# Use explicit features in this script as well. This makes the PoC work
# even when the user has not yet enabled them globally.
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}experimental-features = nix-command flakes"

echo "OK: nix-command + flakes available"

echo
echo "=== clean-state check ==="

if [[ -d "$WORK" ]]; then
    echo "ERROR:"
    echo "Previous PoC state exists:"
    echo "  $WORK"
    echo
    echo "Clean previous PoC state with:"
    echo "  sudo ./clean.sh"
    exit 1
fi

mkdir -p \
    "$CACHE" \
    "$RAUC_DATA" \
    "$RAUC_REPO" \
    "$KEYS" \
    "$CONFIG"

echo
echo "=== create flake ==="

cat > flake.nix <<'EOF'
{
  description = "RAUC-directed incremental Nix artifact update PoC";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      mkHelloRauc = version: runtimeInputs:
        pkgs.writeShellApplication {
          name = "hello-rauc";
          inherit runtimeInputs;

          text = ''
            echo "hello-rauc ${version}"
          '';
        };
    in
    {
      packages.${system} = {
        hello-rauc-v1 = mkHelloRauc "v1" [];

        # V2 deliberately adds jq so that the closure changes.
        hello-rauc-v2 = mkHelloRauc "v2" [
          pkgs.jq
        ];
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          rauc
          jq
          openssl
        ];
      };
    };
}
EOF

echo
echo "=== build applications ==="

#
# Use path: explicitly.
#
# This is important for two reasons:
#   1. the PoC works outside a Git repository;
#   2. newly generated/untracked flake.nix is included in the flake source.
#
nix build "path:$ROOT#hello-rauc-v1" --out-link result-v1
nix build "path:$ROOT#hello-rauc-v2" --out-link result-v2

APP_V1="$(readlink -f result-v1)"
APP_V2="$(readlink -f result-v2)"

printf '%s\n' "$APP_V1" > "$WORK/app-v1.path"
printf '%s\n' "$APP_V2" > "$WORK/app-v2.path"

echo "V1: $APP_V1"
echo "V2: $APP_V2"

echo
echo "=== execute applications ==="

"$APP_V1/bin/hello-rauc"
"$APP_V2/bin/hello-rauc"

echo
echo "=== closure difference ==="

nix-store -q --requisites "$APP_V1" | sort > "$WORK/v1.paths"
nix-store -q --requisites "$APP_V2" | sort > "$WORK/v2.paths"

echo "--- common ---"
comm -12 "$WORK/v1.paths" "$WORK/v2.paths"

echo
echo "--- new in V2 ---"
comm -13 "$WORK/v1.paths" "$WORK/v2.paths"

echo
echo "=== generate Nix binary-cache signing key ==="

nix key generate-secret \
    --key-name nix-rauc-lab-1 \
    > "$KEYS/nix-cache-secret.key"

chmod 600 "$KEYS/nix-cache-secret.key"

nix key convert-secret-to-public \
    < "$KEYS/nix-cache-secret.key" \
    > "$KEYS/nix-cache-public.key"

PUBKEY="$(cat "$KEYS/nix-cache-public.key")"

echo "Public key:"
echo "$PUBKEY"

echo
echo "=== sign application closures ==="

nix store sign \
    --key-file "$KEYS/nix-cache-secret.key" \
    --recursive \
    "$APP_V1"

nix store sign \
    --key-file "$KEYS/nix-cache-secret.key" \
    --recursive \
    "$APP_V2"

echo
echo "=== populate simulated server binary cache ==="

nix copy \
    --to "file://$CACHE" \
    "$APP_V1"

nix copy \
    --to "file://$CACHE" \
    "$APP_V2"

echo
echo "=== binary cache ==="

nix store info --store "file://$CACHE"

echo
echo "=== generate RAUC development certificate ==="

openssl req \
    -x509 \
    -newkey rsa:3072 \
    -nodes \
    -sha256 \
    -days 3650 \
    -keyout "$KEYS/rauc.key.pem" \
    -out "$KEYS/rauc.cert.pem" \
    -subj "/O=nix-rauc-lab/CN=nix-rauc-lab development"

chmod 600 "$KEYS/rauc.key.pem"

echo
echo "=== create simulated empty device store ==="

#
# This is deliberately NOT the host /nix/store.
#
# It represents the Nix store of our simulated target device. This lets us
# prove that V1 exists on the target before the update and that only the
# missing V2 closure paths are fetched later.
#
nix store info --store "$DEVICE"

echo
echo "=== install ONLY V1 into simulated device ==="

nix copy \
    -v \
    --from "file://$CACHE" \
    --to "$DEVICE" \
    --trusted-public-keys "$PUBKEY" \
    "$APP_V1"

echo
echo "=== verify device state ==="

echo "--- V1 ---"

nix path-info \
    --store "$DEVICE" \
    "$APP_V1"

echo
echo "--- V2 must NOT exist ---"

if nix path-info \
    --store "$DEVICE" \
    "$APP_V2" >/dev/null 2>&1
then
    echo "ERROR: V2 unexpectedly exists in device store"
    exit 1
else
    echo "OK: V2 is absent"
fi

echo
echo "=== locate Nix tools for RAUC hook ==="

NIX_BIN="$(command -v nix)"
NIX_STORE_BIN="$(command -v nix-store)"

echo "nix:       $NIX_BIN"
echo "nix-store: $NIX_STORE_BIN"

echo
echo "=== create updater ==="

cat > "$WORK/nix-artifact-updater" <<EOF
#!/usr/bin/env bash
set -euo pipefail

ROOT="$ROOT"
CACHE="$CACHE"
DEVICE="$DEVICE"
RELEASE_REPO="$RAUC_REPO"
PUBKEY='$PUBKEY'

NIX="$NIX_BIN"
NIX_STORE="$NIX_STORE_BIN"

export NIX_CONFIG="\${NIX_CONFIG:+\$NIX_CONFIG
}experimental-features = nix-command flakes"

METADATA="\$RELEASE_REPO/hello-rauc"

echo "[nix-artifact-updater] metadata: \$METADATA"

if [[ ! -e "\$METADATA" ]]; then
    echo "[nix-artifact-updater] ERROR: release metadata not found"
    exit 1
fi

DESIRED="\$(cat "\$METADATA")"

echo "[nix-artifact-updater] desired root: \$DESIRED"
echo "[nix-artifact-updater] cache: file://\$CACHE"
echo "[nix-artifact-updater] device store: \$DEVICE"

if [[ "\$DESIRED" != /nix/store/* ]]; then
    echo "[nix-artifact-updater] ERROR: invalid store path"
    exit 1
fi

echo
echo "[nix-artifact-updater] fetching missing closure paths..."

"\$NIX" copy \
    -v \
    --from "file://\$CACHE" \
    --to "\$DEVICE" \
    --trusted-public-keys "\$PUBKEY" \
    "\$DESIRED"

echo
echo "[nix-artifact-updater] verifying desired closure..."

mapfile -t CLOSURE < <(
    "\$NIX_STORE" \
        --store "\$DEVICE" \
        -q --requisites "\$DESIRED"
)

"\$NIX_STORE" \
    --store "\$DEVICE" \
    --verify-path \
    "\${CLOSURE[@]}"

echo
echo "[nix-artifact-updater] update complete"
EOF

chmod +x "$WORK/nix-artifact-updater"

echo
echo "=== create RAUC post-install handler ==="

cat > "$WORK/rauc-post-install" <<EOF
#!/usr/bin/env bash
set -euo pipefail

echo "[rauc-post-install] RAUC artifact installation completed"
echo "[rauc-post-install] triggering Nix artifact updater"

"$WORK/nix-artifact-updater"
EOF

chmod +x "$WORK/rauc-post-install"

echo
echo "=== create RAUC configuration ==="

cat > "$CONFIG/system.conf" <<EOF
[system]
compatible=nix-rauc-lab
bootloader=noop
data-directory=$RAUC_DATA

[keyring]
path=$KEYS/rauc.cert.pem

[handlers]
post-install=$WORK/rauc-post-install

[artifacts.nix-releases]
path=$RAUC_REPO
type=files
EOF

echo
echo "=== initial device paths ==="

find "$DEVICE/nix/store" \
    -mindepth 1 \
    -maxdepth 1 \
    -not -name '.links' \
    -printf '%f\n' |
    sort |
    tee "$WORK/device-before-update.paths"

echo
echo "=== SETUP COMPLETE ==="
echo
echo "V1 root:"
echo "$APP_V1"
echo
echo "V2 root:"
echo "$APP_V2"
echo
echo "Signed cache:"
echo "$CACHE"
echo
echo "Simulated device:"
echo "$DEVICE"
echo
echo "RAUC config:"
echo "$CONFIG/system.conf"
echo
echo "Next:"
echo "  nix develop \"path:$ROOT\""
echo "  ./produce.sh"

