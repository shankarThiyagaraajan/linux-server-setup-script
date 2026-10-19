# shellcheck shell=bash
# core.sh: paths, output helpers, exit codes, error trap, locking, run ids.

SS_VERSION="3.0.0-dev"

# A predictable PATH: under `su` (not `su -`) /usr/sbin is often missing.
export PATH=${SS_PATH_PREFIX:+$SS_PATH_PREFIX:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# UTF-8 so box drawing and character counts work under sudo and cron.
export LC_ALL=C.UTF-8

# Everything can be redirected for tests.
SS_STATE_DIR="${SS_STATE_DIR:-/var/lib/server-setup}"
SS_CONF_DIR="${SS_CONF_DIR:-/etc/server-setup}"
SS_LOG="${SS_LOG:-/var/log/server-setup.log}"
SS_DRY_RUN="${SS_DRY_RUN:-false}"
SS_ASSUME_YES="${SS_ASSUME_YES:-false}"

# Exit codes: 0 ok, 1 warnings, 2 failures, 3 the tool itself failed.
readonly EXIT_OK=0 EXIT_WARN=1 EXIT_FAIL=2 EXIT_ERROR=3

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"

# Decided once, before output may be mirrored into the log through a pipe.
SS_TTY=false
if [[ -t 0 && -t 1 ]]; then SS_TTY=true; fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_CYAN=$'\e[36m'; C_GREEN=$'\e[32m'; C_AMBER=$'\e[33m'; C_RED=$'\e[31m'
  C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'; C_INV=$'\e[7m'; C_0=$'\e[0m'
else
  C_CYAN=""; C_GREEN=""; C_AMBER=""; C_RED=""; C_DIM=""; C_BOLD=""; C_INV=""; C_0=""
fi

log()  { printf '%s[+]%s %s\n' "$C_GREEN" "$C_0" "$*"; }
info() { printf '%s[·]%s %s\n' "$C_CYAN" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_AMBER" "$C_0" "$*" >&2; }
step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_0"; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_0" "$*" >&2; exit "$EXIT_ERROR"; }

# Hooks run by the error trap, e.g. rolling back the module that failed.
SS_ON_ERROR=()
on_error_push() { SS_ON_ERROR+=("$1"); }
on_error_pop()  { (( ${#SS_ON_ERROR[@]} )) && unset 'SS_ON_ERROR[-1]'; return 0; }

_ss_err_trap() {
  local rc=$? line=$1 cmd=$2 h
  trap - ERR
  printf '%s[x]%s Failed at line %s: %s (exit %s)\n' "$C_RED" "$C_0" "$line" "$cmd" "$rc" >&2
  for (( h = ${#SS_ON_ERROR[@]} - 1; h >= 0; h-- )); do
    "${SS_ON_ERROR[$h]}" || true
  done
  exit "$EXIT_ERROR"
}

ss_init_traps() {
  set -Eeuo pipefail
  trap '_ss_err_trap "$LINENO" "$BASH_COMMAND"' ERR
}

require_root() { [[ $EUID -eq 0 ]] || die "Run as root, for example: sudo server-setup ${1:-}"; }

ss_prepare_dirs() {
  install -d -m 700 "$SS_STATE_DIR" "$SS_STATE_DIR/backups"
  install -d -m 700 "$SS_CONF_DIR" "$SS_CONF_DIR/keys"
  if [[ ! -e "$SS_LOG" ]]; then install -m 600 /dev/null "$SS_LOG"; fi
}

# One change at a time. ss_lock [WAIT_SECONDS]; released by ss_unlock or on exit.
ss_lock() {
  exec 9>"$SS_STATE_DIR/lock"
  flock -w "${1:-0}" 9 || die "Another server-setup run is in progress. Try again when it finishes."
}
ss_unlock() { flock -u 9 2>/dev/null || true; }

# Mirror stdout/stderr to the log without colour codes.
ss_log_to_file() {
  exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g' >>"$SS_LOG")) 2>&1
  printf '\n--- server-setup %s · run %s · %s ---\n' "$SS_VERSION" "$RUN_ID" "$*" >>"$SS_LOG"
}

# run_cmd CMD...: execute, or only describe it in dry-run mode.
run_cmd() {
  if [[ $SS_DRY_RUN == true ]]; then
    printf '%s  would run:%s %s\n' "$C_DIM" "$C_0" "$*"
    return 0
  fi
  "$@"
}

is_true() { [[ ${1,,} =~ ^(1|y|yes|true|on)$ ]]; }
