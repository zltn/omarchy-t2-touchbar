import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "lib/TouchBar.js" as TouchBar

// Drives the Touch Bar's tiny-dfr layout from inside omarchy-shell.
//
// tiny-dfr has no concept of state: every button is drawn once from the config
// and never changes. But it *does* watch /etc/tiny-dfr/config.toml with inotify
// (IN_MOVED_TO | IN_CLOSE | IN_ONESHOT) and, on an event, reloads the config and
// forces a complete redraw. So live state is shown by regenerating the config.
//
// This replaces the standalone tiny-dfr-workspace.service daemon. That daemon
// existed to answer one question -- which Hyprland workspace is focused -- and
// spent ~250 of its 599 lines on the plumbing to find out: globbing for the
// instance signature under /run/user/*/hypr/, connecting to .socket2.sock,
// parsing the event stream, and reconnecting when Hyprland restarts. The shell
// already tracks all of that natively, so here it is one property binding.
//
// It also sidesteps the sandbox trap that cost real time in the daemon:
// ProtectHome=true blanks /run/user as well as /home, which hid the very socket
// the daemon needed. Running in the shell, there is no unit and no sandbox.
//
// Writing config.toml is what triggers the redraw. FileView.setText() opens,
// writes and closes, so tiny-dfr's IN_CLOSE arm fires with a complete file --
// no partial read is possible. Writes are always debounced or coalesced below,
// never back to back, because IN_ONESHOT means tiny-dfr must re-arm its watch
// after each event and a second write landing inside that gap would be missed.

