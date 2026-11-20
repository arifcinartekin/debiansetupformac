#!/usr/bin/env bash
#
# debianopen-firstboot - first-boot wizard inside the Debian VM
#
# Installed by debianopen-setup.sh as /usr/local/sbin/debianopen-firstboot. The
# installer has already created your user (sudo group), locked root and made
# sudo password-free on the serial console. The wizard starts by itself at
# your first login on the console (through sudo) and:
#
#   1) Optionally runs zsh_setup.sh for you (zsh, Oh My Zsh, Powerlevel10k)
#   2) Optionally installs htop, fastfetch with an `info` alias that also
#      runs at every login, and lsd (ls, ll, la, lt use it)
#   3) Optionally sets up the ly login screen on the console
#   4) Removes its own login hook
#
# Ctrl+C aborts; it runs again at the next login on the console.
#
# Usage:
#   sudo debianopen-firstboot              run the wizard
#   sudo debianopen-firstboot --enable     run it at the next login on the console
#   sudo debianopen-firstboot --disable    do not run it at login anymore
#   sudo debianopen-firstboot --login-screen ly|console
#                                          ly login screen, or the plain console login
#
set -euo pipefail

HOOK="/etc/profile.d/debianopen-firstboot.sh"
CONF="/etc/debianopen.conf"
INFO_BEGIN="# >>> debianopen info >>>"
INFO_END="# <<< debianopen info <<<"
LSD_BEGIN="# >>> debianopen lsd >>>"
LSD_END="# <<< debianopen lsd <<<"
ZSH_SETUP="/usr/local/share/debianopen/zsh_setup.sh"
TEMP_SUDOERS="/etc/sudoers.d/99-debianopen-firstboot"
# The serial console the Mac terminal is attached to (console=ttyAMA0)
CONSOLE_TTY="ttyAMA0"
LY_CONFIG="/etc/ly/config.ini"
SHELL_SESSION="/usr/local/bin/debianopen-shell-session"
LY_WRAPPER="/usr/local/sbin/debianopen-ly"
export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------------------
# Software Debian 12 does not ship. Only upstream's own builds and sources,
# pinned by sha256, mirrored unchanged as a GitHub release of debiansetupformac
# (fetched from there first, from upstream otherwise).
# ----------------------------------------------------------------------------
EXTRAS_TAG="firstboot-tools-1"
# fastfetch: upstream's own Debian package (Debian has it from 13 on)
FASTFETCH_VERSION="2.71.0"
FASTFETCH_DEB="fastfetch-${FASTFETCH_VERSION}-linux-aarch64.deb"
FASTFETCH_SHA256="ee894a030fb6fecc5151ebe83ce55c9c72966fd1c708ee6be23af448c0a5f149"
FASTFETCH_URL="https://github.com/fastfetch-cli/fastfetch/releases/download/${FASTFETCH_VERSION}/fastfetch-linux-aarch64.deb"
# ly: not packaged by Debian; built from upstream's source (the version Arch
# Linux ARM ships), with upstream's vendored Zig dependencies and Zig itself
LY_VERSION="1.4.1"
LY_COMMIT="afb1dc62a0568743c9a7952623ec179128c73340"
LY_SRC="ly-${LY_VERSION}.tar.gz"   # git archive of tag v1.4.1 (that commit)
LY_SRC_SHA256="8e0c83d93d904f10157aff410dbef8d3985773821e266c0f219d5a44c3553f67"
LY_GIT="https://codeberg.org/fairyglade/ly.git"
LY_VENDOR="ly-${LY_VERSION}-vendor.tar.zst"
LY_VENDOR_SHA256="0e90692bb89c6fc47ebe3c04812deea4fdd58a0f19b20f308312540a34362752"
LY_VENDOR_URL="https://codeberg.org/fairyglade/ly/releases/download/v${LY_VERSION}/vendor.tar.zst"
ZIG_VERSION="0.16.0"
ZIG_TARBALL="zig-aarch64-linux-${ZIG_VERSION}.tar.xz"
ZIG_SHA256="ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"
# Needed to build ly; removed again afterwards unless they were there before
LY_BUILD_DEPS=(libc6-dev libpam0g-dev)

