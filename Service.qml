import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property bool ok: true
  property bool vortaInstalled: false
  property bool borgInstalled: false
  property bool vortaRunning: false
  property bool backupRunning: false
  property string profileName: ""
  property string currentSsid: ""
  property var repoReachable: null   // null = local repo, nothing to probe
  property string repoHost: ""
  property string scheduleMode: "off"
  property string scheduleLabel: "manual"
  property int intervalSec: 0
  property bool makeUpMissed: true
  property string lastBackupAt: ""
  property double lastBackupTs: 0
  property var lastReturncode: null
  property bool lastOk: false
  property string lastFailureHint: ""
  property var archives: []
  property string statusText: "Checking…"
  property string lastError: ""
  property string actionStatus: ""
  property bool refreshing: false
  property double nowSec: Date.now() / 1000

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property int staleAfterHours: intSetting("staleAfterHours", 24, 1, 168)
  readonly property int failedAfterHours: intSetting("failedAfterHours", 48, 1, 336)
  readonly property string configuredProfile: String(setting("profileName", "") || "")
  readonly property string helperPath: pluginFile("status.py")
  readonly property bool busy: statusProcess.running || backupProcess.running
  readonly property string backupProfile: configuredProfile !== "" ? configuredProfile : profileName
  // An empty SSID is no Wi-Fi at all (cable, or radio off) and must not block a
  // backup -- it gates the "Backup now" button. See deriveState() in Model.js.
  readonly property bool repoAnswers: repoReachable !== false
  readonly property string state: Model.deriveState({
    backupRunning: backupRunning,
    lastReturncode: lastReturncode,
    lastBackupTs: lastBackupTs,
    vortaInstalled: vortaInstalled,
    repoReachable: repoReachable,
  }, nowSec, staleAfterHours, failedAfterHours)
  readonly property string stateText: Model.stateLabel(state, liveStatusText)
  readonly property string liveAgeLabel: lastBackupTs > 0 ? Model.ageLabel(nowSec - lastBackupTs) : "never"
  readonly property string liveStatusText: backupRunning ? "Backup running" : (lastBackupTs > 0 ? ("Last backup " + liveAgeLabel) : statusText)
  readonly property bool needsAction: Model.needsAction(state)
  readonly property var plan: Model.actionPlan(state, {
    lastFailureHint: lastFailureHint,
    liveAgeLabel: liveAgeLabel,
    vortaRunning: vortaRunning,
    lastReturncode: lastReturncode,
    repoReachable: repoReachable,
  })
  readonly property string nextText: Model.nextLabel({
    scheduleMode: scheduleMode,
    scheduleLabel: scheduleLabel,
    repoReachable: repoReachable,
    intervalSec: intervalSec,
    lastBackupTs: lastBackupTs,
    makeUpMissed: makeUpMissed
  }, nowSec)

  property string _statusOutput: ""
  property string _statusError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function pluginFile(name) {
    var url = String(Qt.resolvedUrl("./" + name) || "")
    if (url.indexOf("file://") === 0) url = url.substring(7)
    try {
      return decodeURIComponent(url)
    } catch (e) {
      return url
    }
  }

  function refresh() {
    if (statusProcess.running || helperPath === "") return
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    statusProcess.command = ["python3", helperPath, configuredProfile]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok && parsed.lastError) {
      lastError = parsed.lastError
      return
    }
    ok = parsed.ok !== false
    vortaInstalled = parsed.vortaInstalled === true
    borgInstalled = parsed.borgInstalled === true
    vortaRunning = parsed.vortaRunning === true
    backupRunning = parsed.backupRunning === true
    profileName = String(parsed.profileName || configuredProfile)
    currentSsid = String(parsed.currentSsid || "")
    repoReachable = parsed.repoReachable === undefined ? null : parsed.repoReachable
    repoHost = String(parsed.repoHost || "")
    scheduleMode = String(parsed.scheduleMode || "off")
    scheduleLabel = String(parsed.scheduleLabel || "manual")
    intervalSec = Number(parsed.intervalSec || 0)
    makeUpMissed = parsed.makeUpMissed !== false
    lastBackupAt = String(parsed.lastBackupAt || "")
    lastBackupTs = Number(parsed.lastBackupTs || 0)
    lastReturncode = parsed.lastReturncode === undefined ? null : parsed.lastReturncode
    lastOk = parsed.lastOk === true
    lastFailureHint = String(parsed.lastFailureHint || "")
    archives = parsed.archives || []
    statusText = String(parsed.statusText || "")
    lastError = ""
    nowSec = Date.now() / 1000
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  function startBackup() {
    if (backupProcess.running) return
    lastError = ""
    if (!repoAnswers) {
      lastError = "Backup server is not answering"
      actionStatus = lastError
      return
    }
    if (!vortaRunning) {
      actionStatus = "Starting Vorta…"
      Quickshell.execDetached(["vorta", "--daemonize"])
      startAfterVorta.restart()
      return
    }
    queueBackup()
  }

  function queueBackup() {
    var profile = backupProfile
    if (profile === "") {
      lastError = "No Vorta profile found"
      actionStatus = lastError
      return
    }
    actionStatus = "Starting backup…"
    backupProcess.command = ["vorta", "--create", profile]
    backupProcess.running = true
  }

  function openVorta() {
    actionStatus = "Opening Vorta"
    actionStatusTimer.restart()
    Quickshell.execDetached(["uwsm-app", "--", "vorta"])
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: clockTimer
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 2000
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 8 && !root.backupRunning) {
        ticks = 0
        running = false
      }
    }
  }

  Timer {
    id: startAfterVorta
    interval: 1800
    repeat: false
    onTriggered: root.queueBackup()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = root.elideStatus(stderr || stdout || "Could not read backup status")
    }
  }

  Process {
    id: backupProcess
    running: false
    command: []
    stdout: StdioCollector { id: backupStdout; waitForEnd: true }
    stderr: StdioCollector { id: backupStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stderr = String(backupStderr.text || "")
      var stdout = String(backupStdout.text || "")
      if (exitCode !== 0) {
        root.lastError = root.elideStatus(stderr || stdout || "Could not start backup")
        root.actionStatus = root.lastError
      } else {
        root.lastError = ""
        root.actionStatus = "Backup queued"
        root.actionStatusTimer.restart()
      }
      settleTimer.ticks = 0
      settleTimer.restart()
      root.refresh()
    }
  }
}
