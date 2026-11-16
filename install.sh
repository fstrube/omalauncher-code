#!/usr/bin/env bash
#
# omalauncher-code — install the desktop VS Code as a window in Omalauncher.
#
# Downloads the official VS Code Linux arm64 build from Microsoft, unpacks it
# to /opt/vscode-code, and installs the things that make it usable on a phone: a
# launcher wrapper (Wayland flags, project quirks), a drawer entry, settings for
# a phone-sized window, and two small patches to VS Code's own JavaScript (its
# minimum window size, and its editor type menu) — plus the checksum VS Code
# records for the patched file, so it does not report the install as corrupt.
# Nothing is redistributed: every run fetches VS Code from
# update.code.visualstudio.com itself.
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
  # Not read from $0: under `curl … | bash` that is "bash", not this file.
  cat <<'USAGE'
omalauncher-code — install the desktop VS Code as a window in Omalauncher.

  curl -fsSL https://raw.githubusercontent.com/fstrube/omalauncher-code/main/install.sh | bash
  ./install.sh --version 1.146.0     pin a build instead of the latest stable
  ./install.sh --dry-run             say what would happen, change nothing
  ./install.sh --no-deps             don't let pacman install missing libraries
  ./install.sh --uninstall           remove the program, keep your settings
USAGE
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

# Only the headings carry colour: a step in blue, the closing banner in green.
# What a step found, and what it would do, is plain default text — the eye can
# then find the next step by scanning for blue instead of reading every line.
step() { printf '\n%s==> %s%s\n' "$blue" "$*" "$out_reset"; }
note() { printf '    %s\n' "$*"; }
ok() { printf '%s    %s%s\n' "$green" "$*" "$out_reset"; }
success() { printf '\n%s==> %s%s\n' "$green" "$*" "$out_reset"; }

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
  cat <<'EOF'
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

step "Installing the launcher wrapper, patches and settings"
if ! $DRY; then
  mkdir -p "$LIB" "$(dirname "$ICON")" "$(dirname "$DESKTOP")"
fi

# Two things in VS Code misbehave in a phone window. Both are fixed by editing
# its own JavaScript, since no setting reaches them:
#
# 1. It hardcodes a 400x270dp minimum window size. In landscape with the soft
#    keyboard open the launcher asks a window for 1200x39dp; Chromium clamps that
#    to the minimum, the buffer ends up taller than the space it was given, and
#    the launcher draws it scaled down into the corner. A lower minimum makes the
#    window match what the compositor asks for, so it stays full width.
# 2. Tapping the editor type menu (the › at the right end of the breadcrumbs,
#    the one that switches a file between Text Editor and Markdown Preview)
#    refocuses the editor, because the title bar's "a click in here returns
#    focus to the editor" check knows about the action bar and the breadcrumb
#    items but not about that new button. The menu is open by then, so it loses
#    focus to the editor and closes at once — it flashes for a frame. Teaching
#    the check about the button keeps the focus in the menu.
#
# VS Code also keeps a checksum of that second file in product.json and, at every
# start, warns that the installation "appears to be corrupt" when it no longer
# matches — which is exactly what editing the file does. So the patch also
# records the new checksum: the file is not corrupt, it is patched, and the
# check should say so.
write_patch_helper() {
  cat <<'PATCH'
#!/bin/sh
# Patch VS Code's own JavaScript for a phone window, and keep the checksum it
# records for the patched file in step (see install.sh in omalauncher-code).
# Takes the VS Code directory. Each patch is a fixed string replacement that is a
# no-op once it has been applied. If VS Code has moved that code the patch cannot
# apply: the others still do, the message names the one that is missing, and the
# exit status is non-zero.
set -e
dir=${1:-/opt/vscode-code}
failed=""

# 1. Lower the hardcoded minimum window size. The second pattern is what the
#    previous build's line looked like; both map to the same smaller minimum.
js=$dir/resources/app/out/mainImpl.js
if [ ! -f "$js" ]; then
  echo "minimum window size: no $js" >&2
  failed=yes
elif ! grep -q 'bb={WIDTH:160,WIDTH_WITH_VERTICAL_PANEL:240,HEIGHT:20}' "$js"; then
  sed -i \
    -e 's/bb={WIDTH:400,WIDTH_WITH_VERTICAL_PANEL:600,HEIGHT:270}/bb={WIDTH:160,WIDTH_WITH_VERTICAL_PANEL:240,HEIGHT:20}/' \
    -e 's/bb={WIDTH:240,WIDTH_WITH_VERTICAL_PANEL:360,HEIGHT:120}/bb={WIDTH:160,WIDTH_WITH_VERTICAL_PANEL:240,HEIGHT:20}/' \
    "$js"
  grep -q 'bb={WIDTH:160,WIDTH_WITH_VERTICAL_PANEL:240,HEIGHT:20}' "$js" || {
    echo "minimum window size: pattern not found, update the patterns in $0" >&2
    failed=yes
  }
fi

# 2. Keep the focus in the editor type menu instead of handing it back to the
#    editor, which closes the menu the moment it opens.
wb=$dir/resources/app/out/vs/workbench/workbench.desktop.main.js
if [ ! -f "$wb" ]; then
  echo "editor type menu: no $wb" >&2
  failed=yes
elif ! grep -q 'dm(n,"breadcrumbs-editor-type",this.titleContainer)' "$wb"; then
  sed -i 's/dm(n,"monaco-breadcrumb-item",this.titleContainer)||setTimeout/dm(n,"monaco-breadcrumb-item",this.titleContainer)||dm(n,"breadcrumbs-editor-type",this.titleContainer)||setTimeout/' "$wb"
  grep -q 'dm(n,"breadcrumbs-editor-type",this.titleContainer)' "$wb" || {
    echo "editor type menu: pattern not found, update the patterns in $0" >&2
    failed=yes
  }
fi

# base64 of the sha256 of a file, the form VS Code records its checksums in
# (see step 3). Padded here; the caller strips the padding.
file_checksum() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -binary "$1" | base64 -w0
  elif command -v base64 >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1 | xxd -r -p | base64 -w0
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import base64,hashlib,sys;sys.stdout.write(base64.b64encode(hashlib.sha256(open(sys.argv[1],"rb").read()).digest()).decode())' "$1"
  fi
}

