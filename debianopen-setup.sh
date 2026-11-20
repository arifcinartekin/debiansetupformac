#!/bin/bash
#
# debianopen-setup.sh - Debian Setup for Mac
#
# Installs Debian 12 (bookworm, arm64) on macOS (Apple Silicon) with QEMU and
# adds four terminal commands: `debianopen`, `debianclose`, `debianuninstall`
# and `debianseal`. One command, fully automatic:
#
#   1. Homebrew + qemu + gnupg (installed if missing)
#   2. Asks for the disk passphrase, downloads the Alpine ISO and the pinned
#      Debian netinst ISO and verifies them (sha256 + GPG)
#   3. Drives a temporary Alpine VM over the serial console to prepare the disk:
#      ESP (FAT32) + root (LUKS2 + btrfs subvolumes), debootstrap installs the
#      Debian base system from the ISO, and inside a chroot it sets up apt /
#      apt full-upgrade / kernel / initramfs with LUKS / systemd-boot / fstab /
#      hostname / network / terminfo / first-boot wizard
#   4. Generates start-uefi.sh, seals the VM files (debianseal), boots the new
#      system via UEFI, unlocks the disk, logs in and checks it
#   5. Adds the debianopen / debianclose / debianuninstall / debianseal aliases to ~/.zshrc
#
# Every `debianopen` first checks the VM files against the seal kept in the
# macOS Keychain and refuses to boot if one of them changed. Then it asks for
# the disk passphrase. Root is locked from the start: log in as `user`
# (password: user, changed at the first login); sudo needs no password on the
# serial console. The first-boot wizard then offers zsh, tools and ly.
#
# Usage:
#   bash debianopen-setup.sh
#   bash <(curl -fsSL https://debian.arifcinartekin.me/install)
#
# Environment variables (all optional):
#   DEBIANOPEN_DIR=~/vm/debian    Install directory
#   DEBIANOPEN_HOSTNAME=debian    Hostname inside Debian
#   DEBIANOPEN_FORCE=1            Overwrite a completed install
#   DEBIANOPEN_YES=1              Do not ask for confirmation
#   DEBIANOPEN_PIN_BREW=1         brew pin qemu gnupg (keep brew upgrade away from them)
#   DEBIANOPEN_CPUS=4  DEBIANOPEN_MEM=4G  DEBIANOPEN_ROOT_SIZE=20G  DEBIANOPEN_ESP_SIZE=1G
#   DEBIANOPEN_USER=user          Your account inside Debian (sudo)
#   DEBIANOPEN_SSH_PORT=2224      Mac port for SSH (127.0.0.1 only)
#   DEBIANOPEN_LUKS_PASSPHRASE=...  Disk passphrase (otherwise asked for; needed with DEBIANOPEN_YES=1 without a terminal)
#   DEBIANOPEN_REPO=owner/name  DEBIANOPEN_REF=main   Where companion files are fetched from
#   DEBIANOPEN_ALPINE_MIRROR_URL=...   Where the Alpine ISO is fetched from first (default: this repo's GitHub release)
#   DEBIANOPEN_DEBIAN_MIRROR_URL=...   Where the Debian ISO is fetched from first (default: this repo's GitHub release)
#   DEBIANOPEN_APT_MIRROR=http://deb.debian.org   Debian package mirror used inside the VM
#   DEBIANOPEN_BRIDGE=0           No bridged network (NAT only; default: bridged through socket_vmnet)
#   DEBIANOPEN_BRIDGE_IF=en0      Mac interface to bridge (default: the one with the default route)
#
# For testing (non-macOS / no HVF): DEBIANOPEN_ALLOW_NON_MAC=1 DEBIANOPEN_ACCEL=tcg
#   DEBIANOPEN_CPU=cortex-a72 DEBIANOPEN_FW_CODE=... DEBIANOPEN_FW_VARS=...
#
set -euo pipefail

###############################################################################
# VERSION PINS
###############################################################################
DEBIANOPEN_REPO="${DEBIANOPEN_REPO:-arifcinartekin/debiansetupformac}"
DEBIANOPEN_REF="${DEBIANOPEN_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${DEBIANOPEN_REPO}/${DEBIANOPEN_REF}"

ALPINE_VERSION="3.24.3"
ALPINE_SERIES="v${ALPINE_VERSION%.*}"
ALPINE_ISO="alpine-virt-${ALPINE_VERSION}-aarch64.iso"
ALPINE_ISO_SHA256="e34603080e942e9ebc670689eee77dd7a6551c823a6ff5a299e308ded268098f"
# The ISO is mirrored unchanged (with its upstream .sha256, .asc and the signing
# key) as a GitHub release of this repo and fetched from there first; Alpine's
# own servers are the fallback. The sha256 pin and the GPG signature by the
# pinned fingerprint are what is trusted, wherever the files come from.
ALPINE_RELEASE_TAG="alpine-${ALPINE_VERSION}"
ALPINE_MIRROR_URL="${DEBIANOPEN_ALPINE_MIRROR_URL:-https://github.com/${DEBIANOPEN_REPO}/releases/download/${ALPINE_RELEASE_TAG}}"
ALPINE_BASE_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/releases/aarch64"
ALPINE_KEY_URL="https://alpinelinux.org/keys/ncopa.asc"
ALPINE_KEY_FPR="0482D84022F52DF1C4E7CD43293ACD0907D9495A"

# The Debian netinst ISO carries the base system debootstrap installs. It is
# mirrored unchanged (with the upstream SHA256SUMS, SHA256SUMS.sign and the
# Debian CD signing key) as a GitHub release of this repo and fetched from
# there first; cdimage.debian.org is the fallback. tools/publish-iso.sh
# updates these lines.
DEBIAN_VERSION="12.15.0"
DEBIAN_SUITE="bookworm"
DEBIAN_ISO="debian-${DEBIAN_VERSION}-arm64-netinst.iso"
DEBIAN_ISO_SHA256="2ff1c33f31bbfae04251267d9fd1cb098c055f7cf39d9943b0cf8d5e73a17eba"
DEBIAN_RELEASE_TAG="debian-${DEBIAN_VERSION}"
DEBIAN_MIRROR_URL="${DEBIANOPEN_DEBIAN_MIRROR_URL:-https://github.com/${DEBIANOPEN_REPO}/releases/download/${DEBIAN_RELEASE_TAG}}"
DEBIAN_BASE_URLS="https://cdimage.debian.org/cdimage/archive/${DEBIAN_VERSION}/arm64/iso-cd
https://cdimage.debian.org/cdimage/release/${DEBIAN_VERSION}/arm64/iso-cd"
DEBIAN_KEY_FPR="DF9B9C49EAA9298432589D76DA87E80D6294BE9B"
APT_MIRROR="${DEBIANOPEN_APT_MIRROR:-http://deb.debian.org}"

# Password of the user until the first login, which asks for a new one.
# root never gets a password: it is locked from the install on
TEMP_USER_PASSWORD="user"

###############################################################################
# SETTINGS
###############################################################################
INSTALL_DIR="${DEBIANOPEN_DIR:-$HOME/vm/debian}"
DEB_HOSTNAME="${DEBIANOPEN_HOSTNAME:-debian}"
CPUS="${DEBIANOPEN_CPUS:-4}"
MEM="${DEBIANOPEN_MEM:-4G}"
ROOT_SIZE="${DEBIANOPEN_ROOT_SIZE:-20G}"
ESP_SIZE="${DEBIANOPEN_ESP_SIZE:-1G}"
DEB_USER="${DEBIANOPEN_USER:-user}"
# 2222 is Arch Setup for Mac's, 2223 FreeBSD's: all three VMs can run at the same time
SSH_PORT="${DEBIANOPEN_SSH_PORT:-2224}"
# Bridged network: the VM gets its own address from your router, through
# socket_vmnet (a small root service; QEMU itself stays unprivileged). The
# same service serves Arch Setup for Mac and BSD Setup for Mac too
BRIDGE="${DEBIANOPEN_BRIDGE:-1}"
BRIDGE_IF="${DEBIANOPEN_BRIDGE_IF:-}"
VMNET_DIR="/opt/socket_vmnet"
ACCEL="${DEBIANOPEN_ACCEL:-hvf}"
CPU_MODEL="${DEBIANOPEN_CPU:-host}"

DL_DIR="$INSTALL_DIR/downloads"
LOG_FILE="$INSTALL_DIR/install.log"
INCOMPLETE_MARK="$INSTALL_DIR/.debianopen-incomplete"
MANIFEST="$INSTALL_DIR/.debianopen-manifest"

# Directory of this script when run from a checkout (empty under bash <(curl ...))
SCRIPT_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

WORK=""
HTTP_PID=""
IS_MAC=0
FW_CODE=""
FW_VARS=""
QEMU_BIN=""
DEBIAN_ISO_SIZE=""
MAC_LAN=""
MAC_LOCAL=""
HAS_TERMINFO=0
LUKS_PW=""
BREW_INSTALLED_BY_US=0
FORMULAE_INSTALLED_BY_US=""

###############################################################################
# HELPERS
###############################################################################
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

size_of_file() {
  if [ "$(uname -s)" = Darwin ]; then stat -f %z "$1"; else stat -c %s "$1"; fi
}

fetch() { # url file
  curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 20 -o "$2" "$1"
}

fetch_big() { # url file  (resumable, with progress bar)
  curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 -C - --progress-bar -o "$2" "$1"
}

# Copies a file of this repo from the local checkout, or downloads it from GitHub
repo_file() { # repo-path destination
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$1" ]; then
    cp "$SCRIPT_DIR/$1" "$2"
  else
    fetch "$RAW_BASE/$1" "$2" || die "Could not download $1 from $RAW_BASE"
  fi
}

###############################################################################
# GPG VERIFICATION (temporary keyring; fingerprints are pinned in this script)
###############################################################################
# gpg_verify_sig <key-file> <signature> <file> <expected-fingerprint>
gpg_verify_sig() {
  local keyfile="$1" sigfile="$2" datafile="$3" fpr="$4"
  local gh status
  gh="$(mktemp -d /tmp/debianopen-gpg.XXXXXX)"
  chmod 700 "$gh"
  if ! GNUPGHOME="$gh" gpg --batch --no-tty --quiet --import "$keyfile" >/dev/null 2>&1; then
    rm -rf "$gh"
    return 2
  fi
  status="$(GNUPGHOME="$gh" gpg --batch --no-tty --status-fd 1 --verify "$sigfile" "$datafile" 2>/dev/null || true)"
  GNUPGHOME="$gh" gpgconf --kill all >/dev/null 2>&1 || true
  rm -rf "$gh"
  if printf '%s\n' "$status" | awk -v f="$fpr" '
        $2 == "BADSIG" || $2 == "ERRSIG" || $2 == "REVKEYSIG" { bad = 1 }
        $2 == "VALIDSIG" && ($3 == f || $NF == f) { good = 1 }
        END { exit (good && !bad) ? 0 : 1 }'; then
    return 0
  fi
  return 1
}

