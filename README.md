# omarchy-t2-touchbar

A live Touch Bar for T2 MacBooks running [Omarchy](https://omarchy.org): the
active Hyprland workspace, battery, microphone, night light and pending-update
state, drawn on the strip and kept in sync by the Omarchy shell. Optionally,
real draggable volume and brightness sliders.

It is two halves in one repo, because it has to be:

| Half | What it is | How it installs |
|---|---|---|
| **Plugin** | `manifest.json`, `Service.qml`, `BarWidget.qml`, `lib/` — QML loaded into `omarchy-shell` | `omarchy plugin add`, which `install.sh` runs for you |
| **System** | `tiny-dfr` layout, systemd units, udev rule, sleep hook, sudoers, pacman hook, Hyprland bindings | `install.sh` (needs sudo) |

**The plugin half cannot install the system half.** Omarchy plugins are QML
loaded into the shell process; the manifest schema has no install hook, no
dependency field, and validation refuses symlinks so a plugin cannot reach
outside its own directory. Everything root-owned therefore goes through
`install.sh`. Running `omarchy plugin add` alone gets you a plugin that loads
and does nothing, because there is no `tiny-dfr` for it to drive.

## Install

```bash
git clone https://github.com/<you>/omarchy-t2-touchbar
cd omarchy-t2-touchbar
./install.sh --dry-run   # look first
./install.sh
```

That installs the system half, adds and enables the plugin through
`omarchy plugin add --enable` (so `omarchy plugin update t2.touchbar` works
later), and disables the standalone daemon. It asks for your sudo password;
nothing runs as root that is not listed in the dry run.

**Manual steps — at most two, both at the end:**

1. **Bindings.** Hyprland reloads its config when `hyprland.lua` is saved
   (`misc:disable_autoreload` is off by default), so the new bindings are
   usually live already. If `SUPER+CTRL+A` still opens the plain audio panel
   without switching the strip, run `hyprctl reload`.
2. **If the strip is blank** after the installer's final `systemctl restart
   tiny-dfr`: `journalctl -u tiny-dfr -b 0` says why. The usual cause is the
   USB device still in configuration 1 (see [Gotchas](#gotchas-worth-knowing));
   a reboot applies the package's udev rule if the live switch did not take.

Then check it is alive — see [Verify](#verify) below.

`install.sh` is idempotent — re-run it after a `git pull`, and after
`./build-tiny-dfr.sh`. `--no-plugin` installs the system half only and enables
the standalone Python daemon instead, for a T2 Mac not running omarchy-shell.

The plugin checkout tracks **wherever you cloned this repo from**: from GitHub,
`omarchy plugin update t2.touchbar` pulls GitHub; from a local clone, it pulls
that clone (so commit there first). A plugin dir that is not a git checkout —
copied by hand, or left by an older version of this script — is replaced with
a proper clone; its bar placement is kept, because that lives in `shell.json`.

### Verify

```bash
omarchy-shell touchbar status            # JSON; "workspace" should follow SUPER+1..5
journalctl _COMM=quickshell -b 0 | grep t2.touchbar   # must be empty
ls -l /etc/tiny-dfr/config.toml          # -rw-rw-r-- root <you>
```

Switch workspaces: the pill on the strip should move within ~50 ms. Open the
audio panel with `SUPER+CTRL+A`: the strip should switch to the audio layer and
switch back when the panel closes. After your first suspend/resume, see
[doc/SUSPEND.md](doc/SUSPEND.md) for the two journal checks that tell you
whether the sleep hook ran.

### Migrating from a hand-rolled setup

If you set this up by hand before (following the notes this repo grew out of),
two things collide with the installer:

- **Bindings.** `hypr/touchbar.lua` contains the same `SUPER+CTRL+A/D/G` and
  `SUPER+CTRL+ALT+1..8` bindings you may already have in `bindings.lua`. Remove
  yours first — Hyprland runs duplicate binds twice, and a doubled `toggle`
  opens the panel and closes it again.
- **The daemon.** `install.sh` disables `tiny-dfr-workspace.service` when it
  installs the plugin. That is intended; do not re-enable it alongside.

### Prerequisites

- A T2 MacBook (checked via the `106b:1801`/`106b:1802` PCI id; you are asked
  before continuing if it is missing).
- Hyprland, for the workspace layer.
- The `tiny-dfr` package. Omarchy's installer configures the t2linux
  `arch-mact2` repo on T2 hardware, so `install.sh` just runs
  `pacman -S tiny-dfr`. If that repo is missing (`omarchy refresh pacman`
  drops it), `install/hardware/pacman.sh` in Omarchy shows the two lines.

> **Omarchy actively uninstalls `tiny-dfr` on T2 Macs.** Migration
> `1785944594.sh` runs `omarchy-pkg-drop tiny-dfr` on any machine matching
> `106b:180[12]`, because the daemon held stale device descriptors across
> suspend with `t2bce`. That is a one-off migration, not a blacklist — a
> reinstall sticks until some future migration says otherwise. See
> [doc/SUSPEND.md](doc/SUSPEND.md) for how this repo answers the suspend
> problem. If the strip goes blank after an `omarchy update`, check the package
> still exists before debugging anything else.

### Optional: real sliders

Stock `tiny-dfr` has no slider widget; its buttons can only send key combos.
[`patches/tiny-dfr-slider.patch`](patches/tiny-dfr-slider.patch) adds a
`Slider` button type that reports drag position to a socket, which
`tiny-dfr-slider.service` turns into volume and brightness. Without it the
contextual layers show a stepped 25/50/75/100 row instead — everything else is
identical.

```bash
./build-tiny-dfr.sh   # clones upstream, applies the patch, cargo build, installs to /usr/local/bin
./install.sh          # again: picks up the binary, sets SLIDER=1, installs the drop-in
```

The binary goes to `/usr/local/bin`, which pacman never touches, and a systemd
drop-in points the service at it. The renderer only ever emits a `Slider` key
when `SLIDER=1` is in `touchbar.conf`, which `install.sh` sets from whether that
binary exists — because a stock `tiny-dfr` handed a `Slider` key does not
error, it **silently drops the whole layer** and falls back to its packaged
layout. `test/render-test.js` checks both settings.

## How it works

`tiny-dfr` has no concept of state — every button is drawn once from
`/etc/tiny-dfr/config.toml` and never changes. But it *watches* that file with
inotify and, on a change, reloads and forces a complete redraw. So live state is
shown by regenerating the config.

`Service.qml` renders `config.template.toml` (substituting `@WORKSPACES@` and
`@SLIDER:…@`) and writes it whenever something changes. That is the whole
mechanism.

The plugin replaces a 599-line Python daemon that did the same job. About 250 of
those lines were spent discovering the focused workspace: globbing for
Hyprland's instance signature under `/run/user/*/hypr/`, connecting to
`.socket2.sock`, parsing the event stream, reconnecting when Hyprland restarts.
The shell already tracks all of that, so in QML it is one property binding on
`Hyprland.focusedWorkspace`. State files that the daemon polled (the mic every
100ms) are `FileView`s with `watchChanges`, so they are event-driven instead —
and yes, Quickshell's `FileView` does pick up a file that did not exist when
the watch was armed, and survives it being replaced by rename (tested, see
git history for the harness).

The daemon is still shipped, in `bin/`, for machines without omarchy-shell.
`test/render-test.js` diffs the QML port against it across 120 cases and
requires byte-identical output, so the two cannot drift.

```bash
node test/render-test.js   # exit status is the verdict; don't pipe it into tail
```

### Editing the layout

Edit `/etc/tiny-dfr/config.template.toml` — **never `config.toml`**, which is
generated and overwritten on the next workspace switch. `/etc/tiny-dfr` is
`root:<you>` mode `2775`, so no sudo is needed. Writing the template is enough;
the plugin picks it up via inotify and redraws.

A template that fails to parse is **silently ignored** — `tiny-dfr` falls back
to the packaged layout with nothing in the journal. An empty log is exactly what
a broken config looks like. Validate before saving:

```bash
python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' \
  /etc/tiny-dfr/config.template.toml
```

### Bindings

Touch Bar buttons only send key combos, so every smart button is really a
Hyprland binding. They live in [`hypr/touchbar.lua`](hypr/touchbar.lua), which
`install.sh` copies to `~/.config/hypr/touchbar.lua` and `require`s from your
`hyprland.lua` (one appended line, idempotent, removed by `uninstall.sh`). It
rebinds `SUPER+CTRL+A` and `SUPER+CTRL+D` so the audio/display panels open
*through* `tiny-dfr-context`, which is what lets the strip know a panel is open;
the shell does not expose that over IPC.

### The bar widget

The plugin also puts a small keyboard glyph on the Omarchy bar (right section
by default; move it with `omarchy bar move`). It dims when `tiny-dfr.service`
is not running, and a click restarts the daemon — passwordless, via the
sudoers rule `install.sh` writes. It exists because the strip cannot report
its own death: a stopped daemon and a daemon drawing an all-black layout look
identical from the Touch Bar. Most often needed after a resume; see
[doc/SUSPEND.md](doc/SUSPEND.md).

### Settings

`/etc/tiny-dfr/touchbar.conf`:

```ini
WORKSPACES=5   # yours to change
SLIDER=0       # managed by install.sh
```

Read by both the plugin and the Python fallback, which must agree.

### Status

```bash
omarchy-shell touchbar status
omarchy-shell touchbar redraw
```

## Gotchas worth knowing

**The generated files are written in place, and that is deliberate.**
`tiny-dfr` runs as `nobody`, so everything it reads must stay world-readable. An
in-place write keeps a file's mode; an atomic replace would recreate it under
the writer's umask and could leave a config `nobody` cannot read — which
`tiny-dfr` treats as absent, silently. The cost is that `config.toml` and the
generated SVGs must already be writable by you: `install.sh` creates them
`0664 root:<you>` and the pacman hook restores that after a `tiny-dfr` upgrade.
`Service.qml` warns on the shell's console (journal) if a write fails, because
every other symptom of this is silence:

```bash
journalctl _COMM=quickshell -b 0 | grep t2.touchbar
```

**Do not run the plugin and the daemon together.** Both write `config.toml`.
`install.sh` disables the daemon when it installs the plugin. If you switch by
hand:

```bash
sudo systemctl disable --now tiny-dfr-workspace.service
```

**The Touch Bar USB device has two configurations.** `05ac:8302` boots in
`bConfigurationValue=1`, a single HID interface where the T2 firmware draws its
own fixed Boot Camp layouts. Configuration 2 exposes the class-`0x10` interface
`appletbdrm` binds to, which is what gives `tiny-dfr` a framebuffer. The
package's udev rule does this on `add`; `install.sh` nudges an
already-enumerated device.

**`tiny-dfr` cannot display live status by itself.** `ButtonConfig` supports
only `Icon`, `Text`, `Time` and `Battery` — there is no exec widget and no tray.
Everything live here works by regenerating the config.

**Battery reads differently in two places.** On x86_64 `tiny-dfr` computes
`charge_now/charge_full` while the Omarchy bar uses the kernel's `capacity`;
on a worn cell those disagree by ~10 points. This repo computes its own, clamped
to 100 (the raw ratio reports 101% on a cell whose `charge_full` has drifted).
Not a bug to fix.

**Opening a panel by clicking its bar icon does not switch the layer.** Only
the keybinding and the Touch Bar button route through `tiny-dfr-context`.
Closing works from anywhere. A shell IPC that exposed the open panel would
remove this limitation; until then it is inherent.

## Layout

```
manifest.json  Service.qml  BarWidget.qml  lib/    the plugin (repo root)
install.sh  uninstall.sh  build-tiny-dfr.sh         the system half
system/                                             files installed to /etc, /usr/lib
hypr/touchbar.lua                                   the Hyprland bindings
bin/                                                daemons and helpers
patches/                                            the optional slider patch
test/                                               JS-vs-Python differential test
doc/SUSPEND.md                                      the suspend story
```

## Developing on it

Saving a file under `~/.config/omarchy/plugins/` hot-reloads the plugin, and for
QML changes that is enough. **It is not enough for `IpcHandler`.** The target is
claimed by whichever instance registered it first, so after a hot reload
`omarchy-shell touchbar ...` still reaches the *old* instance and silently runs
the old code — the shell says nothing, and the call returns normally. If an IPC
change appears to have no effect, restart the shell rather than debugging the
code:

```bash
pkill -x quickshell     # omarchy-launch-shell respawns it
```

(`omarchy-refresh-shell` is **not** a restart: it resets `shell.json` to
defaults and wipes your bar layout.)

## Running the daemon and the plugin on the same machine

They can coexist (not simultaneously — see above — but one after the other),
because both now write `0664` in the setgid `/etc/tiny-dfr`. That is a fix, not
an accident: the daemon writes tmp-file + `os.replace()`, which *recreates*
`config.toml` each time, and at the old `0644` a single daemon run left the file
unwritable by the group and permanently locked the plugin out. The plugin writes
in place and cannot chmod its way back out, so it would just stop updating the
strip — silently. `bin/tiny-dfr-workspace` sets `FILE_MODE = 0o664` for exactly
this reason.

If the strip stops following the workspace, check this first:

```bash
ls -l /etc/tiny-dfr/config.toml    # want: -rw-rw-r-- root <you>
```

## Uninstall

```bash
./uninstall.sh            # leaves /etc/tiny-dfr alone
./uninstall.sh --purge    # removes it too
```
