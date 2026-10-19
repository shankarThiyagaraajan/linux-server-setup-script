#!/usr/bin/env bats
load helper

setup() { load_libs; F=$T/etc/app.conf; mkdir -p "$T/etc"; }

@test "write_file is idempotent and backs up once per run" {
  echo old >"$F"
  echo new | write_file "$F" 640
  [ "$(cat "$F")" = new ]
  [ "$(stat -c %a "$F")" = 640 ]
  echo newer | write_file "$F" 640
  [ "$(cat "$SS_STATE_DIR/backups/$RUN_ID/files$F")" = old ]
  [ "$(grep -c . "$SS_STATE_DIR/backups/$RUN_ID/manifest")" = 1 ]
}

@test "dry-run shows a diff and changes nothing" {
  echo old >"$F"
  SS_DRY_RUN=true
  run write_file "$F" 644 <<<"new"
  [[ $output == *"would change $F"* && $output == *"+new"* ]]
  [ "$(cat "$F")" = old ]
  [ ! -d "$SS_STATE_DIR/backups/$RUN_ID" ]
}

@test "hand edits show up as drift until accepted" {
  echo managed | write_file "$F" 644
  [ -z "$(drift_files)" ]
  echo edited >"$F"
  [[ $(drift_files) == "$F"$'\t'* ]]
  accept_drift "$F"
  [ -z "$(drift_files)" ]
  rm "$F"
  [ "$(drift_files)" = "$F"$'\tmissing' ]
}

@test "paths with dots survive the state key" {
  F=$T/etc/sshd_config.d/00-x.conf; mkdir -p "$(dirname "$F")"
  echo a | write_file "$F" 644
  [ "$(state_keys managed)" = "$(managed_key "$F")" ]
  [ "$(managed_path "$(managed_key "$F")")" = "$F" ]
}

@test "rollback restores changed files and removes created ones" {
  echo old >"$F"
  echo new | write_file "$F" 644
  echo created | write_file "$T/etc/new.conf" 644
  rollback_run "$RUN_ID"
  [ "$(cat "$F")" = old ]
  [ ! -e "$T/etc/new.conf" ]
  [ -z "$(drift_files)" ]
}

@test "rollback can be limited to a path prefix" {
  mkdir -p "$T/ssh"; echo a >"$T/ssh/x"; echo b >"$F"
  echo a2 | write_file "$T/ssh/x" 644
  echo b2 | write_file "$F" 644
  rollback_run "$RUN_ID" "$T/ssh/"
  [ "$(cat "$T/ssh/x")" = a ]
  [ "$(cat "$F")" = b2 ]
}
