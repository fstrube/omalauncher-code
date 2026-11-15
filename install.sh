#!/usr/bin/env bash
#
# omalauncher-code — install the desktop VS Code as a window in Omalauncher.
#
# Downloads the official VS Code Linux arm64 build from Microsoft, unpacks it
# to /opt/vscode-code, and installs the three things that make it usable on a
# phone: a launcher wrapper (Wayland flags, project quirks), a drawer entry, and
# an in-window dialog patch. Nothing is redistributed: every run fetches VS Code
# from update.code.visualstudio.com itself.
#
#   curl -fsSL https://raw.githubusercontent.com/fstrube/omalauncher-code/main/install.sh | bash
#   ./install.sh --version 1.146.0     pin a build instead of the latest stable
#   ./install.sh --dry-run             say what would happen, change nothing
#   ./install.sh --uninstall           remove the program, keep your settings
#
# Omalauncher's Linux runs under proot as root; this script expects the same.

set -euo pipefail

VSCODE_VER=${VSCODE_VER:-latest}

DEST=/opt/vscode-code
STAGE=/opt/.vscode-code.new
LIB=/usr/lib/omalauncher-code
BIN=/usr/bin/omalauncher-code
ICON=/usr/share/icons/vscode.png
DESKTOP=/usr/share/applications/omalauncher-code.desktop

# What the Electron build links against, plus wayland-utils: the wrapper asks it
# for the compositor's scale, which it must match or the window won't fill.
DEPENDS=(gtk3 nss libxtst libxss alsa-lib libnotify libsecret libdrm mesa
         fontconfig libxkbfile wayland-utils)

DRY=false
NO_DEPS=false
UNINSTALL=false
tmp=""

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

cleanup() {
  [ -n "$tmp" ] && rm -rf "$tmp"
  return 0
}
trap cleanup EXIT

# Colour, per stream: what the install says goes to stdout, what can go wrong to
# stderr, and each is coloured only when that stream is a terminal and colour is
# wanted (NO_COLOR, TERM=dumb). Warnings never stop the install: a VS Code that
# opens is better than none, and the wrapper repeats the warning (and notifies
# the phone) at every start.
colors_off() { [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ]; }
if [ -t 1 ] && ! colors_off; then
  blue=$'\033[34m'
  green=$'\033[32m'
  out_reset=$'\033[0m'
else
  blue=""
  green=""
  out_reset=""
fi
if [ -t 2 ] && ! colors_off; then
  yellow=$'\033[33m'
  red=$'\033[31m'
  err_reset=$'\033[0m'
else
  yellow=""
  red=""
  err_reset=""
fi

die() {
  printf '%somalauncher-code: %s%s\n' "$red" "$*" "$err_reset" >&2
  exit 1
}

warn() {
  printf '%somalauncher-code: warning: %s%s\n' "$yellow" "$*" "$err_reset" >&2
}

# A step in blue, what it found indented in blue, the good news in green.
step() { printf '\n%s==> %s%s\n' "$blue" "$*" "$out_reset"; }
note() { printf '%s    %s%s\n' "$blue" "$*" "$out_reset"; }
ok() { printf '%s    %s%s\n' "$green" "$*" "$out_reset"; }
success() { printf '\n%s==> %s%s\n' "$green" "$*" "$out_reset"; }

# The closing prose (where things live, what to do next) is information too, so
# it is blue as a block; with colour off it prints exactly as before.
info_block() { printf '%s' "$blue"; cat; printf '%s' "$out_reset"; }

# Runs a command, or only says it when --dry-run.
do_() {
  if $DRY; then
    note "would run: $*"
  else
    "$@"
  fi
}

while [ $# -gt 0 ]; do
  case $1 in
    --version)   VSCODE_VER=${2:-}; [ -n "$VSCODE_VER" ] || die "--version needs a version"; shift 2 ;;
    --version=*) VSCODE_VER=${1#*=}; shift ;;
    --no-deps)   NO_DEPS=true; shift ;;
    --dry-run)   DRY=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help)   usage 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
done

# Empty when there is no install yet (a --dry-run on a fresh phone), and never
# fatal: sed exits 2 for a missing file, and this runs under pipefail + -e.
installed_version() {
  [ -f "$DEST/resources/app/package.json" ] || return 0
  sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$DEST/resources/app/package.json" | head -1 || true
}

# --- uninstall -------------------------------------------------------------

