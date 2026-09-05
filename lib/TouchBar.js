.pragma library

// Pure rendering helpers for the Touch Bar config and its generated icons.
//
// Everything here is a pure function of its arguments so it can be exercised
// outside the shell (see test/render-test.js) -- the QML service is only the
// wiring that decides when to call these and where to put the results.
//
// This is a port of the Python daemon's render/draw logic; the constants and
// the reasoning behind them are kept identical on purpose, because they were
// arrived at empirically against a real 2170x60 panel.

// Bright enough to read at a glance on a black OLED strip at arm's length.
var BATT_GREEN = "#4ade80"
var BATT_AMBER = "#fbbf24"
var BATT_RED = "#f87171"
var UPDATE_AMBER = "#fbbf24"

// Material Symbols "autorenew" -- the two-arrow loop, matching the Nerd Font
// glyph the Omarchy bar uses for its update widget.
var AUTORENEW_PATH =
  "M196-331q-20-36-28-72.5t-8-74.5q0-131 94.5-225.5T480-798h43l-80-80 39-39 " +
  "149 149-149 149-40-40 79-79h-41q-107 0-183.5 76.5T220-478q0 29 5.5 55t13.5 " +
  "49l-43 43ZM476-40 327-189l149-149 39 39-80 80h45q107 0 183.5-76.5T740-479q0" +
  "-29-5-55t-15-49l43-43q20 36 28.5 72.5T800-479q0 131-94.5 225.5T480-159h-45l" +
  "80 80-39 39Z"

// The workspace rows substituted into @WORKSPACES@. The active one becomes a
// pill icon (drawn by tiny-dfr-ws-icons in the theme's border gradient);
// everything else stays a plain digit.
function renderWorkspaceRows(count, active) {
  var rows = []
  for (var n = 1; n <= count; n++) {
    var action = '[ "LeftMeta", "Num' + n + '" ]'
    if (n === active)
      rows.push('    { Icon = "ws' + n + '_active", Action = ' + action + ' },')
    else
      rows.push('    { Text = "' + n + '", Action = ' + action + ' },')
  }
  return rows.join("\n")
}

// Stock tiny-dfr has no Slider button type. A config containing one fails to
// parse, and tiny-dfr then silently falls back to its packaged layout -- the
// contextual layers would simply vanish, with nothing in the journal. So the
// templates carry @SLIDER:<name>@ and this substitutes either the real slider
// (binary built with patches/tiny-dfr-slider.patch, SLIDER=1 in touchbar.conf)
// or a stepped row of absolute levels. The stepped keys are bound to
// SUPER+CTRL+ALT+1..8 by hypr/touchbar.lua. Mirrored in bin/tiny-dfr-workspace.
var STEPPED_KEYS = {
  volume: ["Num1", "Num2", "Num3", "Num4"],
  brightness: ["Num5", "Num6", "Num7", "Num8"]
}

function sliderRow(name, enabled) {
  if (enabled) return '    { Slider = "' + name + '", Stretch = 8 },'
  var keys = STEPPED_KEYS[name]
  if (!keys) return ""
  var levels = [25, 50, 75, 100], rows = []
  for (var i = 0; i < 4; i++) {
    rows.push('    { Text = "' + levels[i] + '", Action = [ "LeftMeta", "LeftCtrl", "LeftAlt", "' +
      keys[i] + '" ], Stretch = 2 },')
  }
  return rows.join("\n")
}

// Substitute the workspace block into whichever template is in force. A
// context template (audio, display) replaces the whole default layer while its
// panel is open, but still carries @WORKSPACES@ so the left edge keeps working.
function renderConfig(templateText, count, active, slider) {
  if (!templateText) return null
  // split/join, not replace(string): JS replaces only the first occurrence,
  // Python's str.replace replaces all, and the differential test caught the
  // two disagreeing the moment a comment mentioned the marker.
  var out = templateText.split("@WORKSPACES@").join(renderWorkspaceRows(count, active))
  return out.replace(/@SLIDER:(\w+)@/g, function(_, name) { return sliderRow(name, !!slider) })
}

function batteryColour(pct, charging) {
  if (charging) return BATT_GREEN
  if (pct < 5) return BATT_RED
  if (pct < 20) return BATT_AMBER
  return BATT_GREEN
}

