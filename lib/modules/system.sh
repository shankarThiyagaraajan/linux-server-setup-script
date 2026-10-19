# shellcheck shell=bash
# system.sh: packages, firewall, Fail2ban, automatic updates, time sync.

apt_get() {
  run_cmd apt-get -y -q -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}
pkg_installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]; }

# Install only what is missing. No upgrades here: those are the "Install
# updates" task, so setup never surprises you with a full upgrade.
ensure_packages() {
  local p missing=()
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  (( ${#missing[@]} )) || return 0
  step "Installing ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt_get update
  apt_get install --no-install-recommends "${missing[@]}"
}

# ------------------------------------------------------------------ firewall
fw_ssh_port() { local p; p=$(state_get ssh.port); printf '%s' "${p:-${CFG[SSH_PORT]:-22}}"; }

apply_firewall() {
  local p cidr ports
  step "Firewall (UFW)"
  ensure_packages ufw
  run_cmd ufw default deny incoming >/dev/null
  run_cmd ufw default allow outgoing >/dev/null
  # Keep forwarding alone when this machine routes traffic (Docker, VPN, LXD).
  if [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 0 ]]; then run_cmd ufw default deny routed >/dev/null; fi

  if [[ ${CFG[MACHINE_TYPE]} == server ]] || cfg_has ssh; then
    ports=$(ssh_current_ports 2>/dev/null || true)
    for p in ${ports:-} $(fw_ssh_port); do
      # Trusted addresses first, so they are never rate-limited.
      for cidr in ${CFG[TRUSTED_CIDRS]}; do
        run_cmd ufw allow from "$cidr" to any port "$p" proto tcp comment 'server-setup: SSH trusted' >/dev/null
      done
      run_cmd ufw limit "$p/tcp" comment 'server-setup: SSH' >/dev/null
    done
  fi
  for p in ${CFG[OPEN_PORTS]}; do run_cmd ufw allow "$p" comment 'server-setup' >/dev/null; done
  run_cmd ufw logging low >/dev/null
  run_cmd ufw --force enable >/dev/null
  run_cmd systemctl enable ufw >/dev/null 2>&1 || true
  state_set firewall.ports "$(json_list ${CFG[OPEN_PORTS]})"
  log "Firewall on: incoming blocked except ${CFG[OPEN_PORTS]:-SSH}${CFG[OPEN_PORTS]:+ and SSH}."
}

# Ports allowed in UFW that setup did not open (opened by hand later).
fw_unmanaged_ports() {
  local saved line port
  saved=" $(state_get firewall.ports | tr -d '[]",') $(state_get ssh.port) $(state_get ssh.previous_port) "
  while read -r line; do
    port=${line%% *}
    [[ $port =~ ^[0-9] ]] || continue
    port=${port%%(v6)*}
    if [[ $saved != *" $port "* && $saved != *" ${port%/*} "* && $saved != *" ${port%/*}/tcp "* ]]; then
      printf '%s\n' "$port"
    fi
  done < <(ufw status 2>/dev/null | awk 'NR>4 && ($2=="ALLOW" || $2=="LIMIT") {print $1}' | sort -u)
}

# ------------------------------------------------------------------ fail2ban
apply_fail2ban() {
  local ignore f2b_ports
  step "Fail2ban"
  f2b_ports=$(ssh_current_ports 2>/dev/null | tr ' ' ',' || true)
  f2b_ports=${f2b_ports:-$(fw_ssh_port)}
  ensure_packages fail2ban python3-systemd
  ignore=$(xargs <<<"127.0.0.1/8 ::1 ${CFG[TRUSTED_CIDRS]}")
  write_file /etc/fail2ban/jail.d/server-setup.local 644 <<EOF
# Managed by server-setup
[DEFAULT]
ignoreip  = $ignore
backend   = systemd
banaction = ufw
banaction_allports = ufw
findtime  = 10m
bantime   = 1h
maxretry  = 5
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1w

[sshd]
enabled  = true
port     = $f2b_ports
mode     = aggressive
maxretry = 3

[recidive]
enabled  = true
backend  = auto
logpath  = /var/log/fail2ban.log
bantime  = 1w
findtime = 1d
EOF
  [[ $SS_DRY_RUN == true ]] && return 0
  touch /var/log/fail2ban.log
  fail2ban-client -t >/dev/null 2>&1 || die "Fail2ban rejected its config (check: fail2ban-client -t)."
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || warn "Fail2ban could not start; check: systemctl status fail2ban"
  log "Fail2ban on (sshd and repeat offenders)."
}

# --------------------------------------------------------------- auto updates
apply_autoupdates() {
  local reboot=${CFG[AUTO_REBOOT]}
  step "Automatic security updates"
  ensure_packages unattended-upgrades
  [[ ${CFG[MACHINE_TYPE]} == personal ]] && reboot=false   # never reboot someone's laptop
  write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  write_file /etc/apt/apt.conf.d/52server-setup-unattended 644 <<EOF
// Managed by server-setup
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "$reboot";
Unattended-Upgrade::Automatic-Reboot-Time "${CFG[REBOOT_TIME]}";
EOF
  run_cmd systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  log "Security updates install daily${reboot:+; automatic reboot: $reboot at ${CFG[REBOOT_TIME]}}."
}

# ------------------------------------------------------------------ time sync
apply_timesync() {
  step "Time zone and clock sync"
  if [[ -n ${CFG[TIMEZONE]} ]]; then run_cmd timedatectl set-timezone "${CFG[TIMEZONE]}" || warn "Could not set the time zone."; fi
  if ! systemctl list-unit-files chrony.service &>/dev/null || ! pkg_installed chrony; then
    pkg_installed systemd-timesyncd || ensure_packages systemd-timesyncd
  fi
  run_cmd timedatectl set-ntp true 2>/dev/null || warn "Could not turn on clock sync (container?)."
}

# --------------------------------------------------------------------- updates
task_updates() {
  step "Installing updates"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local n summary
  apt_get update
  n=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)
  apt_get full-upgrade
  apt_get autoremove --purge
  summary="$n package(s) upgraded"
  (( n == 0 )) && summary="already up to date"
  [[ -f /var/run/reboot-required ]] && summary="$summary · reboot needed"
  history_add updates ok "$summary"
  log "Done: $summary."
}
