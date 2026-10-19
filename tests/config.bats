#!/usr/bin/env bats
load helper

setup() { load_libs; cfg_reset; CFG[MACHINE_TYPE]=server; CFG[ADMIN_USERS]=ops; }

@test "defaults are valid for a server with an admin" {
  run cfg_validate
  [ "$status" -eq 0 ]
}

@test "every problem is reported together" {
  CFG[SSH_PORT]=070000; CFG[OPEN_PORTS]="80/tcp 99999 22/icmp"; CFG[TRUSTED_CIDRS]="10.0.0.0/33"
  CFG[REBOOT_TIME]="25:00"; CFG[AUTO_REBOOT]=maybe; CFG[ADMIN_USERS]="root Bad"
  run cfg_validate
  [ "$status" -eq 1 ]
  [[ $output == *"SSH_PORT"* && $output == *"invalid port: 99999"* && $output == *"22/icmp"* ]]
  [[ $output == *"10.0.0.0/33"* && $output == *"REBOOT_TIME"* && $output == *"AUTO_REBOOT"* ]]
  [[ $output == *"invalid user name: root"* && $output == *"invalid user name: Bad"* ]]
}

@test "a server needs an admin" {
  CFG[ADMIN_USERS]=""
  run cfg_validate
  [[ $output == *"ADMIN_USERS is required"* ]]
}

@test "validators" {
  valid_port 22; valid_port 65535; ! valid_port 0; ! valid_port 65536; ! valid_port 022
  valid_portspec 80; valid_portspec 443/tcp; valid_portspec 6000:6007/udp
  ! valid_portspec 6000:6007; ! valid_portspec 7000:6000/tcp; ! valid_portspec 80/sctp
  valid_cidr 203.0.113.7; valid_cidr 203.0.113.0/24; valid_cidr 2001:db8::/32
  ! valid_cidr 256.1.1.1; ! valid_cidr 1.2.3.4/40; ! valid_cidr example.com
  valid_hash ''; valid_hash "$(openssl passwd -6 x)"; ! valid_hash plaintext
  valid_timezone ''; ! valid_timezone '../../etc/passwd'
}

@test "config file is parsed, never executed" {
  cat >"$T/c.env" <<'CFG'
# comment
PROFILE="web"
SSH_PORT='2222'
OPEN_PORTS="$(touch /tmp/ss-pwned) 80/tcp"
CFG
  cfg_load "$T/c.env"
  [ "${CFG[PROFILE]}" = web ]
  [ "${CFG[SSH_PORT]}" = 2222 ]
  [ ! -e /tmp/ss-pwned ]
  run cfg_validate
  [ "$status" -eq 1 ]
}

@test "unknown keys and malformed lines are refused" {
  printf 'PROFILE=web\nEVIL=1\n' >"$T/u.env"
  run cfg_load "$T/u.env"
  [ "$status" -eq 3 ]
  [[ $output == *"unknown setting EVIL"* ]]
  printf 'export PROFILE=web\n' >"$T/m.env"
  run cfg_load "$T/m.env"
  [ "$status" -eq 3 ]
}

@test "saved config omits secrets and is private" {
  CFG[ADMIN_PASSWORD_HASH]='$6$abc$def'; CFG[ADMIN_PUBKEY]="ssh-ed25519 AAAA"
  cfg_save "$T/saved.env"
  ! grep -q ADMIN_PASSWORD_HASH "$T/saved.env"
  ! grep -q ADMIN_PUBKEY "$T/saved.env"
  [ "$(stat -c %a "$T/saved.env")" = 600 ]
  cfg_reset; cfg_load "$T/saved.env"
  [ "${CFG[ADMIN_USERS]}" = ops ]
}
