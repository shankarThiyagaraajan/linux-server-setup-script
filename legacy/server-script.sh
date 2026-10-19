#!/usr/bin/env bash
# =============================================================================
#  server-setup.sh — dashboard, setup, hardening and health check
#                    for Ubuntu / Debian servers
#
#  Run with no command for the interactive dashboard, or pass a command:
#
#    update      apt update + upgrade                     (no config changes)
#    upgrade     full-upgrade + autoremove + clean        (no config changes)
#    essential   Must-have security: admin user, key-only SSH, root locked,
#                UFW firewall, Fail2ban, automatic security updates
#    full        Essential + kernel/DDoS hardening, web flood limits,
#                swap, log size cap, admin tools
#    doctor      Read-only scan: PASS / WARN / FAIL with recommended fixes
#    release-info     Read-only OS upgrade plan: path, benefits, known issues, checks
#    release-upgrade  Upgrade Ubuntu to the next LTS (one step at a time)
#
#  Options:  -y, --yes   never prompt (unattended)      -h, --help   help
#
#  Examples:
#    sudo bash server-setup.sh                    # dashboard
#    sudo bash server-setup.sh doctor
#    NEW_USER=deploy SSH_PUBKEY="ssh-ed25519 AAAA..." SSH_PORT=2222 \
#      ALLOW_PORTS="80/tcp,443/tcp" sudo -E bash server-setup.sh full --yes
#
#  Doctor exit codes: 0 all pass · 1 warnings · 2 failures (handy for cron/CI).
#  Safe to re-run. Never closes your current SSH session; test a new login
#  before you log out.
# =============================================================================
set -Eeuo pipefail
SCRIPT_VERSION="2.1.0"

# ------------------------------- Configuration -------------------------------
# Every value can be set as an environment variable; blanks are prompted for.
MODE="${MODE:-}"                         # update|upgrade|essential|full|doctor
NEW_USER="${NEW_USER:-}"                 # sudo user to create
SSH_PUBKEY="${SSH_PUBKEY:-}"             # public key text OR path to a .pub file
SSH_PORT="${SSH_PORT:-}"                 # default = current SSH port
ALLOW_PORTS="${ALLOW_PORTS-__ask__}"     # extra inbound ports, e.g. "80/tcp,443/tcp"
SUDO_PASSWORD="${SUDO_PASSWORD:-}"       # blank + unattended -> passwordless sudo
TIMEZONE="${TIMEZONE:-UTC}"
HOSTNAME_NEW="${HOSTNAME_NEW:-}"         # blank = keep current hostname
SWAP_SIZE="${SWAP_SIZE:-auto}"           # full only: auto | 0 | e.g. 2G
ALLOW_TCP_FORWARDING="${ALLOW_TCP_FORWARDING:-local}"  # no | local | yes
WEB_CONN_LIMIT="${WEB_CONN_LIMIT:-100}"  # full only: concurrent conns per IP on 80/443; 0 = off (use 0 behind a CDN)
WEB_RATE_LIMIT="${WEB_RATE_LIMIT:-50/sec}" # full only: new conns per IP on 80/443
FAIL2BAN_IGNOREIP="${FAIL2BAN_IGNOREIP:-}" # IPs/CIDRs never banned
AUTO_REBOOT="${AUTO_REBOOT:-false}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"
JOURNAL_MAX="${JOURNAL_MAX:-500M}"       # full only
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
ASSUME_YES="${ASSUME_YES:-false}"

ESSENTIAL_PKGS=(sudo openssh-server ca-certificates curl wget gnupg ufw fail2ban
                python3-systemd unattended-upgrades needrestart)
FULL_PKGS=(git vim nano htop tmux unzip zip jq rsync tree lsof dnsutils iproute2
           bash-completion logrotate)

# --------------------------------- Helpers -----------------------------------
LOG_FILE=/var/log/server-setup.log
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/server-setup-backup-$TS"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

if [[ -t 1 ]]; then
  c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_c=$'\e[36m'; c_d=$'\e[2m'; c_b=$'\e[1m'; c_0=$'\e[0m'
else
  c_g=""; c_y=""; c_r=""; c_c=""; c_d=""; c_b=""; c_0=""
fi
log()  { printf '%s[+]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$c_b" "$*" "$c_0"; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND (see $LOG_FILE)"' ERR

usage() {
  cat <<EOF
server-setup.sh v$SCRIPT_VERSION — Ubuntu/Debian setup, hardening and health check

Usage: sudo bash server-setup.sh [command] [--yes]

Commands:
  (none)      Interactive dashboard
  update      apt update + upgrade (no config changes)
  upgrade     full-upgrade, remove unused packages, clean cache
  essential   Admin user, key-only SSH, root locked, firewall, Fail2ban, auto-updates
  full        Essential + kernel/DDoS hardening, swap, log cap, admin tools
  doctor      Scan current status and recommend fixes (exit 0/1/2)
  release-info     Show the OS upgrade path, benefits, known issues and checks (read-only)
  release-upgrade  Upgrade Ubuntu to the next LTS (asks for a backup confirmation)

Options:
  -y, --yes   Never prompt (unattended)
  -h, --help  Show this help

Settings are environment variables (NEW_USER, SSH_PUBKEY, SSH_PORT,
ALLOW_PORTS, TIMEZONE, ...). See the header of this script.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help|help) usage; exit 0 ;;
    menu|update|upgrade|essential|full|doctor|release-info|release-upgrade) MODE=$arg ;;
    *) usage; die "Unknown command: $arg" ;;
  esac
done

INTERACTIVE=false
if [[ "$ASSUME_YES" != true ]] && { : </dev/tty; } 2>/dev/null; then INTERACTIVE=true; fi

ask() {  # ask VAR "prompt" "default"
  local __var=$1 __prompt=$2 __def=${3:-} __r=""
  if $INTERACTIVE; then
    if ! read -rp "$__prompt${__def:+ [$__def]}: " __r </dev/tty; then echo; exit 0; fi
  fi
  printf -v "$__var" '%s' "${__r:-$__def}"
}
confirm() { local __a; ask __a "$1 [y/N]" ""; [[ "$__a" =~ ^[Yy] ]]; }
pause()   { if $INTERACTIVE; then read -rp "Press Enter to return to the menu..." _ </dev/tty || true; fi; }

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

pkg_installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]; }

# ------------------------------- Preflight -----------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (e.g. sudo bash $0)."
[[ -r /etc/os-release ]] || die "Cannot detect OS."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" =~ ^(ubuntu|debian)$ || "${ID_LIKE:-}" == *debian* ]] \
  || die "Unsupported OS: ${PRETTY_NAME:-unknown}. Ubuntu/Debian only."

touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g' >>"$LOG_FILE")) 2>&1
printf '\n--- server-setup v%s · %s · %s ---\n' "$SCRIPT_VERSION" "${MODE:-menu}" "$(date)" >>"$LOG_FILE"

# ----------------------------- State probes ----------------------------------
SSHD_EFF=""; CUR_SSH_PORT=22; UFW_STATUS=""; UFW_ACTIVE=false; F2B_ACTIVE=false; AUTOUPD=false
UPD_ALL=0; UPD_SEC=0; APT_AGE_H=0

sshv() { awk -v k="$1" '$1==k {print $2; exit}' <<<"$SSHD_EFF"; }

probe_state() {
  SSHD_EFF=""
  if command -v sshd >/dev/null 2>&1; then
    mkdir -p /run/sshd
    SSHD_EFF=$(sshd -T 2>/dev/null || true)
  fi
  CUR_SSH_PORT=$(sshv port); CUR_SSH_PORT=${CUR_SSH_PORT:-22}
  UFW_STATUS=""; UFW_ACTIVE=false
  if command -v ufw >/dev/null 2>&1; then UFW_STATUS=$(ufw status verbose 2>/dev/null || true); fi
  if grep -q '^Status: active' <<<"$UFW_STATUS"; then UFW_ACTIVE=true; fi
  F2B_ACTIVE=false
  if systemctl is-active --quiet fail2ban 2>/dev/null; then F2B_ACTIVE=true; fi
  local ac; ac=$(apt-config dump 2>/dev/null || true)
  AUTOUPD=false
  if pkg_installed unattended-upgrades && grep -q 'APT::Periodic::Unattended-Upgrade "1"' <<<"$ac"; then AUTOUPD=true; fi
}

