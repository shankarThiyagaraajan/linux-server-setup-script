#!/usr/bin/env bash
# =============================================================================
#  server-setup.sh — baseline setup & hardening for Ubuntu / Debian servers
#
#  Tested targets: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 (and newer).
#
#  What it does
#    1. Updates the system and installs essential tools
#    2. Sets timezone, NTP, hostname (optional), swap (if none), journald limits
#    3. Creates a sudo user and installs your SSH public key
#    4. Hardens SSH: key-only login, root login disabled, optional custom port,
#       modern ciphers, AllowUsers, idle timeouts
#    5. Locks the root password
#    6. UFW firewall: deny all inbound except SSH (+ ports you choose),
#       SSH rate limiting, drops malformed / bogus TCP packets, per-IP
#       connection & rate limits on 80/443
#    7. Fail2ban: bans brute-forcers (sshd + repeat offenders) via UFW
#    8. Kernel/network hardening (SYN-flood protection, anti-spoofing, etc.)
#    9. Automatic security updates
#
#  Safety
#    - Refuses to disable password login unless a valid SSH key is installed.
#    - Validates sshd config before restarting; rolls back on failure.
#    - Your current SSH session stays open. TEST A NEW LOGIN BEFORE CLOSING IT.
#
#  Usage (as root):
#    bash server-setup.sh                     # interactive prompts
#
#    # or fully unattended:
#    NEW_USER=deploy SSH_PUBKEY="ssh-ed25519 AAAA... me@laptop" SSH_PORT=2222 \
#    ALLOW_PORTS="80/tcp,443/tcp" ASSUME_YES=true bash server-setup.sh
#
#  Safe to re-run: every step checks state or rewrites its own config files.
# =============================================================================
set -Eeuo pipefail

# ------------------------------- Configuration -------------------------------
# Every value can be set as an environment variable; blanks are prompted for.
NEW_USER="${NEW_USER:-}"                 # sudo user to create (required)
SSH_PUBKEY="${SSH_PUBKEY:-}"             # public key text OR path to a .pub file
SSH_PORT="${SSH_PORT:-}"                 # default 22
ALLOW_PORTS="${ALLOW_PORTS-__ask__}"     # extra inbound ports, e.g. "80/tcp,443/tcp"
SUDO_PASSWORD="${SUDO_PASSWORD:-}"       # blank + interactive -> prompted; blank + unattended -> passwordless sudo
TIMEZONE="${TIMEZONE:-UTC}"
HOSTNAME_NEW="${HOSTNAME_NEW:-}"         # blank = keep current hostname
SWAP_SIZE="${SWAP_SIZE:-auto}"           # auto | 0 (none) | e.g. 2G
ALLOW_TCP_FORWARDING="${ALLOW_TCP_FORWARDING:-local}"  # no | local | yes  ("local" keeps VS Code Remote / ssh -L working)
WEB_CONN_LIMIT="${WEB_CONN_LIMIT:-100}"  # max concurrent conns per IP on 80/443; 0 = off (set 0 if behind Cloudflare/a CDN/load balancer)
WEB_RATE_LIMIT="${WEB_RATE_LIMIT:-50/sec}" # max NEW conns per IP on 80/443
FAIL2BAN_IGNOREIP="${FAIL2BAN_IGNOREIP:-}" # extra IPs/CIDRs never banned (your current SSH IP is added automatically)
AUTO_REBOOT="${AUTO_REBOOT:-false}"      # reboot automatically when security updates need it
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"
JOURNAL_MAX="${JOURNAL_MAX:-500M}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"     # space-separated extra apt packages
ASSUME_YES="${ASSUME_YES:-false}"        # true = never prompt

