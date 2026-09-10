# omaborg

Omarchy bar widget for [Vorta](https://github.com/borgbase/vorta) / [Borg](https://www.borgbackup.org/).

Shows last-backup freshness on the bar and lists recent archives in a panel.
Left click opens basic stats; right click opens the full view with archive
history and a one-click Backup now button. Status is read from Vorta's
**local** SQLite database and `/proc`. The widget never SSHs to a backup
server and never reads Borg passphrases or SSH keys.

![omaborg panel](screenshot.png)

## Install

```bash
omarchy plugin add https://github.com/<you>/omaborg.git --enable
```

Place it on the bar if needed:

```bash
omarchy plugin enable oma.borg --section right
```

## Requirements

- Omarchy (Quickshell bar)
- `vorta` and `borg` on `PATH`
- A Vorta profile already configured

If you have more than one Vorta profile, set **Vorta profile name** in the
widget settings (or in `~/.config/omarchy/shell.json` on the bar entry).
Leave it empty to use the first profile.

To run backups only on home Wi-Fi, set **Only backup on this Wi-Fi** to that
SSID and point Vorta's pre-backup command at `scripts/vorta-require-wifi`:

```bash
omarchy bar set oma.borg homeSsid YOUR_SSID
# In Vorta → profile → pre-backup command:
~/.local/bin/vorta-require-wifi YOUR_SSID
```

Off that network, scheduled and manual backups are skipped. The bar stays
quiet (not red) until you are home again.

If your backup target is also reachable remotely (e.g. over Tailscale) and
your SSH config points at that remote address when away, pass its hostname
as a second argument so backups still run off the home network as long as
that host answers:

```bash
~/.local/bin/vorta-require-wifi YOUR_SSID your-host.tailnet-name.ts.net
```

## Bar colors

| Appearance | Meaning |
| --- | --- |
| Normal | Last backup within 24 hours |
| Dim | Older than 24 hours |
| Red with **!** | Last backup failed, overdue (> 48 hours), or no backup yet |
| Pulse | A backup is running |

When the icon is red, right-click for the full panel with a short
**what to do** list (usually: get on the home network, then Backup now).

Thresholds are widget settings (`staleAfterHours`, `failedAfterHours`).

## Clicks and keys

Bar:

- Left click: open basic stats (no archives)
- Right click: open full view with archive history
- Middle click: no action

Panel:

- `b`: backup now
- Esc: close

## What this repo does not contain

This project is meant to be public. It must not include:

- SSH private keys, `authorized_keys`, or `known_hosts`
- Borg passphrases or key files
- Vorta `settings.db` (passwords, repo URLs)
- Hostnames, IPs, ports, or remote repo paths

Runtime status (profile name, last archive names) is read on **your**
machine from Vorta. It is not stored in this repository.

## Remove

```bash
omarchy plugin remove oma.borg
```

## Development

Repo root **is** the plugin folder (`manifest.json` at the top level), which
is what `omarchy plugin add` expects.

```bash
omarchy plugin validate .
```

To run a local checkout on Omarchy without publishing:

```bash
rsync -a --delete --exclude .git --exclude .gitignore \
  ./ ~/.config/omarchy/plugins/oma.borg/
omarchy-shell shell rescanPlugins
```
