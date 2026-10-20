# shellcheck shell=bash
# alerts.sh: where security events and health problems are sent (ntfy,
# a webhook, Slack, Telegram, email). The watch service does the sending, so
# alerts go out even when nobody has the dashboard open.
#
# Settings live in /etc/server-setup/alerts.env (mode 600, parsed, never
# sourced). They are kept apart from config.env because they hold tokens.

ALERT_KEYS=(ALERT_NTFY_URL ALERT_NTFY_TOKEN ALERT_WEBHOOK_URL ALERT_SLACK_WEBHOOK
            ALERT_TELEGRAM_TOKEN ALERT_TELEGRAM_CHAT ALERT_EMAIL_TO ALERT_MIN_LEVEL ALERT_HEALTH)
ALERTS_FILE() { printf '%s/alerts.env' "$SS_CONF_DIR"; }

alerts_get() {   # alerts_get KEY → value ("" when unset)
  local line f; f=$(ALERTS_FILE)
  [[ -r $f ]] || return 0
  while IFS= read -r line; do
    if [[ $line =~ ^$1=\"?([^\"]*)\"?$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  done <"$f"
}

alerts_set() {   # alerts_set KEY VALUE (empty value removes it)
  local key=$1 val=$2 f tmp k v
  [[ " ${ALERT_KEYS[*]} " == *" $key "* ]] || die "Unknown alert setting $key"
  [[ $val != *[\"$'\n'\\]* ]] || { warn "That value contains characters that are not allowed."; return 1; }
  f=$(ALERTS_FILE)
  install -d -m 700 "$SS_CONF_DIR"
  tmp=$(mktemp "$f.XXXXXX"); chmod 600 "$tmp"
  {
    printf '# server-setup alert settings. Holds tokens: keep it root-only (mode 600).\n'
    for k in "${ALERT_KEYS[@]}"; do
      if [[ $k == "$key" ]]; then v=$val; else v=$(alerts_get "$k"); fi
      [[ -n $v ]] && printf '%s="%s"\n' "$k" "$v"
    done
  } >"$tmp"
  mv -f "$tmp" "$f"
}

valid_https_url() { [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]\"]*)?$ ]]; }
valid_email()     { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
valid_tg_chat()   { [[ $1 =~ ^-?[0-9]{1,20}$ || $1 =~ ^@[A-Za-z0-9_]{5,32}$ ]]; }

# Which channels are set up, one name per line.
alerts_channels() {
  [[ -n $(alerts_get ALERT_NTFY_URL) ]] && echo ntfy
  [[ -n $(alerts_get ALERT_WEBHOOK_URL) ]] && echo webhook
  [[ -n $(alerts_get ALERT_SLACK_WEBHOOK) ]] && echo slack
  [[ -n $(alerts_get ALERT_TELEGRAM_TOKEN) && -n $(alerts_get ALERT_TELEGRAM_CHAT) ]] && echo telegram
  [[ -n $(alerts_get ALERT_EMAIL_TO) ]] && echo email
  return 0
}

# event_raise SEV KIND MESSAGE [notify] [TITLE]: record an event from server-setup
# itself (maintenance results, reports). The watch picks it up, numbers it and
# sends it to the alert channels; "notify" sends it whatever its level.
event_raise() {
  [[ $SS_DRY_RUN == true ]] && return 0
  python3 -I -c 'import json,sys; print(json.dumps({"sev": sys.argv[1], "kind": sys.argv[2], "msg": sys.argv[3], "notify": sys.argv[4] == "notify", "title": sys.argv[5] or None}))' \
    "$1" "$2" "$3" "${4:-}" "${5:-}" >>"$SS_STATE_DIR/events-inbox.jsonl"
  chmod 600 "$SS_STATE_DIR/events-inbox.jsonl"
  # Without the service, deliver now (the service would do it within seconds).
  watch_running || _watch_py once >/dev/null 2>&1 || true
}

# server-setup alert-test: send a test message to every channel now.
cmd_alert_test() {
  local ch res ok=0 bad=0
  if [[ -z $(alerts_channels) ]]; then warn "No alert channels are set up. Open the dashboard and press 6."; CHECK_RC=1; return 0; fi
  while IFS=$'\t' read -r ch res; do
    if [[ $res == ok ]]; then log "$ch: sent"; ok=$((ok + 1))
    else warn "$ch: $res"; bad=$((bad + 1)); fi
  done < <(_watch_py alert-test)
  state_set last.alerts_test "{\"time\": $(json_str "$(date -Is)"), \"result\": $(json_str "$( ((bad)) && echo failed || echo ok)")}"
  CHECK_RC=$(( bad ? 2 : 0 ))
}

# ------------------------------------------------------------ screen (6)
alert_channel_label() {
  case $1 in
    ntfy) echo "ntfy (phone push)" ;; webhook) echo "Webhook (JSON POST)" ;; slack) echo "Slack" ;;
    telegram) echo "Telegram" ;; email) echo "Email" ;;
  esac
}

alert_channel_state() {   # alert_channel_state CH → coloured status for the menu
  local on=false t ok err
  [[ $'\n'$(alerts_channels)$'\n' == *$'\n'$1$'\n'* ]] && on=true
  $on || { printf '%snot set up%s' "$C_DIM" "$C_0"; return; }
  IFS=$'\t' read -r _ t ok err < <(_watch_py alert-status 2>/dev/null | awk -F'\t' -v c="$1" '$1 == c') || true
  case $ok in
    yes) printf '%s✔ on · last sent %s%s' "$C_GREEN" "$(human_time "$t")" "$C_0" ;;
    no)  printf '%s✘ failing: %s%s' "$C_RED" "${err:0:40}" "$C_0" ;;
    *)   printf '%s✔ on%s' "$C_GREEN" "$C_0" ;;
  esac
}

