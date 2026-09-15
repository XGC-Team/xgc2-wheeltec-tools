#!/usr/bin/env bash
# Wheeltec field network: USB Wi-Fi /24 + ros_topics.yaml GCS peers. Never reconnect.
#
# Onboard PCIe Wi-Fi is unusable as SSH / GCS. This script only writes the
# USB card. Does not run `nmcli connection up`. Does not ping. Does not ifup.
# From --lan-address A.B.C.D it also writes bridge peers .151 / .251.
#
# Usage:
#   sudo bash configure-network.sh --yes --lan-address 192.168.51.11X
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

YES=0
PRINT_BRIDGE_YAML=0
WIFI_SSID="${WHEELTEC_WIFI_SSID:-${XGC2_WIFI_SSID:-}}"
WIFI_PASSWORD="${WHEELTEC_WIFI_PASSWORD:-${XGC2_WIFI_PASSWORD:-}}"
WIFI_IFACE="${WHEELTEC_WIFI_IFACE:-}"
LAN_ADDRESS="${WHEELTEC_LAN_ADDRESS:-}"
LAN_GATEWAY="${WHEELTEC_LAN_GATEWAY:-}"
LAN_DNS="${WHEELTEC_LAN_DNS:-}"
GCS_PREFIX="${WHEELTEC_GCS_PREFIX:-}"
GCS_LAST_OCTETS="${WHEELTEC_GCS_LAST_OCTETS:-151,251}"
CMD_VEL_PORT="${WHEELTEC_CMD_VEL_PORT:-}"
BRIDGE_YAML="/etc/xgc2/wheeltec/ros_topics.yaml"
GCS_PEER_ARGS=()
GCS_IPS=()

usage() {
  cat <<'EOF'
Usage: configure-network.sh --yes --lan-address A.B.C.D[/24] [options]

Write a static /24 on the USB Wi-Fi profile and ros_topics.yaml peers
.151 / .251 on that LAN. Refuses the onboard PCIe card. Does not reconnect.
Edit 192.168.51.11X to the vehicle host (.111-.119). SSID/PSK default to
the same field AP as FS150.

Options:
  --yes                     required for install; not needed for --print-bridge-yaml
  --lan-address A.B.C.D[/24]  required; static IPv4, prefix /24
  --lan-gateway ADDR        default A.B.C.1 from --lan-address
  --lan-dns ADDR            default same as gateway
  --wifi-ssid SSID          from site.env / env; no in-script default
  --wifi-password PASS      from site.env / env / flag; no in-script default
  --wifi-iface IFACE        must be USB wireless; default = first USB Wi-Fi
  --gcs-last-octets LIST    default 151,251
  --cmd-vel-port N          vehicle recv srcPort for /cmd_vel; default from
                            --lan-address .111–.119 → 3001–3009 so Mecanum-01
                            and Scout-01 can share one UGV roster
  --print-bridge-yaml       print ros_topics.yaml to stdout; no root, no NM
  -h, --help                show this help
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

is_wireless() {
  [[ -d "/sys/class/net/$1/wireless" ]]
}

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

usb_wifi_blocklist_hits() {
  command -v lsusb >/dev/null 2>&1 || return 0
  lsusb 2>/dev/null | awk '
    /0bda:1a2b/ { print "0bda:1a2b (USB DISK / Windows no-driver dongle, not a NIC yet)" }
    /0bda:c812/ { print "0bda:c812 (RTL8822CU after mode-switch; no in-tree driver here)" }
  '
}

list_usb_wifi() {
  local iface
  shopt -s nullglob
  for iface in /sys/class/net/*; do
    iface="${iface##*/}"
    [[ "${iface}" == lo ]] && continue
    is_wireless "${iface}" || continue
    [[ "$(iface_kind "${iface}")" == "usb" ]] || continue
    printf '%s\n' "${iface}"
  done
  shopt -u nullglob
}

