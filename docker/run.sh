#!/usr/bin/env bash
# Run the rmvision-rclgd:humble container.
#
#   docker/run.sh verify            # ros2 rclgd doctor + headless rclgd smoke test
#   docker/run.sh doctor            # just `ros2 rclgd doctor`
#   docker/run.sh sim               # windowed simulator, ROS + rclgd ready
#   docker/run.sh godot [args...]   # windowed Godot on the project (+ args)
#   docker/run.sh shell             # interactive shell with ROS + rclgd overlay
#   docker/run.sh godot [args...]   # run the bundled Godot 4.7.2 on the project
#   docker/run.sh foxglove          # Foxglove bridge, ws://localhost:8765 (JPEG + TF + serial)
#   docker/run.sh foxglove-tf       # TF/motion only, ws://localhost:8767 (no camera, lowest latency)
#   docker/run.sh foxglove-full     # Foxglove bridge with every topic incl. raw images,
#                                   # ws://localhost:8766 (heavy, localhost only)
#   docker/run.sh foxglove-phase4   # Phase 4 profile, ws://localhost:8768 (JPEG + QYG)
#   docker/run.sh qyg [launch args] # Phase 4 QYG armor_detector + armor_solver
#   docker/run.sh qyg-shell         # interactive shell in the QYG image (ROS overlay sourced)
#   docker/run.sh phase4            # simulator + QYG stack + closed-loop probe in one container
#   docker/run.sh ros2 topic list   # any command inside the container
#
# The project directory is mounted at /sim, the container uses host networking
# and IPC (DDS + shared memory need it), and the GPU / X11 socket are passed
# through when available.
#
# Before `sim`/`godot` runs, /opt/prepare_sim_project.sh links the installed
# librclgd.so into addons/rclgd/bin/ (GDExtension resolves the bare name
# relative to the .gdextension file) and registers the extension in
# .godot/extension_list.cfg if it is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-rmvision-rclgd:humble}"
PROJECT_DIR="${PROJECT_DIR:-$REPO_ROOT}"
# Phase 4 QYG vision stack image (built by docker/qyg/build.sh).
QYG_IMAGE="${QYG_IMAGE:-rmvision-qyg:humble}"
QYG_DIR="${QYG_DIR:-$REPO_ROOT/../QYG_QDVision2026}"