NEW_USER=""
DO_ZSH=1
DO_HTOP=1
DO_FASTFETCH=1
DO_LSD=1
DO_LY=1

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
log()  { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# conf_get <key> <default>: a value the installer recorded in /etc/debianopen.conf
conf_get() {
  local v=""
  [ -r "$CONF" ] && v="$(awk -F= -v k="$1" '$1 == k { print $2; exit }' "$CONF")"
  printf '%s' "${v:-$2}"
}
SSH_PORT="$(conf_get DEBIANOPEN_SSH_PORT 2224)"
EXTRAS_URL="https://github.com/$(conf_get DEBIANOPEN_REPO arifcinartekin/debiansetupformac)/releases/download/$EXTRAS_TAG"

# ----------------------------------------------------------------------------
# Login hook: /etc/profile.d is read by bash login shells. Debian's zsh does
# not read /etc/profile, so /etc/zsh/zprofile gets one line that does.
# ----------------------------------------------------------------------------

remove_hook() { rm -f "$HOOK"; }

enable_hook() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
  cat > "$HOOK" <<HOOK_EOF
# debianopen first-boot wizard: removed by the wizard once it has run.
# Interactive login shells on the serial console only (sudo needs no password there)
case "\$-" in
  *i*)
    if [ "\$(id -u)" -ne 0 ] && [ "\$(tty 2>/dev/null)" = "/dev/$CONSOLE_TTY" ] \\
       && [ -x /usr/local/sbin/debianopen-firstboot ]; then
      sudo /usr/local/sbin/debianopen-firstboot && exit
    fi
    ;;
esac
HOOK_EOF
  chmod 644 "$HOOK"
  if [ -f /etc/zsh/zprofile ] && ! grep -qF "$HOOK" /etc/zsh/zprofile; then
    printf '\n# debianopen first-boot wizard (does nothing once it has run)\n[ -r %s ] && emulate sh -c ". %s"\n' "$HOOK" "$HOOK" >> /etc/zsh/zprofile
  fi
}

# ----------------------------------------------------------------------------
# Wizard
# ----------------------------------------------------------------------------

ask_yes_no() { # question default(y|n)
  local ans hint="[Y/n]"
  [ "$2" = "n" ] && hint="[y/N]"
  while :; do
    printf '%s %s ' "$1" "$hint"
    IFS= read -r ans || ans=""
    case "${ans:-$2}" in
      y|Y|yes|Yes) return 0 ;;
      n|N|no|No)   return 1 ;;
    esac
  done
}

BUILD_DIR=""
cleanup() {
  rm -f "$TEMP_SUDOERS"
  [ -z "$BUILD_DIR" ] || rm -rf "$BUILD_DIR"
}

on_interrupt() {
  printf '\n'
  warn "Aborted. The wizard will start again at the next login on the console."
  exit 130
}

# The user the wizard sets things up for: the one the installer created
find_user() {
  NEW_USER="$(conf_get DEBIANOPEN_USER "${SUDO_USER:-}")"
  [ -n "$NEW_USER" ] && [ "$NEW_USER" != root ] || die "no user to set up; run it with sudo as your user"
  id "$NEW_USER" >/dev/null 2>&1 || die "user $NEW_USER does not exist"
}

ask_questions() {
  if [ -f "$ZSH_SETUP" ]; then
    ask_yes_no "Set up zsh + Oh My Zsh + Powerlevel10k for $NEW_USER?" y && DO_ZSH=1 || DO_ZSH=0
  else
    DO_ZSH=0
  fi
  ask_yes_no "Install htop (interactive process viewer)?" y && DO_HTOP=1 || DO_HTOP=0
  ask_yes_no "Install fastfetch (system info, 'info' command, shown at every login)?" y && DO_FASTFETCH=1 || DO_FASTFETCH=0
  ask_yes_no "Install lsd (ls with colors and icons; ls, ll, la, lt use it)?" y && DO_LSD=1 || DO_LSD=0
  ask_yes_no "Use the ly login screen instead of the plain console login?" y && DO_LY=1 || DO_LY=0
}