screen_alerts() {
  local chs=(ntfy telegram slack webhook email) items=() c lvl health
  lvl=$(alerts_get ALERT_MIN_LEVEL); lvl=${lvl:-important}
  health=$(alerts_get ALERT_HEALTH); health=${health:-true}
  for c in "${chs[@]}"; do items+=("$(alert_channel_label "$c")|$(alert_channel_state "$c")"); done
  items+=("Send for|$( [[ $lvl == critical ]] && echo "critical events only" || echo "important and critical events")")
  items+=("Machine health|$( [[ $health == true ]] && echo "on: full disks, low memory, failed services" || echo off)")
  items+=("Send a test alert|to every channel that is set up" "Back|")
  ui_clear; step "Alerts"
  printf '  %sSecurity events and health problems are sent here as they happen, by the watch service.%s\n' "$C_DIM" "$C_0"
  watch_installed || printf '  %sThe security watch is off (press w on the dashboard), so alerts go out only while the dashboard is open.%s\n' "$C_AMBER" "$C_0"
  UI_MENU_WIDTH=24 ui_menu "Pick a channel to set it up or change it" "${items[@]}"
  (( UI_CHOICE >= 0 )) || return 0
  if (( UI_CHOICE < ${#chs[@]} )); then alert_channel_setup "${chs[$UI_CHOICE]}"
  else
    case $(( UI_CHOICE - ${#chs[@]} )) in
      0) ui_clear; UI_POPUP_NOTE='' ui_popup "$C_CYAN" "Which events should be sent?" "Info events (normal logins) are never sent." -- \
           "Important and critical|recommended: new addresses, sudo misuse, config changes, full disks" "Critical only|root logins, logins after brute force, new UID 0 accounts"
         case $UI_CHOICE in 0) alerts_set ALERT_MIN_LEVEL important ;; 1) alerts_set ALERT_MIN_LEVEL critical ;; esac ;;
      1) alerts_set ALERT_HEALTH "$( [[ $health == true ]] && echo false || echo true)" ;;
      2) ui_clear; step "Sending a test alert"; cmd_alert_test; ui_pause ;;
      *) return 0 ;;
    esac
  fi
  alerts_restart_watch
  screen_alerts
}

# The service reads alerts.env when it starts.
alerts_restart_watch() { watch_running && systemctl restart "$WATCH_UNIT" 2>/dev/null || true; }

