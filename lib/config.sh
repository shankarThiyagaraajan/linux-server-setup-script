# shellcheck shell=bash
# config.sh: the saved setup choices (/etc/server-setup/config.env) and validation.
#
# The file is parsed, never sourced: only known keys are read and every value
# is validated before anything on the system changes.

# key → default
declare -gA CFG_DEFAULTS=(
  [MACHINE_TYPE]=""            # server | personal | wsl
  [PROFILE]="base"             # base | web | custom
  [COMPONENTS]="ssh firewall fail2ban autoupdates timesync watch schedule"
  [ADMIN_USERS]=""             # space-separated; first one is the primary admin
  [ADMIN_PUBKEY]=""            # key text or file, for the first admin (unattended)
  [ADMIN_PASSWORD_HASH]=""     # crypt hash (openssl passwd -6), for unattended runs
  [ALLOW_NOPASSWD_SUDO]="false"
  [SSH_USERS]=""               # other existing accounts that keep SSH access
  [SSH_PORT]=""                # blank = keep the current port
  [SSH_FORWARDING]="local"     # no | local | yes
  [OPEN_PORTS]=""              # e.g. "80/tcp 443/tcp"
  [TRUSTED_CIDRS]=""           # never rate-limited or banned
  [AUTO_REBOOT]="false"
  [REBOOT_TIME]="04:00"
  [TIMEZONE]=""                # blank = keep the current timezone
  [MAINT_DAILY]="true"         # scheduled maintenance (component "schedule")
  [MAINT_WEEKLY]="true"
  [MAINT_MONTHLY]="true"
  [MAINT_UPDATES]="security"   # weekly job installs: security | all | none
  [MAINT_BACKUPS_KEEP]="8"     # weekly settings backups to keep
  [RECOMMENDATIONS]=""         # optional hardening to apply, e.g. "REC-SYSCTL REC-AUDITD"
)

declare -gA CFG=()

cfg_reset() {
  local k
  CFG=()
  for k in "${!CFG_DEFAULTS[@]}"; do CFG[$k]=${CFG_DEFAULTS[$k]}; done
}

