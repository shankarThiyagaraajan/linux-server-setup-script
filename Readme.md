# server-setup.sh — Documentation

Oct 9, 2026 · @Shankar

## Overview

`server-setup.sh` (v2.0) is a menu-driven tool for Ubuntu and Debian servers: it updates or upgrades the system, hardens a fresh server in one of two depths (Essential or Full), and runs a doctor scan that grades the current state and offers fixes. Setup updates the system, creates a sudo user, locks SSH down to public-key login, disables root, enables a UFW firewall with Fail2ban, applies kernel network hardening, and turns on automatic security updates.

Three design rules shape it:

- **No lockout.** It refuses to disable password login unless a valid SSH key is installed, validates the new SSH config before applying it, and restarts SSH only after the firewall already allows the new port.
- **Re-runnable.** Every step checks current state or rewrites its own config file, so running it twice is safe.
- **Reversible.** Every system file it changes is copied to `/root/server-setup-backup-<timestamp>/` first, and everything it prints is logged to `/var/log/server-setup.log`.

## Dashboard and modes

Run the script with no command to get a live dashboard and a menu; pass a command to run one mode directly.

```text
──────────────────────────────────────────────────────────────────────
 server-setup v2.0.0 · web-01 · Ubuntu 24.04.5 LTS
──────────────────────────────────────────────────────────────────────
 System    kernel 6.8.0 · up 3 days · load 0.12 0.08 0.05 · 2 CPU
 Memory    RAM 506Mi / 3.8Gi · swap 2.0Gi · disk / 31% of 80G
 Network   203.0.113.10 · SSH port 2222
 Updates   12 pending (3 security) · reboot required: no
 Security  root login off ✔  password login off ✔  firewall ✔  fail2ban ✘  auto-updates ✔
──────────────────────────────────────────────────────────────────────
  1) Update system      apt update + upgrade (no config changes)
  2) Upgrade system     full-upgrade, remove unused packages, clean cache
  3) Essential setup    admin user, key-only SSH, root off, firewall, fail2ban, auto-updates
  4) Full setup         essential + kernel/DDoS hardening, swap, log cap, tools
  5) Doctor             scan current status and recommend fixes
  6) Show recent log
  0) Exit
```

| Menu | Command | What it does | Changes config? |
| --- | --- | --- | --- |
| 1 | `update` | `apt update`, `upgrade`, `autoremove`; reports if a reboot is needed | No |
| 2 | `upgrade` | `full-upgrade` (may add/remove packages), `autoremove`, `autoclean`; offers a reboot | No |
| 3 | `essential` | Admin user + key, key-only SSH with modern crypto, root locked, UFW, Fail2ban, automatic updates | Yes |
| 4 | `full` | Everything in Essential, plus admin tools, swap, journal cap, weak-moduli cleanup, kernel hardening, flood and scan filters, web per-IP limits | Yes |
| 5 | `doctor` | Read-only scan with PASS / WARN / FAIL, a health score and recommended fixes | Only if you accept a fix |

Essential is the minimum every internet-facing server needs. Choose Full for public web servers or anything likely to attract floods; it is safe to run Full after Essential.

## Doctor

The doctor checks about 25 items across seven areas, scores the server, and lists a fix for every problem it finds.

| Area | What it checks |
| --- | --- |
| System | Supported OS release, pending reboot, disk usage (warn 80%, fail 90%), swap on small machines, NTP sync, failed services |
| Updates | Pending updates and security updates, automatic updates enabled |
| SSH | Port, root login, password and keyboard-interactive login, empty passwords, key login, X11, `MaxAuthTries`, `AllowUsers`, a sudo user with a key |
| Accounts | Root password locked, extra UID-0 accounts, empty passwords, passwordless sudo |
| Firewall | UFW installed and active, default deny, SSH port allowed and rate-limited, flood filters, public listeners, exposed database ports, Docker bypassing UFW |
| Intrusion prevention | Fail2ban installed, running, sshd jail and ban count, failed SSH logins in the last 24 hours |
| Kernel hardening | SYN cookies, redirects, source routing, reverse-path filtering, martian logging, kernel pointer and `dmesg` restrictions, setuid core dumps |

Example output:

```text
SSH
  ✔ PASS  Root login disabled
  ✘ FAIL  Password login enabled (brute-force target)
          → Essential setup switches SSH to key-only
Intrusion prevention
  ✘ FAIL  Fail2ban installed but not running
          → sudo systemctl enable --now fail2ban

Health score: 82%   18 pass · 2 warn · 2 fail
  Best single fix: Essential setup (menu 3 · sudo bash server-setup.sh essential)
```

