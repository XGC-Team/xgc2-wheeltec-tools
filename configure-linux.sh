#!/usr/bin/env bash
# Wheeltec mecanum Linux bring-up: apt + standalone roscore + serial chassis + swarm_ros_bridge.
#
# IMU rides with wheeltec_robot_node (/imu). Field IPs and ros_topics.yaml
# peers belong to configure-network.sh.
#
# Does not touch NetworkManager. Does not rewrite ros_topics.yaml.
# Does not enable lidar / camera. Does not rewrite L4T / NVIDIA apt.
# Does not send /cmd_vel. Wireless hint is read-only (no ifup, no ping, no NM).
# USB Wi-Fi is often named wlan0 on this image; classify by bus, not iface name.
# Field cars differ (old debs, broken L4T apt, leftover vendor su -). Fix this
# script and re-run it; do not leave unreproducible one-off commands on the car.
#
# Usage:
#   sudo bash configure-linux.sh --yes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
xgc2_load_site() {
  local f="${XGC2_SITE_ENV:-}"
  if [[ -z "${f}" ]]; then
    if [[ -f "${SCRIPT_DIR}/../site.env" ]]; then
      f="${SCRIPT_DIR}/../site.env"
    elif [[ -f "${HOME}/Documents/XGC/UserScripts/site.env" ]]; then
      f="${HOME}/Documents/XGC/UserScripts/site.env"
    fi
  fi
  if [[ -n "${f}" && -f "${f}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${f}"
    set +a
  fi
}
xgc2_load_site

APT_BASE_URL="${APT_BASE_URL:-${XGC2_APT_BASE_URL:-}}"
XGC2_KEY_FPR="2A8E11B36F56D307ADF626D85E5FDC30979EA43F"
ROS_KEY_FPR="C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654"
CONTROLLER_DEVICE="${CONTROLLER_DEVICE:-/dev/wheeltec_controller}"
ONBOARD_ENV="${ONBOARD_ENV:-/etc/xgc2/wheeltec/onboard.env}"
ROSCORE_UNIT="xgc2-wheeltec-roscore.service"
CHASSIS_UNIT="xgc2-wheeltec-chassis.service"
BRIDGE_UNIT="xgc2-wheeltec-swarm-ros-bridge.service"
LIDAR_UNIT="xgc2-wheeltec-lidar.service"
TOPIC_CHECK_SECONDS="${TOPIC_CHECK_SECONDS:-90}"

MANAGED_APT_LISTS=(
  ros-latest.list
  xgc2.list
)

YES=0
SKIP_ROS_SOURCE=0
SKIP_QUARANTINE_SOURCES=0
SKIP_TOPIC_CHECK=0
SKIP_CONTROLLER=0
SKIP_WIRELESS_HINT=0
REWRITE_UBUNTU_MIRROR=0

usage() {
  cat <<'EOF'
Usage: configure-linux.sh --yes [options]

Install standalone ROS master + serial chassis + swarm_ros_bridge (IMU is on the chassis node).
Does not change the network and does not write ros_topics.yaml.

Options:
  --yes                     required; refuse to run without it
  --apt-url URL             from site.env XGC2_APT_BASE_URL; no in-script default
  --skip-ros-source         do not repair ROS apt key/source
  --skip-quarantine-sources do not move aside foreign/broken apt lists
  --skip-topic-check        do not fail when /imu or /PowerVoltage missing
  --skip-controller         do not fail when /dev/wheeltec_controller is missing
  --skip-wireless-hint      do not print the multi-NIC / onboard-Wi-Fi warning
  --rewrite-ubuntu-mirror   rewrite /etc/apt/sources.list (never the default on L4T)
  --topic-check-seconds N   default 90
  -h, --help                show this help

Exit codes:
  0  standalone roscore + chassis + bridge enabled and (unless skipped) topics seen
  1  configuration / apt / service / topic-check failure
EOF
}

log() { printf '+ %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --apt-url) APT_BASE_URL="${2:?}"; shift 2 ;;
    --skip-ros-source) SKIP_ROS_SOURCE=1; shift ;;
    --skip-quarantine-sources) SKIP_QUARANTINE_SOURCES=1; shift ;;
    --skip-topic-check) SKIP_TOPIC_CHECK=1; shift ;;
    --skip-controller) SKIP_CONTROLLER=1; shift ;;
    --skip-wireless-hint) SKIP_WIRELESS_HINT=1; shift ;;
    --rewrite-ubuntu-mirror) REWRITE_UBUNTU_MIRROR=1; shift ;;
    --topic-check-seconds) TOPIC_CHECK_SECONDS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --site-env) export XGC2_SITE_ENV="${2:?}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done


