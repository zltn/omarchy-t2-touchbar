### Repository URL

https://github.com/zltn/omarchy-t2-touchbar

### Category

Hardware

### Tags

hyprland, workspaces, bar

### Suggest a missing tag

touch-bar

### Maintainer notes

Drives the Touch Bar on T2 MacBooks through tiny-dfr. The plugin itself only reads and writes files under /etc/tiny-dfr; the root-owned parts (tiny-dfr layout, systemd units, udev rule, sleep hook, sudoers rule for restarting one service) are installed by a separate, documented `install.sh` that shows a dry run first. That script also installs a Hyprland bindings file and appends one `require` line to `~/.config/hypr/hyprland.lua`; it rebinds SUPER+CTRL+A and SUPER+CTRL+D so the audio/display panels open through a wrapper. Removal is `./uninstall.sh`. External dependency: the `tiny-dfr` package from the t2linux arch-mact2 repo, which Omarchy configures on T2 hardware. An optional patched tiny-dfr (patch included, built locally) adds real sliders; without it the plugin works with stock tiny-dfr.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
