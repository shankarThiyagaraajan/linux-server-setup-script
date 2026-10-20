# shellcheck shell=bash
# recommend.sh: optional hardening, offered as cards. server-setup recommends
# industry practice; the user decides. Nothing here is applied unless the
# user picks Apply (or lists the ID in RECOMMENDATIONS for unattended runs).
#
# Each recommendation is a REC_<field>[ID] entry plus two functions:
#   rec_ok_<id>     returns 0 when the control is already in place
#   rec_apply_<id>  applies it through write_file (so dry-run shows a diff
#                   and the change can be undone from History)
# Check-only items (disk encryption, Secure Boot, Livepatch) have no apply
# function; their card explains how to do it instead.
#
# Decisions live in state.json: recommendations.<ID> = {decision, date, by,
# until}. decision is applied | skip | never | later (re-asked after "until").

declare -gA REC_TITLE=() REC_WHY=() REC_STD=() REC_IMPACT=() REC_UNDO=() REC_EFFORT=() REC_SCOPE=() REC_HOW=()
REC_IDS=()
REC_LATER_DAYS=14

rec_def() {   # rec_def ID SCOPE("all", or any of server personal wsl) TITLE WHY STANDARD IMPACT UNDO EFFORT [HOW for check-only]
  REC_IDS+=("$1"); REC_SCOPE[$1]=$2; REC_TITLE[$1]=$3; REC_WHY[$1]=$4; REC_STD[$1]=$5
  REC_IMPACT[$1]=$6; REC_UNDO[$1]=$7; REC_EFFORT[$1]=$8; REC_HOW[$1]=${9:-}
}
rec_fn() { local id=${1#REC-}; printf '%s' "${id,,}" | tr '-' '_'; }

# ---------------------------------------------------------------- catalogue
rec_def REC-SYSCTL "server personal" "Kernel network hardening" \
  "Turns off ICMP redirects and source routing, turns on reverse-path filtering, SYN cookies and logging of impossible packets, and hides kernel pointers from normal users. These block common spoofing and information leaks." \
  "CIS Ubuntu 24.04 3.3.x, 1.5.x" \
  "Does not change IP forwarding, so Docker, VPNs and routers keep working." \
  "Yes: undo the run from History" "Instant"
rec_ok_sysctl() { [[ -f /etc/sysctl.d/60-server-setup.conf ]] && [[ $(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null) == 0 ]]; }
rec_apply_sysctl() {
  write_file /etc/sysctl.d/60-server-setup.conf 644 <<'EOF'
# Managed by server-setup (recommendation REC-SYSCTL, CIS 3.3.x / 1.5.x)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
  [[ $SS_DRY_RUN == true ]] || sysctl --system >/dev/null 2>&1 || warn "Some kernel settings did not apply (normal inside containers)."
}

rec_def REC-AUDITD server "Audit log for sensitive changes" \
  "Installs auditd and records every change to accounts, sudo rules, SSH settings and SSH keys, and every use of sudo, in a log that a normal user cannot erase. It answers 'who changed this, and when' after an incident." \
  "CIS Ubuntu 24.04 6.3.x · NIST SP 800-53 AU-2, AU-12" \
  "About 1 MB of log a day on a quiet server. Logs rotate automatically." \
  "Yes: undo the run from History, then: sudo apt remove auditd" "About a minute (installs a package)"
rec_ok_auditd() { pkg_installed auditd && [[ -f /etc/audit/rules.d/50-server-setup.rules ]]; }
rec_apply_auditd() {
  ensure_packages auditd
  write_file /etc/audit/rules.d/50-server-setup.rules 640 <<'EOF'
## Managed by server-setup (recommendation REC-AUDITD, CIS 6.3.x)
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /root/.ssh/ -p wa -k ssh-keys
-w /etc/server-setup/ -p wa -k server-setup
-w /var/log/sudo.log -p wa -k sudo-log
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k privilege
-a always,exit -F arch=b32 -S execve -C uid!=euid -F euid=0 -k privilege
EOF
  [[ $SS_DRY_RUN == true ]] && return 0
  augenrules --load >/dev/null 2>&1 || warn "auditd rules saved; they load at the next boot (normal inside containers)."
  systemctl enable --now auditd >/dev/null 2>&1 || true
}

rec_def REC-PWQUALITY all "Strong password rules" \
  "New passwords must be at least 14 characters and not a dictionary word or the user name. Admin passwords guard sudo, so they are worth making hard to guess." \
  "CIS Ubuntu 24.04 5.3.3.2.x · NIST SP 800-63B" \
  "Only affects new passwords; existing ones keep working." \
  "Yes: undo the run from History" "Instant (installs a small package)"
rec_ok_pwquality() { [[ -f /etc/security/pwquality.conf.d/50-server-setup.conf ]]; }
rec_apply_pwquality() {
  ensure_packages libpam-pwquality
  write_file /etc/security/pwquality.conf.d/50-server-setup.conf 644 <<'EOF'
# Managed by server-setup (recommendation REC-PWQUALITY, CIS 5.3.3.2.x)
minlen = 14
minclass = 1
maxrepeat = 3
dictcheck = 1
usercheck = 1
enforce_for_root
EOF
}

rec_def REC-APPARMOR "server personal" "AppArmor on" \
  "AppArmor confines programs to what they need, so a hacked service cannot read the rest of the system. Ubuntu ships it on; this makes sure it stays on." \
  "CIS Ubuntu 24.04 1.3.1.x" \
  "None for normal use." "Yes: sudo systemctl disable --now apparmor" "Instant"
rec_ok_apparmor() { [[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] && systemctl is-enabled --quiet apparmor 2>/dev/null; }
rec_apply_apparmor() {
  ensure_packages apparmor apparmor-utils
  [[ $SS_DRY_RUN == true ]] && { echo "  would run: systemctl enable --now apparmor"; return 0; }
  systemctl enable --now apparmor >/dev/null 2>&1 || warn "AppArmor could not start (normal inside containers)."
}

rec_def REC-LIVEPATCH server "Kernel patches without reboots (Ubuntu Pro)" \
  "Ubuntu Pro is free for up to 5 machines. Livepatch fixes critical kernel holes without a restart, and Pro extends security updates to 10 years and to the 'universe' packages." \
  "Ubuntu security guidance" \
  "Needs a free Ubuntu account and token." "Yes: sudo pro detach" "5 minutes" \
  "Get a token at ubuntu.com/pro (free for personal use), then: sudo pro attach YOUR_TOKEN"
rec_ok_livepatch() { command -v pro >/dev/null && pro status 2>/dev/null | grep -qE '^livepatch +yes +enabled'; }

rec_def REC-DISK-ENCRYPTION personal "Disk encryption" \
  "If this laptop is lost or stolen, encryption keeps your files private. Without it, anyone can read the disk by plugging it into another computer." \
  "CIS Controls v8 3.6 · NIST SP 800-111" \
  "Small speed cost on old hardware." "No (it is chosen when Ubuntu is installed)" "Reinstall" \
  "Encryption is chosen during installation: back up, reinstall Ubuntu, and pick 'Encrypt the new Ubuntu installation' (LUKS)."
rec_ok_disk_encryption() { lsblk -no TYPE 2>/dev/null | grep -qx crypt; }

rec_def REC-SECURE-BOOT personal "Secure Boot" \
  "Secure Boot stops tampered boot loaders and kernels from starting, which blocks a class of hard-to-remove malware." \
  "CIS Controls v8 2.5 · NIST SP 800-147" \
  "Unsigned third-party drivers (some NVIDIA setups) need extra steps." "Yes, in the firmware settings" "5 minutes in the firmware" \
  "Restart, open the firmware (UEFI) settings (often F2, F10 or Del), turn on Secure Boot, save and restart."
rec_ok_secure_boot() { mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; }

rec_def REC-SCREEN-LOCK personal "Lock the screen when idle" \
  "Locks the desktop after 5 minutes without use, so nobody can use your open session if you step away." \
  "CIS Ubuntu 24.04 1.7.x (GNOME) · NIST SP 800-53 AC-11" \
  "You type your password more often." "Yes: Settings > Privacy > Screen Lock" "Instant"
rec_desktop_user() { local u=${SUDO_USER:-}; [[ -n $u && $u != root ]] || u=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3!="root" && $3!="gdm" {print $3; exit}'); printf '%s' "$u"; }
rec_gsettings() {   # rec_gsettings USER get|set SCHEMA KEY [VALUE]
  local u=$1 uid; shift
  uid=$(id -u "$u" 2>/dev/null) || return 1
  [[ -S /run/user/$uid/bus ]] || return 1
  runuser -u "$u" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" gsettings "$@"
}
rec_ok_screen_lock() {
  local u; u=$(rec_desktop_user); [[ -n $u ]] || return 1
  [[ $(rec_gsettings "$u" get org.gnome.desktop.screensaver lock-enabled 2>/dev/null) == true ]] &&
    (( $(rec_gsettings "$u" get org.gnome.desktop.session idle-delay 2>/dev/null | awk '{print $NF}') > 0 ))
}
rec_apply_screen_lock() {
  local u; u=$(rec_desktop_user)
  [[ -n $u ]] || { warn "No desktop session found. Log in to the desktop and try again."; return 1; }
  [[ $SS_DRY_RUN == true ]] && { echo "  would set for $u: lock after 5 minutes idle, lock when the screen blanks"; return 0; }
  rec_gsettings "$u" set org.gnome.desktop.session idle-delay 300 &&
    rec_gsettings "$u" set org.gnome.desktop.screensaver lock-enabled true &&
    rec_gsettings "$u" set org.gnome.desktop.screensaver lock-delay 0 ||
    { warn "Could not change the desktop settings for $u (is $u logged in to the desktop?)."; return 1; }
}

rec_def REC-AUTOLOGIN personal "Turn off automatic login" \
  "With automatic login, anyone who turns on the computer gets your desktop, files and saved browser passwords." \
  "CIS Ubuntu 24.04 1.7.x · NIST SP 800-53 IA-2" \
  "You type your password at start-up." "Yes: undo the run from History" "Instant"
REC_GDM_CONF=${SS_GDM_CONF:-/etc/gdm3/custom.conf}
rec_ok_autologin() { [[ ! -f $REC_GDM_CONF ]] || ! grep -qiE '^\s*AutomaticLoginEnable\s*=\s*true' "$REC_GDM_CONF"; }
rec_apply_autologin() {
  [[ -f $REC_GDM_CONF ]] || return 0
  sed -E 's/^(\s*AutomaticLoginEnable\s*=\s*)true/\1false/I' "$REC_GDM_CONF" | write_file "$REC_GDM_CONF" 644
}

# ---------------------------------------------------------------- state
rec_applies() {   # does this recommendation fit this machine?
  local t; t=$(state_get machine_type); t=${t:-server}
  [[ " ${REC_SCOPE[$1]} " == *" all "* || " ${REC_SCOPE[$1]} " == *" $t "* ]]
}
rec_can_apply() { declare -F "rec_apply_$(rec_fn "$1")" >/dev/null; }
rec_in_place() { "rec_ok_$(rec_fn "$1")" 2>/dev/null; }
rec_decision() { state_get "recommendations.$1.decision"; }

# rec_status ID → in-place | applied-drift | skip | never | later | open
rec_status() {
  local d; d=$(rec_decision "$1")
  if rec_in_place "$1"; then echo in-place; return; fi
  case $d in
    skip|never) echo "$d" ;;
    later) if (( $(state_get "recommendations.$1.until" || echo 0) > $(date +%s) )); then echo later; else echo open; fi ;;
    applied) echo applied-drift ;;
    *) echo open ;;
  esac
}

