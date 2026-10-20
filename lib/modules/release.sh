# shellcheck shell=bash
# release.sh: "Upgrade Ubuntu", moving to the next Ubuntu release without
# leaving the dashboard.
#
#   1. Pre-flight checks and choices in a pop-up. Anything the dashboard can
#      fix itself (pending updates, the upgrade tool, the release channel)
#      is offered there as an option.
#   2. The upgrade runs in its own systemd unit, so a dropped SSH connection
#      or closing the dashboard does not stop it. Progress is shown live.
#   3. Before offering the restart, it checks that you can still get in:
#      sshd config, sudoers, firewall, Fail2ban. A broken SSH config is
#      re-rendered for the new OpenSSH and SSH restarted at once.
#   4. After the restart, a welcome pop-up runs the security check and
#      offers to turn third-party sources back on.

REL_UNIT=server-setup-release-upgrade
REL_LOG=${SS_REL_LOG:-/var/log/server-setup-release-upgrade.log}
REL_CFG=${SS_REL_CFG:-/etc/update-manager/release-upgrades}
REL_ROWS=(); REL_BLOCKERS=0; REL_NEXT=""
REL_FIX_UPDATES=false; REL_FIX_TOOL=false; REL_FIX_REBOOT=false

# ------------------------------------------------------------ facts
rel_channel() {   # lts | normal | never
  local c=""
  [[ -r $REL_CFG ]] && c=$(sed -n 's/^[[:space:]]*Prompt[[:space:]]*=[[:space:]]*//p' "$REL_CFG" | tail -1)
  printf '%s' "${c:-lts}"
}

rel_set_channel() {
  local want=$1
  [[ $want =~ ^(lts|normal|never)$ ]] || return 1
  if [[ -r $REL_CFG ]] && grep -q '^[[:space:]]*Prompt[[:space:]]*=' "$REL_CFG"; then
    sed "s/^[[:space:]]*Prompt[[:space:]]*=.*/Prompt=$want/" "$REL_CFG" | write_file "$REL_CFG" 644
  else
    { [[ -r $REL_CFG ]] && cat "$REL_CFG"; printf '[DEFAULT]\nPrompt=%s\n' "$want"; } | write_file "$REL_CFG" 644
  fi
  history_add release-channel ok "upgrade channel set to $want"
}

rel_channel_label() {
  case $1 in lts) echo "LTS releases only (every 2 years, 5+ years of support)" ;;
             normal) echo "Every release (every 6 months, 9 months of support)" ;;
             *) echo "Release upgrades turned off" ;; esac
}

# rel_next: the release do-release-upgrade would move to, e.g. "26.04.1 LTS".
# Needs the network (changelogs.ubuntu.com). Empty when there is none.
rel_next() {
  if [[ -n ${SS_PROBE_NEXT_RELEASE+x} ]]; then printf '%s' "$SS_PROBE_NEXT_RELEASE"; return; fi
  command -v do-release-upgrade >/dev/null || return 0
  timeout 60 do-release-upgrade -c 2>/dev/null | sed -n "s/^New release '\(.*\)' available.*/\1/p" | head -1 || true
}

