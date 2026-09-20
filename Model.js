function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    parsed.archives = Array.isArray(parsed.archives) ? parsed.archives : []
    return parsed
  } catch (e) {
    var failed = defaultStatus()
    failed.ok = false
    failed.lastError = "Failed to parse Borg status"
    return failed
  }
}

function defaultStatus() {
  return {
    ok: true,
    vortaInstalled: false,
    borgInstalled: false,
    vortaRunning: false,
    backupRunning: false,
    profileName: "",
    currentSsid: "",
    repoHost: "",
    scheduleMode: "off",
    scheduleLabel: "manual",
    scheduleCount: 4,
    scheduleUnit: "hours",
    makeUpMissed: true,
    intervalSec: 14400,
    lastBackupAt: "",
    lastBackupTs: 0,
    lastBackupAgeSec: null,
    lastBackupAgeLabel: "never",
    lastReturncode: null,
    lastOk: false,
    lastFailureHint: "",
    archives: [],
    statusText: "Checking…"
  }
}

function needsAction(state) {
  return state === "failed" || state === "overdue" || state === "never" || state === "missing"
}

function actionPlan(state, extra) {
  extra = extra || {}
  var hint = String(extra.lastFailureHint || "").trim()
  var age = String(extra.liveAgeLabel || "")
  var code = extra.lastReturncode

  if (state === "failed") {
    return {
      title: "Last backup failed",
      body: hint || ("Borg exited with code " + code + ". The last run did not finish."),
      steps: [
        "Stay on the home network",
        "Click Backup now",
        "If it fails again, open Vorta and read the log"
      ],
      primary: "backup"
    }
  }
  if (state === "away") {
    var home = String(extra.homeSsid || "home Wi-Fi")
    var current = String(extra.currentSsid || "none")
    return {
      title: "Not on home Wi-Fi",
      body: "Backups only run on " + home + ". Current network: " + current + ".",
      steps: [
        "This is expected when traveling",
        "Connect to " + home + " at home",
        "A backup will run automatically, or click Backup now once you are home"
      ],
      primary: ""
    }
  }
  if (state === "overdue") {
    return {
      title: "Backup is overdue",
      body: "No successful backup in " + (age || "a long time") + ". The laptop was probably off or away from the backup server.",
      steps: [
        "Connect to the home network",
        "Click Backup now"
      ],
      primary: "backup"
    }
  }
  if (state === "never") {
    return {
      title: "No backup yet",
      body: "Vorta has no completed backup recorded for this profile.",
      steps: [
        "Open Vorta and confirm the repository is connected",
        "Click Backup now"
      ],
      primary: "vorta"
    }
  }
  if (state === "missing") {
    return {
      title: "Vorta is not installed",
      body: "This widget needs Vorta on PATH.",
      steps: [
        "Install Vorta",
        "Add a repository, then refresh this panel"
      ],
      primary: "refresh"
    }
  }
  return { title: "", body: "", steps: [], primary: "backup" }
}

function ageLabel(seconds) {
  if (seconds === null || seconds === undefined || !isFinite(seconds)) return "never"
  var sec = Math.max(0, Math.floor(seconds))
  if (sec < 60) return "just now"
  var minutes = Math.floor(sec / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 48) return hours + "h ago"
  var days = Math.floor(hours / 24)
  return days + "d ago"
}

function deriveState(status, nowSec, staleAfterHours, failedAfterHours) {
  if (status && status.backupRunning) return "running"
  if (status && status.lastReturncode !== null && status.lastReturncode !== undefined
      && status.lastReturncode > 1) return "failed"
  var home = String((status && status.homeSsid) || "")
  var current = String((status && status.currentSsid) || "")
  // An empty SSID means there is no Wi-Fi connection at all -- a cable, or the
  // radio switched off. That is not evidence of being away from the backup
  // server, so only a *different* Wi-Fi counts as away.
  if (home !== "" && current !== "" && current !== home) return "away"
  var ts = status && status.lastBackupTs ? Number(status.lastBackupTs) : 0
  if (!ts) return status && status.vortaInstalled ? "never" : "missing"
  var ageHours = Math.max(0, (nowSec - ts) / 3600)
  if (ageHours >= failedAfterHours) return "overdue"
  if (ageHours >= staleAfterHours) return "stale"
  return "ok"
}

function stateLabel(state, statusText) {
  if (state === "running") return "Backing up"
  if (state === "failed") return "Last backup failed"
  if (state === "away") return "Waiting for home Wi-Fi"
  if (state === "overdue") return "Backup overdue"
  if (state === "stale") return "Backup getting old"
  if (state === "never") return "No backups yet"
  if (state === "missing") return "Vorta is not installed"
  return statusText || "Up to date"
}

function resultLabel(code) {
  if (code === null || code === undefined) return "—"
  if (code === 0) return "ok"
  if (code === 1) return "ok (warnings)"
  return "failed (" + code + ")"
}

function nextLabel(status, nowSec) {
  if (!status) return "—"
  var home = String(status.homeSsid || "")
  var current = String(status.currentSsid || "")
  if (home !== "" && current !== home) return "when back on " + home
  if (status.scheduleMode !== "interval") return status.scheduleLabel || "manual"
  var interval = Number(status.intervalSec || 0)
  var last = Number(status.lastBackupTs || 0)
  if (!interval || !last) return status.scheduleLabel || "—"
  var next = last + interval
  if (next <= nowSec) {
    if (status.makeUpMissed) return "on next catch-up"
    return "waiting for next window"
  }
  return "in " + ageLabel(next - nowSec).replace(" ago", "")
}