resolve_usb_iface() {
  local found
  if [[ -n "${WIFI_IFACE}" ]]; then
    [[ -d "/sys/class/net/${WIFI_IFACE}" ]] || die "no such iface: ${WIFI_IFACE}"
    is_wireless "${WIFI_IFACE}" || die "${WIFI_IFACE} is not wireless"
    [[ "$(iface_kind "${WIFI_IFACE}")" == "usb" ]] \
      || die "${WIFI_IFACE} is $(iface_kind "${WIFI_IFACE}"); onboard / PCIe Wi-Fi is not a usable SSH / GCS path"
    return 0
  fi
  found=""
  while read -r found; do
    break
  done < <(list_usb_wifi)
  [[ -n "${found}" ]] || die "no USB Wi-Fi in sysfs. Plug a known-good USB NIC; do not use the onboard / PCIe radio (USB is often named wlan0 here)"
  WIFI_IFACE="${found}"
  log "using USB Wi-Fi ${WIFI_IFACE}"
}

is_ipv4_host() {
  local host="$1"
  local part
  [[ "${host}" == *.*.*.* ]] || return 1
  IFS=. read -r -a parts <<<"${host}"
  [[ "${#parts[@]}" -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "${part}" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
}

is_ipv4_prefix() {
  local prefix="$1"
  [[ "${prefix}" == *.*.* && "${prefix}" != *.*.*.* ]] || return 1
  local part
  IFS=. read -r -a parts <<<"${prefix}"
  [[ "${#parts[@]}" -eq 3 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "${part}" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
}

reject_lan_placeholder() {
  local raw="${1:-}"
  [[ "${raw}" != *XX* && "${raw}" != *YY* && "${raw}" != *11X* ]] \
    || die "edit --lan-address (placeholder 192.168.51.11X is not an address; Mecanum-01..09 are .111-.119)"
}

emit_bridge_yaml() {
  local dest="$1"
  need_cmd python3
  python3 - "${dest}" "${CMD_VEL_PORT}" "${GCS_PEER_ARGS[@]}" <<'PY'
import sys

dest, port = sys.argv[1], sys.argv[2]
peers = []
seen = set()
for item in sys.argv[3:]:
    name, ip = item.split("=", 1)
    if name in seen:
        raise SystemExit("duplicate peer name: " + name)
    seen.add(name)
    peers.append((name, ip))
if not peers:
    raise SystemExit("no GCS peers")

lines = [
    "### Official swarm_ros_bridge: ZMQ PUB/SUB over TCP.",
    "### send binds tcp://*:srcPort — any GCS can SUB IMU / voltage / chassis.",
    "### recv connects tcp://peer:srcPort — one row per GCS that may send /cmd_vel.",
    "### gcs1 = .151; gcs2 = .251. Field IPs are written here, not in the APT package.",
    "### Wheeltec send is /imu :3001 and /PowerVoltage :3002. No packed vehicle-state topic.",
    "### Air cap: IMU 10 Hz (liveness only; Ground HUD floor 5), voltage 1 Hz. cmd_vel recv unlimited;",
    "### GCS send max_freq 100 is the air ceiling; Scout and Mecanum controllers both choose 30 Hz.",
    "### MCU may still be faster locally. Do not raise IMU. Do not tighten Adapter IMU online age.",
    "### Two stations sending /cmd_vel at once is last-writer-wins.",
    "",
    "IP:",
    "  self: '*'",
]
for name, ip in peers:
    lines.append("  %s: %s" % (name, ip))
lines.append("  test_local: 127.0.0.1")
lines.extend([
    "",
    "send_topics:",
    "- topic_name: /imu",
    "  msg_type: sensor_msgs/Imu",
    "  max_freq: 10",
    "  srcIP: self",
    "  srcPort: 3001",
    "- topic_name: /PowerVoltage",
    "  msg_type: std_msgs/Float32",
    "  max_freq: 1",
    "  srcIP: self",
    "  srcPort: 3002",
    "",
    "recv_topics:",
])
for name, _ip in peers:
    lines.extend([
        "- topic_name: /cmd_vel",
        "  msg_type: geometry_msgs/Twist",
        "  max_freq: 0",
        "  srcIP: %s" % name,
        "  srcPort: %s" % port,
    ])
text = "\n".join(lines) + "\n"
if dest in ("-", ""):
    sys.stdout.write(text)
else:
    open(dest, "w", encoding="utf-8").write(text)
PY
}

resolve_gcs_peers() {
  local raw_octets octet ip name prefix
  GCS_PEER_ARGS=()
  GCS_IPS=()
  prefix="${GCS_PREFIX}"
  if [[ -z "${prefix}" && -n "${LAN_ADDRESS}" ]]; then
    prefix="${LAN_ADDRESS%/*}"
    prefix="${prefix%.*}"
  fi
  [[ -n "${prefix}" ]] || die "need --lan-address (or --gcs-prefix for --print-bridge-yaml)"
  is_ipv4_prefix "${prefix}" || die "invalid GCS LAN prefix from --lan-address: ${prefix}"
  IFS=',' read -r -a raw_octets <<<"${GCS_LAST_OCTETS}"
  [[ ${#raw_octets[@]} -ge 1 ]] || die "empty --gcs-last-octets"
  for octet in "${raw_octets[@]}"; do
    octet="${octet// /}"
    [[ "${octet}" =~ ^[0-9]+$ && "${octet}" -ge 0 && "${octet}" -le 255 ]] \
      || die "invalid last octet: ${octet}"
    ip="${prefix}.${octet}"
    case "${octet}" in
      151) name="gcs1" ;;
      251) name="gcs2" ;;
      *) die "unsupported GCS last octet ${octet}; expected 151 (gcs1) or 251 (gcs2)" ;;
    esac
    GCS_PEER_ARGS+=("${name}=${ip}")
    GCS_IPS+=("${ip}")
  done
}

# Mecanum-01…09 at .111–.119 use GCS cmd_vel 3001–3009. Scout-01 uses 3301, so
# both sequence-1 vehicles can sit in one Experiment UGV roster.
derive_cmd_vel_port() {
  if [[ -n "${CMD_VEL_PORT}" ]]; then
    return 0
  fi
  local host octet
  host="${LAN_ADDRESS%/*}"
  octet="${host##*.}"
  if [[ "${octet}" =~ ^[0-9]+$ && "${octet}" -ge 111 && "${octet}" -le 119 ]]; then
    CMD_VEL_PORT="$((3000 + octet - 110))"
    log "cmd_vel GCS port ${CMD_VEL_PORT} from ${host} (Mecanum-$((octet - 110)))"
    return 0
  fi
  die "need --cmd-vel-port (Mecanum-01…09 at .111–.119 map to 3001–3009; Scout-01 is 3301)"
}

write_bridge_yaml() {
  local dest="${BRIDGE_YAML}"
  mkdir -p "$(dirname "${dest}")"
  if [[ -e "${dest}" ]]; then
    cp -a "${dest}" "${dest}.bak-$(date +%Y%m%d-%H%M%S)"
    log "backup ${dest}"
  fi
  emit_bridge_yaml "${dest}"
  log "wrote ${dest} peers=${GCS_IPS[*]} cmd_vel_port=${CMD_VEL_PORT}"
  reload_bridge_yaml
}

wait_chassis_on_live_master() {
  local ros_setup="${WHEELTEC_ROS_SETUP:-/opt/ros/melodic/setup.bash}"
  local deadline imu=0 volt=0
  [[ -r "${ros_setup}" ]] || { warn "ROS setup missing; skip live topic wait"; return 0; }
  command -v timeout >/dev/null 2>&1 || { warn "timeout missing; skip live topic wait"; return 0; }
  set +u
  # shellcheck disable=SC1090
  source "${ros_setup}"
  set -u
  export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"
  export ROS_IP="${ROS_IP:-127.0.0.1}"
  command -v rostopic >/dev/null 2>&1 || { warn "rostopic missing; skip live topic wait"; return 0; }
  deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if [[ "${imu}" -eq 0 ]] && timeout 2 rostopic echo -n 1 /imu >/dev/null 2>&1; then
      imu=1
    fi
    if [[ "${volt}" -eq 0 ]] && timeout 2 rostopic echo -n 1 /PowerVoltage >/dev/null 2>&1; then
      volt=1
    fi
    if [[ "${imu}" -eq 1 && "${volt}" -eq 1 ]]; then
      log "chassis republished /imu and /PowerVoltage on the live master"
      return 0
    fi
    sleep 1
  done
  return 1
}

reload_bridge_yaml() {
  if ! command -v systemctl >/dev/null 2>&1 \
    || ! systemctl cat xgc2-wheeltec-swarm-ros-bridge.service >/dev/null 2>&1; then
    log "bridge unit not installed yet; yaml is ready for configure linux"
    return 0
  fi
  if ! systemctl cat xgc2-wheeltec-roscore.service >/dev/null 2>&1; then
    die "missing xgc2-wheeltec-roscore.service; need ros-melodic-xgc2-wheeltec-onboard >= 0.1.0-10 (do not restart chassis to own the master)"
  fi
  if systemctl try-restart xgc2-wheeltec-swarm-ros-bridge.service >/dev/null 2>&1; then
    log "try-restart xgc2-wheeltec-swarm-ros-bridge"
  else
    warn "bridge unit present but try-restart failed; start it after configure linux"
  fi
  if systemctl is-active --quiet xgc2-wheeltec-chassis.service 2>/dev/null; then
    wait_chassis_on_live_master \
      || die "no live /imu and /PowerVoltage after yaml reload (standalone roscore must stay up; rerun configure linux, do not USB-reset by hand)"
  else
    log "chassis unit not running; yaml is ready for configure linux"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --lan-address) LAN_ADDRESS="${2:?}"; shift 2 ;;
    --lan-gateway) LAN_GATEWAY="${2:?}"; shift 2 ;;
    --lan-dns) LAN_DNS="${2:?}"; shift 2 ;;
    --wifi-ssid) WIFI_SSID="${2:?}"; shift 2 ;;
    --wifi-password) WIFI_PASSWORD="${2:?}"; shift 2 ;;
    --wifi-iface) WIFI_IFACE="${2:?}"; shift 2 ;;
    --gcs-prefix) GCS_PREFIX="${2:?}"; shift 2 ;;
    --gcs-last-octets) GCS_LAST_OCTETS="${2:?}"; shift 2 ;;
    --cmd-vel-port) CMD_VEL_PORT="${2:?}"; shift 2 ;;
    --print-bridge-yaml) PRINT_BRIDGE_YAML=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --site-env) export XGC2_SITE_ENV="${2:?}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