# Third-party apt sources the upgrader turned off (it comments out .list
# lines with "disabled on upgrade to …" and sets Enabled: no in .sources).
rel_disabled_sources() {
  local d=${SS_APT_SOURCES_D:-/etc/apt/sources.list.d} f
  for f in "$d"/*.list; do [[ -f $f ]] && grep -q 'disabled on upgrade to' "$f" && printf '%s\n' "$f"; done
  for f in "$d"/*.sources; do
    [[ -f $f && $(basename "$f") != ubuntu.sources ]] && grep -qi '^Enabled:[[:space:]]*no' "$f" && printf '%s\n' "$f"
  done
  return 0
}

rel_third_party_count() {
  local d=${SS_APT_SOURCES_D:-/etc/apt/sources.list.d} n=0 f
  for f in "$d"/*.list "$d"/*.sources; do
    [[ -f $f && $(basename "$f") != ubuntu.sources ]] && n=$((n + 1))
  done
  printf '%d' "$n"
}

rel_enable_source() {
  local f=$1
  if [[ $f == *.list ]]; then
    sed -E 's/^#[[:space:]]*(deb.*)[[:space:]]+#[[:space:]]*disabled on upgrade to.*$/\1/' "$f" | write_file "$f" 644
  else
    sed -E 's/^(Enabled:)[[:space:]]*no[[:space:]]*$/\1 yes/I' "$f" | write_file "$f" 644
  fi
}

# ------------------------------------------------------------ pre-flight
rel_row() { REL_ROWS+=("$1	$2"); [[ $1 == FAIL ]] && REL_BLOCKERS=$((REL_BLOCKERS + 1)); return 0; }

# rel_preflight: fills REL_ROWS, REL_BLOCKERS, REL_NEXT and the REL_FIX_* flags.
rel_preflight() {
  REL_ROWS=(); REL_BLOCKERS=0; REL_FIX_UPDATES=false; REL_FIX_TOOL=false; REL_FIX_REBOOT=false
  local ch n free boot held tp ac

  ch=$(rel_channel)
  if ! command -v do-release-upgrade >/dev/null && [[ -z ${SS_PROBE_NEXT_RELEASE+x} ]]; then
    rel_row FAIL "The Ubuntu upgrade tool is not installed"; REL_FIX_TOOL=true; REL_NEXT=""
  elif [[ $ch == never ]]; then
    rel_row FAIL "Release upgrades are turned off for this machine"; REL_NEXT=""
  else
    REL_NEXT=$(rel_next)
    if [[ -n $REL_NEXT ]]; then rel_row PASS "Ubuntu $REL_NEXT is available"
    else rel_row FAIL "No newer release on your channel ($ch)"; fi
  fi

  n=${SS_PROBE_PENDING_UPDATES-$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)}
  if (( n > 0 )); then rel_row FAIL "$n update(s) must be installed first"; REL_FIX_UPDATES=true
  else rel_row PASS "All current updates are installed"; fi

  if [[ -f ${SS_REBOOT_FLAG:-/var/run/reboot-required} ]]; then rel_row FAIL "A restart is needed first, to finish earlier updates"; REL_FIX_REBOOT=true
  else rel_row PASS "No restart pending"; fi

  if [[ -n $(state_get ssh.pending.new_port) ]]; then
    rel_row FAIL "An SSH change is waiting for you to confirm (see This machine)"
  fi

  free=${SS_PROBE_FREE_GB-$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc 0-9)}
  if (( ${free:-0} < 3 )); then rel_row FAIL "Only ${free:-0} GB free on /; the upgrade needs about 5 GB"
  elif (( free < 5 )); then rel_row WARN "${free} GB free on /; about 5 GB is recommended"
  else rel_row PASS "${free} GB free on /"; fi
  if mountpoint -q /boot 2>/dev/null; then
    boot=$(df -BM --output=avail /boot | tail -1 | tr -dc 0-9)
    (( boot < 250 )) && rel_row WARN "Only ${boot} MB free on /boot; old kernels may need removing"
  fi

  if [[ $(state_get machine_type) == personal ]]; then
    ac=${SS_PROBE_AC-$(cat /sys/class/power_supply/A{C,DP}*/online 2>/dev/null | head -1)}
    [[ $ac == 0 ]] && rel_row FAIL "Running on battery; plug in the charger"
  fi

  held=$(apt-mark showhold 2>/dev/null | xargs)
  [[ -n $held ]] && rel_row WARN "Held packages will not be upgraded: $held"

  tp=$(rel_third_party_count)
  (( tp > 0 )) && rel_row INFO "$tp third-party source(s) will be paused during the upgrade; you can turn them back on after"
  rel_row INFO "Runs in the background: a dropped connection will not stop it"
  rel_row INFO "Take a backup or snapshot first; this cannot be undone"
  return 0
}

