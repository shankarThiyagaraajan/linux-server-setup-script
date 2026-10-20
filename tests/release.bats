#!/usr/bin/env bats
load helper

setup() {
  load_libs
  export SS_REL_CFG=$T/release-upgrades SS_REL_LOG=$T/rel.log SS_APT_SOURCES_D=$T/sources.list.d
  export SS_REBOOT_FLAG=$T/reboot-required
  REL_CFG=$SS_REL_CFG REL_LOG=$SS_REL_LOG
  mkdir -p "$SS_APT_SOURCES_D"
  printf '[DEFAULT]\nPrompt=lts\n' >"$SS_REL_CFG"
  export SS_PROBE_NEXT_RELEASE="26.04.1 LTS" SS_PROBE_PENDING_UPDATES=0 SS_PROBE_FREE_GB=20
  OS_VERSION=24.04
}

@test "the release channel is read and changed with a backup" {
  [ "$(rel_channel)" = lts ]
  rel_set_channel normal
  [ "$(rel_channel)" = normal ]
  grep -qx 'Prompt=normal' "$SS_REL_CFG"
  [ -f "$SS_STATE_DIR/backups/$RUN_ID/files$SS_REL_CFG" ]
  run rel_set_channel sometimes
  [ "$status" -eq 1 ]
}

@test "a ready machine has no blockers and offers the next release" {
  rel_preflight
  [ "$REL_BLOCKERS" -eq 0 ]
  [ "$REL_NEXT" = "26.04.1 LTS" ]
  [[ $(rel_rows_formatted) == *"Ubuntu 26.04.1 LTS is available"* ]]
}

@test "pending updates, a pending restart and low disk block, with fixes offered" {
  SS_PROBE_PENDING_UPDATES=12 SS_PROBE_FREE_GB=2
  touch "$SS_REBOOT_FLAG"
  rel_preflight
  [ "$REL_BLOCKERS" -eq 3 ]
  $REL_FIX_UPDATES
  $REL_FIX_REBOOT
  [[ $(rel_rows_formatted) == *"12 update(s) must be installed first"* ]]
}

@test "an unconfirmed SSH change blocks the upgrade" {
  state_set ssh.pending '{"new_port": "2222"}'
  rel_preflight
  [ "$REL_BLOCKERS" -eq 1 ]
  [[ $(rel_rows_formatted) == *"SSH change is waiting"* ]]
}

@test "no newer release, or upgrades turned off, is a blocker" {
  SS_PROBE_NEXT_RELEASE=""
  rel_preflight
  [ "$REL_BLOCKERS" -eq 1 ]
  [[ $(rel_rows_formatted) == *"No newer release on your channel (lts)"* ]]
  printf 'Prompt=never\n' >"$SS_REL_CFG"
  rel_preflight
  [[ $(rel_rows_formatted) == *"turned off"* ]]
}

@test "a laptop on battery is blocked" {
  state_set machine_type '"personal"'
  SS_PROBE_AC=0 rel_preflight
  [ "$REL_BLOCKERS" -eq 1 ]
  [[ $(rel_rows_formatted) == *"plug in the charger"* ]]
}

@test "progress phases are read from the log" {
  : >"$REL_LOG";                                   [ "$(rel_phase)" -eq 0 ]
  echo "Get:1 http://archive.ubuntu.com x" >>"$REL_LOG"; [ "$(rel_phase)" -eq 1 ]
  echo "Unpacking openssh-server (1:9.9)" >>"$REL_LOG"; [ "$(rel_phase)" -eq 2 ]
  echo "Searching for obsolete software" >>"$REL_LOG"; [ "$(rel_phase)" -eq 3 ]
  echo "==> do-release-upgrade finished with exit code 0" >>"$REL_LOG"; [ "$(rel_phase)" -eq 4 ]
  echo "    PASS  SSH is running" >>"$REL_LOG";      [ "$(rel_phase)" -eq 5 ]
}

@test "paused third-party sources are found and turned back on" {
  cat >"$SS_APT_SOURCES_D/docker.list" <<'SRC'
# deb [arch=amd64] https://download.docker.com/linux/ubuntu noble stable # disabled on upgrade to plucky
SRC
  printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/x/y/ubuntu\nEnabled: no\n' >"$SS_APT_SOURCES_D/x.sources"
  printf 'Types: deb\nEnabled: no\n' >"$SS_APT_SOURCES_D/ubuntu.sources"
  [ "$(rel_third_party_count)" -eq 2 ]
  [ "$(rel_disabled_sources | wc -l)" -eq 2 ]
  rel_enable_source "$SS_APT_SOURCES_D/docker.list"
  rel_enable_source "$SS_APT_SOURCES_D/x.sources"
  grep -qx 'deb \[arch=amd64\] https://download.docker.com/linux/ubuntu noble stable' "$SS_APT_SOURCES_D/docker.list"
  grep -qx 'Enabled: yes' "$SS_APT_SOURCES_D/x.sources"
  [ -z "$(rel_disabled_sources)" ]
}

@test "the background run records success and a failed upgrade" {
  ss_lock() { :; }
  rel_post_checks() { REL_POST_FAIL=0; }
  state_set release_upgrade '{"status": "running", "to": "26.04.1 LTS"}'
  SS_RELEASE_CMD=true cmd_release_run >/dev/null
  [ "$(state_get release_upgrade.status)" = ready ]
  [ "$(state_get last.release-upgrade.result)" = ok ]
  state_set release_upgrade.status '"running"'
  SS_RELEASE_CMD=false cmd_release_run >/dev/null
  [ "$(state_get release_upgrade.status)" = failed ]
  [ "$(state_get last.release-upgrade.result)" = failed ]
}

@test "a broken SSH config after the upgrade is re-written with the same ports and login methods" {
  command -v sshd || skip "openssh-server not installed"
  [[ $EUID -eq 0 ]] || skip "needs root"
  SSHD_DROPIN=$T/00-server-setup.conf
  printf 'Port 2222\nAuthenticationMethods publickey,keyboard-interactive\nCiphers no-such-cipher\n' >"$SSHD_DROPIN"
  sshd() { [[ $1 == -t ]] && ! grep -q no-such-cipher "$SSHD_DROPIN"; }
  rel_rerender_ssh
  grep -qx 'Port 2222' "$SSHD_DROPIN"
  ! grep -q 'Port 22$' "$SSHD_DROPIN"
  grep -qx 'AuthenticationMethods publickey,keyboard-interactive' "$SSHD_DROPIN"
  ! grep -q no-such-cipher "$SSHD_DROPIN"
}

@test "when the re-write does not help, the previous drop-in is put back" {
  SSHD_DROPIN=$T/00-server-setup.conf
  printf 'Port 2222\n' >"$SSHD_DROPIN"
  sshd() { return 1; }
  run rel_rerender_ssh
  [ "$status" -eq 1 ]
  [ "$(cat "$SSHD_DROPIN")" = "Port 2222" ]
}
