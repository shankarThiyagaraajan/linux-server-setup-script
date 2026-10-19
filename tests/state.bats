#!/usr/bin/env bats
load helper

setup() { load_libs; }

@test "state values round-trip and the file is private" {
  state_set ssh.port 2222
  state_set setup.admins "$(json_list ops dev)"
  state_set note "$(json_str 'quotes " and ünïcode')"
  [ "$(state_get ssh.port)" = 2222 ]
  [ "$(state_get setup.admins)" = '["ops", "dev"]' ]
  [ "$(state_get note)" = 'quotes " and ünïcode' ]
  [ -z "$(state_get missing.key)" ]
  [ "$(stat -c %a "$SS_STATE_DIR/state.json")" = 600 ]
  state_del ssh.port
  [ -z "$(state_get ssh.port)" ]
}

@test "dry-run never writes state" {
  SS_DRY_RUN=true state_set x 1
  [ ! -e "$SS_STATE_DIR/state.json" ]
}

@test "history records runs and the last result of each task" {
  history_add check ok "score 90"
  history_add updates ok "3 package(s) upgraded"
  run history_tail 5
  [[ ${lines[0]} == *updates* ]]
  [[ ${lines[1]} == *check* ]]
  [ "$(state_get last.check.summary)" = "score 90" ]
  [ "$(state_get last.updates.run_id)" = "$RUN_ID" ]
}

@test "a damaged state file is reported, not overwritten" {
  echo '{broken' >"$SS_STATE_DIR/state.json"
  run state_get x
  [ "$status" -ne 0 ]
  [[ $output == *"damaged"* ]]
  [ "$(cat "$SS_STATE_DIR/state.json")" = '{broken' ]
}