**Fixing what it finds.** In interactive mode the doctor offers two follow-ups:

1. **Automatic fixes** for small, safe changes: install pending updates, enable automatic updates, start Fail2ban, allow and rate-limit the SSH port in UFW, enable NTP, lock root (only when a sudo user with a key exists), lock empty-password accounts, apply the kernel hardening profile.
2. **Run the recommended setup** (Essential or Full) for anything that needs it, such as SSH lockdown or a missing firewall. SSH settings are never changed piecemeal, to avoid lockouts.

**Exit codes** make it usable in cron or CI: `0` all pass, `1` warnings, `2` failures. For example, a weekly check: `0 6 * * 1 root bash /root/server-setup.sh doctor --yes || mail -s "doctor: issues" you@example.com < /var/log/server-setup.log`.

## Requirements

You need root access, a supported OS, and an SSH key pair on your own computer before you start.

| Requirement | Details |
| --- | --- |
| Operating system | Ubuntu 20.04, 22.04, 24.04 or Debian 11, 12 and newer Debian-based releases |
| Privileges | Run as root (`sudo bash server-setup.sh`) |
| SSH key | A public key such as `~/.ssh/id_ed25519.pub`. Create one with `ssh-keygen -t ed25519` on your computer |
| Network | Outbound internet for apt. If you change the SSH port, open it in your cloud provider's firewall or security group too |
| Kernel modules | `conntrack`, `connlimit` and `hashlimit` for the firewall rules. Standard on VMs and bare metal; may be missing in some containers |

Keep your current SSH session open for the whole run and until you have confirmed a new login works.

## Quick start

Copy the script to the server, run it as root, answer five prompts, then test a new login.

**1. Copy it to the server** (from your computer):

```bash
scp server-setup.sh root@<server-ip>:/root/
ssh root@<server-ip>
```

**2a. Run interactively.** It opens the dashboard. Pick 5 (Doctor) to see where the server stands, then 3 (Essential) or 4 (Full); setup asks for the username, SSH key, SSH port, extra ports and sudo password, shows a summary, and waits for `y`:

```bash
sudo bash server-setup.sh
```

**2b. Or run unattended** by passing every value as an environment variable:

```bash
# one-off commands
sudo bash server-setup.sh update
sudo bash server-setup.sh doctor

# full hardening, no prompts
NEW_USER=deploy \
SSH_PUBKEY="ssh-ed25519 AAAA... me@laptop" \
SSH_PORT=2222 \
ALLOW_PORTS="80/tcp,443/tcp" \
sudo -E bash server-setup.sh full --yes
```

`SSH_PUBKEY` also accepts a path to a `.pub` file. In unattended mode with no `SUDO_PASSWORD`, the user gets passwordless sudo.

**3. Test before you log out.** From a new terminal on your computer:

```bash
ssh -p 2222 deploy@<server-ip>
sudo -v
```

Only close the original root session once both commands succeed.

## Execution flow

&#91;embedded content: server-setup.sh execution flow · 9 steps, 3 safety gates\]

This is the Essential and Full setup flow. The two red gates stop the run before SSH is touched live; only after the firewall already allows the port does step 9 restart SSH. In interactive mode, preflight also shows a summary and aborts unless you answer `y`.

## Configuration reference

Every setting is an environment variable; the first five are prompted for when blank and a terminal is available.

