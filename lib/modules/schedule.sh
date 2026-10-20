# shellcheck shell=bash
# schedule.sh: routine maintenance run by systemd timers.
#
#   daily    security check; alert when the score drops or a new problem appears
#   weekly   updates (security only by default), clean-up, journal trim,
#            a backup of the settings server-setup manages, and a short report
#   monthly  new Ubuntu release check, admins who have not logged in for 90 days
#
# Each timer runs `server-setup maintain JOB` through one template service.
# Timers are Persistent (a missed run happens at the next boot) and start at
# a random moment in their window, so a fleet does not update all at once.

SCHED_DIR=${SS_SCHED_DIR:-/etc/systemd/system}
SCHED_JOBS=(daily weekly monthly)
MAINT_BACKUP_DIR=${SS_MAINT_BACKUP_DIR:-/var/backups/server-setup}
declare -gA SCHED_WHEN=([daily]="*-*-* 06:30" [weekly]="Sun *-*-* 04:30" [monthly]="*-*-01 05:00")
declare -gA SCHED_DELAY=([daily]=30m [weekly]=1h [monthly]=1h)
declare -gA SCHED_LABEL=([daily]="Daily check" [weekly]="Weekly updates & clean-up" [monthly]="Monthly review")
declare -gA SCHED_HUMAN=([daily]="every day between 06:30 and 07:00" [weekly]="Sundays between 04:30 and 05:30" [monthly]="on the 1st of each month between 05:00 and 06:00")
declare -gA SCHED_KEY=([daily]=MAINT_DAILY [weekly]=MAINT_WEEKLY [monthly]=MAINT_MONTHLY)

sched_timer() { printf 'server-setup-%s.timer' "$1"; }
sched_on() { [[ ${CFG[${SCHED_KEY[$1]}]} == true ]]; }

sched_describe() {   # what each job does, for the screen and the plan
  case $1 in
    daily) echo "security check; alert if the score drops or a new problem appears" ;;
    weekly) case ${CFG[MAINT_UPDATES]} in
              all) echo "all updates, clean-up, journal trim, settings backup, report" ;;
              none) echo "clean-up, journal trim, settings backup, report (no updates)" ;;
              *) echo "security updates, clean-up, journal trim, settings backup, report" ;;
            esac ;;
    monthly) echo "new Ubuntu release check, admins inactive for 90 days" ;;
  esac
}

apply_schedule() {
  local job
  step "Scheduled maintenance"
  write_file "$SCHED_DIR/server-setup-maintain@.service" 644 <<EOF
# Managed by server-setup
[Unit]
Description=server-setup %i maintenance
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(ss_self) maintain %i
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=3h
EOF
  for job in "${SCHED_JOBS[@]}"; do
    write_file "$SCHED_DIR/$(sched_timer "$job")" 644 <<EOF
# Managed by server-setup
[Unit]
Description=server-setup ${job} maintenance ($(sched_describe "$job"))

[Timer]
OnCalendar=${SCHED_WHEN[$job]}
RandomizedDelaySec=${SCHED_DELAY[$job]}
Persistent=true
Unit=server-setup-maintain@${job}.service

[Install]
WantedBy=timers.target
EOF
  done
  [[ $SS_DRY_RUN == true ]] && return 0
  systemctl daemon-reload 2>/dev/null || true
  for job in "${SCHED_JOBS[@]}"; do sched_enable "$job"; done
  log "Maintenance scheduled: $(for job in "${SCHED_JOBS[@]}"; do sched_on "$job" && printf '%s ' "$job"; done)"
}

sched_enable() {   # start or stop a job's timer to match the settings
  if sched_on "$1"; then systemctl enable --now "$(sched_timer "$1")" >/dev/null 2>&1 || warn "Could not start the $1 timer."
  else systemctl disable --now "$(sched_timer "$1")" >/dev/null 2>&1 || true; fi
}

sched_installed() { [[ -f $SCHED_DIR/server-setup-maintain@.service ]]; }
# What systemd will actually run (the screen shows this, not just the settings).
sched_active() { sched_installed && systemctl is-enabled --quiet "$(sched_timer "$1")" 2>/dev/null; }
sched_next() {     # sched_next JOB → when it runs next, or ""
  local v
  v=$(systemctl show -p NextElapseUSecRealtime --value "$(sched_timer "$1")" 2>/dev/null || true)
  [[ -n $v && $v != n/a && $v != 0 ]] && date -d "$v" '+%a %-d %b %H:%M' 2>/dev/null || true
}