run_zsh_setup() {
  [ "$DO_ZSH" = 1 ] || return 0
  log "zsh setup for $NEW_USER"
  # With zsh already the login shell, zsh_setup.sh does not need to call chsh
  if [ -x /usr/bin/zsh ]; then
    usermod -s /usr/bin/zsh "$NEW_USER"
  fi
  # zsh_setup.sh calls sudo for apt; no password prompts while it runs
  local tmp
  tmp="$(mktemp)"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$tmp"
  if visudo -cf "$tmp" >/dev/null; then
    install -m 0440 -o root -g root "$tmp" "$TEMP_SUDOERS"
  fi
  rm -f "$tmp"

  # The serial console reports vt220; the Mac terminal behind it handles more
  case "${TERM:-}" in
    ""|dumb|vt100|vt220|linux) export TERM=xterm-256color ;;
  esac
  echo "  The Powerlevel10k configuration wizard starts at the end."
  if su -l "$NEW_USER" -c "sh $ZSH_SETUP"; then
    ok "zsh setup finished"
  else
    warn "zsh setup did not finish; run it later as $NEW_USER: sh $ZSH_SETUP"
  fi
  rm -f "$TEMP_SUDOERS"
}

# fetch_pinned <file> <sha256> <url>...: downloads <file> into BUILD_DIR from
# the mirror, then the given URLs, and keeps it only if the sha256 matches
fetch_pinned() {
  local name="$1" sha="$2" out url
  shift 2
  out="$BUILD_DIR/$name"
  for url in "$EXTRAS_URL/$name" "$@"; do
    rm -f "$out"
    curl -fsSL --retry 3 --connect-timeout 20 -o "$out" "$url" 2>/dev/null || continue
    if [ "$(sha256sum "$out" | awk '{ print $1 }')" = "$sha" ]; then
      return 0
    fi
    warn "$name from $url does not match the pinned sha256, ignored"
  done
  rm -f "$out"
  return 1
}

make_build_dir() {
  [ -n "$BUILD_DIR" ] || BUILD_DIR="$(mktemp -d /var/tmp/debianopen-firstboot.XXXXXX)"
}

install_fastfetch() {
  make_build_dir
  if ! fetch_pinned "$FASTFETCH_DEB" "$FASTFETCH_SHA256" "$FASTFETCH_URL"; then
    warn "could not download fastfetch $FASTFETCH_VERSION"
    return 1
  fi
  apt-get install -y -q "$BUILD_DIR/$FASTFETCH_DEB" || return 1
  ok "fastfetch $FASTFETCH_VERSION (upstream's Debian package)"
}

