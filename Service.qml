import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  // Only one Service instance (the bar's) may send notifications; the panel
  // runs a second instance for its own refreshes.
  property bool notify: false

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
  property var usb: ({ configured: false })
  property string _pendingProfile: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 10, 3600)
  readonly property int staleAfterHours: intSetting("staleAfterHours", 24, 1, 168)
  readonly property int failedAfterHours: intSetting("failedAfterHours", 48, 1, 336)
  readonly property string configuredProfile: String(setting("profileName", "") || "")
  readonly property string usbProfileName: String(setting("usbProfileName", "") || "")
  readonly property int usbIntervalDays: intSetting("usbIntervalDays", 30, 1, 365)
  readonly property bool usbConfigured: usb && usb.configured === true
  readonly property bool usbMounted: usbConfigured && usb.mounted === true
  readonly property bool usbDue: Model.usbDue(usb, nowSec, usbIntervalDays)
  readonly property string usbAgeLabel: usbConfigured && usb.lastBackupTs > 0 ? Model.ageLabel(nowSec - usb.lastBackupTs) : "never"
  readonly property string usbNextText: Model.usbNextLabel(usb, nowSec, usbIntervalDays)
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
    statusProcess.command = ["python3", helperPath, configuredProfile, usbProfileName]
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
    usb = parsed.usb || ({ configured: false })
    lastError = ""
    nowSec = Date.now() / 1000
    maybeNotifyUsb()
  }

  // At most two reminders per shell session: once when the copy is due, and
  // once more when the disk shows up while it is still due. The second one
  // carries a button that starts the backup.
  property bool _usbToldDue: false
  property bool _usbToldMounted: false

  function maybeNotifyUsb() {
    if (!usbDue) { _usbToldDue = false; _usbToldMounted = false; return }
    if (!notify || backupRunning || usbNotifyProcess.running) return
    var age = usb.lastBackupTs > 0 ? ("Last copy " + usbAgeLabel + ".") : "No copy yet."
    if (usbMounted && !_usbToldMounted) {
      _usbToldMounted = true
      _usbToldDue = true
      usbNotifyProcess.command = ["notify-send", "-a", "Borg", "-i", "drive-removable-media",
        "-A", "backup=Back up now", "USB backup due", age + " The disk is connected."]
      usbNotifyProcess.running = true
    } else if (!usbMounted && !_usbToldDue) {
      _usbToldDue = true
      usbNotifyProcess.command = ["notify-send", "-a", "Borg", "-i", "drive-removable-media",
        "USB backup due", age + " Plug in the backup disk, then start it from the Borg panel."]
      usbNotifyProcess.running = true
    }
  }

  function startUsbBackup() {
    if (backupProcess.running) return
    lastError = ""
    if (!usbConfigured) { lastError = "No USB profile configured"; actionStatus = lastError; return }
    if (!usbMounted) { lastError = "USB disk is not connected"; actionStatus = lastError; return }
    if (!vortaRunning) {
      actionStatus = "Starting Vorta…"
      Quickshell.execDetached(["vorta", "--daemonize"])
      _pendingProfile = usbProfileName
      startAfterVorta.restart()
      return
    }
    queueBackup(usbProfileName)
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
      _pendingProfile = ""
      startAfterVorta.restart()
      return
    }
    queueBackup("")
  }

  function queueBackup(which) {
    var profile = which || backupProfile
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
    onTriggered: root.queueBackup(root._pendingProfile)
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
    id: usbNotifyProcess
    running: false
    command: []
    stdout: StdioCollector { id: usbNotifyStdout; waitForEnd: true }
    onExited: if (String(usbNotifyStdout.text || "").trim() === "backup") root.startUsbBackup()
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