count_updates() {
  local sim
  sim=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null || true)
  UPD_ALL=$(grep -c '^Inst ' <<<"$sim" || true)
  UPD_SEC=$(grep '^Inst ' <<<"$sim" | grep -ci 'security' || true)
  local lists=/var/lib/apt/lists
  APT_AGE_H=0
  if [[ -d $lists ]]; then APT_AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$lists") ) / 3600 )); fi
}

report_reboot() {
  if [[ -f /var/run/reboot-required ]]; then
    warn "Reboot required to finish updates ($(tr '\n' ' ' </var/run/reboot-required.pkgs 2>/dev/null || true)). Run: sudo reboot"
  else
    log "No reboot needed."
  fi
}

# =============================================================================
#  Maintenance tasks
# =============================================================================
task_update() {
  step "Update system (apt update + upgrade)"
  apt_get update
  apt_get upgrade
  apt_get autoremove --purge
  log "System updated."
  report_reboot
}

task_upgrade() {
  step "Full system upgrade (full-upgrade + cleanup)"
  apt_get update
  apt_get full-upgrade
  apt_get autoremove --purge
  apt_get autoclean
  log "System upgraded and cleaned."
  report_reboot
  if [[ -f /var/run/reboot-required ]] && $INTERACTIVE && confirm "Reboot now?"; then
    log "Rebooting..."; reboot
  fi
}

# =============================================================================
#  OS release upgrade (Ubuntu)
#
#  apt upgrade / full-upgrade never change the Ubuntu version. A new release
#  needs do-release-upgrade, and only one LTS at a time:
#  18.04 -> 20.04 -> 22.04 -> 24.04
# =============================================================================
UBUNTU_LTS_PATH=(18.04 20.04 22.04 24.04)
R_NAME=""; R_STD_END=""; R_ESM_END=""; R_NEXT=""; R_BENEFITS=""; R_ISSUES=""
RP_BLOCK=0

release_info() {  # release_info VERSION -> R_* globals (support dates, next hop, benefits, known issues)
  R_NAME=""; R_STD_END=""; R_ESM_END=""; R_NEXT=""; R_BENEFITS=""; R_ISSUES=""
  case "$1" in
    18.04)
      R_NAME=bionic; R_STD_END=2023-05-31; R_ESM_END=2028-04-30; R_NEXT=20.04
      R_BENEFITS="- Python 3.8, OpenSSH 8.2 (FIDO keys), kernel 5.4, WireGuard built in
- Required stepping stone: Ubuntu upgrades one LTS at a time, so keep going to 22.04 and 24.04
- A newer OpenSSH and OpenSSL, which this script's hardening needs"
      R_ISSUES="- 'python' (Python 2) is no longer installed by default; old scripts fail
- Python 3.6 virtualenvs must be rebuilt
- PHP 7.2 -> 7.4, MySQL 5.7 -> 8.0, PostgreSQL 10 -> 12: back up databases; PostgreSQL needs pg_upgradecluster
- Third-party PPAs are disabled during the upgrade; re-enable them afterwards
- Out-of-tree kernel modules (DKMS) may fail to build; 32-bit-only software may stop working" ;;
    20.04)
      R_NAME=focal; R_STD_END=2025-05-31; R_ESM_END=2030-04-30; R_NEXT=22.04
      R_BENEFITS="- Kernel 5.15, Python 3.10, PHP 8.1, OpenSSL 3, newer toolchains
- Standard security support until April 2027
- cgroup v2 by default and better container support"
      R_ISSUES="- OpenSSL 3.0 breaks some older compiled apps (old Ruby, Node and PHP builds)
- OpenSSH 8.8+ disables SHA-1 'ssh-rsa' signatures: very old SSH clients may be refused
- cgroup v2: old Docker (before 20.10) and some LXC setups need updating
- PHP 7.4 -> 8.1 has breaking changes; PostgreSQL 12 -> 14 needs pg_upgradecluster
- Python 3.8 virtualenvs must be rebuilt" ;;
    22.04)
      R_NAME=jammy; R_STD_END=2027-04-30; R_ESM_END=2032-04-30; R_NEXT=24.04
      R_BENEFITS="- Standard security support until April 2029
- Kernel 6.8, OpenSSH 9.6, Python 3.12, PHP 8.3, glibc 2.39
- Newer compilers and runtimes, and better hardware support"
      R_ISSUES="- SSH uses socket activation (ssh.socket): changing the port only in sshd_config no longer applies. This script handles it
- System-wide 'pip install' is blocked (PEP 668 'externally-managed-environment'): use a venv or pipx
- Python 3.12 removed distutils; some old packages fail to install
- AppArmor restricts unprivileged user namespaces: Chrome, Puppeteer and Electron sandboxes may need a profile
- APT sources move to /etc/apt/sources.list.d/ubuntu.sources (new format): update config-management templates
- PostgreSQL 14 -> 16 needs pg_upgradecluster; PHP 8.1 -> 8.3 has deprecations" ;;
    24.04)
      R_NAME=noble; R_STD_END=2029-04-30; R_ESM_END=2034-04-30; R_NEXT=""
      R_BENEFITS="- Current baseline, standard security support until April 2029"
      R_ISSUES="- A newer LTS may be offered. Check with: do-release-upgrade -c
- Ubuntu usually offers a new LTS only after its first point release (.1)" ;;
  esac
  return 0
}

release_path_text() {  # 18.04 -> 20.04 -> 22.04 -> 24.04, starting at the current version
  local v out="" on=false
  for v in "${UBUNTU_LTS_PATH[@]}"; do
    [[ $v == "${VERSION_ID:-}" ]] && on=true
    if $on; then out="${out:+$out → }$v"; fi
  done
  printf '%s' "$out"
}

