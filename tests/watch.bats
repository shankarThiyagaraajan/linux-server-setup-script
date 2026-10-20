#!/usr/bin/env bats
load helper

setup() {
  load_libs
  export SS_WATCH_FILES="$T/files/*" SS_PROBE_PORTS=$T/ports SS_JOURNAL_CMD="cat $T/journal"
  mkdir -p "$T/files"; : >"$T/ports"; : >"$T/journal"
  echo '{"cursor": "c0", "hashes": {}, "ports": {}}' >"$SS_STATE_DIR/watch.json"   # past the learning run
  printf 'TRUSTED_CIDRS="198.51.100.0/24"\n' >"$SS_CONF_DIR/config.env"
}

# j IDENT MESSAGE [SECONDS_AGO]: one journal entry in `journalctl -o json` form
j() {
  local ts=$(( ( $(date +%s) - ${3:-0} ) * 1000000 ))
  python3 -c 'import json,sys; print(json.dumps({"SYSLOG_IDENTIFIER": sys.argv[1], "MESSAGE": sys.argv[2], "__REALTIME_TIMESTAMP": sys.argv[3], "__CURSOR": "c" + sys.argv[3]}))' "$1" "$2" "$ts" >>"$T/journal"
}
events() { _watch_py list 100 | awk -F'\x1f' '{print $3 "\t" $8}'; }

@test "a login from a new address is important, from a known one it is not" {
  j sshd "Accepted publickey for ops from 203.0.113.5 port 50000 ssh2: ED25519 SHA256:x" 30
  _watch_py once
  [[ $(events) == $'info\tops logged in from 203.0.113.5' ]]
  : >"$T/journal"
  j sshd "Accepted publickey for ops from 192.0.2.77 port 50001 ssh2: ED25519 SHA256:x"
  j sshd-session "Accepted publickey for ops from 203.0.113.5 port 50002 ssh2: ED25519 SHA256:x"
  _watch_py once
  [[ $(events) == *$'important\tops logged in from a new address 192.0.2.77'* ]]
  [ "$(events | grep -c '^important')" -eq 1 ]
}

@test "root, password and after-failure logins are flagged" {
  j sshd "Accepted publickey for root from 203.0.113.9 port 1 ssh2"
  j sshd "Accepted password for dev from 203.0.113.10 port 1 ssh2"
  for i in 1 2 3 4 5 6; do j sshd "Failed password for ops from 192.0.2.66 port $i ssh2"; done
  j sshd "Accepted keyboard-interactive/pam for ops from 192.0.2.66 port 9 ssh2"
  _watch_py once
  run events
  [[ $output == *$'critical\troot logged in over SSH from 203.0.113.9 with a key'* ]]
  [[ $output == *$'important\tdev logged in with a password from 203.0.113.10'* ]]
  [[ $output == *$'critical\tops logged in from 192.0.2.66 right after 6 failed attempts'* ]]
}

@test "password guessing against real accounts is reported once; bot noise is only counted" {
  for i in $(seq 1 12); do j sshd "Failed password for ops from 192.0.2.50 port $i ssh2"; done
  for i in $(seq 1 30); do j sshd "Invalid user admin$i from 192.0.2.99 port $i"; done
  _watch_py once
  : >"$T/journal"; _watch_py once          # a later scan does not report the same address again
  run events
  [ "$(grep -c 'brute' <<<"$(_watch_py list 100 | cut -d$'\x1f' -f4)")" -eq 1 ]
  [[ $output == *"failed logins in an hour from 192.0.2.50 to real account(s): ops"* ]]
  [[ $output != *"192.0.2.99"* ]]
  [[ $(_watch_py summary) == *$'fails\t42'* ]]
}

@test "trusted ranges are never flagged as new or brute force" {
  j sshd "Accepted publickey for ops from 203.0.113.5 port 1 ssh2"
  for i in $(seq 1 12); do j sshd "Failed password for ops from 198.51.100.7 port $i ssh2"; done
  j sshd "Accepted publickey for ops from 198.51.100.7 port 2 ssh2"
  _watch_py once
  [ "$(events | grep -vc '^info')" -eq 0 ]
}

@test "sudo misuse and account changes are important; UID 0 is critical" {
  j sudo "   bob : user NOT in sudoers ; TTY=pts/1 ; PWD=/home/bob ; USER=root ; COMMAND=/bin/bash"
  j sudo "   ops : 3 incorrect password attempts ; TTY=pts/0 ; USER=root ; COMMAND=/bin/ls"
  j useradd "new user: name=eve, UID=1005, GID=1005, home=/home/eve, shell=/bin/bash, from=/dev/pts/0"
  j useradd "new user: name=toor, UID=0, GID=0, home=/root, shell=/bin/bash, from=/dev/pts/0"
  j usermod "add 'eve' to group 'sudo'"
  j usermod "add 'eve' to shadow group 'sudo'"
  _watch_py once
  run events
  [[ $output == *$'important\tbob tried to use sudo without permission'* ]]
  [[ $output == *$'important\tWrong sudo password for ops'* ]]
  [[ $output == *$'important\tNew account eve was created (UID 1005)'* ]]
  [[ $output == *$'critical\tNew account toor was created (UID 0)'* ]]
  [ "$(grep -c 'added to the sudo group' <<<"$output")" -eq 1 ]
}