# Checks that a key file contains the expected fingerprint
key_has_fpr() { # file fpr
  local gh out rc=1
  gh="$(mktemp -d /tmp/debianopen-gpg.XXXXXX)"
  chmod 700 "$gh"
  out="$(GNUPGHOME="$gh" gpg --batch --no-tty --show-keys --with-colons "$1" 2>/dev/null || true)"
  GNUPGHOME="$gh" gpgconf --kill all >/dev/null 2>&1 || true
  rm -rf "$gh"
  if printf '%s\n' "$out" | awk -F: -v f="$2" '$1 == "fpr" && $10 == f { found = 1 } END { exit found ? 0 : 1 }'; then
    rc=0
  fi
  return "$rc"
}

fetch_debian_key() { # output-file
  local out="$1" url
  if [ -n "${DEBIANOPEN_DEBIAN_KEY_FILE:-}" ]; then
    cp "$DEBIANOPEN_DEBIAN_KEY_FILE" "$out"
    key_has_fpr "$out" "$DEBIAN_KEY_FPR" && return 0
    return 1
  fi
  for url in \
    "https://keyring.debian.org/pks/lookup?op=get&search=0x${DEBIAN_KEY_FPR}" \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${DEBIAN_KEY_FPR}" \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/${DEBIAN_KEY_FPR}" \
    "${DEBIAN_MIRROR_URL}/debian-cd-signing-key.asc"; do
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "$out" "$url" 2>/dev/null && key_has_fpr "$out" "$DEBIAN_KEY_FPR"; then
      return 0
    fi
  done
  return 1
}

###############################################################################
# 0) PRE-FLIGHT CHECKS, DEPENDENCIES
###############################################################################
check_platform() {
  if [ "$(uname -s)" = "Darwin" ]; then
    IS_MAC=1
    [ "$(uname -m)" = "arm64" ] || die "This script is for Apple Silicon (arm64) Macs."
    [ "$(id -u)" -ne 0 ] || die "Do not run this script as root (Homebrew does not allow it)."
  else
    [ "${DEBIANOPEN_ALLOW_NON_MAC:-0}" = "1" ] || die "This script is for macOS. (For testing: DEBIANOPEN_ALLOW_NON_MAC=1)"
  fi
  printf '%s' "$DEB_HOSTNAME" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || die "Invalid hostname: $DEB_HOSTNAME"
  printf '%s' "$DEB_USER" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "Invalid user name: $DEB_USER"
  case "$DEB_USER" in
    root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|nobody|messagebus|sshd|_apt|systemd-*)
      die "Pick a user name other than $DEB_USER (DEBIANOPEN_USER)." ;;
  esac
  case "$SSH_PORT" in ''|*[!0-9]*) die "Invalid port: $SSH_PORT" ;; esac
  [ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ] || die "Port out of range (1024-65535): $SSH_PORT"
}

ensure_deps() {
  if [ "$IS_MAC" = "1" ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      warn "Xcode Command Line Tools are missing, opening the installer."
      xcode-select --install || true
      die "Run this script again once that installation has finished."
    fi

    local brew_bin=""
    if command -v brew >/dev/null 2>&1; then
      brew_bin="$(command -v brew)"
    elif [ -x /opt/homebrew/bin/brew ]; then
      brew_bin="/opt/homebrew/bin/brew"
    fi
    if [ -z "$brew_bin" ]; then
      log "Installing Homebrew (may ask for your Mac password)"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      brew_bin="/opt/homebrew/bin/brew"
      [ -x "$brew_bin" ] || die "Homebrew installation failed."
      BREW_INSTALLED_BY_US=1
    fi
    eval "$("$brew_bin" shellenv)"

    local pkg
    for pkg in qemu gnupg; do
      if ! brew list --versions "$pkg" >/dev/null 2>&1; then
        log "brew install $pkg"
        brew install "$pkg"
        FORMULAE_INSTALLED_BY_US="${FORMULAE_INSTALLED_BY_US:+$FORMULAE_INSTALLED_BY_US }$pkg"
      fi
    done
    if [ "${DEBIANOPEN_PIN_BREW:-0}" = "1" ]; then
      brew pin qemu gnupg || warn "brew pin failed (not critical)."
    fi
  fi

  local t
  for t in curl python3 expect qemu-system-aarch64 qemu-img gpg gpgconf base64 awk uuidgen; do
    command -v "$t" >/dev/null 2>&1 || die "Missing tool: $t"
  done
  QEMU_BIN="$(command -v qemu-system-aarch64)"
}

find_firmware() {
  if [ -n "${DEBIANOPEN_FW_CODE:-}" ]; then
    FW_CODE="$DEBIANOPEN_FW_CODE"
    FW_VARS="${DEBIANOPEN_FW_VARS:?DEBIANOPEN_FW_VARS must be set as well}"
  else
    local prefix share=""
    prefix=""
    if command -v brew >/dev/null 2>&1; then
      prefix="$(brew --prefix 2>/dev/null || true)"
    fi
    local cand
    for cand in "$prefix/share/qemu" /opt/homebrew/share/qemu /usr/local/share/qemu /usr/share/qemu; do
      if [ -f "$cand/edk2-aarch64-code.fd" ] && [ -f "$cand/edk2-arm-vars.fd" ]; then
        share="$cand"
        break
      fi
    done
    [ -n "$share" ] || die "QEMU UEFI firmware files (edk2-aarch64-code.fd) not found."
    FW_CODE="$share/edk2-aarch64-code.fd"
    FW_VARS="$share/edk2-arm-vars.fd"
  fi
  if [ ! -f "$FW_CODE" ] || [ ! -f "$FW_VARS" ]; then
    die "Firmware files missing: $FW_CODE / $FW_VARS"
  fi
}

confirm_plan() {
  cat <<EOF

  Install directory : $INSTALL_DIR
  Virtual machine   : ${CPUS} CPUs, ${MEM} RAM, ${ROOT_SIZE} root disk, ${ESP_SIZE} ESP
  Root disk         : LUKS2 encrypted, btrfs (subvolumes @, @home, @log, @pkg)
  Integrity seal    : VM files checked before every boot, seal in the macOS Keychain
  Hostname          : ${DEB_HOSTNAME}
  Account           : ${DEB_USER} (sudo, no password on the serial console); root locked
  Network           : $([ "$BRIDGE" = 1 ] && echo "bridged (address from your router, socket_vmnet: asks for your Mac password once) + " || true)SSH on 127.0.0.1:${SSH_PORT}
  Alpine            : ${ALPINE_VERSION} (verified with sha256 + GPG)
  Debian            : ${DEBIAN_VERSION} (${DEBIAN_SUITE}), ${DEBIAN_ISO} (verified with pinned sha256 + GPG)
  Will change       : brew packages (qemu, gnupg),
                      ~/.zshrc (debianopen, debianclose, debianuninstall, debianseal aliases),
                      login Keychain (one item: debianopen-seal)

EOF
  if [ "${DEBIANOPEN_YES:-0}" = "1" ]; then
    return 0
  fi
  [ -r /dev/tty ] || return 0
  local ans
  printf 'Continue? [Y/n] ' >/dev/tty
  IFS= read -r ans </dev/tty || ans="n"
  case "$ans" in
    ""|y|Y|yes|Yes) return 0 ;;
    *) die "Cancelled." ;;
  esac
}

# The LUKS passphrase never touches the disk or the log: the installer types it
# into the Alpine VM over the serial console with echo off
ask_passphrase() {
  if [ -n "${DEBIANOPEN_LUKS_PASSPHRASE:-}" ]; then
    LUKS_PW="$DEBIANOPEN_LUKS_PASSPHRASE"
    # Not passed on to QEMU and the other tools started from here
    unset DEBIANOPEN_LUKS_PASSPHRASE
  else
    [ -r /dev/tty ] || die "No terminal to ask for the disk passphrase on: set DEBIANOPEN_LUKS_PASSPHRASE."
    local again
    cat >/dev/tty <<'EOF'
  The Debian disk is encrypted with LUKS2. You type this passphrase at every boot.
  There is no way to recover the data without it.

EOF
    while :; do
      printf 'Disk passphrase: ' >/dev/tty
      IFS= read -rs LUKS_PW </dev/tty || die "Cancelled."
      printf '\nRepeat passphrase: ' >/dev/tty
      IFS= read -rs again </dev/tty || die "Cancelled."
      printf '\n' >/dev/tty
      if [ "$LUKS_PW" != "$again" ]; then
        echo "  The passphrases do not match, try again." >/dev/tty
      elif [ "${#LUKS_PW}" -lt 8 ]; then
        echo "  Use at least 8 characters." >/dev/tty
      else
        break
      fi
    done
  fi
  # Control characters would be interpreted by the serial console instead of typed
  case "$LUKS_PW" in
    *[[:cntrl:]]*) die "The disk passphrase must not contain control characters." ;;
  esac
  [ -n "$LUKS_PW" ] || die "The disk passphrase is empty."
}

check_existing() {
  if [ -e "$INSTALL_DIR/disk.qcow2" ] && [ ! -e "$INCOMPLETE_MARK" ] && [ "${DEBIANOPEN_FORCE:-0}" != "1" ]; then
    die "There is already an install in $INSTALL_DIR. Stopping so it is not overwritten.
      Other directory: DEBIANOPEN_DIR=~/vm/debian2 bash debianopen-setup.sh
      Overwrite      : DEBIANOPEN_FORCE=1 bash debianopen-setup.sh
      Remove it      : debianuninstall"
  fi
}

prepare_dirs() {
  mkdir -p "$DL_DIR"
  : > "$INCOMPLETE_MARK"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/debianopen.XXXXXX")"
  chmod 700 "$WORK"
  # Fixed per install, so the router hands the VM the same address every boot
  MAC_LAN="$(random_mac)"
  MAC_LOCAL="$(random_mac)"
  printf '%s %s' "$MAC_LAN" "$MAC_LOCAL" | grep -Eq '^52:54:00(:[0-9a-f]{2}){3} 52:54:00(:[0-9a-f]{2}){3}$' \
    || die "Could not generate MAC addresses ($MAC_LAN, $MAC_LOCAL)"
}

random_mac() { # 52:54:00:xx:xx:xx (QEMU's locally administered prefix)
  # od may spread its output over several lines: join it before splitting
  printf '52:54:00%s\n' "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | sed 's/../:&/g')"
}

###############################################################################
# BRIDGED NETWORK (socket_vmnet)
###############################################################################
# vmnet's bridged mode needs root, and Homebrew's QEMU does not carry Apple's
# entitlement for it. socket_vmnet (from the Lima project) runs as a root
# launchd service and hands an unprivileged QEMU a bridged network card.
# Installed the way Lima recommends: binaries copied to /opt/socket_vmnet,
# owned by root, so the service never runs a file your user could replace.
# The service and its socket are shared by Arch, BSD and Debian Setup for Mac.
vmnet_socket() { printf '/private/var/run/socket_vmnet.bridged.%s' "$1"; }
vmnet_label() { printf 'io.github.lima-vm.socket_vmnet.bridged.%s' "$1"; }

