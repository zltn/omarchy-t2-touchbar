# omarchy-t2-touchbar

A working Touch Bar for T2 MacBooks on [Omarchy](https://omarchy.org).

The strip shows your Hyprland workspaces (the active one highlighted in your
theme colour), a clock, battery, mic, night light and update status, plus
buttons for the Omarchy panels. When you open the audio or display panel, the
strip switches to a layer with volume or brightness controls. With an optional
patched `tiny-dfr` those controls are real sliders you can drag.

The Touch Bar is driven by [tiny-dfr](https://github.com/AsahiLinux/tiny-dfr).
This repo adds the layout, an Omarchy shell plugin that keeps it up to date,
and the system setup around it.

## Before you start

You need:

- A T2 MacBook. The installer checks for the T2 chip and asks before
  continuing if it does not find one.
- Omarchy with Hyprland.
- The `tiny-dfr` package. Omarchy adds the t2linux `arch-mact2` repo on T2
  Macs, so the installer can install it with pacman. If `pacman -Si tiny-dfr`
  finds nothing, that repo is missing from `/etc/pacman.conf`
  (`omarchy refresh pacman` removes it). Omarchy's
  `install/hardware/pacman.sh` shows the two lines to add back.

Good to know: Omarchy removes `tiny-dfr` on T2 Macs during one of its
migrations, because the daemon caused problems across suspend. This repo
includes a sleep hook that handles that. The migration only runs once, so
reinstalling the package sticks. If the strip goes blank after an
`omarchy update`, check the package is still installed before anything else.

## Install

```bash
git clone https://github.com/zltn/omarchy-t2-touchbar
cd omarchy-t2-touchbar
./install.sh --dry-run   # shows what it will do
./install.sh
```

The installer:

- installs the layout into `/etc/tiny-dfr`
- installs the systemd units, udev rule, sleep hook, sudoers rule and pacman
  hook
- installs the Hyprland bindings the Touch Bar buttons use
- adds and enables the shell plugin with `omarchy plugin add`
- disables the standalone daemon, since the plugin does that job

It asks for your sudo password. It only does what the dry run lists. You can
run it again any time; it does not break anything that is already set up.

### After install

Usually nothing. Two things to check:

1. Bindings. Hyprland reloads its config when `hyprland.lua` changes, so the
   new bindings should already work. If `SUPER+CTRL+A` opens the audio panel
   but the strip does not change, run `hyprctl reload`.
2. A blank strip. Run `journalctl -u tiny-dfr -b 0`. The usual cause is the
   Touch Bar USB device still in configuration 1 (see Troubleshooting). A
   reboot fixes that if the installer could not switch it live.

### Check it works

```bash
omarchy-shell touchbar status                          # JSON with the current state
journalctl _COMM=quickshell -b 0 | grep io.github.zltn.t2-touchbar    # should print nothing
ls -l /etc/tiny-dfr/config.toml                        # -rw-rw-r-- root <you>
```

Switch workspaces with `SUPER+1..5`. The highlight on the strip should follow
right away. Press `SUPER+CTRL+A`: the strip should switch to the audio layer,
and switch back when the panel closes.

After your first suspend and resume, see [doc/SUSPEND.md](doc/SUSPEND.md) for
how to check the sleep hook ran.

### If you set this up by hand before

Two things clash with the installer:

- Bindings. `hypr/touchbar.lua` has the same `SUPER+CTRL+A`, `SUPER+CTRL+D`,
  `SUPER+CTRL+G` and `SUPER+CTRL+ALT+1..8` bindings you may already have in
  `bindings.lua`. Remove yours first. Hyprland runs duplicate bindings twice,
  and a doubled toggle opens the panel and closes it again.
- The daemon. The installer disables `tiny-dfr-workspace.service`. Leave it
  disabled. Running it next to the plugin means two programs writing the same
  file.

## Optional: real sliders

Stock `tiny-dfr` only has buttons. `patches/tiny-dfr-slider.patch` adds a
`Slider` button type. Dragging it sends the position to a socket, and
`tiny-dfr-slider.service` turns that into volume or brightness.

```bash
./build-tiny-dfr.sh   # clones upstream, applies the patch, builds, installs to /usr/local/bin
./install.sh          # run again so it picks up the new binary
```

The binary goes to `/usr/local/bin` so package updates cannot overwrite it. A
systemd drop-in points `tiny-dfr.service` at it.

Without the patch, the audio and display layers show a row of 25 / 50 / 75 /
100 buttons instead. Everything else is the same.

Important: stock `tiny-dfr` does not report an error when it sees a `Slider`
key. It silently ignores the whole config and falls back to its built-in
layout. That is why the installer writes `SLIDER=0` or `SLIDER=1` to
`touchbar.conf` based on whether the patched binary exists, and the layout is
only rendered with sliders when it is `1`.

## Configure

### The layout

Edit `/etc/tiny-dfr/config.template.toml`. Do not edit `config.toml`; it is
generated from the template and overwritten on every change. You do not need
sudo, and saving the template is enough to redraw the strip.

If the template has a syntax error, `tiny-dfr` says nothing and falls back to
its built-in layout. Check the file before saving:

```bash
python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' \
  /etc/tiny-dfr/config.template.toml
```

### Settings

`/etc/tiny-dfr/touchbar.conf`:

```ini
WORKSPACES=5   # how many workspace buttons to draw
SLIDER=0       # set by install.sh, do not edit
```

### Bindings

Touch Bar buttons can only send key combinations. Every button that does
something is a Hyprland binding in `hypr/touchbar.lua`. The installer copies
it to `~/.config/hypr/touchbar.lua` and adds one `require` line to your
`hyprland.lua`. Uninstall removes both.

`SUPER+CTRL+A` and `SUPER+CTRL+D` are rebound so the panels open through
`tiny-dfr-context`. That is how the strip learns a panel is open; the shell
does not report it. Because of this, opening a panel by clicking its icon in
the bar does not switch the strip. Keyboard and Touch Bar do. Closing works
from anywhere.

### The bar widget

The plugin adds a small keyboard icon to the Omarchy bar (right section by
default; move it with `omarchy bar move`). It dims when `tiny-dfr.service` is
not running. Clicking it restarts the service, without a password. You will
mostly want this after a resume, when the strip can come back blank.

### Status and redraw

```bash
omarchy-shell touchbar status
omarchy-shell touchbar redraw
```

## Troubleshooting

**The strip stopped following the workspace, and the journal is quiet.**
Check the file permissions first:

```bash
ls -l /etc/tiny-dfr/config.toml   # want -rw-rw-r-- root <you>
journalctl _COMM=quickshell -b 0 | grep io.github.zltn.t2-touchbar
```

The plugin runs as you and writes `config.toml` and the icon files in place.
If a file is not writable by you, the plugin logs a warning in the shell
journal and nothing on the strip updates. This happens if the standalone
daemon ran at some point (it used to recreate the files as root), or after a
`tiny-dfr` package update. Fix: run `./install.sh` again, or:

```bash
sudo chown root:$USER /etc/tiny-dfr/config.toml && sudo chmod 0664 /etc/tiny-dfr/config.toml
```

**The strip is blank after resume.** Click the bar widget, or:

```bash
sudo systemctl restart tiny-dfr
```

This is expected sometimes. See [doc/SUSPEND.md](doc/SUSPEND.md) for why.

**The strip shows the Boot Camp layout (F1-F12, no Omarchy buttons).**
The Touch Bar USB device (`05ac:8302`) is in configuration 1. In that mode the
T2 firmware draws its own layout and `tiny-dfr` cannot draw. Configuration 2
gives `tiny-dfr` a framebuffer. The `tiny-dfr` package has a udev rule that
switches it at boot; the installer switches it live. Check with:

```bash
cat /sys/bus/usb/devices/*/bConfigurationValue   # the Touch Bar should say 2
```

**The audio or display layer never appears.** Either the bindings are not
loaded (`hyprctl reload`), or you opened the panel with the mouse (see
Bindings above).

**The battery percentage differs from the bar.** `tiny-dfr` and the Omarchy
bar read different kernel values, and on an older battery they can differ by
around 10 points. This repo does its own calculation and caps it at 100. Not
a bug.

## How it works

`tiny-dfr` draws its layout from `/etc/tiny-dfr/config.toml` once and never
changes it. But it watches that file, and reloads when it changes. So the
plugin shows live state by rewriting the config: it fills in the active
workspace, and swaps icon files for the battery, mic, night light and update
indicators.

The plugin runs inside `omarchy-shell`. The shell already knows the active
workspace, so the plugin just reacts to that. State from other programs (mic
mute, night light, pending updates) comes in as small files that the plugin
watches.

The plugin cannot install anything outside its own folder. That is by design
in Omarchy: plugins are QML loaded into the shell, with no install hooks.
Everything that needs root goes through `install.sh`. Running
`omarchy plugin add` on its own gives you a plugin with nothing to drive.

`bin/tiny-dfr-workspace` is the original standalone daemon. It does the same
job without the shell and is used when you install with `--no-plugin`.
`test/render-test.js` checks that the plugin and the daemon produce exactly
the same output:

```bash
node test/render-test.js
```

## Files

```
manifest.json, Service.qml, BarWidget.qml, lib/   the shell plugin
install.sh, uninstall.sh, build-tiny-dfr.sh       setup scripts
system/                                           files for /etc and /usr/lib
hypr/touchbar.lua                                 Hyprland bindings
bin/                                              daemon and helper scripts
patches/                                          the optional slider patch
test/                                             tests
doc/SUSPEND.md                                    suspend and resume notes
```

## Development notes

Saving a file under `~/.config/omarchy/plugins/` reloads the plugin. That
works for QML changes. It does not work for the `IpcHandler`: the IPC target
stays with the first instance that registered it, so `omarchy-shell touchbar
...` keeps running the old code with no error. If an IPC change seems to do
nothing, restart the shell:

```bash
pkill -x quickshell     # Omarchy starts it again
```

Do not use `omarchy-refresh-shell` for this. It resets `shell.json` and
removes your bar layout.

The plugin is a git checkout of wherever you cloned this repo from.
`omarchy plugin update io.github.zltn.t2-touchbar` pulls from there. If that is a local
clone, commit your changes first.

## Uninstall

```bash
./uninstall.sh            # keeps /etc/tiny-dfr
./uninstall.sh --purge    # removes it too
```

The `tiny-dfr` package and a patched binary in `/usr/local/bin` are left in
place.
