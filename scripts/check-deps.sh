#!/bin/bash
# Checks for the tools this repo's build, test, deploy, and provisioning
# workflows use, and with --install offers to install what's missing. Linux
# only. See docs/development.md#prerequisites.
#
# Usage:
#   scripts/check-deps.sh               # report; exit 1 if a core tool is missing
#   scripts/check-deps.sh --install     # also offer to install what's missing
#   scripts/check-deps.sh --install -y  # ...without asking
set -uo pipefail

INSTALL=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(uname -s)" != Linux ]; then
    echo "Development is supported on Linux only (this is $(uname -s))." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISSING_CORE=0
declare -A WANT_PKG=()

have() { command -v "$1" >/dev/null 2>&1; }
row()  { printf '  %-9s %-10s %s\n' "$1" "$2" "$3"; }

PM=""
if have apt-get; then PM=apt
elif have dnf; then PM=dnf
elif have pacman; then PM=pacman
elif have apk; then PM=apk
fi

# Package providing a tool, per package manager.
pkg_for() {
    case "$PM:$1" in
        *:lsblk|*:findmnt)  echo util-linux ;;
        *:dd|*:sha256sum)   echo coreutils ;;
        *:partprobe)        echo parted ;;
        apt:udevadm)        echo udev ;;
        dnf:udevadm)        echo systemd-udev ;;
        pacman:udevadm)     echo systemd ;;
        apk:udevadm)        echo eudev ;;
        apt:xz)             echo xz-utils ;;
        apt:ssh|apt:scp|apk:ssh|apk:scp) echo openssh-client ;;
        dnf:ssh|dnf:scp)    echo openssh-clients ;;
        pacman:ssh|pacman:scp) echo openssh ;;
        *)                  echo "$1" ;;
    esac
}

# check TOOL core|optional DESCRIPTION
check() {
    if have "$1"; then
        row ok "$1" "$3"
    elif [ "$2" = core ]; then
        row MISSING "$1" "$3"
        MISSING_CORE=1
        WANT_PKG[$(pkg_for "$1")]=1
    else
        row missing "$1" "$3"
        WANT_PKG[$(pkg_for "$1")]=1
    fi
}

echo "core — build, test, run locally"
GO_WANT="$(awk '/^go [0-9]/ {print $2}' "$REPO_ROOT/go.mod")"
if have go; then
    GO_HAVE="$(go env GOVERSION | sed 's/^go//')"
    if [ "$(printf '%s\n%s\n' "$GO_WANT" "$GO_HAVE" | sort -V | head -1)" = "$GO_WANT" ]; then
        row ok go "$GO_HAVE (go.mod needs $GO_WANT)"
    else
        row MISSING go "$GO_HAVE is older than go.mod's $GO_WANT — https://go.dev/dl/"
        MISSING_CORE=1
    fi
else
    row MISSING go "go.mod needs $GO_WANT — https://go.dev/dl/"
    MISSING_CORE=1
fi
if ! have docker; then
    row MISSING docker "https://docs.docker.com/engine/install/"
    MISSING_CORE=1
elif ! docker info >/dev/null 2>&1; then
    row MISSING docker "installed, but the daemon isn't running or your user can't reach it"
    MISSING_CORE=1
else
    row ok docker "daemon reachable"
fi
check git core "version stamping"

echo
echo "deploy — the portal to Kubernetes"
check helm optional "helm install / upgrade, make helm-lint"

echo
echo "provisioning — flashing Pi SD cards (provision-sd.sh --device)"
check xz optional ".img.xz images"
check zstd optional ".img.zst images"
check dd optional "writing the image"
check lsblk optional "device safety checks"
check findmnt optional "device safety checks"
check partprobe optional "re-reading the card's partition table"
check udevadm optional "waiting for the new partitions"

echo
echo "simulating a tap, and hw-tests"
check curl optional "talking to the portal and the Pi over HTTP"
check python3 optional "parsing JSON responses; building test fixtures"
check ssh optional "driving a test Pi"
check scp optional "copying to a test Pi"
check sha256sum optional "verifying transfers"

echo
PKGS="${!WANT_PKG[*]}"
if [ -n "$PKGS" ]; then
    if [ "$INSTALL" -eq 0 ]; then
        echo "Run 'make deps-install' to install the missing optional tools."
    elif [ -z "$PM" ]; then
        echo "No supported package manager found (apt, dnf, pacman, apk). Install by hand: $PKGS"
    else
        case "$PM" in
            apt)    CMD="sudo apt-get update && sudo apt-get install -y $PKGS" ;;
            dnf)    CMD="sudo dnf install -y $PKGS" ;;
            pacman) CMD="sudo pacman -S --needed --noconfirm $PKGS" ;;
            apk)    CMD="sudo apk add $PKGS" ;;
        esac
        echo "Will run: $CMD"
        REPLY=y
        [ "$ASSUME_YES" -eq 1 ] || read -r -p "Proceed? [y/N] " REPLY
        case "$REPLY" in
            y|Y|yes) eval "$CMD" ;;
            *) echo "Skipped." ;;
        esac
    fi
    echo "Go and Docker are never installed by this script; see the links above."
    echo
fi

if [ "$MISSING_CORE" -eq 1 ]; then
    echo "Core tools are missing; the build won't work until they're installed."
    exit 1
fi
echo "Core tools present."
