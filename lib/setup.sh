# shellcheck shell=bash
# setup.sh: "Set up server" / "Set up this computer".
#
#   1. Work out the machine type (detect, then confirm with the user).
#   2. If setup was already done, show the "already set up" pop-up with what
#      changed since then, and let the user choose what to do.
#   3. Wizard (or the saved/--config settings when unattended).
#   4. Validate everything, show the plan (a dry run with file diffs), confirm.
#   5. Apply; SSH restarts last, with an undo timer.

CONFIG_FILE() { printf '%s/config.env' "$SS_CONF_DIR"; }

# ----------------------------------------------------------- machine type
declare -gA MT_LABEL=([server]="Server" [personal]="Personal computer" [wsl]="WSL (Windows)")

resolve_machine_type() {
  local saved det type reasons
  saved=$(state_get machine_type)
  if [[ -n ${CFG[MACHINE_TYPE]} ]]; then type=${CFG[MACHINE_TYPE]}
  elif [[ -n $saved ]]; then type=$saved
  fi
  if [[ -z ${type:-} ]]; then
    det=$(detect_machine_type); type=${det%%$'\t'*}; reasons=${det#*$'\t'}
    if [[ $type == container ]]; then
      die "This is a container ($reasons). Setup is for full machines; the security check still works: server-setup check"
    fi
    if ui_interactive; then
      local guess=${type%\?} items=("Server|a VPS, cloud or rack server you reach over SSH" "Personal computer|a laptop or desktop you use yourself" "WSL|Ubuntu inside Windows")
      ui_clear
      printf '\n  %sWhat kind of machine is this?%s\n' "$C_BOLD" "$C_0"
      printf '  It looks like a %s%s%s because: %s.\n' "$C_CYAN" "${MT_LABEL[$guess],,}" "$C_0" "${reasons//;/, }"
      printf '  %sYour answer is saved, so you are asked only once.%s\n' "$C_DIM" "$C_0"
      # Put the guess first.
      case $guess in personal) items=("${items[1]}" "${items[0]}" "${items[2]}") ;; wsl) items=("${items[2]}" "${items[0]}" "${items[1]}") ;; esac
      ui_menu "Choose one" "${items[@]}"
      (( UI_CHOICE >= 0 )) || return 1
      case ${items[$UI_CHOICE]%%|*} in Server) type=server ;; "Personal computer") type=personal ;; WSL) type=wsl ;; esac
    elif [[ $type == *\? ]]; then
      warn "Could not tell whether this is a server or a personal computer ($reasons)."
      die "Run again with --type server or --type personal. Nothing was changed."
    else
      info "Detected a ${MT_LABEL[$type],,} ($reasons)."
    fi
  fi
  CFG[MACHINE_TYPE]=$type
  state_set machine_type "$(json_str "$type")"
}

# ----------------------------------------------------------------- import v2
# A server hardened by v2 has 00-hardening.conf but no state.json.
legacy_setup_present() { [[ -z $(state_get setup.done) && -e $SSHD_LEGACY_DROPIN ]]; }

import_legacy_setup() {
  local users port
  users=$(awk '$1=="AllowUsers" {$1=""; print}' "$SSHD_LEGACY_DROPIN" | xargs)
  port=$(awk '$1=="Port" {print $2; exit}' "$SSHD_LEGACY_DROPIN")
  CFG[ADMIN_USERS]=${CFG[ADMIN_USERS]:-$users}
  CFG[SSH_PORT]=${CFG[SSH_PORT]:-$port}
  state_set setup "{\"done\": true, \"imported\": true, \"version\": \"2.x\", \"date\": $(json_str "$(date -r "$SSHD_LEGACY_DROPIN" -Is)"), \"profile\": \"base\", \"admins\": $(json_list $users), \"ssh_port\": $(json_str "$port")}"
  history_add import ok "Imported a setup made by server-setup v2 (admins: ${users:-none}, SSH port ${port:-22})"
  log "Imported the earlier setup. Run the wizard to bring it up to the new version."
}