setup_bridge() {
  if [ "$BRIDGE" != 1 ] || [ "$IS_MAC" != 1 ]; then
    BRIDGE_IF=""
    return 0
  fi
  [ -n "$BRIDGE_IF" ] || BRIDGE_IF="$(route -n get default 2>/dev/null | awk '$1 == "interface:" { print $2; exit }')"
  if ! printf '%s' "$BRIDGE_IF" | grep -Eq '^[a-z]+[0-9]+$'; then
    warn "No network interface to bridge (DEBIANOPEN_BRIDGE_IF=en0 picks one); NAT only"
    BRIDGE_IF=""
    return 0
  fi
  local sock label plist src
  sock="$(vmnet_socket "$BRIDGE_IF")"
  label="$(vmnet_label "$BRIDGE_IF")"
  plist="/Library/LaunchDaemons/$label.plist"
  if [ -S "$sock" ] && [ -x "$VMNET_DIR/bin/socket_vmnet_client" ]; then
    ok "Bridged network on $BRIDGE_IF: socket_vmnet is already running"
    return 0
  fi

  log "Bridged network on $BRIDGE_IF (socket_vmnet)"
  if ! brew list --versions socket_vmnet >/dev/null 2>&1; then
    brew install socket_vmnet || { warn "brew install socket_vmnet failed; NAT only"; BRIDGE_IF=""; return 0; }
    FORMULAE_INSTALLED_BY_US="${FORMULAE_INSTALLED_BY_US:+$FORMULAE_INSTALLED_BY_US }socket_vmnet"
  fi
  src="$(brew --prefix socket_vmnet)/bin"
  [ -x "$src/socket_vmnet" ] && [ -x "$src/socket_vmnet_client" ] || { warn "socket_vmnet binaries not found in $src; NAT only"; BRIDGE_IF=""; return 0; }
  cat > "$WORK/vmnet.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>Program</key><string>$VMNET_DIR/bin/socket_vmnet</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VMNET_DIR/bin/socket_vmnet</string>
    <string>--vmnet-mode=bridged</string>
    <string>--vmnet-interface=$BRIDGE_IF</string>
    <string>$sock</string>
  </array>
  <key>StandardErrorPath</key><string>/var/log/socket_vmnet.bridged.$BRIDGE_IF.log</string>
  <key>RunAtLoad</key><true/>
  <key>UserName</key><string>root</string>
</dict>
</plist>
PLIST_EOF
  if ! sudo -n true 2>/dev/null; then
    if [ ! -r /dev/tty ]; then
      warn "No terminal to ask for your Mac password; NAT only (run the setup from a terminal for the bridged network)"
      BRIDGE_IF=""
      return 0
    fi
    echo "    socket_vmnet runs as root: sudo asks for your Mac password once."
  fi
  if ! sudo /bin/sh -c '
        set -e
        install -d -o root -g wheel -m 755 "$1/bin"
        install -o root -g wheel -m 755 "$2/socket_vmnet" "$2/socket_vmnet_client" "$1/bin/"
        install -o root -g wheel -m 644 "$3" "$4"
        launchctl bootout "system/$5" 2>/dev/null || true
        launchctl bootstrap system "$4"' sh "$VMNET_DIR" "$src" "$WORK/vmnet.plist" "$plist" "$label" </dev/tty; then
    warn "Could not install the socket_vmnet service; NAT only"
    BRIDGE_IF=""
    return 0
  fi
  local i=0
  while [ ! -S "$sock" ] && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  if [ -S "$sock" ]; then
    ok "socket_vmnet bridges $BRIDGE_IF ($plist)"
  else
    warn "socket_vmnet did not start (log: /var/log/socket_vmnet.bridged.$BRIDGE_IF.log); the VM falls back to NAT until it runs"
  fi
}

# Records what this script installed on the Mac so debianuninstall can offer to remove it.
# Earlier runs are merged: something installed by a previous attempt stays recorded.
write_manifest() {
  local prev_brew=0 prev_formulae="" f formulae
  if [ -f "$MANIFEST" ]; then
    prev_brew="$(awk -F= '$1 == "installed_homebrew" { print $2 }' "$MANIFEST")"
    prev_formulae="$(awk -F= '$1 == "installed_formulae" { print $2 }' "$MANIFEST")"
  fi
  formulae="$prev_formulae"
  for f in $FORMULAE_INSTALLED_BY_US; do
    case " $formulae " in
      *" $f "*) ;;
      *) formulae="${formulae:+$formulae }$f" ;;
    esac
  done
  {
    echo "# Written by debianopen-setup.sh, read by debianuninstall"
    echo "installed_homebrew=$([ "$BREW_INSTALLED_BY_US" = 1 ] || [ "${prev_brew:-0}" = 1 ] && echo 1 || echo 0)"
    echo "installed_formulae=$formulae"
    echo "pinned_formulae=$([ "${DEBIANOPEN_PIN_BREW:-0}" = 1 ] && echo "qemu gnupg")"
    echo "ssh_port=$SSH_PORT"
    echo "bridge_if=$BRIDGE_IF"
  } > "$MANIFEST"
}

# Gets the companion files (first-boot wizard, zsh setup, Mac commands)
fetch_companions() {
  log "Getting companion files"
  repo_file guest/debianopen-firstboot.sh "$WORK/debianopen-firstboot.sh"
  repo_file guest/debianopen-winsize.sh "$WORK/debianopen-winsize.sh"
  repo_file third_party/zsh_setup/zsh_setup.sh "$WORK/zsh_setup.sh"
  repo_file mac/debianclose.sh "$WORK/debianclose.sh"
  repo_file mac/debianuninstall.sh "$WORK/debianuninstall.sh"
  repo_file mac/debianseal.sh "$WORK/debianseal.sh"
  ok "first-boot wizard, winsize helper, zsh_setup.sh, debianclose, debianuninstall, debianseal"
}

###############################################################################
# 1) DOWNLOAD + VERIFY
###############################################################################
get_alpine() {
  log "Downloading and verifying Alpine ${ALPINE_VERSION} (installer environment)"
  local iso="$DL_DIR/$ALPINE_ISO"
  # Small files: upstream first (so they stay a second source), then the mirror
  fetch "$ALPINE_BASE_URL/$ALPINE_ISO.sha256" "$iso.sha256" 2>/dev/null \
    || fetch "$ALPINE_MIRROR_URL/$ALPINE_ISO.sha256" "$iso.sha256" \
    || die "Could not download $ALPINE_ISO.sha256"
  fetch "$ALPINE_BASE_URL/$ALPINE_ISO.asc" "$iso.asc" 2>/dev/null \
    || fetch "$ALPINE_MIRROR_URL/$ALPINE_ISO.asc" "$iso.asc" \
    || die "Could not download the Alpine ISO signature"
  fetch "$ALPINE_KEY_URL" "$DL_DIR/alpine-ncopa.asc" 2>/dev/null \
    || fetch "$ALPINE_MIRROR_URL/ncopa.asc" "$DL_DIR/alpine-ncopa.asc" \
    || die "Could not download the Alpine signing key"

  # The ISO: the mirror first, then Alpine's servers. A partial file from an
  # interrupted run is resumed; a wrong file is downloaded again.
  local base
  for base in "$ALPINE_MIRROR_URL" "$ALPINE_MIRROR_URL" "$ALPINE_BASE_URL" "$ALPINE_BASE_URL"; do
    [ "$(sha256_of "$iso" 2>/dev/null)" = "$ALPINE_ISO_SHA256" ] && break
    fetch_big "$base/$ALPINE_ISO" "$iso" || true
    [ "$(sha256_of "$iso" 2>/dev/null)" = "$ALPINE_ISO_SHA256" ] || rm -f "$iso"
  done
  [ -f "$iso" ] || die "Could not download $ALPINE_ISO with the pinned sha256."

  local got published
  got="$(sha256_of "$iso")"
  published="$(awk '{print $1; exit}' "$iso.sha256")"
  [ "$got" = "$ALPINE_ISO_SHA256" ] || die "Alpine ISO sha256 does not match the pin in this script ($got)."
  [ "$got" = "$published" ] || die "Alpine ISO sha256 does not match the published value."
  ok "sha256 OK"

  key_has_fpr "$DL_DIR/alpine-ncopa.asc" "$ALPINE_KEY_FPR" || die "Alpine key fingerprint does not match the expected one."
  gpg_verify_sig "$DL_DIR/alpine-ncopa.asc" "$iso.asc" "$iso" "$ALPINE_KEY_FPR" || die "Alpine GPG signature could not be verified."
  ok "GPG signature OK (fingerprint $ALPINE_KEY_FPR)"
}

get_debian() {
  log "Downloading and verifying the Debian ${DEBIAN_VERSION} netinst ISO"
  local iso="$DL_DIR/$DEBIAN_ISO" sums="$DL_DIR/debian-SHA256SUMS" base got
  # The signed checksum list: upstream first (so it stays a second source), then the mirror
  rm -f "$sums" "$sums.sign"
  for base in $DEBIAN_BASE_URLS "$DEBIAN_MIRROR_URL"; do
    if fetch "$base/SHA256SUMS" "$sums" 2>/dev/null && fetch "$base/SHA256SUMS.sign" "$sums.sign" 2>/dev/null; then
      break
    fi
    rm -f "$sums" "$sums.sign"
  done
  [ -f "$sums" ] && [ -f "$sums.sign" ] || die "Could not download the Debian SHA256SUMS and its signature"

  # The ISO: the mirror first, then Debian's servers. A partial file from an
  # interrupted run is resumed; a wrong file is downloaded again.
  for base in "$DEBIAN_MIRROR_URL" "$DEBIAN_MIRROR_URL" $DEBIAN_BASE_URLS; do
    [ "$(sha256_of "$iso" 2>/dev/null)" = "$DEBIAN_ISO_SHA256" ] && break
    fetch_big "$base/$DEBIAN_ISO" "$iso" || true
    [ "$(sha256_of "$iso" 2>/dev/null)" = "$DEBIAN_ISO_SHA256" ] || rm -f "$iso"
  done
  [ -f "$iso" ] || die "Could not download $DEBIAN_ISO with the pinned sha256."

  got="$(sha256_of "$iso")"
  [ "$got" = "$DEBIAN_ISO_SHA256" ] || die "Debian ISO sha256 does not match the pin in this script ($got)."
  awk -v h="$got" -v f="$DEBIAN_ISO" '$1 == h && ($2 == f || $2 == "*" f) { found = 1 } END { exit found ? 0 : 1 }' "$sums" \
    || die "Debian ISO sha256 does not match the published SHA256SUMS."
  DEBIAN_ISO_SIZE="$(size_of_file "$iso")"
  [ $((DEBIAN_ISO_SIZE % 512)) -eq 0 ] || die "Unexpected Debian ISO size: $DEBIAN_ISO_SIZE"
  ok "sha256 OK: $got"

  local keyfile="$DL_DIR/debian-cd-signing-key.asc"
  fetch_debian_key "$keyfile" || die "Could not get the Debian CD signing key. You can provide a key file with DEBIANOPEN_DEBIAN_KEY_FILE."
  gpg_verify_sig "$keyfile" "$sums.sign" "$sums" "$DEBIAN_KEY_FPR" || die "Debian SHA256SUMS GPG signature could not be verified."
  ok "GPG signature of SHA256SUMS OK (fingerprint $DEBIAN_KEY_FPR)"
}