xgc2_load_site
APT_BASE_URL="${APT_BASE_URL:-${XGC2_APT_BASE_URL:-}}"
if [[ "${SELF_TEST:-0}" -eq 0 && -z "${APT_BASE_URL}" ]]; then
  die "need --apt-url or site.env XGC2_APT_BASE_URL"
fi

[[ "${YES}" -eq 1 ]] || die "refusing to run without --yes (see --help)"
require_root
need_cmd curl
need_cmd gpg
need_cmd apt-get
need_cmd systemctl
need_cmd dpkg
need_cmd install

ARCH="$(dpkg --print-architecture)"
# shellcheck disable=SC1091  # vehicle image contract
. /etc/os-release
APT_SUITE="${VERSION_CODENAME:-}"
case "${APT_SUITE}" in
  bionic) ROS_DISTRO="melodic" ;;
  *) die "unsupported Ubuntu ${APT_SUITE:-unknown}; Wheeltec product is Jetson Nano / Bionic / Melodic" ;;
esac
[[ "${ARCH}" == "arm64" ]] || warn "expected arm64 vehicle computer, got ${ARCH}"

# Read-only. Never ifup, never nmcli, never ping.
iface_kind() {
  local iface="$1"
  local dev path alias
  dev="/sys/class/net/${iface}/device"
  if [[ ! -e "${dev}" ]]; then
    printf 'unknown'
    return
  fi
  path="$(readlink -f "${dev}" 2>/dev/null || true)"
  alias="$(cat "${dev}/modalias" 2>/dev/null || true)"
  case "${alias}" in
    usb:*) printf 'usb'; return ;;
    pci:*|pcix:*) printf 'pci-onboard'; return ;;
  esac
  case "${path}" in
    *usb*) printf 'usb' ;;
    *pci*) printf 'pci-onboard' ;;
    *) printf 'other' ;;
  esac
}

iface_driver() {
  local iface="$1"
  awk -F= '$1 == "DRIVER" { print $2; exit }' \
    "/sys/class/net/${iface}/device/uevent" 2>/dev/null
}

is_wireless() {
  [[ -d "/sys/class/net/$1/wireless" ]]
}

default_route_ifaces() {
  ip -4 route show default 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1) }' \
    | awk 'NF && !seen[$0]++'
}

ssh_local_ip() {
  local raw="${SSH_CONNECTION:-}"
  [[ -n "${raw}" ]] || return 0
  # client_ip client_port server_ip server_port
  awk '{ print $3 }' <<<"${raw}"
}

iface_has_ipv4() {
  local iface="$1" want="$2"
  ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{ print $4 }' \
    | awk -F/ -v want="${want}" '$1 == want { found = 1 } END { exit !found }'
}

usb_wifi_blocklist_hits() {
  command -v lsusb >/dev/null 2>&1 || return 0
  # Windows "免驱" Realtek: first a USB disk, then RTL8822CU. Not a usable NIC
  # on Nano / Xavier 18.04. Swap for a known RTL88x2BU (0bda:b812 / 0bda:b82c).
  lsusb 2>/dev/null | awk '
    /0bda:1a2b/ { print "0bda:1a2b (USB DISK / Windows no-driver dongle, not a NIC yet)" }
    /0bda:c812/ { print "0bda:c812 (RTL8822CU after mode-switch; no in-tree driver here)" }
  '
}

