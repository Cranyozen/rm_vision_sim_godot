# Architecture — RM Vision Sim Godot

This document is the design record for the simulator. It describes what Phase 1
implements today and the contracts Phase 2+ will add.

## 1. Goals and non-goals

**Goal.** A lightweight Godot simulator that lets the QYG `rm_vision` auto-aim
stack detect, solve and command a simulated gimbal with realistic camera images
and a real robot model.

**Non-goals for Phase 1.** Physics, URDF dynamics, firing/hit simulation,
recording, UC field. Those are deliberately deferred.

## 2. Deployment topology

| Mode | Where Godot runs | ROS transport | Status |
| --- | --- | --- | --- |
| Phase 1 | host | none | implemented |
| Phase 2 direct (preferred) | inside the ROS 2 Humble container | rclgd GDExtension (`rclcpp`, no bridge) | planned |
| Fallback | host | thin TCP bridge in the container | only if direct fails |

Direct mode is preferred because it removes the bridge process and the extra
frame copy. rclgd must be built against the container's Humble libraries; a
host Arch Godot cannot load that `.so`. The Phase 2 spike therefore runs Godot
inside the Humble container with GPU/display passthrough, builds rclgd against
Godot 4.7.2, and checks `ros2 rclgd doctor` before any feature work.

The simulated world plays the role of the **MCU**: it publishes the gimbal TF
and `SerialReceiveData`, and consumes `GimbalCmd` / `ChassisCmd`.

## 3. Coordinates, frames and units

### Godot world

- Y up, right-handed, metres.
- The ego's gimbal chain looks along **−Z** at yaw = 0.
- Field 1v1 is 5.6 × 5.6 m; the playable floor is 5.0 × 5.0 m at `y = 0`.
- 3v3 is 12.6 × 8.6 m with its play surface at `y = 0.10`; when enabled it must
  be shifted by −0.10 m so the play surface becomes `y = 0`.

### ROS REP-103

The ROS-side transform follows the convention used by the previous simulator:

```
ros_x = -godot_z      # Godot forward (−Z) → ROS forward (+X)
ros_y = -godot_x      # Godot right (+X)  → ROS left (+Y)
ros_z =  godot_y      # Godot up (+Y)     → ROS up (+Z)
```

`GimbalCmd` / `SerialReceiveData` angles are **degrees** in this project (the
QYG msg comments do not state a unit; its serial driver and the previous stack
use degrees). Pitch is positive up, matching the QYG `SerialReceiveData`
comment.

### TF tree (Phase 2)

```
map ──(static)── odom ──(dynamic, 100–200 Hz)── gimbal_link
                                                  ├──(static)── camera_link
                                                  │                └──(static)── camera_optical_frame
                                                  └──(static)── muzzle (optional, not published in P2)
```

- `map → odom`: static identity.
- `gimbal_link → camera_link`: QYG `gimbal2camera` mount
  `xyz = (0.0461892, 0.0, -0.0603874)`,
  `rpy = (0.0, 0.091, 0.0)`.
- `camera_link → camera_optical_frame`: `rpy = (-π/2, 0, -π/2)` (REP-103
  optical convention).
- `gimbal_link` orientation is `Rz(yaw) · Ry(pitch) · Rx(roll)`, published as a
  quaternion. The default roll is 0.
- `/tf` is reliable, KeepLast(100). `/tf_static` is transient-local and
  published once.

### Units

| Quantity | Unit |
| --- | --- |
| world / mount translation | metres |
| gimbal yaw / pitch / roll | degrees on ROS topics |
| `GimbalCmd` distance | metres |
| bullet speed | m/s |
| image timestamps | nanoseconds, system clock (no `/clock` in P2) |

## 4. Ego rig

`scenes/ego/EgoRig.tscn` → `scripts/sim/EgoRig.gd`.

```
EgoRoot (chassis yaw, world position)
├─ VehicleModel (assets/models/ego/vehicle.glb, +Y floor offset 0.2101 m)
└─ GimbalYaw (world Y, y = 0.2101)
   └─ GIMBAL (imported vehicle subtree, local X pitch; named GimbalPitch)
      └─ CameraMount (camera_link pose)
```

- The vehicle GLB is authored in metres, Y-up, with its chassis bottom at
  `y = −0.2101`; the root is raised by `0.2101 m`.
- The imported `GIMBAL` node is re-parented under the explicit yaw pivot and
  reset to identity; it then serves as the pitch joint. This preserves the real
  model's gimbal geometry while giving the simulator clean control.
