-- Hyprland bindings the Touch Bar layout depends on.
--
-- A Touch Bar button can only ever send a key combo (tiny-dfr has no exec
-- widget), so every "smart" button on the strip is really a keybinding that
-- lives here. Installed to ~/.config/hypr/touchbar.lua and pulled in by a
-- require("hypr.touchbar") line that install.sh appends to hyprland.lua.
-- `o` and `hl` are Omarchy's binding helpers, global in any bindings file.

-- AI button. Omarchy's own SUPER+SHIFT+CTRL+A is "omarchy-agent --pick", which
-- sets the default agent; the bar's AI widget instead opens the usage panel,
-- which is what a Touch Bar button should do too.
o.bind("SUPER + CTRL + G", "AI usage", "omarchy-shell shell toggle omarchy.agents")

-- Contextual layers. These replace the stock Audio/Display bindings so the
-- TRIGGER can declare which panel it opened: every Omarchy panel is the same
-- Hyprland layer ("omarchy-keyboard-panel") at the same geometry, and the shell
-- does not expose which one is open over IPC, so the Touch Bar cannot detect
-- it. Consequence: opening a panel by clicking its bar icon with the mouse does
-- not route through here, so the strip will not switch; keys and Touch Bar
-- buttons both do. closelayer fires reliably, so leaving the layer always works.
hl.unbind("SUPER + CTRL + A")
hl.unbind("SUPER + CTRL + D")
o.bind("SUPER + CTRL + A", "Audio",
  "/usr/local/lib/tiny-dfr/tiny-dfr-context audio omarchy.audio")
o.bind("SUPER + CTRL + D", "Display",
  "/usr/local/lib/tiny-dfr/tiny-dfr-context display omarchy.monitor")

-- Absolute levels for the contextual layers. On a stock tiny-dfr (no slider
-- patch) the layers show a 25/50/75/100 row that lands on these.
--
-- Plain digits, NOT "code:NN": with three modifiers Hyprland fails to parse the
-- code: form and stores the whole string as the key name, leaving the binding
-- dead. It parses fine with a single modifier, which is why Omarchy's own
-- workspace bindings can use code: safely.
for i, level in ipairs({ 25, 50, 75, 100 }) do
  o.bind("SUPER + CTRL + ALT + " .. tostring(i), "Volume " .. level .. "%",
    "wpctl set-volume @DEFAULT_AUDIO_SINK@ " .. level .. "%")
  o.bind("SUPER + CTRL + ALT + " .. tostring(i + 4), "Brightness " .. level .. "%",
    "omarchy-brightness-display " .. level .. "%")
end

-- Night light already has SUPER+CTRL+N in Omarchy's utilities.lua; the Touch
-- Bar aims at that rather than adding a duplicate.
