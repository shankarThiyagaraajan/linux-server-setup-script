#!/usr/bin/env bats
load helper

setup() {
  load_libs
  cfg_reset
  sshd_effective() { printf '%s\n' "${FAKE_EFF:-port 22}"; }
}

@test "public keys are accepted and private keys refused" {
  command -v ssh-keygen || skip "ssh-keygen not installed"
  ssh-keygen -q -t ed25519 -N '' -f "$T/k"
  validate_pubkeys "$(cat "$T/k.pub")"
  run validate_pubkeys "$(cat "$T/k")"
  [ "$status" -eq 1 ]
  [[ $output == *"PRIVATE key"* ]]
  run validate_pubkeys "hello world"
  [ "$status" -eq 1 ]
}

@test "the drop-in locks SSH down and lists every port" {
  CFG[SSH_FORWARDING]=no
  out=$(ssh_render 22 2222)
  grep -qx 'Port 22' <<<"$out"
  grep -qx 'Port 2222' <<<"$out"
  grep -qx 'PermitRootLogin no' <<<"$out"
  grep -qx 'PasswordAuthentication no' <<<"$out"
  grep -qx 'AllowGroups ssh-users' <<<"$out"
  grep -qx 'AuthenticationMethods publickey' <<<"$out"
  grep -qx 'AllowTcpForwarding no' <<<"$out"
}

@test "an existing multi-factor login is kept" {
  FAKE_EFF=$'port 22\nauthenticationmethods publickey,keyboard-interactive'
  out=$(ssh_render 22)
  grep -qx 'AuthenticationMethods publickey,keyboard-interactive' <<<"$out"
  grep -qx 'KbdInteractiveAuthentication yes' <<<"$out"
}

@test "the rendered drop-in passes sshd -t" {
  command -v sshd || skip "openssh-server not installed"
  [[ $EUID -eq 0 ]] || skip "needs root"
  ssh-keygen -q -t ed25519 -N '' -f "$T/hostkey"
  { ssh_render 2222; printf 'HostKey %s\n' "$T/hostkey"; } >"$T/sshd_config"
  mkdir -p /run/sshd
  sshd -t -f "$T/sshd_config"
}