- `vehicle.glb` also ships two detached `激光检测总装` (laser detection
  assembly) meshes under `GIMBAL`; they hover 0.2 m and 0.4 m above the gimbal
  body instead of being mounted on it. `EgoRig` hides every node whose name
  starts with `激光检测总装` while building the rig (the source GLB is left
  untouched), so the visible mesh top stays at `y ≈ 0.435 m` in rig space.
  `tests/ego_model_check.gd` guards this.
- `CameraMount` uses the QYG mount offset/rpy above (preset `qyg`); the model's
  own `CAM_DIRECTION` is visual reference only.
- Pitch is clamped to ±30° in `EgoRig`, ±20° by the Phase 1 keyboard control.
- Ego geometry is layer `2`; field and targets are layer `1`. This lets the
  feed show/omit the ego without changing the TF.
- `set_gimbal(yaw_deg, pitch_deg)` is the single control entry point; Phase 2
  will call it from `GimbalCmd`.
- `preset = "infantry_light"` builds a 3 MB chassis GLB plus a procedural
  gimbal; `preset = "fallback"` builds boxes if an asset is missing.

The vehicle's source materials are near-black (`albedo ≈ 0.008` and pure
black). `EgoRig` lifts dark, non-emissive surfaces to a dark grey for
readability; team/emissive materials are untouched. Phase 5 replaces this with
the final material setup.

### 4.1 Armour modules (targets)

`scripts/sim/ArmorPlate.gd`, `scripts/sim/TargetRig.gd`.

- Geometry: the **official game armour modules used by the Bevy simulator**
  (the sibling `bevy_robomaster_simulator` project). The AM02 small module
  is extracted from `assets/vehicle.glb` (root node `1_ARMOR_ROOT`) and the
  AM12 large module from `assets/HERO.glb` (root node `1_AM12_ARMOR_ROOT`),
  one module subtree each, into `assets/models/armor/armor_small.glb`
  (0.51 MB, 14 parts) and `armor_large.glb` (0.81 MB, 12 parts) with
  `tools/extract_armor.py`. Extracted envelopes are 141.0 × 129.9 × 19.2 mm
  (small) and 236.0 × 132.2 × 19.2 mm (large). The game mesh is shallower than
  the real CAD module (19 mm vs 52 mm); the CAD-derived `am01_small.glb` /
  `am11_large.glb` (DOCS/27 STEP, via `step_to_stl.py` + `step_to_glb.py`)
  are kept for provenance but are no longer loaded.
- Canonical orientation: in the source GLB, an armour root's front normal is
  `-Y` and its up axis is `+Z`. `extract_armor.py` bakes a `-90°` rotation
  about X (plus the root/child transforms), so the extracted module has
  `+Z` = front, `+Y` = up, `+X` = width, origin at the bbox centre. That is
  exactly `ArmorPlate`'s local convention, so it instantiates the GLB with no
  extra rotation; `TargetRig` adds `PI` to each plate yaw so `+Z` faces
  outward.
- Node contract in the extracted GLBs: `BODY`, `BODY_BASE`, `PANEL_CENTER`
  (shell), `STICKER_2` … `STICKER_B` (white number geometry), and
  `LIGHT_L_RED` / `LIGHT_R_RED` / `LIGHT_L_BLUE` / `LIGHT_R_BLUE` (team light
  bars). `ArmorPlate._build()` keeps every shell node visible, shows only
  `STICKER_<number>` and only the `*_RED` or `*_BLUE` light pair — the same
  visibility toggling Bevy does in `src/robomaster/armor/construct.rs`.
- Number stickers are **mesh geometry, not a texture decal**, so the digits
  read correctly from the feed at any distance and never mirror. Stickers sit
  33 µm above the front face in the source; the extractor adds a 0.12 mm lift
  to avoid z-fighting, and the runtime disables sticker shadow casting / GI so
  the thin quads cannot self-shadow. Available numbers follow Bevy's slot
  tables: small = `2,3,4,5,B,G,O`; large = `1,3,4,5,B`. A number the asset
  lacks (e.g. small `1`) falls back to a `Label3D` at `z ≈ 0.0098 m`.
- Team lights are the asset's own emissive light-bar meshes; the PBR import
  keeps their red/blue emission, and hiding the other team's pair is all that
  is needed. No procedural LED boxes.