###############################################################################
# 2) DISKS AND THE INSTALLER VM
###############################################################################
create_images() {
  log "Creating virtual disks"
  rm -f "$INSTALL_DIR/disk.qcow2" "$INSTALL_DIR/efi.qcow2" "$INSTALL_DIR/vars.fd" "$INSTALL_DIR/efi-code.fd"
  qemu-img create -q -f qcow2 "$INSTALL_DIR/disk.qcow2" "$ROOT_SIZE"
  qemu-img create -q -f qcow2 "$INSTALL_DIR/efi.qcow2" "$ESP_SIZE"
  # The firmware is part of the boot chain the seal covers: use a private copy,
  # so a `brew upgrade qemu` does not change it under the seal
  cp "$FW_CODE" "$INSTALL_DIR/efi-code.fd"
  cp "$FW_VARS" "$INSTALL_DIR/vars.fd"
  ok "disk.qcow2 ($ROOT_SIZE), efi.qcow2 ($ESP_SIZE), efi-code.fd, vars.fd"
}

# terminfo source (infocmp -x output) of the Mac terminal, so the terminal also
# works over SSH inside Debian. Looks in the system first, then in the apps'
# own terminfo directories under /Applications (e.g. Ghostty).
find_terminfo_source() {
  local name="$1" d src
  [ -n "$name" ] || return 1
  if src="$(infocmp -x "$name" 2>/dev/null)" && [ -n "$src" ]; then
    printf '%s\n' "$src"; return 0
  fi
  for d in "${TERMINFO:-}" /Applications/*/Contents/Resources/terminfo \
           "$HOME"/Applications/*/Contents/Resources/terminfo; do
    [ -d "$d" ] || continue
    if src="$(TERMINFO="$d" infocmp -x "$name" 2>/dev/null)" && [ -n "$src" ]; then
      printf '%s\n' "$src"; return 0
    fi
  done
  return 1
}

stage_terminfo() { # output
  local name="${TERM:-}"
  case "$name" in
    ""|dumb|xterm|xterm-256color|screen*|tmux*|linux|vt100|vt220)
      return 0 ;;
  esac
  command -v infocmp >/dev/null 2>&1 || return 0
  if find_terminfo_source "$name" > "$1"; then
    HAS_TERMINFO=1
    ok "terminfo of this terminal will be installed: $name"
  else
    rm -f "$1"
    warn "terminfo '$name' not found on this Mac, skipping"
  fi
}

write_installer_vm_script() { # output
  local out="$1"
  {
    printf '#!/bin/bash\n'
    printf 'exec %q \\\n' "$QEMU_BIN"
    printf '  -machine virt,highmem=on -accel %q -cpu %q -smp %q -m %q \\\n' "$ACCEL" "$CPU_MODEL" "$CPUS" "$MEM"
    printf '  -drive if=pflash,format=raw,readonly=on,file=%q \\\n' "$INSTALL_DIR/efi-code.fd"
    printf '  -drive if=pflash,format=raw,file=%q \\\n' "$INSTALL_DIR/vars.fd"
    printf '  -drive if=none,id=root,file=%q,format=qcow2 \\\n' "$INSTALL_DIR/disk.qcow2"
    printf '  -device virtio-blk-pci,drive=root,serial=DEBROOT \\\n'
    printf '  -drive if=none,id=esp,file=%q,format=qcow2 \\\n' "$INSTALL_DIR/efi.qcow2"
    printf '  -device virtio-blk-pci,drive=esp,serial=DEBESP \\\n'
    printf '  -drive if=none,id=iso,file=%q,format=raw,readonly=on \\\n' "$DL_DIR/$ALPINE_ISO"
    printf '  -device virtio-blk-pci,drive=iso,serial=ALPINEISO,bootindex=0 \\\n'
    printf '  -drive if=none,id=debiso,file=%q,format=raw,readonly=on \\\n' "$DL_DIR/$DEBIAN_ISO"
    printf '  -device virtio-blk-pci,drive=debiso,serial=DEBIANISO \\\n'
    printf '  -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \\\n'
    printf '  -nographic\n'
  } > "$out"
  chmod 700 "$out"
}