if $UNINSTALL; then
  step "Removing omalauncher-code"
  for path in "$DEST" "$LIB" "$BIN" "$ICON" "$DESKTOP"; do
    if [ -e "$path" ]; then
      do_ rm -rf "$path"
    fi
  done
  success "Done"
  info_block <<'EOF'
Your settings and extensions are yours, so they are still there:
  ~/.local/share/code-gui   settings, window state, workspace storage
  ~/.vscode/extensions      installed extensions
Delete those two directories to remove every trace of VS Code.
EOF
  exit 0
fi

# --- checks ----------------------------------------------------------------

step "Checking this device"

[ "$(id -u)" -eq 0 ] || die "run as root (Omalauncher's Linux is root under proot)"
[ "$(uname -m)" = aarch64 ] || die "only aarch64 phones are supported, this is $(uname -m)"
for tool in curl tar sed grep; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is missing"
done
ok "arch, root and tools: ok"

if pgrep -f "$DEST/code" >/dev/null 2>&1; then
  die "VS Code is running; close its window and run this again"
fi

# --- dependencies ----------------------------------------------------------

step "Checking dependencies"

if ! $NO_DEPS && command -v pacman >/dev/null 2>&1; then
  missing=()
  for pkg in "${DEPENDS[@]}"; do
    pacman -Q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    note "missing: ${missing[*]}"
    # Not fatal: the editor works without libxss/libnotify, and a stale sync db
    # shouldn't stop the install. wayland-utils only affects scale detection.
    do_ pacman -S --needed --noconfirm "${missing[@]}" ||
      note "pacman could not install them; run pacman -Syu and try again"
  else
    ok "all present"
  fi
else
  note "skipped (--no-deps or no pacman), VS Code needs: ${DEPENDS[*]}"
fi

# --- the build -------------------------------------------------------------

step "Downloading VS Code ${VSCODE_VER} (arm64)"
if $DRY; then
  note "would download: https://update.code.visualstudio.com/$VSCODE_VER/linux-arm64/stable"
else
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/omalauncher-code.XXXXXX")
  url="https://update.code.visualstudio.com/${VSCODE_VER}/linux-arm64/stable"
  # A bar on a terminal, a quiet one-liner when piped into bash.
  if [ -t 2 ]; then curl_args=(-fL --progress-bar); else curl_args=(-fsSL); fi
  curl "${curl_args[@]}" -o "$tmp/vscode.tar.gz" "$url" || die "download failed: $url"
  size=$(du -h "$tmp/vscode.tar.gz" | cut -f1)
  ok "downloaded $size"
  tar -tzf "$tmp/vscode.tar.gz" >/dev/null 2>&1 || die "the download is not a tarball"

  step "Unpacking to $STAGE"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  tar -xzf "$tmp/vscode.tar.gz" -C "$STAGE" --strip-components=1
  [ -x "$STAGE/code" ] || die "the tarball has no code binary"
  [ -f "$STAGE/resources/app/package.json" ] || die "the tarball has no resources/app/package.json"
fi

# --- the fixes -------------------------------------------------------------

step "Installing the launcher wrapper, patch and settings"
if ! $DRY; then
  mkdir -p "$LIB" "$(dirname "$ICON")" "$(dirname "$DESKTOP")"
fi

# VS Code hardcodes a 400x270dp minimum window size. In landscape with the soft
# keyboard open the launcher asks a window for 1200x39dp; Chromium clamps that to
# the minimum, the buffer ends up taller than the space it was given, and the
# launcher draws it scaled down into the corner. Lowering the minimum makes the
# window match what the compositor asks for, so it stays full width.
write_patch_helper() {
  cat <<'PATCH'
#!/bin/sh
# Lower VS Code's hardcoded minimum window size (see install.sh in
# omalauncher-code). Exits non-zero, changing nothing, if the size moved:
# the alternate string you can pass as the second argument is what the
# previous pattern looked like once patched.
set -e
file=${1:-/opt/vscode-code/resources/app/out/mainImpl.js}
[ -f "$file" ] || { echo "patch-min-size: no $file" >&2; exit 1; }
grep -q 'bb={WIDTH:160,WIDTH_WITH_VERTICAL_PANEL:240,HEIGHT:20}' "$file" && exit 0
sed -i \
  -e 's/bb={WIDTH:400,WIDTH_WITH_VERTICAL_PANEL:600,HEIGHT:270}/bb={WIDTH:160,WIDTH_WITH_VERTICAL_PANEL:240,HEIGHT:20}/' \
  -e 's/bb={WIDTH:240,WIDTH_WITH_VERTICAL_PANEL:360,HEIGHT:120}/bb={WIDTH:160,WIDTH_WITH_VERTICAL_PANEL:240,HEIGHT:20}/' \
  "$file"
grep -q 'bb={WIDTH:160,WIDTH_WITH_VERTICAL_PANEL:240,HEIGHT:20}' "$file" || {
  echo "patch-min-size: VS Code moved its minimum window size; update the patterns in $0" >&2
  exit 1
}
PATCH
}