Item {
  id: root

  // Injected by omarchy-shell's plugin loader.
  property var shell: null

  readonly property string etcDir: "/etc/tiny-dfr"
  readonly property string runDir: "/run/tiny-dfr"

  // How many workspace buttons the strip carries. Overridable per machine via
  // /etc/tiny-dfr/touchbar.conf (WORKSPACES=...), read at startup.
  property int workspaceCount: 5

  // Whether the running tiny-dfr carries the slider patch (SLIDER=1 in
  // touchbar.conf). Decides what @SLIDER:name@ in a context template becomes;
  // see sliderRow() in lib/TouchBar.js for why this cannot be left to chance.
  property bool sliderEnabled: false

  // Which contextual layer is showing, or "" for the default layout. Every
  // Omarchy panel is the same Hyprland layer surface at identical geometry and
  // the shell does not expose which one is open, so the *trigger*
  // (tiny-dfr-context) declares the context by writing context.state.
  property string context: ""

  readonly property var contextTemplates: ({
    "audio": "context-audio.template.toml",
    "display": "context-display.template.toml"
  })

  property int activeWorkspace: -1
  property string defaultTemplate: ""
  property string contextTemplate: ""

  property bool micMuted: false
  property bool nightOn: false
  property bool updatePending: false
  property string batteryBucket: ""

  // ---- config rendering ---------------------------------------------------

  function templateText() {
    if (root.context !== "" && root.contextTemplate !== "") return root.contextTemplate
    return root.defaultTemplate
  }

  // Bumped only by forceRedraw(). FileView.setText() is a no-op when the text is
  // unchanged, which is right for ordinary writes but wrong for a forced redraw:
  // tiny-dfr caches icons at config load, so when an SVG is repainted under it
  // (a theme change repainting the workspace pills) the config is byte-identical
  // and nothing would be written, nothing would reload, and the strip would keep
  // the old colours. Emitting the nonce as a trailing TOML comment guarantees the
  // content differs, so the write lands and the inotify watch fires.
  property int redrawNonce: 0

  function writeConfig() {
    if (root.activeWorkspace < 0) return
    var text = TouchBar.renderConfig(templateText(), root.workspaceCount, root.activeWorkspace,
                                     root.sliderEnabled)
    if (!text) return
    if (root.redrawNonce > 0) text += "\n# redraw " + root.redrawNonce + "\n"
    configFile.setText(text)
  }

  function forceRedraw() {
    root.redrawNonce += 1
    root.writeConfig()
  }

  // Workspace switches get their own short debounce and are deliberately NOT
  // routed through the state coalescer: they are the one path where latency is
  // actually felt. 30ms is just long enough to swallow the burst Hyprland emits
  // for a single switch (workspace + workspacev2 + focusedmon all fire together)
  // and short enough to be imperceptible.
  Timer {
    id: workspaceDebounce
    interval: 30
    onTriggered: root.writeConfig()
  }

  // Every config rewrite makes tiny-dfr force a COMPLETE redraw, which asks
  // appletbdrm for one damage rect covering the whole 2170x60 panel. The driver
  // allocates that ~509KB transfer buffer with kvzalloc; when memory is
  // fragmented kvzalloc falls back to vmalloc, which the kernel refuses to DMA
  // ("rejecting DMA map of vmalloc memory" -> Failed to send message -11) and
  // the frame is dropped. So icon-state changes are batched: several arriving
  // together produce ONE rewrite, and therefore one full-panel transfer.
  Timer {
    id: stateCoalesce
    interval: 150
    onTriggered: root.writeConfig()
  }

  // A config reload replaces tiny-dfr's layer array mid-touch, so let the
  // layout settle rather than swapping it out from under a finger still on the
  // button.
  Timer {
    id: contextSettle
    interval: 150
    onTriggered: root.applyPendingContext()
  }

  // "open" or "close" -- WHICH context is resolved only when the settle timer
  // fires, not when the event arrives. tiny-dfr-context writes context.state
  // and then opens the panel, and contextStateFile picks that write up through
  // an asynchronous reload; reading it at event time could still see the
  // previous value. 150ms later it has landed.
  property string pendingKind: ""

  function applyPendingContext() {
    var target = root.pendingKind === "open" ? root.contextFromState : ""
    root.pendingKind = ""
    if (target === root.context) return
    root.context = target
    if (root.context === "") {
      root.contextTemplate = ""
      root.writeConfig()
    } else {
      // Loading the template triggers the rewrite once it arrives.
      contextTemplateFile.path = root.etcDir + "/" + root.contextTemplates[root.context]
    }
  }

  // ---- workspace ----------------------------------------------------------

  readonly property int focusedWorkspaceId:
    Hyprland.focusedWorkspace !== null ? Hyprland.focusedWorkspace.id : -1

  onFocusedWorkspaceIdChanged: {
    if (focusedWorkspaceId < 0) return
    if (focusedWorkspaceId === root.activeWorkspace) return
    root.activeWorkspace = focusedWorkspaceId
    workspaceDebounce.restart()
  }

  // ---- contextual layers --------------------------------------------------

  readonly property string panelNamespace: "omarchy-keyboard-panel"

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name !== "openlayer" && event.name !== "closelayer") return
      if (String(event.data).trim() !== root.panelNamespace) return

      if (event.name === "openlayer") {
        root.pendingKind = "open"
      } else {
        // However the panel was dismissed, drop the layer.
        root.clearContextState()
        root.pendingKind = "close"
      }
      contextSettle.restart()
    }
  }

  property string contextFromState: ""

  function clearContextState() {
    contextStateFile.setText("\n")
    root.contextFromState = ""
  }

  // ---- files --------------------------------------------------------------

  // The generated config. Never watched: this is the write target, and watching
  // it would feed our own writes straight back in.
  //
  // atomicWrites is off deliberately, and this is load-bearing. tiny-dfr runs
  // as `nobody`, so everything it reads has to stay world-readable. An in-place
  // write keeps the file's existing mode and owner; an atomic write replaces
  // the file with a fresh one created under this process's umask, which on a
  // stricter umask would leave a config `nobody` cannot read. tiny-dfr treats an
  // unreadable or unparseable config as absent and silently falls back to the
  // packaged layout -- no error, no log line -- so that failure would present as
  // "the Touch Bar just stopped following the workspace" with nothing to go on.
  //
  // The cost of in-place writing is that the file must already be writable by
  // this user; install.sh creates it 0664 root:<user> and the pacman hook puts
  // that back after a tiny-dfr upgrade. onSaveFailed below makes the remaining
  // case loud rather than silent.
  FileView {
    id: configFile
    path: root.etcDir + "/config.toml"
    atomicWrites: false
    printErrors: false
    onSaveFailed: root.reportWriteFailure(path)
  }

  // The one failure mode worth shouting about: without write access every part
  // of this plugin still runs and reports healthy over IPC while the strip
  // quietly stops updating. Warn once rather than on every switch.
  property bool writeFailureReported: false

  function reportWriteFailure(path) {
    if (root.writeFailureReported) return
    root.writeFailureReported = true
    // Which symptom depends on which file: config.toml means nothing on the
    // strip updates at all; an SVG means only that one indicator is frozen.
    var symptom = /config\.toml$/.test(path)
      ? "the Touch Bar will not update at all"
      : "that indicator will stay frozen on the strip"
    console.warn("t2.touchbar: cannot write " + path + " -- " + symptom +
      ". It must be writable by this user; re-run install.sh, or: " +
      "sudo chown root:$USER " + path + " && sudo chmod 0664 " + path)
  }

  FileView {
    id: templateFile
    path: root.etcDir + "/config.template.toml"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.defaultTemplate = text()
      // Through the debounce, not direct: at startup this, touchbar.conf and
      // the first workspace all land within a few ms of each other, and three
      // back-to-back writes would race tiny-dfr's IN_ONESHOT re-arm.
      workspaceDebounce.restart()
    }
    onFileChanged: reload()
  }

  FileView {
    id: contextTemplateFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.contextTemplate = text()
      root.writeConfig()
    }
    onLoadFailed: {
      // A missing or unreadable context template falls back to the default
      // layer rather than leaving the strip on a stale layout.
      root.context = ""
      root.contextTemplate = ""
      root.writeConfig()
    }
    onFileChanged: reload()
  }

  // context.state lives in /etc and therefore SURVIVES a reboot. A freshly
  // started shell cannot be inside an open panel, so a leftover value would
  // strand the Touch Bar on a contextual layer forever -- the only thing that
  // clears a context is a closelayer event, and no panel was ever opened to
  // produce one. Cleared on startup below.
  FileView {
    id: contextStateFile
    path: root.etcDir + "/context.state"
    watchChanges: true
    atomicWrites: false
    printErrors: false
    onLoaded: {
      var v = text().trim()
      root.contextFromState = root.contextTemplates.hasOwnProperty(v) ? v : ""
    }
    onFileChanged: reload()
  }

  // ---- icon state ---------------------------------------------------------

  // The mic and night icons are a straight glyph swap: the listeners publish
  // the state, this only chooses which SVG mic.svg / night.svg holds. Sources
  // are static, so they are read once and kept in memory.
  property string micOnSvg: ""
  property string micMutedSvg: ""
  property string nightOnSvg: ""
  property string nightOffSvg: ""

  FileView { id: micOnFile;    path: root.etcDir + "/mic_on.svg";    printErrors: false; onLoaded: root.micOnSvg = text() }
  FileView { id: micMutedFile; path: root.etcDir + "/mic_muted.svg"; printErrors: false; onLoaded: root.micMutedSvg = text() }
  FileView { id: nightOnFile;  path: root.etcDir + "/night_on.svg";  printErrors: false; onLoaded: root.nightOnSvg = text() }
  FileView { id: nightOffFile; path: root.etcDir + "/night_off.svg"; printErrors: false; onLoaded: root.nightOffSvg = text() }

  // Same in-place rule as config.toml above: tiny-dfr reads these as `nobody`,
  // so they must keep their world-readable mode rather than being replaced.
  FileView { id: micSvgFile;     path: root.etcDir + "/mic.svg";     atomicWrites: false; printErrors: false; onSaveFailed: root.reportWriteFailure(path) }
  FileView { id: nightSvgFile;   path: root.etcDir + "/night.svg";   atomicWrites: false; printErrors: false; onSaveFailed: root.reportWriteFailure(path) }
  FileView { id: batterySvgFile; path: root.etcDir + "/battery.svg"; atomicWrites: false; printErrors: false; onSaveFailed: root.reportWriteFailure(path) }
  FileView { id: updateSvgFile;  path: root.etcDir + "/update.svg";  atomicWrites: false; printErrors: false; onSaveFailed: root.reportWriteFailure(path) }

  // Live state, published by the listeners as one-byte files. Watched rather
  // than polled -- the Python daemon polled mic.state every 100ms purely
  // because it had no event loop to hang an inotify watch on.
  FileView {
    id: micStateFile
    path: root.runDir + "/mic.state"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyMic(TouchBar.readFlag(text()))
    onFileChanged: reload()
  }

  FileView {
    id: nightStateFile
    path: root.runDir + "/night.state"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyNight(TouchBar.readFlag(text()))
    onFileChanged: reload()
  }

  // The check itself runs as the user on a systemd timer, NOT here: it calls
  // checkupdates, which needs the network. Reading a one-byte file costs
  // nothing and keeps pacman off this path entirely.
  FileView {
    id: updateStateFile
    path: root.etcDir + "/update.state"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyUpdate(TouchBar.readFlag(text()))
    onFileChanged: reload()
  }

  function applyMic(muted) {
    if (muted === null || muted === root.micMuted) return
    root.micMuted = muted
    var svg = muted ? root.micMutedSvg : root.micOnSvg
    if (svg === "") return
    micSvgFile.setText(svg)
    stateCoalesce.restart()
  }

  function applyNight(on) {
    if (on === null || on === root.nightOn) return
    root.nightOn = on
    var svg = on ? root.nightOnSvg : root.nightOffSvg
    if (svg === "") return
    nightSvgFile.setText(svg)
    stateCoalesce.restart()
  }

  function applyUpdate(pending) {
    if (pending === null || pending === root.updatePending) return
    root.updatePending = pending
    updateSvgFile.setText(TouchBar.updateSvg(pending))
    stateCoalesce.restart()
  }

  // ---- battery ------------------------------------------------------------

  // The only genuinely polled input: sysfs does not deliver usable inotify
  // events. Redrawn only when the 5% bucket, the charging state or the colour
  // actually changes, so an idle desktop produces zero churn.
  property int batteryPercent: -1
  property bool batteryCharging: false

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: batteryProbe.running = true
  }

  Process {
    id: batteryProbe
    command: ["sh", "-c",
      'b=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1); ' +
      '[ -n "$b" ] || exit 1; ' +
      'for f in status charge_now charge_full capacity; do ' +
      '  if [ -r "$b/$f" ]; then cat "$b/$f"; else echo; fi; done']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.split("\n")
        var st = TouchBar.parseBattery(
          (lines[0] || "").trim(), (lines[1] || "").trim(),
          (lines[2] || "").trim(), (lines[3] || "").trim())
        if (st === null) return

        var bucket = TouchBar.batteryBucket(st.percent, st.charging)
        root.batteryPercent = st.percent
        root.batteryCharging = st.charging
        if (bucket === root.batteryBucket) return

        root.batteryBucket = bucket
        batterySvgFile.setText(TouchBar.batterySvg(st.percent, st.charging))
        stateCoalesce.restart()
      }
    }
  }

  // ---- config file --------------------------------------------------------

  // Per-machine knobs. Absent on most installs, in which case the defaults
  // above stand.
  FileView {
    path: root.etcDir + "/touchbar.conf"
    printErrors: false
    onLoaded: {
      var m = text().match(/^\s*WORKSPACES\s*=\s*(\d+)\s*$/m)
      if (m) {
        var n = parseInt(m[1], 10)
        if (n > 0 && n <= 10) root.workspaceCount = n
      }
      root.sliderEnabled = /^\s*SLIDER\s*=\s*1\s*$/m.test(text())
      workspaceDebounce.restart()
    }
  }

  Component.onCompleted: {
    // Drop any context stranded across a reboot before anything is drawn.
    root.clearContextState()
  }

  IpcHandler {
    target: "touchbar"

    function status(): string {
      return JSON.stringify({
        workspace: root.activeWorkspace,
        workspaces: root.workspaceCount,
        context: root.context === "" ? null : root.context,
        battery: root.batteryPercent,
        charging: root.batteryCharging,
        micMuted: root.micMuted,
        nightlight: root.nightOn,
        updatePending: root.updatePending,
        slider: root.sliderEnabled,
        nonce: root.redrawNonce
      })
    }

    // Force a redraw, for when an icon changed underneath us -- tiny-dfr caches
    // icons at config load and only watches config.toml, so a repainted SVG
    // alone changes nothing on screen. This is what the theme hook calls after
    // regenerating the workspace pills.
    function redraw(): string {
      root.forceRedraw()
      return "ok"
    }
  }
}
