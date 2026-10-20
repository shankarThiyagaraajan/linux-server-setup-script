#!/usr/bin/env bats
# End-to-end setup on a THROWAWAY Ubuntu 24.04 container (it creates users and
# rewrites /etc/ssh). systemctl, ufw, timedatectl, systemd-run and
# fail2ban-client are replaced by recording test doubles; sshd -t is real.
# Run with: SS_INTEGRATION=1 bats tests/integration.bats

setup_file() {
  [[ ${SS_INTEGRATION:-} == 1 ]] || skip "set SS_INTEGRATION=1 (destructive: use a throwaway container)"
  export T=$(mktemp -d)
  export SS_STATE_DIR=$T/state SS_CONF_DIR=$T/conf SS_LOG=$T/log
  export SHIM_DIR=$T/shim SHIM_LOG=$T/shim.log SS_PATH_PREFIX=$BATS_TEST_DIRNAME/shims SS_MAINT_BACKUP_DIR=$T/maint
  mkdir -p "$SHIM_DIR"; : >"$SHIM_LOG"
  ssh-keygen -A >/dev/null
  ssh-keygen -q -t ed25519 -N '' -f "$T/id" >/dev/null
  cat >"$T/server.env" <<CFG
PROFILE="web"
COMPONENTS="ssh firewall fail2ban autoupdates timesync watch schedule"
MAINT_UPDATES="none"
RECOMMENDATIONS="REC-PWQUALITY"
ADMIN_USERS="opsadmin"
ADMIN_PUBKEY="$T/id.pub"
ADMIN_PASSWORD_HASH='$(openssl passwd -6 'correct horse battery')'
SSH_PORT="2222"
OPEN_PORTS="80/tcp 443/tcp"
TRUSTED_CIDRS="203.0.113.0/24"
CFG
}

teardown_file() { [[ -n ${T:-} ]] && rm -rf "$T"; }

# SS_BIN lets CI run the same tests against the bundled dist/server-setup.
ss() { "${SS_BIN:-$BATS_TEST_DIRNAME/../bin/server-setup}" "$@"; }

@test "setup applies a server profile unattended" {
  run ss setup --yes --type server --config "$T/server.env"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx 'AllowGroups ssh-users' /etc/ssh/sshd_config.d/00-server-setup.conf
  grep -qx 'Port 22' /etc/ssh/sshd_config.d/00-server-setup.conf      # old port kept until confirm
  grep -qx 'Port 2222' /etc/ssh/sshd_config.d/00-server-setup.conf
  sshd -t
  id -nG opsadmin | grep -qw sudo
  id -nG opsadmin | grep -qw ssh-users
  grep -qx 'ProtectSystem=strict' /etc/systemd/system/server-setup-watch.service
  grep -q 'systemctl restart server-setup-watch' "$SHIM_LOG"
  [ -x /etc/update-motd.d/60-server-setup ]
  grep -qx 'Persistent=true' /etc/systemd/system/server-setup-weekly.timer
  grep -q 'systemctl enable --now server-setup-daily.timer' "$SHIM_LOG"
  grep -qx 'minlen = 14' /etc/security/pwquality.conf.d/50-server-setup.conf
  grep -qF "$(cut -d' ' -f2 "$T/id.pub")" /home/opsadmin/.ssh/authorized_keys
  [ "$(passwd -S opsadmin | awk '{print $2}')" = P ]
  [ "$(passwd -S root | awk '{print $2}')" = L ]
  grep -q '^2222/tcp LIMIT' "$SHIM_DIR/ufw.rules"
  grep -q '^443/tcp ALLOW' "$SHIM_DIR/ufw.rules"
  grep -q 'systemd-run .*rollback --ssh' "$SHIM_LOG"
  grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/52server-setup-unattended
}

@test "state and history record the setup" {
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["setup"]["done"] and s["machine_type"]=="server" and s["ssh"]["pending"]["new_port"]=="2222"' "$SS_STATE_DIR/state.json"
  grep -q '"task": "setup"' "$SS_STATE_DIR/history.jsonl"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["setup"]["run_id"])' "$SS_STATE_DIR/state.json" >"$T/first_run"
  [ "$(stat -c %a "$SS_STATE_DIR/state.json")" = 600 ]
  grep -q '^SSH_PORT="2222"' "$SS_CONF_DIR/config.env"
  ! grep -q PASSWORD_HASH "$SS_CONF_DIR/config.env"
}

@test "a second run before confirm keeps both ports and does not restart SSH" {
  : >"$SHIM_LOG"
  run ss setup --yes --config "$T/server.env"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"SSH settings unchanged"* ]]
  ! grep -q 'systemctl restart ssh' "$SHIM_LOG"
  grep -qx 'Port 22' /etc/ssh/sshd_config.d/00-server-setup.conf
}

@test "an unattended run refuses to overwrite hand edits" {
  echo '# hand edit' >>/etc/ssh/sshd_config.d/00-server-setup.conf
  run ss setup --yes --config "$T/server.env"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"changed by hand"* ]]
  run ss check --json
  [[ $output == *'"id": "DRIFT"'* ]]
  sed -i '/# hand edit/d' /etc/ssh/sshd_config.d/00-server-setup.conf
}

@test "confirm closes the old port and cancels the undo timer" {
  run ss confirm
  echo "$output"
  [ "$status" -eq 0 ]
  ! grep -qx 'Port 22' /etc/ssh/sshd_config.d/00-server-setup.conf
  grep -qx 'Port 2222' /etc/ssh/sshd_config.d/00-server-setup.conf
  grep -q 'systemctl stop server-setup-confirm.timer' "$SHIM_LOG"
  [ -z "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ssh"].get("pending",""))' "$SS_STATE_DIR/state.json")" ]
}

@test "the undo timer's rollback restores the previous SSH config" {
  run ss rollback --ssh "$(cat "$T/first_run")"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e /etc/ssh/sshd_config.d/00-server-setup.conf ]
  sshd -t
}

@test "invalid settings are all reported and nothing changes" {
  printf 'SSH_PORT="0022"\nOPEN_PORTS="80/xyz"\nADMIN_USERS="Bad User"\n' >"$T/bad.env"
  before=$(ls -l /etc/ssh/sshd_config.d)
  run ss setup --yes --type server --config "$T/bad.env"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ $output == *"SSH_PORT"* && $output == *"invalid port: 80/xyz"* && $output == *"invalid user name"* ]]
  [ "$before" = "$(ls -l /etc/ssh/sshd_config.d)" ]
}

@test "the events command scans and lists without failing" {
  run ss events --json
  echo "$output"
  [ "$status" -eq 0 ]
  python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$output"
}

@test "recommendations list what was applied" {
  run ss recommendations --json
  echo "$output"
  [ "$status" -eq 0 ]
  python3 -c 'import json,sys; r={x["id"]: x for x in json.loads(sys.stdin.read())}; assert r["REC-PWQUALITY"]["status"] == "in-place", r' <<<"$output"
}

@test "the weekly job saves a settings backup and records the run" {
  run ss maintain weekly
  echo "$output"
  [ "$status" -eq 0 ]
  ls "$T/maint"/settings-*.tar.gz
  tar -tzf "$(ls "$T/maint"/settings-*.tar.gz | head -1)" | grep -q 'conf/config.env$'
  grep -q '"task": "maintain-weekly"' "$SS_STATE_DIR/history.jsonl"
}