write_wrapper() {
  cat <<'WRAPPER'
#!/usr/bin/env bash
# Launch the desktop VS Code (Electron) as a Wayland window inside Omalauncher.
# Installed by omalauncher-code's install.sh; re-running that overwrites this.
set -euo pipefail

VSCODE_DIR=${VSCODE_DIR:-/opt/vscode-code}
VSCODE_USER_DATA=${VSCODE_USER_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/code-gui}

# VS Code verifies downloaded extensions with a .NET binary (vsce-sign). Under
# proot CoreCLR cannot size its GC heap ("GC heap initialization failed with
# error 0x8007000E") and every install fails with "cannot verify the extension
# signature ... UnknownError". A hard limit makes CoreCLR reserve less and start.
export DOTNET_GCHeapHardLimit=0x4000000

# The compositor configures windows in surface logical pixels, so Chromium must
# render at exactly the output's scale: any other factor draws a buffer that
# does not cover the surface and leaves wallpaper at the edges. Ask the
# compositor; VSCODE_SCALE overrides, 2 is the fallback when the socket or tool
# is missing. Text size is a separate matter, window.zoomLevel in the settings.
scale=${VSCODE_SCALE:-}
if [ -z "$scale" ] && command -v wayland-info >/dev/null 2>&1; then
  # wayland-info prints one wl_output block per display: "x: 0, y: 0, scale: 2,"
  scale=$(timeout 3 wayland-info 2>/dev/null |
          sed -n 's/.*scale: *\([0-9][0-9]*\).*/\1/p' | sort -n | tail -1) || true
fi
scale=${scale:-2}

# First run only: settings that suit a phone window. Never overwrites yours.
settings=$VSCODE_USER_DATA/User/settings.json
if [ ! -e "$settings" ] && [ -r /usr/lib/omalauncher-code/settings.default.json ]; then
  mkdir -p "$VSCODE_USER_DATA/User"
  cp /usr/lib/omalauncher-code/settings.default.json "$settings"
fi

# Belt and braces: re-apply the minimum window size in case the tree was
# replaced outside install.sh (which already patched it), such as someone
# unpacking a new tarball over /opt by hand. Normally a no-op: the helper exits
# after one grep. If it can no longer apply, the editor still starts but won't
# fill the screen in landscape with the keyboard open, so say that out loud
# instead of failing silently.
main_js=$VSCODE_DIR/resources/app/out/mainImpl.js
if [ -x /usr/lib/omalauncher-code/patch-min-size ]; then
  if ! why=$(/usr/lib/omalauncher-code/patch-min-size "$main_js" 2>&1); then
    failure="minimum window size patch failed: ${why:-unknown error}"
    log=$VSCODE_USER_DATA/patch-failures.log
    printf '%s %s\n' "$(date -Is 2>/dev/null || echo '?')" "$failure" \
      >> "$log" 2>/dev/null || true
    printf 'omalauncher-code: %s (logged to %s)\n' "$failure" "$log" >&2
    # A toast on the phone: the window has no room for one this early, and the
    # log only helps someone who thinks to look.
    if command -v omalauncher >/dev/null 2>&1; then
      omalauncher notify "VS Code" "Minimum window size patch failed: reinstall omalauncher-code. Until then the window may not fill the screen in landscape with the keyboard open." >/dev/null 2>&1 || true
    fi
  fi
fi

args=(
  --no-sandbox                     # proot has no user namespaces, and this is root
  --disable-gpu-sandbox
  --disable-dev-shm-usage           # /dev/shm is a bind from phone storage
  --ozone-platform=wayland
  --enable-features=WaylandWindowDecorations
  --user-data-dir="$VSCODE_USER_DATA"
  --force-device-scale-factor="$scale"
  --disable-workspace-trust         # no dialog on the first open of a folder
  # No --start-maximized or --window-size: the launcher gives every window its
  # own Android task and sizes it there; a remembered size only fights it.
)

# $VSCODE_DIR/code, not bin/code: bin/code re-execs the editor, and the
# launcher's per-app proot kills the app when the process it started exits.
exec "$VSCODE_DIR/code" "${args[@]}" "$@"
WRAPPER
}