# --------------------------------- Helpers -----------------------------------
LOG_FILE=/var/log/server-setup.log
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/server-setup-backup-$TS"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
log()  { printf '%s[+]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$c_b" "$*" "$c_0"; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND (see $LOG_FILE)"' ERR

INTERACTIVE=false
if [[ "$ASSUME_YES" != true ]] && { : </dev/tty; } 2>/dev/null; then INTERACTIVE=true; fi

ask() {  # ask VAR "prompt" "default"
  local __var=$1 __prompt=$2 __def=${3:-} __r=""
  if $INTERACTIVE; then read -rp "$__prompt${__def:+ [$__def]}: " __r </dev/tty || true; fi
  printf -v "$__var" '%s' "${__r:-$__def}"
}

backup() {  # backup FILE...
  local f
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
  done
}

apt_get() { apt-get -y -q -o DPkg::Lock::Timeout=300 \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }

# ------------------------------- Preflight -----------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (e.g. sudo bash $0)."
[[ -r /etc/os-release ]] || die "Cannot detect OS."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" =~ ^(ubuntu|debian)$ || "${ID_LIKE:-}" == *debian* ]] \
  || die "Unsupported OS: ${PRETTY_NAME:-unknown}. Ubuntu/Debian only."

touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
log "server-setup started $(date) on ${PRETTY_NAME}"

# --- Gather input ---
step "Configuration"
CURRENT_IP="${SSH_CLIENT%% *}"

[[ -n "$NEW_USER" ]] || ask NEW_USER "Admin username to create" "admin"
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username: '$NEW_USER'"
[[ "$NEW_USER" != root ]] || die "NEW_USER cannot be root."

[[ -n "$SSH_PORT" ]] || ask SSH_PORT "SSH port" "22"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "Invalid SSH port: $SSH_PORT"

if [[ "$ALLOW_PORTS" == "__ask__" ]]; then
  ask ALLOW_PORTS "Extra inbound ports to open, comma-separated (e.g. 80/tcp,443/tcp; blank = none)" ""
fi
ALLOW_PORTS=$(tr ',' ' ' <<<"$ALLOW_PORTS")

# --- Resolve the SSH public key (refuse to continue without one) ---
USER_HOME="/home/$NEW_USER"
if id "$NEW_USER" &>/dev/null; then USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6); fi
AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"

if [[ -n "$SSH_PUBKEY" && -f "$SSH_PUBKEY" ]]; then SSH_PUBKEY=$(<"$SSH_PUBKEY"); fi
if [[ -z "$SSH_PUBKEY" && -s "$AUTH_KEYS" ]]; then
  log "Existing key(s) found in $AUTH_KEYS — keeping them."
elif [[ -z "$SSH_PUBKEY" && -s /root/.ssh/authorized_keys ]]; then
  ans="y"; ask ans "Copy root's existing authorized_keys to $NEW_USER? [Y/n]" "y"
  [[ "$ans" =~ ^[Yy] ]] && SSH_PUBKEY=$(grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)
fi
if [[ -z "$SSH_PUBKEY" && ! -s "$AUTH_KEYS" ]]; then
  ask SSH_PUBKEY "Paste your SSH PUBLIC key (from ~/.ssh/id_ed25519.pub on your computer)" ""
fi
if [[ -n "$SSH_PUBKEY" ]]; then
  tmpk=$(mktemp)
  printf '%s\n' "$SSH_PUBKEY" >"$tmpk"
  if command -v ssh-keygen >/dev/null; then
    ssh-keygen -l -f "$tmpk" >/dev/null 2>&1 || { rm -f "$tmpk"; die "That is not a valid SSH public key."; }
  else
    grep -qE '^(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-)' "$tmpk" || { rm -f "$tmpk"; die "That is not a valid SSH public key."; }
  fi
  rm -f "$tmpk"
elif [[ ! -s "$AUTH_KEYS" ]]; then
  die "No SSH key provided. Refusing to disable password login (you would be locked out)."
fi

# --- Sudo password ---
NEED_PW=true
if id "$NEW_USER" &>/dev/null && [[ $(passwd -S "$NEW_USER" | awk '{print $2}') == P ]]; then NEED_PW=false; fi
if $NEED_PW && [[ -z "$SUDO_PASSWORD" ]] && $INTERACTIVE; then
  while true; do
    read -rsp "Set a sudo password for $NEW_USER (blank = passwordless sudo): " p1 </dev/tty; echo
    [[ -z "$p1" ]] && break
    read -rsp "Repeat password: " p2 </dev/tty; echo
    [[ "$p1" == "$p2" ]] && { SUDO_PASSWORD=$p1; break; }
    warn "Passwords do not match, try again."
  done
fi

cat <<EOF

  User:            $NEW_USER (sudo, key-only SSH)
  SSH port:        $SSH_PORT
  Open ports:      ${SSH_PORT}/tcp (rate-limited) ${ALLOW_PORTS:-}
  Root login:      disabled + root password locked
  Password login:  disabled
  Timezone:        $TIMEZONE
  Web limits:      $( ((WEB_CONN_LIMIT > 0)) && echo "${WEB_CONN_LIMIT} conns/IP, ${WEB_RATE_LIMIT} new conns/IP on 80/443" || echo off)
  Backups:         $BACKUP_DIR

EOF
if $INTERACTIVE; then
  ans=""; ask ans "Proceed? [y/N]" "n"
  [[ "$ans" =~ ^[Yy] ]] || die "Aborted by user."
fi
mkdir -p "$BACKUP_DIR"