release_plan() {  # read-only: print the plan and run checks. Sets RP_BLOCK (number of blockers)
  RP_BLOCK=0
  local ver=${VERSION_ID:-0} today; today=$(date +%F)
  step "OS release upgrade plan — ${PRETTY_NAME:-unknown}"

  if [[ ${ID:-} != ubuntu ]]; then
    warn "A guided release upgrade is built in for Ubuntu only."
    cat <<EOF
For Debian, follow the official release notes and upgrade one release at a time:
  https://www.debian.org/releases/stable/releasenotes
EOF
    RP_BLOCK=1; return 0
  fi

  release_info "$ver"
  if [[ -z $R_NAME ]]; then
    warn "Ubuntu $ver is not in this script's release table (interim or very new release)."
    echo "Ask Ubuntu what it offers:  do-release-upgrade -c"
    RP_BLOCK=1; return 0
  fi

  # --- where you are ---
  local status
  if [[ $today > $R_STD_END ]]; then
    status="${c_r}standard support ended $R_STD_END${c_0} (security fixes only with Ubuntu Pro ESM until $R_ESM_END)"
  elif [[ $today > $(date -d "$R_STD_END -365 days" +%F) ]]; then
    status="${c_y}standard support ends $R_STD_END${c_0}"
  else
    status="${c_g}supported until $R_STD_END${c_0}"
  fi
  printf '\n  %-14s Ubuntu %s (%s) — %b\n' "Current:" "$ver" "$R_NAME" "$status"

  if [[ -z $R_NEXT ]]; then
    printf '  %-14s %s\n' "Upgrade path:" "none in the built-in table. You are on the newest LTS this script knows."
    printf '\n%sNotes%s\n%s\n' "$c_b" "$c_0" "$R_ISSUES"
    RP_BLOCK=1; return 0
  fi

  local next_name next_std
  local keep_name=$R_NAME keep_issues=$R_ISSUES keep_ben=$R_BENEFITS keep_next=$R_NEXT
  release_info "$keep_next"; next_name=$R_NAME; next_std=$R_STD_END
  R_NAME=$keep_name; R_ISSUES=$keep_issues; R_BENEFITS=$keep_ben; R_NEXT=$keep_next

  printf '  %-14s %s  %s(one LTS at a time, reboot between steps)%s\n' "Upgrade path:" "$(release_path_text)" "$c_d" "$c_0"
  local next_note="supported until $next_std"
  if [[ $today > $next_std ]]; then next_note="standard support already ended $next_std: keep going to the next LTS after it"; fi
  printf '  %-14s Ubuntu %s (%s) — %s\n' "Next step:" "$R_NEXT" "$next_name" "$next_note"
  printf '\n%sWhat you gain%s\n%s\n' "$c_b" "$c_0" "$R_BENEFITS"
  printf '\n%sKnown issues to check first%s\n%s\n' "$c_b" "$c_0" "$R_ISSUES"

  # --- pre-flight checks ---
  printf '\n%sPre-flight checks%s\n' "$c_b" "$c_0"
  local free_gb boot_mb held reboot third p pkgs=""
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if (( ${free_gb:-0} < 5 )); then
    printf '  %s✘%s %s GB free on / (need at least 5 GB)\n' "$c_r" "$c_0" "${free_gb:-0}"; RP_BLOCK=$((RP_BLOCK + 1))
  else
    printf '  %s✔%s %s GB free on /\n' "$c_g" "$c_0" "$free_gb"
  fi
  if mountpoint -q /boot 2>/dev/null; then
    boot_mb=$(df -Pm /boot | awk 'NR==2 {print $4}')
    if (( boot_mb < 300 )); then
      printf '  %s✘%s only %s MB free on /boot (need 300 MB): remove old kernels with apt autoremove --purge\n' "$c_r" "$c_0" "$boot_mb"; RP_BLOCK=$((RP_BLOCK + 1))
    fi
  fi
  held=$(apt-mark showhold 2>/dev/null | xargs || true)
  if [[ -n $held ]]; then
    printf '  %s✘%s held packages block the upgrade: %s (apt-mark unhold <name>)\n' "$c_r" "$c_0" "$held"; RP_BLOCK=$((RP_BLOCK + 1))
  else
    printf '  %s✔%s no held packages\n' "$c_g" "$c_0"
  fi
  reboot=false; [[ -f /var/run/reboot-required ]] && reboot=true
  if $reboot; then
    printf '  %s✘%s a reboot is pending: reboot first, then run this again\n' "$c_r" "$c_0"; RP_BLOCK=$((RP_BLOCK + 1))
  else
    printf '  %s✔%s no reboot pending\n' "$c_g" "$c_0"
  fi
  third=$(grep -rhsE '^(deb|URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -viE 'ubuntu\.com|ubuntu-ports|ubuntu\.sources' | grep -c . || true)
  if (( third > 0 )); then
    printf '  %s!%s %s third-party apt source line(s): they are disabled during the upgrade; re-enable afterwards\n' "$c_y" "$c_0" "$third"
  fi
  for p in mysql-server mariadb-server postgresql docker-ce docker.io mongodb-org; do
    pkg_installed "$p" && pkgs="$pkgs $p"
  done
  if [[ -n $pkgs ]]; then
    printf '  %s!%s services installed:%s — back up their data before upgrading\n' "$c_y" "$c_0" "$pkgs"
  fi
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    printf '  %s!%s you are connected over SSH: the upgrade opens a spare SSH on port 1022 in case this session drops\n' "$c_y" "$c_0"
    if [[ -z ${TMUX:-} && -z ${STY:-} ]]; then
      printf '  %s!%s not inside tmux or screen: run "tmux" first so a dropped connection cannot interrupt the upgrade\n' "$c_y" "$c_0"
    fi
  fi
  printf '  %s!%s take a snapshot or backup of the whole server first (this cannot be undone)\n' "$c_y" "$c_0"
  return 0
}

task_release_upgrade() {
  release_plan
  if (( RP_BLOCK > 0 )); then
    warn "Fix the items marked ✘ (or the notes above), then run this again."
    return 0
  fi

  if $INTERACTIVE; then
    echo
    confirm "I have a fresh backup or snapshot of this server" || { warn "Cancelled — nothing changed."; return 0; }
    local typed; ask typed "Type UPGRADE to start the upgrade to Ubuntu $R_NEXT" ""
    [[ $typed == UPGRADE ]] || { warn "Cancelled — nothing changed."; return 0; }
  elif [[ ${CONFIRM_RELEASE_UPGRADE:-} != yes ]]; then
    die "Unattended OS upgrades need CONFIRM_RELEASE_UPGRADE=yes (and a backup). Nothing changed."
  fi

  local target=$R_NEXT
  step "Bringing Ubuntu ${VERSION_ID} fully up to date first"
  apt_get update
  apt_get full-upgrade
  apt_get autoremove --purge
  if [[ -f /var/run/reboot-required ]]; then
    warn "That update needs a reboot first. Run: sudo reboot — then run this again."
    return 0
  fi

  step "Preparing the release upgrader"
  pkg_installed update-manager-core || apt_get install update-manager-core
  if [[ -f /etc/update-manager/release-upgrades ]]; then
    backup /etc/update-manager/release-upgrades
    sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades
  fi

  local avail; avail=$(do-release-upgrade -c 2>&1 || true)
  if grep -qi 'no new release found' <<<"$avail"; then
    warn "Ubuntu does not offer $target from this system yet:"
    echo "$avail" | sed 's/^/    /'
    return 0
  fi
  log "Ubuntu offers: $(grep -i 'new release' <<<"$avail" | head -1)"

  local ufw_1022=false
  if [[ -n ${SSH_CONNECTION:-} ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 1022/tcp comment 'release-upgrade spare ssh' >/dev/null && ufw_1022=true
    log "Opened port 1022 in UFW for the upgrader's spare SSH."
  fi

  step "Upgrading to Ubuntu $target (log: /var/log/dist-upgrade/)"
  if $INTERACTIVE; then
    # the upgrader asks questions and needs the real terminal, not the log pipe
    do-release-upgrade </dev/tty >/dev/tty 2>/dev/tty || warn "The upgrader exited with an error; see /var/log/dist-upgrade/."
  else
    do-release-upgrade -f DistUpgradeViewNonInteractive || warn "The upgrader exited with an error; see /var/log/dist-upgrade/."
  fi

  # shellcheck disable=SC1091
  local now; now=$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")
  echo
  log "System now reports: $now"
  if $ufw_1022; then log "Remove the spare port when done: sudo ufw delete allow 1022/tcp"; fi
  cat <<EOF

Next:
  1. sudo reboot   (if the upgrader did not already)
  2. Log in again and check your services and databases
  3. Re-enable any third-party apt sources you use
  4. Run again for the next step (one LTS at a time):  sudo bash $0 release-info
  5. Check the result:  sudo bash $0 doctor
EOF
  return 0
}

# =============================================================================
#  Setup (essential | full)
# =============================================================================
NEED_PW=true; OLD_SSH_PORT=22; CURRENT_IP=""; USER_HOME=""; AUTH_KEYS=""

collect_setup_input() {
  local level=$1 ans
  step "${level^} setup — configuration"
  OLD_SSH_PORT=$CUR_SSH_PORT

  local sc=${SSH_CLIENT:-}
  CURRENT_IP=${sc%% *}
  if [[ -z "$CURRENT_IP" ]]; then CURRENT_IP=$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' || true); fi
  [[ "$CURRENT_IP" =~ ^[0-9a-fA-F:.]+$ ]] || CURRENT_IP=""

  [[ -n "$NEW_USER" ]] || ask NEW_USER "Admin username to create" "admin"
  [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username: '$NEW_USER'"
  [[ "$NEW_USER" != root ]] || die "NEW_USER cannot be root."

  [[ -n "$SSH_PORT" ]] || ask SSH_PORT "SSH port" "$CUR_SSH_PORT"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "Invalid SSH port: $SSH_PORT"

  if [[ "$ALLOW_PORTS" == "__ask__" ]]; then
    ask ALLOW_PORTS "Extra inbound ports to open, comma-separated (e.g. 80/tcp,443/tcp; blank = none)" ""
  fi
  ALLOW_PORTS=$(tr ',' ' ' <<<"$ALLOW_PORTS")

  # --- SSH public key: refuse to continue without one ---
  USER_HOME="/home/$NEW_USER"
  if id "$NEW_USER" &>/dev/null; then USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6); fi
  AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"

  if [[ -n "$SSH_PUBKEY" && -f "$SSH_PUBKEY" ]]; then SSH_PUBKEY=$(<"$SSH_PUBKEY"); fi
  if [[ -z "$SSH_PUBKEY" && -s "$AUTH_KEYS" ]]; then
    log "Existing key(s) found in $AUTH_KEYS — keeping them."
  elif [[ -z "$SSH_PUBKEY" && -s /root/.ssh/authorized_keys ]]; then
    ans="y"; ask ans "Copy root's existing authorized_keys to $NEW_USER? [Y/n]" "y"
    if [[ "$ans" =~ ^[Yy] ]]; then SSH_PUBKEY=$(grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true); fi
  fi
  if [[ -z "$SSH_PUBKEY" && ! -s "$AUTH_KEYS" ]]; then
    ask SSH_PUBKEY "Paste your SSH PUBLIC key (from ~/.ssh/id_ed25519.pub on your computer)" ""
  fi
  if [[ -n "$SSH_PUBKEY" ]]; then
    local tmpk; tmpk=$(mktemp)
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
    local p1 p2
    while true; do
      read -rsp "Set a sudo password for $NEW_USER (blank = passwordless sudo): " p1 </dev/tty; echo
      [[ -z "$p1" ]] && break
      read -rsp "Repeat password: " p2 </dev/tty; echo
      if [[ "$p1" == "$p2" ]]; then SUDO_PASSWORD=$p1; break; fi
      warn "Passwords do not match, try again."
    done
  fi

  local scope="packages, admin user, key-only SSH, root locked, UFW, Fail2ban, auto-updates"
  [[ $level == full ]] && scope="$scope, + tools, swap, log cap, kernel/DDoS hardening, web flood limits"
  cat <<EOF

  Mode:            ${level^} setup
  Includes:        $scope
  User:            $NEW_USER (sudo, key-only SSH)
  SSH port:        $SSH_PORT$( [[ $SSH_PORT != "$OLD_SSH_PORT" ]] && echo " (currently $OLD_SSH_PORT)")
  Open ports:      ${SSH_PORT}/tcp (rate-limited) ${ALLOW_PORTS:-}
  Root login:      disabled + root password locked
  Password login:  disabled
  Timezone:        $TIMEZONE
EOF
  if [[ $level == full ]]; then
    printf '  Web limits:      %s\n' "$( ((WEB_CONN_LIMIT > 0)) && echo "${WEB_CONN_LIMIT} conns/IP, ${WEB_RATE_LIMIT} new conns/IP on 80/443" || echo off)"
  fi
  echo
  if $INTERACTIVE && ! confirm "Proceed?"; then warn "Cancelled — nothing changed."; return 1; fi
  return 0
}

s_packages() {
  local level=$1 p
  step "Updating system & installing packages"
  apt_get update
  apt_get full-upgrade
  local want=("${ESSENTIAL_PKGS[@]}")
  [[ $level == full ]] && want+=("${FULL_PKGS[@]}")
  local extra=(); read -ra extra <<<"$EXTRA_PACKAGES"
  want+=("${extra[@]}")
  local avail=()
  for p in "${want[@]}"; do
    if apt-cache show "$p" &>/dev/null; then avail+=("$p"); else warn "Package not available, skipping: $p"; fi
  done
  apt_get install "${avail[@]}"
  apt_get autoremove --purge
}

s_basics() {
  local level=$1
  step "Timezone & time sync"
  timedatectl set-timezone "$TIMEZONE" || warn "Could not set timezone $TIMEZONE"
  timedatectl set-ntp true 2>/dev/null || warn "Could not enable NTP (container?)"

  if [[ -n "$HOSTNAME_NEW" ]]; then
    step "Hostname"
    backup /etc/hosts
    hostnamectl set-hostname "$HOSTNAME_NEW"
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME_NEW/" /etc/hosts
    else
      printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" >>/etc/hosts
    fi
  fi

  [[ $level == full ]] || return 0

  step "Swap"
  local size=$SWAP_SIZE
  if [[ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]]; then
    log "Swap already active — skipping."
  elif [[ "$size" != 0 ]]; then
    if [[ "$size" == auto ]]; then
      local mem_mb; mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
      if (( mem_mb < 4096 )); then size=2G; else size=0; log "${mem_mb} MB RAM — swap not needed."; fi
    fi
    if [[ "$size" != 0 ]]; then
      local free_mb need_mb
      free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
      need_mb=$(numfmt --from=iec "$size" | awk '{print int($1/1048576)}')
      if (( free_mb > need_mb + 1024 )); then
        fallocate -l "$size" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$need_mb" status=none
        chmod 600 /swapfile && mkswap /swapfile >/dev/null
        if swapon /swapfile 2>/dev/null; then
          grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
          log "Created $size swap file."
        else
          rm -f /swapfile; warn "swapon not permitted (container?) — no swap created."
        fi
      else
        warn "Not enough disk space for $size swap — skipping."
      fi
    fi
  fi

  step "Journald size limit"
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=%s\nCompress=yes\n' "$JOURNAL_MAX" >/etc/systemd/journald.conf.d/99-size.conf
  systemctl restart systemd-journald 2>/dev/null || true
}

s_user() {
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
  SUDO_PASSWORD=""

  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$USER_HOME/.ssh"
  touch "$AUTH_KEYS"
  if [[ -n "$SSH_PUBKEY" ]]; then
    local k
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      grep -qxF "$k" "$AUTH_KEYS" || echo "$k" >>"$AUTH_KEYS"
    done <<<"$SSH_PUBKEY"
  fi
  chmod 600 "$AUTH_KEYS"; chown "$NEW_USER:$NEW_USER" "$AUTH_KEYS"
  [[ -s "$AUTH_KEYS" ]] || die "authorized_keys is empty — aborting before SSH lockdown."
  log "SSH key(s) installed: $(grep -c . "$AUTH_KEYS")"
}

filter_algos() {  # keep only algorithms this OpenSSH build supports
  local type=$1 list=$2 sup a out=() arr=()
  sup=$(ssh -Q "$type" 2>/dev/null) || return 0
  IFS=, read -ra arr <<<"$list"
  for a in "${arr[@]}"; do
    if grep -qxF "$a" <<<"$sup"; then out+=("$a"); fi
  done
  (IFS=,; echo "${out[*]}")
}

restore_ssh() {
  warn "Restoring previous SSH configuration."
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf
  cp -a "$BACKUP_DIR/etc/ssh/." /etc/ssh/ 2>/dev/null || true
}

s_ssh_config() {
  local level=$1
  step "Hardening SSH (applied at the end)"
  backup /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/ssh/moduli
  mkdir -p /etc/ssh/sshd_config.d /run/sshd

  # Drop-ins must be read FIRST: sshd keeps the first value it sees.
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi

  local kex ciphers macs
  kex=$(filter_algos kex "mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,sntrup761x25519-sha512,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512")
  ciphers=$(filter_algos cipher "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr")
  macs=$(filter_algos mac "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com")

  # 00- prefix wins over cloud-init's 50-cloud-init.conf (PasswordAuthentication yes)
  cat >/etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# Managed by server-setup.sh v$SCRIPT_VERSION ($TS, $level)
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

# --- Modern crypto only (filtered to what this OpenSSH supports) ---
${kex:+KexAlgorithms $kex}
${ciphers:+Ciphers $ciphers}
${macs:+MACs $macs}
EOF
  chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

  if [[ $level == full && -f /etc/ssh/moduli ]]; then
    awk '$5 >= 3071' /etc/ssh/moduli >/etc/ssh/moduli.safe
    if [[ -s /etc/ssh/moduli.safe ]]; then mv /etc/ssh/moduli.safe /etc/ssh/moduli; else rm -f /etc/ssh/moduli.safe; fi
  fi

  if ! sshd -t; then restore_ssh; die "sshd config test failed — SSH left unchanged."; fi
  local eff want
  eff=$(sshd -T 2>/dev/null)
  for want in "passwordauthentication no" "permitrootlogin no" "port $SSH_PORT" "pubkeyauthentication yes"; do
    grep -qix "$want" <<<"$eff" || { restore_ssh; die "Effective sshd setting mismatch: expected '$want' (another config overrides it)."; }
  done
  log "sshd config validated."
}

s_root() {
  step "Locking root password"
  passwd -l root >/dev/null && log "Root password locked (use sudo from ${NEW_USER:-your admin user})."
}

s_sysctl() {
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
  log "Kernel hardening applied."
}

add_ufw_block() {  # file  cidr-mask  chain — idempotent extra filtering in UFW before-rules
  local f=$1 mask=$2 ch=$3 blk
  [[ -f "$f" ]] || return 0
  sed -i '/^# BEGIN server-setup/,/^# END server-setup/d' "$f"
  blk=$(mktemp)
  {
    echo "# BEGIN server-setup"
    echo "# Drop new TCP connections that do not start with SYN, and NULL/XMAS scans"
    echo "-A $ch -p tcp ! --syn -m conntrack --ctstate NEW -j DROP"
    echo "-A $ch -p tcp --tcp-flags ALL NONE -j DROP"
    echo "-A $ch -p tcp --tcp-flags ALL ALL -j DROP"
    if (( WEB_CONN_LIMIT > 0 )); then
      echo "# Per-IP limits on web ports (connection-flood mitigation)"
      echo "-A $ch -p tcp --syn -m multiport --dports 80,443 -m connlimit --connlimit-above $WEB_CONN_LIMIT --connlimit-mask $mask -j DROP"
      echo "-A $ch -p tcp --syn -m multiport --dports 80,443 -m hashlimit --hashlimit-name web$mask --hashlimit-mode srcip --hashlimit-srcmask $mask --hashlimit-above $WEB_RATE_LIMIT --hashlimit-burst 100 -j DROP"
    fi
    echo "# END server-setup"
  } >"$blk"
  awk -v bf="$blk" '/^COMMIT$/ && !done { while ((getline l < bf) > 0) print l; done=1 } { print }' "$f" >"$f.new"
  cat "$f.new" >"$f"; rm -f "$f.new" "$blk"
}

s_firewall() {
  local level=$1 p
  step "Firewall (UFW)"
  backup /etc/ufw/before.rules /etc/ufw/before6.rules /etc/default/ufw
  if [[ $level == full ]]; then
    s_sysctl
    add_ufw_block /etc/ufw/before.rules 32 ufw-before-input     # IPv4 chain
    add_ufw_block /etc/ufw/before6.rules 64 ufw6-before-input   # IPv6 chain is ufw6-*
    # Let UFW load OUR kernel settings instead of its own (which would undo some)
    sed -i 's|^IPT_SYSCTL=.*|IPT_SYSCTL=/etc/sysctl.d/99-server-hardening.conf|' /etc/default/ufw
  fi
  sed -i 's|^IPV6=.*|IPV6=yes|' /etc/default/ufw

  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny routed
  ufw limit "$SSH_PORT/tcp" comment 'SSH (rate limited)'
  for p in $ALLOW_PORTS; do ufw allow "$p" comment 'server-setup'; done
  ufw logging low

  if ! ufw --force enable; then
    warn "UFW failed to load custom rules — restoring default before.rules and retrying."
    cp -a "$BACKUP_DIR/etc/ufw/before.rules" /etc/ufw/before.rules 2>/dev/null || true
    cp -a "$BACKUP_DIR/etc/ufw/before6.rules" /etc/ufw/before6.rules 2>/dev/null || true
    ufw --force enable || die "UFW could not be enabled."
  fi
  ufw reload >/dev/null
  systemctl enable ufw >/dev/null 2>&1 || true
  ufw status verbose
}

s_fail2ban() {
  step "Fail2ban"
  local ignore
  ignore=$(xargs <<<"127.0.0.1/8 ::1 ${CURRENT_IP:-} $(tr ',' ' ' <<<"$FAIL2BAN_IGNOREIP")")
  backup /etc/fail2ban/jail.local
  cat >/etc/fail2ban/jail.local <<EOF
# Managed by server-setup.sh v$SCRIPT_VERSION
[DEFAULT]
ignoreip = $ignore
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
    systemctl enable fail2ban >/dev/null 2>&1 || true
    if systemctl restart fail2ban 2>/dev/null; then
      log "Fail2ban active (sshd + recidive)."
    else
      warn "Fail2ban configured but could not be started (no systemd?). Start it with: sudo systemctl restart fail2ban"
    fi
  else
    warn "Fail2ban config test failed — check: fail2ban-client -t"
  fi
}

s_autoupdates() {
  step "Automatic security updates"
  pkg_installed unattended-upgrades || apt_get install unattended-upgrades
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
  log "Automatic security updates enabled."
}

s_ssh_restart() {
  step "Restarting SSH (firewall already allows port $SSH_PORT)"
  if systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
    # Ubuntu 22.10+ socket activation: listening port comes from sshd_config via a generator
    systemctl daemon-reload || true
    systemctl restart ssh.socket || warn "Could not restart ssh.socket"
  fi
  if ! systemctl restart ssh 2>/dev/null && ! systemctl restart sshd 2>/dev/null; then
    warn "Could not restart SSH — the old settings are still live. Restart it with: sudo systemctl restart ssh"
    return 0
  fi
  sleep 1
  local listening; listening=$(ss -ltn 2>/dev/null || true)
  if grep -qE "[:.]$SSH_PORT\s" <<<"$listening"; then
    log "sshd listening on port $SSH_PORT."
  else
    warn "sshd does not appear to be listening on $SSH_PORT — check: ss -ltnp | grep ssh"
  fi
}

setup_summary() {
  local level=$1 ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  cat <<EOF

${c_g}${c_b}${level^} setup complete.${c_0}

${c_y}${c_b}IMPORTANT — DO NOT CLOSE THIS SESSION YET.${c_0}
From a NEW terminal on your computer, confirm you can log in:

    ssh -p $SSH_PORT $NEW_USER@${ip:-<server-ip>}
    sudo -v        # confirm sudo works

If your cloud provider has its own firewall / security group, make sure
TCP port $SSH_PORT is allowed there too.
EOF
  if [[ "$SSH_PORT" != "$OLD_SSH_PORT" ]]; then
    printf '\nThe old SSH port %s is still open in UFW. After testing, close it:\n    sudo ufw delete limit %s/tcp\n' "$OLD_SSH_PORT" "$OLD_SSH_PORT"
  fi
  cat <<EOF

Verify everything:   sudo bash server-setup.sh doctor
Backups:             $BACKUP_DIR
Log:                 $LOG_FILE
EOF
  report_reboot
}

run_setup() {
  local level=$1
  if [[ ${ID:-} == ubuntu ]] && dpkg --compare-versions "${VERSION_ID:-99}" lt 20.04; then
    warn "Ubuntu ${VERSION_ID} is too old for this setup: its OpenSSH does not understand the hardened SSH settings."
    warn "Upgrade the OS first:  sudo bash $0 release-upgrade   (plan: release-info)"
    return 0
  fi
  probe_state
  collect_setup_input "$level" || return 0
  TS=$(date +%Y%m%d-%H%M%S); BACKUP_DIR="/root/server-setup-backup-$TS"; mkdir -p "$BACKUP_DIR"
  s_packages "$level"
  s_basics "$level"
  s_user
  s_ssh_config "$level"
  s_root
  s_firewall "$level"
  s_fail2ban
  s_autoupdates
  s_ssh_restart
  setup_summary "$level"
}

# =============================================================================
#  Doctor — read-only health & security scan
# =============================================================================
D_PASS=0; D_WARN=0; D_FAIL=0; DOCTOR_RC=0; REC_LEVEL=none
FIX_TEXT=(); FIX_AUTO=(); FIX_AUTO_DESC=(); EMPTY_PW_USERS=""

sec() { printf '\n%s%s%s\n' "$c_b" "$1" "$c_0"; }

res() {  # res STATUS "message" ["fix"] ["auto-fix function"] ["essential|full"]
  local st=$1 msg=$2 fix=${3:-} auto=${4:-} lvl=${5:-} f
  case $st in
    PASS) D_PASS=$((D_PASS + 1)); printf '  %s✔ PASS%s  %s\n' "$c_g" "$c_0" "$msg" ;;
    WARN) D_WARN=$((D_WARN + 1)); printf '  %s! WARN%s  %s\n' "$c_y" "$c_0" "$msg" ;;
    FAIL) D_FAIL=$((D_FAIL + 1)); printf '  %s✘ FAIL%s  %s\n' "$c_r" "$c_0" "$msg" ;;
    INFO) printf '  %s· INFO%s  %s\n' "$c_c" "$c_0" "$msg" ;;
  esac
  if [[ -n $fix ]]; then
    printf '          %s→ %s%s\n' "$c_d" "$fix" "$c_0"
    FIX_TEXT+=("[$st] $msg → $fix")
  fi
  if [[ -n $auto ]]; then
    for f in "${FIX_AUTO[@]}"; do if [[ $f == "$auto" ]]; then auto=""; fi; done
    if [[ -n $auto ]]; then FIX_AUTO+=("$auto"); FIX_AUTO_DESC+=("$msg"); fi
  fi
  case $lvl in
    essential) [[ $REC_LEVEL == full ]] || REC_LEVEL=essential ;;
    full) REC_LEVEL=full ;;
  esac
  return 0
}