# Builds ly from source with Zig and installs it to /usr/bin/ly, /etc/ly,
# /etc/pam.d/ly and ly@.service. No X11 support: there is no X server here.
build_ly() {
  local src zig newdeps=() p
  make_build_dir
  log "Building ly $LY_VERSION from source (takes a minute or two)"
  for p in "${LY_BUILD_DEPS[@]}"; do
    dpkg-query -W -f '${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || newdeps+=("$p")
  done
  if [ "${#newdeps[@]}" -gt 0 ]; then
    apt-get install -y -q --no-install-recommends "${newdeps[@]}" >/dev/null || { warn "could not install ${newdeps[*]}"; return 1; }
  fi

  fetch_pinned "$ZIG_TARBALL" "$ZIG_SHA256" "$ZIG_URL" || { warn "could not download Zig $ZIG_VERSION"; return 1; }
  tar -xJf "$BUILD_DIR/$ZIG_TARBALL" -C "$BUILD_DIR"
  zig="$BUILD_DIR/${ZIG_TARBALL%.tar.xz}/zig"

  src="$BUILD_DIR/ly-$LY_VERSION"
  if fetch_pinned "$LY_SRC" "$LY_SRC_SHA256"; then
    tar -xzf "$BUILD_DIR/$LY_SRC" -C "$BUILD_DIR"
  else
    # Upstream's git, checked against the pinned commit
    git clone -q --depth 1 --branch "v$LY_VERSION" "$LY_GIT" "$src" 2>/dev/null \
      && [ "$(git -C "$src" rev-parse HEAD)" = "$LY_COMMIT" ] \
      || { warn "could not get ly $LY_VERSION (commit $LY_COMMIT)"; return 1; }
  fi
  fetch_pinned "$LY_VENDOR" "$LY_VENDOR_SHA256" "$LY_VENDOR_URL" || { warn "could not download ly's vendored dependencies"; return 1; }
  # zig-pkg/: the dependencies, so the build needs no network
  tar --zstd -xf "$BUILD_DIR/$LY_VENDOR" -C "$src"

  if ! (cd "$src" && ZIG_GLOBAL_CACHE_DIR="$BUILD_DIR/zig-cache" ZIG_LOCAL_CACHE_DIR="$BUILD_DIR/zig-local" \
        "$zig" build installexe -Doptimize=ReleaseSafe -Dinit_system=systemd -Denable_x11_support=false) \
        > "$BUILD_DIR/build.log" 2>&1; then
    tail -n 20 "$BUILD_DIR/build.log" >&2
    warn "building ly failed"
    return 1
  fi
  systemctl daemon-reload
  if [ "${#newdeps[@]}" -gt 0 ]; then
    apt-get purge -y -q --autoremove "${newdeps[@]}" >/dev/null || true
  fi
  [ -x /usr/bin/ly ] || { warn "ly was not installed"; return 1; }
  ok "ly $LY_VERSION built and installed"
}

install_tools() {
  local pkgs=()
  [ "$DO_HTOP" = 1 ] && pkgs+=(htop)
  [ "$DO_LSD" = 1 ] && pkgs+=(lsd)
  if [ "${#pkgs[@]}" -gt 0 ] || [ "$DO_FASTFETCH" = 1 ] || [ "$DO_LY" = 1 ]; then
    log "Packages: ${pkgs[*]:-}$([ "$DO_FASTFETCH" = 1 ] && echo " fastfetch")$([ "$DO_LY" = 1 ] && echo " ly")"
    apt-get update -q >/dev/null || warn "apt-get update failed"
  fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    if apt-get install -y -q "${pkgs[@]}"; then
      ok "installed: ${pkgs[*]}"
    else
      warn "apt-get failed; install them later with: sudo apt install ${pkgs[*]}"
    fi
  fi
  if [ "$DO_FASTFETCH" = 1 ]; then
    install_fastfetch || warn "fastfetch was not installed"
  fi
}

# append_block <file> <begin> <end> <text>: replaces that debianopen block in a file of the user
append_block() {
  local file="$1" begin="$2" end="$3" tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$file" > "$tmp"
  fi
  printf '%s\n%s\n%s\n' "$begin" "$4" "$end" >> "$tmp"
  install -m 0644 -o "$NEW_USER" -g "$(id -gn "$NEW_USER")" "$tmp" "$file"
  rm -f "$tmp"
}

# user_rc_files: sets USER_RC and USER_PROFILE for the user's login shell
user_rc_files() {
  local home
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  if [ "$(getent passwd "$NEW_USER" | cut -d: -f7)" = /usr/bin/zsh ]; then
    USER_RC="$home/.zshrc"
    # .zprofile runs before .zshrc, so the output does not upset Powerlevel10k's instant prompt
    USER_PROFILE="$home/.zprofile"
  else
    USER_RC="$home/.bashrc"
    # Debian's ~/.profile reads ~/.bashrc; a ~/.bash_profile would replace it
    USER_PROFILE="$home/.profile"
  fi
}

