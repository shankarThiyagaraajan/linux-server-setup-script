# Loads the libraries into the test shell without running main, with all
# state redirected to a temporary directory.
load_libs() {
  export T=$BATS_TEST_TMPDIR
  export SS_STATE_DIR=$T/state SS_CONF_DIR=$T/conf SS_LOG=$T/log NO_COLOR=1
  mkdir -p "$SS_STATE_DIR/backups" "$SS_CONF_DIR/keys"
  local f
  for f in core config state files os ui modules/users modules/ssh modules/system modules/release modules/watch modules/recommend checks setup dashboard; do
    # shellcheck source=/dev/null
    . "$BATS_TEST_DIRNAME/../lib/$f.sh"
  done
  RUN_ID=20261019-120000-1
}