# cfg_load FILE: KEY=value or KEY="value" lines; unknown keys are an error.
cfg_load() {
  local file=$1 line key val n=0
  [[ -r $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      die "$file line $n is not KEY=value: $line"
    fi
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
    [[ -v "CFG_DEFAULTS[$key]" ]] || die "$file line $n: unknown setting $key"
    CFG[$key]=$val
  done <"$file"
}

# Environment variables override the file (handy for one-off unattended runs).
cfg_from_env() {
  local k
  for k in "${!CFG_DEFAULTS[@]}"; do
    if [[ -n ${!k+x} ]]; then CFG[$k]=${!k}; fi
  done
}

cfg_save() {
  local file=$1 tmp k
  tmp=$(mktemp "${file}.XXXXXX")
  {
    printf '# server-setup settings, written %s. Edit with: sudo server-setup setup\n' "$(date -Is)"
    for k in $(printf '%s\n' "${!CFG_DEFAULTS[@]}" | sort); do
      [[ $k == ADMIN_PUBKEY || $k == ADMIN_PASSWORD_HASH ]] && continue   # secrets and keys live elsewhere
      printf '%s="%s"\n' "$k" "${CFG[$k]}"
    done
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# ------------------------------- validators ----------------------------------
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]; }
valid_port()     { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
valid_portspec() {   # 80, 80/tcp, 6000:6007/udp
  local p=${1%/*} proto=
  [[ $1 == */* ]] && proto=${1#*/}
  [[ -z $proto || $proto =~ ^(tcp|udp)$ ]] || return 1
  if [[ $p == *:* ]]; then
    [[ -n $proto ]] && valid_port "${p%%:*}" && valid_port "${p#*:}" && (( 10#${p%%:*} < 10#${p#*:} ))
  else
    valid_port "$p"
  fi
}
valid_cidr() {
  local ip=${1%/*} mask=
  [[ $1 == */* ]] && mask=${1#*/}
  if [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local o; for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
    [[ -z $mask ]] || { [[ $mask =~ ^[0-9]{1,2}$ ]] && (( 10#$mask <= 32 )); }
  elif [[ $ip =~ ^[0-9A-Fa-f:]+$ && $ip == *:* ]]; then
    [[ -z $mask ]] || { [[ $mask =~ ^[0-9]{1,3}$ ]] && (( 10#$mask <= 128 )); }
  else
    return 1
  fi
}
valid_time()     { [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
valid_bool()     { [[ ${1,,} =~ ^(true|false)$ ]]; }
valid_timezone() { [[ -z $1 ]] || { [[ $1 =~ ^[A-Za-z0-9_+/-]+$ && -f /usr/share/zoneinfo/$1 ]]; }; }
valid_hash()     { [[ -z $1 || $1 =~ ^\$(6|y|7|2b)\$[./A-Za-z0-9$]+$ ]]; }

# cfg_validate: collect every problem, report them together, change nothing.
cfg_validate() {
  local errs=() u p c
  [[ ${CFG[MACHINE_TYPE]} =~ ^(server|personal|wsl)$ ]] || errs+=("MACHINE_TYPE must be server, personal or wsl")
  [[ ${CFG[PROFILE]} =~ ^(base|web|custom)$ ]] || errs+=("PROFILE must be base, web or custom")
  for c in ${CFG[COMPONENTS]}; do
    [[ $c =~ ^(ssh|firewall|fail2ban|autoupdates|timesync|watch|schedule)$ ]] || errs+=("unknown component: $c")
  done
  for c in ${CFG[RECOMMENDATIONS]}; do
    [[ -v "REC_TITLE[$c]" ]] || errs+=("unknown recommendation: $c (see: server-setup recommendations)")
  done
  for u in ${CFG[ADMIN_USERS]} ${CFG[SSH_USERS]}; do
    valid_username "$u" || errs+=("invalid user name: $u")
  done
  if [[ ${CFG[MACHINE_TYPE]} == server && -z ${CFG[ADMIN_USERS]} ]]; then
    errs+=("ADMIN_USERS is required on a server")
  fi
  [[ -z ${CFG[SSH_PORT]} ]] || valid_port "${CFG[SSH_PORT]}" || errs+=("SSH_PORT must be 1-65535 without leading zeros")
  [[ ${CFG[SSH_FORWARDING]} =~ ^(no|local|yes)$ ]] || errs+=("SSH_FORWARDING must be no, local or yes")
  for p in ${CFG[OPEN_PORTS]}; do valid_portspec "$p" || errs+=("invalid port: $p (use 80/tcp or 6000:6007/udp)"); done
  for p in ${CFG[TRUSTED_CIDRS]}; do valid_cidr "$p" || errs+=("invalid IP or CIDR: $p"); done
  for c in MAINT_DAILY MAINT_WEEKLY MAINT_MONTHLY; do valid_bool "${CFG[$c]}" || errs+=("$c must be true or false"); done
  [[ ${CFG[MAINT_UPDATES]} =~ ^(security|all|none)$ ]] || errs+=("MAINT_UPDATES must be security, all or none")
  [[ ${CFG[MAINT_BACKUPS_KEEP]} =~ ^[1-9][0-9]{0,2}$ ]] || errs+=("MAINT_BACKUPS_KEEP must be a number from 1 to 999")
  valid_bool "${CFG[AUTO_REBOOT]}" || errs+=("AUTO_REBOOT must be true or false")
  valid_bool "${CFG[ALLOW_NOPASSWD_SUDO]}" || errs+=("ALLOW_NOPASSWD_SUDO must be true or false")
  valid_time "${CFG[REBOOT_TIME]}" || errs+=("REBOOT_TIME must be HH:MM")
  valid_timezone "${CFG[TIMEZONE]}" || errs+=("unknown TIMEZONE: ${CFG[TIMEZONE]}")
  valid_hash "${CFG[ADMIN_PASSWORD_HASH]}" || errs+=("ADMIN_PASSWORD_HASH must be a crypt hash, e.g. from: openssl passwd -6")
  if (( ${#errs[@]} )); then
    printf '%s[x]%s Settings are not valid; nothing was changed:\n' "$C_RED" "$C_0" >&2
    printf '      - %s\n' "${errs[@]}" >&2
    return 1
  fi
}

cfg_has() { [[ " ${CFG[COMPONENTS]} " == *" $1 "* ]]; }
cfg_primary_admin() { local a; read -ra a <<<"${CFG[ADMIN_USERS]}"; printf '%s' "${a[0]:-}"; }
