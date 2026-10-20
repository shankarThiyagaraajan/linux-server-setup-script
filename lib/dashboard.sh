# shellcheck shell=bash
# dashboard.sh: the "Control Room" screen and the screens it opens.

# ------------------------------------------------------------------ helpers
bar() {   # bar PERCENT WIDTH → coloured █/░ bar
  local pct=${1%.*} w=$2 full col
  [[ $pct =~ ^[0-9]+$ ]] || pct=0
  (( pct > 100 )) && pct=100
  full=$(( (pct * w + 50) / 100 ))
  col=$C_GREEN; (( pct >= 75 )) && col=$C_AMBER; (( pct >= 90 )) && col=$C_RED
  printf '%s%s%s%s%s' "$col" "$(rep █ "$full")" "$C_DIM" "$(rep ░ $((w - full)))" "$C_0"
}
ok_mark()  { printf '%s✔%s' "$C_GREEN" "$C_0"; }
bad_mark() { printf '%s✘%s' "$C_RED" "$C_0"; }
warn_mark(){ printf '%s!%s' "$C_AMBER" "$C_0"; }
lr() { printf '%s\x1f%s' "$1" "$2"; }   # a left/right row for a panel

cpu_pct() {
  local a b
  read -r _ a1 a2 a3 a4 a5 a6 a7 _ </proc/stat; a=$((a1 + a2 + a3 + a4 + a5 + a6 + a7)); local ia=$a4
  sleep 0.2
  read -r _ b1 b2 b3 b4 b5 b6 b7 _ </proc/stat; b=$((b1 + b2 + b3 + b4 + b5 + b6 + b7))
  (( b > a )) && echo $(( 100 - (b4 - ia) * 100 / (b - a) )) || echo 0
}

# panel TITLE WIDTH ROW... → prints boxed lines (one per output line).
# A row containing \x1f is split into a left part and a right-aligned part.
panel() {
  local title=$1 w=$2 r l rt inner; shift 2
  inner=$((w - 4))
  printf '%s┌┤ %s%s%s ├%s┐%s\n' "$C_DIM" "$C_CYAN$C_BOLD" "$title" "$C_0$C_DIM" "$(rep ─ $((w - 6 - ${#title})))" "$C_0"
  for r in "$@"; do
    if [[ $r == *$'\x1f'* ]]; then
      l=${r%%$'\x1f'*}; rt=${r#*$'\x1f'}
      r="$(ui_pad "$l" $((inner - $(ui_len "$rt"))))$rt"
    fi
    printf '%s│%s %s %s│%s\n' "$C_DIM" "$C_0" "$(ui_pad "$r" "$inner")" "$C_DIM" "$C_0"
  done
  printf '%s└%s┘%s\n' "$C_DIM" "$(rep ─ $((w - 2)))" "$C_0"
}

# side_by_side WIDTH "panel output"... : join panels column-wise.
side_by_side() {
  local w=$1; shift
  local -a cols=() ; local i max=0 n row line
  for i in "$@"; do cols+=("$i"); n=$(wc -l <<<"$i"); (( n > max )) && max=$n; done
  for (( row = 1; row <= max; row++ )); do
    line=""
    for i in "${cols[@]}"; do
      local cell; cell=$(sed -n "${row}p" <<<"$i")
      line+="$(ui_pad "$cell" "$w") "
    done
    printf '%s\n' "${line% }"
  done
}

# ------------------------------------------------------------------ data
dash_collect() {
  D_TYPE=$(state_get machine_type); D_TYPE=${D_TYPE:-server}
  D_EFF=$(command -v sshd >/dev/null && sshd_effective || true)
  D_UFW=$(command -v ufw >/dev/null && ufw status 2>/dev/null || true)
  D_SEC_UPD=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep '^Inst ' | grep -ci security || true)
  D_ALL_UPD=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)
}