rel_rows_formatted() {
  local r st msg
  for r in "${REL_ROWS[@]}"; do
    st=${r%%$'\t'*}; msg=${r#*$'\t'}
    case $st in
      PASS) printf '%s✔%s %s\n' "$C_GREEN" "$C_0" "$msg" ;;
      WARN) printf '%s!%s %s\n' "$C_AMBER" "$C_0" "$msg" ;;
      FAIL) printf '%s✘%s %s\n' "$C_RED" "$C_0" "$msg" ;;
      *)    printf '%s·%s %s%s%s\n' "$C_CYAN" "$C_0" "$C_DIM" "$msg" "$C_0" ;;
    esac
  done
}

# ------------------------------------------------------------ running
rel_running() { systemctl is-active --quiet "$REL_UNIT" 2>/dev/null; }

rel_start() {
  local to=$1
  [[ $SS_DRY_RUN == true ]] && { info "would start the upgrade to Ubuntu $to"; return 0; }
  install -m 600 /dev/null "$REL_LOG"
  state_set release_upgrade "{\"status\": \"running\", \"from\": $(json_str "$OS_VERSION"), \"to\": $(json_str "$to"), \"started\": $(date +%s), \"run_id\": $(json_str "$RUN_ID")}"
  history_add release-upgrade started "upgrade from $OS_VERSION to $to started"
  systemctl reset-failed "$REL_UNIT" 2>/dev/null || true
  systemd-run --quiet --unit "$REL_UNIT" --collect \
    --description "server-setup: upgrade Ubuntu to $to" \
    -p StandardOutput="append:$REL_LOG" -p StandardError="append:$REL_LOG" \
    --setenv=DEBIAN_FRONTEND=noninteractive --setenv=NEEDRESTART_MODE=a \
    "$(ss_self)" __release-run
}

# __release-run: the body of the systemd unit. Takes the lock for the whole
# upgrade so nothing else changes the system meanwhile.
cmd_release_run() {
  local rc=0 to status
  ss_lock 600
  to=$(state_get release_upgrade.to)
  printf '==> server-setup: upgrading Ubuntu %s to %s (%s)\n' "$OS_VERSION" "$to" "$(date -Is)"
  ${SS_RELEASE_CMD:-do-release-upgrade -f DistUpgradeViewNonInteractive} </dev/null || rc=$?
  printf '==> do-release-upgrade finished with exit code %s\n' "$rc"
  if (( rc != 0 )); then
    state_set release_upgrade.status '"failed"'
    state_set release_upgrade.finished "$(date +%s)"
    history_add release-upgrade failed "upgrade to $to stopped with exit code $rc"
    return 0
  fi
  rel_post_checks
  status=ready; (( REL_POST_FAIL > 0 )) && status=attention
  state_set release_upgrade.status "$(json_str "$status")"
  state_set release_upgrade.finished "$(date +%s)"
  history_add release-upgrade "$( [[ $status == ready ]] && echo ok || echo attention)" \
    "Ubuntu $to installed; restart needed$( [[ $status == attention ]] && echo " · $REL_POST_FAIL check(s) need attention")"
}