# ------------------------------------------------------------ the jobs
# server-setup maintain JOB (the timers run this; "Run now" on screen 7 too)
cmd_maintain() {
  local job=$1 start summary result=ok
  [[ " ${SCHED_JOBS[*]} " == *" $job "* ]] || die "maintain needs daily, weekly or monthly"
  cfg_reset; cfg_load "$(CONFIG_FILE)"
  start=$(date +%s); MAINT_NOTES=(); MAINT_RESULT=ok
  step "${SCHED_LABEL[$job]}"
  "maint_$job"
  result=$MAINT_RESULT
  summary=$(IFS=';'; printf '%s' "${MAINT_NOTES[*]}"); summary=${summary//;/ · }
  history_add "maintain-$job" "$result" "${summary:-done} ($(( $(date +%s) - start ))s)"
  log "${SCHED_LABEL[$job]}: ${summary:-done}"
}
maint_note() { MAINT_NOTES+=("$1"); }
maint_problem() { MAINT_RESULT=attention; maint_note "$1"; }

maint_daily() {
  local before before_fail id r st
  before=$(state_get last_check.score)
  before_fail=$(state_get last_check.fail_ids)     # empty: no list from an older version
  run_checks
  local new_fail=()
  for r in "${CHK_RESULTS[@]}"; do
    IFS=$'\t' read -r st id _ <<<"$r"
    [[ -n $before_fail && $st == FAIL && " $(tr -d '[]",' <<<"$before_fail") " != *" $id "* ]] && new_fail+=("$id")
  done
  check_save
  ui_interactive && print_checks
  maint_note "score $CHK_SCORE"
  # Compare with the last check; the very first one only sets the baseline.
  if [[ -n $before ]] && { (( CHK_SCORE < before )) || (( ${#new_fail[@]} )); }; then
    local msg="Security score dropped from $before to $CHK_SCORE"
    (( CHK_SCORE < before )) || msg="Security score is $CHK_SCORE"
    (( ${#new_fail[@]} )) && msg+=". New problem(s): $(maint_fail_text "${new_fail[@]}")"
    event_raise important score-drop "$msg"
    maint_problem "score dropped"
  fi
}
maint_fail_text() {
  local r st id msg out=()
  for r in "${CHK_RESULTS[@]}"; do
    IFS=$'\t' read -r st id msg _ <<<"$r"
    [[ " $* " == *" $id "* ]] && out+=("$msg")
  done
  (IFS=';'; printf '%s' "${out[*]}") | sed 's/;/; /g'
}

maint_weekly() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local n=0 report=() upd
  case ${CFG[MAINT_UPDATES]} in
    none) upd="updates off" ;;
    all)
      apt_get update >/dev/null || maint_problem "apt update failed"
      n=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)
      apt_get full-upgrade || maint_problem "updates failed"
      upd="$n update(s)" ;;
    *)
      apt_get update >/dev/null || maint_problem "apt update failed"
      n=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep '^Inst ' | grep -ci security || true)
      if command -v unattended-upgrade >/dev/null; then run_cmd unattended-upgrade || maint_problem "security updates failed"
      else maint_problem "unattended-upgrades is not installed"; fi
      upd="$n security update(s)" ;;
  esac
  maint_note "$upd"
  apt_get autoremove --purge >/dev/null || true
  run_cmd journalctl --vacuum-time=30d --vacuum-size=500M >/dev/null 2>&1 || true
  maint_backup || maint_problem "settings backup failed"
  [[ -f /var/run/reboot-required ]] && maint_note "restart needed"
  # The weekly report: a few lines that say the machine is looked after.
  report+=("Updates: $upd")
  report+=("Security score: $(state_get last_check.score || true)/100")
  report+=("Disk /: $(df -P / | awk 'NR==2 {print $5}') used")
  report+=("Failed SSH logins (24h): $(_watch_py summary 2>/dev/null | awk -F'\t' '$1=="fails" {print $2}')")
  [[ -f /var/run/reboot-required ]] && report+=("A restart is needed to finish updates.")
  event_raise info weekly-report "$(printf '%s\n' "${report[@]}")" notify "weekly report"
}

# A tarball of the settings server-setup manages, root-only, oldest pruned.
maint_backup() {
  local keep=${CFG[MAINT_BACKUPS_KEEP]} f paths=() p
  for p in "$SS_CONF_DIR" /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/ufw /etc/fail2ban/jail.d \
           /etc/sudoers /etc/sudoers.d /etc/apt/apt.conf.d /etc/apt/sources.list.d /etc/sysctl.d /etc/audit/rules.d; do
    [[ -e $p ]] && paths+=("$p")
  done
  f="$MAINT_BACKUP_DIR/settings-$(date +%Y%m%d-%H%M%S).tar.gz"
  if [[ $SS_DRY_RUN == true ]]; then echo "  would save ${paths[*]} to $f"; return 0; fi
  install -d -m 700 "$MAINT_BACKUP_DIR"
  (umask 077; tar -czf "$f" --ignore-failed-read "${paths[@]}" 2>/dev/null) || return 1
  ls -1t "$MAINT_BACKUP_DIR"/settings-*.tar.gz 2>/dev/null | tail -n +$(( keep + 1 )) | xargs -r rm -f
  maint_note "settings saved"
}

maint_monthly() {
  local next a last stale=() since
  since=$(date -d "$(state_get setup.date)" +%s 2>/dev/null || echo 0)
  next=$(rel_next)
  if [[ -n $next ]]; then
    event_raise info new-release "Ubuntu $next is available. Upgrade from the dashboard (key 8) when you are ready." notify "new Ubuntu release"
    maint_note "Ubuntu $next available"
  fi
  for a in $(state_get setup.admins | tr -d '[]",'); do
    id "$a" &>/dev/null || continue
    passwd -S "$a" 2>/dev/null | awk '{exit ($2 == "L") ? 0 : 1}' && continue     # already locked
    command -v lastlog >/dev/null || break
    last=$(lastlog -b 90 -u "$a" 2>/dev/null | awk 'NR==2' || true)        # a line only if older than 90 days
    [[ -z $last ]] && continue
    # "Never logged in" counts only once the machine has been set up for 90 days.
    [[ $last == *"Never logged in"* ]] && (( $(date +%s) - since < 90 * 86400 )) && continue
    stale+=("$a")
  done
  if (( ${#stale[@]} )); then
    event_raise important stale-admin "Admin account(s) not used for 90 days or more: ${stale[*]}. Lock them if nobody needs them (Users & SSH keys)."
    maint_problem "${#stale[@]} unused admin(s)"
  fi
  maint_note "review done"
}

# ------------------------------------------------------------ screen (7)
screen_schedule() {
  local items=() job t r st
  cfg_reset; cfg_load "$(CONFIG_FILE)"
  for job in "${SCHED_JOBS[@]}"; do
    t=$(state_get "last.maintain-$job.time"); r=$(state_get "last.maintain-$job.result")
    if ! sched_installed; then st="${C_DIM}not set up${C_0}"
    elif sched_active "$job"; then st="${C_GREEN}● on${C_0}$(n=$(sched_next "$job"); [[ -n $n ]] && echo " · next $n" || true)"
    else st="${C_DIM}○ off${C_0}"; fi
    [[ -n $t ]] && st+=" · last $(human_time "$t") $( [[ $r == ok ]] && ok_mark || warn_mark)"
    items+=("${SCHED_LABEL[$job]}|$st")
  done
  items+=("Weekly updates|$(case ${CFG[MAINT_UPDATES]} in all) echo "all updates" ;; none) echo "none (clean-up only)" ;; *) echo "security only (recommended)" ;; esac)")
  items+=("Back|")
  ui_clear; step "Schedule"
  printf '  %sRoutine maintenance that runs by itself. Results show here, in History, and as alerts.%s\n' "$C_DIM" "$C_0"
  sched_installed || printf '  %sNot set up yet: pick a job and turn it on.%s\n' "$C_AMBER" "$C_0"
  UI_MENU_WIDTH=28 ui_menu "Pick a job to run it now or turn it on or off" "${items[@]}"
  (( UI_CHOICE >= 0 )) || return 0
  if (( UI_CHOICE < ${#SCHED_JOBS[@]} )); then sched_job_popup "${SCHED_JOBS[$UI_CHOICE]}"
  elif (( UI_CHOICE == ${#SCHED_JOBS[@]} )); then sched_updates_popup
  else return 0; fi
  screen_schedule
}

sched_job_popup() {
  local job=$1 toggle
  local what; what=$(sched_describe "$job")
  sched_active "$job" && toggle="Turn off|stop running it on schedule" || toggle="Turn on|runs ${SCHED_HUMAN[$job]}"
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$C_CYAN" "${SCHED_LABEL[$job]}" "${what^}." "" \
    "Runs ${SCHED_HUMAN[$job]}. If the machine is off then, it runs soon after the next start-up." \
    -- "Run now|with live output" "$toggle" "Back|"
  case $UI_CHOICE in
    0) dash_lock || return 0
       ui_clear; cmd_maintain "$job" || warn "The job stopped with an error; see History."
       ss_unlock; ui_pause ;;
    1) dash_lock || return 0
       ui_clear
       if ! sched_installed; then   # first time: only the job picked, not all three
         CFG[MAINT_DAILY]=false CFG[MAINT_WEEKLY]=false CFG[MAINT_MONTHLY]=false
       fi
       if sched_active "$job"; then CFG[${SCHED_KEY[$job]}]=false; else CFG[${SCHED_KEY[$job]}]=true; fi
       sched_save_cfg
       if sched_installed; then sched_enable "$job"; else apply_schedule; fi
       history_add schedule ok "$job maintenance $(sched_on "$job" && echo on || echo off)"
       ss_unlock ;;
  esac
}

sched_updates_popup() {
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$C_CYAN" "Which updates should the weekly job install?" \
    "Automatic security updates also run every day on their own; the weekly job makes sure nothing is stuck." -- \
    "Security only|recommended: fixes, without new versions that change behaviour" \
    "All updates|everything, like Install updates (3)" \
    "None|clean-up and backup only; you update by hand"
  (( UI_CHOICE >= 0 )) || return 0
  local v=(security all none)
  dash_lock || return 0
  CFG[MAINT_UPDATES]=${v[$UI_CHOICE]}; sched_save_cfg
  sched_installed && apply_schedule >/dev/null      # the timer descriptions mention it
  history_add schedule ok "weekly updates: ${CFG[MAINT_UPDATES]}"
  ss_unlock
}

sched_save_cfg() {
  cfg_has schedule || CFG[COMPONENTS]=$(xargs <<<"${CFG[COMPONENTS]} schedule")
  cfg_save "$(CONFIG_FILE)"     # also before setup, so setup keeps these choices
}