# --- automatic fixes (safe, targeted) ---
fix_updates()     { task_update; }
fix_autoupdates() { s_autoupdates; }
fix_fail2ban()    { step "Starting Fail2ban"; systemctl enable --now fail2ban && log "Fail2ban started."; }
fix_sysctl()      { s_sysctl; }
fix_ntp()         { step "Enabling time sync"; timedatectl set-ntp true && log "NTP enabled."; }
fix_lock_root()   { s_root; }
fix_ufw_ssh()     { step "Allowing SSH port $CUR_SSH_PORT in UFW"; ufw limit "$CUR_SSH_PORT/tcp" comment 'SSH (rate limited)'; }
fix_empty_pw()    {
  local u; step "Locking accounts with empty passwords"
  for u in $EMPTY_PW_USERS; do passwd -l "$u" >/dev/null && log "Locked $u"; done
}

doctor() {
  D_PASS=0; D_WARN=0; D_FAIL=0; REC_LEVEL=none
  FIX_TEXT=(); FIX_AUTO=(); FIX_AUTO_DESC=(); EMPTY_PW_USERS=""
  probe_state; count_updates
  step "Doctor — $(hostname) · ${PRETTY_NAME:-unknown} · $(date '+%Y-%m-%d %H:%M')"

  # ---------------------------------------------------------------- System
  sec "System"
  local ver=${VERSION_ID:-99} today; today=$(date +%F)
  if [[ $ID == ubuntu ]]; then
    release_info "$ver"
    if [[ -z $R_NAME ]]; then
      res INFO "${PRETTY_NAME:-Ubuntu} is not in the built-in support table; check do-release-upgrade -c"
    elif [[ $today > $R_STD_END ]]; then
      res FAIL "Ubuntu $ver standard support ended $R_STD_END (no free security updates)" "Upgrade the OS: sudo bash server-setup.sh release-info  (path: $(release_path_text))"
    elif [[ $today > $(date -d "$R_STD_END -365 days" +%F) ]]; then
      res WARN "Ubuntu $ver standard support ends $R_STD_END" "Plan the OS upgrade: sudo bash server-setup.sh release-info"
    else
      res PASS "Ubuntu $ver is supported until $R_STD_END"
    fi
  elif [[ $ID == debian && ${ver%%.*} =~ ^[0-9]+$ ]] && (( ${ver%%.*} < 12 )); then
    res WARN "Debian $ver is past regular support" "Upgrade to Debian 12 or newer"
  else
    res PASS "${PRETTY_NAME:-OS} is a supported release"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    res WARN "Reboot required to finish updates" "sudo reboot"
  else
    res PASS "No reboot pending"
  fi

  local disk_pct; disk_pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
  if (( disk_pct >= 90 )); then
    res FAIL "Root disk ${disk_pct}% full" "sudo apt-get autoremove --purge && sudo journalctl --vacuum-size=200M"
  elif (( disk_pct >= 80 )); then
    res WARN "Root disk ${disk_pct}% full" "sudo apt-get autoremove --purge && sudo journalctl --vacuum-size=200M"
  else
    res PASS "Root disk ${disk_pct}% used"
  fi

  local mem_mb swap_mb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  swap_mb=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
  if (( swap_mb == 0 && mem_mb < 2048 )); then
    res WARN "No swap and only ${mem_mb} MB RAM (risk of out-of-memory kills)" "Full setup creates a 2G swap file" "" full
  else
    res PASS "Memory ${mem_mb} MB, swap ${swap_mb} MB"
  fi

  local ntp; ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  case $ntp in
    yes) res PASS "Clock synchronised (NTP)" ;;
    no)  res WARN "Clock not synchronised" "sudo timedatectl set-ntp true" fix_ntp ;;
    *)   res INFO "Time sync status unavailable (container?)" ;;
  esac

  local failed; failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | xargs || true)
  if [[ -n $failed ]]; then
    res WARN "Failed services: $failed" "Inspect with: systemctl status <unit>"
  else
    res PASS "No failed services"
  fi

  # --------------------------------------------------------------- Updates
  sec "Updates"
  if (( APT_AGE_H > 24 )); then res INFO "Package lists are ${APT_AGE_H} h old; counts may be low until the next update"; fi
  if (( UPD_SEC > 0 )); then
    res FAIL "$UPD_SEC security updates pending ($UPD_ALL total)" "Update system (menu 1)" fix_updates
  elif (( UPD_ALL > 0 )); then
    res WARN "$UPD_ALL updates pending" "Update system (menu 1)" fix_updates
  else
    res PASS "System is up to date"
  fi
  if $AUTOUPD; then
    res PASS "Automatic security updates enabled"
  else
    res FAIL "Automatic security updates are off" "Enable unattended-upgrades" fix_autoupdates essential
  fi

  # ------------------------------------------------------------------- SSH
  sec "SSH"
  local has_key_admin=false
  if [[ -z $SSHD_EFF ]]; then
    if pkg_installed openssh-server; then
      res FAIL "Cannot read the sshd configuration" "Check it with: sudo sshd -t"
    else
      res INFO "OpenSSH server not installed — SSH checks skipped"
    fi
  else
    if [[ $CUR_SSH_PORT == 22 ]]; then
      res INFO "SSH on default port 22 (optional: a custom port cuts bot noise)"
    else
      res PASS "SSH on custom port $CUR_SSH_PORT"
    fi

    case "$(sshv permitrootlogin)" in
      no) res PASS "Root login disabled" ;;
      prohibit-password|without-password|forced-commands-only)
          res WARN "Root can log in with an SSH key" "Essential setup sets PermitRootLogin no" "" essential ;;
      *)  res FAIL "Root can log in with a password" "Essential setup sets PermitRootLogin no" "" essential ;;
    esac

    if [[ "$(sshv passwordauthentication)" == no ]]; then
      res PASS "Password login disabled"
    else
      res FAIL "Password login enabled (brute-force target)" "Essential setup switches SSH to key-only" "" essential
    fi

    local kbd; kbd=$(sshv kbdinteractiveauthentication); kbd=${kbd:-$(sshv challengeresponseauthentication)}
    if [[ $kbd == yes ]]; then
      res WARN "Keyboard-interactive login enabled (can allow passwords via PAM)" "Essential setup disables it" "" essential
    else
      res PASS "Keyboard-interactive login disabled"
    fi

    if [[ "$(sshv permitemptypasswords)" == yes ]]; then
      res FAIL "Empty passwords allowed over SSH" "Essential setup sets PermitEmptyPasswords no" "" essential
    fi
    if [[ "$(sshv pubkeyauthentication)" == no ]]; then
      res FAIL "Public-key login disabled" "Essential setup enables key login" "" essential
    fi
    if [[ "$(sshv x11forwarding)" == yes ]]; then
      res WARN "X11 forwarding enabled" "Essential setup disables it" "" essential
    fi
    local mat; mat=$(sshv maxauthtries); mat=${mat:-6}
    if (( mat > 4 )); then
      res WARN "MaxAuthTries is $mat (more guesses per connection)" "Essential setup sets it to 3" "" essential
    else
      res PASS "MaxAuthTries is $mat"
    fi

    local allow; allow=$(awk '$1=="allowusers" || $1=="allowgroups" {print $2}' <<<"$SSHD_EFF" | xargs || true)
    if [[ -n $allow ]]; then
      res PASS "SSH restricted to: $allow"
    else
      res WARN "Any account can attempt SSH login (no AllowUsers)" "Essential setup restricts SSH to your admin user" "" essential
    fi
  fi

  local admins="" u home
  for u in $(getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' ' ' || true); do
    home=$(getent passwd "$u" | cut -d: -f6 || true)
    if [[ -n $home && -s "$home/.ssh/authorized_keys" ]]; then admins="$admins $u"; fi
  done
  if [[ -n $admins ]]; then
    has_key_admin=true
    res PASS "Sudo user(s) with SSH keys:$admins"
  else
    res FAIL "No non-root sudo user with an SSH key" "Essential setup creates one" "" essential
  fi

  # -------------------------------------------------------------- Accounts
  sec "Accounts"
  local root_st; root_st=$(passwd -S root 2>/dev/null | awk '{print $2}' || true)
  if [[ $root_st == L ]]; then
    res PASS "Root password locked"
  elif $has_key_admin; then
    res WARN "Root has a usable password" "sudo passwd -l root" fix_lock_root
  else
    res WARN "Root has a usable password" "Create a sudo user first (Essential setup), then lock root" "" essential
  fi

  local uid0; uid0=$(awk -F: '$3==0 && $1!="root" {print $1}' /etc/passwd | xargs || true)
  if [[ -n $uid0 ]]; then
    res FAIL "Extra accounts with root privileges (UID 0): $uid0" "Investigate, then remove: sudo userdel <name>"
  else
    res PASS "Only root has UID 0"
  fi

  EMPTY_PW_USERS=$(awk -F: '$2=="" {print $1}' /etc/shadow | xargs || true)
  if [[ -n $EMPTY_PW_USERS ]]; then
    res FAIL "Accounts with empty passwords: $EMPTY_PW_USERS" "sudo passwd -l <name>" fix_empty_pw
  else
    res PASS "No accounts with empty passwords"
  fi

  local nopw; nopw=$(grep -rlsE '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | xargs || true)
  if [[ -n $nopw ]]; then res INFO "Passwordless sudo configured in: $nopw"; fi

  # -------------------------------------------------------------- Firewall
  sec "Firewall"
  if ! command -v ufw >/dev/null 2>&1; then
    local other; other=$( { nft list ruleset 2>/dev/null; iptables -S INPUT 2>/dev/null; } | grep -cE 'hook input|^-A INPUT' || true)
    if (( other > 0 )); then
      res WARN "UFW not installed (another firewall ruleset is present)" "Essential setup installs and configures UFW" "" essential
    else
      res FAIL "No firewall installed" "Essential setup installs UFW (deny incoming, allow SSH)" "" essential
    fi
  elif ! $UFW_ACTIVE; then
    res FAIL "UFW installed but inactive" "Essential setup enables it safely (SSH allowed first)" "" essential
  else
    res PASS "UFW firewall active"
    if grep -qE '^Default: (deny|reject) \(incoming\)' <<<"$UFW_STATUS"; then
      res PASS "Incoming traffic denied by default"
    else
      res FAIL "Firewall allows incoming traffic by default" "sudo ufw default deny incoming" "" essential
    fi
    if grep -qE "^${CUR_SSH_PORT}(/tcp)?[[:space:]]+LIMIT" <<<"$UFW_STATUS"; then
      res PASS "SSH port $CUR_SSH_PORT allowed and rate-limited"
    elif grep -qE "^${CUR_SSH_PORT}(/tcp)?[[:space:]]+ALLOW" <<<"$UFW_STATUS"; then
      res WARN "SSH port $CUR_SSH_PORT allowed but not rate-limited" "sudo ufw limit $CUR_SSH_PORT/tcp" fix_ufw_ssh
    else
      res FAIL "SSH port $CUR_SSH_PORT not explicitly allowed (lockout risk on reload)" "sudo ufw limit $CUR_SSH_PORT/tcp" fix_ufw_ssh
    fi
    if grep -q '^# BEGIN server-setup' /etc/ufw/before.rules 2>/dev/null; then
      res PASS "Flood & scan filters installed (SYN checks, web per-IP limits)"
    else
      res WARN "No extra flood/scan filtering" "Full setup adds packet filters and web per-IP limits" "" full
    fi
  fi

  local listen pub
  listen=$(ss -H -tulpn 2>/dev/null || true)
  pub=$(awk 'NF >= 5 {
      addr=$5; n=split(addr, a, ":"); port=a[n]; host=substr(addr, 1, length(addr)-length(port)-1)
      if (host ~ /^127\./ || host == "[::1]" || host == "::1" || host ~ /%lo$/) next
      proc=$7; sub(/^users:\(\("/, "", proc); sub(/".*/, "", proc); if (proc == "") proc="-"
      print port "/" $1 " " proc
    }' <<<"$listen" | sort -u -t/ -k1,1n || true)
  if [[ -n $pub ]]; then
    res INFO "Listening on public interfaces: $(xargs <<<"$(sed 's/ /:/' <<<"$pub")")"
    local line port proto proc open
    while read -r line; do
      [[ -z $line ]] && continue
      port=${line%%/*}; proto=${line#*/}; proto=${proto%% *}; proc=${line##* }
      case $port in
        3306|5432|6379|27017|9200|11211|5984|1433|9042)
          open=true
          if $UFW_ACTIVE && ! grep -qE "^${port}(/${proto})?[[:space:]]+(ALLOW|LIMIT)" <<<"$UFW_STATUS"; then open=false; fi
          if $open; then
            res WARN "Database/cache port $port ($proc) reachable from the internet" "Bind it to 127.0.0.1, or allow only trusted IPs: sudo ufw allow from <ip> to any port $port"
          fi ;;
      esac
    done <<<"$pub"
  elif command -v ss >/dev/null 2>&1; then
    res PASS "No services listening on public interfaces"
  fi

  if command -v docker >/dev/null 2>&1 && $UFW_ACTIVE; then
    res WARN "Docker is installed: published container ports bypass UFW" "Publish as 127.0.0.1:PORT:PORT behind a reverse proxy"
  fi

  # --------------------------------------------------- Intrusion prevention
  sec "Intrusion prevention"
  if ! pkg_installed fail2ban; then
    res FAIL "Fail2ban not installed" "Essential setup installs and configures it" "" essential
  elif ! $F2B_ACTIVE; then
    res FAIL "Fail2ban installed but not running" "sudo systemctl enable --now fail2ban" fix_fail2ban
  else
    local jails; jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' || true)
    if grep -qw sshd <<<"$jails"; then
      local banned; banned=$(fail2ban-client status sshd 2>/dev/null | awk '/Currently banned/ {print $NF}' || true)
      res PASS "Fail2ban active (jails: ${jails:-none}; ${banned:-0} IPs banned for SSH)"
    else
      res WARN "Fail2ban running without an sshd jail" "Essential setup adds the sshd and recidive jails" "" essential
    fi
  fi

  local logs fails=0
  logs=$(journalctl -q --no-pager --since '24 hours ago' _COMM=sshd _COMM=sshd-session 2>/dev/null || true)
  fails=$(grep -cE 'Failed (password|publickey)|Invalid user|authentication failure' <<<"$logs" || true)
  if (( fails > 50 )) && ! $F2B_ACTIVE; then
    res WARN "$fails failed SSH logins in the last 24 h with no Fail2ban" "Essential setup enables Fail2ban" "" essential
  else
    res INFO "$fails failed SSH login attempts in the last 24 h"
  fi

  # ------------------------------------------------------ Kernel hardening
  sec "Kernel hardening"
  local -a want=(net.ipv4.tcp_syncookies=1 net.ipv4.conf.all.accept_redirects=0
                 net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.all.accept_source_route=0
                 net.ipv4.icmp_echo_ignore_broadcasts=1 net.ipv4.conf.all.log_martians=1
                 kernel.dmesg_restrict=1 fs.suid_dumpable=0 fs.protected_symlinks=1)
  local kv key val cur bad=""
  for kv in "${want[@]}"; do
    key=${kv%%=*}; val=${kv#*=}
    cur=$(sysctl -n "$key" 2>/dev/null || true)
    if [[ -n $cur && $cur != "$val" ]]; then bad="$bad $key"; fi
  done
  cur=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || true)
  [[ $cur == 0 ]] && bad="$bad net.ipv4.conf.all.rp_filter"
  cur=$(sysctl -n kernel.kptr_restrict 2>/dev/null || true)
  [[ $cur == 0 ]] && bad="$bad kernel.kptr_restrict"
  if [[ -n $bad ]]; then
    res WARN "$(wc -w <<<"$bad") kernel settings not hardened:$bad" "Apply the hardening sysctl profile" fix_sysctl full
  else
    res PASS "SYN-flood, anti-spoofing and kernel info-leak settings hardened"
  fi

  # --------------------------------------------------------------- Summary
  local total=$((D_PASS + D_WARN + D_FAIL)) score=100
  (( total > 0 )) && score=$(( D_PASS * 100 / total ))
  local colour=$c_g
  (( score < 90 )) && colour=$c_y
  (( score < 60 )) && colour=$c_r
  printf '\n%sHealth score: %s%d%%%s   %s%d pass%s · %s%d warn%s · %s%d fail%s\n' \
    "$c_b" "$colour" "$score" "$c_0" "$c_g" "$D_PASS" "$c_0" "$c_y" "$D_WARN" "$c_0" "$c_r" "$D_FAIL" "$c_0"

  if (( ${#FIX_TEXT[@]} > 0 )); then
    printf '\n%sRecommended fixes%s\n' "$c_b" "$c_0"
    local i=1 t
    for t in "${FIX_TEXT[@]}"; do printf '  %2d. %s\n' "$i" "$t"; i=$((i + 1)); done
  else
    printf '\n%sNothing to fix.%s\n' "$c_g" "$c_0"
  fi

  if [[ $REC_LEVEL != none ]]; then
    printf '\n  Best single fix: %s%s setup%s (menu %s · sudo bash server-setup.sh %s)\n' \
      "$c_b" "${REC_LEVEL^}" "$c_0" "$([[ $REC_LEVEL == full ]] && echo 4 || echo 3)" "$REC_LEVEL"
  fi

  DOCTOR_RC=0
  if (( D_WARN > 0 )); then DOCTOR_RC=1; fi
  if (( D_FAIL > 0 )); then DOCTOR_RC=2; fi

  if $INTERACTIVE; then
    if (( ${#FIX_AUTO[@]} > 0 )); then
      printf '\n%sAutomatic fixes available:%s\n' "$c_b" "$c_0"
      local j
      for j in "${!FIX_AUTO_DESC[@]}"; do printf '  - %s\n' "${FIX_AUTO_DESC[$j]}"; done
      if confirm "Apply the ${#FIX_AUTO[@]} automatic fix(es) above now?"; then
        local fn
        for fn in "${FIX_AUTO[@]}"; do "$fn"; done
        log "Automatic fixes applied. Run the doctor again to confirm."
      fi
    fi
    if [[ $REC_LEVEL != none ]] && confirm "Run ${REC_LEVEL^} setup now to fix the rest?"; then
      run_setup "$REC_LEVEL"
    fi
  fi
  return 0
}

# =============================================================================
#  Dashboard
# =============================================================================
mark() { if [[ $1 == ok ]]; then printf '%s✔%s' "$c_g" "$c_0"; else printf '%s✘%s' "$c_r" "$c_0"; fi; }

dashboard() {
  probe_state; count_updates
  local mem swap disk ip up load cores reboot upd
  mem=$(free -h | awk '/^Mem:/ {print $3 " / " $2}')
  swap=$(free -h | awk '/^Swap:/ {print $2}')
  disk=$(df -hP / | awk 'NR==2 {print $5 " of " $2}')
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  up=$(uptime -p 2>/dev/null | sed 's/^up //' || true)
  load=$(cut -d' ' -f1-3 /proc/loadavg)
  cores=$(nproc)
  reboot="no"; [[ -f /var/run/reboot-required ]] && reboot="${c_y}yes${c_0}"
  upd="${c_g}up to date${c_0}"
  if (( UPD_ALL > 0 )); then upd="${c_y}${UPD_ALL} pending${c_0} (${UPD_SEC} security)"; fi

  local s_root=bad s_pw=bad s_fw=bad s_f2b=bad s_auto=bad
  [[ "$(sshv permitrootlogin)" == no ]] && s_root=ok
  [[ "$(sshv passwordauthentication)" == no ]] && s_pw=ok
  $UFW_ACTIVE && s_fw=ok
  $F2B_ACTIVE && s_f2b=ok
  $AUTOUPD && s_auto=ok

  if $INTERACTIVE && [[ -n ${TERM:-} ]]; then clear 2>/dev/null || true; fi
  printf '%s──────────────────────────────────────────────────────────────────────%s\n' "$c_d" "$c_0"
  printf ' %sserver-setup v%s%s · %s · %s\n' "$c_b" "$SCRIPT_VERSION" "$c_0" "$(hostname)" "${PRETTY_NAME:-unknown}"
  printf '%s──────────────────────────────────────────────────────────────────────%s\n' "$c_d" "$c_0"
  printf ' %-9s kernel %s · up %s · load %s · %s CPU\n' "System" "$(uname -r)" "${up:-?}" "$load" "$cores"
  printf ' %-9s RAM %s · swap %s · disk / %s\n' "Memory" "$mem" "$swap" "$disk"
  printf ' %-9s %s · SSH port %s\n' "Network" "${ip:-?}" "$CUR_SSH_PORT"
  printf ' %-9s %b · reboot required: %b\n' "Updates" "$upd" "$reboot"
  printf ' %-9s root login off %s  password login off %s  firewall %s  fail2ban %s  auto-updates %s\n' \
    "Security" "$(mark $s_root)" "$(mark $s_pw)" "$(mark $s_fw)" "$(mark $s_f2b)" "$(mark $s_auto)"
  printf '%s──────────────────────────────────────────────────────────────────────%s\n' "$c_d" "$c_0"
  cat <<EOF
  ${c_b}1)${c_0} Update system      apt update + upgrade (no config changes)
  ${c_b}2)${c_0} Upgrade system     full-upgrade, remove unused packages, clean cache
  ${c_b}3)${c_0} Essential setup    admin user, key-only SSH, root off, firewall, fail2ban, auto-updates
  ${c_b}4)${c_0} Full setup         essential + kernel/DDoS hardening, swap, log cap, tools
  ${c_b}5)${c_0} Doctor             scan current status and recommend fixes
  ${c_b}6)${c_0} OS release upgrade scan the upgrade path, benefits and known issues; upgrade Ubuntu
  ${c_b}7)${c_0} Show recent log
  ${c_b}0)${c_0} Exit
EOF
  echo
}

menu() {
  local choice
  while true; do
    dashboard
    choice=""; ask choice "Choose an option" ""
    case "$choice" in
      1) task_update; pause ;;
      2) task_upgrade; pause ;;
      3) run_setup essential; pause ;;
      4) run_setup full; pause ;;
      5) doctor; pause ;;
      6) task_release_upgrade; pause ;;
      7) tail -n 40 "$LOG_FILE"; pause ;;
      0|q|Q|exit) exit 0 ;;
      *) warn "Unknown option: ${choice:-<empty>}"; sleep 1 ;;
    esac
  done
}

# =============================================================================
#  Main
# =============================================================================
case "${MODE:-}" in
  ""|menu)
    if $INTERACTIVE; then menu; fi
    usage; die "No terminal available — pass a command (update, upgrade, essential, full, doctor, release-info, release-upgrade)." ;;
  update)          task_update ;;
  upgrade)         task_upgrade ;;
  essential|full)  run_setup "$MODE" ;;
  doctor)          doctor; exit "$DOCTOR_RC" ;;
  release-info)    release_plan ;;
  release-upgrade) task_release_upgrade ;;
esac