# rel_post_checks: can we still get in after the restart? Fixes what it
# safely can (the SSH drop-in), and records the rest.
rel_post_checks() {
  local rows=() fixed=""
  REL_POST_FAIL=0
  printf '==> Checking that you can still log in after the restart\n'
  if command -v sshd >/dev/null; then
    mkdir -p /run/sshd
    if sshd -t 2>/dev/null; then rows+=("PASS	SSH configuration is valid for the new OpenSSH")
    elif [[ -f $SSHD_DROPIN ]] && rel_rerender_ssh; then
      ssh_service_restart || true
      rows+=("PASS	SSH configuration was updated for the new OpenSSH"); fixed=" (fixed)"
    elif [[ -f $SSHD_DROPIN ]]; then
      rows+=("FAIL	SSH configuration does not load: sshd -t"); REL_POST_FAIL=$((REL_POST_FAIL + 1))
    else
      rows+=("FAIL	SSH configuration does not load: sshd -t"); REL_POST_FAIL=$((REL_POST_FAIL + 1))
    fi
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
      rows+=("PASS	SSH is running")
    else
      systemctl restart ssh 2>/dev/null || true
      if systemctl is-active --quiet ssh 2>/dev/null; then rows+=("PASS	SSH was restarted")
      else rows+=("FAIL	SSH is not running"); REL_POST_FAIL=$((REL_POST_FAIL + 1)); fi
    fi
  fi
  if command -v visudo >/dev/null; then
    if visudo -c >/dev/null 2>&1; then rows+=("PASS	sudo rules are valid")
    else rows+=("FAIL	sudo rules do not load: visudo -c"); REL_POST_FAIL=$((REL_POST_FAIL + 1)); fi
  fi
  if command -v ufw >/dev/null && [[ $(state_get setup.done) == true ]]; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then rows+=("PASS	Firewall is on and allows SSH on port $(state_get ssh.port)")
    else rows+=("WARN	Firewall is off after the upgrade"); fi
  fi
  if command -v fail2ban-client >/dev/null && [[ -f /etc/fail2ban/jail.d/server-setup.local ]]; then
    if fail2ban-client -t >/dev/null 2>&1; then rows+=("PASS	Fail2ban configuration is valid")
    else rows+=("WARN	Fail2ban configuration does not load: fail2ban-client -t"); fi
  fi
  printf '    %s\n' "${rows[@]//$'\t'/  }"
  state_set release_upgrade.post "$(json_list "${rows[@]}")"
  [[ -n $fixed ]] && history_add release-upgrade ok "SSH settings updated for the new OpenSSH"
  return 0
}

# rel_rerender_ssh: write the drop-in again with the algorithms the new
# OpenSSH supports. Ports and login methods come from the current drop-in,
# never from sshd -T (which is what just failed), so nothing else changes.
rel_rerender_ssh() {
  local ports methods
  printf '==> sshd -t failed; re-writing the server-setup SSH settings for the new OpenSSH\n'
  ports=$(awk '$1=="Port" {print $2}' "$SSHD_DROPIN" | xargs)
  methods=$(awk '$1=="AuthenticationMethods" {print $2}' "$SSHD_DROPIN")
  [[ -n $ports ]] || return 1
  cfg_reset; cfg_load "$(CONFIG_FILE)"
  # shellcheck disable=SC2086
  SS_SSH_METHODS=$methods ssh_render $ports | write_file "$SSHD_DROPIN" 644
  if sshd -t; then return 0; fi
  rollback_run "$RUN_ID" "$SSHD_DROPIN" || true
  return 1
}

# Progress: the phase the upgrade is in, from its log.
REL_PHASES=("Preparing" "Downloading" "Installing" "Cleaning up" "Checking access" "Done")
rel_phase() {
  local f=${1:-$REL_LOG} p=0
  [[ -s $f ]] || { echo 0; return; }
  if grep -q '^==> do-release-upgrade finished' "$f"; then p=4
    grep -q 'Checking that you can still log in' "$f" && p=4
    grep -qE '^    (PASS|WARN|FAIL)' "$f" && p=5
  elif grep -qiE 'Searching for obsolete software|Remove obsolete packages|Removing obsolete' "$f"; then p=3
  elif grep -qE '^(Unpacking|Setting up|Preparing to unpack) ' "$f"; then p=2
  elif grep -qE '^(Get:|Fetched |Fetching)' "$f"; then p=1
  fi
  echo "$p"
}

