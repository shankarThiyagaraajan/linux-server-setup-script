# shellcheck shell=bash
# ssh.sh: SSH hardening with a safety net.
#
#  - Access is limited to the ssh-users group (AllowGroups), never one user.
#  - An existing multi-factor setup (AuthenticationMethods with several
#    methods) is kept.
#  - A port change listens on the old AND new port until you confirm.
#  - Before sshd restarts, a timer is armed that restores the previous SSH
#    config unless `server-setup confirm` is run from a NEW login in time.

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-server-setup.conf
SSHD_LEGACY_DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf   # written by v2
CONFIRM_MINUTES=${CONFIRM_MINUTES:-10}
CONFIRM_UNIT=server-setup-confirm
SSH_CHANGED=false

sshd_effective() { mkdir -p /run/sshd; sshd -T 2>/dev/null; }
sshd_value() { awk -v k="$1" '$1==k {print $2; exit}' <<<"${2:-$(sshd_effective)}"; }
ssh_current_ports() { awk '$1=="port" {print $2}' <<<"$(sshd_effective)" | sort -un | xargs; }

ssh_filter_algos() {  # keep only what this OpenSSH build supports
  local type=$1 list=$2 sup a out=()
  sup=$(ssh -Q "$type" 2>/dev/null) || return 0
  local IFS=,
  for a in $list; do
    if grep -qxF "$a" <<<"$sup"; then out+=("$a"); fi
  done
  printf '%s' "${out[*]}"
}

# ssh_render PORT... : the drop-in content.
ssh_render() {
  local p eff methods kex ciphers macs kbd=no
  eff=$(sshd_effective || true)
  methods=$(sshd_value authenticationmethods "$eff")
  # Keep a multi-factor setup (e.g. publickey,keyboard-interactive) instead of replacing it.
  if [[ $methods == *,* ]]; then kbd=yes; else methods=publickey; fi
  kex=$(ssh_filter_algos kex "mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,sntrup761x25519-sha512,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512")
  ciphers=$(ssh_filter_algos cipher "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr")
  macs=$(ssh_filter_algos mac "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com")

  printf '# Managed by server-setup. Change it with: sudo server-setup setup\n'
  printf '# (hand edits are reported as drift by the security check)\n'
  for p in "$@"; do printf 'Port %s\n' "$p"; done
  cat <<EOF

# Who can log in, and how
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication $kbd
PermitEmptyPasswords no
AuthenticationMethods $methods
UsePAM yes
AllowGroups $SSH_GROUP
MaxAuthTries 3
MaxSessions 10
MaxStartups 10:30:60
LoginGraceTime 30

# Features
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding ${CFG[SSH_FORWARDING]}
PermitTunnel no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
EOF
  printf '\n# Modern algorithms only (filtered to what this OpenSSH supports)\n'
  [[ -n $kex ]] && printf 'KexAlgorithms %s\n' "$kex"
  [[ -n $ciphers ]] && printf 'Ciphers %s\n' "$ciphers"
  [[ -n $macs ]] && printf 'MACs %s\n' "$macs"
  return 0
}

ssh_restore_files() {
  warn "Restoring the previous SSH configuration."
  rollback_run "$RUN_ID" /etc/ssh/ || true
}

# apply_ssh: writes and validates; the restart happens in ssh_restart at the very end.
apply_ssh() {
  local cur_ports new_port ports pend_old before after eff want
  step "SSH"
  cur_ports=$(ssh_current_ports); cur_ports=${cur_ports:-22}
  new_port=${CFG[SSH_PORT]:-${cur_ports%% *}}
  ports=$new_port
  pend_old=$(state_get ssh.pending.old_port)
  if [[ -n $pend_old && $pend_old != "$new_port" ]]; then
    ports="$pend_old $new_port"          # a port change is still waiting for confirm: keep both
  elif [[ " $cur_ports " != *" $new_port "* ]]; then
    ports="${cur_ports%% *} $new_port"
  fi
  if [[ $ports == *" "* ]]; then info "SSH will listen on ${ports% *} and $new_port until you confirm the new port works."; fi

  before=$( { cat "$SSHD_DROPIN" "$SSHD_LEGACY_DROPIN" 2>/dev/null || true; } | sha256sum)
  if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    backup_file /etc/ssh/sshd_config
    run_cmd sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
  # shellcheck disable=SC2086
  ssh_render $ports | write_file "$SSHD_DROPIN" 644
  if [[ -e $SSHD_LEGACY_DROPIN ]]; then
    backup_file "$SSHD_LEGACY_DROPIN"; run_cmd rm -f "$SSHD_LEGACY_DROPIN"
    info "Replaced the old 00-hardening.conf from server-setup v2."
  fi
  after=$( { cat "$SSHD_DROPIN" "$SSHD_LEGACY_DROPIN" 2>/dev/null || true; } | sha256sum)
  [[ $before != "$after" ]] && SSH_CHANGED=true
  [[ $SS_DRY_RUN == true ]] && return 0

  on_error_push ssh_restore_files
  if ! sshd -t; then ssh_restore_files; die "The new SSH config failed sshd -t. SSH was left unchanged."; fi
  eff=$(sshd_effective)
  for want in "passwordauthentication no" "permitrootlogin no" "port $new_port" "pubkeyauthentication yes"; do
    if ! grep -qix "$want" <<<"$eff"; then
      ssh_restore_files
      die "Another SSH config file overrides '$want'. Check /etc/ssh/sshd_config and sshd_config.d/, then run_cmd again."
    fi
  done
  if grep -qi '^allowusers ' <<<"$eff"; then
    warn "Another SSH config sets AllowUsers; users must match it AND the $SSH_GROUP group."
  fi
  on_error_pop
  [[ -n $pend_old ]] || state_set ssh.previous_port "${cur_ports%% *}"
  state_set ssh.port "$new_port"
  log "SSH config written and validated."
}