warn_wireless() {
  [[ "${SKIP_WIRELESS_HINT}" -eq 0 ]] || { log "skip wireless hint"; return; }
  local iface kind driver addr route_ifaces ssh_ip ssh_iface=""
  local -a wifi=()
  local usb_wifi=0 onboard_wifi=0 onboard_is_path=0 usb_is_path=0
  local hit

  shopt -s nullglob
  for iface in /sys/class/net/*; do
    iface="${iface##*/}"
    [[ "${iface}" == lo ]] && continue
    is_wireless "${iface}" || continue
    wifi+=("${iface}")
  done
  shopt -u nullglob

  log "wireless: Wheeltec has a poor onboard radio; onboard Wi-Fi is not a usable SSH / GCS path. USB is often wlan0"
  if [[ "${#wifi[@]}" -eq 0 ]]; then
    warn "no wireless interfaces in sysfs; confirm a USB NIC is plugged in (do not use the onboard card)"
  fi
  printf '+ %-8s %-12s %-16s %s\n' "iface" "kind" "ipv4" "driver"
  for iface in "${wifi[@]}"; do
    kind="$(iface_kind "${iface}")"
    driver="$(iface_driver "${iface}")"
    addr="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{ print $4 }' | head -n1)"
    printf '+ %-8s %-12s %-16s %s\n' "${iface}" "${kind}" "${addr:-down}" "${driver:-?}"
    case "${kind}" in
      usb) usb_wifi=1 ;;
      pci-onboard) onboard_wifi=1 ;;
    esac
  done

  route_ifaces="$(default_route_ifaces | tr '\n' ' ')"
  [[ -n "${route_ifaces}" ]] && log "default route via: ${route_ifaces}"
  ssh_ip="$(ssh_local_ip || true)"
  if [[ -n "${ssh_ip}" ]]; then
    for iface in "${wifi[@]}"; do
      if iface_has_ipv4 "${iface}" "${ssh_ip}"; then
        ssh_iface="${iface}"
        break
      fi
    done
    if [[ -n "${ssh_iface}" ]]; then
      log "this SSH session is on ${ssh_iface} (${ssh_ip}) kind=$(iface_kind "${ssh_iface}")"
    else
      log "this SSH session local IP is ${ssh_ip} (not on a wireless iface listed above)"
    fi
  fi

  for iface in ${route_ifaces}; do
    is_wireless "${iface}" || continue
    if [[ "$(iface_kind "${iface}")" == "pci-onboard" ]]; then
      onboard_is_path=1
    fi
    if [[ "$(iface_kind "${iface}")" == "usb" ]]; then
      usb_is_path=1
    fi
  done
  if [[ -n "${ssh_iface}" && "$(iface_kind "${ssh_iface}")" == "pci-onboard" ]]; then
    onboard_is_path=1
  fi
  if [[ -n "${ssh_iface}" && "$(iface_kind "${ssh_iface}")" == "usb" ]]; then
    usb_is_path=1
  fi

  if [[ "${onboard_wifi}" -eq 1 ]]; then
    warn "onboard / native Wi-Fi is a bad radio. USB is often named wlan0 here; use the USB card, not the onboard one"
  fi
  if [[ "${onboard_is_path}" -eq 1 ]]; then
    warn "SSH or the default route is on the onboard card. Plug a USB RTL88x2BU and move the session; this script will not change NetworkManager"
  fi
  if [[ "${usb_wifi}" -eq 0 ]]; then
    warn "no USB Wi-Fi in sysfs. Plug a known-good USB NIC before relying on centralized experiment UDP. Do not compile a driver for the onboard card"
  elif [[ "${usb_is_path}" -eq 0 && "${onboard_is_path}" -eq 0 ]]; then
    warn "USB Wi-Fi is present but is not the SSH / default-route path. Confirm the usable card owns the address before you trust the GCS link"
  fi
  if [[ "${usb_is_path}" -eq 1 ]]; then
    log "USB Wi-Fi is carrying SSH or the default route; keep using that card"
  fi

  while read -r hit; do
    [[ -z "${hit}" ]] && continue
    warn "USB Wi-Fi blocklist: ${hit}. Swap the dongle. Do not build rtl8822cu / rtw88 on this image"
  done < <(usb_wifi_blocklist_hits)

  log "wireless hint is read-only: no ifup, no nmcli, no ping"
}

stamp="$(date +%Y%m%d-%H%M%S)"
QUARANTINE_DIR="/var/backups/xgc2-wheeltec-apt-${stamp}"

backup() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${path}.bak-${stamp}"
    log "backup ${path} -> ${path}.bak-${stamp}"
  fi
}

fingerprint_of() {
  local file="$1"
  if gpg --help 2>&1 | grep -q -- '--show-keys'; then
    gpg --show-keys --with-fingerprint --with-colons "${file}" 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10; exit }'
    return 0
  fi
  local home
  home="$(mktemp -d)"
  gpg --homedir "${home}" --batch --import "${file}" >/dev/null 2>&1 || true
  gpg --homedir "${home}" --with-colons --fingerprint 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }'
  rm -rf "${home}"
}