# 3. VS Code compares workbench.desktop.main.js against the checksum it shipped
#    in product.json, at every start, and warns that the installation "appears to
#    be corrupt" when they differ. Patching the file makes them differ, so record
#    the patched file's checksum — in the form VS Code stores it (sha256, base64,
#    without padding).
wb_rel=vs/workbench/workbench.desktop.main.js
product=$dir/resources/app/product.json
if [ ! -f "$wb" ]; then
  : # already reported above
elif [ ! -f "$product" ]; then
  echo "installation checksum: no $product" >&2
  failed=yes
elif ! sum=$(file_checksum "$wb") || [ -z "$sum" ]; then
  echo "installation checksum: need openssl, xxd or python3 to hash $wb" >&2
  failed=yes
else
  sum=$(printf '%s' "$sum" | tr -d '=')
  recorded=$(sed -n "s#^[[:space:]]*\"$wb_rel\": \"\([^\"]*\)\".*#\1#p" "$product")
  if [ -n "$recorded" ] && [ "$recorded" != "$sum" ]; then
    sed -i "s#\"$wb_rel\": \"$recorded\"#\"$wb_rel\": \"$sum\"#" "$product"
    recorded=$(sed -n "s#^[[:space:]]*\"$wb_rel\": \"\([^\"]*\)\".*#\1#p" "$product")
    [ "$recorded" = "$sum" ] || {
      echo "installation checksum: could not record it in $product" >&2
      failed=yes
    }
  fi
  # A build that lists no checksum for the file has nothing to keep in step.
fi

[ -z "$failed" ] || exit 1
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

# Belt and braces: re-apply the patches in case the tree was replaced outside
# install.sh (which already patched it), such as someone unpacking a new tarball
# over /opt by hand. Normally a no-op: the helper exits after two greps. If a
# patch can no longer apply, the editor still starts — with too small a minimum
# window, or a menu that closes as it opens — so say that out loud instead of
# failing silently.
if [ -x /usr/lib/omalauncher-code/patch-vscode ]; then
  if ! why=$(/usr/lib/omalauncher-code/patch-vscode "$VSCODE_DIR" 2>&1); then
    failure="VS Code patch failed: ${why:-unknown error}"
    log=$VSCODE_USER_DATA/patch-failures.log
    printf '%s %s\n' "$(date -Is 2>/dev/null || echo '?')" "$failure" \
      >> "$log" 2>/dev/null || true
    printf 'omalauncher-code: %s (logged to %s)\n' "$failure" "$log" >&2
    # A toast on the phone: the window has no room for one this early, and the
    # log only helps someone who thinks to look.
    if command -v omalauncher >/dev/null 2>&1; then
      omalauncher notify "VS Code" "A patch did not apply: reinstall omalauncher-code. Until then the window may be too small in landscape with the keyboard open, and the editor type menu may close as soon as it opens." >/dev/null 2>&1 || true
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
# which is worse than the two things these patches fix — and the wrapper warns
# about exactly those at every start.
apply_patch() {
  local err
  if ! err=$("$LIB/patch-vscode" "$1" 2>&1); then
    warn "a patch did not apply: ${err:-unknown error}"
    warn "installing anyway. The editor still runs, but the window can be too small in landscape with the keyboard open, the editor type menu (the › at the end of the breadcrumbs) can close as soon as it opens, and VS Code may warn that the installation was modified. The launcher wrapper warns again, and notifies the phone, at every start."
  fi
}

if $DRY; then
  note "would install: $BIN (wrapper)"
  note "would install: $LIB/patch-vscode (minimum window size and editor type menu patches, and VS Code's checksum for the patched file)"
  note "would install: $LIB/settings.default.json (settings, first run only), $DESKTOP, $ICON"
else
  write_patch_helper > "$LIB/patch-vscode"
  chmod 755 "$LIB/patch-vscode"
  # Installs before 1.0.1 shipped this patch as its own helper.
  rm -f "$LIB/patch-min-size"
  write_wrapper > "$BIN"
  chmod 755 "$BIN"
  write_settings > "$LIB/settings.default.json"
  chmod 644 "$LIB/settings.default.json"
fi

step "Applying the phone patches to the new build"
if $DRY; then
  note "would patch mainImpl.js and vs/workbench/workbench.desktop.main.js in $DEST/resources/app/out, and record the new checksum of the latter in product.json"
else
  apply_patch "$STAGE"
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
cat <<EOF

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