setup_info() {
  [ "$DO_FASTFETCH" = 1 ] && command -v fastfetch >/dev/null 2>&1 || return 0
  log "'info' command"
  user_rc_files
  append_block "$USER_RC" "$INFO_BEGIN" "$INFO_END" "alias info='fastfetch'"
  append_block "$USER_PROFILE" "$INFO_BEGIN" "$INFO_END" \
    '[ -t 1 ] && command -v fastfetch >/dev/null 2>&1 && fastfetch'
  ok "'info' runs fastfetch; it also runs at every login ($(basename "$USER_PROFILE"))"
}

setup_lsd() {
  [ "$DO_LSD" = 1 ] && command -v lsd >/dev/null 2>&1 || return 0
  log "lsd aliases"
  user_rc_files
  # Appended after zsh_setup has written .zshrc, so these win over Oh My Zsh's ll/la
  append_block "$USER_RC" "$LSD_BEGIN" "$LSD_END" "$(printf '%s\n' \
    "alias ls='lsd'" \
    "alias ll='lsd -l'" \
    "alias la='lsd -la'" \
    "alias lt='lsd --tree'")"
  ok "ls, ll, la, lt use lsd ($(basename "$USER_RC"))"
}

# ----------------------------------------------------------------------------
# Login screen (ly on the serial console)
# ----------------------------------------------------------------------------

# ly_set <option> <value>: one option of ly's config.ini
ly_set() {
  if grep -q "^$1 = " "$LY_CONFIG"; then
    sed -i "s|^$1 = .*|$1 = $2|" "$LY_CONFIG"
  else
    warn "ly has no option '$1' (newer version?), skipped"
  fi
}

configure_ly() {
  [ -f "$LY_CONFIG" ] || { warn "$LY_CONFIG not found, is ly installed?"; return 1; }
  # A serial line has no keyboard LEDs and no backlight; there is no X server
  ly_set hide_keyboard_locks true
  ly_set brightness_down_key null
  ly_set brightness_up_key null
  ly_set xinitrc null
  ly_set clock '%a %d %b  %H:%M'
  ly_set bigclock en
  # ly would send the shell's output to this log instead of the terminal
  ly_set session_log null

  # A serial console has no size (0x0) until debianopen-winsize hands it the
  # Mac terminal's, and ly aborts on a 0x0 screen. The size only sticks while
  # the console is open, so a wrapper sets 80x24 on its own stdin (the console)
  # and then becomes ly; debianopen-winsize corrects it within two seconds.
  # Restart: should ly ever exit, the console must not stay empty
  cat > "$LY_WRAPPER" <<'WRAPPER_EOF'
#!/bin/sh
# Starts ly on the serial console with a usable size (debianopen)
case "$(stty size 2>/dev/null)" in
  ""|"0 "*|*" 0") stty rows 24 cols 80 2>/dev/null ;;
esac
exec /usr/bin/ly "$@"
WRAPPER_EOF
  chmod 755 "$LY_WRAPPER"
  mkdir -p /etc/systemd/system/ly@.service.d
  cat > /etc/systemd/system/ly@.service.d/debianopen.conf <<DROPIN_EOF
[Service]
ExecStart=
ExecStart=$LY_WRAPPER
Restart=always
RestartSec=1
DROPIN_EOF
  systemctl daemon-reload

  # The session to log into: your login shell, in this terminal
  cat > "$SHELL_SESSION" <<'SESSION_EOF'
#!/bin/sh
# Shell session for ly on the serial console (debianopen). ly sends a session's
# output to a log file, which suits graphical sessions; a shell needs the terminal.
exec >/dev/tty 2>&1
printf '\033[H\033[2J'
exec "${SHELL:-/bin/bash}" -l
SESSION_EOF
  chmod 755 "$SHELL_SESSION"
  mkdir -p /etc/ly/custom-sessions
  cat > /etc/ly/custom-sessions/shell.desktop <<SESSION_EOF
[Desktop Entry]
Name=Shell
Comment=Your login shell in this terminal
Exec=$SHELL_SESSION
Type=Application
SESSION_EOF
}

