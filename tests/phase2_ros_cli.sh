#!/usr/bin/env bash
# Phase 2 ROS CLI acceptance checks. Run INSIDE the ROS 2 Humble container with
# the simulator already running and the workspace sourced:
#
#   source /opt/ros/humble/setup.bash && source /ros_ws/install/setup.bash
#   docker/run.sh sim                              # in another terminal
#   ./tests/phase2_ros_cli.sh
#
# Uses the standard tools from the Phase 2 acceptance list (ros2 topic list,
# tf2_echo, ros2 topic pub/echo) plus one rclpy probe for topic rates and
# camera_info (per-topic `ros2 topic hz` processes under-report best-effort
# streams on a loaded machine; the probe subscribes once to every topic).
# Expects PHASE2_ROS_CLI: PASS.
set -u

FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

command -v ros2 >/dev/null || { echo "ros2 not sourced"; exit 2; }

echo "== waiting for topics =="
for _ in $(seq 1 20); do
	if ros2 topic list 2>/dev/null | grep -qx '/image_raw/compressed'; then
		break
	fi
	sleep 1
done

echo "== topics =="
TOPICS="$(ros2 topic list 2>/dev/null)"
for t in /image_raw /image_raw/compressed /camera_info /tf /tf_static \
	/serial/receive /armor_solver/cmd_gimbal /cmd_chassis; do
	if grep -qx "$t" <<<"$TOPICS"; then
		pass "topic $t"
	else
		fail "topic $t missing"
	fi
done

echo "== publish rates + camera_info (rclpy probe, 3 s window) =="
PROBE="$(timeout 30 python3 "$(dirname "$0")/phase2_rate_probe.py" 2>/dev/null)"
RATES_LINE="$(grep '^RATES ' <<<"$PROBE" || true)"
K_LINE="$(grep '^K ' <<<"$PROBE" || true)"
TFR_LINE="$(grep '^TFRATES ' <<<"$PROBE" || true)"
if [[ -z "$RATES_LINE" ]]; then
	fail "rate probe produced no output"
else
	field() {
		awk -v key="$1=" '{for (i = 2; i <= NF; i++) if (index($i, key) == 1) {sub(key, "", $i); print $i}}' <<<"$RATES_LINE"
	}
	check_rate() {
		local name="$1" value="$2" min="$3"
		awk -v v="$value" -v m="$min" 'BEGIN { exit !(v >= m) }' \
			&& pass "$name ${value} Hz (>= ${min})" \
			|| fail "$name ${value} Hz (< ${min})"
	}
	# The best-effort 6.2 MB raw stream frequently drops in a Python subscriber;
	# the backend publishes 30 Hz and the GDScript check asserts encoding/size.
	check_rate /image_raw "$(field raw)" 10
	check_rate /image_raw/compressed "$(field jpg)" 50
	check_rate /camera_info "$(field info)" 8
	check_rate /serial/receive "$(field serial)" 40
	check_rate /tf "$(field tf)" 45
fi

if [[ -n "$TFR_LINE" ]]; then
	MAP_ODOM="$(awk '{for (i = 2; i <= NF; i++) if ($i ~ /^map_odom=/) {sub("map_odom=", "", $i); print $i}}' <<<"$TFR_LINE")"
	GIMBAL="$(awk '{for (i = 2; i <= NF; i++) if ($i ~ /^gimbal=/) {sub("gimbal=", "", $i); print $i}}' <<<"$TFR_LINE")"
	MONO="$(awk '{for (i = 2; i <= NF; i++) if ($i ~ /^mono_map_odom=/) {sub("mono_map_odom=", "", $i); print $i}}' <<<"$TFR_LINE")"
	awk -v m="$MAP_ODOM" 'BEGIN { exit !(m >= 40) }' \
		&& pass "map→odom ${MAP_ODOM} Hz (>= 40)" \
		|| fail "map→odom ${MAP_ODOM} Hz (< 40, odom lags the robot)"
	awk -v g="$GIMBAL" 'BEGIN { exit !(g >= 40) }' \
		&& pass "odom→gimbal_link ${GIMBAL} Hz (>= 40)" \
		|| fail "odom→gimbal_link ${GIMBAL} Hz (< 40)"
	[[ "$MONO" == "1" ]] \
		&& pass "map→odom timestamps are monotonic" \
		|| fail "map→odom timestamps went backwards"
