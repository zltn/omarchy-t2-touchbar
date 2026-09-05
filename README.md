# omarchy-t2-touchbar

A live Touch Bar for T2 MacBooks running [Omarchy](https://omarchy.org): the
active Hyprland workspace, battery, microphone, night light and pending-update
state, drawn on the strip and kept in sync by the Omarchy shell.

It is two halves in one repo, because it has to be:

| Half | What it is | How it installs |
|---|---|---|
| **Plugin** | `manifest.json`, `Service.qml`, `BarWidget.qml`, `lib/` — QML loaded into `omarchy-shell` | `omarchy plugin add`, or `install.sh` |
| **System** | `tiny-dfr` layout, systemd units, udev rules, sleep hook, sudoers, pacman hook | `install.sh` (needs sudo) |

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
omarchy plugin enable t2.touchbar
```

`install.sh` is idempotent, so re-run it after an update. `--no-plugin` installs
the system half only and enables the standalone Python daemon instead, for a T2
Mac not running omarchy-shell.

### Prerequisites

- A T2 MacBook (checked via the `106b:1801`/`106b:1802` PCI id; you are asked
  before continuing if it is missing).
- The `tiny-dfr` package, from the t2linux `arch-mact2` repo. It is not in the
  AUR and the repo is usually not in `pacman.conf`, so this is normally a
  `pacman -U` of the package file.
- Hyprland, for the workspace layer.

> **Omarchy actively uninstalls `tiny-dfr` on T2 Macs.** Migration
> `1785944594.sh` runs `omarchy-pkg-drop tiny-dfr` on any machine matching
> `106b:180[12]`, because the daemon held stale device descriptors across
> suspend with `t2bce`. See [doc/SUSPEND.md](doc/SUSPEND.md) for how this repo
> answers that. If the strip goes blank after an `omarchy update`, check the
> package still exists before debugging anything else.

## How it works

`tiny-dfr` has no concept of state — every button is drawn once from
`/etc/tiny-dfr/config.toml` and never changes. But it *watches* that file with
inotify and, on a change, reloads and forces a complete redraw. So live state is
shown by regenerating the config.

`Service.qml` renders `config.template.toml` (substituting `@WORKSPACES@`) and
writes it whenever something changes. That is the whole mechanism.

The plugin replaces a 599-line Python daemon that did the same job. About 250 of
those lines were spent discovering the focused workspace: globbing for
Hyprland's instance signature under `/run/user/*/hypr/`, connecting to
`.socket2.sock`, parsing the event stream, reconnecting when Hyprland restarts.
The shell already tracks all of that, so in QML it is one property binding on
`Hyprland.focusedWorkspace`. State files that the daemon polled (the mic every
100ms) are `FileView`s with `watchChanges`, so they are event-driven instead.

The daemon is still shipped, in `bin/`, for machines without omarchy-shell.
`test/render-test.js` diffs the QML port against it across 104 cases and
requires byte-identical output, so the two cannot drift.

```bash
node test/render-test.js
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

### Settings

`/etc/tiny-dfr/touchbar.conf`:

```ini
WORKSPACES=5
```

Read by both the plugin and the Python fallback, which must agree — the layout
draws this many buttons and `tiny-dfr-ws-icons` paints exactly this many pills.

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
`Service.qml` warns on the shell's console if a write fails, because every other
symptom of this is silence.

**Do not run the plugin and the daemon together.** Both write `config.toml`;
running both means two writers racing and double the full-panel redraws. If you
enable the plugin, disable the daemon:

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
Everything live here works by regenerating the config. Buttons can only
*trigger* actions, via key combos Hyprland binds.

**Battery reads differently in two places.** On x86_64 `tiny-dfr` computes
`charge_now/charge_full` while the Omarchy bar uses the kernel's `capacity`;
on a worn cell those disagree by ~10 points. This repo computes its own, clamped
to 100 (the raw ratio reports 101% on a cell whose `charge_full` has drifted).
Not a bug to fix.

## Layout

```
manifest.json      Service.qml  BarWidget.qml  lib/     the plugin (repo root)
install.sh  uninstall.sh                                the system half
system/                                                 files installed to /etc, /usr/lib
bin/                                                    daemons and helpers
test/                                                   JS-vs-Python differential test
doc/SUSPEND.md                                          the suspend story
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
omarchy-restart-shell   # or: pkill -x quickshell   (the launcher respawns it)
```

A quick way to tell which instance answered: add a field to `status` and see
whether it appears.

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