# login_screen ly|console: what greets you on the console from the next boot on
login_screen() {
  case "$1" in
    ly)
      [ -x /usr/bin/ly ] || build_ly || return 1
      configure_ly || return 1
      # The console getty comes from a generator (console=ttyAMA0): mask, not disable
      systemctl enable "ly@$CONSOLE_TTY.service" >/dev/null 2>&1 || return 1
      systemctl mask "serial-getty@$CONSOLE_TTY.service" >/dev/null 2>&1 \
        || { systemctl disable "ly@$CONSOLE_TTY.service" >/dev/null 2>&1; return 1; }
      ;;
    console)
      systemctl disable "ly@$CONSOLE_TTY.service" >/dev/null 2>&1 || true
      systemctl unmask "serial-getty@$CONSOLE_TTY.service" >/dev/null 2>&1 || die "could not unmask serial-getty@$CONSOLE_TTY"
      ;;
    *) die "usage: sudo debianopen-firstboot --login-screen ly|console" ;;
  esac
}

# Swaps the console over right away. This ends the session on the console, so
# it runs outside it, from systemd
switch_console() { # ly|console
  local stop="ly@$CONSOLE_TTY.service" start="serial-getty@$CONSOLE_TTY.service"
  if [ "$1" = ly ]; then
    stop="serial-getty@$CONSOLE_TTY.service" start="ly@$CONSOLE_TTY.service"
  fi
  systemd-run --quiet --no-block --collect /bin/sh -c "sleep 1; systemctl stop $stop; systemctl start $start" >/dev/null
}

setup_login_screen() {
  [ "$DO_LY" = 1 ] || return 0
  log "Login screen"
  if login_screen ly; then
    LY_OK=1
    ok "ly greets you on the console from now on (back to the plain login: sudo debianopen-firstboot --login-screen console)"
  else
    warn "ly could not be set up; the plain console login stays"
  fi
}

set_login_screen() { # ly|console, from the command line
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
  trap cleanup EXIT
  login_screen "$1"
  if [ -t 0 ] && [ "$(tty 2>/dev/null)" = "/dev/$CONSOLE_TTY" ]; then
    echo "Login screen: $1, from the next boot on."
    ask_yes_no "Switch the console now? This ends this console session." n && switch_console "$1"
  else
    switch_console "$1"
    echo "Login screen: $1. The console has switched over."
  fi
}

run_wizard() {
  [ "$(id -u)" -eq 0 ] || die "run it with sudo: sudo debianopen-firstboot"
  [ -t 0 ] || die "a terminal is required"
  find_user

  trap cleanup EXIT
  trap on_interrupt INT TERM

  printf '\n%sWelcome to Debian %s (%s), %s%s\n' "$C_B" "$(cat /etc/debian_version 2>/dev/null)" "$(uname -n)" "$NEW_USER" "$C_0"
  printf 'This one-time setup installs a few optional tools.\n'
  printf 'Press Ctrl+C to skip it for now.\n\n'

  LY_OK=0
  ask_questions
  install_tools
  run_zsh_setup
  setup_info
  setup_lsd
  setup_login_screen
  remove_hook

  printf '\n%sDone.%s\n' "$C_B" "$C_0"
  printf '  SSH from the Mac    : ssh -p %s %s@localhost\n' "$SSH_PORT" "$NEW_USER"
  printf '  root                : locked; sudo works without a password on this console only\n'
  printf '  Shut down           : debianclose (on the Mac) or sudo poweroff\n\n'
  if [ "$LY_OK" = 1 ]; then
    printf 'Press Enter to go to the login screen. '
    IFS= read -r _ || true
    switch_console ly
  else
    printf 'Press Enter to log out. '
    IFS= read -r _ || true
  fi
}

case "${1:-}" in
  --enable)  enable_hook ;;
  --disable) [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; remove_hook ;;
  --login-screen) set_login_screen "${2:-}" ;;
  "")        run_wizard ;;
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)         die "unknown option: $1 (help: --help)" ;;
esac
