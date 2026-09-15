#!/usr/bin/env bash
# Read-only Wheeltec onboard acceptance: services, controller device, live ROS
# topics, bridge listeners/configuration, and the /cmd_vel graph.
set -uo pipefail

TOPIC_TIMEOUT="${WHEELTEC_CHECK_TOPIC_TIMEOUT:-3}"
ROS_SETUP="${WHEELTEC_ROS_SETUP:-/opt/ros/melodic/setup.bash}"
CONTROLLER_DEVICE="${WHEELTEC_CONTROLLER_DEVICE:-/dev/wheeltec_controller}"
BRIDGE_YAML="${WHEELTEC_BRIDGE_YAML:-/etc/xgc2/wheeltec/ros_topics.yaml}"
FAILED=0

usage() {
  cat <<'EOF'
Usage: check-onboard.sh [options]

Read-only Wheeltec checks. It does not install, restart, reconnect, or publish
/cmd_vel.

Options:
  --topic-timeout N  seconds allowed for one message on each live topic (default 3)
  -h, --help          show this help
EOF
}

pass() { printf '+ PASS %s\n' "$*"; }
fail() { printf '+ FAIL %s\n' "$*" >&2; FAILED=1; }

while (($#)); do
  case "$1" in
    --topic-timeout) TOPIC_TIMEOUT="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ "${TOPIC_TIMEOUT}" =~ ^[1-9][0-9]*$ && "${TOPIC_TIMEOUT}" -le 30 ]] \
  || { printf 'error: --topic-timeout must be 1..30\n' >&2; exit 2; }

for command in systemctl timeout ss grep awk; do
  if command -v "${command}" >/dev/null 2>&1; then
    pass "command ${command}"
  else
    fail "missing command ${command}"
  fi
done

check_unit() {
  local unit="$1"
  if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
    pass "enabled ${unit}"
  else
    fail "not enabled ${unit}"
  fi
  if systemctl is-active --quiet "${unit}" 2>/dev/null; then
    pass "active ${unit}"
  else
    fail "not active ${unit}"
  fi
}

check_unit xgc2-wheeltec-roscore.service
check_unit xgc2-wheeltec-chassis.service
check_unit xgc2-wheeltec-swarm-ros-bridge.service
if [[ -e "${CONTROLLER_DEVICE}" ]]; then
  pass "controller device ${CONTROLLER_DEVICE}"
else
  fail "controller device ${CONTROLLER_DEVICE} missing"
fi

if [[ -r "${ROS_SETUP}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ROS_SETUP}"
  set -u
  pass "ROS setup ${ROS_SETUP}"
else
  fail "ROS setup ${ROS_SETUP} is unavailable"
fi
if command -v rostopic >/dev/null 2>&1; then
  pass "command rostopic"
else
  fail "missing command rostopic after ROS setup"
fi
export ROS_MASTER_URI="${ROS_MASTER_URI:-http://127.0.0.1:11311}"

bridge_send_max_freq() {
  local topic="$1"
  awk -v topic="${topic}" '
    $0 == "- topic_name: " topic { grab=1; next }
    grab && $1 == "max_freq:" { print $2; exit }
  ' "${BRIDGE_YAML}"
}

check_bridge_send_max_freq() {
  local topic="$1" want="$2" actual
  actual="$(bridge_send_max_freq "${topic}")"
  if [[ "${actual}" == "${want}" ]]; then
    pass "bridge send ${topic} max_freq=${want}"
  else
    fail "bridge send ${topic} max_freq=${actual:-missing}, expected ${want} (rerun configure network; do not ship a new APT)"
  fi
}

check_live_topic() {
  local topic="$1" expected="$2" wait="${3:-$TOPIC_TIMEOUT}" actual
  actual="$(rostopic type "${topic}" 2>/dev/null || true)"
  if [[ "${actual}" == "${expected}" ]]; then
    pass "topic ${topic} type ${expected}"
  else
    fail "topic ${topic} type ${actual:-missing}, expected ${expected}"
    return
  fi
  if timeout "${wait}s" rostopic echo -n 1 "${topic}" >/dev/null 2>&1; then
    pass "topic ${topic} produced one message"
  else
    fail "topic ${topic} produced no message within ${wait}s"
  fi
}

check_live_topic /imu sensor_msgs/Imu 8
check_live_topic /PowerVoltage std_msgs/Float32 8

if [[ -r "${BRIDGE_YAML}" ]]; then
  pass "bridge config ${BRIDGE_YAML}"
  if [[ "$(grep -Ec '^- topic_name: /cmd_vel$' "${BRIDGE_YAML}" 2>/dev/null)" -eq 2 ]]; then
    pass "bridge has two /cmd_vel GCS receivers"
  else
    fail "bridge must have two /cmd_vel GCS receivers (gcs1=.151, gcs2=.251)"
  fi
  for peer in gcs1 gcs2; do
    if grep -Eq "^  ${peer}: [0-9]+(\\.[0-9]+){3}$" "${BRIDGE_YAML}"; then
      pass "bridge peer ${peer}"
    else
      fail "bridge peer ${peer} missing"
    fi
  done
  for topic in /imu /PowerVoltage; do
    if grep -Fqx -- "- topic_name: ${topic}" "${BRIDGE_YAML}"; then
      pass "bridge send ${topic}"
    else
      fail "bridge send ${topic} missing"
    fi
  done
  check_bridge_send_max_freq /imu 10
  check_bridge_send_max_freq /PowerVoltage 1
  if grep -Fqx -- '- topic_name: /scout/chassis_state' "${BRIDGE_YAML}"; then
    fail "bridge incorrectly contains Scout chassis_state"
  else
    pass "bridge has no invented chassis_state"
  fi
else
  fail "bridge config ${BRIDGE_YAML} missing"
fi

listeners="$(ss -ltn 2>/dev/null || true)"
for port in 3001 3002; do
  if grep -Eq ":${port}[[:space:]]" <<<"${listeners}"; then
    pass "bridge TCP listener ${port}"
  else
    fail "bridge TCP listener ${port} missing"
  fi
done

cmd_info="$(rostopic info /cmd_vel 2>/dev/null || true)"
if grep -Fq 'Type: geometry_msgs/Twist' <<<"${cmd_info}"; then
  pass "/cmd_vel type geometry_msgs/Twist"
else
  fail "/cmd_vel type is missing or wrong"
fi
section_has_node() {
  local section="$1"
  awk -v section="${section}" '
    $0 ~ "^" section ":" { inside=1; next }
    inside && /^[A-Za-z][A-Za-z ]*:/ { exit }
    inside && $0 ~ /^ \* \// { found=1 }
    END { exit !found }
  ' <<<"${cmd_info}"
}
if section_has_node Publishers; then pass "/cmd_vel has a publisher"; else fail "/cmd_vel has no publisher"; fi
if section_has_node Subscribers; then pass "/cmd_vel has a chassis subscriber"; else fail "/cmd_vel has no chassis subscriber"; fi

if ((FAILED)); then
  printf 'Wheeltec onboard check failed.\n' >&2
  exit 1
fi
printf 'Wheeltec onboard check passed. No command was published.\n'