| Variable | Default | What it controls |
| --- | --- | --- |
| `NEW_USER` | prompt (`admin`) | Sudo user to create. Lowercase letters, digits, `_` and `-`; cannot be `root` |
| `SSH_PUBKEY` | prompt | Public key text or path to a `.pub` file. If blank, existing keys for the user or root's keys are used |
| `SSH_PORT` | prompt (`22`) | Port sshd listens on, 1–65535 |
| `ALLOW_PORTS` | prompt (none) | Extra inbound ports, comma-separated, e.g. `80/tcp,443/tcp` |
| `SUDO_PASSWORD` | prompt | Sudo password. Blank means passwordless sudo |
| `TIMEZONE` | `UTC` | System timezone, e.g. `Asia/Kolkata` |
| `HOSTNAME_NEW` | keep current | New hostname; also updates `/etc/hosts` |
| `SWAP_SIZE` | `auto` | `auto` = 2G when RAM is under 4 GB and no swap exists; `0` = none; or a size like `4G` |
| `ALLOW_TCP_FORWARDING` | `local` | `no`, `local` or `yes`. `local` keeps VS Code Remote and `ssh -L` working |
| `WEB_CONN_LIMIT` | `100` | Max concurrent connections per IP on ports 80/443. `0` turns web limits off |
| `WEB_RATE_LIMIT` | `50/sec` | Max new connections per IP per second on ports 80/443 (burst 100) |
| `FAIL2BAN_IGNOREIP` | none | IPs or CIDRs never banned, comma-separated. Your current SSH IP is always added |
| `AUTO_REBOOT` | `false` | Reboot automatically when a security update requires it |
| `AUTO_REBOOT_TIME` | `04:00` | Time of that automatic reboot |
| `JOURNAL_MAX` | `500M` | Maximum disk space for systemd journal logs |
| `EXTRA_PACKAGES` | none | Extra apt packages, space-separated |
| `ASSUME_YES` | `false` | `true` = never prompt; required for unattended runs |

`SWAP_SIZE`, `JOURNAL_MAX`, `WEB_CONN_LIMIT` and `WEB_RATE_LIMIT` apply to Full setup only. `SSH_PORT` defaults to the port SSH uses now, so re-runs keep it. The command can also be set with `MODE` (for example `MODE=doctor`); `--yes` is the same as `ASSUME_YES=true`. With no terminal and no command, the script prints help and exits instead of guessing.

## What each step does

Setup runs nine steps after preflight, in the order shown in the flow diagram. Essential skips the Full-only parts: admin tools, swap and journal cap (steps 1–2), weak-moduli cleanup (step 4), and kernel hardening plus flood filters (step 6).

### 1. Packages

Runs `apt-get update` and `full-upgrade`, then installs: `sudo openssh-server ca-certificates curl wget gnupg git vim nano htop tmux unzip zip jq rsync tree lsof dnsutils iproute2 bash-completion logrotate ufw fail2ban python3-systemd unattended-upgrades needrestart`, plus `EXTRA_PACKAGES`. Packages missing from the release are skipped with a warning. Apt waits up to 5 minutes for a lock held by first-boot updates.

### 2. System basics

- Sets the timezone and enables NTP time sync.
- Sets the hostname if `HOSTNAME_NEW` is given.
- Creates `/swapfile` when no swap exists (see `SWAP_SIZE`), only if at least 1 GB of disk stays free.
- Caps journal logs at `JOURNAL_MAX`.

### 3. Admin user

Creates `NEW_USER` with no login password, adds it to the `sudo` group, and sets the sudo password or a passwordless sudoers rule (validated with `visudo`). Installs the SSH key(s) into `~/.ssh/authorized_keys` with `700`/`600` permissions, skipping duplicates.

### 4. SSH hardening

Writes `/etc/ssh/sshd_config.d/00-hardening.conf`. The `00-` prefix matters: sshd keeps the first value it reads, so this file beats cloud-init's `50-cloud-init.conf`, which often turns password login back on.

| Setting | Value |
| --- | --- |
| Login method | Public key only (`AuthenticationMethods publickey`) |
| Root login | `PermitRootLogin no` |
| Password / keyboard-interactive | Disabled |
| Allowed users | `AllowUsers NEW_USER` |
| Brute-force limits | `MaxAuthTries 3`, `LoginGraceTime 30`, `MaxStartups 10:30:60` |
| Forwarding | X11 and agent off, TCP per `ALLOW_TCP_FORWARDING`, tunnels off |
| Idle sessions | Dropped after about 10 minutes without a response |
| Crypto | Modern key exchange, ciphers and MACs, filtered to what the installed OpenSSH supports |
| Logging | `LogLevel VERBOSE` (logs key fingerprints) |

It also removes Diffie-Hellman moduli under 3072 bits from `/etc/ssh/moduli`. SSH is configured here but not restarted until step 9.

### 5. Root

Locks the root password with `passwd -l root`. Root keys are untouched, but SSH no longer accepts root logins; use `sudo` from the admin user.

### 6. Firewall and kernel hardening

**UFW policy:** deny incoming, allow outgoing, deny routed. The SSH port is opened with `ufw limit` (blocks an IP after 6 connection attempts in 30 seconds). Ports in `ALLOW_PORTS` are opened normally.

