#!/usr/bin/env bash
set -euo pipefail

RAUC_VERSION="1.15.2"
RAUC_TAG="v${RAUC_VERSION}"
RAUC_SRC="/tmp/rauc-${RAUC_VERSION}"

echo "============================================"
echo " Nix + RAUC PoC prerequisite installer"
echo "============================================"
echo

# ----------------------------------------------------------------------
# Check host
# ----------------------------------------------------------------------

if [[ ! -r /etc/os-release ]]; then
    echo "ERROR: cannot detect Linux distribution"
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

echo "OS: ${PRETTY_NAME:-unknown}"

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "ERROR: this installer currently supports Ubuntu only"
    exit 1
fi

echo
echo "=== install Ubuntu packages ==="

sudo apt-get update

#
# Runtime tools + RAUC build dependencies.
#
# RAUC's documented build dependencies include:
#   build-essential
#   meson
#   libtool
#   libdbus-1-dev
#   libglib2.0-dev
#   libcurl*-dev
#   libssl-dev
#
sudo apt-get install -y \
    build-essential \
    meson \
    ninja-build \
    pkg-config \
    libtool \
    libdbus-1-dev \
    libglib2.0-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libnl-genl-3-dev \
    libjson-glib-dev \
    squashfs-tools \
    curl \
    ca-certificates \
    openssl \
    xz-utils \
    git \
    jq \
    dbus

# ----------------------------------------------------------------------
# Install Nix
# ----------------------------------------------------------------------

echo
echo "=== install Nix ==="

if [[ -x /nix/var/nix/profiles/default/bin/nix ]]; then
    echo "Nix already installed:"
    /nix/var/nix/profiles/default/bin/nix --version
else
    echo "Installing official Nix multi-user installation..."

    NIX_INSTALLER="/tmp/install-nix.sh"

    curl \
        --proto '=https' \
        --tlsv1.2 \
        -L \
        https://nixos.org/nix/install \
        -o "$NIX_INSTALLER"

    sh "$NIX_INSTALLER" --daemon

    rm -f "$NIX_INSTALLER"
fi

echo
echo "=== load Nix environment ==="

NIX_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"

if [[ ! -f "$NIX_PROFILE" ]]; then
    echo "ERROR: Nix profile script not found:"
    echo "  $NIX_PROFILE"
    exit 1
fi

# shellcheck disable=SC1090
. "$NIX_PROFILE"

echo
echo "=== configure nix-command + flakes ==="

sudo mkdir -p /etc/nix

NIX_CONF="/etc/nix/nix.conf"

if [[ ! -f "$NIX_CONF" ]]; then
    sudo touch "$NIX_CONF"
fi

if grep -Eq \
    '^[[:space:]]*experimental-features[[:space:]]*=.*nix-command.*flakes' \
    "$NIX_CONF"
then
    echo "nix-command + flakes already enabled"
else
    #
    # Do not blindly append a second experimental-features line if one
    # already exists.
    #
    if grep -Eq \
        '^[[:space:]]*experimental-features[[:space:]]*=' \
        "$NIX_CONF"
    then
        echo "Existing experimental-features configuration:"
        grep -E \
            '^[[:space:]]*experimental-features[[:space:]]*=' \
            "$NIX_CONF"

        echo
        echo "Adding nix-command/flakes using extra-experimental-features"

        echo \
            'extra-experimental-features = nix-command flakes' |
            sudo tee -a "$NIX_CONF" >/dev/null
    else
        echo \
            'experimental-features = nix-command flakes' |
            sudo tee -a "$NIX_CONF" >/dev/null
    fi
fi

sudo systemctl restart nix-daemon

echo
echo "=== verify Nix ==="

nix --version
nix-store --version

nix flake --help >/dev/null

echo "Nix flakes: OK"

# ----------------------------------------------------------------------
# Remove old manually-installed /usr/local RAUC if this script is rerun
# ----------------------------------------------------------------------

echo
echo "=== existing RAUC ==="

if command -v rauc >/dev/null 2>&1; then
    echo "Current command:"
    command -v rauc
    rauc --version || true
else
    echo "No RAUC currently visible in PATH"
fi

if [[ -x /usr/bin/rauc ]]; then
    echo
    echo "Ubuntu packaged RAUC:"
    /usr/bin/rauc --version || true
fi

# ----------------------------------------------------------------------
# Build RAUC 1.15.2
# ----------------------------------------------------------------------

