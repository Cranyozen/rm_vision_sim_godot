# Phase 4 QYG vision stack (`rmvision-qyg:humble`)

Runtime image for the closed loop between this simulator and QYG's
`armor_detector` + `armor_solver`. It is derived from
`rmvision-rclgd:humble` (rclgd + Godot + `rm_interfaces`) and adds only the QYG
vision packages, so the simulator and the vision stack can run side by side on
the same ROS 2 graph.

The simulator plays the MCU: it publishes `/image_raw`, `/camera_info`, TF and
`/serial/receive`, and consumes the solver's `/armor_solver/cmd_gimbal`. QYG's
`camera_driver`, `serial_driver`, `virtual_serial` and `robot_state_publisher`
are deliberately **not** built into the image and must not be started — they
would fight the simulator over the camera, TF and serial port.

Status: verified end to end on this host with `PHASE4_QYG: PASS` for
`1v1_static`, `1v1_line`, `3v3_spin` and `flat_range` (YOLO, OpenVINO CPU,
~27–29 Hz detection, <1° convergence error, ~10 ms image latency). The
traditional OpenCV backend does **not** work on the rendered scenes (see
[Troubleshooting](#troubleshooting)); use YOLO.

See also: [Phase 4 acceptance checklist](../../docs/PHASE4_ACCEPTANCE.md),
[QYG ↔ simulator contract](../../docs/QYG_PHASE2_CONTRACT.md),
[base container notes](../README.md).

## Image contents

| Path | Contents |
| --- | --- |
| `/qyg_ws/install/{rm_interfaces,rm_utils,armor_detector,armor_solver}` | The four QYG packages built with `colcon` (`Release`, tests off). |
| `/qyg_ws/config/` | Baked copy of QYG's `src/rm_bringup/config/node_params/*.yaml`. |
| OpenVINO 2025.3 | Runtime for the YOLO armor detector (`openvino-2025.3.0` apt package); the CPU plugin is used here. |
| base image | `rmvision-rclgd:humble`: ROS 2 Humble, rclgd GDExtension, Godot 4.7.2, `rm_interfaces`, Foxglove bridge. |

The image has the base image's entrypoint, so `/opt/ros/humble` and
`/ros_ws/install` are sourced automatically. `docker/run.sh qyg*` additionally
sources `/qyg_ws/install/setup.bash`.

## Build

```bash
# from the repository root
docker/qyg/build.sh
```

- Default QYG checkout: `$REPO_ROOT/../QYG_QDVision2026`; override with
  `QYG_DIR=/path/to/QYG_QDVision2026`.
- Output image: `rmvision-qyg:humble`; override with `QYG_IMAGE=`.
- The script stages only the four packages plus
  `$QYG_DIR/src/rm_bringup/config/node_params/` into the build context
  (default `/tmp/rmvision-qyg-ctx`, override with `QYG_BUILD_CTX`), then runs
  `docker build`. The QYG checkout itself is never modified.
- `docker/qyg/build.sh --no-cache` forces a full rebuild.
- `rmvision-rclgd:humble` must exist first (`docker/build.sh`,
  `docker/run.sh verify`). The build container needs direct network access for
  `apt` (the host proxy is not passed into the build); if networking is
  restricted, see `AGENTS.md` §0.2.

Check:

```bash
docker image inspect rmvision-qyg:humble --format '{{.Id}} {{.Created}}'
```

## Run

The simulator must already be running (windowed, same `ROS_DOMAIN_ID`, and
`docker/run.sh` gives both containers `--network host --ipc host`):

```bash
# terminal 1: simulator (GPU/display required)
docker/run.sh sim

# terminal 2: QYG detector + solver (foreground; Ctrl-C stops it)
docker/run.sh qyg

# optional: Foxglove bridge on ws://localhost:8765
docker/run.sh foxglove

# interactive shell in the QYG image (ROS + QYG overlay sourced)
docker/run.sh qyg-shell
```

`docker/run.sh qyg` can start before the simulator; the detector simply drops
frames until `/image_raw` and `/camera_info` are being published. It forwards
every extra argument to the launch file, e.g.:

```bash
docker/run.sh qyg mode:=1
docker/run.sh qyg detector:=tradition binary_thres:=60
docker/run.sh qyg mode:=1 detector:=tradition ignore_negative:=false
```

Do not run QYG in the base image; the QYG packages only exist in
`rmvision-qyg:humble`.

### One-container end-to-end run

`docker/run.sh phase4` runs the simulator, the QYG stack and the probe in a
single container (windowed Godot, so a display is still required):

```bash
docker/run.sh phase4
PHASE4_DURATION=30 docker/run.sh phase4
PHASE4_MODE=1 docker/run.sh phase4
PHASE4_SCENARIO=res://scenarios/1v1_line.yaml docker/run.sh phase4
docker/run.sh phase4 detector:=tradition binary_thres:=60
```

Environment variables: `PHASE4_DURATION` (measurement window, default 15 s),
`PHASE4_MODE` (0 = red, 1 = blue; default 0), `PHASE4_SCENARIO` (optional
`--scenario=` override), `PHASE4_TRACE=1` (print cmd/sim aim telemetry a few
times per second), `PHASE4_DUMP=1` (save `/image_raw` and detector debug images
to `tests/phase4_dump_*.png` for inspection). Extra arguments after `phase4` go
to the launch file.
It prints `PHASE4_QYG: PASS`/`FAIL` and the metrics JSON; logs are
`/tmp/phase4_godot.log` and `/tmp/phase4_qyg.log` inside the container.

## Launch arguments (`phase4_qyg.launch.py`)

| Argument | Default | Meaning |
| --- | --- | --- |
| `params_dir` | `/qyg_ws/config` | Directory with QYG's `armor_detector_params.yaml` / `armor_solver_params.yaml`; `run.sh` points it at the live mount when available. |
| `mode` | `0` | Vision mode: `0` = auto-aim red, `1` = auto-aim blue. Applied via the `set_mode` services 2 s after startup. |
| `detector` | `yolo` | Detector backend: `yolo` (OpenVINO IR) or `tradition` (OpenCV fallback). |
| `device` | `CPU` | OpenVINO device for YOLO. CPU works on this AMD host; `GPU` needs an Intel GPU + driver stack. |
| `binary_thres` | empty | Overrides the YAML `binary_thres: 80`; only used by the traditional detector. Empty keeps the YAML value. |
| `ignore_negative` | `true` | Drop armors whose number classifier says `negative`. `false` clears `ignore_classes` so rendered digits classified as `negative` are kept. |
| `yolo_conf` | empty | Overrides `yolo.conf_threshold` (YAML default `0.65`). Empty keeps the YAML value. |
| `target_frame` | `odom` | Frame the solver expresses targets in; the simulator publishes `odom`. |
| `detector_debug` | `true` | Publish `/armor_detector/armors` and detector debug output. Turning it off hides the topic the tests subscribe to. |
| `solver_debug` | `false` | Publish solver debug image/markers. |

The launch also always sets the simulator-specific overrides
`use_state_machine_camera=false`, `enable_record=false`, `gimble_frame=gimbal_link`,
and keeps both nodes in one composable container.

## One-process architecture

`armor_solver` does **not** subscribe to `/armor_detector/armors`. The detector
publishes each processed frame into the in-process `VisionStateMachine`
singleton, and the solver blocks on that slot in its worker thread. Running the
two nodes as separate processes (or separate containers) leaves the solver
idle — it still emits idle `GimbalCmd` messages, so it is easy to miss.

The launch therefore loads both as `ComposableNode`s in one
`component_container_mt` with intra-process comms. Keep it that way. Starting
QYG's stock `bringup_SingleProcess.launch.py` is not an option: it opens the
Hik camera, starts the serial driver and `robot_state_publisher`, all of which
conflict with the simulator.

## Parameters

- Default source: the baked `/qyg_ws/config/`, copied from
  `$QYG_DIR/src/rm_bringup/config/node_params/` at build time.
- Live override: when
  `$QYG_DIR/src/rm_bringup/config/node_params/armor_detector_params.yaml`
  exists, `docker/run.sh qyg` / `phase4` bind-mount that directory read-only at
  `/qyg_params` and pass `params_dir:=/qyg_params`. Editing the QYG YAML and
  restarting the container is enough; there is no hot reload and no image
  rebuild.
- To force the baked copy, point `QYG_DIR` at a path without `node_params`
  (the script falls back to `/qyg_ws/config`).
- Inspect the effective values with `ros2 param dump /armor_detector` and
  `ros2 param dump /armor_solver` from `docker/run.sh qyg-shell`.

The QYG checkout is treated as read-only by this project: do not patch its
sources for the simulator, and keep tuning in the YAML / launch arguments.

## Topics (simulator ↔ QYG)

| Direction | Topic | Type | Notes |
| --- | --- | --- | --- |
| sim → QYG | `/image_raw` | `sensor_msgs/Image` | 1280×1024 `rgb8`, 30 Hz, `frame_id=camera_optical_frame` |
| sim → QYG | `/camera_info` | `sensor_msgs/CameraInfo` | 10 Hz, feed intrinsics, must arrive before images |
| sim → QYG | `/tf`, `/tf_static` | TF | `map→odom→gimbal_link→camera_link→camera_optical_frame`; target centres on dynamic `/tf` |
| sim → QYG | `/serial/receive` | `rm_interfaces/SerialReceiveData` | 50 Hz; `bullet_speed=25.0`, yaw/pitch in degrees (pitch up-positive); `mode` is a fixed debug value |
| QYG → sim | `/armor_solver/cmd_gimbal` | `rm_interfaces/GimbalCmd` | solver timer ~250 Hz; absolute yaw/pitch in `odom`, degrees; `distance<0` = idle. The simulator also listens on the legacy `/cmd_gimbal` name |
| QYG → observer | `/armor_detector/armors` | `rm_interfaces/Armors` | published only with `detector_debug:=true` |
| QYG → observer | `/armor_solver/target`, `/armor_solver/armors`, `/armor_solver/measurement`, `/armor_solver/ballistic_debug` | `rm_interfaces/*` | tracking / debug outputs in `odom` |
| QYG → observer | `/armor_detector/marker`, `/armor_solver/marker`, `/armor_solver/result_img` | visualization / image | debug output |

Quick checks from the host:

```bash
docker/run.sh ros2 topic list | grep -E 'image_raw|camera_info|armor|serial'
docker/run.sh ros2 topic hz /image_raw
docker/run.sh ros2 topic hz /armor_detector/armors
docker/run.sh ros2 topic echo /armor_solver/target --once
docker/run.sh ros2 topic echo /armor_solver/cmd_gimbal --once
```

`docker/run.sh ros2 ...` runs any command in the base image, which already has
`rm_interfaces`; use `docker/run.sh qyg-shell` when you need the QYG overlay
(e.g. `ros2 param`, or the Python test).

## Vision mode

The real robot's serial driver pushes the vision mode from the MCU byte; in
this stack no serial driver runs, so the launch sets it once through the
`/armor_detector/set_mode` and `/armor_solver/set_mode` services
(`rm_interfaces/srv/SetMode`). `mode:=0` is red, `mode:=1` is blue.

`/serial/receive.mode` published by the simulator is **not** a mode control:
it is a fixed debug value (`RosConfig.SERIAL_MODE = 1`) and no QYG node in this
launch consumes it. To switch colour manually:

```bash
docker/run.sh qyg-shell
ros2 service call /armor_detector/set_mode rm_interfaces/srv/SetMode "{mode: 1}"
ros2 service call /armor_solver/set_mode   rm_interfaces/srv/SetMode "{mode: 1}"
```

## Foxglove visualization

Run `docker/run.sh qyg solver_debug:=true` (so `/armor_solver/result_img` is
published), then `docker/run.sh foxglove-phase4` and open
`ws://localhost:8768` in Foxglove Studio. Import
[`foxglove_phase4_layout.json`](../foxglove_phase4_layout.json) from the
Layouts menu to get the camera feed, solver overlay, `map`-fixed 3D TF/markers,
gimbal-tracking plots and target/armor raw messages. See
[`../README.md`](../README.md#phase-4-closed-loop) and
[`../../docs/PHASE4_ACCEPTANCE.md`](../../docs/PHASE4_ACCEPTANCE.md) §4.6.

## Tests

End-to-end, one container (recommended):

```bash
docker/run.sh phase4
# expect `PHASE4_QYG: PASS` in the output (a QYG log tail follows)
```

Manual measurement against a running `sim` + `qyg` pair:

```bash
docker/run.sh qyg-shell
# inside the container:
python3 /sim/tests/phase4_qyg_check.py --duration 15 --json-out /tmp/phase4_metrics.json
```

`tests/phase4_qyg_check.py` reports detection rate / non-empty ratio,
`/armor_solver/target` tracking ratio, `/armor_solver/cmd_gimbal` rate and
convergence (`yaw_diff`/`pitch_diff`, skipping the first third of the run),
image-to-callback latency, and the closed-loop gimbal error between
`/serial/receive` and the solver's `exp_yaw`/`exp_pitch`. Default pass
thresholds: detection ≥ 3 Hz and ≥ 50 % non-empty, tracking ≥ 20 %, cmd stream
≥ 5 Hz, yaw error ≤ 3°, closed-loop samples ≥ 10 with median yaw error ≤ 3°,
serial ≥ 20 Hz with a positive bullet speed and a non-empty mode set. Override them with
`--min-detection-hz`, `--min-nonempty`, `--min-tracking`, `--min-cmd-hz`,
`--max-yaw-error`; `--json-out` stores the metrics.

Scenario runs:

```bash
PHASE4_SCENARIO=res://scenarios/1v1_static.yaml docker/run.sh phase4
PHASE4_SCENARIO=res://scenarios/1v1_line.yaml   docker/run.sh phase4
PHASE4_SCENARIO=res://scenarios/3v3_spin.yaml   docker/run.sh phase4
PHASE4_SCENARIO=res://scenarios/flat_range.yaml docker/run.sh phase4
```

## Troubleshooting

| Symptom | Check / fix |
| --- | --- |
| `IMAGE NOT FOUND` / image old | `docker/qyg/build.sh`; confirm `rmvision-rclgd:humble` exists and matches QYG sources. |
| No `PHASE4_MODE: set vision mode N` line | The mode setter could not reach the services. Call both `set_mode` services manually (above); the setter waits up to 40 s per service. |
| `/armor_detector/armors` missing | `detector_debug` must be `true` (the topic is debug-gated); check the launch arguments. |
| `armors` always empty (tradition) | Expected on rendered scenes: the bright sky/ground makes `findContours(RETR_EXTERNAL)` return only the background outline, so the LED bars are dropped. `binary_thres` cannot fix both background and bars; use `detector:=yolo`. |
| `armors` always empty (YOLO) | Verify `/image_raw` and `/camera_info` publishers; run with `PHASE4_DUMP=1` and inspect `tests/phase4_dump_raw.png`. If the white number sticker flickers/aliases on the dark panel, the sticker/panel depth conflict is back: `ArmorPlate.gd` lifts the sticker by 0.5 mm (`mi.position.z += 0.0005`) to avoid z-fighting — check that it is still there. |
| Armor numbers come out `negative` / tracking has odd ids | Restart with `ignore_negative:=false` (clears `ignore_classes`). The rendered digits do not look like QYG's training data. |
| No `/armor_solver/target` | The detector and solver must be in the same process — use this launch, not two `ros2 run`s. |
| Commands visible but gimbal does not move | Confirm the simulator logs `ROS backend up (rclgd)` and the topic is `/armor_solver/cmd_gimbal` (the solver's real name). |
| `Transform error` in solver logs | The simulator must be running and publishing `/tf` with image-time coverage; do not start QYG `robot_state_publisher`. |
| `fire_advice` always false | Not a failure: Phase 4 does not implement firing. `bullet_speed` is 25.0 m/s from `/serial/receive`. |
| Black / corrupt rendering, llvmpipe | GPU permissions: check the host user's `video`/`render` groups and `/dev/dri`; see `AGENTS.md` §0.1. Do not disable rendering. |
| Very slow detection | YOLO runs on OpenVINO **CPU** here (AMD host). `device:=GPU` needs an Intel GPU. Measured ~6–10 ms inference and ~27–29 Hz end-to-end detection on this machine, which is enough for the closed loop. |
| `flat_range` targets not tracked | The scenario's far targets (roughly 8.6–13 m) exceed the solver's default `max_armor_distance: 10.0 m`; use closer scenarios for full closed-loop runs. |

## Related

- [Phase 4 acceptance checklist](../../docs/PHASE4_ACCEPTANCE.md) — manual
  checklist, measurements table, known limitations.
- [QYG ↔ simulator contract](../../docs/QYG_PHASE2_CONTRACT.md) — topic names,
  QoS, TF conventions and the one-process requirement.
- [Base container notes](../README.md) — rclgd image, Foxglove bridge, GPU/X11
  passthrough.
- `docker/run.sh` (`qyg`, `qyg-shell`, `phase4`), `docker/qyg/build.sh`,
  `docker/qyg/phase4_qyg.launch.py`, `docker/qyg/run_phase4.sh`,
  `docker/qyg/set_vision_mode.py`, `tests/phase4_qyg_check.py`.