- Mounting angle: the real AM01/AM12 module is installed at **75° to the
  ground** (the DOCS/27 section marks 105° between the plate face and the
  ground on the outward side), i.e. a 15° lean with the top edge back toward
  the robot.
  `ArmorPlate.MOUNT_TILT_DEG = 15.0` applies `rotation.x = -15°` to the whole
  plate in `_ready()`, so the front normal points 15° upward and the number
  panel faces the (higher) camera of an opposing robot. `TargetRig` only sets
  the yaw; the tilt is a property of the module, so standalone uses
  (`tests/capture_armor.gd`) are tilted too.
- Target layout: 1/2/4 plates at radius `0.24 m` (small) or `0.30 m` (large),
  plate centre at `y = 0.25 m`; no target chassis and no physics in Phase 1.

## 5. Feed pipeline (Phase 1)

```
Main
├─ SubViewport "FeedViewport"  1280×1024, UPDATE_ALWAYS, no MSAA
│  └─ Camera3D "FeedCamera"    fov = 17.21°, near 0.05, far 80, cull_mask 1
├─ Camera3D "DebugCamera"      third-person / FPV, cull_mask 3
└─ HUD                         preview 320×256 + fullscreen
```

- The feed camera copies `EgoRig.get_camera_mount().global_transform` each
  frame.
- FOV is derived from the QYG 1440 × 1080 intrinsics scaled to 1280 × 1024:
  `vfov = 2·atan(H / (2·fy_scaled)) ≈ 17.21°`. `fx ≈ fy`, so Godot's
  `KEEP_HEIGHT` projection is within ~0.06 % of the ideal frustum.
- Phase 1 previews the viewport texture; there is no JPEG encode and no
  distortion model. Phase 2 adds `sensor_msgs/Image` + `CompressedImage`
  publishing; Phase 6 adds the Brown-Conrady model and off-centre `set_frustum`.

### Phase 2 image contract (planned)

| Topic | Type | Rate | Encoding | QoS |
| --- | --- | --- | --- | --- |
| `/image_raw` | `sensor_msgs/Image` | 30 Hz (configurable) | `rgb8` first; `bayer_rggb8` if QYG needs it | best-effort, KeepLast(1) |
| `/image_raw/compressed` | `sensor_msgs/CompressedImage` | 60 Hz | JPEG q90 | best-effort, KeepLast(1) |
| `/camera_info` | `sensor_msgs/CameraInfo` | 10 Hz | 1280×1024, scaled fx/fy/cx/cy, D = 0 in P2 | reliable |
| `/tf` | `tf2_msgs/TFMessage` | 100–200 Hz | odom→gimbal_link | reliable, KeepLast(100) |
| `/tf_static` | `tf2_msgs/TFMessage` | once | map→odom, gimbal_link→camera_link, camera_link→camera_optical_frame | transient-local |
| `/serial/receive` | `rm_interfaces/SerialReceiveData` | 50 Hz | degrees, mode 1, configurable bullet speed | best-effort |
| `/cmd_gimbal` | `rm_interfaces/GimbalCmd` (sub) | — | degrees | reliable |
| `/cmd_chassis` | `rm_interfaces/ChassisCmd` (sub) | — | optional | reliable |

The hot path avoids a second RGBA→RGB conversion: the viewport image is
converted once to `rgb8` (or Bayer), the raw message and the JPEG both derive
from that buffer. JPEG encoding runs on `WorkerThreadPool`; message objects and
buffers are reused. The 6.2 MB raw frame requires the Fast DDS shared-memory
profile (`maxMessageSize` > 6.2 MB, `ipc: host`) or DDS silently degrades to
UDP loopback.

## 6. QYG integration (Phase 2/4)

Do **not** launch QYG's `camera_driver`, `serial_driver` or
`robot_state_publisher`:

- `serial_driver` opens `/dev/rm_usb0`, publishes its own `/serial/receive`
  and TF, and will conflict with the simulator.
- `robot_state_publisher` cannot produce useful joint states for the floating
  `gimbal_link` joint; the simulator is the authoritative TF source.
- `camera_driver` would publish real/recorded images, not the simulated feed.

Launch only `armor_detector` + `armor_solver`. The detector must subscribe to
the image topics (`use_state_machine_camera:=false`); the solver input is
`armor_detector/armors`; the solver's `cmd_gimbal` is remapped to `/cmd_gimbal`.
The detector uses `detect_color: 0` (red) and `target_frame: odom`; the solver
uses `gimble_frame: gimbal_link` and bullet speed from `/serial/receive`.

## 7. Scenario YAML (Phase 3, not implemented yet)

`YAML.gd` (MIT, pure GDScript) will be vendored under `addons/yaml_gd/`; the
schema is validated by `ScenarioSchema.gd`, and `YamlWriter.gd` writes the
editor's deterministic output. Planned schema:

