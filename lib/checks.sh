# shellcheck shell=bash
# checks.sh: the read-only security check. Each check has an ID, a status
# (PASS / WARN / FAIL / INFO / SKIP), a message and a suggested fix.
# Checks the user chose to skip (recommendations.<ID>.decision == skip)
# are shown as "Skipped by you" and left out of the score.

CHK_RESULTS=()    # "STATUS<TAB>ID<TAB>message<TAB>fix"
CHK_PASS=0; CHK_WARN=0; CHK_FAIL=0; CHK_SCORE=100

chk() {   # chk STATUS ID "message" ["fix"]
  local st=$1 id=$2 msg=$3 fix=${4:-}
  if [[ $st =~ ^(WARN|FAIL)$ && $(state_get "recommendations.$id.decision" 2>/dev/null) =~ ^(skip|never)$ ]]; then
    st=SKIP; msg="$msg (skipped by you)"; fix=""
  fi
  case $st in PASS) CHK_PASS=$((CHK_PASS + 1)) ;; WARN) CHK_WARN=$((CHK_WARN + 1)) ;; FAIL) CHK_FAIL=$((CHK_FAIL + 1)) ;; esac
  CHK_RESULTS+=("$st	$id	$msg	$fix")
}

run_checks() {
  CHK_RESULTS=(); CHK_PASS=0; CHK_WARN=0; CHK_FAIL=0
  local mtype eff v ufw pct n

  mtype=$(state_get machine_type); mtype=${mtype:-server}

  # ---- system
  if [[ -f /var/run/reboot-required ]]; then chk WARN SYS-REBOOT "A reboot is needed to finish updates" "sudo reboot"
  else chk PASS SYS-REBOOT "No reboot pending"; fi
  pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
  if (( pct >= 90 )); then chk FAIL SYS-DISK "Disk / is ${pct}% full" "sudo apt-get autoremove --purge; sudo journalctl --vacuum-size=200M"
  elif (( pct >= 80 )); then chk WARN SYS-DISK "Disk / is ${pct}% full" "sudo apt-get autoremove --purge; sudo journalctl --vacuum-size=200M"
  else chk PASS SYS-DISK "Disk / is ${pct}% used"; fi
  n=$(systemctl --failed --no-legend --plain 2>/dev/null | grep -c . || true)
  if (( n > 0 )); then chk WARN SYS-UNITS "$n service(s) failed" "systemctl --failed"; else chk PASS SYS-UNITS "No failed services"; fi
  v=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  case $v in yes) chk PASS SYS-TIME "Clock is synchronised" ;; no) chk WARN SYS-TIME "Clock is not synchronised" "sudo timedatectl set-ntp true" ;; esac

  # ---- updates
  n=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep '^Inst ' | grep -ci security || true)
  if (( n > 0 )); then chk FAIL UPD-SECURITY "$n security update(s) waiting" "server-setup updates"
  else chk PASS UPD-SECURITY "No security updates waiting"; fi
  if pkg_installed unattended-upgrades && apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then
    chk PASS UPD-AUTO "Automatic security updates are on"
  else
    chk FAIL UPD-AUTO "Automatic security updates are off" "Set up server → Automatic updates"
  fi

  # ---- SSH (only when an SSH server is installed)
  if command -v sshd >/dev/null 2>&1; then
    eff=$(sshd_effective || true)
    if [[ -z $eff ]]; then
      chk FAIL SSH-CONFIG "The SSH config does not load" "sudo sshd -t"
    else
      case $(sshd_value permitrootlogin "$eff") in
        no) chk PASS SSH-ROOT "Root cannot log in over SSH" ;;
        prohibit-password|without-password|forced-commands-only)
            chk WARN SSH-ROOT "Root can log in over SSH with a key" "Set up server → SSH" ;;
        *)  chk FAIL SSH-ROOT "Root can log in over SSH with a password" "Set up server → SSH" ;;
      esac
      [[ $(sshd_value passwordauthentication "$eff") == no ]] && chk PASS SSH-PASSWORD "SSH accepts keys only" \
        || chk FAIL SSH-PASSWORD "SSH accepts passwords" "Set up server → SSH"
      if grep -qiE '^(allowgroups|allowusers) ' <<<"$eff"; then chk PASS SSH-ALLOW "SSH is limited to: $(awk '$1=="allowgroups"||$1=="allowusers" {$1=""; print}' <<<"$eff" | xargs)"
      else chk WARN SSH-ALLOW "Every account may try to log in over SSH" "Set up server → SSH"; fi
      v=$(sshd_value maxauthtries "$eff")
      (( ${v:-6} <= 4 )) && chk PASS SSH-TRIES "MaxAuthTries is $v" || chk WARN SSH-TRIES "MaxAuthTries is ${v:-6}" "Set up server → SSH"
    fi
    if [[ -n $(state_get ssh.pending) ]]; then
      chk WARN SSH-PENDING "SSH changes are waiting for you to confirm" "Log in again in a new terminal and run: sudo server-setup confirm"
    fi
  elif [[ $mtype == server ]]; then
    chk INFO SSH-NONE "No SSH server installed"
  fi

  # ---- accounts
  v=$(awk -F: '$3==0 && $1!="root" {print $1}' /etc/passwd | xargs)
  [[ -z $v ]] && chk PASS ACC-UID0 "Only root has UID 0" || chk FAIL ACC-UID0 "Extra accounts with root rights: $v" "Investigate, then: sudo userdel <name>"
  v=$(awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null | xargs)
  [[ -z $v ]] && chk PASS ACC-EMPTYPW "No accounts with an empty password" || chk FAIL ACC-EMPTYPW "Accounts with an empty password: $v" "sudo passwd -l <name>"

  # ---- firewall
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    chk PASS FW-ACTIVE "Firewall is on"
    ufw=$(ufw status verbose 2>/dev/null)
    grep -qE '^Default: (deny|reject) \(incoming\)' <<<"$ufw" && chk PASS FW-DEFAULT "Incoming connections are blocked by default" \
      || chk FAIL FW-DEFAULT "Firewall lets incoming connections in by default" "sudo ufw default deny incoming"
  else
    chk FAIL FW-ACTIVE "Firewall is off" "Set up server → Firewall"
  fi

  # ---- intrusion prevention (servers, or when SSH is installed)
  if [[ $mtype == server ]] || command -v sshd >/dev/null 2>&1; then
    if systemctl is-active --quiet fail2ban 2>/dev/null; then chk PASS F2B-ACTIVE "Fail2ban is running"
    else chk WARN F2B-ACTIVE "Fail2ban is not running" "Set up server → Fail2ban"; fi
  fi

  # ---- security watch
  if [[ " $(state_get setup.components | tr -d '[]",') " == *" watch "* ]] || watch_installed; then
    if watch_running; then chk PASS WATCH-ON "Security watch is running"
    else chk WARN WATCH-ON "Security watch is not running" "sudo systemctl restart $WATCH_UNIT"; fi
  else
    chk WARN WATCH-ON "Security watch is off" "Dashboard: press w"
  fi
  n=$(_watch_py summary 2>/dev/null | awk -F'\t' '$1=="unreviewed" {print $2 + 0}')
  v=$(_watch_py summary 2>/dev/null | awk -F'\t' '$1=="unreviewed" {print $3 + 0}')
  if (( ${v:-0} > 0 )); then chk FAIL EVT-OPEN "$n security event(s) to review, $v critical" "Dashboard: press e"
  elif (( ${n:-0} > 0 )); then chk WARN EVT-OPEN "$n security event(s) to review" "Dashboard: press e"; fi

  # ---- optional hardening (only what fits this machine; never scored unless in place)
  rec_checks

  # ---- drift
  n=$(drift_files | grep -c . || true)
  if (( n > 0 )); then chk WARN DRIFT "$n managed file(s) were changed outside server-setup" "Set up server → Review the changes"; fi

  local total=$((CHK_PASS + CHK_WARN + CHK_FAIL))
  CHK_SCORE=100
  (( total > 0 )) && CHK_SCORE=$(( (CHK_PASS * 100 + CHK_WARN * 50) / total ))
  return 0
}

# check_rc: 0 all good, 1 warnings, 2 failures.
check_rc() { (( CHK_FAIL > 0 )) && return 2; (( CHK_WARN > 0 )) && return 1; return 0; }

print_checks() {
  local r st id msg fix icon
  for r in "${CHK_RESULTS[@]}"; do
    IFS=$'\t' read -r st id msg fix <<<"$r"
    case $st in
      PASS) icon="${C_GREEN}✔${C_0}" ;; WARN) icon="${C_AMBER}!${C_0}" ;; FAIL) icon="${C_RED}✘${C_0}" ;;
      SKIP) icon="${C_DIM}–${C_0}" ;; *) icon="${C_CYAN}·${C_0}" ;;
    esac
    printf '  %s %s%-13s%s %s\n' "$icon" "$C_DIM" "$id" "$C_0" "$msg"
    [[ -n $fix ]] && printf '                  %s→ %s%s\n' "$C_DIM" "$fix" "$C_0"
  done
  printf '\n  %sSecurity score: %s/100%s  ·  %d pass · %d warn · %d fail\n' "$C_BOLD" "$CHK_SCORE" "$C_0" "$CHK_PASS" "$CHK_WARN" "$CHK_FAIL"
}

checks_json() {
  local r
  for r in "${CHK_RESULTS[@]}"; do printf '%s\n' "$r"; done | python3 -I -c '
import json, sys
rows = [dict(zip(("status", "id", "message", "fix"), l.rstrip("\n").split("\t"))) for l in sys.stdin if l.strip()]
print(json.dumps({"score": int(sys.argv[1]), "results": rows}, indent=2))' "$CHK_SCORE"
}

# cmd_check [json]: sets CHECK_RC (0/1/2) instead of returning it, so a
# finding is never mistaken for the tool failing.
cmd_check() {
  local json=${1:-false} rc=0
  run_checks
  if [[ $json == true ]]; then checks_json; else step "Security check"; print_checks; fi
  check_rc || rc=$?
  if [[ $EUID -eq 0 ]]; then
    state_set last_check "{\"score\": $CHK_SCORE, \"pass\": $CHK_PASS, \"warn\": $CHK_WARN, \"fail\": $CHK_FAIL}"
    history_add check "$( ((rc == 0)) && echo ok || echo attention)" "score $CHK_SCORE · $CHK_WARN warn · $CHK_FAIL fail"
  fi
  CHECK_RC=$rc
}