is_managed_apt_list() {
  local base="$1"
  local m
  for m in "${MANAGED_APT_LISTS[@]}"; do
    [[ "${base}" == "${m}" ]] && return 0
  done
  return 1
}

is_protected_apt_list() {
  local base="$1"
  case "${base}" in
    nvidia*|*"tegra"*|*"cuda"*|*"jetson"*) return 0 ;;
  esac
  return 1
}

quarantine_path() {
  local path="$1"
  local base
  base="$(basename -- "${path}")"
  is_protected_apt_list "${base}" && { warn "keep L4T/NVIDIA list ${base}"; return 0; }
  mkdir -p "${QUARANTINE_DIR}"
  mv -f -- "${path}" "${QUARANTINE_DIR}/${base}"
  log "quarantine ${path} -> ${QUARANTINE_DIR}/${base}"
}

fetch_ros_asc() {
  local dest="$1" url
  for url in \
    "https://mirrors.tuna.tsinghua.edu.cn/rosdistro/ros.asc" \
    "http://mirrors.tuna.tsinghua.edu.cn/rosdistro/ros.asc" \
    "https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc"
  do
    if curl -fsSL --connect-timeout 8 --max-time 45 "${url}" -o "${dest}"; then
      log "fetched ROS apt key from ${url}"
      return 0
    fi
  done
  return 1
}