**Extra packet filtering** in `/etc/ufw/before.rules` and `before6.rules`, inside a `# BEGIN/END server-setup` block:

- Drop new TCP connections that do not start with SYN.
- Drop NULL and XMAS scan packets.
- On ports 80/443: drop connections over `WEB_CONN_LIMIT` per IP, and new connections over `WEB_RATE_LIMIT` per IP (IPv6 grouped per /64).

**Kernel settings** in `/etc/sysctl.d/99-server-hardening.conf`: SYN cookies and larger SYN backlog, reverse-path filtering against spoofed IPs, logging of impossible source addresses, no ICMP redirects or source routing, restricted kernel pointers and `dmesg`, no setuid core dumps, `vm.swappiness = 10`. UFW is pointed at this file so its own defaults do not undo it. Core dumps are also disabled for all users.

### 7. Fail2ban

Writes `/etc/fail2ban/jail.local`, reading the systemd journal and banning through UFW.

| Jail | Trigger | Ban |
| --- | --- | --- |
| `sshd` (aggressive mode) | 3 failures in 10 minutes | 1 hour, doubling for repeat offenders up to 1 week |
| `recidive` | 5 bans in 1 day | 1 week, all ports |

Localhost and your current SSH IP are never banned.

### 8. Automatic updates

Enables daily `unattended-upgrades` for security updates, removes unused kernels and dependencies, and reboots at `AUTO_REBOOT_TIME` only if `AUTO_REBOOT=true`.

### 9. SSH restart

On Ubuntu 22.10+ (socket activation) it reloads systemd and restarts `ssh.socket` so the new port takes effect, then restarts the SSH service and checks that sshd is listening on `SSH_PORT`. Your current session stays connected.

## Safety checks and rollback

Each risky change is gated by a check that stops the script or rolls back before you can be locked out.

| Check | When | If it fails |
| --- | --- | --- |
| Running as root on Ubuntu/Debian | Preflight | Stops before any change |
| Username and SSH port are valid | Preflight | Stops before any change |
| SSH key exists and parses with `ssh-keygen` | Preflight | Stops: "Refusing to disable password login" |
| `authorized_keys` is not empty | Step 3 | Stops before SSH is touched |
| Sudoers rule passes `visudo -c` | Step 3 | Removes the rule and stops |
| `sshd -t` accepts the new config | Step 4 | Restores the SSH backup and stops |
| Effective config (`sshd -T`) shows port, no root, no password, keys on | Step 4 | Restores the SSH backup and stops: another file overrides a setting |
| UFW loads the custom rules | Step 6 | Restores the original `before.rules` and enables UFW without them |
| `fail2ban-client -t` passes | Step 7 | Leaves Fail2ban unchanged and warns |
| sshd listens on `SSH_PORT` | Step 9 | Warns with the command to investigate |

**Order matters.** The firewall rule for the SSH port is in place before SSH restarts, so the new port is reachable the moment sshd moves to it.

**Backups.** Before editing, the script copies `/etc/ssh/sshd_config`, `/etc/ssh/sshd_config.d/`, `/etc/ssh/moduli`, `/etc/ufw/before.rules`, `/etc/ufw/before6.rules`, `/etc/default/ufw`, `/etc/fail2ban/jail.local` and `/etc/hosts` to `/root/server-setup-backup-<timestamp>/`, keeping the same paths. To restore one: `cp -a /root/server-setup-backup-<ts>/etc/ssh/sshd_config /etc/ssh/`.

## After running

Confirm a new login works, then check the firewall and Fail2ban before closing the root session.

- [ ] New terminal: `ssh -p <port> <user>@<server-ip>` logs in without a password
- [ ] `sudo -v` works for the new user
- [ ] `ssh root@<server-ip>` is refused
- [ ] `ssh -o PubkeyAuthentication=no <user>@<server-ip>` is refused (no password login)
- [ ] `sudo ufw status verbose` shows only the ports you expect
- [ ] `sudo fail2ban-client status` lists the `sshd` and `recidive` jails
- [ ] Reboot if the script warned that one is required: `sudo reboot`

Then run `sudo bash server-setup.sh doctor`: a hardened server should score 90% or more with no FAIL lines.

**Useful commands**

