#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "This will remove everything in:"
echo "  $ROOT"
echo
echo "except:"
echo "  setup.sh"
echo "  produce.sh"
echo "  consume.sh"
echo "  clean.sh"
echo

read -r -p "Continue? [y/N] " answer

case "$answer" in
    y|Y|yes|YES)
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

rm -rf work
rm -f result-v1 result-v2 flake.nix flake.lock

echo "Clean."