configure_ros_source() {
  [[ "${SKIP_ROS_SOURCE}" -eq 0 ]] || { log "skip ROS source"; return; }
  local keyring=/usr/share/keyrings/ros-archive-keyring.gpg
  local list=/etc/apt/sources.list.d/ros-latest.list
  local asc
  asc="$(mktemp /tmp/ros.asc.XXXXXX)"
  fetch_ros_asc "${asc}" || die "could not download ROS apt signing key"
  local fpr
  fpr="$(fingerprint_of "${asc}")"
  [[ "${fpr}" == "${ROS_KEY_FPR}" ]] || die "ROS apt key fingerprint mismatch: ${fpr:-empty}"
  gpg --dearmor --yes -o /tmp/ros-archive-keyring.gpg "${asc}"
  install -d -m 0755 /usr/share/keyrings
  install -m 0644 /tmp/ros-archive-keyring.gpg "${keyring}"
  backup "${list}"
  local stale base
  shopt -s nullglob
  for stale in /etc/apt/sources.list.d/*ros*.list /etc/apt/sources.list.d/*ros*.sources; do
    base="$(basename -- "${stale}")"
    [[ "${base}" == "ros-latest.list" ]] && continue
    [[ "${base}" == *.bak-* ]] && continue
    quarantine_path "${stale}"
  done
  shopt -u nullglob
  printf 'deb [arch=%s signed-by=%s] http://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu %s main\n' \
    "${ARCH}" "${keyring}" "${APT_SUITE}" >"${list}"
  rm -f "${asc}" /tmp/ros-archive-keyring.gpg
  log "wrote ROS ${ROS_DISTRO} source with signed-by keyring"
}

configure_xgc2_source() {
  local key_url="${APT_BASE_URL%/}/xgc2-archive-keyring.gpg"
  local key_file
  key_file="$(mktemp /tmp/xgc2-archive-keyring.XXXXXX)"
  curl -fsSL --connect-timeout 10 --max-time 60 "${key_url}" -o "${key_file}" \
    || die "could not download XGC2 apt key from ${key_url}"
  local fpr
  fpr="$(fingerprint_of "${key_file}")"
  [[ "${fpr}" == "${XGC2_KEY_FPR}" ]] || die "XGC2 apt key fingerprint mismatch: ${fpr:-empty}"
  install -d -m 0755 /etc/apt/keyrings
  install -m 0644 "${key_file}" /etc/apt/keyrings/xgc2-archive-keyring.gpg
  rm -f "${key_file}"
  local stale base
  shopt -s nullglob
  for stale in /etc/apt/sources.list.d/*xgc2*.list /etc/apt/sources.list.d/*xgc2*.sources; do
    base="$(basename -- "${stale}")"
    [[ "${base}" == "xgc2.list" ]] && continue
    [[ "${base}" == *.bak-* ]] && continue
    quarantine_path "${stale}"
  done
  shopt -u nullglob
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/xgc2-archive-keyring.gpg] %s %s main\n' \
    "${ARCH}" "${APT_BASE_URL%/}" "${APT_SUITE}" \
    >/etc/apt/sources.list.d/xgc2.list
  log "wrote /etc/apt/sources.list.d/xgc2.list (${APT_BASE_URL%/} ${APT_SUITE})"
}

quarantine_matching_update_log() {
  local logf="$1"
  local quarantined=0 path base host
  local -a hosts=()
  while read -r host; do
    [[ -n "${host}" ]] || continue
    hosts+=("${host}")
  done < <(sed -nE 's/.*GPG error: https?:\/\/([^/ ]+).*/\1/p; s/.*Failed to fetch https?:\/\/([^/ ]+).*/\1/p' "${logf}" | sort -u)
  [[ ${#hosts[@]} -gt 0 ]] || return 1
  shopt -s nullglob
  for path in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    base="$(basename -- "${path}")"
    is_managed_apt_list "${base}" && continue
    is_protected_apt_list "${base}" && continue
    for host in "${hosts[@]}"; do
      if grep -Fq "${host}" "${path}" 2>/dev/null; then
        quarantine_path "${path}"
        quarantined=1
        break
      fi
    done
  done
  shopt -u nullglob
  [[ "${quarantined}" -eq 1 ]]
}

apt_update_resilient() {
  local attempt=1
  local max_attempts=8
  local logf
  while [[ "${attempt}" -le "${max_attempts}" ]]; do
    logf="$(mktemp /tmp/apt-update.XXXXXX)"
    log "apt-get update (attempt ${attempt}/${max_attempts})"
    if apt-get update 2>"${logf}"; then
      cat "${logf}" >&2 || true
      if grep -Eq 'NO_PUBKEY|GPG error:' "${logf}"; then
        if [[ "${SKIP_QUARANTINE_SOURCES}" -eq 0 ]] && quarantine_matching_update_log "${logf}"; then
          rm -f "${logf}"
          attempt=$((attempt + 1))
          continue
        fi
        warn "apt-get update GPG warning left in place (unrelated TeamViewer/NVIDIA keys must not block XGC2)"
      fi
      rm -f "${logf}"
      return 0
    fi
    cat "${logf}" >&2 || true
    if [[ "${SKIP_QUARANTINE_SOURCES}" -ne 0 ]]; then
      rm -f "${logf}"
      die "apt-get update failed and --skip-quarantine-sources is set"
    fi
    local bad host quarantined=0 path base
    bad="$(
      sed -n "s/.*The repository '\\([^']*\\)'.*/\\1/p;s/.*Failed to fetch \\([^ ]*\\).*/\\1/p" "${logf}" \
        | head -n1 || true
    )"
    rm -f "${logf}"
    host="$(printf '%s' "${bad}" | sed -E 's#^[a-zA-Z]+://##' | cut -d/ -f1)"
    shopt -s nullglob
    for path in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
      base="$(basename -- "${path}")"
      is_managed_apt_list "${base}" && continue
      is_protected_apt_list "${base}" && continue
      if [[ -n "${bad}" ]]; then
        if grep -Fq "${bad}" "${path}" 2>/dev/null \
          || { [[ -n "${host}" ]] && grep -Fq "${host}" "${path}" 2>/dev/null; }; then
          quarantine_path "${path}"
          quarantined=1
          break
        fi
        continue
      fi
      quarantine_path "${path}"
      quarantined=1
      break
    done
    shopt -u nullglob
    [[ "${quarantined}" -eq 1 ]] || die "apt-get update failed; no foreign list left to quarantine"
    attempt=$((attempt + 1))
  done
  die "apt-get update still failing after quarantining foreign sources"
}

package_installed() {
  dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

install_stack() {
  local -a pkgs=(
    "ros-melodic-xgc2-wheeltec-onboard"
  )
  local pkg
  apt_update_resilient
  log "apt-get install -y --no-install-recommends ${pkgs[*]}"
  # Unrelated broken nvidia-l4t / TeamViewer packages make apt-get return 100
  # even after our debs unpack. Upgrade still happens; we only require our pkgs.
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "${pkgs[@]}"; then
    warn "apt-get install exited non-zero (often unrelated nvidia-l4t / TeamViewer); checking product packages"
  fi
  for pkg in "${pkgs[@]}"; do
    package_installed "${pkg}" || die "package missing after install: ${pkg}"
  done
  package_installed "ros-melodic-swarm-ros-bridge" \
    || die "official ros-melodic-swarm-ros-bridge missing (needed by the vehicle peer)"
  test -f /lib/systemd/system/"${ROSCORE_UNIT}" \
    || die "missing ${ROSCORE_UNIT}; need ros-melodic-xgc2-wheeltec-onboard >= 0.1.0-10 (standalone ROS master; do not let chassis own it)"
  test -f /lib/systemd/system/"${CHASSIS_UNIT}" || die "missing ${CHASSIS_UNIT}"
  test -f /lib/systemd/system/"${BRIDGE_UNIT}" || die "missing ${BRIDGE_UNIT}"
  log "product $(dpkg-query -W -f '${Package} ${Version}' ros-melodic-xgc2-wheeltec-onboard)"
}

reap_vendor_leftovers() {
  # Vendor ExecStart is `su - wheeltec` / a sleep wrapper. systemctl stop does
  # not reap the grandchild roslaunch, which keeps the serial ACM wedged.
  local pattern
  local -a patterns=(
    'roslaunch turn_on_wheeltec_robot turn_on_wheeltec_robot.launch'
    'roslaunch swarm_ros_bridge test.launch'
    '/home/wheeltec/ugv-auto-launch/turn_on_wheeltec_robot.sh'
    '/home/wheeltec/ugv-auto-launch/swarm_ros_bridge.sh'
    '/home/wheeltec/wheeltec_robot/devel/lib/turn_on_wheeltec_robot/wheeltec_robot_node'
  )
  for pattern in "${patterns[@]}"; do
    if pgrep -f "${pattern}" >/dev/null 2>&1; then
      log "TERM leftover vendor: ${pattern}"
      pkill -TERM -f "${pattern}" >/dev/null 2>&1 || true
    fi
  done
  sleep 2
  for pattern in "${patterns[@]}"; do
    if pgrep -f "${pattern}" >/dev/null 2>&1; then
      log "KILL leftover vendor: ${pattern}"
      pkill -KILL -f "${pattern}" >/dev/null 2>&1 || true
    fi
  done
}

reset_controller_usb() {
  local real sys iface usb vendor product
  [[ -e "${CONTROLLER_DEVICE}" ]] || { warn "no ${CONTROLLER_DEVICE} to reset"; return 0; }
  real="$(readlink -f "${CONTROLLER_DEVICE}")"
  sys="/sys/class/tty/${real##*/}/device"
  iface="$(readlink -f "${sys}" 2>/dev/null || true)"
  [[ -n "${iface}" && -e "${iface}" ]] || { warn "no sysfs for ${CONTROLLER_DEVICE}"; return 0; }
  usb="$(dirname "${iface}")"
  vendor="$(cat "${usb}/idVendor" 2>/dev/null || true)"
  product="$(cat "${usb}/idProduct" 2>/dev/null || true)"
  if [[ "${vendor}" != "1a86" || "${product}" != "55d4" ]]; then
    warn "refusing USB reset of ${usb} (${vendor:-?}:${product:-?}); expected WCH 1a86:55d4"
    return 0
  fi
  [[ -w "${usb}/authorized" ]] || { warn "cannot write ${usb}/authorized"; return 0; }
  log "USB reset controller ${usb} (1a86:55d4)"
  printf '0\n' >"${usb}/authorized"
  sleep 1
  printf '1\n' >"${usb}/authorized"
}

wait_controller_openable() {
  local timeout="${1:-30}"
  local py
  py="$(command -v python3 || command -v python || true)"
  [[ -n "${py}" ]] || die "python required to wait for ${CONTROLLER_DEVICE}"
  log "wait until ${CONTROLLER_DEVICE} is openable (${timeout}s)"
  "${py}" - "${CONTROLLER_DEVICE}" "${timeout}" <<'PY'
import os
import sys
import time

path, timeout = sys.argv[1], float(sys.argv[2])
deadline = time.time() + timeout
while time.time() < deadline:
    try:
        fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        os.close(fd)
        sys.exit(0)
    except OSError:
        time.sleep(0.2)
sys.stderr.write("device not openable: %s\n" % path)
sys.exit(1)
PY
}

disable_vendor_units() {
  local unit
  for unit in \
    turn_on_wheeltec_robot.service \
    swarm_ros_bridge.service \
    teststartup.service \
    roscore.service
  do
    if systemctl cat "${unit}" >/dev/null 2>&1; then
      log "stop/disable vendor ${unit}"
      systemctl stop "${unit}" >/dev/null 2>&1 || true
      systemctl disable "${unit}" >/dev/null 2>&1 || true
    fi
  done
  reap_vendor_leftovers
  if systemctl cat "${LIDAR_UNIT}" >/dev/null 2>&1; then
    if systemctl is-enabled --quiet "${LIDAR_UNIT}" 2>/dev/null; then
      warn "${LIDAR_UNIT} is enabled; leaving it (this command does not own lidar)"
    else
      log "leave disabled: ${LIDAR_UNIT}"
    fi
  fi
}

wait_ros_master() {
  local seconds="${1:-30}"
  local deadline=$((SECONDS + seconds))
  while (( SECONDS < deadline )); do
    if ss -ltn 2>/dev/null | grep -Eq ':11311[[:space:]]'; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

pin_onboard_env() {
  [[ -f "${ONBOARD_ENV}" ]] || die "missing ${ONBOARD_ENV} after package install"
  if grep -q '^ROS_MASTER_URI=' "${ONBOARD_ENV}"; then
    sed -i 's|^ROS_MASTER_URI=.*|ROS_MASTER_URI=http://127.0.0.1:11311|' "${ONBOARD_ENV}"
  else
    printf 'ROS_MASTER_URI=http://127.0.0.1:11311\n' >>"${ONBOARD_ENV}"
  fi
  if grep -q '^ROS_IP=' "${ONBOARD_ENV}"; then
    sed -i 's|^ROS_IP=.*|ROS_IP=127.0.0.1|' "${ONBOARD_ENV}"
  else
    printf 'ROS_IP=127.0.0.1\n' >>"${ONBOARD_ENV}"
  fi
  log "pin ROS_MASTER_URI loopback and ROS_IP=127.0.0.1 in ${ONBOARD_ENV}"
}

enable_comm_stack() {
  systemctl daemon-reload
  test -f /lib/systemd/system/"${ROSCORE_UNIT}" \
    || die "missing ${ROSCORE_UNIT}; need ros-melodic-xgc2-wheeltec-onboard >= 0.1.0-10"
  pin_onboard_env
  systemctl stop "${BRIDGE_UNIT}" >/dev/null 2>&1 || true
  systemctl stop "${CHASSIS_UNIT}" >/dev/null 2>&1 || true
  reap_vendor_leftovers
  reset_controller_usb
  wait_controller_openable 30 \
    || die "${CONTROLLER_DEVICE} not openable after vendor cleanup / USB reset"
  log "enable and restart ${ROSCORE_UNIT} (standalone ROS master; reload ${ONBOARD_ENV})"
  systemctl enable "${ROSCORE_UNIT}"
  systemctl restart "${ROSCORE_UNIT}"
  systemctl is-active --quiet "${ROSCORE_UNIT}" || die "${ROSCORE_UNIT} failed after restart"
  wait_ros_master 30 \
    || die "ROS master did not listen on :11311 after ${ROSCORE_UNIT}; not starting chassis or the bridge"
  log "enable and restart ${CHASSIS_UNIT} (join standalone master; re-open serial after USB reset)"
  systemctl enable "${CHASSIS_UNIT}"
  systemctl restart "${CHASSIS_UNIT}"
  systemctl is-active --quiet "${CHASSIS_UNIT}" || die "${CHASSIS_UNIT} failed to start"
  if [[ "${SKIP_TOPIC_CHECK}" -eq 0 ]]; then
    wait_live_chassis \
      || die "no live /imu and /PowerVoltage after ${CHASSIS_UNIT}; not starting the bridge"
  fi
  log "enable and restart ${BRIDGE_UNIT} (join standalone master; do not spawn one)"
  systemctl enable "${BRIDGE_UNIT}"
  systemctl restart "${BRIDGE_UNIT}"
  systemctl is-active --quiet "${BRIDGE_UNIT}" || die "${BRIDGE_UNIT} failed to start"
}

source_ros() {
  set +u
  # shellcheck disable=SC1090
  source "/opt/ros/${ROS_DISTRO}/setup.bash"
  set -u
  export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"
  export ROS_IP="${ROS_IP:-127.0.0.1}"
}

wait_live_chassis() {
  local deadline=$((SECONDS + TOPIC_CHECK_SECONDS))
  local imu=0 volt=0
  source_ros
  while (( SECONDS < deadline )); do
    if [[ "${imu}" -eq 0 ]] && timeout 2 rostopic echo -n 1 /imu >/dev/null 2>&1; then
      log "topic /imu produced a message"
      imu=1
    fi
    if [[ "${volt}" -eq 0 ]] && timeout 2 rostopic echo -n 1 /PowerVoltage >/dev/null 2>&1; then
      log "topic /PowerVoltage produced a message"
      volt=1
    fi
    if [[ "${imu}" -eq 1 && "${volt}" -eq 1 ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

verify_central_link() {
  if [[ "${SKIP_CONTROLLER}" -eq 0 && ! -e "${CONTROLLER_DEVICE}" ]]; then
    die "${CONTROLLER_DEVICE} missing; chassis serial is required. Re-run with --skip-controller only if the adapter is absent on purpose"
  fi
  if [[ "${SKIP_TOPIC_CHECK}" -ne 0 ]]; then
    warn "skipping topic check (--skip-topic-check)"
    return 0
  fi
  source_ros
  command -v rostopic >/dev/null 2>&1 || die "rostopic missing after ROS ${ROS_DISTRO} install"
  command -v timeout >/dev/null 2>&1 || die "timeout missing (needed to wait for a live topic message)"
  if ! wait_live_chassis; then
    warn "no live chassis topics; USB reset + restart once"
    systemctl stop "${CHASSIS_UNIT}" >/dev/null 2>&1 || true
    reap_vendor_leftovers
    reset_controller_usb
    wait_controller_openable 30 \
      || die "${CONTROLLER_DEVICE} not openable on retry"
    systemctl is-active --quiet "${ROSCORE_UNIT}" || {
      log "restart ${ROSCORE_UNIT} before chassis retry"
      systemctl restart "${ROSCORE_UNIT}"
    }
    wait_ros_master 30 \
      || die "ROS master did not listen on :11311 after ${ROSCORE_UNIT} (chassis must not own it)"
    systemctl restart "${CHASSIS_UNIT}"
    systemctl is-active --quiet "${CHASSIS_UNIT}" || die "${CHASSIS_UNIT} failed to start on retry"
    wait_live_chassis \
      || die "no live /imu and /PowerVoltage within ${TOPIC_CHECK_SECONDS}s after USB reset (serial device is present; MCU is not streaming — check chassis power / 3S battery before retrying)"
    systemctl restart "${BRIDGE_UNIT}"
    wait_live_chassis || die "chassis dropped off the master after starting the bridge; rerun configure linux"
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -E ':3001|:3002' || \
      warn "TCP/UDP 3001/3002 not listed yet; bridge may still be staggering"
  fi
}

smoke() {
  log "smoke"
  systemctl --no-pager --full status "${ROSCORE_UNIT}" "${CHASSIS_UNIT}" "${BRIDGE_UNIT}" | sed -n '1,50p'
  if [[ -d "${QUARANTINE_DIR}" ]]; then
    log "quarantined apt sources under ${QUARANTINE_DIR}"
  fi
  cat <<EOF
+ centralized path: standalone roscore + serial chassis + onboard IMU + swarm_ros_bridge
+ vehicle send (after network yaml): /imu :3001, /PowerVoltage :3002
+ field IPs / ros_topics.yaml: run Wheeltec · configure network
+ ground process: swarm-ros-bridge-mecanum-physical (managementAddress = this vehicle)
+ not enabled: lidar / camera
+ not sent: /cmd_vel
+ wireless: onboard NIC is not the SSH / GCS path; USB is often wlan0 (see hint above)
EOF
  log "done"
}

if [[ "${REWRITE_UBUNTU_MIRROR}" -eq 1 ]]; then
  warn "--rewrite-ubuntu-mirror is opt-in; L4T companions should not rewrite sources.list"
fi
warn_wireless
configure_ros_source
configure_xgc2_source
install_stack
disable_vendor_units
enable_comm_stack
verify_central_link
smoke
