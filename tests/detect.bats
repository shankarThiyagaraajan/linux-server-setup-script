#!/usr/bin/env bats
load helper

setup() {
  load_libs
  export SS_PROBE_VIRT="" SS_PROBE_CHASSIS="" SS_PROBE_DESKTOP_PKG=0 SS_PROBE_TARGET="" \
         SS_PROBE_BATTERY=0 SS_PROBE_CLOUD="" SS_PROBE_SSH=""
}

type_of() { detect_machine_type | cut -f1; }

@test "a cloud VM without a desktop is a server" {
  SS_PROBE_CHASSIS=vm SS_PROBE_CLOUD=AWS SS_PROBE_TARGET=multi-user.target
  [ "$(type_of)" = server ]
}

@test "a laptop with Ubuntu Desktop is personal" {
  SS_PROBE_CHASSIS=laptop SS_PROBE_DESKTOP_PKG=1 SS_PROBE_TARGET=graphical.target SS_PROBE_BATTERY=1
  [ "$(type_of)" = personal ]
  [[ $(detect_machine_type) == *"has a battery"* ]]
}

@test "mixed signals are marked unsure" {
  SS_PROBE_CHASSIS=vm SS_PROBE_TARGET=graphical.target
  [ "$(type_of)" = "server?" ]
}

@test "containers and WSL are recognised" {
  SS_PROBE_VIRT=docker; [ "$(type_of)" = container ]
  SS_PROBE_VIRT=wsl;    [ "$(type_of)" = wsl ]
}

@test "only Ubuntu 24.04 and newer is supported" {
  printf 'ID=ubuntu\nVERSION_ID="22.04"\n' >"$T/old"
  SS_OS_RELEASE=$T/old os_load
  run os_require_supported
  [ "$status" -eq 3 ]
  printf 'ID=debian\nVERSION_ID="12"\n' >"$T/deb"
  SS_OS_RELEASE=$T/deb os_load
  run os_require_supported
  [ "$status" -eq 3 ]
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$T/lts"
  SS_OS_RELEASE=$T/lts os_load
  run os_require_supported
  [ "$status" -eq 0 ]
  printf 'ID=ubuntu\nVERSION_ID="25.10"\n' >"$T/int"
  SS_OS_RELEASE=$T/int os_load
  run os_require_supported
  [ "$status" -eq 0 ]
  [[ $output == *"interim"* ]]
}