| Task | Command |
| --- | --- |
| Show firewall rules | `sudo ufw status numbered` |
| Open a port | `sudo ufw allow 443/tcp` |
| Close a port | `sudo ufw delete allow 443/tcp` |
| List banned IPs | `sudo fail2ban-client status sshd` |
| Unban an IP | `sudo fail2ban-client set sshd unbanip <ip>` |
| Show effective SSH config | `sudo sshd -T` |
| Allow another SSH user | Add the name to `AllowUsers` in `/etc/ssh/sshd_config.d/00-hardening.conf`, then `sudo sshd -t && sudo systemctl restart ssh` |
| Watch SSH logins | `sudo journalctl -u ssh -f` |
| Check pending updates | `sudo unattended-upgrade --dry-run -d` |
| Re-read the setup log | `sudo less /var/log/server-setup.log` |

## Troubleshooting and recovery

Most problems come from a port blocked outside the server, a ban on your own IP, or a key mismatch.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| New SSH login times out | New port blocked by the cloud provider's firewall or security group | Open the port in the provider console. Still in the old session? Check `ss -ltnp \| grep ssh` |
| `Permission denied (publickey)` | Wrong key, wrong user, or bad permissions | Use `ssh -i <key> -v`. On the server: `~/.ssh` is `700`, `authorized_keys` is `600`, both owned by the user |
| Connection refused after a few quick logins | `ufw limit` (6 tries in 30 s) or a Fail2ban ban | Wait 30 s, or from another session: `sudo fail2ban-client set sshd unbanip <ip>` |
| Locked out completely | Session closed before testing | Use the provider's web or serial console, log in as the new user, and restore from the backup folder. Root has no password, so set one first if you need root there: `sudo passwd root` |
| Web visitors blocked behind Cloudflare, a CDN or a load balancer | All traffic arrives from a few proxy IPs and hits the per-IP web limits | Re-run with `WEB_CONN_LIMIT=0` |
| Docker containers reachable despite UFW | Docker writes its own iptables rules and bypasses UFW for published ports | Publish as `127.0.0.1:8080:80` and put a reverse proxy in front |
| Ansible or scripts fail with many SSH connections | `ufw limit` on the SSH port | Add your automation host: `sudo ufw insert 1 allow from <ip> to any port <ssh-port> proto tcp` |
| Warnings about sysctl, swap or NTP | Running in a container (LXC, OpenVZ) that blocks those settings | Safe to ignore; the host controls them |
| Script stops with "Effective sshd setting mismatch" | Another config file sets the value before the drop-in | Find it with `grep -ri '<setting>' /etc/ssh/`, remove or fix it, re-run |

## Files changed and limitations

The script writes to these files; everything else on the system is left as it was apart from package upgrades.

| File | Purpose |
| --- | --- |
| `/etc/ssh/sshd_config.d/00-hardening.conf` | SSH hardening (created) |
| `/etc/ssh/sshd_config` | `Include` line added only if missing |
| `/etc/ssh/moduli` | Weak DH moduli removed |
| `/etc/sudoers.d/90-<user>` | Passwordless sudo, only when no password is set |
| `/home/<user>/.ssh/authorized_keys` | Your SSH key(s) |
| `/etc/ufw/before.rules`, `before6.rules` | Extra packet filtering block |
| `/etc/default/ufw` | Points UFW at the hardening sysctl file; IPv6 on |
| `/etc/sysctl.d/99-server-hardening.conf` | Kernel and network hardening |
| `/etc/security/limits.d/99-no-core.conf` | Core dumps off |
| `/etc/fail2ban/jail.local` | Fail2ban jails |
| `/etc/apt/apt.conf.d/20auto-upgrades`, `52unattended-upgrades-local` | Automatic updates |
| `/etc/systemd/journald.conf.d/99-size.conf` | Journal size cap |
| `/swapfile`, `/etc/fstab` | Swap, only when created |
| `/etc/hosts` | Only when `HOSTNAME_NEW` is set |

**Limitations**

- **Large DDoS attacks** saturate the network link before packets reach the server, so no on-server setting can stop them. Use Cloudflare or your provider's DDoS protection for that; this script handles SYN floods, connection floods and abusive single IPs.
- **Debian and Ubuntu only.** RHEL, Rocky, Alma and Fedora use `firewalld` and `dnf` and are not supported.
- **Existing UFW rules are kept,** not reset. Review `ufw status` if the server was configured before.
- **One SSH user.** `AllowUsers` lists only `NEW_USER`; add others by hand.
- **No application setup.** Web servers, databases and Docker are out of scope; open their ports with `ALLOW_PORTS` or `ufw allow`.