@test "changes made while server-setup holds its lock are recorded as info" {
  j useradd "new user: name=opsadmin, UID=1001, GID=1001, home=/home/opsadmin, shell=/bin/bash"
  SS_WATCH_ASSUME_SETUP=1 _watch_py once
  [[ $(events) == $'info\tNew account opsadmin was created (UID 1001) (while server-setup was making changes)' ]]
}

@test "the first run only learns: past events never raise alarms" {
  rm "$SS_STATE_DIR/watch.json"
  j sshd "Accepted publickey for root from 203.0.113.9 port 1 ssh2" 60
  _watch_py once
  [ "$(events | grep -vc '^info')" -eq 0 ]
  [[ $(_watch_py summary) == *$'learning\t0'* ]]
}

@test "an added SSH key, sudoers file or preload file is detected; server-setup's own writes are not" {
  printf 'ssh-ed25519 AAAAold ops@laptop\n' >"$T/files/authorized_keys"
  _watch_py once                       # baseline for the new file is "created": establish it first
  : >"$SS_STATE_DIR/events.jsonl"
  printf 'ssh-ed25519 AAAAevil attacker@box\n' >>"$T/files/authorized_keys"
  echo 'eve ALL=(ALL) NOPASSWD:ALL' >"$T/files/sudoers"
  echo /tmp/x.so >"$T/files/ld.so.preload"
  echo managed >"$T/files/sshd_config"
  state_set "managed.$(managed_key "$T/files/sshd_config")" "$(json_str "$(file_hash "$T/files/sshd_config")")"
  _watch_py once
  run events
  [[ $output == *"SSH key added for ?: attacker@box"* ]]
  [[ $output == *$'important\tsudo rules added'* ]]
  [[ $output == *$'critical\t'*"ld.so.preload was created"* ]]
  [[ $output != *sshd_config* ]]
}

@test "a new listening port is reported" {
  printf 'tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n' >"$T/ports"
  _watch_py once
  printf 'tcp LISTEN 0 4096 0.0.0.0:4444 0.0.0.0:* users:(("nc",pid=9,fd=3))\ntcp LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=8,fd=3))\n' >>"$T/ports"
  _watch_py once
  run events
  [[ $output == *$'important\tNew service listening on port 4444/tcp (nc)'* ]]
  [[ $output != *5432* ]]
}

@test "reviewing events clears the login banner" {
  j sshd "Accepted publickey for root from 203.0.113.9 port 1 ssh2"
  j sudo "   bob : user NOT in sudoers ; TTY=pts/1 ; USER=root ; COMMAND=/bin/sh"
  _watch_py once
  grep -q '2 security event(s) need your attention (1 critical)' "$SS_STATE_DIR/watch-banner"
  events_ack 1
  grep -q '1 security event(s)' "$SS_STATE_DIR/watch-banner"
  events_ack all 2
  [ ! -e "$SS_STATE_DIR/watch-banner" ]
  [[ $(_watch_py list 10 | cut -d$'\x1f' -f5 | sort -u) == yes ]]
}

@test "follow mode picks up events as they are written" {
  export SS_JOURNAL_CMD="tail -n +1 -f $T/journal"
  _watch_py follow >"$T/follow.out" 2>&1 3>&- &
  sleep 1
  j sshd "Accepted publickey for root from 203.0.113.9 port 1 ssh2"
  for _ in $(seq 1 30); do grep -q CRITICAL "$T/follow.out" && break; sleep 0.3; done
  pkill -f "$SS_CONF_DIR follow" || true
  pkill -f "tail -n +1 -f $T/journal" || true
  grep -q 'CRITICAL: root logged in over SSH' "$T/follow.out"
}

@test "blocking refuses your own address, local and trusted ones" {
  SSH_CONNECTION="203.0.113.5 50000 10.0.0.1 22"
  run ip_block 203.0.113.5
  [[ $output == *"address you are connected from"* ]]
  run ip_block 127.0.0.1
  [[ $output == *"local address"* ]]
  run ip_block 198.51.100.20
  [[ $output == *"trusted range"* ]]
  run ip_block not-an-ip
  [ "$status" -eq 1 ]
}

@test "locking refuses root, your own account and the last admin" {
  SUDO_USER=ops
  run account_lock root;   [[ $output == *"Root is handled"* ]]
  id nobody >/dev/null
  state_set setup.admins '["nobody"]'
  run account_lock nobody; [[ $output == *"only admin left"* ]]
}
