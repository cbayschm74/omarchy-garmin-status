import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Third-party bar widget. The host injects bar, moduleName, and settings.
// An empty statusCommand runs the bundled status.py through python3.
// An explicit statusCommand or launchCommand replaces that default.
// Nothing here is joined into a shell command, and this file does not read
// Garmin volumes itself.
BarWidget {
  id: root
  moduleName: "org.garminlinux.status"

  property string statusState: "disconnected"
  property int volumeCount: 0
  property int deviceCount: 0
  property string displayText: "Garmin"
  property string statusTooltip: "No Garmin USB storage"
  property string pendingStdout: ""
  property bool statusSettled: true
  property bool killedByWatchdog: false

  readonly property int pollIntervalSec: {
    var configured = parseInt(String(setting("pollIntervalSec", 30)), 10)
    if (!isFinite(configured)) configured = 30
    if (configured < 15) configured = 15
    if (configured > 3600) configured = 3600
    return configured
  }

  // Stay above the module's 5s lsblk timeout and strictly below the next poll,
  // so a hung process is reaped before another one can start.
  readonly property int commandTimeoutSec: {
    var configured = parseInt(String(setting("commandTimeoutSec", 8)), 10)
    if (!isFinite(configured)) configured = 8
    if (configured < 6) configured = 6
    var cap = Math.max(6, pollIntervalSec - 1)
    if (configured > cap) configured = cap
    return configured
  }

  readonly property string visibleTooltip: {
    var command = launchCommand()
    if (command.length === 0) return statusTooltip
    return statusTooltip === "" ? "Open Garmin Linux Companion" : statusTooltip + "\nOpen Garmin Linux Companion"
  }

  function asList(value) {
    if (Array.isArray(value)) return value
    // shell.json arrays can arrive as a Qt list with length but fail Array.isArray.
    if (value && typeof value !== "string" && typeof value.length === "number") return value
    return null
  }

  function commandArgv(value) {
    var parsed = value
    if (typeof parsed === "string") {
      var trimmed = parsed.trim()
      if (trimmed === "") return []
      if (trimmed.charAt(0) === "[") {
        try {
          parsed = JSON.parse(trimmed)
        } catch (error) {
          return []
        }
      } else if (trimmed.indexOf("\n") === -1 && trimmed.indexOf("\u0000") === -1) {
        return [trimmed]
      } else {
        return []
      }
    }
    var items = asList(parsed)
    if (!items) return []
    var command = []
    for (var i = 0; i < items.length; i++) {
      var part = items[i]
      if (typeof part !== "string" || part.length === 0) return []
      if (part.indexOf("\n") !== -1 || part.indexOf("\r") !== -1 || part.indexOf("\u0000") !== -1) return []
      command.push(part)
    }
    return command
  }

  function launchCommand() {
    return commandArgv(setting("launchCommand", []))
  }

  function bundledStatusCommand() {
    var path = decodeURIComponent(String(Qt.resolvedUrl("status.py")).replace(/^file:\/\//, ""))
    if (path.charAt(0) !== "/") return []
    if (path.indexOf("\n") !== -1 || path.indexOf("\r") !== -1 || path.indexOf("\u0000") !== -1) return []
    return ["python3", "-B", path]
  }

  function workingDirectory() {
    var value = setting("workingDirectory", "")
    if (typeof value !== "string" || value.charAt(0) !== "/") return ""
    if (value.indexOf("\n") !== -1 || value.indexOf("\r") !== -1 || value.indexOf("\u0000") !== -1) return ""
    return value
  }

  function applyLocal(tooltip) {
    statusState = "error"
    volumeCount = 0
    deviceCount = 0
    displayText = "Garmin"
    statusTooltip = tooltip
  }

  function lastLine(raw) {
    var text = String(raw || "").replace(/\r/g, "").trim()
    if (text === "") return ""
    var parts = text.split("\n")
    return String(parts[parts.length - 1] || "").trim()
  }

  function bounded(value, max) {
    return value.length > max ? value.substring(0, max) : value
  }

  function parseStatus(raw) {
    var parsed
    try {
      parsed = JSON.parse(lastLine(raw))
    } catch (error) {
      return null
    }
    if (!parsed || (parsed.state !== "connected" && parsed.state !== "disconnected" && parsed.state !== "error"))
      return null
    var count = parsed.volume_count
    if (typeof count !== "number" || !isFinite(count) || Math.floor(count) !== count || count < 0) return null
    if (parsed.state === "connected" ? count < 1 : count !== 0) return null
    var devices = parsed.device_count
    if (typeof devices !== "number" || !isFinite(devices) || Math.floor(devices) !== devices || devices < 0) return null
    if (parsed.state === "connected" ? (devices < 1 || devices > count) : devices !== 0) return null
    if (typeof parsed.text !== "string" || typeof parsed.tooltip !== "string") return null
    return {
      state: parsed.state,
      volumeCount: count,
      deviceCount: devices,
      text: bounded(parsed.text, 40),
      tooltip: bounded(parsed.tooltip, 180)
    }
  }

  function refresh() {
    if (statusProcess.running) return
    var command = commandArgv(setting("statusCommand", []))
    if (command.length === 0) command = bundledStatusCommand()
    if (command.length === 0) {
      statusSettled = true
      killedByWatchdog = false
      applyLocal("Status command is not configured")
      return
    }
    pendingStdout = ""
    statusSettled = false
    killedByWatchdog = false
    var directory = workingDirectory()
    if (directory !== "") statusProcess.workingDirectory = directory
    statusProcess.command = command
    statusProcess.running = true
    watchdog.interval = commandTimeoutSec * 1000
    if (!watchdog.running) watchdog.start()
  }

  function finishStatus(exitCode) {
    if (statusSettled) return
    statusSettled = true
    watchdog.stop()
    sigkillTimer.stop()
    if (killedByWatchdog) {
      killedByWatchdog = false
      applyLocal("Status command timed out")
      return
    }
    if (exitCode !== 0) {
      applyLocal("Status command failed")
      return
    }
    var parsed = parseStatus(pendingStdout !== "" ? pendingStdout : statusOut.text)
    if (!parsed) {
      applyLocal(exitCode === 0 ? "Status command returned malformed JSON" : "Status command failed")
      return
    }
    statusState = parsed.state
    volumeCount = parsed.volumeCount
    deviceCount = parsed.deviceCount
    displayText = parsed.text
    statusTooltip = parsed.tooltip
  }

  function terminateStuck() {
    if (!statusProcess.running) return
    killedByWatchdog = true
    statusProcess.signal(15) // SIGTERM
    sigkillTimer.restart()
  }

  function forceKill() {
    if (!statusProcess.running) {
      if (!statusSettled && killedByWatchdog) finishStatus(1)
      return
    }
    killedByWatchdog = true
    statusProcess.signal(9) // SIGKILL
    statusProcess.running = false
    finishStatus(1)
  }

  function launch() {
    var command = launchCommand()
    if (command.length === 0) return
    Quickshell.execDetached(command)
  }

  onSettingsChanged: Qt.callLater(root.refresh)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    id: pollTimer
    interval: root.pollIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: watchdog
    repeat: false
    onTriggered: root.terminateStuck()
  }

  Timer {
    id: sigkillTimer
    interval: 1000
    repeat: false
    onTriggered: root.forceKill()
  }

  Process {
    id: statusProcess
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
      onStreamFinished: root.pendingStdout = String(text || "")
    }
    // A failed exec can return to stopped without an exited signal. Defer
    // until after normal exited delivery so a successful exit keeps its code.
    onRunningChanged: if (!running && !root.statusSettled) Qt.callLater(function() {
      if (!statusProcess.running && !root.statusSettled) root.finishStatus(1)
    })
    onExited: function(exitCode) {
      root.finishStatus(exitCode)
    }
  }

  // Diagnostics expose only the same sanitized state rendered on the bar.
  IpcHandler {
    target: "org.garminlinux.status"
    function status(): string {
      return JSON.stringify({state: root.statusState, device_count: root.deviceCount, volume_count: root.volumeCount,
                             text: root.displayText, tooltip: root.statusTooltip})
    }
    function refresh(): void { root.broadcast("refresh") }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.visibleTooltip
    active: root.statusState === "error"
    dimmed: root.statusState === "disconnected"
    // Use exactly the host's standard icon slot and optical canvas.
    slotSize: Style.bar.iconSlot
    opticalSize: Style.bar.iconCanvas
    iconComponent: Component {
      Canvas {
        property color ink: button.active ? button.activeColor : button.foreground
        onInkChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.fillStyle = ink
          // Compact Garmin-style triangular mark; no USB glyph or wordmark.
          ctx.beginPath()
          ctx.moveTo(width * 0.5, height * 0.06)
          ctx.lineTo(width * 0.94, height * 0.88)
          ctx.lineTo(width * 0.06, height * 0.88)
          ctx.closePath()
          ctx.fill()
        }
      }
    }

    Rectangle {
      objectName: "deviceCountBadge"
      visible: root.statusState === "connected" && root.deviceCount > 0
      width: Math.max(10, countText.implicitWidth + 3)
      height: 11
      radius: 3
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: 1
      anchors.topMargin: 1
      color: root.bar ? root.bar.background : "#202020"
      Text {
        id: countText
        anchors.centerIn: parent
        text: String(root.deviceCount)
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Math.max(9, Math.round(Style.font.caption * 0.9))
        font.bold: true
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.launch()
    }
  }
}