# ------------------------------------------------------------ screens
# screen_upgrade: the "Upgrade Ubuntu" menu item.
screen_upgrade() {
  local st
  st=$(state_get release_upgrade.status)
  if rel_running || [[ $st == running ]]; then rel_watch; return; fi
  if [[ $st =~ ^(ready|attention|failed)$ ]]; then rel_result_popup; return; fi

  while true; do
    ui_clear; printf '\n  %sChecking for a newer Ubuntu release…%s\n' "$C_DIM" "$C_0"
    rel_preflight
    local body=() items=() acts=() ch
    ch=$(rel_channel)
    body+=("This machine runs ${C_BOLD}${OS_PRETTY}${C_0}.")
    body+=("${C_DIM}Upgrade channel: $(rel_channel_label "$ch")${C_0}")
    body+=("")
    mapfile -t -O "${#body[@]}" body < <(rel_rows_formatted)
    if (( REL_BLOCKERS == 0 )) && [[ -n $REL_NEXT ]]; then
      items+=("Upgrade to Ubuntu $REL_NEXT|starts after one more confirmation"); acts+=(start)
    fi
    $REL_FIX_TOOL    && { items+=("Install the upgrade tool|ubuntu-release-upgrader-core"); acts+=(tool); }
    $REL_FIX_UPDATES && { items+=("Install updates now|then check again"); acts+=(updates); }
    $REL_FIX_REBOOT  && { items+=("Restart now|you will need to log in again afterwards"); acts+=(reboot); }
    items+=("Change upgrade channel|now: $(rel_channel_label "$ch" | cut -d' ' -f1-3)"); acts+=(channel)
    items+=("Check again|"); acts+=(again)
    items+=("Back to the dashboard|"); acts+=(back)
    ui_clear
    ui_popup "$( (( REL_BLOCKERS )) && echo "$C_AMBER" || echo "$C_CYAN")" "Upgrade Ubuntu" "${body[@]}" -- "${items[@]}"
    (( UI_CHOICE >= 0 )) || return 0
    case ${acts[$UI_CHOICE]} in
      start)   rel_confirm_start "$REL_NEXT" && { rel_watch; return; } ;;
      tool)    dash_lock || continue; ui_clear; ensure_packages ubuntu-release-upgrader-core; ss_unlock; ui_pause ;;
      updates) dash_lock || continue; ui_clear; task_updates; ss_unlock; ui_pause ;;
      reboot)  rel_reboot_popup "A restart is needed before upgrading." ;;
      channel) rel_channel_popup ;;
      again)   ;;
      back)    return 0 ;;
    esac
  done
}

rel_confirm_start() {
  local to=$1
  ui_clear
  ui_popup "$C_AMBER" "Start the upgrade to Ubuntu $to?" \
    "This usually takes 20 to 60 minutes. Services restart during it." \
    "It keeps your current versions of config files you changed." \
    "Third-party sources are paused; you can turn them back on afterwards." \
    "" \
    "It runs in the background. You can leave this screen or lose the" \
    "connection; open Upgrade Ubuntu again to see where it is." \
    "" \
    "${C_BOLD}There is no undo.${C_0} Have a backup or snapshot before you start." \
    -- "Not now|back" "I have a backup, start now|upgrade to $to"
  (( UI_CHOICE == 1 )) || return 1      # "Not now" comes first, so a stray enter never starts it
  dash_lock || return 1
  rel_start "$to"; ss_unlock
}

# ui_key with a timeout; prints nothing when no key was pressed.
rel_key() { local k; IFS= read -rsn1 -t "$1" k </dev/tty || return 0; [[ -z $k ]] && echo enter || printf '%s\n' "$k"; }

