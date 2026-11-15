# omalauncher-code

The real desktop **Visual Studio Code** as a window in
[Omalauncher](https://github.com/SimonSchubert/omalauncher) — the full editor
with the integrated terminal, extensions, IntelliSense and debugging, not a
web IDE. It fills the screen in portrait and landscape, keeps typing usable with
the soft keyboard open, and draws its dialogs inside the window instead of
opening another Android screen.

```sh
curl -fsSL https://raw.githubusercontent.com/fstrube/omalauncher-code/main/install.sh | bash
```

Or clone and run it, which is the same thing but lets you read it first:

```sh
git clone https://github.com/fstrube/omalauncher-code
cd omalauncher-code && ./install.sh
```

Then open **VS Code** from the app drawer, or run `omalauncher-code [folder]`
in a terminal. The first launch takes about 20 seconds.

Requires an arm64 phone with Omalauncher's Linux (Arch Linux ARM under proot).
The script downloads VS Code from Microsoft's own update server, so this
repository contains no Microsoft binaries.

## What it installs

| path | what |
| --- | --- |
| `/opt/vscode-code` | the official `linux-arm64` build, unpacks to ~1 GB |
| `/usr/bin/omalauncher-code` | wrapper: the Wayland and proot flags VS Code needs here |
| `/usr/lib/omalauncher-code/settings.default.json` | copied to your settings on first run only |
| `/usr/lib/omalauncher-code/patch-min-size` | lowers VS Code's minimum window size |
| `/usr/share/applications/omalauncher-code.desktop` | the drawer entry |
| `/usr/share/icons/vscode.png` | its icon |

and nothing else. Your settings live in `~/.local/share/code-gui`, your
extensions in `~/.vscode/extensions`; neither is touched by an update or an
uninstall.

## Why these flags and patches

Omalauncher is a Wayland compositor that gives every window its own Android
task, and its Linux runs under proot as root. That needs four things, all of
which the wrapper does for you:

- **`--no-sandbox` and `--disable-gpu-sandbox`**: proot has no user namespaces,
  and `--no-sandbox` as root is what makes Chromium start at all.
- **`--ozone-platform=wayland`, `--enable-features=WaylandWindowDecorations`**:
  a real Wayland client, so the launcher can size and tile the window.
- **`--force-device-scale-factor=<the output's scale>`**: the compositor
  configures windows in surface logical pixels, so Chromium must render at
  exactly that scale; any other factor draws a buffer that doesn't cover the
  surface and leaves wallpaper at the edges. The wrapper reads the scale from
  `wayland-info` and falls back to 2. Text is then sized with
  `window.zoomLevel` in the settings, not with the scale factor.
- **the minimum window size patch**: VS Code hardcodes a 400×270 dp minimum. In
  landscape with the soft keyboard open the launcher asks a window for
  1200×39 dp — the keyboard and its key bar leave almost nothing. Chromium
  clamps that to the minimum, the buffer ends up far taller than the space it was
  given, and the launcher draws it scaled down into the corner. Lowering the
  minimum makes the window match what the compositor asks for, so it stays full
  width. The patch is applied at install time and re-applied on every launch,
  and it says so out loud if a later build moves that code — a line on stderr,
  a line in `~/.local/share/code-gui/patch-failures.log`, and a notification on
  the phone, because the symptom is otherwise invisible until you open the
  keyboard in landscape.

`DOTNET_GCHeapHardLimit` is set too: VS Code verifies extensions with a .NET
tool that can't size its heap under proot, which otherwise makes every extension
install fail with "cannot verify the extension signature ... UnknownError".

The settings written on first run keep dialogs in the window: the launcher turns
every toplevel window into its own task, so a GTK dialog would open as a second
Android screen. `files.simpleDialog.enable` makes file, folder and save pickers
use VS Code's own quick input box, and `window.dialogStyle: "custom"` makes
message boxes and About draw in the editor. VS Code's update check stays on
(`update.mode: "default"`), so you're told when a newer build exists; applying
it is the installer's job, as below.

## Options

```
./install.sh                 latest stable
./install.sh --version 1.146.0
./install.sh --dry-run       say what would happen, change nothing
./install.sh --no-deps       don't let pacman install missing libraries
./install.sh --uninstall     remove the program, keep settings and extensions
```

Re-running it is how you update by hand, and it is safe to run twice: the new
build is downloaded and patched next to the old one and only then swapped in,
and it refuses to touch a running window.

## Updating

VS Code checks Microsoft's update server and tells you when a newer build
exists — but these Linux builds cannot install it: the update service ends up
calling `openExternal` on the download page, and there is no download, no
restart, no in-place swap (`updateService.linux.doDownloadUpdate` in
`resources/app/out/mainImpl.js`). Updating is the installer's job:

```sh
close the window, then: ./install.sh
```

That takes a couple of minutes, keeps your settings and extensions, applies the
minimum window size to the new tree, and warns in yellow if that patch no
longer applies — it installs anyway, since an editor that opens is better than
none, and the wrapper repeats the warning at every start.

The patch is also re-applied by the wrapper at every start, so a tree replaced
by hand — a tarball unpacked over `/opt/vscode-code` — is fixed at the next
launch. If a new build moves the code the patch touches, the wrapper can't fix
it: the window still opens, but in landscape with the keyboard open it may not
fill the screen. That is what the notification and
`~/.local/share/code-gui/patch-failures.log` are for, and reinstalling is the
fix.

To keep VS Code from checking at all, set `"update.mode": "none"` in
`~/.local/share/code-gui/User/settings.json`, or `"manual"` to check only when
you ask.

## Using it on a phone

- Tap is a click, long press a right click, drag scrolls. Apps with touch support
  (foot, GTK) get real touch; the editor itself doesn't, as on any desktop.
- The soft keyboard works, including with the window in landscape. If the
  terminal's key bar gets in the way, hide the key bar in the launcher's
  terminal settings.
- **Super+W** closes the window. The launcher keeps it in Recents like any app.
- Menus are hidden; the command palette (`Ctrl+Shift+P`) and the activity bar
  cover them. `Ctrl+O` and `Ctrl+S` ask in the window.

### Known limits

A few things are genuinely separate windows, and the launcher still gives each
its own Android task: **Developer Tools** (`Ctrl+Shift+I`), **New Window**, an
extension that creates its own window, and the Electron crash dialog. Only the
launcher can change that (it would have to embed transient windows instead of
opening a task); popups, menus and completion lists are already drawn inside the
window and are fine.

## Troubleshooting

**The window is drawn small, wallpaper showing at the edges.** The scale factor
doesn't match the compositor. Run `wayland-info | grep scale` and start VS Code
with `VSCODE_SCALE=<that number> omalauncher-code`.

**Text is too big or too small.** `window.zoomLevel` in
`~/.local/share/code-gui/User/settings.json`. -1 suits a scale-2 phone.

**It launches and immediately disappears.** Something is reading
`bin/code` instead of `/opt/vscode-code/code`; the launcher's proot kills the
app when the process it started exits. Use `omalauncher-code`.

**Extension installs fail with a signature error.** The wrapper must have set
`DOTNET_GCHeapHardLimit`; check you're starting it through `omalauncher-code`.

**A notification says the minimum window size patch failed.** A newer build
moved the code the patch touches, so `install.sh` warned and installed it
anyway. The window may not fill the screen in landscape with the keyboard open;
the error is in `~/.local/share/code-gui/patch-failures.log`, and a patched
release or an update to the patterns in
`/usr/lib/omalauncher-code/patch-min-size` is the fix.

**Nothing in the drawer.** `/usr/share/applications/omalauncher-code.desktop`
must exist and `Exec=` must point at `/usr/bin/omalauncher-code`.

## License

The installer is MIT, see [LICENSE](LICENSE). Visual Studio Code itself is
Microsoft's, under
[its own license](https://code.visualstudio.com/license); this project
downloads it from Microsoft and adds a local patch, and ships no part of it.
AUR's `visual-studio-code-bin` does the same thing for regular Arch.
