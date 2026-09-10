#!/usr/bin/env python3
"""Read Vorta/Borg status for the Omarchy bar plugin.

Never talks to a backup server and never reads passphrases or SSH keys.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
from datetime import datetime
from pathlib import Path

VORTA_DB = Path.home() / ".local/share/Vorta/settings.db"
VORTA_LOG = Path.home() / ".local/state/Vorta/log/vorta.log"


def which(name: str) -> bool:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if directory and os.access(os.path.join(directory, name), os.X_OK):
            return True
    return False


def cmdline_of(pid: str) -> str:
    try:
        raw = Path("/proc", pid, "cmdline").read_bytes()
    except OSError:
        return ""
    return raw.replace(b"\x00", b" ").decode("utf-8", "replace")


def current_ssid() -> str:
    """The broadcast SSID of the connected AP, not the NetworkManager
    connection profile name -- NM can autoconnect via a differently-named
    duplicate profile (e.g. "Home" vs "Home 1") for the same physical
    network, which would otherwise cause a false SSID mismatch."""
    try:
        completed = subprocess.run(
            ["nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi"],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    for line in completed.stdout.splitlines():
        active, sep, ssid = line.partition(":")
        if sep and active == "yes":
            return ssid
    return ""


def scan_procs() -> tuple[bool, bool]:
    vorta = False
    borg_create = False
    try:
        pids = os.listdir("/proc")
    except OSError:
        return False, False
    for pid in pids:
        if not pid.isdigit():
            continue
        cmd = cmdline_of(pid)
        if not cmd:
            continue
        if "/usr/bin/vorta" in cmd or cmd.endswith(" vorta") or " vorta " in cmd or cmd.rstrip().endswith("vorta"):
            if "status.py" not in cmd:
                vorta = True
        if "borg create" in cmd or "/usr/bin/borg create" in cmd:
            borg_create = True
    return vorta, borg_create


def parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    text = str(value).strip()
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def age_label(seconds: float | None) -> str:
    if seconds is None:
        return "never"
    sec = max(0, int(seconds))
    if sec < 60:
        return "just now"
    minutes = sec // 60
    if minutes < 60:
        return f"{minutes}m ago"
    hours = minutes // 60
    if hours < 48:
        return f"{hours}h ago"
    days = hours // 24
    return f"{days}d ago"


def schedule_label(mode: str, count: int, unit: str) -> str:
    if mode == "interval":
        if count == 1:
            noun = {"minutes": "minute", "hours": "hour", "days": "day", "weeks": "week"}.get(unit, unit)
            return f"every {noun}"
        return f"every {count} {unit}"
    if mode == "fixed":
        return "daily at a fixed time"
    return "manual"


def interval_seconds(count: int, unit: str) -> int:
    multipliers = {"minutes": 60, "hours": 3600, "days": 86400, "weeks": 604800}
    return max(0, int(count)) * multipliers.get(unit, 0)


def repo_display_name(url: str, repo_name: str, profile_name: str) -> str:
    """Hostname or 'local' only — never user, port, or path."""
    if repo_name:
        return repo_name
    raw = url or ""
    if raw.startswith("/") or raw.startswith("file://"):
        return "local"
    host = raw
    if "://" in host:
        host = host.split("://", 1)[1]
    if "@" in host:
        host = host.split("@", 1)[1]
    host = host.split("/", 1)[0]
    host = host.split(":", 1)[0]
    return host or profile_name or "borg"


def sanitize_hint(text: str) -> str:
    t = str(text or "").strip()
    t = re.sub(r"^[\d\-T:,. ]+ - \S+ - (ERROR|WARNING|INFO|DEBUG) - ", "", t)
    t = re.sub(r"ssh://\S+", "the backup server", t)
    t = re.sub(r"file://\S+", "a local path", t)
    t = re.sub(r"/volume\S+", "the repository", t)
    t = re.sub(r"(?i)passphrase\S*", "passphrase", t)
    t = re.sub(r"\s+", " ", t).strip()
    if t.startswith("Remote: "):
        t = t[len("Remote: ") :].strip()
    return t[:180] + ("…" if len(t) > 180 else "")


def failure_hint(returncode: int | None) -> str:
    if returncode is None or returncode <= 1:
        return ""
    fd = -1
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        fd = os.open(VORTA_LOG, flags)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return f"Borg exited with code {returncode}."
        with open(fd, "rb", closefd=True) as f:
            fd = -1
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 256 * 1024))
            tail = f.read().decode("utf-8", errors="replace")
        lines = tail.splitlines()[-250:]
    except OSError:
        return f"Borg exited with code {returncode}."
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass
    for line in reversed(lines):
        if "objc" in line or "DEBUG" in line:
            continue
        if " ERROR " in line or "Error during backup" in line or "Could not" in line:
            hint = sanitize_hint(line)
            if hint:
                return hint
    return f"Borg exited with code {returncode}."


def open_db() -> sqlite3.Connection | None:
    if not VORTA_DB.exists():
        return None
    uri = f"file:{VORTA_DB}?mode=ro"
    try:
        con = sqlite3.connect(uri, uri=True, timeout=1.0)
        con.row_factory = sqlite3.Row
        return con
    except sqlite3.Error:
        return None


def load_status(profile_name: str) -> dict:
    now = datetime.now()
    vorta_installed = which("vorta")
    borg_installed = which("borg")
    vorta_running, backup_running = scan_procs()

    payload = {
        "ok": True,
        "vortaInstalled": vorta_installed,
        "borgInstalled": borg_installed,
        "vortaRunning": vorta_running,
        "backupRunning": backup_running,
        "profileName": profile_name,
        "currentSsid": current_ssid(),
        "repoHost": "",
        "scheduleMode": "off",
        "scheduleLabel": "manual",
        "scheduleCount": 0,
        "scheduleUnit": "hours",
        "makeUpMissed": True,
        "intervalSec": 0,
        "lastBackupAt": "",
        "lastBackupTs": 0,
        "lastBackupAgeSec": None,
        "lastBackupAgeLabel": "never",
        "lastReturncode": None,
        "lastOk": False,
        "lastFailureHint": "",
        "archives": [],
        "statusText": "No backups yet",
    }

    con = open_db()
    if con is None:
        payload["ok"] = vorta_installed
        payload["statusText"] = "Vorta not configured" if vorta_installed else "Vorta is not installed"
        return payload

    try:
        profile = None
        if profile_name:
            profile = con.execute(
                """
                SELECT p.name, p.schedule_mode, p.schedule_interval_count, p.schedule_interval_unit,
                       p.schedule_make_up_missed, r.url, r.name AS repo_name
                FROM backupprofilemodel p
                LEFT JOIN repomodel r ON r.id = p.repo_id
                WHERE p.name = ?
                """,
                (profile_name,),
            ).fetchone()
        if profile is None:
            profile = con.execute(
                """
                SELECT p.name, p.schedule_mode, p.schedule_interval_count, p.schedule_interval_unit,
                       p.schedule_make_up_missed, r.url, r.name AS repo_name
                FROM backupprofilemodel p
                LEFT JOIN repomodel r ON r.id = p.repo_id
                ORDER BY p.id
                LIMIT 1
                """
            ).fetchone()
        if profile is not None:
            payload["profileName"] = profile["name"] or profile_name
            payload["scheduleMode"] = profile["schedule_mode"] or "off"
            payload["scheduleCount"] = int(profile["schedule_interval_count"] or 0)
            payload["scheduleUnit"] = profile["schedule_interval_unit"] or "hours"
            payload["makeUpMissed"] = bool(profile["schedule_make_up_missed"])
            payload["scheduleLabel"] = schedule_label(
                payload["scheduleMode"], payload["scheduleCount"], payload["scheduleUnit"]
            )
            payload["intervalSec"] = interval_seconds(payload["scheduleCount"], payload["scheduleUnit"])
            payload["repoHost"] = repo_display_name(
                profile["url"] or "",
                profile["repo_name"] or "",
                payload["profileName"],
            )

        event = con.execute(
            """
            SELECT start_time, end_time, returncode
            FROM eventlogmodel
            WHERE subcommand = 'create'
            ORDER BY id DESC
            LIMIT 1
            """
        ).fetchone()
        if event is not None:
            ended = parse_dt(event["end_time"]) or parse_dt(event["start_time"])
            if ended is not None:
                payload["lastBackupAt"] = ended.strftime("%Y-%m-%d %H:%M")
                payload["lastBackupTs"] = int(ended.timestamp())
                age = (now - ended).total_seconds()
                payload["lastBackupAgeSec"] = int(age)
                payload["lastBackupAgeLabel"] = age_label(age)
            code = event["returncode"]
            payload["lastReturncode"] = None if code is None else int(code)
            payload["lastOk"] = payload["lastReturncode"] in (0, 1)
            payload["lastFailureHint"] = failure_hint(payload["lastReturncode"])

        archives = []
        for row in con.execute(
            """
            SELECT name, time
            FROM archivemodel
            ORDER BY time DESC
            LIMIT 8
            """
        ):
            when = parse_dt(row["time"])
            age = (now - when).total_seconds() if when else None
            archives.append(
                {
                    "name": row["name"] or "",
                    "time": when.strftime("%Y-%m-%d %H:%M") if when else str(row["time"] or ""),
                    "ageLabel": age_label(age),
                    "ts": int(when.timestamp()) if when else 0,
                }
            )
        payload["archives"] = archives
    except sqlite3.Error as exc:
        payload["ok"] = False
        payload["statusText"] = f"Could not read Vorta database ({exc})"
        return payload
    finally:
        con.close()

    if backup_running:
        payload["statusText"] = "Backup running"
    elif payload["lastBackupTs"]:
        payload["statusText"] = f"Last backup {payload['lastBackupAgeLabel']}"
        if payload["lastReturncode"] not in (0, 1, None):
            payload["statusText"] = "Last backup failed"
    elif not vorta_running:
        payload["statusText"] = "Vorta is not running"
    else:
        payload["statusText"] = "No backups yet"

    return payload


def main() -> None:
    profile = ""
    if len(sys.argv) > 1:
        profile = sys.argv[1].strip()
    print(json.dumps(load_status(profile), ensure_ascii=False))


if __name__ == "__main__":
    main()