rel_watch() {
  local key phase start lines cols w i tail_n now el to l
  to=$(state_get release_upgrade.to); start=$(state_get release_upgrade.started)
  ui_hide_cursor
  while true; do
    if ! rel_running && [[ $(state_get release_upgrade.status) != running ]]; then rel_result_popup; return; fi
    if ! rel_running && [[ $(state_get release_upgrade.status) == running ]]; then
      sleep 2
      if ! rel_running && [[ $(state_get release_upgrade.status) == running ]]; then
        state_set release_upgrade.status '"failed"'
        history_add release-upgrade failed "the upgrade stopped unexpectedly"
        rel_result_popup; return
      fi
    fi
    lines=$(ui_lines); cols=$(ui_cols); w=$(( cols - 1 ))
    phase=$(rel_phase); now=$(date +%s); el=$(( now - ${start:-now} ))
    local steps=""
    for i in "${!REL_PHASES[@]}"; do
      if (( i < phase )); then steps+="${C_GREEN}✔ ${REL_PHASES[$i]}${C_0}   "
      elif (( i == phase )); then steps+="${C_CYAN}${C_BOLD}● ${REL_PHASES[$i]}${C_0}   "
      else steps+="${C_DIM}○ ${REL_PHASES[$i]}${C_0}   "; fi
    done
    tail_n=$(( lines - 10 )); (( tail_n < 3 )) && tail_n=3
    local rows=("$(lr "Upgrading to Ubuntu $to" "$(printf '%dm %02ds' $((el / 60)) $((el % 60)))")" "$steps" "$(rep ─ $((w - 4)))")
    while IFS= read -r l; do rows+=("${C_DIM}$l${C_0}"); done < <(tail -n "$tail_n" "$REL_LOG" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
    ui_clear
    panel "Upgrade Ubuntu" "$w" "${rows[@]}"
    printf ' %sb back to the dashboard (the upgrade keeps running)%s\n' "$C_DIM" "$C_0"
    key=$(rel_key 2)
    case $key in b|B|q|$'\e') ui_show_cursor; return 0 ;; esac
  done
}

rel_result_popup() {
  local st to body=() items=() acts=() r post
  st=$(state_get release_upgrade.status); to=$(state_get release_upgrade.to)
  post=$(state_get release_upgrade.post)
  if [[ -n $post ]]; then
    while IFS= read -r r; do
      case ${r%%$'\t'*} in PASS) body+=("${C_GREEN}✔${C_0} ${r#*$'\t'}") ;; WARN) body+=("${C_AMBER}!${C_0} ${r#*$'\t'}") ;; *) body+=("${C_RED}✘${C_0} ${r#*$'\t'}") ;; esac
    done < <(python3 -I -c 'import json,sys; [print(x) for x in json.loads(sys.argv[1])]' "$post")
  fi
  case $st in
    ready)
      ui_clear
      UI_POPUP_NOTE='' ui_popup "$C_GREEN" "Ubuntu $to is installed" "Restart to start using it. Checked before the restart:" "${body[@]}" \
        -- "Restart now|you will need to log in again afterwards" "Restart later|the dashboard reminds you" "Show the upgrade log|"
      acts=(reboot later log) ;;
    attention)
      ui_clear
      UI_POPUP_NOTE='' ui_popup "$C_RED" "Ubuntu $to is installed, but check this before restarting" \
        "Restarting now could leave you unable to log in:" "${body[@]}" \
        -- "Check again|after you have fixed it" "Show the upgrade log|" "Restart anyway|not recommended" "Back|"
      acts=(recheck log reboot-anyway later) ;;
    failed)
      body=("The upgrade stopped before it finished. The last lines of its log:" "")
      while IFS= read -r r; do body+=("${C_DIM}$r${C_0}"); done < <(tail -n 8 "$REL_LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
      body+=("" "The full log is $REL_LOG (also under /var/log/dist-upgrade/).")
      ui_clear
      UI_POPUP_NOTE='' ui_popup "$C_RED" "The upgrade to Ubuntu $to did not finish" "${body[@]}" \
        -- "Show the upgrade log|" "Try again|runs the checks first" "Back|"
      acts=(log retry later) ;;
    *) return 0 ;;
  esac
  (( UI_CHOICE >= 0 )) || return 0
  case ${acts[$UI_CHOICE]} in
    reboot)  rel_reboot_popup "" now ;;
    reboot-anyway) rel_reboot_popup "Some checks failed. You may not be able to log in after the restart." ;;
    log)     rel_show_log; rel_result_popup ;;
    recheck) dash_lock || return 0
             ui_clear; rel_post_checks; local s=ready; (( REL_POST_FAIL > 0 )) && s=attention
             state_set release_upgrade.status "$(json_str "$s")"; ss_unlock; rel_result_popup ;;
    retry)   state_del release_upgrade; screen_upgrade ;;
  esac
}