if [[ "${PRINT_BRIDGE_YAML}" -eq 1 ]]; then
  [[ -n "${LAN_ADDRESS}" || -n "${GCS_PREFIX}" ]] || die "need --lan-address"
  if [[ -n "${LAN_ADDRESS}" ]]; then
    reject_lan_placeholder "${LAN_ADDRESS}"
    is_ipv4_host "${LAN_ADDRESS%/*}" || die "invalid --lan-address: ${LAN_ADDRESS}"
  fi
  derive_cmd_vel_port
  [[ "${CMD_VEL_PORT}" =~ ^[0-9]+$ && "${CMD_VEL_PORT}" -ge 1 && "${CMD_VEL_PORT}" -le 65535 ]] \
    || die "invalid --cmd-vel-port: ${CMD_VEL_PORT}"
  resolve_gcs_peers
  emit_bridge_yaml -
  exit 0
fi


xgc2_load_site
WIFI_SSID="${WIFI_SSID:-${XGC2_WIFI_SSID:-}}"
WIFI_PASSWORD="${WIFI_PASSWORD:-${XGC2_WIFI_PASSWORD:-}}"
if [[ -z "${WIFI_SSID}" ]]; then
  die "need --wifi-ssid or site.env XGC2_WIFI_SSID"
fi

