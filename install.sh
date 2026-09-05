#!/bin/bash
# Install the system half of the T2 Touch Bar stack.
#
# The Omarchy plugin (manifest.json + Service.qml, at the root of this repo)
# only draws the layout. Everything the layout depends on -- the tiny-dfr
# daemon, /etc/tiny-dfr, the systemd units, the udev rules, the sleep hook --
# is root-owned and cannot be shipped by the plugin system, which by design
# copies a git checkout into ~/.config/omarchy/plugins and loads QML from it.
# That is what this script is for.
#
#   ./install.sh              install everything
#   ./install.sh --no-plugin  system half only, leaving the shell alone
#   ./install.sh --dry-run    print what would change and exit
#
# Safe to re-run: every step is idempotent.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
WITH_PLUGIN=1
WORKSPACES="${WORKSPACES:-5}"

while (( $# > 0 )); do
  case "$1" in
    --dry-run)   DRY=1; shift ;;
    --no-plugin) WITH_PLUGIN=0; shift ;;
    -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
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

if ! pacman -Q tiny-dfr >/dev/null 2>&1; then
  warn "The 'tiny-dfr' package is not installed."
  warn "Get it from the t2linux arch-mact2 repo, e.g."
  warn "  sudo pacman -U https://mirror.funami.tech/arch-mact2/os/x86_64/tiny-dfr-<ver>-x86_64.pkg.tar.zst"
  warn ""
  warn "NOTE: Omarchy deliberately uninstalls tiny-dfr on T2 Macs (migration"
  warn "1785944594) because the optional daemon held stale device descriptors"
  warn "across suspend. The gentle sleep hook installed here is the answer to"
  warn "that -- see doc/SUSPEND.md. If the Touch Bar goes blank after an"
  warn "'omarchy update', check the package still exists before debugging."
  (( DRY )) || die "install tiny-dfr first, then re-run"
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

if [[ ! -f /etc/tiny-dfr/touchbar.conf ]] || (( DRY )); then
  say "Writing /etc/tiny-dfr/touchbar.conf (WORKSPACES=$WORKSPACES)"
  if (( DRY )); then
    printf '   would: write /etc/tiny-dfr/touchbar.conf\n'
  else
    sudo install -Dm0664 -o root -g "$TARGET_USER" /dev/stdin /etc/tiny-dfr/touchbar.conf <<EOF
# Per-machine Touch Bar settings. Read by both the QML plugin and the Python
# fallback daemon, which must agree: the layout draws this many workspace
# buttons and tiny-dfr-ws-icons paints exactly this many pills.
WORKSPACES=$WORKSPACES
EOF
  fi
else
  say "Keeping existing /etc/tiny-dfr/touchbar.conf"
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
for f in "$REPO"/system/etc/systemd/system/tiny-dfr.service.d/*.conf; do
  run sudo install -Dm0644 "$f" "/etc/systemd/system/tiny-dfr.service.d/$(basename "$f")"
done

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

say "Generating the workspace pill icons for the current theme"
run "$TARGET_HOME/.local/bin/tiny-dfr-ws-icons" || warn "pill generation failed (is Hyprland running?)"

say "Enabling units"
run sudo systemctl enable --now tiny-dfr.service
run systemctl --user enable --now tiny-dfr-slider.service
run systemctl --user enable --now tiny-dfr-update-check.timer

# ---------------------------------------------------------------------------
# Plugin
# ---------------------------------------------------------------------------

if (( WITH_PLUGIN )); then
  say "Installing the Omarchy shell plugin"
  if ! command -v omarchy-plugin-validate >/dev/null; then
    warn "omarchy-shell not found; skipping the plugin half."
    warn "Enable the standalone daemon instead:"
    warn "  sudo systemctl enable --now tiny-dfr-workspace.service"
  else
    PLUGIN_DIR="$TARGET_HOME/.config/omarchy/plugins/t2.touchbar"
    if (( DRY )); then
      printf '   would: copy plugin -> %s\n' "$PLUGIN_DIR"
    else
      omarchy-plugin-validate "$REPO" || die "plugin failed validation"
      mkdir -p "$PLUGIN_DIR"
      # Only the files the shell loads. The system half and the tests have no
      # business inside a directory the shell scans and hot-reloads.
      cp -f "$REPO/manifest.json" "$REPO/Service.qml" "$REPO/BarWidget.qml" "$PLUGIN_DIR/"
      mkdir -p "$PLUGIN_DIR/lib"
      cp -f "$REPO/lib/TouchBar.js" "$PLUGIN_DIR/lib/"

      omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
      say "Plugin installed. Enable it with:"
      say "  omarchy plugin enable t2.touchbar"
    fi
    # The plugin and the daemon both write config.toml; running both means two
    # writers racing on the same file and double the full-panel redraws.
    if systemctl is-enabled --quiet tiny-dfr-workspace.service 2>/dev/null; then
      warn "tiny-dfr-workspace.service is enabled and does the same job as the"
      warn "plugin. Disable it once the plugin is confirmed working:"
      warn "  sudo systemctl disable --now tiny-dfr-workspace.service"
    fi
  fi
else
  say "Skipping the plugin; enabling the standalone daemon instead"
  run sudo systemctl enable --now tiny-dfr-workspace.service
fi

say "Done."
(( DRY )) && say "(dry run -- nothing was changed)"
exit 0