alert_channel_setup() {
  local ch=$1 v t on=false
  [[ $'\n'$(alerts_channels)$'\n' == *$'\n'$ch$'\n'* ]] && on=true
  if $on; then
    ui_clear
    UI_POPUP_NOTE='' ui_popup "$C_CYAN" "$(alert_channel_label "$ch")" "This channel is set up." -- "Change it|" "Remove it|stop sending here" "Back|"
    case $UI_CHOICE in
      0) ;;
      1) alert_channel_clear "$ch"; history_add alerts ok "removed the $ch alert channel"; return 0 ;;
      *) return 0 ;;
    esac
  fi
  ui_clear; step "$(alert_channel_label "$ch")"
  case $ch in
    ntfy)
      printf '  Install the ntfy app on your phone and subscribe to a topic with a long, hard-to-guess name.\n'
      printf '  %sExample: https://ntfy.sh/srv-7f3k9q2x (anyone who knows the topic can read it; use a token for a private server).%s\n' "$C_DIM" "$C_0"
      ui_input v "Topic URL"; valid_https_url "$v" || { warn "Use an https:// address."; ui_pause; return 0; }
      ui_secret t "Access token (blank if the topic needs none)"
      alerts_set ALERT_NTFY_URL "$v" && alerts_set ALERT_NTFY_TOKEN "$t" ;;
    telegram)
      printf '  Create a bot with @BotFather, send it a message, then find your chat id with @userinfobot.\n'
      ui_secret t "Bot token"; [[ $t =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] || { warn "That does not look like a bot token (123456:ABC...)."; ui_pause; return 0; }
      ui_input v "Chat id"; valid_tg_chat "$v" || { warn "A chat id is a number (or @channelname)."; ui_pause; return 0; }
      alerts_set ALERT_TELEGRAM_TOKEN "$t" && alerts_set ALERT_TELEGRAM_CHAT "$v" ;;
    slack)
      printf '  In Slack: Apps > Incoming Webhooks > Add to a channel, then copy the webhook URL.\n'
      ui_secret v "Webhook URL"; [[ $v == https://hooks.slack.com/* ]] && valid_https_url "$v" || { warn "Slack webhook URLs start with https://hooks.slack.com/"; ui_pause; return 0; }
      alerts_set ALERT_SLACK_WEBHOOK "$v" ;;
    webhook)
      printf '  Each event is sent as JSON: host, severity, title, text, kind, time, id.\n'
      ui_secret v "Webhook URL (it may contain a secret)"; valid_https_url "$v" || { warn "Use an https:// address."; ui_pause; return 0; }
      alerts_set ALERT_WEBHOOK_URL "$v" ;;
    email)
      if ! command -v msmtp >/dev/null; then
        warn "Email needs msmtp, set up with your mail provider in /etc/msmtprc (sudo apt install msmtp msmtp-mta)."
        printf '  %sThis is the one step done outside the dashboard: the mail login is yours to type into that file.%s\n' "$C_DIM" "$C_0"
        ui_pause; return 0
      fi
      ui_input v "Send to"; valid_email "$v" || { warn "Not an email address."; ui_pause; return 0; }
      alerts_set ALERT_EMAIL_TO "$v" ;;
  esac
  history_add alerts ok "set up the $ch alert channel"
  log "$(alert_channel_label "$ch") is set up."
  alerts_restart_watch
  ui_confirm "Send a test alert now?" y && { printf '\n'; cmd_alert_test; }
  ui_pause
}

alert_channel_clear() {
  case $1 in
    ntfy) alerts_set ALERT_NTFY_URL ""; alerts_set ALERT_NTFY_TOKEN "" ;;
    telegram) alerts_set ALERT_TELEGRAM_TOKEN ""; alerts_set ALERT_TELEGRAM_CHAT "" ;;
    slack) alerts_set ALERT_SLACK_WEBHOOK "" ;;
    webhook) alerts_set ALERT_WEBHOOK_URL "" ;;
    email) alerts_set ALERT_EMAIL_TO "" ;;
  esac
}
