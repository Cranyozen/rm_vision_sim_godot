# rclgd on ROS 2 Humble — container build

This directory builds **`rmvision-rclgd:humble`**: an image with rclgd (the
ROS 2 GDExtension for Godot) compiled against **ROS 2 Humble**, the Godot
**4.7.2** engine, and the `rm_interfaces` custom messages, all in one colcon
overlay.

**Result: yes, rclgd runs on Humble.** Upstream rclgd has no Humble branch
(it targets Jazzy/Kilted/Lyrical/Rolling), but the port needs only **three
small patches** — no architectural change. See
[`patches/`](patches) and the verification output in
[Verification](#verification).

## Quick start

```bash
# 1. Build the image (uses http://localhost:7000 as proxy by default)
docker/build.sh

# 2. Verify: doctor + headless publish/subscribe + custom-message discovery
docker/run.sh verify

# 3. Interactive shell with ROS Humble + rclgd overlay sourced
docker/run.sh shell

# 4. Run the simulator (windowed; passes through /dev/dri + X11)
docker/run.sh sim
#    or with explicit Godot args:
docker/run.sh godot --script res://tests/phase2_ros_check.gd
#    or headless (no rendering; Phase 2 feed checks need the windowed run):
docker/run.sh godot --headless --script res://tests/phase2_ros_check.gd
```

Environment knobs for `build.sh`: `PROXY=` (empty to disable), `IMAGE=`,
`RCLGD_BUILD_CACHE=`, `RM_INTERFACES_DIR=` (defaults to
`../QYG_QDVision2026/src/rm_interfaces` relative to this repo), `--no-cache`.

`run.sh godot`/`run.sh sim` forward every extra argument to Godot after
`--path /sim`, e.g. `docker/run.sh godot --script res://tests/phase2_ros_check.gd`
or `docker/run.sh godot --version`. `ROS_DOMAIN_ID` (default `42`) can be
overridden per run, e.g. `ROS_DOMAIN_ID=77 docker/run.sh sim`, so several
simulators/checks can run side by side without cross-talk.

## What the image contains

| Path | Contents |
| --- | --- |
| `/ros_ws/install/rclgd/lib/rclgd/librclgd.so` | the GDExtension library |
| `/ros_ws/install/rclgd/lib/rclgd/godot-bin` | Godot **4.7.2** stable, SHA512-verified at build |
| `/ros_ws/install/rclgd/lib/rclgd/godot` | launcher used by `ros2 run rclgd godot` |
| `/ros_ws/install/rm_interfaces/...` | `rm_interfaces` messages (`GimbalCmd`, `SerialReceiveData`, …) |
| `/ros_ws/install/ros_babel_fish/...` | runtime message handler (Humble branch) |
| `/usr/local/bin/godot` | symlink to the bundled Godot 4.7.2 binary |
| `/opt/prepare_sim_project.sh` | links `librclgd.so` into `/sim/addons/rclgd/bin/` and registers the extension before a non-editor run |
| `/opt/rclgd-test/` | headless smoke test project + `run_smoke.sh` |
| `/opt/patches/` | the three patches applied to the rclgd sources |
| `/opt/ros/humble/.../foxglove_bridge` | Foxglove Studio WebSocket bridge (`ros-humble-foxglove-bridge`) |

Pinned upstream revisions (checked out by `build.sh`, all overridable):

| Repo | Ref | Commit |
| --- | --- | --- |
| `Ozuba/rclgd` | `rolling` (3.0.0) | `4d0a8b3ff98cc6b13d3c46725576644f5bc89440` |
| `LOEWE-emergenCITY/ros_babel_fish` | `humble` (1.25.x) | `c76d4ef565cc0340e2c8193a6bad3fcdba591fb7` |
| `godotengine/godot-cpp` | `master` (API 4.7) | `8070599885b6df675fcad033dd032ce44be2b850` |
| Godot engine | `4.7.2-stable` linux.x86_64 | sha512 `9aa00f7a…54c65` |

`godot-cpp` is used at `master` because that is the checkout that carries the
`extension_api-4-7.json` matching Godot 4.7.2 (godot-cpp has no 4.7 branch).
`GODOTCPP_API_VERSION=4.7` selects that API file.

## Patches (why rclgd did not build on Humble)

### `0001-godot-4.7.2-and-api-json.patch`

1. Retargets the engine pin from 4.7.1 to **4.7.2** (`GODOT_VERSION`) and
   refreshes both SHA512 pins from the 4.7.2 release's `SHA512-SUMS.txt`
   (the SHA512 is still enforced, so a bad archive is a hard build error).
2. godot-cpp ≥ 4.6 ships one API JSON per engine minor
   (`gdextension/extension_api-4-7.json`) and no longer has the unversioned
   `extension_api.json` that rclgd's CMakeLists reads; the patch resolves the
   file matching `GODOT_VERSION` with a fallback to the legacy name.
3. Adds `RCLGD_GODOT_ARCHIVE`: if it points at a pre-downloaded engine zip,
   CMake stages it where `file(DOWNLOAD)` expects it. This makes the container
   build work offline/deterministically instead of fetching Godot from inside
   the build; the hash check is unchanged.

### `0002-rbf-humble-array-api.patch`

`ros_babel_fish` 3.x (Rolling/Kilted) encodes the array size as a single
`ArraySize` enum (`ArrayMessage_<T, ArraySize>`), and its
`RBF2_TEMPLATE_CALL_ARRAY_TYPES` macro derives the bounded/fixed flags.
The `humble` branch of ros_babel_fish (1.x) still uses the older
`ArrayMessage_<T, BOUNDED, FIXED_LENGTH>` / `CompoundArrayMessage_<BOUNDED,
FIXED_LENGTH>` form. The patch only re-parameterises the conversion helpers in
`rclgd/src/rclgd/utils/ros_type_utils.hpp`; the conversion logic itself is
untouched (the macro already does the same runtime dispatch on Humble).
This was the bulk of the original 507 compile errors.

### `0003-humble-node-create-timer.patch`

`rclcpp::Node::create_timer(duration, callback)` is a Rolling addition;
Humble only has `create_wall_timer` and the free
`rclcpp::create_timer(node, clock, period, callback)`. The patch uses the free
function with the **node clock**, which keeps rclgd's intended semantics
(`use_sim_time` / `Engine.time_scale` aware timers) instead of silently
switching to a wall timer.

Nothing else in rclgd needed changes: the rclcpp/rclcpp_action/tf2_ros APIs it
uses (publishers, subscriptions, services, actions, TF broadcast/listen,
parameters, graph introspection) already exist in Humble.

## Foxglove debug bridge

The image ships `ros-humble-foxglove-bridge`, so you can inspect the live ROS
graph (images, TF, serial data, plotting) in [Foxglove Studio](https://foxglove.dev/)
without installing ROS on the host.

```bash
# terminal 1: simulator
docker/run.sh sim

# terminal 2: bridge (host networking => port 8765 is on localhost)
docker/run.sh foxglove

# then in Foxglove Studio: Open connection -> Foxglove WebSocket -> ws://localhost:8765
```

Two profiles live in this directory:

| Command | Port | Topics |
| --- | --- | --- |
| `docker/run.sh foxglove` | 8765 | JPEG `/image_raw/compressed`, `/camera_info`, `/tf`, `/tf_static`, `/serial/receive`, `/cmd_*`, `/armor_solver/*`, `/armor_detector/*`, `/rosout` |
| `docker/run.sh foxglove-tf` | 8767 | no camera topics: `/tf`, `/tf_static`, `/serial/receive`, `/camera_info`, `/cmd_*`, `/armor_solver/*`, `/rosout` |
| `docker/run.sh foxglove-full` | 8766 | every topic, including raw `/image_raw` (3.9 MB/message, ~120 MB/s at 30 Hz) |

The TF tree is rooted at `map` (field origin, with `map -> odom` following the
chassis), so set the Foxglove **3D panel fixed frame to `map`** to see the
robot move inside the field instead of at the origin.

The default profile deliberately excludes raw `/image_raw`; use
`foxglove-full` only on localhost or a fast wired link. All profiles allow the
client to publish `/cmd_*` and `/armor_solver/*`, so you can nudge the gimbal
or send a `GimbalCmd` from Studio. The bridge uses the same `ROS_DOMAIN_ID` as
the simulator container (default `42`; pass `ROS_DOMAIN_ID=77` to both if you
changed it).

### "odom is stale / transform age >500 ms"

The simulator publishes `map→odom` every rendered frame and on every camera
capture (~130 Hz, monotonic stamps); `tf2_monitor map odom` reports sub-ms
delay. If Foxglove shows a stale transform, the delay is on the **client /
bridge queue**, not in ROS: a stalled or CPU-starved Foxglove client stops
reading its websocket, the bridge queues messages (60 Hz JPEG makes this much
worse), and the transform ages until the client catches up. Reproduce it with a
websocket client that pauses reads for 2 s: TF age jumps to ~2 s.

Mitigations:

- Use `docker/run.sh foxglove-tf` (port 8767) for motion/TF work — no camera
  stream, ~40 KB/s, so the TF tree stays fresh even on a busy desktop.
- Keep the Image panel small or close it; avoid many 3D panels.
- Reconnect the Foxglove data source after restarting the simulator (a client
  that connected to a previous run can keep stale metadata).
- Check the live values from inside the container:
  `ros2 run tf2_ros tf2_monitor map odom` and
  `ros2 topic hz /tf` should show <1 ms delay / ~350 Hz.

## Windowed run and Phase 2 acceptance

`docker/run.sh sim` / `docker/run.sh godot [args]` first run
`/opt/prepare_sim_project.sh`, because a non-editor run needs two things the
Godot editor normally sets up:

1. **Activate `addons/rclgd/bin/rclgd.gdextension`.** The repo ships it as
   `rclgd.gdextension.template` so a plain host Godot run (no ROS libraries)
   never tries to load rclgd and never prints missing-library errors. The
   prepare script copies the template to the active name. That file lists the
   bare name `librclgd.so`, and GDExtension resolves relative library paths
   **relative to the `.gdextension` file**, i.e. `addons/rclgd/bin/`, not
   relative to the engine binary. The installed layout
   (`/ros_ws/install/rclgd/lib/rclgd/`) therefore does **not** work with the
   bare name; the prepare script creates the symlink
   `addons/rclgd/bin/librclgd.so -> /ros_ws/install/rclgd/lib/rclgd/librclgd.so`.
2. **`.godot/extension_list.cfg` must list the extension.** The editor import
   pass writes it; the prepare script appends
   `res://addons/rclgd/bin/rclgd.gdextension` when missing and runs
   `godot --headless --path /sim --import` once for a fresh checkout.

`docker/run.sh` removes the active descriptor, the `librclgd.so` symlink and
the extension-list entry when Godot exits, so host runs stay clean even after
a container session.

Verified on this host (AMD Radeon via RADV, X11/XWayland):

```
Vulkan 1.3.255 - Forward+ - Using Device #0: AMD - AMD Unknown (RADV GFX1103_R1)
ROS 2 Executor running in separate thread
Main: ROS backend up (rclgd)
```

and the same windowed container seen from a second container on the host
network:

```
$ docker run --rm --network host --ipc host -e ROS_DOMAIN_ID=42 \
      rmvision-rclgd:humble bash -c 'ros2 topic list'
/armor_solver/cmd_gimbal
/camera_info
/cmd_chassis
/cmd_gimbal
/image_raw
/image_raw/compressed
/serial/receive
/tf
/tf_static
$ ... ros2 topic hz /camera_info
average rate: 9.999
```

To run the CLI acceptance script against a live simulator, start `sim` in one
terminal and in another:

```bash
docker run --rm -it --network host --ipc host -e ROS_DOMAIN_ID=42 \
    -v "$PWD:/sim" -w /sim rmvision-rclgd:humble ./tests/phase2_ros_cli.sh
```

(`docker/run.sh` does not start long-running servers itself; `sim` is a
foreground Godot process and Ctrl-C stops it cleanly.)

Audio: the container has no `/dev/snd`; Godot falls back to the dummy audio
driver (`All audio drivers failed, falling back to the dummy driver`). This is
expected and does not affect rendering or ROS.

## Verification

`docker/run.sh verify` output (abridged; see the final report for the full log):

```
✓ ROS_DISTRO=humble, default rmw
✓ rclgd sourced from /ros_ws/install/rclgd
✓ extension library /ros_ws/install/rclgd/lib/rclgd/librclgd.so
✓ godot launcher installed (ros2 run rclgd godot)
✓ version pin: Godot 4.7.2
✓ godot 4.7.2.stable.official.ed1daf0bf at /ros_ws/install/rclgd/lib/rclgd/godot-bin
all checks passed
```

The headless smoke test (`docker/test/rclgd_smoke.gd`) then loads the extension
in Godot 4.7.2 headless and proves: `rclgd.init()`, `RosNode` creation,
`std_msgs/msg/String` publish+subscribe loopback, and
`RosMsg.from_type("rm_interfaces/msg/GimbalCmd")` +
`RosMsg.from_type("rm_interfaces/msg/SerialReceiveData")` discovery, ending with
`RCLGD_SMOKE: PASS`.

The verified image is `rmvision-rclgd:humble`
(`sha256:885e0c4f85e3c192051d1ae05ac83970b681ef95afca70bcc2bbb7c83fb605ab`,
~2.55 GB on disk). The same pin-set/patches rebuild from scratch with
`docker/build.sh --no-cache`.

## Using the extension in the simulator project

The project ships `addons/rclgd/bin/rclgd.gdextension.template`; inside the
container `prepare_sim_project.sh` activates it as
`addons/rclgd/bin/rclgd.gdextension`, symlinks the installed `librclgd.so`
next to it, and registers it in `.godot/extension_list.cfg`. Do not commit the
active descriptor: on a host without ROS it would make Godot print
missing-library errors on every run. `docker/run.sh` deletes it on exit.

Start the node with `node.init("rm_vision_sim")` before publishing; topic
types are the same strings `ros2` uses (`sensor_msgs/msg/Image`, …), and custom
`rm_interfaces` types are resolved through `AMENT_PREFIX_PATH`, which the
container entrypoint sources.

## Known limitations

- **GPU / X11**: `run.sh` passes `/dev/dri`, the X11 socket, `XAUTHORITY`
  and (when present) the Wayland socket through, plus the host `video`/`render`
  group IDs. The image ships Ubuntu 22.04 mesa (`mesa-vulkan-drivers`,
  `libgl1-mesa-dri`) which works with the host's AMD/Intel kernel driver. On
  this host Vulkan/Forward+ on RADV is verified. If Godot falls back to
  llvmpipe (black/blurry feed), check your user's `video`/`render` group
  membership and `/dev/dri` permissions on the host first — do not disable
  rendering.
- **NVIDIA**: not configured; add `--gpus all` / `nvidia-container-toolkit`
  (and the host driver libs) yourself. The default path is mesa (AMD/Intel).
- **`prepare_sim_project.sh` writes into the mounted project**: it creates the
  active `addons/rclgd/bin/rclgd.gdextension`, the `librclgd.so` symlink and
  the `.godot/extension_list.cfg` entry (and runs `--import` on a fresh
  checkout). Files created by the container are root-owned; `docker/run.sh`
  removes the rclgd ones on exit. Those paths are also in `.gitignore`.
- **`--network host` + `--ipc host`** are required for DDS discovery and fast
  shared-memory transport; the container sets `ROS_DOMAIN_ID=42` by default so
  it does not collide with an existing ROS graph on the host (`ROS_DOMAIN_ID=…`
  overrides).
- **Humble only**: the patches hard-code Humble-era rclcpp/ros_babel_fish
  behaviour. On Jazzy+ use upstream rclgd unpatched (patch 0002/0003 would not
  apply cleanly; 0001 is still needed for the 4.7.2 pin if upstream hasn't
  bumped it).
- **Build time/size**: the image is built from source; the Godot engine binary
  alone is ~146 MB, `docker images` reports ~2.5 GB on disk (ROS base ~1.1 GB).
  The colcon build tree is deleted from the image.
- **Proxy vs docker build**: `build.sh` uses `http://localhost:7000` for the
  host-side source fetches, but does **not** pass it as a docker build arg: the
  proxy listens on host loopback and is unreachable from the build network, so
  exporting it would break `apt-get`. The apt layer uses the daemon's direct
  network instead.
- **rclgd 3.0.0 vs docs**: the checkout is `rolling`/3.0.0 (the branch that
  supports Godot 4.7); `main` at the same revision also pins 4.7.1. There is
  no upstream Humble branch and no upstream 2.1.0-based Godot-4.7 support.
