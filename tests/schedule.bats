#!/usr/bin/env bats
load helper

setup() {
  export SS_SCHED_DIR=$BATS_TEST_TMPDIR/units SS_MAINT_BACKUP_DIR=$BATS_TEST_TMPDIR/backups
  load_libs
  export SHIM_DIR=$T/shim SHIM_LOG=$T/shim.log PATH="$BATS_TEST_DIRNAME/shims:$PATH"
  export SS_JOURNAL_CMD=true SS_WATCH_FILES="$T/none" SS_PROBE_PORTS=$T/ports SS_HEALTH_PROBE=$T/health
  mkdir -p "$SHIM_DIR" "$SS_SCHED_DIR"; : >"$SHIM_LOG"; : >"$T/ports"
  echo '{"cursor": "c0", "hashes": {}, "ports": {}}' >"$SS_STATE_DIR/watch.json"
  cfg_reset
}

# A fake security check: run_checks fills CHK_* from FAKE_SCORE / FAKE_FAILS.
fake_checks() {
  run_checks() {
    CHK_RESULTS=("PASS	SSH-ROOT	Root cannot log in over SSH	")
    local f; for f in $FAKE_FAILS; do CHK_RESULTS+=("FAIL	$f	$f is broken	fix it"); done
    CHK_SCORE=$FAKE_SCORE CHK_PASS=1 CHK_WARN=0 CHK_FAIL=$(wc -w <<<"$FAKE_FAILS")
  }
}
events() { _watch_py list 20 | awk -F'\x1f' '{print $3 "|" $4 "|" $8}'; }

@test "timers are written persistent and randomised, and only enabled jobs start" {
  CFG[MAINT_MONTHLY]=false
  SS_DRY_RUN=true apply_schedule >"$T/plan"
  grep -q 'would change .*server-setup-weekly.timer' "$T/plan"
  [ ! -e "$SS_SCHED_DIR/server-setup-weekly.timer" ]
  apply_schedule
  grep -qx 'Persistent=true' "$SS_SCHED_DIR/server-setup-daily.timer"
  grep -qx 'OnCalendar=Sun \*-\*-\* 04:30' "$SS_SCHED_DIR/server-setup-weekly.timer"
  grep -qx 'RandomizedDelaySec=1h' "$SS_SCHED_DIR/server-setup-monthly.timer"
  grep -qx 'Unit=server-setup-maintain@daily.service' "$SS_SCHED_DIR/server-setup-daily.timer"
  grep -qE '^ExecStart=.* maintain %i$' "$SS_SCHED_DIR/server-setup-maintain@.service"
  grep -q 'enable --now server-setup-daily.timer' "$SHIM_LOG"
  grep -q 'enable --now server-setup-weekly.timer' "$SHIM_LOG"
  grep -q 'disable --now server-setup-monthly.timer' "$SHIM_LOG"
}

@test "the daily check sets a baseline first, then alerts on a lower score or a new failure" {
  fake_checks
  FAKE_SCORE=90 FAKE_FAILS="UPD-AUTO" cmd_maintain daily
  [ "$MAINT_RESULT" = ok ]
  [ -z "$(events)" ]
  FAKE_SCORE=90 FAKE_FAILS="UPD-AUTO" cmd_maintain daily
  [ -z "$(events)" ]
  FAKE_SCORE=70 FAKE_FAILS="UPD-AUTO FW-ACTIVE" cmd_maintain daily
  [ "$MAINT_RESULT" = attention ]
  [[ $(events) == 'important|score-drop|Security score dropped from 90 to 70. New problem(s): FW-ACTIVE is broken' ]]
  [[ $(history_tail 1) == *maintain-daily*attention*"score 70 · score dropped"* ]]
}

@test "the weekly job backs up settings, keeps only the newest, and sends a report" {
  CFG[MAINT_UPDATES]=none CFG[MAINT_BACKUPS_KEEP]=2
  printf 'MAINT_UPDATES="none"\nMAINT_BACKUPS_KEEP="2"\n' >"$SS_CONF_DIR/config.env"
  apt_get() { :; }
  mkdir -p "$SS_MAINT_BACKUP_DIR"
  for d in 20260101 20260102 20260103; do touch -d "${d:0:4}-${d:4:2}-${d:6:2}" "$SS_MAINT_BACKUP_DIR/settings-$d-000000.tar.gz"; done
  cmd_maintain weekly
  [ "$(ls "$SS_MAINT_BACKUP_DIR" | grep -c .)" -eq 2 ]
  new=$(ls -t "$SS_MAINT_BACKUP_DIR"/settings-*.tar.gz | head -1)
  [ "$(stat -c %a "$new")" = 600 ]
  tar -tzf "$new" | grep -q '^etc/ssh/sshd_config$'
  [ ! -e "$SS_MAINT_BACKUP_DIR/settings-20260101-000000.tar.gz" ]
  [[ $(events) == "info|weekly-report|Updates: updates off"* ]]
  [[ $(history_tail 1) == *maintain-weekly*ok*"updates off · settings saved"* ]]
}

@test "security-only weekly updates use unattended-upgrade" {
  CFG[MAINT_UPDATES]=security
  apt_get() { echo "apt-get $*" >>"$T/calls"; }
  maint_backup() { :; }
  mkdir -p "$T/bin"; printf '#!/bin/sh\n' >"$T/bin/unattended-upgrade"; chmod +x "$T/bin/unattended-upgrade"
  PATH="$T/bin:$PATH" SS_DRY_RUN=true maint_weekly >"$T/out"
  grep -q 'would run: unattended-upgrade' "$T/out"
  grep -q 'apt-get update' "$T/calls"
  ! grep -q 'full-upgrade' "$T/calls"
}

@test "the monthly review reports a new Ubuntu release" {
  SS_PROBE_NEXT_RELEASE="26.04 LTS" cmd_maintain monthly
  [[ $(events) == "info|new-release|Ubuntu 26.04 LTS is available."* ]]
}

@test "maintenance settings are validated" {
  CFG[MACHINE_TYPE]=personal CFG[MAINT_UPDATES]=most CFG[MAINT_BACKUPS_KEEP]=0 CFG[MAINT_DAILY]=yes
  run cfg_validate
  [ "$status" -eq 1 ]
  [[ $output == *"MAINT_UPDATES must be security, all or none"* ]]
  [[ $output == *"MAINT_BACKUPS_KEEP must be"* ]]
  [[ $output == *"MAINT_DAILY must be true or false"* ]]
}
