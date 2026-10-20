# server-setup

[![CI](https://github.com/shankarThiyagaraajan/linux-server-setup-script/actions/workflows/ci.yml/badge.svg)](https://github.com/shankarThiyagaraajan/linux-server-setup-script/actions/workflows/ci.yml)

One tool to set up, check and look after Ubuntu machines, whether a cloud server, a home server or your own laptop. It opens a dashboard (the **Control Room**) that shows how the machine is doing and what server-setup last did, and every change it makes can be previewed first and undone later.

> **Status:** v3 is in development. It covers setup, the security check, the live security watch, alerts, scheduled maintenance, recommendations, updates, Ubuntu release upgrades, history and undo. The personal-computer extras (apps and dev tools, privacy, backups) are coming next.

## Supported systems

- Ubuntu **24.04 LTS** and newer (interim releases run with a warning)
- Servers, personal computers and WSL. server-setup detects which one it is running on and asks you to confirm.
- Containers are not supported for setup.

## Install

```bash
git clone https://github.com/shankarThiyagaraajan/linux-server-setup-script.git
cd linux-server-setup-script
make build                 # dist/server-setup + dist/server-setup.sha256
sudo install -m 755 dist/server-setup /usr/local/sbin/server-setup
sudo server-setup
```

`dist/server-setup` is one self-contained file, so you can copy it to other machines (check it against `server-setup.sha256`). You can also run `sudo bin/server-setup` straight from the clone.

## Commands

| Command | What it does |
|---|---|
| `sudo server-setup` | Open the dashboard |
| `sudo server-setup setup` | Run the setup wizard. If the machine is already set up, it offers changes instead of starting over. |
| `sudo server-setup confirm` | Keep new SSH settings (run it from a **new** login) |
| `sudo server-setup check [--json]` | Security check, with exit code 0 (ok), 1 (warnings) or 2 (failures) |
| `sudo server-setup updates` | Install updates now |
| `sudo server-setup history` | What server-setup did on this machine, and when |
| `sudo server-setup rollback RUN_ID [--ssh]` | Put back the files a run changed |
| `sudo server-setup events [--json]` | Security events found by the watch, newest first |
| `sudo server-setup release-upgrade [--check]` | Upgrade to the next Ubuntu release (the dashboard's **Upgrade Ubuntu** does the same with live progress) |
| `sudo server-setup recommendations [--json]` | Optional hardening for this machine and what you decided about each |
| `sudo server-setup maintain daily\|weekly\|monthly` | Run a maintenance job now (the timers run these) |
| `sudo server-setup alert-test` | Send a test alert to every channel that is set up |

Options: `--dry-run` shows every change as a diff without making it, `--yes --config FILE` runs without questions, `--type server|personal|wsl` skips the machine-type question, and `--no-confirm-timer` is for provisioning tools that verify SSH themselves.

Exit codes: `0` ok, `1` warnings, `2` failures or invalid settings, `3` server-setup itself failed.

## What setup does on a server

- Creates admin accounts with your SSH key and a sudo password, and adds them to `ssh-users`. It refuses to continue if an admin would end up without a key or password.
- SSH: keys only, no root login, `AllowGroups ssh-users`, modern algorithms, and an optional port change. An existing multi-factor setup is kept.
- Firewall (UFW): deny incoming by default, a rate-limited SSH rule, your extra ports, and trusted ranges that are never rate-limited.
- Fail2ban for SSH, including repeat offenders.
- Automatic security updates, with reboots only if you allow them.
- Time sync and time zone.
- The security watch and scheduled maintenance (below).
- Any recommendations you tick (below).

It installs only missing packages. It never upgrades the whole system during setup; that is what `updates` is for.

## The SSH safety net

Changing SSH is how people lock themselves out, so setup never removes your way in until you prove the new way works:

1. When the port changes, SSH listens on **both** the old and new port.
2. An undo timer starts. If you don't confirm within 10 minutes, the previous SSH configuration is restored automatically.
3. Open a **new** terminal, log in on the new port, and run `sudo server-setup confirm`. That closes the old port and stops the timer. Confirming from the session you ran setup in is refused, because that session proves nothing.

## Security watch

A small systemd service (`server-setup-watch`) follows the system journal live and records security events. It only reads; it never changes anything by itself.

| Level | Examples |
|---|---|
| **Critical** | root logged in over SSH; a login right after many failed attempts from the same address; a new UID 0 account; an SSH key added for root; `/etc/ld.so.preload` appearing |
| **Important** | a login from a new address or with a password; 10+ failed logins in an hour to a real account; sudo misuse; new accounts or admins; SSH key, sudoers, SSH server, cron or system service changes; a new program listening on the network; out-of-memory kills |
| **Info** | normal logins and password changes, kept for the timeline |

Bot noise (guessing at accounts that don't exist) is counted, not alerted on. Your trusted ranges are never flagged. Changes server-setup makes itself are recorded as info, and the first run only learns what is normal, so turning the watch on does not raise alarms about the past.

Events reach you in three places:
- **Dashboard.** The Security watch panel shows what needs attention, and new important events open a pop-up as they arrive (the dashboard refreshes itself every 30 seconds; critical events also ring the terminal bell). Press `e` for the full list.
- **Login message.** While events wait for review, SSH logins show a short notice.
- **Security check.** Unreviewed events show up in `server-setup check`, and critical ones make it fail.

Each event has actions in its pop-up:
- **This was me.** Marks the event as reviewed.
- **Block the address.** Adds a firewall deny at the top of the rules. It refuses your own address, local addresses and your trusted ranges.
- **Lock the account.** Locks the password, expires the account so SSH keys stop working too, and ends its sessions. It refuses root, your own account and the last admin.

The service is hardened with a read-only system view (`ProtectSystem=strict`, `NoNewPrivileges`), writes only to `/var/lib/server-setup`, and runs with low priority, a 256 MB memory limit and a 20% CPU limit. On a machine set up before the watch existed, press `w` in the dashboard to turn it on.

## Alerts

**Alerts** (key `6`) sends security events and machine-health problems to your phone or team as they happen. Set up any of:

| Channel | What you need |
|---|---|
| **ntfy** | The ntfy app and a long, hard-to-guess topic (`https://ntfy.sh/…`), or your own ntfy server with a token |
| **Telegram** | A bot token from @BotFather and your chat id |
| **Slack** | An incoming-webhook URL |
| **Webhook** | Any HTTPS URL; each alert is POSTed as JSON (host, severity, title, text, kind, time, id) |
| **Email** | `msmtp` set up with your mail provider in `/etc/msmtprc` (the one step done outside the dashboard, because the mail login is yours to type) |

- By default important and critical events are sent; you can switch to critical only. Info events are never sent.
- **Machine health** (on by default): a disk or its inodes over 90% full, memory almost full, a failed service. Each problem is sent once, and again only after it has recovered and come back.
- A burst of more than five events becomes one message. A failed send is retried with back-off for a day, then reported as an event.
- The watch service does the sending, so alerts go out with nobody logged in. Settings live in `/etc/server-setup/alerts.env` (root-only, never executed; see [examples/alerts.env](examples/alerts.env) for unattended installs), and tokens never appear in a command line. Only `https://` addresses are accepted.

## Scheduled maintenance

**Schedule** (key `7`) shows three systemd timers, with their next run and last result, and lets you turn each one on or off or run it now with live output.

| Job | When | What it does |
|---|---|---|
| **Daily check** | every day, 06:30–07:00 | Runs the security check and alerts when the score drops or a new failure appears |
| **Weekly updates & clean-up** | Sundays, 04:30–05:30 | Installs updates (security only by default; all or none if you choose), removes unused packages, trims the journal to 30 days, saves a backup of the settings server-setup manages to `/var/backups/server-setup` (the newest 8 are kept), and sends a short report |
| **Monthly review** | the 1st, 05:00–06:00 | Tells you when a new Ubuntu release is out, and lists admin accounts nobody has used for 90 days |

The timers are persistent (a run missed while the machine was off happens soon after it starts) and start at a random moment in their window, so a fleet does not update all at once. Settings: `MAINT_DAILY`, `MAINT_WEEKLY`, `MAINT_MONTHLY`, `MAINT_UPDATES` and `MAINT_BACKUPS_KEEP` in `config.env`.

## Upgrading Ubuntu

**Upgrade Ubuntu** (key `8`) handles the whole move to the next release without you leaving the dashboard:

1. **Before.** A pop-up checks that the machine is ready: a newer release on your channel, updates installed, no restart pending, enough disk space, no unconfirmed SSH change, and on a laptop, the charger plugged in. Most problems can be fixed from the pop-up itself (install updates, install the upgrade tool, restart, switch between LTS-only and every release). A last confirmation reminds you to take a backup and defaults to **Not now**.
2. **During.** The upgrade runs in its own systemd unit, so a dropped SSH connection or closing the dashboard does not stop it. The screen shows the phase, the elapsed time and the live log; press `b` to go back and `8` to return. The full log can be scrolled in the dashboard and is kept in `/var/log/server-setup-release-upgrade.log`.
3. **Before the restart.** It checks that you can still get in: the SSH config loads with the new OpenSSH, SSH is running, sudo rules are valid, and the firewall and Fail2ban are up. If the server-setup SSH settings no longer load, they are re-written for the new OpenSSH, keeping your ports and login methods, and SSH is restarted at once. If anything is still wrong, the pop-up says so in red and does not offer the restart as the default.
4. **After.** A welcome pop-up runs the security check and lets you turn paused third-party sources back on, one by one.

## Tracking, drift and undo

- `/var/lib/server-setup/state.json` holds what is set up, the last run of each task and the hash of every file server-setup manages. `history.jsonl` holds one line per run. Both are root-only.
- Every changed file is backed up per run under `/var/lib/server-setup/backups/<RUN_ID>/`, so `rollback` restores it exactly and removes files the run created.
- If someone edits a managed file by hand, the security check reports it as drift. Setup then asks whether to keep the edit or restore it, and never overwrites the edit silently.
- Settings are saved to `/etc/server-setup/config.env`, which is parsed and never executed. Keys go in `/etc/server-setup/keys/<user>.pub`.

## Unattended setup

```bash
openssl passwd -6          # make a password hash for ADMIN_PASSWORD_HASH
sudo server-setup setup --yes --type server --config examples/config.env
```

See [examples/config.env](examples/config.env) for every setting. All values are validated, and all problems are reported together before anything changes.

## Recommendations: optional hardening is your call

**Recommendations** (key `9`) lists extra hardening that fits this kind of machine. Each card says why it matters, which standard it comes from, what it might affect, whether it can be undone, and how long it takes. Nothing is applied unless you choose **Apply**, and Apply first shows exactly what will change.

| ID | For | What it does | Standard |
|---|---|---|---|
| `REC-SYSCTL` | servers, computers | Kernel network hardening (no redirects or source routing, reverse-path filter, SYN cookies, hidden kernel pointers). IP forwarding is left alone. | CIS 3.3.x, 1.5.x |
| `REC-AUDITD` | servers | auditd rules for accounts, sudo, SSH settings and keys, and privilege use | CIS 6.3.x · NIST 800-53 AU-2 |
| `REC-PWQUALITY` | all | New passwords of at least 14 characters, no dictionary words | CIS 5.3.3.2.x · NIST 800-63B |
| `REC-APPARMOR` | servers, computers | Keeps AppArmor on | CIS 1.3.1.x |
| `REC-LIVEPATCH` | servers | Ubuntu Pro with Livepatch (check only: needs your free token) | Ubuntu security guidance |
| `REC-DISK-ENCRYPTION` | computers | Disk encryption (check only: chosen at install time) | CIS Controls 3.6 · NIST 800-111 |
| `REC-SECURE-BOOT` | computers | Secure Boot (check only: set in the firmware) | CIS Controls 2.5 · NIST 800-147 |
| `REC-SCREEN-LOCK` | computers | Lock the screen after 5 idle minutes | CIS 1.7.x · NIST 800-53 AC-11 |
| `REC-AUTOLOGIN` | computers | Turn off automatic login | CIS 1.7.x |

- Each card offers **Apply** (or **I've done it** for check-only items), **Remind me in 14 days**, **Skip**, and **Never ask again**. Decisions are kept in `state.json`, so nothing is asked twice.
- The setup wizard shows the ones that can be applied as a checklist, ticked by default, and you untick what you don't want.
- Unattended runs apply only what `RECOMMENDATIONS` lists in the settings file; they never accept one on their own.
- The security check shows each one: in place counts as a pass, open ones are listed as recommended without lowering the score, and skipped ones show as "skipped by you".

## Development

```bash
make lint      # shellcheck
make test      # unit tests (bats)
make build     # dist/server-setup, one self-contained file + sha256
SS_INTEGRATION=1 bats tests/integration.bats   # THROWAWAY Ubuntu 24.04 container only
```

The code lives in `bin/server-setup` and `lib/`, and `tools/build.sh` inlines it into one file for release.

## The old scripts

The previous `server-script.sh` is in [legacy/](legacy/) for reference and is no longer maintained. It can lock you out (it replaces `AllowUsers` and changes the SSH port with no way back), so use `server-setup` instead. A machine set up with it is recognised, and its settings are imported the first time you run `server-setup setup`.