dash_header() {
  local score badge up
  score=$(state_get last_check.score)
  up=$(uptime -p 2>/dev/null | sed 's/^up //; s/ hours\?/h/; s/ minutes\?/m/; s/ days\?/d/; s/,//g')
  if [[ $D_TYPE == server ]]; then badge="SERVER"; else badge="PERSONAL · $(hostnamectl chassis 2>/dev/null || echo computer)"; fi
  local left
  left="${C_CYAN}${C_BOLD}server-setup ${SS_VERSION%%-*}${C_0}  ${C_INV} ${badge^^} ${C_0}  $(hostname)  ${C_DIM}${OS_PRETTY} · up ${up:-?} · $(date '+%Y-%m-%d %H:%M %Z')${C_0}"
  local right
  if [[ -n $score ]]; then right="${C_DIM}SECURITY${C_0} ${C_BOLD}${score}/100${C_0} $(bar "$score" 10)"
  else right="${C_DIM}SECURITY${C_0} not checked yet (press 2)"; fi
  panel "Control Room" "$1" "$(lr "$left" "$right")"
}

panel_system() {
  local mem_t mem_u swap_t swap_u disk cpu load cores
  read -r mem_t mem_u < <(free -m | awk '/^Mem:/ {print $2, $3}')
  read -r swap_t swap_u < <(free -m | awk '/^Swap:/ {print $2, $3}')
  disk=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
  cpu=$(cpu_pct); load=$(cut -d' ' -f1-3 /proc/loadavg); cores=$(nproc)
  panel "System" "$1" \
    "$(lr "CPU  $(bar "$cpu" 12)" "$cpu%")" \
    "$(lr "RAM  $(bar $(( mem_u * 100 / (mem_t > 0 ? mem_t : 1) )) 12)" "$(awk -v u="$mem_u" -v t="$mem_t" 'BEGIN{printf "%.1f/%.1fG", u/1024, t/1024}')")" \
    "$(lr "Disk $(bar "$disk" 12)" "$disk%")" \
    "$(lr "Swap $(bar $(( swap_t > 0 ? swap_u * 100 / swap_t : 0 )) 12)" "$( (( swap_t > 0 )) && awk -v u="$swap_u" -v t="$swap_t" 'BEGIN{printf "%.1f/%.1fG", u/1024, t/1024}' || echo none)")" \
    "$(lr "${C_DIM}load $load${C_0}" "${C_DIM}$cores CPU${C_0}")"
}

panel_security() {
  local rows=() rules banned n
  if [[ -n $D_EFF ]]; then
    if [[ $(sshd_value passwordauthentication "$D_EFF") == no && $(sshd_value permitrootlogin "$D_EFF") == no ]]; then
      rows+=("$(ok_mark) SSH key-only · root login off")
    else rows+=("$(bad_mark) SSH allows passwords or root"); fi
  elif [[ $D_TYPE != server ]]; then rows+=("$(ok_mark) No SSH server (nothing to attack)"); fi
  if grep -q '^Status: active' <<<"$D_UFW"; then
    rules=$(awk 'NR>4 && NF' <<<"$D_UFW" | grep -vc '(v6)' || true)
    rows+=("$(ok_mark) Firewall on · $rules rule(s)")
  else rows+=("$(bad_mark) Firewall off"); fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    banned=$(fail2ban-client status sshd 2>/dev/null | awk '/Currently banned/ {print $NF}')
    rows+=("$(ok_mark) Fail2ban · ${banned:-0} IP(s) banned")
  elif [[ $D_TYPE == server ]]; then rows+=("$(warn_mark) Fail2ban not running"); fi
  if apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then rows+=("$(ok_mark) Automatic security updates on")
  else rows+=("$(bad_mark) Automatic updates off"); fi
  if (( D_SEC_UPD > 0 )); then rows+=("$(warn_mark) $D_SEC_UPD security update(s) waiting")
  elif (( D_ALL_UPD > 0 )); then rows+=("$(ok_mark) No security updates · $D_ALL_UPD other")
  else rows+=("$(ok_mark) Up to date"); fi
  n=$(rec_open_ids | grep -c . || true)
  (( n > 0 )) && rows+=("${C_CYAN}●${C_0} $n recommendation(s) · press 9")
  panel "Security" "$1" "${rows[@]}"
}