# ------------------------------ 1. Packages ----------------------------------
step "Updating system & installing essentials"
apt_get update
apt_get full-upgrade
PKGS=(
  sudo openssh-server ca-certificates curl wget gnupg
  git vim nano htop tmux unzip zip jq rsync tree lsof
  dnsutils iproute2 bash-completion logrotate
  ufw fail2ban python3-systemd unattended-upgrades needrestart
)
read -ra _extra <<<"$EXTRA_PACKAGES"
PKGS+=("${_extra[@]}")
AVAIL=()
for p in "${PKGS[@]}"; do
  if apt-cache show "$p" &>/dev/null; then AVAIL+=("$p"); else warn "Package not available, skipping: $p"; fi
done
apt_get install "${AVAIL[@]}"
apt_get autoremove --purge

# --------------------------- 2. System basics --------------------------------
step "Timezone, time sync, hostname"
timedatectl set-timezone "$TIMEZONE" || warn "Could not set timezone $TIMEZONE"
timedatectl set-ntp true 2>/dev/null || warn "Could not enable NTP (container?)"
if [[ -n "$HOSTNAME_NEW" ]]; then
  backup /etc/hosts
  hostnamectl set-hostname "$HOSTNAME_NEW"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME_NEW/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" >>/etc/hosts
  fi
fi

step "Swap"
if [[ -n "$(swapon --show --noheadings)" ]]; then
  log "Swap already active — skipping."
elif [[ "$SWAP_SIZE" != 0 ]]; then
  if [[ "$SWAP_SIZE" == auto ]]; then
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    (( mem_mb < 4096 )) && SWAP_SIZE=2G || SWAP_SIZE=0
  fi
  if [[ "$SWAP_SIZE" != 0 ]]; then
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    need_mb=$(numfmt --from=iec "$SWAP_SIZE" | awk '{print int($1/1048576)}')
    if (( free_mb > need_mb + 1024 )); then
      fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$need_mb" status=none
      chmod 600 /swapfile && mkswap /swapfile >/dev/null
      if swapon /swapfile 2>/dev/null; then
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
        log "Created $SWAP_SIZE swap file."
      else
        rm -f /swapfile; warn "swapon not permitted (container?) — no swap created."
      fi
    else
      warn "Not enough disk space for $SWAP_SIZE swap — skipping."
    fi
  fi
fi

step "Journald size limit"
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=%s\nCompress=yes\n' "$JOURNAL_MAX" >/etc/systemd/journald.conf.d/99-size.conf
systemctl restart systemd-journald || true

# ------------------------------ 3. Admin user --------------------------------
step "Admin user: $NEW_USER"
if ! id "$NEW_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$NEW_USER"
  log "Created user $NEW_USER"
fi
usermod -aG sudo "$NEW_USER"
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"

if [[ -n "$SUDO_PASSWORD" ]]; then
  echo "$NEW_USER:$SUDO_PASSWORD" | chpasswd
  rm -f "/etc/sudoers.d/90-$NEW_USER"
  log "Sudo password set."
elif $NEED_PW; then
  echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-$NEW_USER"
  chmod 440 "/etc/sudoers.d/90-$NEW_USER"
  visudo -cf "/etc/sudoers.d/90-$NEW_USER" >/dev/null || { rm -f "/etc/sudoers.d/90-$NEW_USER"; die "sudoers validation failed"; }
  warn "No password given — $NEW_USER has passwordless sudo."
fi
unset SUDO_PASSWORD p1 p2

install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$USER_HOME/.ssh"
touch "$AUTH_KEYS"
if [[ -n "$SSH_PUBKEY" ]]; then
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    grep -qxF "$k" "$AUTH_KEYS" || echo "$k" >>"$AUTH_KEYS"
  done <<<"$SSH_PUBKEY"
fi
chmod 600 "$AUTH_KEYS"; chown "$NEW_USER:$NEW_USER" "$AUTH_KEYS"
[[ -s "$AUTH_KEYS" ]] || die "authorized_keys is empty — aborting before SSH lockdown."
log "SSH key(s) installed: $(grep -c . "$AUTH_KEYS")"

# ------------------------------ 4. SSH hardening -----------------------------
step "Hardening SSH"
backup /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/ssh/moduli
mkdir -p /etc/ssh/sshd_config.d /run/sshd

# Make sure drop-in configs are read FIRST (sshd uses the first value it sees).
if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

