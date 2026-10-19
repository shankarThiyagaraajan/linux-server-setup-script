# shellcheck shell=bash
# files.sh: every file change goes through write_file, which
#   - skips the write when the content is already right (idempotent re-runs)
#   - backs up the old file once per run, with a manifest for exact rollback
#   - records the new file's hash so later runs can spot hand edits (drift)
#   - in dry-run mode only shows the diff

run_backup_dir() { printf '%s/backups/%s' "$SS_STATE_DIR" "$RUN_ID"; }

# backup_file PATH: once per run. Records whether the file existed, so a
# rollback can delete files this run created.
backup_file() {
  local f=$1 dir manifest
  [[ $SS_DRY_RUN == true ]] && return 0
  dir=$(run_backup_dir); manifest="$dir/manifest"
  install -d -m 700 "$dir/files"
  if [[ -f $manifest ]] && grep -qxF -e "existed	$f" -e "new	$f" "$manifest"; then return 0; fi
  if [[ -e $f ]]; then
    install -d -m 700 "$dir/files$(dirname "$f")"
    cp -a "$f" "$dir/files$f"
    printf 'existed\t%s\n' "$f" >>"$manifest"
  else
    printf 'new\t%s\n' "$f" >>"$manifest"
  fi
}

file_hash() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# write_file PATH MODE < content
write_file() {
  local f=$1 mode=$2 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $f ]] && cmp -s "$tmp" "$f"; then
    rm -f "$tmp"
    [[ $SS_DRY_RUN == true ]] || state_set "managed.$(managed_key "$f")" "$(json_str "$(file_hash "$f")")"
    return 0
  fi
  if [[ $SS_DRY_RUN == true ]]; then
    printf '%s  would change %s%s\n' "$C_AMBER" "$f" "$C_0"
    if [[ -f $f ]]; then
      diff -u --label "$f (now)" --label "$f (planned)" "$f" "$tmp" | sed 's/^/    /'
    else
      diff -u --label "(new file)" --label "$f" /dev/null "$tmp" | sed 's/^/    /'
    fi || true
    rm -f "$tmp"
    return 0
  fi
  backup_file "$f"
  install -d "$(dirname "$f")"
  install -m "$mode" "$tmp" "$f"
  rm -f "$tmp"
  state_set "managed.$(managed_key "$f")" "$(json_str "$(file_hash "$f")")"
}

# Dots in paths would split the state key; keep the path readable but safe.
managed_key() { local k=${1//./%2E}; printf '%s' "$k"; }
managed_path() { local p=${1//%2E/.}; printf '%s' "$p"; }

# drift_files: managed files whose content no longer matches what we wrote.
# Prints "path<TAB>modified-date" or "path<TAB>missing".
drift_files() {
  local k f want have
  while IFS= read -r k; do
    [[ -z $k ]] && continue
    f=$(managed_path "$k")
    want=$(state_get "managed.$k")
    if [[ ! -e $f ]]; then
      printf '%s\tmissing\n' "$f"
    else
      have=$(file_hash "$f")
      [[ $have == "$want" ]] || printf '%s\t%s\n' "$f" "$(date -r "$f" '+%-d %b %H:%M')"
    fi
  done < <(state_keys managed)
}

# accept_drift PATH: keep the hand edit; make it the new expected content.
accept_drift() { state_set "managed.$(managed_key "$1")" "$(json_str "$(file_hash "$1")")"; }

# rollback_run RUN_ID [PATH_PREFIX]: restore files a run changed.
rollback_run() {
  local id=$1 prefix=${2:-/} dir kind f
  dir="$SS_STATE_DIR/backups/$id"
  [[ -f $dir/manifest ]] || die "No backup found for run $id."
  while IFS=$'\t' read -r kind f; do
    [[ $f == "$prefix"* ]] || continue
    if [[ $kind == existed ]]; then
      cp -a "$dir/files$f" "$f"
      info "restored $f"
    else
      rm -f "$f"
      info "removed $f (created by run $id)"
    fi
    if [[ -e $f ]]; then accept_drift "$f"; else state_del "managed.$(managed_key "$f")"; fi
  done < <(tac "$dir/manifest")
}

list_runs_with_backups() { ls -1 "$SS_STATE_DIR/backups" 2>/dev/null | sort -r; }
