#!/usr/bin/env bash
# Phase 4 one-container closed-loop run.
#
# Runs inside the rmvision-qyg image (docker/run.sh phase4 does the docker part):
#   1. prepare the rclgd wiring and start the windowed simulator
#   2. wait until /image_raw has a publisher
#   3. start docker/qyg/phase4_qyg.launch.py (detector + solver)
#   4. run tests/phase4_qyg_check.py and print PHASE4_QYG: PASS/FAIL
#
# Environment:
#   PHASE4_DURATION   measurement window in seconds (default 15)
#   PHASE4_MODE       vision mode 0=red 1=blue (default 0)
#   PHASE4_SCENARIO   scenario resource, e.g. res://scenarios/1v1_static.yaml
#
# Extra arguments are passed to the QYG launch (e.g. detector:=tradition).
set -uo pipefail

# ament setup files dereference unset variables; sourcing them under `set -u`
# aborts with "AMENT_TRACE_SETUP_FILES: unbound variable".
set +u
source /opt/ros/humble/setup.bash
if [ -f /qyg_ws/install/setup.bash ]; then
    source /qyg_ws/install/setup.bash
fi
set -u

DURATION="${PHASE4_DURATION:-15}"
MODE="${PHASE4_MODE:-0}"
GODOT_LOG=/tmp/phase4_godot.log
QYG_LOG=/tmp/phase4_qyg.log

GODOT_PID=""
QYG_PID=""

cleanup() {
    local rc=$?
    [ -n "$QYG_PID" ] && kill "$QYG_PID" 2>/dev/null || true
    [ -n "$GODOT_PID" ] && kill "$GODOT_PID" 2>/dev/null || true
    [ -n "$QYG_PID" ] && wait "$QYG_PID" 2>/dev/null || true
    [ -n "$GODOT_PID" ] && wait "$GODOT_PID" 2>/dev/null || true
    pkill -f component_container_mt 2>/dev/null || true
    # Same cleanup as docker/run.sh: never leave the container-only rclgd
    # wiring behind for a host Godot run.
    rm -f /sim/addons/rclgd/bin/rclgd.gdextension /sim/addons/rclgd/bin/librclgd.so
    sed -i '\#res://addons/rclgd/bin/rclgd.gdextension#d' \
        /sim/.godot/extension_list.cfg 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT INT TERM

/opt/prepare_sim_project.sh /sim

SCENARIO_ARGS=()
if [ -n "${PHASE4_SCENARIO:-}" ]; then
    SCENARIO_ARGS=(-- "--scenario=${PHASE4_SCENARIO}")
fi

echo "==> starting simulator (log: $GODOT_LOG)"
godot --path /sim "${SCENARIO_ARGS[@]}" >"$GODOT_LOG" 2>&1 &
GODOT_PID=$!

echo "==> waiting for /image_raw publisher"
ready=0
for i in $(seq 1 90); do
    if ! kill -0 "$GODOT_PID" 2>/dev/null; then
        echo "simulator exited before publishing /image_raw" >&2
        tail -n 60 "$GODOT_LOG" >&2
        exit 1
    fi
    # Capture first: `grep -q` closes the pipe early and `pipefail` would turn
    # that SIGPIPE into a failed condition.
    topics="$(ros2 topic list 2>/dev/null || true)"
    info="$(ros2 topic info /image_raw 2>/dev/null || true)"
    if grep -qx "/image_raw" <<<"$topics" && [[ "$info" == *"Publisher count: 1"* ]]; then
        ready=1
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        echo "  still waiting for /image_raw (${i}s); topics:"
        ros2 topic list 2>&1 | sed 's/^/    /' | head -20
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "timed out waiting for /image_raw" >&2
    tail -n 60 "$GODOT_LOG" >&2
    exit 1
fi

echo "==> starting QYG detector + solver (log: $QYG_LOG)"
ros2 launch /sim/docker/qyg/phase4_qyg.launch.py \
    "mode:=${MODE}" "$@" >"$QYG_LOG" 2>&1 &
QYG_PID=$!

echo "==> waiting for QYG nodes"
ready=0
for _ in $(seq 1 90); do
    if ! kill -0 "$QYG_PID" 2>/dev/null; then
        echo "QYG launch exited early" >&2
        tail -n 80 "$QYG_LOG" >&2
        exit 1
    fi
    topics="$(ros2 topic list 2>/dev/null || true)"
    if grep -qx "/armor_detector/armors" <<<"$topics" \
            && grep -qx "/armor_solver/cmd_gimbal" <<<"$topics"; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "timed out waiting for QYG topics" >&2
    tail -n 80 "$QYG_LOG" >&2
    exit 1
fi

if [ "${PHASE4_DUMP:-0}" = "1" ]; then
    echo "==> dumping detector input/debug images to /sim/tests/phase4_dump_*.png"
    python3 /sim/tests/phase4_dump_image.py --topic /image_raw \
        --out /sim/tests/phase4_dump_raw.png --encoding bgr8 || true
    python3 /sim/tests/phase4_dump_image.py --topic /armor_detector/binary_img \
        --out /sim/tests/phase4_dump_binary.png --encoding mono8 || true
    python3 /sim/tests/phase4_dump_image.py --topic /armor_detector/number_img \
        --out /sim/tests/phase4_dump_number.png --encoding bgr8 || true
    python3 /sim/tests/phase4_dump_image.py --topic /armor_solver/result_img \
        --out /sim/tests/phase4_dump_result.png --encoding bgr8 || true
fi

echo "==> measuring for ${DURATION}s"
# Wait for the one-shot vision mode setter, so the measurement window covers
# the first lock instead of the idle start-up frames.
for _i in $(seq 1 20); do
    grep -q "PHASE4_MODE" "$QYG_LOG" 2>/dev/null && break
    sleep 0.5
done

TRACE_ARG=""; [ "${PHASE4_TRACE:-0}" = "1" ] && TRACE_ARG="--trace"
python3 /sim/tests/phase4_qyg_check.py --duration "$DURATION" $TRACE_ARG
rc=$?

echo
echo "==> QYG log tail"
tail -n 40 "$QYG_LOG"
exit "$rc"