filter_algos() {  # keep only algorithms this OpenSSH build supports
  local type=$1 list=$2 sup out=() a
  sup=$(ssh -Q "$type" 2>/dev/null) || return 0
  IFS=, read -ra arr <<<"$list"
  for a in "${arr[@]}"; do grep -qxF "$a" <<<"$sup" && out+=("$a"); done
  (IFS=,; echo "${out[*]}")
}
KEX=$(filter_algos kex "mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,sntrup761x25519-sha512,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512")
CIPHERS=$(filter_algos cipher "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr")
MACS=$(filter_algos mac "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com")

# 00- prefix so it wins over cloud-init's 50-cloud-init.conf (PasswordAuthentication yes)
cat >/etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# Managed by server-setup.sh ($TS)
Port $SSH_PORT
AddressFamily any

# --- Authentication: keys only, no root ---
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
UsePAM yes
AllowUsers $NEW_USER
MaxAuthTries 3
MaxSessions 10
MaxStartups 10:30:60
LoginGraceTime 30

# --- Session / features ---
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding $ALLOW_TCP_FORWARDING
PermitTunnel no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE

# --- Modern crypto only ---
${KEX:+KexAlgorithms $KEX}
${CIPHERS:+Ciphers $CIPHERS}
${MACS:+MACs $MACS}
EOF
chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

# Remove weak Diffie-Hellman moduli (< 3072 bit)
if [[ -f /etc/ssh/moduli ]]; then
  awk '$5 >= 3071' /etc/ssh/moduli >/etc/ssh/moduli.safe
  if [[ -s /etc/ssh/moduli.safe ]]; then mv /etc/ssh/moduli.safe /etc/ssh/moduli; else rm -f /etc/ssh/moduli.safe; fi
fi

restore_ssh() {
  warn "Restoring previous SSH configuration."
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf
  cp -a "$BACKUP_DIR/etc/ssh/." /etc/ssh/ 2>/dev/null || true
}
if ! sshd -t; then restore_ssh; die "sshd config test failed — nothing applied."; fi
EFF=$(sshd -T 2>/dev/null)
for want in "passwordauthentication no" "permitrootlogin no" "port $SSH_PORT" "pubkeyauthentication yes"; do
  grep -qix "$want" <<<"$EFF" || { restore_ssh; die "Effective sshd setting mismatch: expected '$want' (another config overrides it)."; }
done
log "sshd config validated."

# ------------------------------- 5. Root ------------------------------------
step "Locking root password"
passwd -l root >/dev/null && log "Root password locked (sudo still works for $NEW_USER)."

# ------------------------------ 6. Firewall ---------------------------------
step "Firewall (UFW)"
backup /etc/ufw/before.rules /etc/ufw/before6.rules /etc/default/ufw

# Extra packet filtering inserted into UFW's before-rules (idempotent block)
add_ufw_block() {  # file  cidr-mask
  local f=$1 mask=$2 blk
  [[ -f "$f" ]] || return 0
  sed -i '/^# BEGIN server-setup/,/^# END server-setup/d' "$f"
  blk=$(mktemp)
  {
    echo "# BEGIN server-setup"
    echo "# Drop new TCP connections that do not start with SYN, and NULL/XMAS scans"
    echo "-A ufw-before-input -p tcp ! --syn -m conntrack --ctstate NEW -j DROP"
    echo "-A ufw-before-input -p tcp --tcp-flags ALL NONE -j DROP"
    echo "-A ufw-before-input -p tcp --tcp-flags ALL ALL -j DROP"
    if (( WEB_CONN_LIMIT > 0 )); then
      echo "# Per-IP limits on web ports (connection-flood mitigation)"
      echo "-A ufw-before-input -p tcp --syn -m multiport --dports 80,443 -m connlimit --connlimit-above $WEB_CONN_LIMIT --connlimit-mask $mask -j DROP"
      echo "-A ufw-before-input -p tcp --syn -m multiport --dports 80,443 -m hashlimit --hashlimit-name web$mask --hashlimit-mode srcip --hashlimit-srcmask $mask --hashlimit-above $WEB_RATE_LIMIT --hashlimit-burst 100 -j DROP"
    fi
    echo "# END server-setup"
  } >"$blk"
  awk -v bf="$blk" '/^COMMIT$/ && !done { while ((getline l < bf) > 0) print l; done=1 } { print }' "$f" >"$f.new"
  cat "$f.new" >"$f"; rm -f "$f.new" "$blk"
}
add_ufw_block /etc/ufw/before.rules 32
add_ufw_block /etc/ufw/before6.rules 64

