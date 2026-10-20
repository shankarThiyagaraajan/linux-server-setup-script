#!/usr/bin/env bats
load helper

setup() {
  load_libs
  export SS_WATCH_FILES="$T/files/*" SS_PROBE_PORTS=$T/ports SS_JOURNAL_CMD="cat $T/journal" SS_HEALTH_PROBE=$T/health
  export SS_ALERT_ALLOW_HTTP=1 SS_TELEGRAM_API
  mkdir -p "$T/files" "$T/sink"; : >"$T/ports"; : >"$T/journal"
  echo '{"cursor": "c0", "hashes": {}, "ports": {}}' >"$SS_STATE_DIR/watch.json"
  python3 "$BATS_TEST_DIRNAME/fixtures/http_sink.py" "$T/sink" 3>&- &
  SINK_PID=$!
  for _ in $(seq 50); do [[ -f $T/sink/port ]] && break; sleep 0.1; done
  URL="http://127.0.0.1:$(cat "$T/sink/port")"
  SS_TELEGRAM_API=$URL
}
teardown() { kill "$SINK_PID" 2>/dev/null || true; }

j() {
  local ts=$(( $(date +%s) * 1000000 ))
  python3 -c 'import json,sys; print(json.dumps({"SYSLOG_IDENTIFIER": sys.argv[1], "MESSAGE": sys.argv[2], "__REALTIME_TIMESTAMP": sys.argv[3], "__CURSOR": "c" + sys.argv[3]}))' "$1" "$2" "$ts" >>"$T/journal"
}
sent() { cat "$T/sink/requests" 2>/dev/null || true; }
nsent() { sent | grep -c . || true; }

@test "alert settings are kept root-only and edited key by key" {
  alerts_set ALERT_NTFY_URL "https://ntfy.sh/topic-x"
  alerts_set ALERT_NTFY_TOKEN "tk_secret"
  alerts_set ALERT_MIN_LEVEL critical
  [ "$(stat -c %a "$SS_CONF_DIR/alerts.env")" = 600 ]
  [ "$(alerts_get ALERT_NTFY_URL)" = "https://ntfy.sh/topic-x" ]
  [ "$(alerts_get ALERT_NTFY_TOKEN)" = tk_secret ]
  alerts_set ALERT_NTFY_TOKEN ""
  ! grep -q TOKEN "$SS_CONF_DIR/alerts.env"
  [ "$(alerts_get ALERT_MIN_LEVEL)" = critical ]
  [[ $(alerts_channels) == ntfy ]]
  run alerts_set ALERT_WEBHOOK_URL 'https://x/"; rm -rf /'
  [ "$status" -ne 0 ]
  run alerts_set NOT_A_KEY x
  [ "$status" -ne 0 ]
  valid_https_url "https://hooks.example.com/a/b?c=d"
  ! valid_https_url "http://example.com/x"
  valid_tg_chat -100123456 && valid_tg_chat @mychannel && ! valid_tg_chat 'abc'
}

@test "important events go to every channel; info events do not" {
  alerts_set ALERT_NTFY_URL "$URL/topic"; alerts_set ALERT_NTFY_TOKEN tk1
  alerts_set ALERT_WEBHOOK_URL "$URL/hook"
  alerts_set ALERT_TELEGRAM_TOKEN "123:abcdefghijklmnopqrstuvwxyz"; alerts_set ALERT_TELEGRAM_CHAT 42
  j sshd "Accepted publickey for root from 203.0.113.9 port 1 ssh2"
  j sudo "  ops : TTY=pts/0 ; PWD=/ ; USER=root ; COMMAND=/bin/ls"
  _watch_py once
  [ "$(nsent)" -eq 3 ]
  sent | python3 -c '
import json, sys
r = {x["path"].split("/")[1]: x for x in map(json.loads, sys.stdin)}
assert r["topic"]["auth"] == "Bearer tk1" and "root logged in" in r["topic"]["body"], r
assert r["topic"]["title"].endswith(": critical")
h = json.loads(r["hook"]["body"]); assert h["severity"] == "critical" and h["kind"] == "root-login", h
t = json.loads(r["bot123:abcdefghijklmnopqrstuvwxyz"]["body"]); assert t["chat_id"] == "42", t'
  [ "$(_watch_py alert-status | awk -F'\t' '$1=="ntfy" {print $3}')" = yes ]
}

@test "critical-only sends nothing for important events" {
  alerts_set ALERT_WEBHOOK_URL "$URL/hook"; alerts_set ALERT_MIN_LEVEL critical
  j sudo "  dev : user NOT in sudoers ; TTY=pts/0 ; PWD=/ ; USER=root ; COMMAND=/bin/sh"
  _watch_py once
  [ "$(nsent)" -eq 0 ]
}