write_settings() {
  cat <<'SETTINGS'
{
  // The window is rendered at the phone's display scale (2 on most), so text at
  // the default size would be twice as large as on a desktop. -1 is 0.83x of that.
  "window.zoomLevel": -1,
  // Every Wayland toplevel becomes its own Android task in the launcher, so a
  // native dialog (a second toplevel) opens on a screen of its own instead of
  // over the editor. These two keep dialogs inside the window it already has:
  // file and folder pickers ask with the quick input box, and message boxes
  // are drawn by VS Code rather than GTK.
  "files.simpleDialog.enable": true,
  "window.dialogStyle": "custom",
  // The window has its own close button; a menu bar only eats a phone's width.
  "window.menuBarVisibility": "hidden",
  "editor.minimap.enabled": false,
  // Let VS Code tell you when a new build exists. These Linux builds have no
  // self-update: the menu item opens the download page, and updating is this
  // installer's job.
  "update.mode": "default"
}
SETTINGS
}

# Best effort, on purpose: a build whose patch no longer applies is still a
# working editor. Failing here would leave the phone with no VS Code at all,
# which is worse than a window that doesn't fill the screen in landscape with
# the keyboard open — and the wrapper warns about exactly that at every start.
apply_patch() {
  local err
  if ! err=$("$LIB/patch-min-size" "$1" 2>&1); then
    warn "the minimum window size patch did not apply: ${err:-unknown error}"
    warn "installing anyway. In landscape with the keyboard open the window may not fill the screen; the launcher wrapper warns about this again, and notifies the phone, at every start."
  fi
}

if $DRY; then
  note "would install: $BIN (wrapper)"
  note "would install: $LIB/patch-min-size (minimum window size patch)"
  note "would install: $LIB/settings.default.json (settings, first run only), $DESKTOP, $ICON"
else
  write_patch_helper > "$LIB/patch-min-size"
  chmod 755 "$LIB/patch-min-size"
  write_wrapper > "$BIN"
  chmod 755 "$BIN"
  write_settings > "$LIB/settings.default.json"
  chmod 644 "$LIB/settings.default.json"
fi

step "Applying the minimum window size to the new build"
if $DRY; then
  note "would patch $DEST/resources/app/out/mainImpl.js"
else
  apply_patch "$STAGE/resources/app/out/mainImpl.js"
fi

step "Replacing $DEST"
do_ rm -rf "$DEST"
if $DRY; then
  note "would move $STAGE into place"
else
  mv "$STAGE" "$DEST"
fi

step "Installing the drawer entry"
if $DRY; then
  note "would write $DESKTOP"
else
  cp "$DEST/resources/app/resources/linux/code.png" "$ICON"
  chmod 644 "$ICON"
  cat > "$DESKTOP" <<DESKTOP_FILE
[Desktop Entry]
Type=Application
Name=VS Code
GenericName=Code Editor
Comment=Visual Studio Code, the real desktop editor, as a window
Exec=$BIN %F
Icon=$ICON
StartupWMClass=Code
StartupNotify=true
Categories=Development;TextEditor;
Keywords=code;editor;vscode;
MimeType=text/plain;text/x-python;application/json;text/markdown;text/html;text/css;application/javascript;text/x-csrc;
DESKTOP_FILE
  chmod 644 "$DESKTOP"
fi

# --- done ------------------------------------------------------------------

version=$(installed_version)
success "Done: VS Code ${version:-$VSCODE_VER} in $DEST"
info_block <<EOF

Open "VS Code" from the drawer, or run: omalauncher-code [folder]
The first launch takes about 20 seconds.

Not happy with the size of things? window.zoomLevel in
  ~/.local/share/code-gui/User/settings.json
Wrong scale (window drawn small, wallpaper showing at the edges)? Start it as
  VSCODE_SCALE=3 omalauncher-code
to see the density the launcher expects.

Updating: run this script again (add --version to pin a build).
Removing: ./install.sh --uninstall — your settings and extensions stay.
EOF