# Let UFW apply OUR kernel settings instead of its own (its file would undo some of them)
sed -i 's|^IPT_SYSCTL=.*|IPT_SYSCTL=/etc/sysctl.d/99-server-hardening.conf|' /etc/default/ufw
sed -i 's|^IPV6=.*|IPV6=yes|' /etc/default/ufw

ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw limit "$SSH_PORT/tcp" comment 'SSH (rate limited)'
for p in $ALLOW_PORTS; do ufw allow "$p" comment 'server-setup'; done
ufw logging low

# Kernel / network hardening (also the file UFW now loads)
step "Kernel & network hardening (sysctl)"
cat >/etc/sysctl.d/99-server-hardening.conf <<'EOF'
# Managed by server-setup.sh
# --- SYN flood / connection flood protection ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_rfc1337 = 1
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096

# --- Anti-spoofing ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# --- ICMP ---
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# --- No redirects / source routing ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# --- Kernel info leaks & misc ---
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
vm.swappiness = 10
EOF
sysctl --system >/dev/null 2>&1 || warn "Some sysctl keys could not be applied (normal in containers)."

printf '* hard core 0\n' >/etc/security/limits.d/99-no-core.conf

if ! ufw --force enable; then
  warn "UFW failed to load custom rules — restoring default before.rules and retrying."
  cp -a "$BACKUP_DIR/etc/ufw/before.rules" /etc/ufw/before.rules 2>/dev/null || true
  cp -a "$BACKUP_DIR/etc/ufw/before6.rules" /etc/ufw/before6.rules 2>/dev/null || true
  ufw --force enable || die "UFW could not be enabled."
fi
ufw reload >/dev/null
systemctl enable ufw >/dev/null 2>&1 || true
ufw status verbose

# ------------------------------- 7. Fail2ban --------------------------------
step "Fail2ban"
IGNORE="127.0.0.1/8 ::1 ${CURRENT_IP:-} $(tr ',' ' ' <<<"$FAIL2BAN_IGNOREIP")"
backup /etc/fail2ban/jail.local
cat >/etc/fail2ban/jail.local <<EOF
# Managed by server-setup.sh
[DEFAULT]
ignoreip = $(xargs <<<"$IGNORE")
backend  = systemd
banaction = ufw
banaction_allports = ufw
findtime = 10m
maxretry = 5
bantime  = 1h
# repeat offenders get exponentially longer bans (up to 1 week)
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

[sshd]
enabled  = true
port     = $SSH_PORT
mode     = aggressive
maxretry = 3

# Ban IPs that keep getting banned, on all ports, for a week
[recidive]
enabled  = true
backend  = auto
logpath  = /var/log/fail2ban.log
banaction = ufw
bantime  = 1w
findtime = 1d
maxretry = 5
EOF
touch /var/log/fail2ban.log
if fail2ban-client -t >/dev/null 2>&1; then
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  log "Fail2ban active (sshd + recidive)."
else
  warn "Fail2ban config test failed — check: fail2ban-client -t"
fi

# --------------------------- 8. Automatic updates ---------------------------
step "Automatic security updates"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat >/etc/apt/apt.conf.d/52unattended-upgrades-local <<EOF
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$AUTO_REBOOT";
Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_REBOOT_TIME";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

# ---------------------- 9. Apply SSH (last, after firewall) -----------------
step "Restarting SSH"
if systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
  # Ubuntu 22.10+ socket activation: the listening port comes from sshd_config via a generator
  systemctl daemon-reload
  systemctl restart ssh.socket
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd
sleep 1
if ss -ltn | grep -qE "[:.]$SSH_PORT\s"; then
  log "sshd listening on port $SSH_PORT."
else
  warn "sshd does not appear to be listening on $SSH_PORT — check: ss -ltnp | grep ssh"
fi

# --------------------------------- Summary ----------------------------------
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

${c_g}${c_b}Setup complete.${c_0}

${c_y}${c_b}IMPORTANT — DO NOT CLOSE THIS SESSION YET.${c_0}
From a NEW terminal on your computer, confirm you can log in:

    ssh -p $SSH_PORT $NEW_USER@${IP:-<server-ip>}
    sudo -v        # confirm sudo works

If your cloud provider has its own firewall / security group, make sure
TCP port $SSH_PORT is allowed there too.

Useful commands:
    sudo ufw status verbose               # firewall rules
    sudo ufw allow 443/tcp                # open a port
    sudo fail2ban-client status sshd      # banned IPs
    sudo fail2ban-client set sshd unbanip <ip>
    sudo sshd -T | less                   # effective SSH config

Backups of changed files: $BACKUP_DIR
Full log:                 $LOG_FILE
EOF
if [[ -f /var/run/reboot-required ]]; then warn "A reboot is required to finish kernel updates: sudo reboot"; fi