echo
echo "=== download RAUC ${RAUC_VERSION} ==="

rm -rf "$RAUC_SRC"

git clone \
    --depth 1 \
    --branch "$RAUC_TAG" \
    https://github.com/rauc/rauc.git \
    "$RAUC_SRC"

cd "$RAUC_SRC"

echo
echo "RAUC source revision:"
git describe --tags --always

echo
echo "=== configure RAUC ${RAUC_VERSION} ==="

#
# /usr/local is intentional.
#
# Ubuntu's RAUC package can remain installed at:
#
#     /usr/bin/rauc
#
# while our newer PoC version becomes:
#
#     /usr/local/bin/rauc
#
# /usr/local/bin normally precedes /usr/bin in PATH.
#
meson setup build \
    --prefix=/usr/local \
    --buildtype=release

echo
echo "=== build RAUC ${RAUC_VERSION} ==="

meson compile -C build

echo
echo "=== verify RAUC before installation ==="

./build/rauc --version

BUILT_VERSION="$(./build/rauc --version)"

if [[ "$BUILT_VERSION" != *"$RAUC_VERSION"* ]]; then
    echo "ERROR: unexpected RAUC build:"
    echo "  $BUILT_VERSION"
    exit 1
fi

echo
echo "=== install RAUC ${RAUC_VERSION} ==="

sudo meson install -C build

#
# Refresh shell command lookup. This matters if bash previously cached
# /usr/bin/rauc.
#
hash -r

echo
echo "=== verify installed RAUC ==="

if [[ ! -x /usr/local/bin/rauc ]]; then
    echo "ERROR: expected RAUC binary not found:"
    echo "  /usr/local/bin/rauc"
    exit 1
fi

/usr/local/bin/rauc --version

INSTALLED_VERSION="$(/usr/local/bin/rauc --version)"

if [[ "$INSTALLED_VERSION" != *"$RAUC_VERSION"* ]]; then
    echo "ERROR: wrong RAUC version installed:"
    echo "  $INSTALLED_VERSION"
    exit 1
fi

echo
echo "=== verify command resolution ==="

echo "PATH:"
echo "$PATH" | tr ':' '\n'

echo
echo "rauc resolves to:"
command -v rauc

echo
echo "Default rauc:"
rauc --version

if [[ "$(command -v rauc)" != "/usr/local/bin/rauc" ]]; then
    echo
    echo "WARNING:"
    echo "Your shell does not resolve rauc to /usr/local/bin/rauc."
    echo
    echo "For this PoC use:"
    echo "  /usr/local/bin/rauc"
fi

echo
echo "=== installed RAUC versions ==="

if [[ -x /usr/local/bin/rauc ]]; then
    printf "%-25s " "/usr/local/bin/rauc"
    /usr/local/bin/rauc --version
fi

if [[ -x /usr/bin/rauc ]]; then
    printf "%-25s " "/usr/bin/rauc"
    /usr/bin/rauc --version
fi

# ----------------------------------------------------------------------
# Verify D-Bus
# ----------------------------------------------------------------------

echo
echo "=== verify D-Bus ==="

if command -v dbus-daemon >/dev/null 2>&1; then
    echo "dbus-daemon: $(command -v dbus-daemon)"
else
    echo "ERROR: dbus-daemon not found"
    exit 1
fi

# ----------------------------------------------------------------------
# Final result
# ----------------------------------------------------------------------

echo
echo "============================================"
echo " PREREQUISITES INSTALLED SUCCESSFULLY"
echo "============================================"
echo

echo "Nix:"
nix --version

echo
echo "RAUC used by this PoC:"
/usr/local/bin/rauc --version

echo
echo "RAUC binary:"
echo "  /usr/local/bin/rauc"

echo
echo "Ubuntu packaged RAUC, if present:"
if [[ -x /usr/bin/rauc ]]; then
    /usr/bin/rauc --version
else
    echo "  not installed"
fi

echo
echo "IMPORTANT:"
echo
echo "If Nix was installed during this run, open a new terminal"
echo "before continuing, or execute:"
echo
echo "  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
echo
echo "Then verify:"
echo
echo "  nix --version"
echo "  rauc --version"
echo "  command -v rauc"
echo
echo "Expected RAUC:"
echo "  /usr/local/bin/rauc"
echo "  rauc ${RAUC_VERSION}"
echo