rec_decide() {   # rec_decide ID applied|skip|never|later
  local until=0
  [[ $2 == later ]] && until=$(( $(date +%s) + REC_LATER_DAYS * 86400 ))
  state_set "recommendations.$1" "{\"decision\": $(json_str "$2"), \"date\": $(json_str "$(date -Is)"), \"by\": $(json_str "${SUDO_USER:-root}"), \"until\": $until}"
  history_add recommendation ok "${REC_TITLE[$1]}: $2"
}

# Open = applicable, not in place, and not decided against (for the dashboard count).
rec_open_ids() {
  local id
  for id in "${REC_IDS[@]}"; do rec_applies "$id" && [[ $(rec_status "$id") =~ ^(open|applied-drift)$ ]] && echo "$id"; done
  return 0
}

rec_apply() {    # rec_apply ID: apply and record (caller holds the lock)
  local id=$1
  step "${REC_TITLE[$id]}"
  "rec_apply_$(rec_fn "$id")" || return 1
  [[ $SS_DRY_RUN == true ]] && return 0
  rec_decide "$id" applied
  log "${REC_TITLE[$id]}: done."
}

# ---------------------------------------------------------------- screens
rec_card() {   # rec_card ID: the card pop-up, with the decision buttons
  local id=$1 st body=() items=() acts=() color=$C_CYAN
  st=$(rec_status "$id")
  body+=("${C_BOLD}${REC_TITLE[$id]}${C_0}  $(rec_status_label "$st")" "")
  body+=("${REC_WHY[$id]}" "")
  body+=("Standard:     ${REC_STD[$id]}")
  body+=("Impact:       ${REC_IMPACT[$id]}")
  body+=("Can undo:     ${REC_UNDO[$id]}")
  body+=("Effort:       ${REC_EFFORT[$id]}")
  [[ -n ${REC_HOW[$id]} ]] && body+=("" "How:          ${REC_HOW[$id]}")
  if [[ $st != in-place ]]; then
    if rec_can_apply "$id"; then items+=("Apply|shows exactly what changes first"); acts+=(apply)
    else items+=("I've done it|check again"); acts+=(recheck); fi
    items+=("Remind me in $REC_LATER_DAYS days|" "Skip|not for this machine; shown as skipped in the check" "Never ask again|"); acts+=(later skip never)
  fi
  items+=("Back|"); acts+=(back)
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$color" "Recommendation $id" "${body[@]}" -- "${items[@]}"
  (( UI_CHOICE >= 0 )) || return 0
  case ${acts[$UI_CHOICE]} in
    apply)   rec_apply_with_plan "$id" ;;
    recheck) rec_in_place "$id" && { rec_decide "$id" applied; return 0; }
             UI_POPUP_NOTE='' ui_popup "$C_AMBER" "Not in place yet" "server-setup still can't see it on this machine." "${REC_HOW[$id]}" -- "OK|" ;;
    later|skip|never) rec_decide "$id" "${acts[$UI_CHOICE]}"
                      [[ ${acts[$UI_CHOICE]} == later ]] || rec_cfg_list remove "$id" ;;
  esac
}

