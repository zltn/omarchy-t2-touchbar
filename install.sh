#!/bin/bash
# Install the system half of the T2 Touch Bar stack, then the shell plugin.
#
# The Omarchy plugin (manifest.json + Service.qml, at the root of this repo)
# only draws the layout. Everything the layout depends on -- the tiny-dfr
# daemon, /etc/tiny-dfr, the systemd units, the udev rules, the sleep hook --
# is root-owned and cannot be shipped by the plugin system, which by design
# copies a git checkout into ~/.config/omarchy/plugins and loads QML from it.
# That is what this script is for.
#
#   ./install.sh              install everything
#   ./install.sh --no-plugin  system half only, driven by the standalone daemon
#   ./install.sh --dry-run    print what would change and exit
#
# Safe to re-run: every step is idempotent. Re-run after ./build-tiny-dfr.sh.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
WITH_PLUGIN=1
WORKSPACES="${WORKSPACES:-5}"
PLUGIN_ID=io.github.zltn.t2-touchbar

while (( $# > 0 )); do
  case "$1" in
    --dry-run)   DRY=1; shift ;;
    --no-plugin) WITH_PLUGIN=0; shift ;;
    -h|--help)   sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# The invoking user, not root: this is who ends up owning /etc/tiny-dfr's group
# so the layout can be edited without sudo, and whose session runs the units.
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n $TARGET_HOME ]] || { echo "cannot resolve home for $TARGET_USER" >&2; exit 1; }