// Change key: 5% steps, plus charging state, plus the colour.
//
// The colour has to be part of this. Buckets alone would miss the amber->red
// crossing at 5%, because 4% and 5% both round to the same bucket -- exactly
// the transition that matters most.
function batteryBucket(pct, charging) {
  if (pct === null || pct === undefined) return null
  return [Math.round(pct / 5) * 5, charging, batteryColour(pct, charging)].join("/")
}

// A horizontal battery whose fill and colour both track the level.
//
// The viewBox is 72x48 and the glyph fills it, because librsvg preserves
// aspect ratio when rendering into tiny-dfr's icon rectangle: a square viewBox
// drawn into a wide rect just letterboxes, wasting the width. The template
// pairs this with IconWidth = 72 / IconHeight = 48 to match.
//
// Box height is 48, the same as every other icon, so the battery sits with
// identical top/bottom padding in the 60px panel. Width is 72 rather than a
// full 2:1, to keep a visible gap from the neighbouring icon.
//
// The shell (outline + terminal) is white like every other icon on the strip;
// only the fill level inside carries the colour, so the battery reads as part
// of the icon set and the colour means one thing only: charge level.
// Format a number the way Python's str(float) does, so an integral value keeps
// its ".0". SVG does not care, but the Python daemon is still shipped as the
// fallback for non-Omarchy setups: if the two ever run against the same file
// (during a migration, say) byte-identical output stops them rewriting
// battery.svg back and forth and forcing a full-panel redraw each time.
function pyFloat(v) {
  return Number.isInteger(v) ? v.toFixed(1) : String(v)
}

function batterySvg(pct, charging) {
  var colour = batteryColour(pct, charging)
  var trackX = 8.0, trackY = 11.5, trackH = 25.0, trackMax = 46.0
  var fillW = trackMax * pct / 100.0

  // Punched in the panel's black so it reads as a cutout at any fill level.
  var bolt = charging
    ? '<path fill="#000000" d="M34 11 L24 25 L30 25 L27.5 37 L38 22 L32 22 Z"/>'
    : ""

  var fill = fillW > 1
    ? '<rect x="' + pyFloat(trackX) + '" y="' + pyFloat(trackY) + '" width="' +
      fillW.toFixed(2) + '" height="' + pyFloat(trackH) + '" rx="4" fill="' +
      colour + '"/>'
    : ""

  return '<svg xmlns="http://www.w3.org/2000/svg" width="72" height="48" ' +
    'viewBox="0 0 72 48">' +
    '<rect x="3" y="6" width="56" height="36" rx="9" fill="none" ' +
    'stroke="white" stroke-width="3.5"/>' +
    '<rect x="62" y="17" width="6" height="14" rx="2.5" fill="white"/>' +
    fill + bolt + '</svg>'
}

// White normally, amber when an update is pending.
//
// The bar widget hides itself entirely when nothing is pending; here the
// button stays put and changes colour instead, because a button vanishing from
// the Touch Bar reflows every other button next to it.
function updateSvg(available) {
  var colour = available ? UPDATE_AMBER : "white"
  return '<svg xmlns="http://www.w3.org/2000/svg" height="48" ' +
    'viewBox="0 -960 960 960" width="48">' +
    '<path fill="' + colour + '" d="' + AUTORENEW_PATH + '"/>' +
    '</svg>'
}

// Parse (percent, charging) out of the batched sysfs read the service does.
// charge_now/charge_full is preferred over `capacity` and then clamped:
// tiny-dfr's own widget has no clamp, and on a cell whose charge_full has
// drifted below true capacity a full charge reports 101%.
function parseBattery(status, chargeNow, chargeFull, capacity) {
  var pct = null
  var now = parseFloat(chargeNow), full = parseFloat(chargeFull)
  if (!isNaN(now) && !isNaN(full) && full > 0) pct = (now / full) * 100.0
  if (pct === null) {
    var cap = parseFloat(capacity)
    if (!isNaN(cap)) pct = cap
  }
  if (pct === null) return null
  return {
    percent: Math.max(0, Math.min(100, Math.round(pct))),
    charging: status === "Charging" || status === "Full"
  }
}

// True/False from a one-byte state file, null when absent or malformed.
function readFlag(text) {
  if (text === null || text === undefined) return null
  var v = String(text).trim()
  if (v === "1") return true
  if (v === "0") return false
  return null
}