[[ "${YES}" -eq 1 ]] || die "refusing to run without --yes (see --help)"
[[ -n "${LAN_ADDRESS}" ]] || die "need --lan-address"
reject_lan_placeholder "${LAN_ADDRESS}"
[[ "${WIFI_SSID}" != "FIELD_SSID" ]] \
  || die "edit --wifi-ssid (placeholder FIELD_SSID is not a network name)"
derive_cmd_vel_port
[[ "${CMD_VEL_PORT}" =~ ^[0-9]+$ && "${CMD_VEL_PORT}" -ge 1 && "${CMD_VEL_PORT}" -le 65535 ]] \
  || die "invalid --cmd-vel-port: ${CMD_VEL_PORT}"
require_root
need_cmd nmcli
need_cmd ip
need_cmd python3

while read -r hit; do
  [[ -z "${hit}" ]] && continue
  die "USB Wi-Fi blocklist: ${hit}. Swap the dongle. Do not build rtl8822cu / rtw88"
done < <(usb_wifi_blocklist_hits)

resolve_usb_iface

normalize_lan_cidr() {
  local raw="$1" host prefix
  raw="${raw//[[:space:]]/}"
  [[ -n "${raw}" ]] || return 1
  if [[ "${raw}" == */* ]]; then
    host="${raw%/*}"
    prefix="${raw##*/}"
  else
    host="${raw}"
    prefix="24"
  fi
  is_ipv4_host "${host}" || return 1
  if [[ "${prefix}" == "32" ]]; then
    warn "refusing IPv4 /32 (breaks on-link ARP); using ${host}/24"
    prefix="24"
  fi
  [[ "${prefix}" == "24" ]] || die "field IPv4 must be /24, got ${host}/${prefix}"
  printf '%s/%s\n' "${host}" "${prefix}"
}

default_from_cidr() {
  local host="$1"
  printf '%s.1\n' "${host%.*}"
}

active_wifi_on_iface() {
  local iface="$1"
  nmcli -t -f NAME,TYPE,DEVICE connection show --active \
    | awk -F: -v iface="${iface}" '$2 == "802-11-wireless" && $3 == iface { print $1; exit }'
}

apply_static_ipv4() {
  local profile="$1"
  local cidr="$2"
  # Field NM profiles often keep 802-11-wireless.mac-address from the NIC
  # that first created them. Clearing it (never rewriting it to this USB
  # card's burned-in MAC) is the asset-IP contract: any later USB Wi-Fi
  # that enumerates as this iface autoconnects to the same /24. USB
  # constraint is connection.interface-name only.
  nmcli connection modify "${profile}" \
    connection.interface-name "${WIFI_IFACE}" \
    802-11-wireless.mac-address "" \
    802-11-wireless.cloned-mac-address "" \
    connection.autoconnect yes \
    connection.autoconnect-priority 200 \
    ipv4.method manual \
    ipv4.addresses "${cidr}" \
    ipv4.gateway "${LAN_GATEWAY}" \
    ipv4.dns "${LAN_DNS}" \
    ipv4.ignore-auto-dns yes
}

apply_live_ipv4_prefix() {
  local iface="$1"
  local cidr="$2"
  local host="${cidr%/*}"
  local live live_host
  live="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4; exit}')"
  [[ -n "${live}" ]] || return 0
  live_host="${live%/*}"
  if [[ "${live_host}" != "${host}" ]]; then
    warn "live ${iface} is ${live}, profile now ${cidr}; not applying (would drop SSH)"
    return 0
  fi
  if [[ "${live}" == "${cidr}" ]]; then
    log "${iface} already ${cidr}"
    return 0
  fi
  log "same host ${host}; apply ${live} -> ${cidr} without reconnect"
  ip addr add "${cidr}" dev "${iface}" 2>/dev/null || true
  [[ "${live}" == "${cidr}" ]] || ip addr del "${live}" dev "${iface}" 2>/dev/null || true
  if nmcli device reapply "${iface}"; then
    log "nmcli device reapply ${iface}"
  else
    warn "reapply failed; kernel may already be ${cidr} until next NM refresh"
  fi
}

cidr="$(normalize_lan_cidr "${LAN_ADDRESS}")" \
  || die "invalid --lan-address: ${LAN_ADDRESS}"
[[ "${cidr}" == *.*.*.*/* ]] || die "expected IPv4 CIDR, got ${cidr}"
if [[ -z "${LAN_GATEWAY}" ]]; then
  LAN_GATEWAY="$(default_from_cidr "${cidr%/*}")"
fi
if [[ -z "${LAN_DNS}" ]]; then
  LAN_DNS="${LAN_GATEWAY}"
fi

profile=""
if [[ -n "${WIFI_SSID}" ]]; then
  profile="$(nmcli -t -f NAME,UUID,TYPE connection show \
    | awk -F: -v ssid="${WIFI_SSID}" '$1 == ssid && $3 == "802-11-wireless" { print $1; exit }')"
else
  profile="$(active_wifi_on_iface "${WIFI_IFACE}")"
  [[ -n "${profile}" ]] || die "no active Wi-Fi on USB ${WIFI_IFACE}; pass --wifi-ssid to name the profile"
  log "no --wifi-ssid; using active USB Wi-Fi profile '${profile}'"
fi

if [[ -n "${profile}" ]]; then
  log "write static IPv4 on USB profile '${profile}' iface ${WIFI_IFACE} (no reconnect)"
  apply_static_ipv4 "${profile}" "${cidr}"
  if [[ -n "${WIFI_SSID}" ]]; then
    nmcli connection modify "${profile}" 802-11-wireless.ssid "${WIFI_SSID}"
  fi
  if [[ -n "${WIFI_PASSWORD}" ]]; then
    nmcli connection modify "${profile}" \
      802-11-wireless-security.key-mgmt wpa-psk \
      802-11-wireless-security.psk "${WIFI_PASSWORD}"
  fi
else
  [[ -n "${WIFI_SSID}" ]] || die "need --wifi-ssid to create a profile"
  [[ -n "${WIFI_PASSWORD}" ]] || die "no existing '${WIFI_SSID}' profile; pass --wifi-password to create one"
  log "create Wi-Fi profile '${WIFI_SSID}' on USB ${WIFI_IFACE} (no connect now)"
  nmcli connection add type wifi ifname "${WIFI_IFACE}" con-name "${WIFI_SSID}" \
    ssid "${WIFI_SSID}" \
    connection.autoconnect yes \
    connection.autoconnect-priority 200 \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "${WIFI_PASSWORD}" \
    ipv4.method manual \
    ipv4.addresses "${cidr}" \
    ipv4.gateway "${LAN_GATEWAY}" \
    ipv4.dns "${LAN_DNS}" \
    ipv4.ignore-auto-dns yes
  profile="${WIFI_SSID}"
  apply_static_ipv4 "${profile}" "${cidr}"
fi
log "NM saved ${profile} on ${WIFI_IFACE} -> ${cidr} gw ${LAN_GATEWAY} dns ${LAN_DNS}"
apply_live_ipv4_prefix "${WIFI_IFACE}" "${cidr}"
resolve_gcs_peers
write_bridge_yaml
log "not running nmcli connection up (would drop SSH if SSID/host changes)"
log "onboard PCIe Wi-Fi was not written"