last_line() {   # last_line TASK LABEL
  local t r s
  t=$(state_get "last.$1.time"); r=$(state_get "last.$1.result"); s=$(state_get "last.$1.summary")
  if [[ -z $t ]]; then lr "$2" "${C_DIM}never${C_0}"; return; fi
  local m; case $r in ok) m=$(ok_mark) ;; failed) m=$(bad_mark) ;; *) m=$(warn_mark) ;; esac
  [[ $1 == check ]] && s="score $(state_get last_check.score)" || s=""
  lr "$2" "$(human_time "$t")${s:+ · $s} $m"
}

panel_lastruns() {
  local drift pending rows=()
  if [[ $(state_get setup.done) == true ]]; then rows+=("$(lr "$( [[ $D_TYPE == server ]] && echo "Server set up" || echo "Computer set up")" "$(human_time "$(state_get setup.date)") · $(state_get setup.profile) $(ok_mark)")")
  else rows+=("$(lr "Set up" "${C_AMBER}not yet (press 1)${C_0}")"); fi
  rows+=("$(last_line check "Security check")" "$(last_line updates "Updates")")
  pending=$(state_get ssh.pending.new_port)
  if [[ -n $pending ]]; then rows+=("$(lr "SSH change" "${C_AMBER}confirm from a new login${C_0}")")
  else
    drift=$(drift_files | grep -c . || true)
    if (( drift > 0 )); then rows+=("$(lr "Settings drift" "${C_AMBER}$drift change(s)${C_0}")")
    else rows+=("$(lr "Settings drift" "${C_GREEN}none${C_0}")"); fi
  fi
  panel "Last runs" "$1" "${rows[@]}"
}

panel_ports() {
  local rows=("$(lr "${C_DIM}PORT       PROCESS" "FIREWALL${C_0}")") line port proto proc fw n=0
  while read -r proto port proc; do
    [[ -z $port ]] && continue
    fw="${C_RED}blocked${C_0}"
    if ! grep -q '^Status: active' <<<"$D_UFW"; then fw="${C_AMBER}open (fw off)${C_0}"
    elif grep -qE "^${port}(/${proto})?[[:space:]]+LIMIT" <<<"$D_UFW"; then fw="${C_GREEN}limit${C_0}"
    elif grep -qE "^${port}(/${proto})?[[:space:]]+ALLOW" <<<"$D_UFW"; then fw="${C_GREEN}allow${C_0}"; fi
    rows+=("$(lr "$(ui_pad "$port/$proto" 10) $proc" "$fw")"); n=$((n + 1))
    (( n >= 5 )) && break
  done < <(command -v ss >/dev/null && ss -H -tulpn 2>/dev/null | awk '{
      split($5, a, ":"); port = a[length(a)]; host = substr($5, 1, length($5) - length(port) - 1)
      if (host ~ /^127\./ || host == "[::1]" || host ~ /%lo$/ || host == "127.0.0.53%lo") next
      p = $7; sub(/^users:\(\("/, "", p); sub(/".*/, "", p)
      print $1, port, (p == "" ? "-" : p) }' | sort -u -k2,2n || true)
  (( n == 0 )) && rows+=("${C_DIM}nothing listening on public addresses${C_0}")
  panel "Open ports" "$1" "${rows[@]}"
}

panel_events() {
  local rows=() t task by res sum m
  while IFS=$'\t' read -r t task by res sum _; do
    [[ -z $t ]] && continue
    case $res in ok) m=$(ok_mark) ;; failed) m=$(bad_mark) ;; *) m=$(warn_mark) ;; esac
    rows+=("${C_DIM}$(ui_pad "$(human_time "$t" | sed 's/^today //')" 9)${C_0} $m $task · $sum")
  done < <(history_tail 5)
  (( ${#rows[@]} )) || rows=("${C_DIM}no runs recorded yet${C_0}")
  panel "Recent activity" "$1" "${rows[@]}"
}

panel_machine() {
  local rows=() admins port pend left
  admins=$(state_get setup.admins | tr -d '[]"' | tr ',' ' ' | xargs)
  port=$(sshd_value port "$D_EFF")
  rows+=("$(lr "Type" "$( [[ $D_TYPE == server ]] && echo Server || echo "Personal computer")")")
  [[ -n $admins ]] && rows+=("$(lr "Admins" "$admins")")
  [[ -n $port ]] && rows+=("$(lr "SSH port" "$port")")
  pend=$(state_get ssh.pending.applied)
  if [[ -n $pend ]]; then
    left=$(( pend + CONFIRM_MINUTES * 60 - $(date +%s) ))
    (( left > 0 )) && rows+=("$(lr "${C_AMBER}Undo timer${C_0}" "${C_AMBER}$((left / 60))m $((left % 60))s left${C_0}")")
  fi
  case $(state_get release_upgrade.status) in
    running)   rows+=("$(lr "${C_CYAN}Upgrade${C_0}" "${C_CYAN}running · press 8${C_0}")") ;;
    ready)     rows+=("$(lr "${C_GREEN}Upgrade${C_0}" "${C_GREEN}restart to finish · 8${C_0}")") ;;
    attention|failed) rows+=("$(lr "${C_RED}Upgrade${C_0}" "${C_RED}needs attention · 8${C_0}")") ;;
  esac
  rows+=("$(lr "Reboot needed" "$( [[ -f /var/run/reboot-required ]] && echo "${C_AMBER}yes${C_0}" || echo "${C_GREEN}no${C_0}")")")
  panel "This machine" "$1" "${rows[@]}"
}

