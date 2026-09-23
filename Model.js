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
    repoReachable: null,
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
  if (state === "unreachable") {
    var host = String(extra.repoHost || "the backup server")
    return {
      title: "Backup server unreachable",
      body: host + " is not answering, so a backup cannot run right now.",
      steps: [
        "This is expected when away without a VPN tunnel",
        "Connect to the network the repository lives on, or bring the tunnel up",
        "A backup will run automatically once it answers"
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
  // A remote repository that does not answer is the one condition that makes a
  // backup impossible, whatever network we are on. This replaced a Wi-Fi SSID
  // comparison, which asked about location instead: it blocked backups over a
  // VPN tunnel, and it could not tell apart two places sharing an SSID.
  // null means a local repository, where there is nothing to probe.
  if (status && status.repoReachable === false) return "unreachable"
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
  if (state === "unreachable") return "Backup server unreachable"
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
  if (status.repoReachable === false) return "when the repo answers again"
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