# The log inside the dashboard: ↑/↓ and PgUp/PgDn scroll, b goes back.
rel_show_log() {
  local -a L; local top=0 h key i
  mapfile -t L < <(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$REL_LOG" 2>/dev/null | tr -d '\r')
  h=$(( $(ui_lines) - 3 ))
  (( ${#L[@]} > h )) && top=$(( ${#L[@]} - h ))
  while true; do
    ui_clear
    printf ' %s%s · lines %d-%d of %d%s\n' "$C_BOLD" "$REL_LOG" $((top + 1)) $((top + h < ${#L[@]} ? top + h : ${#L[@]})) "${#L[@]}" "$C_0"
    for (( i = top; i < top + h && i < ${#L[@]}; i++ )); do printf ' %s\n' "$(ui_pad "${L[$i]}" $(( $(ui_cols) - 2 )))"; done
    printf ' %s↑/↓ scroll · space page down · g top · G end · b back%s' "$C_DIM" "$C_0"
    key=$(ui_key)
    case $key in
      up) (( top > 0 )) && top=$((top - 1)) ;;
      down) (( top + h < ${#L[@]} )) && top=$((top + 1)) ;;
      space) top=$((top + h)); (( top + h > ${#L[@]} )) && top=$(( ${#L[@]} > h ? ${#L[@]} - h : 0 )) ;;
      g) top=0 ;;
      G) top=$(( ${#L[@]} > h ? ${#L[@]} - h : 0 )) ;;
      b|q|esc) return 0 ;;
    esac
  done
}

rel_channel_popup() {
  local cur; cur=$(rel_channel)
  ui_clear
  ui_popup "$C_CYAN" "Which Ubuntu releases should this machine move to?" \
    "Now: $(rel_channel_label "$cur")." "" \
    "Servers usually stay on LTS: fewer big changes, longer support." \
    -- "LTS releases only|recommended" "Every release|newest features, upgrade every 6 months" "Never|turn release upgrades off" "Back|"
  local want
  case $UI_CHOICE in 0) want=lts ;; 1) want=normal ;; 2) want=never ;; *) return 0 ;; esac
  [[ $want == "$cur" ]] && return 0
  dash_lock || return 0
  rel_set_channel "$want"; ss_unlock
}

rel_reboot_popup() {
  local why=$1 skip_ask=${2:-}
  if [[ -z $skip_ask ]]; then
    ui_clear
    UI_POPUP_NOTE='' ui_popup "$C_AMBER" "Restart this machine?" "$why" \
      "$( [[ -n ${SSH_CONNECTION:-} ]] && echo "Your SSH connection will close. Log in again in a minute or two and open server-setup." || echo "Save your work in other apps first.")" \
      -- "Restart now|" "Not now|"
    (( UI_CHOICE == 0 )) || return 0
  fi
  history_add reboot ok "restarted from the dashboard"
  ui_clear; printf '\n  Restarting… Open server-setup again after you log back in.\n\n'
  systemctl reboot
  exit 0
}

# After the restart: shown once when the dashboard opens on the new release.
rel_welcome_popup() {
  local st to
  st=$(state_get release_upgrade.status); to=$(state_get release_upgrade.to)
  [[ $st =~ ^(ready|attention)$ ]] || return 0
  [[ -n $OS_VERSION && ${to%% *} == "$OS_VERSION"* ]] || return 0
  [[ -f ${SS_REBOOT_FLAG:-/var/run/reboot-required} ]] && return 0
  local -a srcs; mapfile -t srcs < <(rel_disabled_sources)
  local items=("Run the security check|recommended after an upgrade")
  (( ${#srcs[@]} )) && items+=("Turn third-party sources back on|${#srcs[@]} paused by the upgrade")
  items+=("Later|")
  state_set release_upgrade.status '"done"'
  history_add release-upgrade ok "now running $OS_PRETTY"
  while true; do
    ui_clear
    UI_POPUP_NOTE='' ui_popup "$C_GREEN" "Welcome to $OS_PRETTY" "The upgrade is complete and this machine restarted on the new release." \
      "$( (( ${#srcs[@]} )) && echo "${#srcs[@]} third-party source(s) are still paused." || echo "No third-party sources were paused.")" \
      -- "${items[@]}"
    case "${items[$UI_CHOICE]:-Later|}" in
      "Run the security check"*) ui_clear; cmd_check; ui_pause ;;
      "Turn third-party"*) rel_sources_screen; mapfile -t srcs < <(rel_disabled_sources)
                           (( ${#srcs[@]} )) || items=("Run the security check|recommended after an upgrade" "Later|") ;;
      *) return 0 ;;
    esac
  done
}

rel_sources_screen() {
  local -a srcs items=(); local f i
  mapfile -t srcs < <(rel_disabled_sources)
  (( ${#srcs[@]} )) || return 0
  for f in "${srcs[@]}"; do items+=("off|$(basename "$f")|$(grep -m1 -oE 'https?://[^ ]+' "$f" || true)"); done
  ui_clear; step "Third-party sources paused by the upgrade"
  printf '  %sOnly turn on sources that have packages for the new release.%s\n' "$C_DIM" "$C_0"
  ui_checklist "Tick the sources to turn back on" "${items[@]}" || return 0
  (( ${#UI_CHECKED[@]} )) || return 0
  dash_lock || return 0
  for i in "${UI_CHECKED[@]}"; do rel_enable_source "${srcs[$i]}"; log "Turned on $(basename "${srcs[$i]}")"; done
  if apt-get update -q >/dev/null 2>"$SS_STATE_DIR/apt-update.err"; then log "Package lists updated."
  else warn "apt update reported problems; the source may not support this release yet:"; sed 's/^/    /' "$SS_STATE_DIR/apt-update.err" | tail -5; fi
  history_add sources ok "turned ${#UI_CHECKED[@]} third-party source(s) back on"
  ss_unlock
  ui_pause
}

# ------------------------------------------------------------ command line
# server-setup release-upgrade [--check]: the same steps without the dashboard.
cmd_release_upgrade() {
  local check_only=${1:-false}
  step "Upgrade Ubuntu"
  rel_preflight
  rel_rows_formatted | sed 's/^/  /'
  if [[ $check_only == true ]]; then
    (( REL_BLOCKERS > 0 )) && CHECK_RC=$EXIT_FAIL || CHECK_RC=$EXIT_OK
    return 0
  fi
  (( REL_BLOCKERS == 0 )) || { warn "Fix the items marked ✘ first (or use the dashboard, which can fix most of them)."; CHECK_RC=$EXIT_FAIL; return 0; }
  if ! $SS_ASSUME_YES; then
    ui_confirm "Upgrade to Ubuntu $REL_NEXT now? There is no undo; have a backup." || { CHECK_RC=$EXIT_OK; return 0; }
  fi
  rel_start "$REL_NEXT"
  log "The upgrade is running in the background (unit $REL_UNIT). Follow it in the dashboard: sudo server-setup"
  CHECK_RC=$EXIT_OK
}