@test "a burst of events becomes one message" {
  alerts_set ALERT_WEBHOOK_URL "$URL/hook"
  for u in a1 a2 a3 a4 a5 a6 a7; do j sudo "  $u : user NOT in sudoers ; TTY=pts/0 ; PWD=/ ; USER=root ; COMMAND=/bin/sh"; done
  _watch_py once
  [ "$(nsent)" -eq 1 ]
  [[ $(sent) == *"7 events"* && $(sent) == *"a7 tried to use sudo"* ]]
}

@test "a failed send is retried later, not lost" {
  alerts_set ALERT_WEBHOOK_URL "$URL/hook"
  touch "$T/sink/fail"
  j sshd "Accepted publickey for root from 203.0.113.9 port 1 ssh2"
  _watch_py once
  [ "$(nsent)" -eq 0 ]
  [ "$(_watch_py alert-status | awk -F'\t' '$1=="pending" {print $2}')" = 1 ]
  [[ $(_watch_py alert-status | awk -F'\t' '$1=="webhook" {print $3 " " $4}') == "no HTTP Error 500"* ]]
  rm "$T/sink/fail"
  python3 - "$SS_STATE_DIR/watch.json" <<'PY'   # pretend the back-off has passed
import json, sys
w = json.load(open(sys.argv[1])); w["outbox"][0]["next"] = 0; json.dump(w, open(sys.argv[1], "w"))
PY
  : >"$T/journal"
  _watch_py once
  [ "$(nsent)" -eq 1 ]
  [ "$(_watch_py alert-status | awk -F'\t' '$1=="pending" {print $2}')" = 0 ]
}

@test "only https addresses are used outside tests" {
  alerts_set ALERT_WEBHOOK_URL "$URL/hook"
  SS_ALERT_ALLOW_HTTP=0 run _watch_py alert-test
  [[ $output == $'webhook\tonly https:// addresses are allowed' ]]
  run _watch_py alert-test
  [[ $output == $'webhook\tok' ]]
  [[ $(sent) == *"test alert"* ]]
}

@test "events from server-setup itself are numbered, kept important under the lock, and notify sends info" {
  alerts_set ALERT_WEBHOOK_URL "$URL/hook"
  exec 8>"$SS_STATE_DIR/lock"; flock 8               # server-setup is busy (as during maintenance)
  event_raise important score-drop "Security score went from 90 to 70"
  event_raise info weekly-report "Updates: 3" notify "weekly report"
  exec 8>&-
  [ ! -s "$SS_STATE_DIR/events-inbox.jsonl" ]
  _watch_py list 10 | awk -F'\x1f' '{print $3 "|" $4 "|" $8}' >"$T/ev"
  grep -qx 'important|score-drop|Security score went from 90 to 70' "$T/ev"
  grep -qx 'info|weekly-report|Updates: 3' "$T/ev"
  [ "$(nsent)" -eq 2 ]
  [[ $(sent) == *'weekly report'* ]]
}

@test "health problems are raised once and cleared when they recover" {
  echo '{"disk": {"/": 95, "/boot": 40}, "inodes": {"/": 10}, "mem_avail": 30, "failed": ["nginx.service"]}' >"$T/health"
  _watch_py once; _watch_py once
  _watch_py list 10 | awk -F'\x1f' '{print $3 "|" $8}' >"$T/ev"
  [ "$(grep -c . "$T/ev")" -eq 2 ]
  grep -qx 'important|Disk / is 95% full' "$T/ev"
  grep -qx 'important|Service nginx.service has failed' "$T/ev"
  echo '{"disk": {"/": 60}, "failed": []}' >"$T/health"
  _watch_py once
  _watch_py list 10 | awk -F'\x1f' '{print $3 "|" $8}' | grep -qx 'info|Back to normal: Disk / is 95% full'
  echo '{"disk": {"/": 98}}' >"$T/health"
  alerts_set ALERT_HEALTH false
  _watch_py once
  ! _watch_py list 10 | grep -q '98%'
}

@test "alert-test reports each channel" {
  alerts_set ALERT_WEBHOOK_URL "$URL/hook"
  alerts_set ALERT_SLACK_WEBHOOK "http://127.0.0.1:9/nothing-listens"
  run cmd_alert_test
  [[ $output == *"webhook: sent"* ]]
  [[ $output == *"slack:"* && $output != *"slack: sent"* ]]
  [ "$(state_get last.alerts_test.result)" = failed ]
}