```yaml
schema_version: 1
name: 1v1_line
field: rmul2027_1v1          # rmul2027_1v1 | rmul2027_3v3 | flat
ros:
  backend: rclgd             # rclgd | bridge
  raw_encoding: rgb8         # rgb8 | bayer_rggb8
  raw_hz: 30
  compressed_hz: 60
  jpeg_quality: 90
camera:
  preset: qyg_6mm
ego:
  model: vehicle             # vehicle | infantry_light | urdf:<path> (P5)
  position: [0.0, 0.0, 2.2]
  yaw_deg: 0.0
targets:
  - id: t1
    team: red                # red | blue
    armor: small             # small | large
    number: "3"              # string, kept as a string by the parser
    armors: 4                # 1 | 2 | 4
    position: [0.0, 0.0, -1.4]
    yaw_deg: 180.0
    motion:
      type: line             # static | line | polyline | spin
      waypoints: [[-0.5, 0.0, -1.4], [3.5, 0.0, -1.4]]
      speed: 1.0
      mode: pingpong         # once | loop | pingpong
      spin_deg_s: 90.0
```

Starter scenarios planned: `1v1_static`, `1v1_line`, `3v3_spin`, `flat_range`.
Motion changes the target root transform; detection/TF positions are derived
from the same transforms.

## 8. Performance budget

Measured Phase 1 on the development machine (AMD Radeon 780M, Vulkan, 1600×900
window plus a 1280×1024 feed viewport): **120 FPS / 8.33 ms per frame**, V-Sync
capped. No MSAA, no SSAO, no glow, one shadow-casting directional light.

Phase 2 targets:

- compressed image publish ≥ 60 Hz;
- raw image ≥ 30 Hz (60 Hz optional);
- Godot main thread < 16.6 ms;
- encode + publish CPU ≤ 50 % of one core;
- no per-frame allocation spikes in the image path.

## 9. Phase gates

| Phase | Deliverable | Gate |
| --- | --- | --- |
| P1 | world/field/targets/ego/feed/HUD | user manual acceptance |
| P2 | rclgd spike, image/TF/serial topics, ≥60 fps compressed | user manual acceptance |
| P3 | motion, YAML scenarios, scene selector | user manual acceptance |
| P4 | QYG detector+solver closed loop | user manual acceptance |
| P5 | URDF/SDF loader, high-fidelity model/materials | user manual acceptance |
| P6 | distortion/off-centre projection, performance presets | user manual acceptance |
| P7 | deferred physics/UC/recording/firing | — |

## 10. Decisions log

- **Direct rclgd, not a hand-written GDExtension.** rclgd already wraps
  `rclcpp` with Godot threading, TF, QoS and BabelFish dynamic messages.
- **Bridge is a fallback**, only for host-Godot mode; it is not on the default
  path.
- **Simulator is the MCU.** It owns TF and `SerialReceiveData`; QYG's serial
  and state-publisher nodes stay off.
- **Feed is 1280×1024**, FOV derived from QYG's 1440×1080 intrinsics.
- **Raw is `rgb8` first**, not RGBA; RGB conversion happens once and feeds both
  raw and JPEG. Bayer is a `sim_codec` add-on only if QYG requires it.
- **TF is explicit** (`tf2_msgs/TFMessage`), not rclgd's automatic axis
  mapping.
- **Gimbal angles are degrees**, matching the QYG serial/solver conventions.
- **No `/clock`** in P2; timestamps use the system clock (matches the previous
  stack).

## 11. Risks

| Risk | Mitigation |
| --- | --- |
| rclgd not officially tested on Humble | Phase 2 spike; patch compatibility; fallback to minimal extension/bridge |
| rclgd pins Godot version | retarget to Godot 4.7.2 per rclgd docs; rebuild |
| Image publish blocks the main thread | preallocated buffers, worker thread, QoS depth 1, drop-oldest |
| QYG detector rejects `rgb8` | `sim_codec` bayer conversion; verify early in P2 |
| 6 MB raw frame over DDS | Fast DDS SHM profile + `ipc: host`; compressed path is the 60 fps guarantee |
| QYG launch forces camera/serial | launch detector+solver directly, not the full bringup |
| Headless GLB instantiation crash | never instantiate GLBs in the smoke test; manual/windowed only |
| YAML edge syntax | vendored YAML.gd + schema validation + round-trip tests |
| Asset licences unclear | local use only; see `THIRD_PARTY_NOTICES.md` |