# ------------------------------------------------------------------ menu
menu_items() {
  if [[ $D_TYPE == server ]]; then
    MENU_KEYS=(1 2 3 4 5 6 7 8 9 h q)
    MENU_LABELS=("Set up server" "Security check" "Install updates" "Users & SSH keys" "Firewall & ports" "Alerts" "Schedule" "Upgrade Ubuntu" "Recommendations" "History" "Quit")
  else
    MENU_KEYS=(1 2 3 4 5 6 7 8 9 h q)
    MENU_LABELS=("Set up this computer" "Security check" "Install updates" "Apps & dev tools" "Firewall & ports" "Privacy" "Backups" "Upgrade Ubuntu" "Recommendations" "History" "Quit")
  fi
}
# Screens that arrive in later updates are shown dimmed.
menu_ready() {
  case "$D_TYPE:$1" in
    *:1|*:2|*:3|*:5|*:8|*:9|*:h|*:q|server:4) return 0 ;;
    *) return 1 ;;
  esac
}

dash_keybar() {
  local i out="" k
  menu_items
  for i in "${!MENU_KEYS[@]}"; do
    k=${MENU_KEYS[$i]}
    if menu_ready "$k"; then out+="${C_INV}${C_CYAN} $k ${C_0} ${MENU_LABELS[$i]}   "
    else out+="${C_DIM}[$k] ${MENU_LABELS[$i]}${C_0}   "; fi
  done
  printf ' %s\n' "$out"
}

dash_draw() {
  local cols w3 w2
  cols=$(ui_cols)
  dash_collect
  ui_clear
  if (( cols >= 96 )); then
    w3=$(( (cols - 2) / 3 ))
    dash_header "$(( w3 * 3 + 2 ))"
    side_by_side "$w3" "$(panel_system "$w3")" "$(panel_security "$w3")" "$(panel_lastruns "$w3")"
    side_by_side "$w3" "$(panel_ports "$w3")" "$(panel_events "$w3")" "$(panel_machine "$w3")"
    panel_watch "$(( w3 * 3 + 2 ))"
  else
    w2=$(( cols - 1 ))
    dash_header "$w2"
    panel_watch "$w2"; panel_security "$w2"; panel_lastruns "$w2"; panel_system "$w2"
  fi
  dash_keybar
  printf ' %se security events · r refresh (it also refreshes itself) · keys work without enter%s\n' "$C_DIM" "$C_0"
}