# Keep RECOMMENDATIONS in the saved settings in line with decisions made on the
# cards, so a later "Set up" (or a replay of config.env elsewhere) matches.
rec_cfg_list() {   # rec_cfg_list add|remove ID
  local f; f=$(CONFIG_FILE)
  [[ -f $f ]] || return 0
  cfg_reset; cfg_load "$f"
  CFG[RECOMMENDATIONS]=$(tr ' ' '\n' <<<"${CFG[RECOMMENDATIONS]}" | grep -vxF -e "$2" -e '' || true)
  [[ $1 == add ]] && CFG[RECOMMENDATIONS]+=" $2"
  CFG[RECOMMENDATIONS]=$(xargs <<<"${CFG[RECOMMENDATIONS]}")
  cfg_save "$f"
}

rec_apply_with_plan() {
  local id=$1 plan
  dash_lock || return 0
  # The package manager's own command lines say little to a reader; show the package names.
  plan=$( ( SS_DRY_RUN=true; NO_COLOR=1; "rec_apply_$(rec_fn "$id")" ) 2>&1 | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g
    /would run: apt-get .* update$/d; s/would run: apt-get .* install (--no-install-recommends )?/would install the package: /; /^\s*$/d' | head -40)
  ss_unlock
  local lines=(); mapfile -t lines <<<"${plan:-  (no file changes; it only turns a setting on)}"
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$C_CYAN" "Apply: ${REC_TITLE[$id]}" "This is what will change:" "" "${lines[@]}" \
    -- "Not now|" "Apply now|"
  (( UI_CHOICE == 1 )) || return 0
  dash_lock || return 0
  ui_clear
  if rec_apply "$id"; then rec_cfg_list add "$id"; else warn "Not applied."; fi
  ss_unlock; ui_pause
}

rec_status_label() {
  case $1 in
    in-place) printf '%s✔ in place%s' "$C_GREEN" "$C_0" ;;
    applied-drift) printf '%s! applied before, no longer in place%s' "$C_AMBER" "$C_0" ;;
    skip) printf '%s– skipped%s' "$C_DIM" "$C_0" ;;
    never) printf '%s– never ask%s' "$C_DIM" "$C_0" ;;
    later) printf '%s… reminder set%s' "$C_DIM" "$C_0" ;;
    *) printf '%s● recommended%s' "$C_AMBER" "$C_0" ;;
  esac
}

