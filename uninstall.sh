#!/bin/bash
# Remove the T2 Touch Bar stack.
#
# Leaves the tiny-dfr package itself alone -- this only removes what
# install.sh added. Pass --purge to also delete /etc/tiny-dfr, which the
# tiny-dfr package owns and would otherwise be left with this repo's layout.

set -euo pipefail

PURGE=0
DRY=0
while (( $# > 0 )); do
  case "$1" in
    --purge)   PURGE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

say() { printf '\033[1;34m==\033[0m %s\n' "$*"; }
run() { if (( DRY )); then printf '   would: %s\n' "$*"; else "$@" || true; fi; }

say "Disabling units"
run systemctl --user disable --now tiny-dfr-slider.service
run systemctl --user disable --now tiny-dfr-update-check.timer
run sudo systemctl disable --now tiny-dfr-workspace.service

say "Removing the shell plugin"
if command -v omarchy-plugin-disable >/dev/null; then
  run omarchy-plugin-disable t2.touchbar
fi
run rm -rf "$TARGET_HOME/.config/omarchy/plugins/t2.touchbar"
command -v omarchy-shell >/dev/null && run omarchy-shell shell rescanPlugins

say "Removing system files"
for f in \
  /etc/systemd/system/tiny-dfr-workspace.service \
  /etc/systemd/system/tiny-dfr.service.d/99-local-build.conf \
  /etc/systemd/system/tiny-dfr.service.d/slider.conf \
  /usr/lib/systemd/system-sleep/tiny-dfr-suspend \
  /etc/udev/rules.d/99-touchbar-power.rules \
  /etc/tmpfiles.d/tiny-dfr.conf \
  /etc/pacman.d/hooks/90-tiny-dfr-perms.hook \
  /etc/sudoers.d/50-tiny-dfr \
  /usr/local/lib/tiny-dfr/tiny-dfr-workspace \
  /usr/local/lib/tiny-dfr/tiny-dfr-context
do
  [[ -e $f ]] && run sudo rm -f "$f"
done
run sudo rmdir --ignore-fail-on-non-empty /usr/local/lib/tiny-dfr /etc/systemd/system/tiny-dfr.service.d

say "Removing user files"
for f in \
  "$TARGET_HOME/.local/bin/tiny-dfr-ws-icons" \
  "$TARGET_HOME/.local/bin/tiny-dfr-update-check" \
  "$TARGET_HOME/.local/bin/tiny-dfr-slider-listener" \
  "$TARGET_HOME/.config/systemd/user/tiny-dfr-slider.service" \
  "$TARGET_HOME/.config/systemd/user/tiny-dfr-update-check.service" \
  "$TARGET_HOME/.config/systemd/user/tiny-dfr-update-check.timer" \
  "$TARGET_HOME/.config/omarchy/hooks/theme-set.d/tiny-dfr-ws-icons"
do
  [[ -e $f ]] && run rm -f "$f"
done

if (( PURGE )); then
  say "Purging /etc/tiny-dfr"
  run sudo rm -rf /etc/tiny-dfr
  say "Reinstall the package to restore its stock layout: sudo pacman -S tiny-dfr"
else
  say "Leaving /etc/tiny-dfr in place (pass --purge to remove it)"
  say "Its config.toml still holds this repo's generated layout; reinstall the"
  say "package to get the stock one back: sudo pacman -S tiny-dfr"
fi

run sudo systemctl daemon-reload
run systemctl --user daemon-reload
run sudo udevadm control --reload-rules

say "Done. The tiny-dfr package itself was not touched."
(( DRY )) && say "(dry run -- nothing was changed)"
exit 0