# ------------------------------------------------------------------ screens
screen_users() {
  local u rows ak n pw items=() users=()
  ui_clear; step "Users & SSH keys"
  printf '  %s%-16s %-8s %-9s %s%s\n' "$C_DIM" "ACCOUNT" "SUDO" "PASSWORD" "SSH KEYS" "$C_0"
  for u in $( { getent group "$SSH_GROUP" | cut -d: -f4 | tr ',' '\n'; getent group sudo | cut -d: -f4 | tr ',' '\n'; accounts_with_keys; } | sort -u); do
    [[ -z $u ]] && continue
    ak="$(user_home "$u")/.ssh/authorized_keys"; n=0; [[ -s $ak ]] && n=$(grep -cE '^[^#]' "$ak" || true)
    has_usable_password "$u" && pw=yes || pw=no
    printf '  %-16s %-8s %-9s %s%s\n' "$u" "$(id -nG "$u" | grep -qw sudo && echo yes || echo no)" "$pw" "$n" "$(id -nG "$u" | grep -qw "$SSH_GROUP" || echo "  ${C_DIM}(no SSH access)${C_0}")"
    users+=("$u")
  done
  ui_menu "What would you like to do?" "Add an SSH key|to one of the accounts above" "Remove SSH access|take an account out of $SSH_GROUP" "Add an admin|opens the setup wizard" "Back|"
  case $UI_CHOICE in
    0) local who key; ui_input who "Account"; id "$who" &>/dev/null || { warn "No such account."; ui_pause; return; }
       ui_input key "Paste the PUBLIC key"
       validate_pubkeys "$key" || { ui_pause; return; }
       ak="$(user_home "$who")/.ssh/authorized_keys"
       install -d -m 700 -o "$who" -g "$who" "$(dirname "$ak")"; touch "$ak"; backup_file "$ak"
       grep -qxF -- "$key" "$ak" || printf '%s\n' "$key" >>"$ak"; chmod 600 "$ak"; chown "$who:$who" "$ak"
       history_add users ok "added an SSH key for $who"; log "Key added for $who." ;;
    1) local who admins; ui_input who "Account"
       admins=" $(state_get setup.admins | tr -d '[]",') "
       if [[ $admins == *" $who "* ]] && ! ui_confirm "$who is an admin. Removing SSH access can lock you out. Continue?"; then return 0; fi
       if gpasswd -d "$who" "$SSH_GROUP" >/dev/null; then
         history_add users ok "removed SSH access for $who"; log "$who can no longer log in over SSH."
       fi ;;
    2) cmd_setup ;;
  esac
  ui_pause
}

screen_firewall() {
  local p
  ui_clear; step "Firewall & ports"
  if ! command -v ufw >/dev/null; then warn "The firewall is not installed. Use Set up (1) to add it."; ui_pause; return; fi
  ufw status numbered 2>/dev/null | sed 's/^/  /'
  ui_menu "What would you like to do?" "Open a port|for example 8080/tcp" "Close a port|remove an allow rule" "Back|"
  case $UI_CHOICE in
    0) ui_input p "Port to open (80/tcp, 6000:6007/udp)"
       valid_portspec "$p" || { warn "Not a valid port."; ui_pause; return; }
       backup_file /etc/ufw/user.rules
       ufw allow "$p" comment 'server-setup' >/dev/null
       cfg_reset; cfg_load "$(CONFIG_FILE)"; CFG[OPEN_PORTS]=$(xargs <<<"${CFG[OPEN_PORTS]} $p"); cfg_save "$(CONFIG_FILE)"
       state_set firewall.ports "$(json_list ${CFG[OPEN_PORTS]})"
       history_add firewall ok "opened $p"; log "Opened $p." ;;
    1) ui_input p "Port to close (as shown above, e.g. 8080/tcp)"
       valid_portspec "$p" || { warn "Not a valid port."; ui_pause; return; }
       if [[ $p == "$(state_get ssh.port)"* ]]; then warn "That is the SSH port. Change SSH from Set up instead."; ui_pause; return; fi
       ufw delete allow "$p" >/dev/null || warn "No allow rule for $p."
       cfg_reset; cfg_load "$(CONFIG_FILE)"; CFG[OPEN_PORTS]=$(tr ' ' '\n' <<<"${CFG[OPEN_PORTS]}" | grep -vxF "$p" | xargs || true); cfg_save "$(CONFIG_FILE)"
       state_set firewall.ports "$(json_list ${CFG[OPEN_PORTS]})"
       history_add firewall ok "closed $p"; log "Closed $p." ;;
  esac
  ui_pause
}

