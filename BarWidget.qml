import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons

// Touch Bar health, on the Omarchy bar.
//
// The strip itself can never show its own status: tiny-dfr renders whatever
// config.toml says and has no way to report that it has stopped, so a dead
// daemon and a daemon drawing an all-black layout look identical from the
// Touch Bar. That is what this widget is for -- it is the one piece of Touch
// Bar state that has to live somewhere else.
//
// Most commonly needed after a resume: the gentle sleep hook deliberately does
// not re-enumerate the USB device (the aggressive variant that did hard-locked
// this machine twice), so the strip can come back blank with tiny-dfr still
// nominally running. A click restarts it, which is the documented recovery.

BarWidget {
  id: root
  moduleName: "t2.touchbar"

  // Nerd Font "keyboard" glyph, matching the weight of the bar's other icons.
  readonly property string glyph: ""

  property bool daemonActive: true
  property bool checked: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    bar: root.bar
    text: root.glyph
    // Dim rather than hide when the daemon is down: a widget that vanishes
    // reflows the whole bar section, and this one exists precisely to be
    // noticed when something is wrong.
    dimmed: root.checked && !root.daemonActive
    tooltipText: !root.checked ? "Touch Bar"
      : (root.daemonActive ? "Touch Bar: running (click to restart)"
                           : "Touch Bar: stopped (click to restart)")
    onPressed: function(mouseButton) { restart.running = true }
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!probe.running) probe.running = true
  }

  Process {
    id: probe
    command: ["systemctl", "is-active", "--quiet", "tiny-dfr.service"]
    onExited: function(exitCode) {
      root.daemonActive = exitCode === 0
      root.checked = true
    }
  }

  // Passwordless via /etc/sudoers.d/50-tiny-dfr, which allows exactly this one
  // unit restart and nothing else.
  Process {
    id: restart
    command: ["sudo", "-n", "systemctl", "restart", "tiny-dfr.service"]
    onExited: probe.running = true
  }
}