# 9: every recommendation that fits this machine, with its state.
screen_recommendations() {
  local ids=() items=() id
  for id in "${REC_IDS[@]}"; do
    rec_applies "$id" || continue
    ids+=("$id"); items+=("${REC_TITLE[$id]}|$(rec_status_label "$(rec_status "$id")")")
  done
  ui_clear; step "Recommendations"
  printf '  %sIndustry practice for this kind of machine. Nothing is applied unless you choose Apply.%s\n' "$C_DIM" "$C_0"
  UI_MENU_WIDTH=46 ui_menu "Pick one to see why it matters and decide" "${items[@]}" "Back|"
  (( UI_CHOICE >= 0 && UI_CHOICE < ${#ids[@]} )) || return 0
  rec_card "${ids[$UI_CHOICE]}"
  screen_recommendations
}

# For the security check: one row per recommendation that fits this machine.
rec_checks() {
  local id st
  for id in "${REC_IDS[@]}"; do
    rec_applies "$id" || continue
    st=$(rec_status "$id")
    case $st in
      in-place) chk PASS "$id" "${REC_TITLE[$id]}" ;;
      skip|never) chk SKIP "$id" "${REC_TITLE[$id]} (skipped by you)" ;;
      later) chk INFO "$id" "${REC_TITLE[$id]}: reminder set" ;;
      *) chk INFO "$id" "${REC_TITLE[$id]}: recommended" "Dashboard: 9 Recommendations" ;;
    esac
  done
}