# ------------------------------------------------------------------- wizard
wizard_profile() {
  ui_menu "What will this server do?" \
    "Base|SSH, firewall, Fail2ban, automatic updates" \
    "Web server|base + open ports 80 and 443" \
    "Custom|choose every part yourself"
  case $UI_CHOICE in
    0) CFG[PROFILE]=base ;;
    1) CFG[PROFILE]=web; [[ ${CFG[OPEN_PORTS]} == *443* ]] || CFG[OPEN_PORTS]=$(xargs <<<"${CFG[OPEN_PORTS]} 80/tcp 443/tcp") ;;
    2) CFG[PROFILE]=custom ;;
    *) return 1 ;;
  esac
}

wizard_components() {
  local all names=() i c on items=() desc
  if [[ ${CFG[MACHINE_TYPE]} == server ]]; then all="ssh firewall fail2ban autoupdates timesync watch"
  else all="firewall autoupdates timesync watch ssh fail2ban"; fi
  declare -A desc=(
    [ssh]="SSH|keys only, no root login, limited to the ssh-users group"
    [firewall]="Firewall|block incoming connections except the ones you allow"
    [fail2ban]="Fail2ban|ban addresses that keep failing to log in"
    [autoupdates]="Automatic updates|install security updates every day"
    [timesync]="Clock sync|keep the clock correct (needed for logs and TLS)"
    [watch]="Security watch|alert on suspicious logins, new admins, key and config changes"
  )
  for c in $all; do
    on=off; cfg_has "$c" && on=on
    # On a personal computer SSH and Fail2ban only make sense if an SSH server is installed.
    if [[ ${CFG[MACHINE_TYPE]} != server && $c =~ ^(ssh|fail2ban)$ ]] && ! pkg_installed openssh-server; then continue; fi
    items+=("$on|${desc[$c]}"); names+=("$c")
  done
  ui_checklist "Which parts do you want?" "${items[@]}" || return 1
  CFG[COMPONENTS]=""
  for i in "${UI_CHECKED[@]}"; do CFG[COMPONENTS]+="${names[$i]} "; done
  CFG[COMPONENTS]=$(xargs <<<"${CFG[COMPONENTS]}")
}

wizard_key_for() {
  local u=$1 home k src ans
  home=$(user_home "$u" 2>/dev/null || true)
  if [[ -n $(user_keys_source "$u") || ( -n $home && -s $home/.ssh/authorized_keys ) ]]; then return 0; fi
  printf '\n  %s needs an SSH key to log in.\n' "$u"
  for src in "${SUDO_USER:+$(user_home "$SUDO_USER")/.ssh/authorized_keys}" /root/.ssh/authorized_keys; do
    [[ -n $src && -s $src ]] || continue
    if ui_confirm "Use the key(s) from $src?" y; then
      k=$(grep -E '^(ssh-|ecdsa-|sk-)' "$src" || true)
      [[ -n $k ]] && validate_pubkeys "$k" && { KEYS_NEW[$u]=$k; return 0; }
    fi
  done
  while true; do
    ui_input ans "Paste $u's PUBLIC key (from ~/.ssh/id_ed25519.pub on your computer), or a path to a .pub file"
    [[ -f $ans ]] && ans=$(<"$ans")
    if [[ -n $ans ]] && validate_pubkeys "$ans"; then KEYS_NEW[$u]=$ans; return 0; fi
    warn "A public key is required, otherwise $u could not log in."
  done
}

wizard_password_for() {
  local u=$1 pw
  if id "$u" &>/dev/null && has_usable_password "$u"; then return 0; fi
  printf '\n  %s needs a password for sudo (and for the provider console if SSH ever breaks).\n' "$u"
  ui_secret pw "Password for $u"
  if [[ -z $pw ]]; then
    if ui_confirm "No password: allow $u to use sudo WITHOUT a password? Not recommended."; then
      CFG[ALLOW_NOPASSWD_SUDO]=true; return 0
    fi
    wizard_password_for "$u"; return
  fi
  PW_HASH[$u]=$(openssl passwd -6 -stdin <<<"$pw")
}

