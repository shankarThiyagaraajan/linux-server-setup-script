# server-setup

[![CI](https://github.com/shankarThiyagaraajan/linux-server-setup-script/actions/workflows/ci.yml/badge.svg)](https://github.com/shankarThiyagaraajan/linux-server-setup-script/actions/workflows/ci.yml)

One tool to set up, check and look after Ubuntu machines, whether a cloud server, a home server or your own laptop. It opens a dashboard (the **Control Room**) that shows how the machine is doing and what server-setup last did, and every change it makes can be previewed first and undone later.

> **Status:** v3 is in development. This first release covers setup, the security check, updates, history and undo. Alerts, schedules, release upgrades and the personal-computer extras are coming next (they show as "coming soon" in the menu).

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

Options: `--dry-run` shows every change as a diff without making it, `--yes --config FILE` runs without questions, `--type server|personal|wsl` skips the machine-type question, and `--no-confirm-timer` is for provisioning tools that verify SSH themselves.

Exit codes: `0` ok, `1` warnings, `2` failures or invalid settings, `3` server-setup itself failed.

## What setup does on a server

- Creates admin accounts with your SSH key and a sudo password, and adds them to `ssh-users`. It refuses to continue if an admin would end up without a key or password.
- SSH: keys only, no root login, `AllowGroups ssh-users`, modern algorithms, and an optional port change. An existing multi-factor setup is kept.
- Firewall (UFW): deny incoming by default, a rate-limited SSH rule, your extra ports, and trusted ranges that are never rate-limited.
- Fail2ban for SSH, including repeat offenders.
- Automatic security updates, with reboots only if you allow them.
- Time sync and time zone.

It installs only missing packages. It never upgrades the whole system during setup; that is what `updates` is for.

## The SSH safety net

Changing SSH is how people lock themselves out, so setup never removes your way in until you prove the new way works:

1. When the port changes, SSH listens on **both** the old and new port.
2. An undo timer starts. If you don't confirm within 10 minutes, the previous SSH configuration is restored automatically.
3. Open a **new** terminal, log in on the new port, and run `sudo server-setup confirm`. That closes the old port and stops the timer. Confirming from the session you ran setup in is refused, because that session proves nothing.

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

## Optional hardening is your call

Extra measures (disk encryption checks, Secure Boot, screen lock, auditd and similar) will be offered as recommendations with the reason and the trade-off, in a coming release. Nothing optional is applied unless you accept it. The security check already supports this: a recommendation you skip is shown as skipped rather than counted against your score.

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
