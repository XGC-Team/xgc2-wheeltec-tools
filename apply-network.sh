#!/usr/bin/env bash
# Wheeltec: activate the saved field Wi-Fi profile written by configure-network.sh.
# This can drop the current SSH session. It never edits the profile.
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

# Wheeltec: activate the saved field Wi-Fi profile written by configure-network.sh.
# This can drop the current SSH session. It never edits the profile.
set -euo pipefail

YES=0
WIFI_SSID="${WHEELTEC_WIFI_SSID:-${XGC2_WIFI_SSID:-}}"
WIFI_IFACE="${WHEELTEC_WIFI_IFACE:-}"
SYS_CLASS_NET="${WHEELTEC_SYS_CLASS_NET:-/sys/class/net}"

usage() {
  cat <<'EOF'
Usage: apply-network.sh --yes [options]

Activate the saved Wheeltec field Wi-Fi profile on its USB Wi-Fi interface.
The current SSH session may drop.

Options:
  --yes               required; refuse to run without it
  --wifi-ssid SSID    from site.env / env; no in-script default
  --wifi-iface IFACE  optional; otherwise read from the saved profile
  -h, --help          show this help
EOF
}

log() { printf '+ %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

iface_kind() {
  local iface="$1" dev path alias
  dev="${SYS_CLASS_NET}/${iface}/device"
  [[ -e "${dev}" ]] || { printf 'unknown'; return; }
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

while (($#)); do
  case "$1" in
    --yes) YES=1; shift ;;
    --wifi-ssid) WIFI_SSID="${2:?}"; shift 2 ;;
    --wifi-iface) WIFI_IFACE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --site-env) export XGC2_SITE_ENV="${2:?}"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done


xgc2_load_site
WIFI_SSID="${WIFI_SSID:-${XGC2_WIFI_SSID:-}}"
WIFI_PASSWORD="${WIFI_PASSWORD:-${XGC2_WIFI_PASSWORD:-}}"
if [[ -z "${WIFI_SSID}" ]]; then
  die "need --wifi-ssid or site.env XGC2_WIFI_SSID"
fi

[[ "${YES}" -eq 1 ]] || die "refusing to run without --yes (see --help)"
[[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
[[ -n "${WIFI_SSID}" && "${WIFI_SSID}" != "FIELD_SSID" ]] \
  || die "edit --wifi-ssid (placeholder FIELD_SSID is not a saved profile)"
command -v nmcli >/dev/null 2>&1 || die "missing command: nmcli"

profile="$(nmcli -t -f NAME,UUID,TYPE connection show \
  | awk -F: -v name="${WIFI_SSID}" '$1 == name && $3 == "802-11-wireless" { print $1; exit }')"
[[ -n "${profile}" ]] || die "saved Wi-Fi profile '${WIFI_SSID}' is missing; run Wheeltec · configure network first"

if [[ -z "${WIFI_IFACE}" ]]; then
  WIFI_IFACE="$(nmcli -g connection.interface-name connection show "${profile}" 2>/dev/null | head -n 1)"
fi
[[ -n "${WIFI_IFACE}" && -d "${SYS_CLASS_NET}/${WIFI_IFACE}/wireless" ]] \
  || die "saved profile '${profile}' has no wireless interface; pass --wifi-iface"
[[ "$(iface_kind "${WIFI_IFACE}")" == "usb" ]] \
  || die "${WIFI_IFACE} is $(iface_kind "${WIFI_IFACE}"); refusing onboard / PCIe Wi-Fi"

log "activate ${profile} on USB ${WIFI_IFACE} (SSH on this link may drop)"
nmcli connection up "${profile}" ifname "${WIFI_IFACE}"
log "up ${profile} on ${WIFI_IFACE}"