wizard_users() {
  local def=${CFG[ADMIN_USERS]} ok u others=() items=() i
  [[ -z $def && -n ${SUDO_USER:-} && $SUDO_USER != root ]] && def=$SUDO_USER
  while true; do
    ui_input "CFG[ADMIN_USERS]" "Admin account(s), separated by spaces" "${def:-admin}"
    ok=true
    for u in ${CFG[ADMIN_USERS]}; do valid_username "$u" || { warn "Not a valid user name: $u"; ok=false; }; done
    [[ -n ${CFG[ADMIN_USERS]} && $ok == true ]] && break
  done
  for u in ${CFG[ADMIN_USERS]}; do wizard_key_for "$u"; wizard_password_for "$u"; done

  # Everyone else who logs in with a key today: keep or drop their SSH access.
  for u in $(accounts_with_keys); do
    [[ " ${CFG[ADMIN_USERS]} " == *" $u "* ]] && continue
    others+=("$u")
    if [[ -z ${CFG[SSH_USERS]} || " ${CFG[SSH_USERS]} " == *" $u "* ]]; then items+=("on|$u|logs in with an SSH key today")
    else items+=("off|$u|logs in with an SSH key today"); fi
  done
  if (( ${#others[@]} )); then
    ui_checklist "These accounts can log in over SSH today. Keep their access?" "${items[@]}" || return 1
    CFG[SSH_USERS]=""
    for i in "${UI_CHECKED[@]}"; do CFG[SSH_USERS]+="${others[$i]} "; done
    CFG[SSH_USERS]=$(xargs <<<"${CFG[SSH_USERS]}")
  fi
}

wizard_network() {
  local v cur ip
  if cfg_has ssh; then
    cur=$(ssh_current_ports | awk '{print $1}')
    while true; do
      ui_input v "SSH port (keep $cur unless you have a reason)" "${CFG[SSH_PORT]:-${cur:-22}}"
      valid_port "$v" && { CFG[SSH_PORT]=$v; break; }; warn "Use a number from 1 to 65535."
    done
    [[ ${CFG[SSH_PORT]} != "$cur" ]] && warn "Open TCP port ${CFG[SSH_PORT]} in your cloud provider's firewall too. SSH keeps port $cur open until you confirm."
  fi
  if cfg_has firewall; then
    while true; do
      ui_input v "Other ports to open, separated by spaces (e.g. 80/tcp 443/tcp)" "${CFG[OPEN_PORTS]}"
      local bad="" p; for p in $v; do valid_portspec "$p" || bad+=" $p"; done
      [[ -z $bad ]] && { CFG[OPEN_PORTS]=$v; break; }; warn "Not valid:$bad"
    done
  fi
  if cfg_has firewall || cfg_has fail2ban; then
    ip=${SSH_CONNECTION:-}; ip=${ip%% *}
    while true; do
      ui_input v "Trusted IPs/networks that are never rate-limited or banned${ip:+ (you are connecting from $ip)}" "${CFG[TRUSTED_CIDRS]}"
      local bad="" c; for c in $v; do valid_cidr "$c" || bad+=" $c"; done
      [[ -z $bad ]] && { CFG[TRUSTED_CIDRS]=$v; break; }; warn "Not valid:$bad"
    done
  fi
}

wizard_updates() {
  cfg_has autoupdates || return 0
  [[ ${CFG[MACHINE_TYPE]} == server ]] || return 0
  if ui_confirm "Reboot automatically when an update needs it?" "$( is_true "${CFG[AUTO_REBOOT]}" && echo y || echo n)"; then
    CFG[AUTO_REBOOT]=true
    local v; while true; do ui_input v "Reboot time (HH:MM, server time)" "${CFG[REBOOT_TIME]}"; valid_time "$v" && { CFG[REBOOT_TIME]=$v; break; }; done
  else
    CFG[AUTO_REBOOT]=false
  fi
}

# The wizard only collects answers; everything it collects is validated again
# (cfg_validate, users_preflight) before anything changes.
run_wizard() {   # run_wizard [components-only]
  ui_clear
  printf '\n  %s%s setup%s · %s · %s\n' "$C_CYAN$C_BOLD" "${MT_LABEL[${CFG[MACHINE_TYPE]}]}" "$C_0" "$(hostname)" "$OS_PRETTY"
  if [[ ${1:-} != components-only && ${CFG[MACHINE_TYPE]} == server ]]; then wizard_profile || return 1; fi
  wizard_components || return 1
  if [[ ${1:-} != components-only ]]; then
    if [[ ${CFG[MACHINE_TYPE]} == server ]]; then wizard_users || return 1; fi
    wizard_network
    wizard_updates
  fi
}

# ------------------------------------------------------------------- apply
needed_packages() {
  local p=()
  cfg_has ssh && p+=(openssh-server)
  cfg_has firewall && p+=(ufw)
  cfg_has fail2ban && p+=(fail2ban python3-systemd)
  cfg_has autoupdates && p+=(unattended-upgrades)
  printf '%s\n' "${p[@]}"
}

apply_all() {
  # Install everything first, so a download problem stops us before any config changes.
  mapfile -t _pk < <(needed_packages)
  (( ${#_pk[@]} )) && ensure_packages "${_pk[@]}"
  save_new_keys
  [[ ${CFG[MACHINE_TYPE]} == server ]] && apply_users
  cfg_has ssh && apply_ssh
  cfg_has firewall && apply_firewall
  cfg_has fail2ban && apply_fail2ban
  cfg_has autoupdates && apply_autoupdates
  cfg_has timesync && apply_timesync
  cfg_has watch && apply_watch
  [[ ${CFG[MACHINE_TYPE]} == server ]] && apply_root_lock
  cfg_has ssh && ssh_restart
  return 0
}

setup_failed_hook() {
  # SSH not restarted yet: put its files back so a later restart can't apply half a setup.
  [[ $SSH_CHANGED == true ]] && ssh_restore_files
  history_add setup failed "stopped with an error; see $SS_LOG" || true
}

show_plan_and_confirm() {
  ui_interactive && ui_clear
  step "Plan: what will change"
  printf '  Machine:     %s\n' "${MT_LABEL[${CFG[MACHINE_TYPE]}]}"
  printf '  Parts:       %s\n' "${CFG[COMPONENTS]:-none}"
  [[ ${CFG[MACHINE_TYPE]} == server ]] && printf '  Admins:      %s (sudo, SSH keys)\n' "${CFG[ADMIN_USERS]}"
  [[ -n ${CFG[SSH_USERS]} ]] && printf '  Also SSH:    %s\n' "${CFG[SSH_USERS]}"
  cfg_has ssh && printf '  SSH port:    %s\n' "${CFG[SSH_PORT]:-unchanged}"
  cfg_has firewall && printf '  Open ports:  SSH %s\n' "${CFG[OPEN_PORTS]}"
  [[ -n ${CFG[TRUSTED_CIDRS]} ]] && printf '  Trusted:     %s\n' "${CFG[TRUSTED_CIDRS]}"
  printf '\n  %sDetails (files that change are shown as diffs):%s\n' "$C_DIM" "$C_0"
  ( SS_DRY_RUN=true; apply_all ) || die "Could not build the plan."
  if cfg_has ssh; then
    printf '\n  %sAfter SSH restarts you have %s minutes to log in from a NEW terminal and run:%s\n' "$C_AMBER" "$CONFIRM_MINUTES" "$C_0"
    printf '      sudo server-setup confirm\n  %sIf you don'"'"'t, the SSH changes undo themselves.%s\n' "$C_AMBER" "$C_0"
  fi
  if ui_interactive; then ui_confirm "Apply this plan?" || { warn "Cancelled. Nothing was changed."; return 1; }; fi
}

do_apply() {
  local admins
  on_error_push setup_failed_hook
  apply_all
  on_error_pop
  cfg_save "$(CONFIG_FILE)"
  admins=$(json_list ${CFG[ADMIN_USERS]})
  state_set setup "{\"done\": true, \"date\": $(json_str "$(date -Is)"), \"version\": $(json_str "$SS_VERSION"), \"profile\": $(json_str "${CFG[PROFILE]}"), \"admins\": $admins, \"ssh_port\": $(json_str "$(state_get ssh.port)"), \"components\": $(json_list ${CFG[COMPONENTS]}), \"run_id\": $(json_str "$RUN_ID")}"
  history_add setup ok "${CFG[PROFILE]} · ${CFG[COMPONENTS]// /, }"
  setup_summary
}

setup_summary() {
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '\n%s%sSetup complete.%s\n' "$C_GREEN" "$C_BOLD" "$C_0"
  if cfg_has ssh && [[ -n $(state_get ssh.pending) ]]; then
    printf '\n%s%sKeep this session open.%s From a NEW terminal on your computer:\n\n' "$C_AMBER" "$C_BOLD" "$C_0"
    printf '    ssh -p %s %s@%s\n    sudo server-setup confirm\n\n' "$(state_get ssh.port)" "$(cfg_primary_admin)" "${ip:-<server-ip>}"
    printf 'Without that, the SSH changes undo themselves in %s minutes.\n' "$CONFIRM_MINUTES"
  fi
  printf 'History: sudo server-setup history   ·   Backups: %s\n' "$(run_backup_dir)"
}

# ------------------------------------------------------- already set up
setup_changes_lines() {
  local f when p comps=() c
  while IFS=$'\t' read -r f when; do
    [[ -z $f ]] && continue
    if [[ $when == missing ]]; then printf '%s! %s%s was deleted\n' "$C_AMBER" "$C_0" "$f"
    else printf '%s! %s%s was edited by hand (%s)\n' "$C_AMBER" "$C_0" "$f" "$when"; fi
  done < <(drift_files)
  if command -v ufw >/dev/null 2>&1; then
    for p in $(fw_unmanaged_ports); do printf '%s! %sPort %s was opened outside server-setup\n' "$C_AMBER" "$C_0" "$p"; done
  fi
  for c in ssh firewall fail2ban autoupdates timesync; do cfg_has "$c" || comps+=("$c"); done
  (( ${#comps[@]} )) && printf '%s· %sNot set up: %s\n' "$C_DIM" "$C_0" "${comps[*]}"
  return 0
}

already_set_up_popup() {
  local date ver prof admins port changes=() body=()
  date=$(state_get setup.date); ver=$(state_get setup.version); prof=$(state_get setup.profile)
  admins=$(state_get setup.admins | tr -d '[]"' | tr ',' ' ' | xargs); port=$(state_get ssh.port)
  mapfile -t changes < <(setup_changes_lines)
  body+=("Set up on $(date -d "$date" '+%-d %b %Y %H:%M' 2>/dev/null || echo "$date") with server-setup $ver · profile $prof${admins:+ · admin $admins}${port:+ · SSH port $port}")
  body+=("")
  body+=("${C_CYAN}What changed since then${C_0}")
  if (( ${#changes[@]} )); then body+=("${changes[@]}"); else body+=("${C_GREEN}✔${C_0} Everything still matches the saved setup"); fi
  ui_popup "$C_AMBER" "This $( [[ ${CFG[MACHINE_TYPE]} == server ]] && echo server || echo computer) is already set up" "${body[@]}" -- \
    "Change some settings|walk through the wizard with your current choices" \
    "Add components|turn on parts that are not set up yet" \
    "Review the changes|keep each change, or put back the saved setup" \
    "Show current setup|read-only summary" \
    "Set up again from scratch|asks you to type RESET first" \
    "Cancel|back to the dashboard"
  POPUP_CHOICE=$UI_CHOICE
}

review_changes() {
  local f when p any=false
  ui_clear; step "Review the changes"
  while IFS=$'\t' read -r f when; do
    [[ -z $f ]] && continue; any=true
    printf '\n  %s%s%s changed %s\n' "$C_BOLD" "$f" "$C_0" "$when"
    ui_menu "What should happen to it?" "Keep my change|server-setup will treat it as the new normal" "Put back the saved version|re-applied when you confirm the plan" "Decide later|leave it reported as a change"
    case $UI_CHOICE in 0) accept_drift "$f"; log "Kept." ;; 1) REAPPLY=true ;; esac
  done < <(drift_files)
  for p in $(fw_unmanaged_ports); do
    any=true
    printf '\n  %sPort %s%s is open but not part of the saved setup.\n' "$C_BOLD" "$p" "$C_0"
    ui_menu "What should happen to it?" "Keep it open|add it to the saved setup" "Close it|remove the firewall rule now" "Decide later|"
    case $UI_CHOICE in
      0) CFG[OPEN_PORTS]=$(xargs <<<"${CFG[OPEN_PORTS]} $p"); cfg_save "$(CONFIG_FILE)"; state_set firewall.ports "$(json_list ${CFG[OPEN_PORTS]})"; log "Kept $p." ;;
      1) ufw delete allow "$p" >/dev/null && log "Closed $p."; history_add firewall ok "closed $p (opened outside server-setup)" ;;
    esac
  done
  $any || log "Nothing has changed since setup."
}

show_current_setup() {
  ui_clear; step "Current setup"
  sed -n '/^[A-Z]/p' "$(CONFIG_FILE)" 2>/dev/null | sed 's/^/  /'
  if command -v ufw >/dev/null; then printf '\n'; ufw status verbose 2>/dev/null | sed 's/^/  /'; fi
  printf '\n  SSH group %s: %s\n' "$SSH_GROUP" "$(getent group "$SSH_GROUP" | cut -d: -f4)"
  ui_pause
}

# ------------------------------------------------------------------- entry
cmd_setup() {
  local typed
  REAPPLY=false
  cfg_reset
  cfg_load "$(CONFIG_FILE)"
  [[ -n ${SS_CONFIG_ARG:-} ]] && cfg_load "$SS_CONFIG_ARG"
  cfg_from_env
  [[ -n ${SS_TYPE_ARG:-} ]] && CFG[MACHINE_TYPE]=$SS_TYPE_ARG
  resolve_machine_type || return 0

  if legacy_setup_present; then
    if ! ui_interactive || ui_confirm "This machine was set up by an older server-setup (v2). Import that setup first?" y; then import_legacy_setup; fi
  fi

  if ui_interactive; then
    if [[ $(state_get setup.done) == true ]]; then
      already_set_up_popup
      case $POPUP_CHOICE in
        0) run_wizard || return 0 ;;
        1) run_wizard components-only || return 0 ;;
        2) review_changes; $REAPPLY || { ui_pause; return 0; } ;;
        3) show_current_setup; return 0 ;;
        4) ui_clear; ui_input typed "This rewrites every setting from scratch. Type RESET to continue"
           [[ $typed == RESET ]] || { warn "Cancelled."; return 0; }
           local mt=${CFG[MACHINE_TYPE]}; cfg_reset; CFG[MACHINE_TYPE]=$mt; run_wizard || return 0 ;;
        *) return 0 ;;
      esac
    else
      run_wizard || return 0
    fi
  elif [[ $(state_get setup.done) == true ]]; then
    local d; d=$(drift_files)
    if [[ -n $d ]]; then
      warn "These managed files were changed by hand since the last setup:"; printf '    %s\n' "${d//$'\t'/  }" >&2
      warn "Not overwriting them in an unattended run. Review them with: sudo server-setup setup"
      exit "$EXIT_WARN"
    fi
  fi

  cfg_validate || exit "$EXIT_FAIL"
  [[ ${CFG[MACHINE_TYPE]} == server ]] && { users_preflight || exit "$EXIT_FAIL"; }
  show_plan_and_confirm || return 0
  do_apply
}
