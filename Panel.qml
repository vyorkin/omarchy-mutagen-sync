import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Mutagen's synchronization sessions in the Omarchy bar.
//
// Quiet by default: while every session watches, the bar shows the sync glyph
// and nothing else. A count appears when sessions want attention — endpoint not
// connected, session not watching, or paused — and conflicts switch the glyph to
// the theme's urgent colour. Scan problems (Mutagen refusing absolute symlinks)
// deliberately never colour the bar: they are normal for a repository that
// carries those links in a file instead, so they are reported in the popup and
// in the tooltip text and nothing more.
//
// Cost: one `mutagen sync list` per poll, through the compact Go template in
// Model.js (~10 ms against the daemon, ~1.6 kB for thirty sessions). One poll is
// in flight at a time, and every poll runs on a fresh Process object: a reused
// one can lose its exit event and then report running forever, which would stop
// the widget for the rest of the session.
//
// Actions: click toggles the popup, middle click polls now, `r` polls now,
// Enter (or a click on a row) forces that session to sync now, Escape closes.
Panel {
  id: root

  moduleName: "io.github.vyorkin.mutagen-sync"
  ipcTarget: "io.github.vyorkin.mutagen-sync"

  property var sessions: []
  property var totals: Model.emptyTotals()
  property string errorText: ""
  property int selectedIndex: 0
  property int runEpoch: 0
  property bool pollRunning: false
  property bool killSent: false
  property double deadlineAt: 0
  property var activePoll: null
  // Tri-state on purpose: -1 is "not asked yet", 0 is "mutagen is not installed",
  // 1 is "mutagen is there". The first poll asks before it spawns anything.
  property int presence: -1
  property int failures: 0
  property bool probeRunning: false
  property var activeProbe: null

  readonly property color foreground: bar && bar.barForeground !== undefined
    ? bar.barForeground : Color.foreground
  readonly property color urgent: Color.urgent
  readonly property color textColor: Color.popups.text
  readonly property color dimText: Qt.darker(textColor, 1.5)
  readonly property color dimForeground: Qt.darker(foreground, 1.6)
  readonly property string glyphSync: "󰓦"
  readonly property string glyphDown: "󰅖"

  // A mutagen that is not installed is a fact, not an alarm: it stays quiet, and
  // the widget only asks again once a minute.
  readonly property bool missing: presence === 0
  readonly property bool down: errorText !== "" && !missing
  readonly property int conflicts: totals.conflicts
  readonly property int attention: totals.attention
  readonly property int pollIntervalMs: missing || failures >= Model.FAILURE_BACKOFF_AFTER
    ? Model.IDLE_INTERVAL_MS
    : (opened ? Model.POLL_INTERVAL_OPEN_MS : Model.POLL_INTERVAL_MS)

  readonly property string barText: {
    if (missing || down) return glyphDown
    var count = conflicts > 0 ? conflicts : attention
    return count > 0 ? glyphSync + " " + count : glyphSync
  }
  readonly property color barColor: down ? urgent
    : missing ? dimForeground
    : conflicts > 0 ? urgent
    : foreground

  readonly property string tooltipText: {
    if (missing) return "Mutagen: not installed"
    if (down) return "Mutagen: " + errorText
    if (totals.total === 0) return "Mutagen: no sessions"
    var line = "Mutagen: " + totals.total + " sessions, " + totals.watching + " watching"
    if (conflicts > 0) line += " · " + conflicts + " conflicts"
    if (attention > 0) line += " · " + attention + " to look at"
    if (totals.problems > 0) line += " · " + totals.problems + " symlink notes"
    return line
  }

  readonly property string summaryText: {
    if (missing) return "not installed"
    if (down) return "daemon not reachable"
    if (totals.total === 0) return "no sessions"
    var parts = [totals.total + " sessions", totals.watching + " watching"]
    if (totals.paused > 0) parts.push(totals.paused + " paused")
    if (attention > 0) parts.push(attention + " to look at")
    if (totals.problems > 0) parts.push(totals.problems + " symlink notes")
    return parts.join(" · ")
  }

  // ---------------------------------------------------------------- polling ---

  Timer {
    id: pollTimer
    interval: root.pollIntervalMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  // A poll that outlives its deadline lost its exit event or is stuck behind a
  // wedged daemon. First strike kills the child, second strike drops the object
  // so the next tick starts on a fresh one.
  Timer {
    id: watchdog
    interval: 1000
    repeat: true
    running: true
    onTriggered: root.checkWatchdog()
  }

  Component {
    id: pollComponent

    Process {
      id: poll
      property int runEpoch: 0
      property bool released: false
      property string collected: ""
      property var collector: out
      property var errorCollector: err
      command: Model.listCommand()

      stdout: StdioCollector {
        id: out
        waitForEnd: true
        onStreamFinished: poll.collected = text
      }
      stderr: StdioCollector {
        id: err
        waitForEnd: true
      }
      onExited: function(exitCode) { root.finishPoll(poll, exitCode) }
    }
  }

  Component {
    id: probeComponent

    Process {
      id: probeProc
      property bool released: false
      command: Model.presenceCommand()
      onExited: function(exitCode) { root.finishProbe(probeProc, exitCode) }
    }
  }

  // A probe is `sh -c command -v`, which cannot take a minute: this only guards
  // against a Process that never reports back at all.
  Timer {
    id: probeWatchdog
    interval: 15000
    running: root.probeRunning
    onTriggered: {
      if (root.activeProbe) {
        try { root.activeProbe.destroy() } catch (error) { /* already gone */ }
        root.activeProbe = null
      }
      root.probeRunning = false
      root.presence = -1
    }
  }

  Component {
    id: flushComponent

    Process {
      id: flush
      property var onDone: null
      command: []
      onExited: function() {
        var done = flush.onDone
        flush.destroy()
        if (done) done()
      }
    }
  }

  function poll() {
    if (pollRunning) return

    // Nothing is spawned before the widget knows mutagen is there: invoking a
    // missing binary makes Quickshell log a warning on every attempt.
    if (presence !== 1) {
      probe()
      return
    }

    pollRunning = true

    var process = pollComponent.createObject(root, { runEpoch: ++runEpoch })
    if (!process) {
      pollRunning = false
      console.warn("mutagen-sync: could not create the poll process")
      return
    }

    activePoll = process
    killSent = false
    deadlineAt = Date.now() + Model.POLL_TIMEOUT_MS
    process.running = true
  }

  function probe() {
    if (probeRunning) return
    probeRunning = true

    var process = probeComponent.createObject(root)
    if (!process) {
      probeRunning = false
      console.warn("mutagen-sync: could not create the presence probe")
      return
    }
    activeProbe = process
    process.running = true
  }

  function finishProbe(process, exitCode) {
    if (process && !process.released) {
      process.released = true
      process.destroy()
    }
    activeProbe = null
    probeRunning = false
    presence = exitCode === 0 ? 1 : 0

    if (presence === 0) {
      errorText = ""
      sessions = []
      totals = Model.emptyTotals()
      selectedIndex = 0
      return
    }

    failures = 0
    poll()
  }

  function releasePoll(process) {
    if (!process || process.released) return
    process.released = true
    if (activePoll === process) activePoll = null
    process.destroy()
  }

  function checkWatchdog() {
    var process = activePoll
    if (!process || Date.now() < deadlineAt) return

    if (!killSent) {
      killSent = true
      console.warn("mutagen-sync: poll did not finish within "
                   + Math.round(Model.POLL_TIMEOUT_MS / 1000) + " s; killing it")
      ++runEpoch            // whatever it returns now belongs to a dead run
      process.runEpoch = -1
      try { process.signal(9) } catch (error) { /* object may be gone */ }
      try { process.running = false } catch (error) { /* ditto */ }
      return
    }

    releasePoll(process)
    pollRunning = false
  }

  function finishPoll(process, exitCode) {
    if (!process || process.released) return

    var stale = process.runEpoch !== runEpoch
    // The collector can finish a hair after the exit notification; fall back to
    // its own text so a fast exit is not read as "no sessions".
    var output = process.collected !== ""
      ? process.collected : (process.collector ? process.collector.text : "")
    var failure = process.errorCollector
      ? String(process.errorCollector.text || "").trim() : ""

    releasePoll(process)
    pollRunning = false
    if (stale) return

    if (exitCode !== 0) {
      // The binary may have been removed since the last probe; ask again rather
      // than shouting the same failure every interval.
      presence = -1
      failures++
      errorText = failure !== ""
        ? failure.split("\n")[0]
        : "mutagen exited with code " + exitCode
      sessions = []
      totals = Model.emptyTotals()
      selectedIndex = 0
      return
    }

    errorText = ""
    failures = 0
    var parsed = Model.parseSessions(output)
    sessions = parsed
    totals = Model.summarize(parsed)
    if (selectedIndex > parsed.length - 1)
      selectedIndex = Math.max(0, parsed.length - 1)
  }

  function moveSelection(delta) {
    if (sessions.length === 0) return
    var next = selectedIndex + delta
    selectedIndex = Math.max(0, Math.min(sessions.length - 1, next))
  }

  function flushSelected() {
    if (down || missing || presence !== 1 || sessions.length === 0) return
    var session = sessions[selectedIndex]
    if (!session) return

    var process = flushComponent.createObject(root, {
      command: Model.flushCommand(session.name),
      onDone: function() { root.poll() }
    })
    if (!process) return
    process.running = true
  }

  onOpenedChanged: if (opened) poll()

  // -------------------------------------------------------------------- bar ---

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    foreground: root.barColor
    tooltipText: root.tooltipText

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.poll()
      else root.toggle()
    }
  }

  // ----------------------------------------------------------------- popup ---

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveSelection(dy) }
      onActivateRequested: root.flushSelected()
      onReturnRequested: root.flushSelected()
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (text === "r") root.poll()
        else if (text === "f") root.flushSelected()
      }

      Column {
        id: body
        width: parent.width
        spacing: Style.spacing.controlGap

        RowLayout {
          width: parent.width
          spacing: Style.spacing.controlGap

          PanelSectionHeader {
            text: "Mutagen"
            foreground: root.textColor
          }

          Item { Layout.fillWidth: true }

          Text {
            text: root.summaryText
            color: root.down ? root.urgent : root.dimText
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }
        }

        PanelSeparator { foreground: root.textColor }

        Text {
          visible: root.down
          width: parent.width
          text: root.errorText
          color: root.urgent
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          textFormat: Text.PlainText
        }

        Text {
          visible: !root.down && root.sessions.length === 0
          width: parent.width
          text: "No sessions"
          color: root.dimText
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          textFormat: Text.PlainText
        }

        ListView {
          id: list
          width: parent.width
          visible: !root.down && root.sessions.length > 0
          height: Math.min(root.sessions.length, Model.MAX_ROWS) * Style.space(24)
          clip: true
          interactive: contentHeight > height
          model: root.sessions
          currentIndex: root.selectedIndex

          delegate: Rectangle {
            id: row
            required property int index
            required property var modelData

            width: list.width
            height: Style.space(24)
            radius: Style.cornerRadius
            color: row.index === root.selectedIndex
              ? Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.08)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                text: row.modelData.short
                color: root.textColor
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                elide: Text.ElideMiddle
                textFormat: Text.PlainText
              }

              Text {
                visible: row.modelData.conflicts > 0
                text: row.modelData.conflicts + " conflict"
                  + (row.modelData.conflicts === 1 ? "" : "s")
                color: root.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }

              Text {
                visible: row.modelData.problems > 0
                text: row.modelData.problems + " symlink"
                  + (row.modelData.problems === 1 ? "" : "s")
                color: root.dimText
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }

              Text {
                text: Model.statusLabel(row.modelData)
                color: row.modelData.healthy ? root.dimText : root.textColor
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedIndex = row.index
              onClicked: root.flushSelected()
            }
          }
        }

        PanelSeparator {
          visible: !root.down && root.sessions.length > 0
          foreground: root.textColor
        }

        Text {
          width: parent.width
          text: "Enter — sync now · r — refresh · middle click — refresh"
          color: root.dimText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
        }
      }
    }
  }
}