screen_history() {
  local t task by res sum col runs=() i
  ui_clear; step "History"
  printf '  %s%-16s %-18s %-9s %-10s %s%s\n' "$C_DIM" "WHEN" "TASK" "BY" "RESULT" "DETAILS" "$C_0"
  while IFS=$'\t' read -r t task by res sum _; do
    [[ -z $t ]] && continue
    case $res in ok) col=$C_GREEN ;; failed) col=$C_RED ;; *) col=$C_AMBER ;; esac
    printf '  %-16s %-18s %-9s %s%-10s%s %s\n' "$(date -d "$t" '+%-d %b %H:%M' 2>/dev/null || echo "$t")" "$task" "$by" "$col" "$res" "$C_0" "$sum"
  done < <(history_tail 25)
  mapfile -t runs < <(list_runs_with_backups | head -8)
  if (( ${#runs[@]} == 0 )); then ui_pause; return; fi
  local items=(); for i in "${runs[@]}"; do items+=("Undo run $i|restore the files it changed"); done
  items+=("Back|")
  ui_menu "Undo a run?" "${items[@]}"
  (( UI_CHOICE >= 0 && UI_CHOICE < ${#runs[@]} )) || return 0
  i=${runs[$UI_CHOICE]}
  printf '\n'; sed 's/^/  /' "$SS_STATE_DIR/backups/$i/manifest"
  ui_confirm "Restore these files to how they were before run $i?" || return 0
  rollback_run "$i"
  if grep -q '/etc/ssh/' "$SS_STATE_DIR/backups/$i/manifest"; then sshd -t && ssh_service_restart; fi
  if grep -q '/etc/fail2ban/' "$SS_STATE_DIR/backups/$i/manifest"; then systemctl restart fail2ban || true; fi
  history_add rollback ok "undid run $i"
  ui_pause
}

# dash_lock: like ss_lock, but when another task holds the lock it says so in a
# pop-up and returns 1, so the dashboard stays open.
dash_lock() {
  exec 9>"$SS_STATE_DIR/lock"
  flock -n 9 && return 0
  local what="Another server-setup task"
  rel_running && what="The Ubuntu upgrade"
  systemctl is-active --quiet "$CONFIRM_UNIT" 2>/dev/null && what="The SSH undo timer"
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$C_AMBER" "Busy" "$what is changing this machine right now." \
    "Try again when it finishes. Everything else on the dashboard still works." -- "OK|"
  return 1
}

dashboard() {
  local key
  trap 'ui_show_cursor' EXIT
  rel_welcome_popup
  while true; do
    watch_scan
    # New events that need attention pop up as they arrive.
    if (( $(_watch_py summary 2>/dev/null | awk -F'\t' '$1=="unreviewed" {print $4}') > $(state_get events_popup_upto || echo 0) + 0 )); then
      events_attention_popup
    fi
    dash_draw
    key=$(ui_key_wait 30)
    # The lock is held only while something changes, so the SSH undo timer
    # (which also takes it) is never blocked by an open dashboard.
    case $key in
      1) dash_lock || continue; cmd_setup; ss_unlock; ui_pause ;;
      2) ui_clear; cmd_check; ui_pause ;;
      3) dash_lock || continue; ui_clear; task_updates; ss_unlock; ui_pause ;;
      4) if [[ $D_TYPE == server ]]; then dash_lock || continue; screen_users; ss_unlock; else coming_soon "Apps & dev tools"; fi ;;
      5) dash_lock || continue; screen_firewall; ss_unlock ;;
      6|7) menu_items; coming_soon "${MENU_LABELS[$((key - 1))]}" ;;
      8) screen_upgrade ;;
      9) screen_recommendations ;;
      e|E) screen_events ;;
      w|W) if ! watch_installed; then watch_turn_on; fi ;;
      h|H) dash_lock || continue; screen_history; ss_unlock ;;
      q|Q|esc) ui_clear; exit 0 ;;
    esac
  done
}

coming_soon() { ui_clear; printf '\n  %s%s%s arrives in the next update of server-setup.\n' "$C_BOLD" "$1" "$C_0"; ui_pause; }