write_guest_script() { # output
  cat > "$1" <<'GUEST_EOF'
#!/bin/sh
# debianopen guest installer: runs in the Alpine live environment (busybox ash)
set -eu

step() { echo "DEBIANOPEN_STEP: $*"; }
die()  { echo "DEBIANOPEN_ERROR: $*"; exit 1; }
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "DEBIANOPEN_ERROR: guest script exited with code $rc"' EXIT

: "${ROOT_UUID:?}" "${LUKS_UUID:?}" "${ESP_ID:?}" "${ESP_UUID:?}" "${FILES_URL:?}" "${ALPINE_SERIES:?}"
: "${ISO_SHA256:?}" "${ISO_SIZE:?}" "${DEBIAN_SUITE:?}" "${APT_MIRROR:?}"
: "${DEB_HOSTNAME:?}" "${DEB_USER:?}" "${USER_PW:?}" "${SSH_PORT:?}" "${DEBIANOPEN_REPO:?}" "${MAC_LAN:?}" "${MAC_LOCAL:?}"
HAS_TERMINFO="${HAS_TERMINFO:-0}"
ESP_OPTS="rw,relatime,fmask=0077,dmask=0077,errors=remount-ro"
BTRFS_OPTS="rw,noatime,compress=zstd:1"
CRYPTDEV=/dev/mapper/cryptroot
ISO_MNT=/media/debian

step "Installing Alpine tools"
# http: packages are verified by apk signatures; avoids CA/clock issues on the live ISO
printf '%s\n' \
  "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/main" \
  "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/community" > /etc/apk/repositories
apk update >/dev/null || die "apk update failed (internet access?)"
apk add -q --no-progress btrfs-progs cryptsetup curl sfdisk dosfstools debootstrap || die "apk add failed"
modprobe btrfs 2>/dev/null || true
modprobe dm-crypt 2>/dev/null || true
modprobe vfat 2>/dev/null || true
modprobe isofs 2>/dev/null || true

find_disk() {
  for d in /sys/block/vd*; do
    [ -e "$d/serial" ] || continue
    s="$(cat "$d/serial" 2>/dev/null || true)"
    if [ "$s" = "$1" ]; then
      echo "/dev/${d##*/}"
      return 0
    fi
  done
  return 1
}
ROOTDEV="$(find_disk DEBROOT)" || die "root disk not found"
ESPDEV="$(find_disk DEBESP)" || die "ESP disk not found"
ISODEV="$(find_disk DEBIANISO)" || die "Debian ISO disk not found"
step "Disks: root=$ROOTDEV  esp=$ESPDEV  debian-iso=$ISODEV"

step "Verifying the Debian ISO (sha256) and mounting it"
# The disk is the ISO file as is (its size is a multiple of 512 bytes)
GOT="$(head -c "$ISO_SIZE" "$ISODEV" | sha256sum | awk '{print $1}')"
[ "$GOT" = "$ISO_SHA256" ] || die "Debian ISO sha256 mismatch inside the VM ($GOT)"
mkdir -p "$ISO_MNT"
mount -t iso9660 -o ro "$ISODEV" "$ISO_MNT" || die "could not mount the Debian ISO"
[ -f "$ISO_MNT/dists/$DEBIAN_SUITE/Release" ] || die "the Debian ISO has no $DEBIAN_SUITE repository"

step "Partitioning the ESP (GPT, EFI System) and formatting it as FAT32"
echo 'type=U' | sfdisk --quiet --label gpt "$ESPDEV" >/dev/null
ESPPART="${ESPDEV}1"
i=0
while [ ! -b "$ESPPART" ] && [ "$i" -lt 20 ]; do
  mdev -s 2>/dev/null || true
  sleep 1
  i=$((i + 1))
done
[ -b "$ESPPART" ] || die "$ESPPART did not appear"
mkfs.fat -F32 -n EFI -i "$ESP_ID" "$ESPPART" >/dev/null

step "Encrypting the root disk with LUKS2 (argon2id)"
# The Mac types the passphrase in with echo off, so it is not in the log
stty -echo 2>/dev/null || true
echo "DEBIANOPEN_NEED_PASSPHRASE"
IFS= read -r LUKS_PW || die "no passphrase received"
stty echo 2>/dev/null || true
[ -n "$LUKS_PW" ] || die "empty passphrase"
# --key-file - takes the input as is: printf without a newline matches what is typed at boot
printf '%s' "$LUKS_PW" | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id \
  --uuid "$LUKS_UUID" --label debiancrypt --key-file - "$ROOTDEV" || die "cryptsetup luksFormat failed"
printf '%s' "$LUKS_PW" | cryptsetup open --key-file - "$ROOTDEV" cryptroot || die "cryptsetup open failed"
LUKS_PW=""

step "Formatting the encrypted volume as btrfs (subvolumes @, @home, @log, @pkg)"
mkfs.btrfs -q -f -L debianroot -U "$ROOT_UUID" "$CRYPTDEV" >/dev/null
mount "$CRYPTDEV" /mnt
for sv in @ @home @log @pkg; do
  btrfs subvolume create "/mnt/$sv" >/dev/null || die "could not create subvolume $sv"
done
umount /mnt
mount -o "$BTRFS_OPTS,subvol=/@" "$CRYPTDEV" /mnt
mkdir -p /mnt/home /mnt/var/log /mnt/var/cache/apt
mount -o "$BTRFS_OPTS,subvol=/@home" "$CRYPTDEV" /mnt/home
mount -o "$BTRFS_OPTS,subvol=/@log" "$CRYPTDEV" /mnt/var/log
mount -o "$BTRFS_OPTS,subvol=/@pkg" "$CRYPTDEV" /mnt/var/cache/apt

step "Installing the Debian base system from the ISO with debootstrap (this can take a few minutes)"
# The ISO was verified above (its sha256 is in the GPG-signed SHA256SUMS);
# debootstrap checks every package against the ISO's Release and Packages files.
# The ISO carries no Release signature of its own, hence --no-check-gpg.
if ! debootstrap --arch=arm64 --variant=minbase --no-check-gpg \
     --include=systemd-sysv,ca-certificates \
     "$DEBIAN_SUITE" /mnt "file://$ISO_MNT" > /tmp/debootstrap.log 2>&1; then
  tail -n 30 /tmp/debootstrap.log
  tail -n 30 /mnt/debootstrap/debootstrap.log 2>/dev/null || true
  die "debootstrap failed"
fi
umount "$ISO_MNT" 2>/dev/null || true
[ -x /mnt/usr/bin/apt-get ] && [ -x /mnt/lib/systemd/systemd ] || die "the base system does not have the expected layout"

step "Preparing the chroot"
# The ESP is mounted inside the chroot once systemd-boot is installed: with an
# ESP in sight, the package's own setup would try to write EFI variables and fail
mkdir -p /mnt/boot/efi
mount -t proc proc /mnt/proc -o nosuid,noexec,nodev
mount -t sysfs sys /mnt/sys -o nosuid,noexec,nodev,ro
mount -t devtmpfs udev /mnt/dev -o mode=0755,nosuid
mkdir -p /mnt/dev/pts /mnt/dev/shm
mount -t devpts devpts /mnt/dev/pts -o mode=0620,gid=5,nosuid,noexec
mount -t tmpfs shm /mnt/dev/shm -o mode=1777,nosuid,nodev
mount -t tmpfs run /mnt/run -o nosuid,nodev,mode=0755
mount -t tmpfs tmp /mnt/tmp -o mode=1777,strictatime,nodev,nosuid
# systemd-resolved turns /etc/resolv.conf into a link to its stub; temporary DNS for the chroot
mkdir -p /mnt/run/systemd/resolve
cp /etc/resolv.conf /mnt/run/systemd/resolve/stub-resolv.conf
cp /etc/resolv.conf /mnt/run/systemd/resolve/resolv.conf
rm -f /mnt/etc/resolv.conf
cp /etc/resolv.conf /mnt/etc/resolv.conf

cat > /mnt/etc/fstab <<FSTAB_EOF
# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
UUID=${ROOT_UUID}  /                btrfs  ${BTRFS_OPTS},subvol=/@     0 0
UUID=${ROOT_UUID}  /home            btrfs  ${BTRFS_OPTS},subvol=/@home  0 0
UUID=${ROOT_UUID}  /var/log         btrfs  ${BTRFS_OPTS},subvol=/@log   0 0
UUID=${ROOT_UUID}  /var/cache/apt   btrfs  ${BTRFS_OPTS},subvol=/@pkg   0 0
UUID=${ESP_UUID}  /boot/efi  vfat  ${ESP_OPTS}  0 2
FSTAB_EOF

cat > /mnt/etc/crypttab <<CRYPTTAB_EOF
# <target name> <source device> <key file> <options>
cryptroot UUID=${LUKS_UUID} none luks,discard,initramfs
CRYPTTAB_EOF

step "Setting the hostname: $DEB_HOSTNAME"
echo "$DEB_HOSTNAME" > /mnt/etc/hostname
cat > /mnt/etc/hosts <<HOSTS_EOF
127.0.0.1	localhost
127.0.1.1	$DEB_HOSTNAME
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
HOSTS_EOF

step "Installing the first-boot wizard and zsh setup"
curl -fsS -o /tmp/debianopen-firstboot.sh "$FILES_URL/debianopen-firstboot.sh" || die "could not download the first-boot wizard"
curl -fsS -o /tmp/zsh_setup.sh "$FILES_URL/zsh_setup.sh" || die "could not download zsh_setup.sh"
install -D -m 0755 /tmp/debianopen-firstboot.sh /mnt/usr/local/sbin/debianopen-firstboot
install -D -m 0644 /tmp/zsh_setup.sh /mnt/usr/local/share/debianopen/zsh_setup.sh

step "Installing the terminal size helper"
curl -fsS -o /tmp/debianopen-winsize.sh "$FILES_URL/debianopen-winsize.sh" || die "could not download the winsize helper"
install -D -m 0755 /tmp/debianopen-winsize.sh /mnt/usr/local/sbin/debianopen-winsize
mkdir -p /mnt/etc/systemd/system
# Started by udev when the launcher's virtio-serial port appears; no [Install] section needed
cat > /mnt/etc/systemd/system/debianopen-winsize.service <<'UNIT_EOF'
[Unit]
Description=Keep the serial console the size of the Mac terminal (debianopen)
BindsTo=dev-virtio\x2dports-org.debianopen.winsize.device
After=dev-virtio\x2dports-org.debianopen.winsize.device

[Service]
ExecStart=/usr/local/sbin/debianopen-winsize
Restart=always
RestartSec=1
UNIT_EOF
mkdir -p /mnt/etc/udev/rules.d
cat > /mnt/etc/udev/rules.d/90-debianopen-winsize.rules <<'UDEV_EOF'
SUBSYSTEM=="virtio-ports", ATTR{name}=="org.debianopen.winsize", TAG+="systemd", ENV{SYSTEMD_WANTS}+="debianopen-winsize.service"
UDEV_EOF
if [ "$HAS_TERMINFO" = "1" ]; then
  curl -fsS -o /mnt/root/.debianopen-terminfo "$FILES_URL/terminfo.src" || die "could not download terminfo"
fi

( umask 077; printf '%s' "$USER_PW" > /mnt/root/.debianopen-pw )
cat > /mnt/root/debianopen-chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
step() { echo "DEBIANOPEN_STEP: $*"; }
fail() { echo "DEBIANOPEN_ERROR: $*"; exit 1; }
export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
APT=(apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

step "Pointing apt at the Debian mirrors ($APT_MIRROR)"
# http: packages are verified by apt's signatures (debian-archive-keyring)
cat > /etc/apt/sources.list <<SOURCES_EOF
deb $APT_MIRROR/debian $DEBIAN_SUITE main contrib non-free-firmware
deb $APT_MIRROR/debian $DEBIAN_SUITE-updates main contrib non-free-firmware
deb $APT_MIRROR/debian-security $DEBIAN_SUITE-security main contrib non-free-firmware
SOURCES_EOF
"${APT[@]}" update

step "Updating the system (apt full-upgrade)"
"${APT[@]}" full-upgrade

step "Installing packages"
"${APT[@]}" install --no-install-recommends \
  systemd-boot systemd-resolved systemd-timesyncd dbus libpam-systemd udev kmod \
  initramfs-tools cryptsetup cryptsetup-initramfs btrfs-progs dosfstools \
  openssh-server sudo zsh git curl wget unzip fontconfig ca-certificates \
  less nano iproute2 iputils-ping procps psmisc bash-completion ncurses-term \
  man-db file xz-utils zstd

step "Installing systemd-boot"
# Kernels and initramfs images reach the ESP through kernel-install, which
# Debian's kernel and initramfs hooks call on every update
mount /boot/efi || fail "could not mount the ESP"
systemd-machine-id-setup >/dev/null
mkdir -p /etc/kernel
echo "root=/dev/mapper/cryptroot rootflags=subvol=@ rw console=ttyAMA0" > /etc/kernel/cmdline
echo "layout=bls" > /etc/kernel/install.conf
bootctl install --esp-path=/boot/efi --no-variables --make-machine-id-directory=yes
cat > /boot/efi/loader/loader.conf <<LOADER_EOF
timeout 3
console-mode max
editor no
LOADER_EOF

step "Installing the kernel and building the initramfs with LUKS unlock and btrfs"
# cryptsetup-initramfs reads /etc/crypttab; the hook asks for the passphrase
# on the serial console. MODULES=most (the default) brings virtio and btrfs.
"${APT[@]}" install --no-install-recommends linux-image-arm64
KVER="$(ls /lib/modules | sort -V | tail -n 1)"
[ -n "$KVER" ] && [ -f "/boot/vmlinuz-$KVER" ] || fail "no kernel was installed"
update-initramfs -u -k "$KVER"
lsinitramfs "/boot/initrd.img-$KVER" > /tmp/initramfs.list
grep -q 'sbin/cryptsetup$' /tmp/initramfs.list \
  || fail "the initramfs has no cryptsetup, it could not unlock the disk"
grep -q 'conf/conf.d/cryptroot$\|cryptroot/crypttab$' /tmp/initramfs.list \
  || fail "the initramfs does not know the encrypted root (crypttab)"
MID="$(cat /etc/machine-id)"
if [ ! -s "/boot/efi/$MID/$KVER/linux" ]; then
  # The hooks only act once systemd-boot is in place; add this kernel by hand
  kernel-install add "$KVER" "/boot/vmlinuz-$KVER" "/boot/initrd.img-$KVER"
fi
[ -s "/boot/efi/$MID/$KVER/linux" ] || fail "the kernel did not reach the ESP"
ls /boot/efi/loader/entries/*.conf >/dev/null 2>&1 || fail "systemd-boot has no boot entry"

step "Creating the user $DEB_USER (sudo) and locking root"
useradd -m -G sudo -s /bin/bash "$DEB_USER"
PW="$(cat /root/.debianopen-pw)"
rm -f /root/.debianopen-pw
printf '%s:%s\n' "$DEB_USER" "$PW" | chpasswd
grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers \
  || fail "/etc/sudoers does not include /etc/sudoers.d"
# noninteractive_auth: `sudo -n` asks PAM too (sudo >= 1.9.10 otherwise refuses
# without trying), so the serial console rule below also covers scripts using -n
printf 'Defaults noninteractive_auth\n%%sudo ALL=(ALL:ALL) ALL\n' > /tmp/10-sudo
visudo -cf /tmp/10-sudo >/dev/null || fail "invalid sudoers file"
install -m 0440 -o root -g root /tmp/10-sudo /etc/sudoers.d/10-sudo
rm -f /tmp/10-sudo
# sudo without a password, but only on the serial console (the Mac terminal
# running debianopen). SSH and every other terminal still ask for it.
# sudo puts its terminal in PAM_TTY; pam_succeed_if lets it through before pam_unix
if ! grep -q 'debianopen: serial console' /etc/pam.d/sudo; then
  awk '!done && (/^auth/ || /^@include[[:space:]]+common-auth/) {
         print "# debianopen: serial console, no password (the terminal running debianopen)"
         print "auth\t\tsufficient\tpam_succeed_if.so quiet tty in /dev/ttyAMA0:ttyAMA0"
         done = 1
       } { print }' /etc/pam.d/sudo > /tmp/pam-sudo
  cat /tmp/pam-sudo > /etc/pam.d/sudo
  rm -f /tmp/pam-sudo
fi
grep -q '^auth.*pam_succeed_if.so quiet tty in /dev/ttyAMA0' /etc/pam.d/sudo \
  || fail "could not set up sudo on the serial console"
# No password, no login: not on the console, not over SSH. sudo -i gives a root shell
passwd -l root >/dev/null
# What the first-boot wizard shows and sets up
cat > /etc/debianopen.conf <<CONF_EOF
DEBIANOPEN_USER=$DEB_USER
DEBIANOPEN_SSH_PORT=$SSH_PORT
DEBIANOPEN_REPO=$DEBIANOPEN_REPO
CONF_EOF
chmod 644 /etc/debianopen.conf

step "Network (systemd-networkd: bridged + local SSH), locale, console"
# Two network cards, told apart by the MAC addresses the launcher gives them:
# the bridged one (or QEMU's NAT when the bridge is not running) gets its
# address by DHCP; the second carries only the Mac's 127.0.0.1 SSH forward,
# with a fixed address and no default route
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-debianopen-lan.network <<NET_EOF
# debianopen: bridged to the Mac's network, address from your router
[Match]
MACAddress=$MAC_LAN

[Network]
DHCP=yes
NET_EOF
cat > /etc/systemd/network/10-debianopen-local.network <<NET_EOF
# debianopen: QEMU's NAT, only for ssh -p $SSH_PORT localhost on the Mac
[Match]
MACAddress=$MAC_LOCAL

[Network]
Address=10.0.2.15/24
LinkLocalAddressing=no
IPv6AcceptRA=no
NET_EOF
cat > /etc/systemd/network/20-wired.network <<NET_EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
NET_EOF
systemctl enable systemd-networkd.service systemd-resolved.service systemd-timesyncd.service ssh.service >/dev/null 2>&1 \
  || fail "could not enable the network services"
echo "LANG=C.UTF-8" > /etc/default/locale
# The serial console reports vt220; the Mac terminal behind it handles more
mkdir -p /etc/systemd/system/serial-getty@ttyAMA0.service.d
cat > /etc/systemd/system/serial-getty@ttyAMA0.service.d/term.conf <<GETTY_EOF
[Service]
Environment=TERM=xterm-256color
GETTY_EOF

if [ -f /root/.debianopen-terminfo ]; then
  step "Installing the terminal's terminfo"
  tic -x -o /usr/share/terminfo /root/.debianopen-terminfo || echo "warning: tic failed"
  rm -f /root/.debianopen-terminfo
fi

apt-get clean
CHROOT_EOF

chroot /mnt /usr/bin/env -i HOME=/root TERM=dumb LANG=C.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  ROOT_UUID="$ROOT_UUID" LUKS_UUID="$LUKS_UUID" DEB_USER="$DEB_USER" \
  SSH_PORT="$SSH_PORT" DEBIAN_SUITE="$DEBIAN_SUITE" APT_MIRROR="$APT_MIRROR" DEBIANOPEN_REPO="$DEBIANOPEN_REPO" \
  MAC_LAN="$MAC_LAN" MAC_LOCAL="$MAC_LOCAL" \
  /bin/bash /root/debianopen-chroot.sh || die "installation inside the chroot failed"
rm -f /mnt/root/debianopen-chroot.sh /mnt/root/.debianopen-pw /mnt/root/.debianopen-terminfo
# The link systemd-resolved expects (the chroot used a copy of Alpine's file)
ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

step "Checking the installation"
for f in EFI/BOOT/BOOTAA64.EFI EFI/systemd/systemd-bootaa64.efi loader/loader.conf; do
  [ -s "/mnt/boot/efi/$f" ] || die "/boot/efi/$f is missing"
done
echo "DEBIANOPEN_PKGLIST_BEGIN"
chroot /mnt /usr/bin/dpkg-query -W -f '${Package} ${Version}\n'
echo "DEBIANOPEN_PKGLIST_END"

step "Unmounting"
sync
for m in /mnt/tmp /mnt/run /mnt/dev/shm /mnt/dev/pts /mnt/dev /mnt/sys /mnt/proc /mnt/boot/efi \
         /mnt/var/cache/apt /mnt/var/log /mnt/home /mnt; do
  umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
done
sync
cryptsetup close cryptroot 2>/dev/null || true
step "Alpine install stage done"
GUEST_EOF
}

write_installer_expect() { # output
  cat > "$1" <<'EXP_EOF'
#!/usr/bin/expect -f
# Drives the Alpine VM over the serial console. Input: environment variables (DEBIANOPEN_*)
set timeout 30
match_max 200000
log_user 0
proc wait_info {} {
    if {[catch {wait} r]} { return "could not get exit status" }
    return "pid=[lindex $r 0] os_error=[lindex $r 2] exit_code_or_signal=[lindex $r 3]"
}
log_file -a $env(DEBIANOPEN_LOG)

proc die {msg} {
    puts stderr "\nERROR: $msg"
    exit 1
}

# Kept out of the environment of QEMU and everything else spawned from here
set luks $env(DEBIANOPEN_LUKS_PW)
unset env(DEBIANOPEN_LUKS_PW)

spawn $env(DEBIANOPEN_VM_SCRIPT)

# 1) Boot and log in
set nudges 0
set logins 0
expect {
    -re {login: $} {
        incr logins
        if {$logins > 3} { die "Alpine login failed" }
        send "root\r"
        exp_continue
    }
    -re {[Pp]assword: $} {
        send "\r"
        exp_continue
    }
    -re {:~# $} { }
    timeout {
        incr nudges
        if {$nudges > $env(DEBIANOPEN_BOOT_NUDGES)} { die "Alpine boot timed out (log: $env(DEBIANOPEN_LOG))" }
        send "\r"
        exp_continue
    }
    eof { die "QEMU exited unexpectedly - [wait_info] (log: $env(DEBIANOPEN_LOG))" }
}

# Runs one command and returns its exit code
proc run {cmd tmo} {
    global timeout
    set timeout $tmo
    send -- "$cmd; echo DEBIANOPEN_RC=\$?\r"
    expect {
        -re {DEBIANOPEN_RC=([0-9]+)\r} { return $expect_out(1,string) }
        timeout { die "timed out: $cmd" }
        eof { die "QEMU exited - [wait_info]: $cmd" }
    }
}

if {[run "stty cols 250" 30] != 0} { die "stty failed" }
puts "    - Alpine is up, configuring the network"; flush stdout
if {[run "ip link set eth0 up && udhcpc -i eth0 -q -n >/dev/null 2>&1" 120] != 0} { die "Alpine network did not come up (DHCP)" }
if {[run "wget -q -O /tmp/guest.sh http://10.0.2.2:$env(DEBIANOPEN_PORT)/guest-install.sh" 60] != 0} { die "could not fetch the guest script from the Mac" }

# 2) The actual installation
set vars "ROOT_UUID=$env(DEBIANOPEN_ROOT_UUID) LUKS_UUID=$env(DEBIANOPEN_LUKS_UUID)"
append vars " ESP_ID=$env(DEBIANOPEN_ESP_ID) ESP_UUID=$env(DEBIANOPEN_ESP_UUID)"
append vars " FILES_URL=http://10.0.2.2:$env(DEBIANOPEN_PORT) ALPINE_SERIES=$env(DEBIANOPEN_ALPINE_SERIES)"
append vars " ISO_SHA256=$env(DEBIANOPEN_ISO_SHA256) ISO_SIZE=$env(DEBIANOPEN_ISO_SIZE)"
append vars " DEBIAN_SUITE=$env(DEBIANOPEN_SUITE) APT_MIRROR=$env(DEBIANOPEN_APT_MIRROR)"
append vars " DEB_HOSTNAME=$env(DEBIANOPEN_HOSTNAME) HAS_TERMINFO=$env(DEBIANOPEN_HAS_TERMINFO)"
append vars " DEB_USER=$env(DEBIANOPEN_USER) USER_PW=$env(DEBIANOPEN_USER_PW) SSH_PORT=$env(DEBIANOPEN_SSH_PORT)"
append vars " DEBIANOPEN_REPO=$env(DEBIANOPEN_REPO) MAC_LAN=$env(DEBIANOPEN_MAC_LAN) MAC_LOCAL=$env(DEBIANOPEN_MAC_LOCAL)"
set timeout $env(DEBIANOPEN_IDLE_TIMEOUT)
send -- "$vars sh /tmp/guest.sh; echo DEBIANOPEN_GUEST_DONE=\$?\r"

set guest_rc -1
set errmsg ""
expect {
    -re {([^\n]*)\n} {
        set line [string trimright $expect_out(1,string) "\r"]
        set cont 1
        if {[regexp {^DEBIANOPEN_STEP: (.*)$} $line -> msg]} {
            puts "    - $msg"; flush stdout
        } elseif {$line eq "DEBIANOPEN_NEED_PASSPHRASE"} {
            # The guest turned echo off before asking
            send -- "$luks\r"
        } elseif {[regexp {^DEBIANOPEN_ERROR: (.*)$} $line -> msg]} {
            set errmsg $msg
            puts stderr "    x $msg"; flush stderr
        } elseif {[regexp {^DEBIANOPEN_GUEST_DONE=([0-9]+)$} $line -> rc]} {
            set guest_rc $rc
            set cont 0
        }
        if {$cont} { exp_continue }
    }
    timeout { die "The installation produced no output for $env(DEBIANOPEN_IDLE_TIMEOUT) s (log: $env(DEBIANOPEN_LOG))" }
    eof { die "QEMU exited during the installation - [wait_info] (log: $env(DEBIANOPEN_LOG))" }
}

if {$guest_rc != 0} {
    die "Installation failed (exit code $guest_rc) $errmsg (log: $env(DEBIANOPEN_LOG))"
}

# 3) Clean shutdown
set timeout 180
send -- "sync; poweroff\r"
expect {
    eof { }
    timeout { die "Alpine did not shut down" }
}
catch {wait}
exit 0
EXP_EOF
}

run_installer() {
  log "Installer VM running (driven automatically over the Alpine serial console)"
  echo "    Detailed output: $LOG_FILE"

  local stage="$WORK/stage"
  mkdir -p "$stage"
  write_guest_script "$stage/guest-install.sh"
  cp "$WORK/debianopen-firstboot.sh" "$stage/debianopen-firstboot.sh"
  cp "$WORK/debianopen-winsize.sh" "$stage/debianopen-winsize.sh"
  cp "$WORK/zsh_setup.sh" "$stage/zsh_setup.sh"
  stage_terminfo "$stage/terminfo.src"

  local port
  port="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$stage" >"$WORK/http.log" 2>&1 &
  HTTP_PID=$!
  local i=0
  until curl -fsI "http://127.0.0.1:$port/guest-install.sh" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || die "The local HTTP server did not start ($WORK/http.log)"
    sleep 0.2
  done

  write_installer_vm_script "$WORK/run-installer-vm.sh"
  write_installer_expect "$WORK/installer.exp"

  ROOT_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  LUKS_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  ESP_ID="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]')"
  ESP_UUID="${ESP_ID:0:4}-${ESP_ID:4:4}"

  DEBIANOPEN_LOG="$LOG_FILE" \
  DEBIANOPEN_VM_SCRIPT="$WORK/run-installer-vm.sh" \
  DEBIANOPEN_PORT="$port" \
  DEBIANOPEN_ROOT_UUID="$ROOT_UUID" \
  DEBIANOPEN_LUKS_UUID="$LUKS_UUID" \
  DEBIANOPEN_LUKS_PW="$LUKS_PW" \
  DEBIANOPEN_ESP_ID="$ESP_ID" \
  DEBIANOPEN_ESP_UUID="$ESP_UUID" \
  DEBIANOPEN_ISO_SHA256="$DEBIAN_ISO_SHA256" \
  DEBIANOPEN_ISO_SIZE="$DEBIAN_ISO_SIZE" \
  DEBIANOPEN_SUITE="$DEBIAN_SUITE" \
  DEBIANOPEN_APT_MIRROR="$APT_MIRROR" \
  DEBIANOPEN_ALPINE_SERIES="$ALPINE_SERIES" \
  DEBIANOPEN_HOSTNAME="$DEB_HOSTNAME" \
  DEBIANOPEN_HAS_TERMINFO="$HAS_TERMINFO" \
  DEBIANOPEN_USER="$DEB_USER" \
  DEBIANOPEN_USER_PW="$TEMP_USER_PASSWORD" \
  DEBIANOPEN_SSH_PORT="$SSH_PORT" \
  DEBIANOPEN_REPO="$DEBIANOPEN_REPO" \
  DEBIANOPEN_MAC_LAN="$MAC_LAN" \
  DEBIANOPEN_MAC_LOCAL="$MAC_LOCAL" \
  DEBIANOPEN_BOOT_NUDGES="${DEBIANOPEN_BOOT_NUDGES:-40}" \
  DEBIANOPEN_IDLE_TIMEOUT="${DEBIANOPEN_IDLE_TIMEOUT:-1800}" \
    expect -f "$WORK/installer.exp" || die "The installer VM failed. Log: $LOG_FILE"

  kill "$HTTP_PID" >/dev/null 2>&1 || true
  HTTP_PID=""
  ok "Disk ready"
}

###############################################################################
# 3) LAUNCHER, VERIFICATION, ALIASES
###############################################################################
write_start_script() {
  local out="$INSTALL_DIR/start-uefi.sh"
  # Console on stdio with signal=off: Ctrl+C goes to the process running in the
  # guest instead of killing QEMU (what -nographic does). mux keeps Ctrl+A X/C.
  local mon_opt='-mon chardev=con0,mode=readline'
  if "$QEMU_BIN" -object help 2>/dev/null | grep -qw monitor-hmp; then
    mon_opt='-object monitor-hmp,id=mon0,chardev=con0'
  fi
  # The generated script intentionally contains literal $
  # shellcheck disable=SC2016
  {
    printf '#!/bin/bash\n'
    printf '# Debian (QEMU) launcher. Generated by debianopen-setup.sh.\n'
    printf '# Quit: `debianclose` from another Mac terminal, `sudo poweroff` inside the VM, or Ctrl+A then X.\n'
    printf '# Ctrl+C goes to the guest (it does not stop the VM).\n'
    printf '# SSH: ssh -p %s %s@localhost\n' "$SSH_PORT" "$DEB_USER"
    printf 'SSH_PORT="${DEBIANOPEN_SSH_PORT:-%s}"\n' "$SSH_PORT"
    printf 'QEMU_BIN=%q\n' "$QEMU_BIN"
    printf 'QEMU_MACHINE=(-machine virt,highmem=on -accel %q -cpu %q -smp %q -m %q)\n' "$ACCEL" "$CPU_MODEL" "$CPUS" "$MEM"
    printf 'QEMU_MONITOR=(%s)\n' "$mon_opt"
    printf 'BRIDGE_IF=%q\n' "$BRIDGE_IF"
    printf 'MAC_LAN=%q\nMAC_LOCAL=%q\n' "$MAC_LAN" "$MAC_LOCAL"
    cat <<'LAUNCHER_EOF'
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
pid="$(cat "$DIR/qemu.pid" 2>/dev/null || true)"
if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -qF "$DIR/disk.qcow2"; then
  echo "The Debian VM is already running (pid $pid). Shut it down with: debianclose" >&2
  exit 1
fi
# Integrity check: if any VM file differs from the seal, QEMU is not started
# and the disk passphrase prompt never appears
"$DIR/debianseal.sh" verify || exit 1
echo "$$" > "$DIR/.debianopen-session"
rm -f "$DIR/qmp.sock" "$DIR/winsize.in" "$DIR/winsize.out"
# vars.fd stays as sealed: each boot gets a throwaway copy of the UEFI variables
cp "$DIR/vars.fd" "$DIR/vars.run.fd" || exit 1
# Terminal size channel to the guest (debianopen-winsize inside Debian)
WINSIZE=0
mkfifo -m 600 "$DIR/winsize.in" "$DIR/winsize.out" 2>/dev/null && WINSIZE=1
WINSIZE_ARGS=()
if [ "$WINSIZE" = 1 ]; then
  WINSIZE_ARGS=(-device virtio-serial-pci,id=vser0
    -chardev "pipe,id=winsize,path=$DIR/winsize"
    -device virtserialport,bus=vser0.0,chardev=winsize,name=org.debianopen.winsize)
fi
# Network: with socket_vmnet running, the first card is bridged (address from
# your router) and the second is QEMU's NAT, only for SSH on 127.0.0.1. Without
# it, the first card is the NAT. The guest tells them apart by MAC address
NAT="user,id=nat,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
VMNET_CLIENT=/opt/socket_vmnet/bin/socket_vmnet_client
VMNET_SOCK="/private/var/run/socket_vmnet.bridged.$BRIDGE_IF"
RUN=()
if [ -n "$BRIDGE_IF" ] && [ -S "$VMNET_SOCK" ] && [ -x "$VMNET_CLIENT" ]; then
  # socket_vmnet_client hands QEMU the socket on the lowest free fd, which
  # must be 3: the command below runs with fd 3 closed (bash <(curl ...) and
  # other callers can leave it open)
  RUN=("$VMNET_CLIENT" "$VMNET_SOCK")
  NET_ARGS=(-device "virtio-net-pci,netdev=lan,mac=$MAC_LAN" -netdev socket,id=lan,fd=3
            -device "virtio-net-pci,netdev=nat,mac=$MAC_LOCAL" -netdev "$NAT")
  echo "Network: bridged on $BRIDGE_IF (address from your router); SSH also on 127.0.0.1:$SSH_PORT"
else
  NET_ARGS=(-device "virtio-net-pci,netdev=nat,mac=$MAC_LAN" -netdev "$NAT")
  [ -z "$BRIDGE_IF" ] || echo "Network: socket_vmnet is not running on $BRIDGE_IF, NAT only this time (sudo launchctl kickstart system/io.github.lima-vm.socket_vmnet.bridged.$BRIDGE_IF)" >&2
fi
# Closing the terminal must not skip the reseal below; QEMU still gets the signal
hup=""
trap 'hup=1' HUP TERM
# In the background so this script can forward window size changes, with the
# terminal as its input (a background job would otherwise read /dev/null)
${RUN[@]+"${RUN[@]}"} "$QEMU_BIN" "${QEMU_MACHINE[@]}" \
  -drive if=pflash,format=raw,readonly=on,file="$DIR/efi-code.fd" \
  -drive if=pflash,format=raw,file="$DIR/vars.run.fd" \
  -drive if=none,id=root,file="$DIR/disk.qcow2",format=qcow2 \
  -device virtio-blk-pci,drive=root \
  -drive if=none,id=esp,file="$DIR/efi.qcow2",format=qcow2 \
  -device virtio-blk-pci,drive=esp,bootindex=0 \
  "${NET_ARGS[@]}" \
  ${WINSIZE_ARGS[@]+"${WINSIZE_ARGS[@]}"} \
  -qmp "unix:$DIR/qmp.sock,server=on,wait=off" \
  -pidfile "$DIR/qemu.pid" \
  -display none \
  -chardev stdio,id=con0,mux=on,signal=off \
  -serial chardev:con0 "${QEMU_MONITOR[@]}" <&0 3>&- &
qpid=$!
wpid=""
if [ "$WINSIZE" = 1 ]; then
  # Sends the terminal size on every resize (SIGWINCH), and every 2 s so a
  # reboot inside the VM gets it again. Read-write open: never blocks on the FIFO
  (
    trap - HUP TERM
    exec 9<>"$DIR/winsize.in" || exit 0
    send() {
      local sz
      sz="$(stty size </dev/tty 2>/dev/null)" || return 0
      case "$sz" in [1-9]*" "[1-9]*) printf '%s\n' "$sz" >&9 ;; esac
    }
    trap send WINCH
    while kill -0 "$qpid" 2>/dev/null; do
      send
      sleep 2 & wait $! 2>/dev/null
    done
  ) &
  wpid=$!
fi
# wait returns early when a trapped signal arrives: keep waiting until QEMU is gone
wait "$qpid"
rc=$?
while kill -0 "$qpid" 2>/dev/null; do
  wait "$qpid"
  rc=$?
done
[ -z "$wpid" ] || kill "$wpid" 2>/dev/null
rm -f "$DIR/vars.run.fd" "$DIR/qmp.sock" "$DIR/qemu.pid" "$DIR/winsize.in" "$DIR/winsize.out"
# What this session wrote (the disk, kernel updates on the ESP) is the new sealed state
if [ -n "$hup" ]; then
  "$DIR/debianseal.sh" update >/dev/null 2>&1 && rm -f "$DIR/.debianopen-session"
elif "$DIR/debianseal.sh" update; then
  rm -f "$DIR/.debianopen-session"
else
  echo "Could not seal the VM files: the next debianopen will refuse to boot until you run debianseal accept" >&2
fi
exit "$rc"
LAUNCHER_EOF
  } > "$out"
  chmod 755 "$out"
}

write_verify_expect() { # output
  cat > "$1" <<'EXP_EOF'
#!/usr/bin/expect -f
# Boots the new system through the launcher (seal check), unlocks the LUKS disk,
# logs in as the user, checks a few things (root locked, sudo without a password
# on the console only), enables the first-boot wizard and shuts down.
set timeout 30
match_max 200000
log_user 0
log_file -a $env(DEBIANOPEN_LOG)

proc die {msg} {
    puts stderr "\nERROR: $msg"
    exit 1
}

set pw $env(DEBIANOPEN_PASSWORD)
# Kept out of the environment of QEMU
set luks $env(DEBIANOPEN_LUKS_PW)
unset env(DEBIANOPEN_LUKS_PW)
spawn $env(DEBIANOPEN_START_SCRIPT)

set nudges 0
set logins 0
set unlocks 0
expect {
    -re {INTEGRITY CHECK FAILED} { die "the launcher's integrity check failed (log: $env(DEBIANOPEN_LOG))" }
    -re {Please unlock disk [^\r\n]*: $} {
        incr unlocks
        if {$unlocks > 3} { die "the LUKS passphrase was rejected" }
        # The prompt can appear before echo is off (and the input flushed):
        # typed right away, the passphrase could be echoed into the log
        sleep 1
        send -- "$luks\r"
        exp_continue
    }
    -re {login: $} {
        incr logins
        if {$logins > 3} { die "Debian login failed (password rejected?)" }
        send -- "$env(DEBIANOPEN_USER)\r"
        exp_continue
    }
    -re {Password: $} {
        send -- "$pw\r"
        exp_continue
    }
    # Debian's bash prompt is user@host:~$ (in colour on this terminal)
    -re {@[^\r\n]*\$ $} { }
    timeout {
        incr nudges
        if {$nudges > $env(DEBIANOPEN_BOOT_NUDGES)} { die "Debian boot timed out (log: $env(DEBIANOPEN_LOG))" }
        send "\r"
        exp_continue
    }
    eof { die "QEMU exited; the system did not boot (log: $env(DEBIANOPEN_LOG))" }
}
puts "    - Logged in"; flush stdout

set timeout 60
# Every field is followed by a fixed delimiter: output can arrive in pieces,
# and an unterminated last group would match a partial value
send -- "echo DEBIANOPEN_\$((20+22))_\$(uname -r)_\$(findmnt -n -o SOURCE /boot/efi)_\$(findmnt -n -o FSTYPE /)_\$(sudo -n cryptsetup status cryptroot >/dev/null 2>&1 && echo luks || echo plain)_\$(uname -n)_\$(cat /etc/debian_version)_END\r"
expect {
    -re {DEBIANOPEN_42_([^_\r\n]+)_(/dev/[a-z0-9]+)_([a-z0-9]+)_([a-z]+)_([A-Za-z0-9.-]+)_([0-9.]+)_END} {
        set kver $expect_out(1,string)
        set bootdev $expect_out(2,string)
        set rootfs $expect_out(3,string)
        set crypt $expect_out(4,string)
        set host $expect_out(5,string)
        set debver $expect_out(6,string)
    }
    timeout { die "could not read uname/findmnt output" }
    eof { die "QEMU exited" }
}
puts "    - Debian $debver, kernel: $kver, ESP: $bootdev, root: $rootfs on $crypt, hostname: $host"; flush stdout
if {$host ne $env(DEBIANOPEN_HOSTNAME)} { die "hostname is '$host', expected '$env(DEBIANOPEN_HOSTNAME)'" }
if {$rootfs ne "btrfs"} { die "the root filesystem is '$rootfs', expected btrfs" }
if {$crypt ne "luks"} { die "the root filesystem is not on the LUKS volume (or sudo asked for a password on the console)" }

# Root locked; sudo needs no password here (serial console) but does without a
# terminal, which stands for every other way in (SSH)
send -- "echo DEBIANOPEN_ACC_\$(sudo -n passwd -S root | cut -d' ' -f2)_\$(sudo -n true 2>/dev/null && echo free || echo pw)_\$(setsid -w sudo -n true </dev/null >/dev/null 2>&1 && echo free || echo pw)_END\r"
expect {
    -re {DEBIANOPEN_ACC_([A-Z]*)_([a-z]+)_([a-z]+)_END} {
        set rootpw $expect_out(1,string)
        set console $expect_out(2,string)
        set other $expect_out(3,string)
    }
    timeout { die "could not check root and sudo" }
    eof { die "QEMU exited" }
}
if {$rootpw ne "L"} { die "the root account is not locked (passwd -S: '$rootpw')" }
if {$console ne "free"} { die "sudo asks for a password on the serial console" }
if {$other ne "pw"} { die "sudo does not ask for a password outside the serial console" }
puts "    - root locked, sudo password-free on the console only"; flush stdout

# Kernel updates must reach the ESP: the running kernel is the one kernel-install put
# there (the ESP is readable by root only)
send -- "echo DEBIANOPEN_ESP_\$(sudo -n test -s /boot/efi/\$(cat /etc/machine-id)/\$(uname -r)/linux && echo yes || echo no)_\$(ping -c1 -W5 deb.debian.org >/dev/null 2>&1 && echo net || echo nonet)_END\r"
expect {
    -re {DEBIANOPEN_ESP_([a-z]+)_([a-z]+)_END} {
        set esp $expect_out(1,string)
        set net $expect_out(2,string)
    }
    timeout { die "could not check the ESP" }
    eof { die "QEMU exited" }
}
if {$esp ne "yes"} { die "the running kernel is not in the ESP's kernel-install layout" }
if {$net eq "net"} {
    puts "    - kernel in the ESP, network up"
} else {
    puts "    ! the VM could not reach deb.debian.org (not critical, check the network later)"
}
flush stdout

# sshd (key generation on first boot can take a while)
set ssh_ok 0
for {set i 0} {$i < 90} {incr i} {
    set banner ""
    catch {exec python3 -c {import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.settimeout(3)
sys.stdout.write(s.recv(64).decode("ascii", "ignore"))} $env(DEBIANOPEN_SSH_PORT)} banner
    if {[string match "SSH-2.0*" $banner]} { set ssh_ok 1; break }
    after 2000
}
if {$ssh_ok} {
    puts "    - sshd is answering (127.0.0.1:$env(DEBIANOPEN_SSH_PORT))"
} else {
    puts "    ! sshd did not answer within 3 min (not critical, try again later)"
}
flush stdout

set f [open "$env(DEBIANOPEN_WORK)/kver" w]
puts $f $kver
close $f

# The wizard starts at the next login on the console; that login first asks
# for a new password (the temporary one expires now). One sudo for all of it:
# with the password expired, sudo itself would ask for a new one
send -- "sudo -n sh -c '/usr/local/sbin/debianopen-firstboot --enable && chage -d 0 $env(DEBIANOPEN_USER) && echo DEBIANOPEN_EN_OK_\$((40+2)) && sync && poweroff' || echo DEBIANOPEN_EN_FAIL_\$((40+2))\r"
expect {
    -re {DEBIANOPEN_EN_OK_42} { }
    -re {DEBIANOPEN_EN_FAIL_42} { die "could not enable the first-boot wizard" }
    timeout { die "could not enable the first-boot wizard (timeout)" }
    eof { die "QEMU exited" }
}
puts "    - First-boot wizard enabled, temporary password expired"; flush stdout

set timeout 180
expect {
    eof { }
    timeout { die "Debian did not shut down" }
}
catch {wait}
exit 0
EXP_EOF
}

verify_boot() {
  log "Sealing the VM files (seal stored in the login Keychain)"
  # Drop the NVRAM state left by the installer VM: vars.fd is sealed as a clean
  # template, and every boot runs on a throwaway copy of it
  cp "$FW_VARS" "$INSTALL_DIR/vars.fd"
  write_start_script
  "$INSTALL_DIR/debianseal.sh" update || die "Could not seal the VM files. Is the login Keychain unlocked?"

  # The launcher checks the seal, boots, and seals again after the shutdown
  log "Booting the new system via UEFI and verifying it"
  write_verify_expect "$WORK/verify.exp"
  DEBIANOPEN_LOG="$LOG_FILE" \
  DEBIANOPEN_START_SCRIPT="$INSTALL_DIR/start-uefi.sh" \
  DEBIANOPEN_USER="$DEB_USER" \
  DEBIANOPEN_PASSWORD="$TEMP_USER_PASSWORD" \
  DEBIANOPEN_LUKS_PW="$LUKS_PW" \
  DEBIANOPEN_HOSTNAME="$DEB_HOSTNAME" \
  DEBIANOPEN_SSH_PORT="$SSH_PORT" \
  DEBIANOPEN_WORK="$WORK" \
  DEBIANOPEN_BOOT_NUDGES="${DEBIANOPEN_BOOT_NUDGES:-40}" \
    expect -f "$WORK/verify.exp" || die "Verification boot failed. Log: $LOG_FILE"
  "$INSTALL_DIR/debianseal.sh" verify >/dev/null || die "The VM files were not sealed after the verification boot."
  ok "Seal checked, disk unlocked, login works, root locked, sudo checked, first-boot wizard armed, clean shutdown, sealed again"
}

# The Mac commands live next to the disks and are covered by the seal
install_scripts() {
  install -m 755 "$WORK/debianclose.sh" "$INSTALL_DIR/debianclose.sh"
  install -m 755 "$WORK/debianuninstall.sh" "$INSTALL_DIR/debianuninstall.sh"
  install -m 755 "$WORK/debianseal.sh" "$INSTALL_DIR/debianseal.sh"
}

install_aliases() {
  local rc="$HOME/.zshrc" begin="# >>> debianopen >>>" end="# <<< debianopen <<<"
  touch "$rc"
  if [ ! -f "$rc.debianopen-backup" ]; then
    cp "$rc" "$rc.debianopen-backup"
  fi
  local tmp="$WORK/zshrc.new"
  awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$rc" > "$tmp"
  {
    printf '%s\n' "$begin"
    printf 'alias debianopen=%q\n' "$INSTALL_DIR/start-uefi.sh"
    printf 'alias debianclose=%q\n' "$INSTALL_DIR/debianclose.sh"
    printf 'alias debianuninstall=%q\n' "$INSTALL_DIR/debianuninstall.sh"
    printf 'alias debianseal=%q\n' "$INSTALL_DIR/debianseal.sh"
    printf '%s\n' "$end"
  } >> "$tmp"
  cat "$tmp" > "$rc"
  # shellcheck disable=SC2088
  ok "debianopen, debianclose, debianuninstall, debianseal added to ~/.zshrc (backup: $rc.debianopen-backup)"
}

write_lock() {
  local lock="$INSTALL_DIR/versions.lock"
  {
    echo "# Generated by debianopen-setup.sh: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "alpine_version=$ALPINE_VERSION"
    echo "alpine_iso_sha256=$ALPINE_ISO_SHA256"
    echo "debian_version=$DEBIAN_VERSION ($DEBIAN_SUITE)"
    echo "debian_iso=$DEBIAN_ISO"
    echo "debian_iso_sha256=$DEBIAN_ISO_SHA256"
    echo "apt_mirror=$APT_MIRROR"
    echo "debian_kernel=$(cat "$WORK/kver" 2>/dev/null || echo unknown)"
    echo "hostname=$DEB_HOSTNAME"
    echo "qemu=$("$QEMU_BIN" --version | head -n 1)"
    echo "root_uuid=$ROOT_UUID"
    echo "root_fs=btrfs (subvolumes @ @home @log @pkg) on LUKS2 $LUKS_UUID"
    echo "esp_uuid=$ESP_UUID"
    echo
    echo "# Debian packages (dpkg-query -W)"
    awk '/^DEBIANOPEN_PKGLIST_BEGIN/ { on = 1; next } /^DEBIANOPEN_PKGLIST_END/ { on = 0 } on { gsub(/\033\[[?0-9;]*[a-zA-Z]/, ""); sub(/\r$/, ""); if ($0 ~ /^[^ ]+ [^ ]+$/) print }' "$LOG_FILE"
  } > "$lock"
  ok "Version record: $lock"
}

###############################################################################
# MAIN
###############################################################################
main() {
  printf '\n\033[1mDebian Setup for Mac\033[0m: Debian %s (%s) arm64 on macOS with QEMU\n' "${DEBIAN_VERSION%%.*}" "$DEBIAN_SUITE"
  check_platform
  check_existing
  log "Checking dependencies"
  ensure_deps
  find_firmware
  confirm_plan
  ask_passphrase
  prepare_dirs
  setup_bridge
  write_manifest
  fetch_companions
  get_alpine
  get_debian
  create_images
  run_installer
  install_scripts
  verify_boot
  install_aliases
  write_lock
  rm -f "$INCOMPLETE_MARK"

  printf '\n\033[1;32mInstallation complete.\033[0m\n'
  cat <<EOF

  Open a new terminal (or run: source ~/.zshrc). Commands:

      debianopen        start Debian in this terminal
      debianclose       shut Debian down cleanly (from another Mac terminal)
      debianuninstall   remove what this setup installed, asking item by item
      debianseal        integrity seal of the VM files (debianopen checks it before every boot)

  Every boot      : the seal is checked, then Debian asks for the disk passphrase
  First login     : user ${DEB_USER}, password ${TEMP_USER_PASSWORD}; you set a new password right away.
                    root is locked; sudo needs no password on this console (the
                    terminal running debianopen) and asks for it everywhere else.
                    The first-boot wizard then offers zsh, htop, fastfetch, lsd
                    and the ly login screen.
  SSH             : ssh -p $SSH_PORT ${DEB_USER}@localhost   (also <its address>:22 on your network when bridged)
  Directory       : $INSTALL_DIR
  Version record  : $INSTALL_DIR/versions.lock

EOF
  if [ "${DEBIANOPEN_YES:-0}" != "1" ] && [ -r /dev/tty ]; then
    local ans
    printf 'Start Debian now? [Y/n] ' >/dev/tty
    IFS= read -r ans </dev/tty || ans="n"
    case "$ans" in
      ""|y|Y|yes|Yes)
        LUKS_PW=""
        cleanup
        trap - EXIT
        exec "$INSTALL_DIR/start-uefi.sh" ;;
    esac
  fi
}

main "$@"