ssh_service_restart() {
  if systemctl is-enabled ssh.socket &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
    systemctl daemon-reload          # Ubuntu's socket generator reads the port from sshd_config
    systemctl restart ssh.socket
  fi
  systemctl restart ssh
}

# The entry point used by the dead-man timer and by confirm.
ss_self() { printf '%s' "${SS_SELF:-/usr/local/sbin/server-setup}"; }

ssh_restart() {
  [[ $SSH_CHANGED == true ]] || { info "SSH settings unchanged; no restart needed."; return 0; }
  if [[ $SS_DRY_RUN == true ]]; then echo "  would restart SSH with a ${CONFIRM_MINUTES}-minute undo timer"; return 0; fi
  local old_port new_port
  old_port=$(state_get ssh.previous_port); new_port=$(state_get ssh.port)
  if is_true "${SS_NO_CONFIRM:-false}"; then
    warn "Undo timer skipped (--no-confirm-timer). Make sure you can log in before you disconnect."
  else
    systemctl stop "$CONFIRM_UNIT.timer" 2>/dev/null || true
    systemd-run --quiet --unit "$CONFIRM_UNIT" --on-active="${CONFIRM_MINUTES}min" \
      --description "server-setup: undo SSH changes unless confirmed" \
      "$(ss_self)" rollback --ssh "$RUN_ID" >/dev/null
    state_set ssh.pending "{\"run_id\": $(json_str "$RUN_ID"), \"applied\": $(date +%s), \"old_port\": $(json_str "$old_port"), \"new_port\": $(json_str "$new_port")}"
  fi
  step "Restarting SSH"
  ssh_service_restart
  sleep 1
  if ss -ltn | grep -qE "[:.]$new_port\s"; then log "SSH is listening on port $new_port."; else warn "SSH does not seem to listen on $new_port; check: ss -ltnp | grep ssh"; fi
}

# ---------------------------------------------------------------- confirm / undo
# ssh_session_start: when the current login session began (epoch seconds).
ssh_session_start() {
  local sid et
  sid=$(ps -o sid= -p $$ | tr -d ' ')
  et=$(ps -o etimes= -p "$sid" 2>/dev/null | tr -d ' ')
  [[ -n $et ]] && echo $(( $(date +%s) - et ))
}

cmd_confirm() {
  local pending applied old new start conn_port
  pending=$(state_get ssh.pending)
  if [[ -z $pending ]]; then log "Nothing to confirm: no SSH change is waiting."; return 0; fi
  applied=$(state_get ssh.pending.applied); old=$(state_get ssh.pending.old_port); new=$(state_get ssh.pending.new_port)
  start=$(ssh_session_start || true)
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    conn_port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    if [[ -n $start && $start -lt $applied ]]; then
      die "This is the login you ran setup from. Open a NEW SSH login (ssh -p $new ...) and run 'sudo server-setup confirm' there."
    fi
    if [[ $conn_port != "$new" ]]; then
      die "This login came in on port $conn_port, not the new port $new. Log in with: ssh -p $new ... and confirm from there."
    fi
  fi
  systemctl stop "$CONFIRM_UNIT.timer" "$CONFIRM_UNIT.service" 2>/dev/null || true
  if [[ -n $old && $old != "$new" ]]; then
    step "Closing the old SSH port $old"
    CFG[SSH_FORWARDING]=$(sshd_value allowtcpforwarding); CFG[SSH_FORWARDING]=${CFG[SSH_FORWARDING]:-local}
    ssh_render "$new" | write_file "$SSHD_DROPIN" 644
    sshd -t || die "sshd -t failed; the old port stays open."
    ufw delete limit "$old/tcp" >/dev/null 2>&1 || ufw delete allow "$old/tcp" >/dev/null 2>&1 || true
    ssh_service_restart
  fi
  state_del ssh.pending
  state_set ssh.previous_port "$new"
  history_add confirm ok "SSH changes confirmed${old:+ (port $old closed)}"
  log "Confirmed. The undo timer is cancelled and SSH changes are permanent."
}

cmd_rollback_ssh() {
  local id=$1
  step "Undoing SSH changes from run $id"
  rollback_run "$id" /etc/ssh/
  sshd -t || die "Restored config fails sshd -t; check /etc/ssh by hand."
  ssh_service_restart
  state_del ssh.pending
  history_add rollback ok "SSH changes from run $id were undone (not confirmed in time)"
  log "Previous SSH configuration restored."
}