# Unattended: apply what the RECOMMENDATIONS setting lists, nothing else.
apply_recommendations() {
  local id
  for id in ${CFG[RECOMMENDATIONS]}; do
    [[ -v "REC_TITLE[$id]" ]] || { warn "Unknown recommendation $id; skipped."; continue; }
    rec_applies "$id" || { info "$id does not apply to this machine; skipped."; continue; }
    rec_can_apply "$id" || { info "$id is check-only: ${REC_HOW[$id]}"; continue; }
    rec_in_place "$id" && { info "${REC_TITLE[$id]}: already in place."; continue; }
    rec_apply "$id"
  done
}

# Setup wizard: a checklist of the recommendations that can be applied here.
# Open ones are ticked; ones you skipped or postponed are shown unticked;
# "never ask" ones are left out.
wizard_recommendations() {
  local id st items=() ids=() on i
  for id in "${REC_IDS[@]}"; do
    rec_applies "$id" && rec_can_apply "$id" || continue
    st=$(rec_status "$id")
    [[ $st == in-place || $st == never ]] && continue
    on=on; [[ $st =~ ^(skip|later)$ ]] && on=off
    [[ " ${CFG[RECOMMENDATIONS]} " == *" $id "* ]] && on=on
    ids+=("$id"); items+=("$on|${REC_TITLE[$id]}|${REC_STD[$id]}")
  done
  (( ${#ids[@]} )) || return 0
  printf '\n  %sRecommended extra hardening. Untick anything you do not want; dashboard key 9 explains each one.%s' "$C_DIM" "$C_0"
  ui_checklist "Extra hardening (industry practice)" "${items[@]}" || return 1
  CFG[RECOMMENDATIONS]=""
  for i in "${UI_CHECKED[@]}"; do CFG[RECOMMENDATIONS]+="${ids[$i]} "; done
  CFG[RECOMMENDATIONS]=$(xargs <<<"${CFG[RECOMMENDATIONS]}")
}

# server-setup recommendations [--json]
cmd_recommendations() {
  local id st json=${1:-false}
  for id in "${REC_IDS[@]}"; do
    rec_applies "$id" || continue
    st=$(rec_status "$id")
    if [[ $json == true ]]; then
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$id" "$st" "$(rec_can_apply "$id" && echo yes || echo no)" "${REC_TITLE[$id]}" "${REC_STD[$id]}"
    else
      printf '  %-20s %s  %s\n' "$id" "$(ui_pad "$(rec_status_label "$st")" 34)" "${REC_TITLE[$id]}"
    fi
  done | if [[ $json == true ]]; then python3 -I -c 'import json,sys; k=("id","status","can_apply","title","standard"); print(json.dumps([dict(zip(k, l.rstrip("\n").split("\x1f"))) for l in sys.stdin], indent=2))'; else cat; fi
}
