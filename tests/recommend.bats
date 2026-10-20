#!/usr/bin/env bats
load helper

setup() {
  load_libs
  REC_GDM_CONF=$T/custom.conf
  printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=dev\n' >"$REC_GDM_CONF"
  state_set machine_type '"personal"'
}

ids() { for id in "${REC_IDS[@]}"; do rec_applies "$id" && echo "$id"; done; return 0; }

@test "only recommendations that fit the machine type are offered" {
  run ids
  [[ $output == *REC-DISK-ENCRYPTION* && $output == *REC-AUTOLOGIN* && $output == *REC-SYSCTL* ]]
  [[ $output != *REC-AUDITD* ]]
  state_set machine_type '"server"'
  run ids
  [[ $output == *REC-AUDITD* && $output == *REC-LIVEPATCH* && $output != *REC-SCREEN-LOCK* ]]
  state_set machine_type '"wsl"'
  run ids
  [[ $output == REC-PWQUALITY ]]   # the kernel, AppArmor and the desktop belong to Windows there
}

@test "decisions move a recommendation between open, skipped, postponed and never" {
  [ "$(rec_status REC-AUTOLOGIN)" = open ]
  rec_decide REC-AUTOLOGIN skip;  [ "$(rec_status REC-AUTOLOGIN)" = skip ]
  rec_decide REC-AUTOLOGIN never; [ "$(rec_status REC-AUTOLOGIN)" = never ]
  rec_decide REC-AUTOLOGIN later; [ "$(rec_status REC-AUTOLOGIN)" = later ]
  state_set recommendations.REC-AUTOLOGIN.until 1   # the reminder date has passed
  [ "$(rec_status REC-AUTOLOGIN)" = open ]
  [[ $(state_get recommendations.REC-AUTOLOGIN.by) == "${SUDO_USER:-root}" ]]
  [[ $(history_tail 1) == *"Turn off automatic login: later"* ]]
}

@test "apply previews in dry-run, then changes the file and records the decision" {
  SS_DRY_RUN=true rec_apply REC-AUTOLOGIN >"$T/plan"
  grep -q 'AutomaticLoginEnable=false' "$T/plan"
  grep -q 'AutomaticLoginEnable=true' "$REC_GDM_CONF"
  [ -z "$(rec_decision REC-AUTOLOGIN)" ]
  rec_apply REC-AUTOLOGIN
  grep -q '^AutomaticLoginEnable=false' "$REC_GDM_CONF"
  grep -q '^AutomaticLogin=dev' "$REC_GDM_CONF"
  [ "$(rec_status REC-AUTOLOGIN)" = in-place ]
  [ "$(rec_decision REC-AUTOLOGIN)" = applied ]
  # someone turns it back on: shown as drift from what was applied
  sed -i 's/=false/=true/' "$REC_GDM_CONF"
  [ "$(rec_status REC-AUTOLOGIN)" = applied-drift ]
  [[ $(rec_open_ids) == *REC-AUTOLOGIN* ]]
}

@test "the security check reports recommendations without counting them against the score" {
  rec_decide REC-SECURE-BOOT skip
  CHK_RESULTS=(); CHK_PASS=0; CHK_WARN=0; CHK_FAIL=0
  rec_checks
  [ "$CHK_WARN" -eq 0 ] && [ "$CHK_FAIL" -eq 0 ]
  printf '%s\n' "${CHK_RESULTS[@]}" >"$T/rows"
  grep -q $'^SKIP\tREC-SECURE-BOOT\tSecure Boot (skipped by you)' "$T/rows"
  grep -q $'^INFO\tREC-AUTOLOGIN\tTurn off automatic login: recommended' "$T/rows"
  rec_apply REC-AUTOLOGIN >/dev/null
  CHK_RESULTS=(); CHK_PASS=0; rec_checks
  printf '%s\n' "${CHK_RESULTS[@]}" | grep -q $'^PASS\tREC-AUTOLOGIN'
}

@test "a check the user chose never to be asked about is skipped, not failed" {
  state_set recommendations.FW-ACTIVE '{"decision": "never"}'
  CHK_RESULTS=(); CHK_FAIL=0
  chk FAIL FW-ACTIVE "Firewall is off" "fix"
  [ "$CHK_FAIL" -eq 0 ]
  [[ ${CHK_RESULTS[0]} == SKIP* ]]
}

@test "unattended runs apply only what RECOMMENDATIONS lists" {
  cfg_reset
  CFG[RECOMMENDATIONS]="REC-AUTOLOGIN REC-DISK-ENCRYPTION REC-AUDITD"
  run apply_recommendations
  [[ $output == *"REC-DISK-ENCRYPTION is check-only"* ]]
  [[ $output == *"REC-AUDITD does not apply to this machine"* ]]
  grep -q '^AutomaticLoginEnable=false' "$REC_GDM_CONF"
  [ -z "$(rec_decision REC-SCREEN-LOCK)" ]
  cfg_reset; CFG[RECOMMENDATIONS]=""
  printf 'AutomaticLoginEnable=true\n' >"$REC_GDM_CONF"
  apply_recommendations
  grep -q 'AutomaticLoginEnable=true' "$REC_GDM_CONF"
}

@test "settings reject unknown recommendation IDs" {
  cfg_reset
  CFG[MACHINE_TYPE]=personal CFG[RECOMMENDATIONS]="REC-AUTOLOGIN REC-NOPE"
  run cfg_validate
  [ "$status" -eq 1 ]
  [[ $output == *"unknown recommendation: REC-NOPE"* ]]
  [[ $output != *REC-AUTOLOGIN* ]]
}

@test "card decisions keep the saved settings in line" {
  printf 'MACHINE_TYPE="personal"\nRECOMMENDATIONS="REC-SYSCTL"\n' >"$SS_CONF_DIR/config.env"
  rec_cfg_list add REC-AUTOLOGIN
  grep -qx 'RECOMMENDATIONS="REC-SYSCTL REC-AUTOLOGIN"' "$SS_CONF_DIR/config.env"
  rec_cfg_list add REC-AUTOLOGIN
  grep -qx 'RECOMMENDATIONS="REC-SYSCTL REC-AUTOLOGIN"' "$SS_CONF_DIR/config.env"
  rec_cfg_list remove REC-SYSCTL
  grep -qx 'RECOMMENDATIONS="REC-AUTOLOGIN"' "$SS_CONF_DIR/config.env"
  [ "$(stat -c %a "$SS_CONF_DIR/config.env")" = 600 ]
}

@test "recommendations --json lists this machine's items with their state" {
  rec_decide REC-SECURE-BOOT never
  run cmd_recommendations true
  [ "$status" -eq 0 ]
  python3 -c '
import json, sys
rows = {r["id"]: r for r in json.loads(sys.argv[1])}
assert rows["REC-SECURE-BOOT"]["status"] == "never", rows
assert rows["REC-AUTOLOGIN"]["can_apply"] == "yes"
assert rows["REC-DISK-ENCRYPTION"]["can_apply"] == "no"
assert "REC-AUDITD" not in rows' "$output"
}
