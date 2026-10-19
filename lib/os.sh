# shellcheck shell=bash
# os.sh: supported-OS gate and server / personal computer / WSL detection.

OS_ID=""; OS_VERSION=""; OS_PRETTY=""; OS_CODENAME=""

os_load() {
  local f=${SS_OS_RELEASE:-/etc/os-release}
  [[ -r $f ]] || die "Cannot read $f."
  OS_ID=$(sed -n 's/^ID=//p' "$f" | tr -d '"')
  OS_VERSION=$(sed -n 's/^VERSION_ID=//p' "$f" | tr -d '"')
  OS_PRETTY=$(sed -n 's/^PRETTY_NAME=//p' "$f" | tr -d '"')
  OS_CODENAME=$(sed -n 's/^VERSION_CODENAME=//p' "$f" | tr -d '"')
}

# Ubuntu 24.04 or newer. Interim (non-LTS) releases run with a warning.
os_require_supported() {
  [[ $OS_ID == ubuntu ]] || die "server-setup supports Ubuntu 24.04 LTS and newer. This is ${OS_PRETTY:-an unknown system}."
  dpkg --compare-versions "${OS_VERSION:-0}" ge 24.04 \
    || die "Ubuntu $OS_VERSION is too old. Upgrade to 24.04 LTS first (sudo do-release-upgrade), then run this again."
  if [[ ! $OS_VERSION =~ ^[0-9]*[02468]\.04$ ]]; then
    warn "Ubuntu $OS_VERSION is an interim release. server-setup is tested on LTS releases."
  fi
}

# detect_machine_type: prints "TYPE<TAB>reason; reason; ..." where TYPE is
# server | personal | wsl | container, with "?" appended when unsure.
# Every probe can be redirected for tests through SS_PROBE_* variables.
detect_machine_type() {
  local virt chassis desktop=0 server=0 reasons=()
  virt=${SS_PROBE_VIRT-$(systemd-detect-virt 2>/dev/null || true)}
  chassis=${SS_PROBE_CHASSIS-$(hostnamectl chassis 2>/dev/null || true)}

  if [[ $virt == wsl ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    printf 'wsl\tWindows Subsystem for Linux\n'; return
  fi
  if [[ $virt =~ ^(lxc|lxc-libvirt|docker|podman|openvz|systemd-nspawn|rkt|container-other)$ ]]; then
    printf 'container\trunning inside a %s container\n' "$virt"; return
  fi

  case $chassis in
    laptop|convertible|tablet|handset) desktop=$((desktop + 3)); reasons+=("chassis is $chassis") ;;
    desktop)                            desktop=$((desktop + 2)); reasons+=("chassis is desktop") ;;
    server)                             server=$((server + 3));   reasons+=("chassis is server") ;;
    vm)                                 server=$((server + 1));   reasons+=("virtual machine") ;;
  esac

  local has_desktop_pkg=${SS_PROBE_DESKTOP_PKG-$(dpkg-query -W -f='${Status}\n' ubuntu-desktop ubuntu-desktop-minimal 2>/dev/null | grep -c 'install ok installed' || true)}
  if (( has_desktop_pkg > 0 )); then desktop=$((desktop + 2)); reasons+=("Ubuntu Desktop is installed"); fi

  local target=${SS_PROBE_TARGET-$(systemctl get-default 2>/dev/null || true)}
  if [[ $target == graphical.target ]]; then desktop=$((desktop + 1)); reasons+=("starts a graphical desktop")
  elif [[ $target == multi-user.target ]]; then server=$((server + 1)); reasons+=("starts without a desktop"); fi

  local battery=${SS_PROBE_BATTERY-$(compgen -G '/sys/class/power_supply/BAT*' >/dev/null && echo 1 || echo 0)}
  if (( battery )); then desktop=$((desktop + 2)); reasons+=("has a battery"); fi

  local cloud=${SS_PROBE_CLOUD-$(cloud_vendor)}
  if [[ -n $cloud ]]; then server=$((server + 3)); reasons+=("runs on $cloud"); fi

  if [[ -n ${SS_PROBE_SSH-${SSH_CONNECTION:-}} ]]; then server=$((server + 1)); reasons+=("you are connected over SSH"); fi

  local type sure=""
  if (( desktop > server )); then type=personal; else type=server; fi
  local gap=$(( desktop - server ))
  (( gap < 0 )) && gap=$(( -gap ))
  if (( gap < 2 )); then sure="?"; fi
  local IFS=';'
  printf '%s%s\t%s\n' "$type" "$sure" "${reasons[*]:-no clear signals}"
}

# Cloud provider from DMI data (no network calls).
cloud_vendor() {
  local v
  v=$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_vendor 2>/dev/null | tr '\n' ' ')
  case ${v,,} in
    *amazon*|*ec2*)          echo "AWS" ;;
    *google*)                echo "Google Cloud" ;;
    *microsoft*|*hyper-v*)   echo "Azure" ;;
    *digitalocean*)          echo "DigitalOcean" ;;
    *hetzner*)               echo "Hetzner" ;;
    *linode*|*akamai*)       echo "Linode" ;;
    *vultr*)                 echo "Vultr" ;;
    *ovh*)                   echo "OVHcloud" ;;
    *openstack*)             echo "OpenStack" ;;
    *oracle*)                echo "Oracle Cloud" ;;
    *) [[ -d /var/lib/cloud/instance ]] && echo "a cloud provider" ;;
  esac
  return 0
}