say()  { printf '\033[1;34m==\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

run() {
  if (( DRY )); then printf '   would: %s\n' "$*"; else "$@"; fi
}

# Substitute @USER@ and install in one step, so the templated files never touch
# disk in their untemplated form.
install_templated() {
  local src="$1" dest="$2" mode="${3:-0644}"
  if (( DRY )); then
    printf '   would: install %s -> %s (mode %s, @USER@=%s)\n' "$src" "$dest" "$mode" "$TARGET_USER"
    return
  fi
  sudo install -Dm"$mode" /dev/stdin "$dest" \
    < <(sed "s/@USER@/$TARGET_USER/g" "$src")
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

say "Checking this is a T2 Mac"
if ! lspci -nn 2>/dev/null | grep -qiE '106b:180[12]'; then
  warn "No Apple T2 controller (106b:1801/1802) found on the PCI bus."
  warn "This stack drives the Touch Bar on T2 MacBooks and does nothing elsewhere."
  if (( ! DRY )); then
    read -rp "Continue anyway? [y/N] " ans
    [[ ${ans,,} == y* ]] || exit 1
  fi
fi

MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
say "Model: $MODEL, installing for user: $TARGET_USER"

command -v hyprctl >/dev/null || warn "hyprctl not found; the workspace layer needs Hyprland."

# Omarchy's own installer adds the t2linux arch-mact2 repo on T2 hardware, so
# the package is normally one pacman away. `omarchy refresh pacman` can drop
# that repo again, which is the usual reason this check fails.
if ! pacman -Q tiny-dfr >/dev/null 2>&1; then
  if pacman -Si tiny-dfr >/dev/null 2>&1; then
    say "Installing the tiny-dfr package"
    run sudo pacman -S --needed --noconfirm tiny-dfr
  else
    warn "The 'tiny-dfr' package is not installed and no configured repo provides it."
    warn "It lives in the t2linux arch-mact2 repo, which Omarchy configures on T2"
    warn "Macs at install time. Check /etc/pacman.conf for [arch-mact2]; if it is"
    warn "missing, Omarchy's install/hardware/pacman.sh shows the two lines to add."
    (( DRY )) || die "install tiny-dfr first, then re-run"
  fi
fi

# Omarchy deliberately removes tiny-dfr on T2 Macs (migration 1785944594)
# because the daemon held stale device descriptors across suspend. The gentle
# sleep hook installed below is this repo's answer; see doc/SUSPEND.md. The
# removal is a one-off migration, not a blacklist, so a reinstall sticks --
# until a future migration says otherwise. If the strip goes blank after an
# `omarchy update`, check the package still exists before debugging.

# The slider patch is optional. Its presence decides three things below: the
# service drop-in, the slider units, and SLIDER= in touchbar.conf, which tells
# the renderer whether it may emit a Slider key at all.
SLIDER=0
if [[ -x /usr/local/bin/tiny-dfr ]]; then
  SLIDER=1
  say "Found /usr/local/bin/tiny-dfr: enabling the slider layers"
else
  say "No patched tiny-dfr in /usr/local/bin: contextual layers use stepped levels"
  say "  (optional: ./build-tiny-dfr.sh, then re-run this script)"
fi

# ---------------------------------------------------------------------------
# /etc/tiny-dfr -- layout templates and icons
# ---------------------------------------------------------------------------

say "Installing Touch Bar layout into /etc/tiny-dfr"
for f in "$REPO"/system/etc/tiny-dfr/*; do
  run sudo install -Dm0644 "$f" "/etc/tiny-dfr/$(basename "$f")"
done

# The group-writable setgid bit is what lets the layout be edited without sudo.
# The tiny-dfr package owns /etc/tiny-dfr and resets this on upgrade, which is
# what the pacman hook below puts back.
run sudo chown -R "root:$TARGET_USER" /etc/tiny-dfr
run sudo chmod 2775 /etc/tiny-dfr

say "Writing /etc/tiny-dfr/touchbar.conf (WORKSPACES=$WORKSPACES SLIDER=$SLIDER)"
if (( DRY )); then
  printf '   would: write /etc/tiny-dfr/touchbar.conf\n'
else
  # WORKSPACES is the user's to keep; SLIDER follows the binary and is rewritten.
  if [[ -f /etc/tiny-dfr/touchbar.conf ]]; then
    WORKSPACES=$(sed -n 's/^\s*WORKSPACES\s*=\s*\([0-9]\+\)\s*$/\1/p' /etc/tiny-dfr/touchbar.conf | tail -1)
    WORKSPACES=${WORKSPACES:-5}
  fi
  sudo install -Dm0664 -o root -g "$TARGET_USER" /dev/stdin /etc/tiny-dfr/touchbar.conf <<EOF
# Per-machine Touch Bar settings. Read by both the shell plugin and the
# fallback daemon, which must agree: the layout draws this many workspace
# buttons and tiny-dfr-ws-icons paints exactly this many pills.
WORKSPACES=$WORKSPACES
# 1 only when /usr/local/bin/tiny-dfr carries patches/tiny-dfr-slider.patch.
# Managed by install.sh; a stock tiny-dfr fed a Slider key silently drops the
# whole layer.
SLIDER=$SLIDER
EOF
fi

# The files the plugin generates at runtime. They are written IN PLACE (see the
# comment on configFile in Service.qml: tiny-dfr reads them as `nobody`, so an
# atomic replace under the writer's umask could leave them unreadable), which
# means they must already exist and already be writable by $TARGET_USER.
#
# Creating them here is what makes the plugin work at all on a fresh install:
# without this, every write fails, the plugin still reports healthy, and
# tiny-dfr silently falls back to the packaged layout.
say "Creating the generated files 0664 root:$TARGET_USER"
for f in config.toml battery.svg update.svg mic.svg night.svg context.state update.state; do
  if [[ -e /etc/tiny-dfr/$f ]]; then
    run sudo chown "root:$TARGET_USER" "/etc/tiny-dfr/$f"
    run sudo chmod 0664 "/etc/tiny-dfr/$f"
  else
    # Seeded empty; the plugin fills them on its first pass. config.toml is the
    # exception -- an empty config parses as "no keys", which tiny-dfr merges
    # over its packaged defaults harmlessly until the first real write.
    run sudo install -Dm0664 -o root -g "$TARGET_USER" /dev/null "/etc/tiny-dfr/$f"
  fi
done

# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------

say "Installing helpers into /usr/local/lib/tiny-dfr"
run sudo install -dm2775 -o root -g "$TARGET_USER" /usr/local/lib/tiny-dfr
for f in tiny-dfr-workspace tiny-dfr-context; do
  run sudo install -Dm0775 -o root -g "$TARGET_USER" \
    "$REPO/bin/$f" "/usr/local/lib/tiny-dfr/$f"
done

say "Installing user helpers into $TARGET_HOME/.local/bin"
for f in tiny-dfr-ws-icons tiny-dfr-update-check tiny-dfr-slider-listener; do
  run install -Dm0755 "$REPO/bin/$f" "$TARGET_HOME/.local/bin/$f"
done

# ---------------------------------------------------------------------------
# systemd, udev, tmpfiles, sudoers, pacman
# ---------------------------------------------------------------------------

say "Installing systemd units"
run sudo install -Dm0644 "$REPO/system/etc/systemd/system/tiny-dfr-workspace.service" \
  /etc/systemd/system/tiny-dfr-workspace.service

# Only with the patched binary: the drop-in that points the service at it, and
# the one that lets it write the slider socket. Installing the first without the
# binary would leave tiny-dfr.service failing to start on every other machine.
DROPIN=/etc/systemd/system/tiny-dfr.service.d
if (( SLIDER )); then
  for f in "$REPO"/system/etc/systemd/system/tiny-dfr.service.d/*.conf; do
    run sudo install -Dm0644 "$f" "$DROPIN/$(basename "$f")"
  done
else
  for f in 99-local-build.conf slider.conf; do
    [[ -e $DROPIN/$f ]] && run sudo rm -f "$DROPIN/$f"
  done
fi

# /usr/lib, NOT /etc: systemd 261 compiles in a single system-sleep hook
# directory and ignores /etc/systemd/system-sleep without a word of complaint.
say "Installing sleep hook into /usr/lib/systemd/system-sleep"
run sudo install -Dm0755 "$REPO/system/usr/lib/systemd/system-sleep/tiny-dfr-suspend" \
  /usr/lib/systemd/system-sleep/tiny-dfr-suspend

say "Installing udev rule, tmpfiles, pacman hook"
run sudo install -Dm0644 "$REPO/system/etc/udev/rules.d/99-touchbar-power.rules" \
  /etc/udev/rules.d/99-touchbar-power.rules
install_templated "$REPO/system/etc/tmpfiles.d/tiny-dfr.conf" /etc/tmpfiles.d/tiny-dfr.conf
install_templated "$REPO/system/etc/pacman.d/hooks/90-tiny-dfr-perms.hook" \
  /etc/pacman.d/hooks/90-tiny-dfr-perms.hook

# Exactly these four unit actions, nothing else. Changing the daemon itself
# still needs a real sudo, on purpose.
say "Installing sudoers rule"
if (( DRY )); then
  printf '   would: write /etc/sudoers.d/50-tiny-dfr\n'
else
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Let $TARGET_USER bounce the Touch Bar units without a password: restarting
# them is how a blank strip is recovered after resume, and how a layout edit is
# applied. Nothing else is granted.
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart tiny-dfr.service
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart tiny-dfr-workspace.service
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start tiny-dfr-workspace.service
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/systemctl stop tiny-dfr-workspace.service
EOF
  # visudo -c refuses a malformed file; installing one unchecked can lock the
  # user out of sudo entirely.
  if sudo visudo -cqf "$tmp"; then
    sudo install -Dm0440 "$tmp" /etc/sudoers.d/50-tiny-dfr
  else
    rm -f "$tmp"; die "generated sudoers rule failed validation, not installing"
  fi
  rm -f "$tmp"
fi

say "Installing user units"
for f in "$REPO"/system/user-units/*; do
  run install -Dm0644 "$f" "$TARGET_HOME/.config/systemd/user/$(basename "$f")"
done

say "Installing theme hook (repaints the workspace pills on theme change)"
run install -Dm0755 "$REPO/system/theme-hook-tiny-dfr-ws-icons" \
  "$TARGET_HOME/.config/omarchy/hooks/theme-set.d/tiny-dfr-ws-icons"

# The Touch Bar buttons only ever *send key combos*; these are the Hyprland
# bindings those combos land on. Without them the AI button, the contextual
# layers and the stepped level rows are all dead keys.
say "Installing Hyprland bindings (hypr/touchbar.lua)"
run install -Dm0644 "$REPO/hypr/touchbar.lua" "$TARGET_HOME/.config/hypr/touchbar.lua"
HYPR_MAIN="$TARGET_HOME/.config/hypr/hyprland.lua"
if [[ -f $HYPR_MAIN ]] && ! grep -q 'require("hypr.touchbar")' "$HYPR_MAIN"; then
  if (( DRY )); then
    printf '   would: append require("hypr.touchbar") to %s\n' "$HYPR_MAIN"
  else
    printf '\n-- Touch Bar bindings (omarchy-t2-touchbar); remove this line to drop them.\nrequire("hypr.touchbar")\n' >> "$HYPR_MAIN"
    say "  appended require(\"hypr.touchbar\") to hyprland.lua"
  fi
fi

# ---------------------------------------------------------------------------
# Activate
# ---------------------------------------------------------------------------

say "Reloading systemd, udev and tmpfiles"
run sudo systemd-tmpfiles --create /etc/tmpfiles.d/tiny-dfr.conf
run sudo udevadm control --reload-rules
run sudo systemctl daemon-reload
run systemctl --user daemon-reload

# The Touch Bar's USB device boots in bConfigurationValue=1, a single HID
# interface where the T2 firmware draws its own fixed Boot Camp layouts.
# Configuration 2 exposes the class-0x10 interface appletbdrm binds to, which
# is what gives tiny-dfr a framebuffer to draw into. The tiny-dfr package's
# udev rule does this on `add`, but a device already enumerated needs a nudge.
say "Checking Touch Bar USB configuration"
if (( ! DRY )); then
  for d in /sys/bus/usb/devices/*; do
    [[ -r $d/idVendor && -r $d/idProduct ]] || continue
    [[ $(cat "$d/idVendor") == 05ac && $(cat "$d/idProduct") == 8302 ]] || continue
    cfg=$(cat "$d/bConfigurationValue" 2>/dev/null || echo "?")
    if [[ $cfg == 2 ]]; then
      say "  Touch Bar already in configuration 2"
    else
      warn "  Touch Bar in configuration $cfg; switching to 2"
      echo 2 | sudo tee "$d/bConfigurationValue" >/dev/null || \
        warn "  could not switch; a reboot will apply the udev rule"
    fi
  done
fi

# --no-redraw: nothing is driving the strip yet. Without it the script's
# fallback would `systemctl restart` the daemon into life right before the
# plugin is enabled, leaving two writers on config.toml.
say "Generating the workspace pill icons for the current theme"
run "$TARGET_HOME/.local/bin/tiny-dfr-ws-icons" --no-redraw || warn "pill generation failed (is Hyprland running?)"

say "Enabling units"
run sudo systemctl enable --now tiny-dfr.service
run systemctl --user enable --now tiny-dfr-update-check.timer
if (( SLIDER )); then
  run systemctl --user enable --now tiny-dfr-slider.service
else
  systemctl --user is-enabled --quiet tiny-dfr-slider.service 2>/dev/null && \
    run systemctl --user disable --now tiny-dfr-slider.service
fi
run sudo systemctl restart tiny-dfr.service

# ---------------------------------------------------------------------------
# Who drives the strip: the plugin, or the standalone daemon. Never both --
# they write the same file.
# ---------------------------------------------------------------------------

if (( WITH_PLUGIN )) && command -v omarchy-plugin-add >/dev/null; then
  say "Installing the Omarchy shell plugin"
  PLUGIN_DIR="$TARGET_HOME/.config/omarchy/plugins/$PLUGIN_ID"
  # Through `omarchy plugin add`, so the plugin is a git checkout that
  # `omarchy plugin update` can manage. Prefer this repo's own origin (a fresh
  # clone from GitHub tracks upstream); fall back to the local checkout.
  PLUGIN_URL=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
  [[ -n $PLUGIN_URL ]] || PLUGIN_URL="file://$REPO"
  # A plugin dir that is not a git checkout (hand-copied, or left by an older
  # version of this script) cannot be updated by `omarchy plugin update`;
  # replace it with a proper clone. Enablement lives in shell.json, keyed by
  # id, so the bar placement survives the swap.
  if [[ -d $PLUGIN_DIR && ! -d $PLUGIN_DIR/.git ]]; then
    say "  $PLUGIN_DIR is a loose copy, not a git checkout; replacing it"
    run rm -rf "$PLUGIN_DIR"
  fi
  if (( DRY )); then
    printf '   would: omarchy plugin add %s --enable --yes\n' "$PLUGIN_URL"
  elif [[ -d $PLUGIN_DIR ]]; then
    say "  already installed (git checkout). Update with: omarchy plugin update $PLUGIN_ID"
  else
    omarchy-plugin-validate "$REPO" || die "plugin failed validation"
    # --enable --yes is non-interactive: no prompt, no placement question, the
    # bar widget lands in its manifest defaultSection.
    if ! omarchy-plugin-add "$PLUGIN_URL" --enable --yes; then
      [[ -d $PLUGIN_DIR ]] || die "omarchy plugin add failed"
      warn "plugin added but could not be enabled automatically; run:"
      warn "  omarchy plugin enable $PLUGIN_ID"
    fi
  fi

  say "Stopping the standalone daemon (the plugin does its job now)"
  run sudo systemctl disable --now tiny-dfr-workspace.service

  if (( ! DRY )); then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
    if omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$PLUGIN_ID" 'any(.[]; .id == $id and .enabled)' >/dev/null; then
      omarchy-shell touchbar redraw >/dev/null 2>&1 || true
      say "Plugin enabled and drawing."
    else
      say "Enable the plugin with:  omarchy plugin enable $PLUGIN_ID"
    fi
  fi
else
  (( WITH_PLUGIN )) && warn "omarchy-shell not found; using the standalone daemon instead"
  say "Enabling the standalone daemon"
  run sudo systemctl enable --now tiny-dfr-workspace.service
fi

say "Done."
(( DRY )) && say "(dry run -- nothing was changed)"
exit 0