else
	fail "TF rates missing from the probe"
fi

if [[ -n "$K_LINE" ]]; then
	read -r _ FX FY CX CY <<<"$K_LINE"
	awk -v fx="$FX" -v fy="$FY" -v cx="$CX" -v cy="$CY" 'BEGIN {
		exit !(fx > 3300 && fx < 3450 && fy > 3300 && fy < 3450 &&
		       cx > 590 && cx < 620 && cy > 520 && cy < 550) }' \
		&& pass "camera_info k=[fx=$FX fy=$FY cx=$CX cy=$CY]" \
		|| fail "camera_info k=[fx=$FX fy=$FY cx=$CX cy=$CY]"
else
	fail "camera_info missing from (or not received by) the probe"
fi

echo "== TF =="
if timeout 8 ros2 run tf2_ros tf2_echo odom gimbal_link 2>&1 | grep -q "Translation"; then
	pass "tf2_echo odom -> gimbal_link"
else
	fail "tf2_echo odom -> gimbal_link"
fi
if timeout 8 ros2 run tf2_ros tf2_echo gimbal_link camera_link 2>&1 | grep -q "Translation"; then
	pass "tf2_echo gimbal_link -> camera_link"
else
	fail "tf2_echo gimbal_link -> camera_link"
fi
if timeout 8 ros2 run tf2_ros tf2_echo map odom 2>&1 | grep -q "Translation"; then
	pass "tf2_echo map -> odom (field origin)"
else
	fail "tf2_echo map -> odom (field origin)"
fi

echo "== cmd_gimbal -> serial/receive echo =="
ros2 topic pub --once /armor_solver/cmd_gimbal rm_interfaces/msg/GimbalCmd \
	"{header: {frame_id: odom}, yaw: 17.0, pitch: -6.0, distance: 3.0, id: '3'}" \
	>/dev/null 2>&1
sleep 0.4
SERIAL_MSG="$(timeout 8 ros2 topic echo --once /serial/receive 2>/dev/null)"
YAW="$(awk '/^yaw:/ {print $2; exit}' <<<"$SERIAL_MSG")"
PITCH="$(awk '/^pitch:/ {print $2; exit}' <<<"$SERIAL_MSG")"
MODE="$(awk '/^mode:/ {print $2; exit}' <<<"$SERIAL_MSG")"
awk -v y="$YAW" -v p="$PITCH" -v m="$MODE" 'BEGIN {
	exit !(y > 16.5 && y < 17.5 && p > -6.5 && p < -5.5 && m == 1) }' \
	&& pass "gimbal follows /armor_solver/cmd_gimbal (serial yaw=$YAW pitch=$PITCH mode=$MODE)" \
	|| fail "gimbal does not follow /armor_solver/cmd_gimbal (serial yaw=${YAW:-?} pitch=${PITCH:-?} mode=${MODE:-?})"

echo "== compressed image sanity =="
JPEG_HDR="$(timeout 8 ros2 topic echo --once --field data /image_raw/compressed 2>/dev/null | head -c 40)"
if [[ "$JPEG_HDR" == *"["* ]]; then
	pass "/image_raw/compressed carries data"
else
	fail "/image_raw/compressed data missing"
fi

if [[ "$FAIL" -eq 0 ]]; then
	echo "PHASE2_ROS_CLI: PASS"
	exit 0
fi
echo "PHASE2_ROS_CLI: FAIL ($FAIL)"
exit 1