command="${1:-shell}"
[ $# -gt 0 ] && shift

DOCKER_ARGS=(
    --rm
    --network host
    --ipc host
    --workdir /sim
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
    -e ROS_AUTOMATIC_DISCOVERY_RANGE="${ROS_AUTOMATIC_DISCOVERY_RANGE:-LOCALHOST}"
    -v "$PROJECT_DIR:/sim"
)

# Interactive only when we have a TTY.
if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_ARGS+=(-it)
fi

# --- GPU / display passthrough ---------------------------------------------
# The simulator needs a real GPU. If you get black frames or Mesa llvmpipe,
# check that your user is in the video/render groups and that /dev/dri is
# accessible (see the note in docker/README.md); do not disable rendering.
if [ -e /dev/dri ]; then
    DOCKER_ARGS+=(--device /dev/dri)
    video_gid="$(getent group video | cut -d: -f3 || true)"
    render_gid="$(getent group render | cut -d: -f3 || true)"
    [ -n "${video_gid:-}" ] && DOCKER_ARGS+=(--group-add "$video_gid")
    [ -n "${render_gid:-}" ] && DOCKER_ARGS+=(--group-add "$render_gid")
fi

if [ -n "${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
    DOCKER_ARGS+=(
        -e DISPLAY="$DISPLAY"
        -v /tmp/.X11-unix:/tmp/.X11-unix:ro
    )
    if [ -n "${XAUTHORITY:-}" ] && [ -f "$XAUTHORITY" ]; then
        DOCKER_ARGS+=(-e XAUTHORITY=/tmp/.Xauthority -v "$XAUTHORITY:/tmp/.Xauthority:ro")
    elif [ -f "$HOME/.Xauthority" ]; then
        DOCKER_ARGS+=(-e XAUTHORITY=/tmp/.Xauthority -v "$HOME/.Xauthority:/tmp/.Xauthority:ro")
    fi
    # XWayland sessions often expose an X11 DISPLAY plus a Wayland socket;
    # pass the latter through too when it exists.
    if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] \
            && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
        DOCKER_ARGS+=(
            -e WAYLAND_DISPLAY="$WAYLAND_DISPLAY"
            -e XDG_RUNTIME_DIR=/tmp/xdg-runtime
            -v "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:/tmp/xdg-runtime/$WAYLAND_DISPLAY"
        )
    fi
fi

run_sim_script() {
    # $1: extra godot args, rest: user args appended after --path /sim
    local script="$1"
    shift
    # Clean up the container-only rclgd wiring on exit so a later host Godot
    # run does not try (and fail) to load the ROS library.
    local cleanup='rc=$?; rm -f /sim/addons/rclgd/bin/rclgd.gdextension /sim/addons/rclgd/bin/librclgd.so; sed -i "\#res://addons/rclgd/bin/rclgd.gdextension#d" /sim/.godot/extension_list.cfg 2>/dev/null; exit $rc'
    docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
        bash -c "/opt/prepare_sim_project.sh /sim && godot --path /sim $script \"\$@\"; $cleanup" _ "$@"
}

case "$command" in
    verify)
        # doctor first, then the headless smoke test; the smoke runner exits
        # non-zero on failure and docker propagates it.
        docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
            bash -c 'ros2 rclgd doctor && /opt/rclgd-test/run_smoke.sh'
        ;;
    doctor)
        docker run "${DOCKER_ARGS[@]}" "$IMAGE" ros2 rclgd doctor
        ;;
    foxglove|foxglove-full|foxglove-tf|foxglove-phase4)
        case "$command" in
            foxglove-full)  params=/sim/docker/foxglove_bridge_full.yaml ;;
            foxglove-tf)    params=/sim/docker/foxglove_bridge_tf.yaml ;;
            foxglove-phase4) params=/sim/docker/foxglove_phase4.yaml ;;
            *)              params=/sim/docker/foxglove_bridge.yaml ;;
        esac
        docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
            ros2 run foxglove_bridge foxglove_bridge --ros-args \
            --params-file "$params" "$@"
        ;;
    shell)
        docker run "${DOCKER_ARGS[@]}" "$IMAGE" bash
        ;;
    qyg)
        # Phase 4: start the QYG detector + solver against the running simulator.
        # The live QYG node_params directory is bind-mounted over the baked-in
        # copy when it exists, so parameter edits do not need an image rebuild.
        QYG_RUN_ARGS=("${DOCKER_ARGS[@]}" -w /tmp -e PYTHONDONTWRITEBYTECODE=1)
        params_dir=/qyg_ws/config
        if [ -f "$QYG_DIR/src/rm_bringup/config/node_params/armor_detector_params.yaml" ]; then
            QYG_RUN_ARGS+=(-v "$QYG_DIR/src/rm_bringup/config/node_params:/qyg_params:ro")
            params_dir=/qyg_params
        fi
        docker run "${QYG_RUN_ARGS[@]}" "$QYG_IMAGE" \
            bash -lc 'source /qyg_ws/install/setup.bash && exec ros2 launch \
                /sim/docker/qyg/phase4_qyg.launch.py params_dir:='"$params_dir"' "$@"' _ "$@"
        ;;
    qyg-shell)
        docker run "${DOCKER_ARGS[@]}" "$QYG_IMAGE" bash -lc \
            'source /qyg_ws/install/setup.bash; exec bash'
        ;;
    phase4)
        # Automated closed loop in ONE container: simulator + QYG stack + probe.
        QYG_RUN_ARGS=("${DOCKER_ARGS[@]}"
            -w /tmp
            -e PYTHONDONTWRITEBYTECODE=1
            -e PHASE4_DURATION="${PHASE4_DURATION:-15}"
            -e PHASE4_MODE="${PHASE4_MODE:-0}"
            -e PHASE4_DUMP="${PHASE4_DUMP:-0}"
            -e PHASE4_TRACE="${PHASE4_TRACE:-0}")
        [ -n "${PHASE4_SCENARIO:-}" ] && QYG_RUN_ARGS+=(-e PHASE4_SCENARIO="$PHASE4_SCENARIO")
        params_dir=/qyg_ws/config
        if [ -f "$QYG_DIR/src/rm_bringup/config/node_params/armor_detector_params.yaml" ]; then
            QYG_RUN_ARGS+=(-v "$QYG_DIR/src/rm_bringup/config/node_params:/qyg_params:ro")
            params_dir=/qyg_params
        fi
        docker run "${QYG_RUN_ARGS[@]}" "$QYG_IMAGE" \
            bash -lc 'source /qyg_ws/install/setup.bash && exec \
                /sim/docker/qyg/run_phase4.sh params_dir:='"$params_dir"' "$@"' _ "$@"
        ;;
    sim)
        run_sim_script "--verbose" "$@"
        ;;
    godot)
        run_sim_script "" "$@"
        ;;
    *)
        docker run "${DOCKER_ARGS[@]}" "$IMAGE" "$command" "$@"
        ;;
esac
