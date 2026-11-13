# Ego model contract

This is the normative contract for an ego (own robot) model in the simulator.
Any robot that follows it can be added with a profile file only — no GDScript
change. A Chinese mirror lives in
[`EGO_MODEL_CONTRACT.zh_CN.md`](EGO_MODEL_CONTRACT.zh_CN.md); if the two ever
disagree, this file is authoritative.

The implementation lives in:

- `scripts/sim/EgoRig.gd` — the single, profile-driven rig builder.
- `scripts/sim/EgoModelConfig.gd` — profile loading, defaults and validation.
- `config/ego/*.yaml` — one profile per robot (`vehicle`, `infantry_light`,
  `debug`, `sentry24`, `sentry24_urdf`, `urdf_gimbal`, `sdf_gimbal` ship
  in-tree).
- `scripts/scenario/ScenarioSchema.gd` — accepts exactly the discovered profile
  ids as `ego.model`.

## 1. Frame and units

| Aspect | Requirement |
| --- | --- |
| Engine | Godot 4.7 Forward+, scene imported as `PackedScene` (`.glb`/`.gltf`/`.scn`/`.tscn`) **or** a URDF/SDF robot description (`.urdf`/`.xacro`/`.sdf`, Phase 5, §9) |
| Units | Metres |
| Up axis | `+Y` |
| Forward at yaw 0 | `−Z` |
| Right | `+X` |
| Origin | Chassis centre on the ground plane (`y = 0` after `asset.floor_offset_m`) |
| Chassis yaw | Rotation around world `Y`; positive = left turn |

The rig composes `EgoRoot (chassis yaw) → GimbalYaw → GimbalPitch →
CameraMount`. `EgoRig.set_gimbal(yaw_deg, pitch_deg)` is the only gimbal control
entry point; `EgoController` owns the world pose.

## 2. Required node structure

```
<Ego model root>
├─ BASE / CHASSIS / ...              # chassis meshes (names are free)
└─ GIMBAL                            # pivot node, found by name (profile `gimbal.pitch_node`)
   ├─ GIMBAL_MAIN / BARREL / ...     # gimbal head meshes (names are free)
   ├─ CAM_DIRECTION                  # camera eye position, empty Node3D
   └─ SHOT_DIRECTION                 # optional aim marker, empty Node3D
```

A two-axis gimbal (separate yaw and pitch bearings) adds one node:

```
<Ego model root>
├─ BASE / CHASSIS / ...
└─ GIMBAL_YAW                        # yaw pivot, profile `gimbal.yaw_node`
   ├─ YAW_BASE / HOPPER / ...        # yaw-only meshes (names are free)
   └─ GIMBAL                         # pitch pivot, profile `gimbal.pitch_node`
      ├─ GIMBAL_MAIN / BARREL / ...  # pitching head meshes (names are free)
      ├─ CAM_DIRECTION
      └─ SHOT_DIRECTION
```

- `GIMBAL_YAW` (name configurable via `gimbal.yaw_node`, optional): when present
  and an ancestor of `GIMBAL`, its translation is the **yaw** pivot (rotation
  about world `Y`) and `GIMBAL` keeps its authored offset from it, so yaw and
  pitch rotate about their real axes. Without it both joints share the `GIMBAL`
  translation (one-axis assets such as `vehicle.glb`).
- `GIMBAL` (name configurable via `gimbal.pitch_node`): the node is re-parented
  under the explicit yaw pivot, reset to identity (`position = 0`,
  `rotation = 0`) and used as the pitch joint. Its authored translation is
  preserved as the pivot position (`EgoRig._build_gimbal_from_model`).
- `CAM_DIRECTION` (name configurable via `camera.marker_node`): an empty node
  whose **translation in gimbal space** is the camera eye position. Its rotation
  is optional for the default `gimbal` mount (position only) and required only
  for the `cam_direction` camera preset, where it is interpreted as the CAD
  camera frame: view direction = local `−Y`, up = local `−Z`; a `−90°` X
  correction turns it into a Godot camera pose.
- `SHOT_DIRECTION`: optional aim marker; not used by the default camera.
- The camera marker and `SHOT_DIRECTION` are the only nodes that stay directly
  on the pitch joint; every other child is re-parented under `GimbalVisual` and
  receives `gimbal.install_pitch_deg` about the joint origin. This exclusion
  list is **derived** from `camera.marker_node` + `SHOT_DIRECTION`; it is not a
  profile key.

Meshes are visual only: the rig does not need collision shapes, physics bodies,
skeletons, animations, LODs or UVs. After building, all
`GeometryInstance3D.layers` are forced to `2` (the ego layer); the feed camera
culls layer `1`, so the ego is invisible in the published image unless the
operator enables self-view (`F2`).

## 3. Pose and size rules

- `asset.unit_scale`: multiply the loaded asset root (GLB scene or description
  meshes). Assets authored in millimetres use `0.001` (e.g. `infantry.glb`);
  metre assets use `1.0` (the default).
- `asset.floor_offset_m`: lift the asset root so the chassis bottom sits on
  `y = 0`. For `vehicle.glb` the chassis bottom is at `y = −0.2101`, so the
  profile uses `0.2101`.
- `gimbal.install_pitch_deg`: cancels an install pitch baked into the visual
  head (`vehicle.glb` is authored 25° nose-up → `−25`). Author new assets level
  and leave this at `0`.
- `gimbal.visual_offset_m`: optional translation for the compensated visual
  pivot (`[0, 0, 0]` unless the levelled head would clip the chassis).
- `asset.hide_node_prefixes`: imported nodes whose names start with a prefix are
  hidden at load time (detached sub-assemblies such as `激光检测总装`). The
  source GLB is never modified.
- The model should be roughly infantry-sized (about 0.5 m footprint); avoid
  visible geometry floating above the gimbal.

## 4. Profile file (schema version 2)

One YAML file per robot under `config/ego/`, named `<id>.yaml`. The `id` must be
unique; `scenario.ego.model` and `EgoRig.preset` use it.

```yaml
schema_version: 2                  # required, must be 2
id: vehicle                        # required, unique
display_name: Vehicle (full CAD)   # UI / diagnostics label

asset:                             # required: the one model source
  path: res://assets/robots/vehicle/vehicle.glb   # required; extension picks the loader
  unit_scale: 1.0                  # 0.001 for millimetre assets
  floor_offset_m: 0.2101           # chassis bottom -> y = 0
  hide_node_prefixes:              # imported nodes hidden at load time
    - "激光检测总装"
  mesh_root: ""                    # urdf/sdf only: mesh remap root

gimbal:
  # scene assets (.glb / .gltf / .scn / .tscn):
  pitch_node: GIMBAL               # pitch pivot; omit for chassis-only assets
  yaw_node: ""                     # optional separate yaw pivot (two-axis gimbal)
  install_pitch_deg: -25.0         # install-pitch compensation
  visual_offset_m: [0.0, 0.0, 0.0]
  synthetic: {}                    # optional, see §5
  # description assets (.urdf / .xacro / .sdf):
  yaw_joint: gimbal_yaw_joint      # revolute joint driven by operator yaw
  pitch_joint: gimbal_pitch_joint  # revolute joint driven by operator pitch

camera:
  # scene assets:
  marker_node: CAM_DIRECTION       # eye-position empty
  # all assets (fallback when the marker / description frames are absent):
  mount_m: [-0.002017, 0.1963421255, -0.0600251630]
  # description assets:
  link: camera_link
  optical_frame: camera_optical_frame
```

### 4.1 Asset kind is inferred, not declared

`asset.path`'s extension decides which loader runs and therefore which
`gimbal`/`camera` keys are legal:

| Extension | Kind | Loader |
| --- | --- | --- |
| `.glb`, `.gltf`, `.scn`, `.tscn` | `scene` | `load()` as `PackedScene` |
| `.urdf`, `.xacro` | `description` (format `urdf`) | `UrdfLoader` |
| `.sdf` | `description` (format `sdf`) | `SdfLoader` |
| anything else | error | — |

- Exactly one `asset.path` exists, so a profile can never mix the two routes.
- A `gimbal`/`camera` key that belongs to the other kind is an **error**
  (`gimbal.yaw_joint is not valid for scene assets`); an unknown key is a
  warning.
- Description profiles must name `gimbal.yaw_joint` and `gimbal.pitch_joint`;
  scene profiles must provide `gimbal.pitch_node` or `gimbal.synthetic`.
- The normalized dictionary carries `source` (`"scene"` / `"description"`) and
  only the blocks/keys that apply to that source.

Defaults for every optional key live in `EgoModelConfig` (`ASSET_DEFAULTS`,
`SCENE_GIMBAL_DEFAULTS`, `DESCRIPTION_GIMBAL_DEFAULTS`, ...); invalid required
values are reported as errors and the rig falls back to the box rig.

> Known parser limitation: the vendored `YAMLParser` reads a **single-element
> flow sequence** (`key: ["x"]`) as an empty array. Use the block form for
> single-element lists:
>
> ```yaml
> hide_node_prefixes:
>   - "激光检测总装"
> ```

## 5. Synthetic gimbal (chassis-only assets)

An asset without a pitch pivot node can declare `gimbal.synthetic`; the rig then
builds the pivot chain and the fixed camera mount from the profile:

```yaml
gimbal:
  synthetic:
    yaw_pivot_m: [0.0, 0.152, 0.0]    # rig-space joint positions
    pitch_pivot_m: [0.0, 0.045, 0.0]
    parts:
      - name: PITCH_BODY
        attach: pitch        # model | yaw | pitch
        shape: box           # box | cylinder
        size: [0.16, 0.075, 0.13]
        position: [0.0, 0.02, -0.02]
        rotation_deg: [0.0, 0.0, 0.0]
        color: [0.06, 0.07, 0.08]       # RGB or RGBA

camera:
  mount_m: [0.0, 0.035, -0.11]        # fixed camera position (gimbal space)
```

Cylinder parts additionally take `radius` and `height`. Parts marked
`attach: model` are parented to the loaded chassis instead of a gimbal joint.
With a synthetic gimbal the camera mount is fixed to `camera.mount_m`; camera
presets do not move it.

## 6. Camera mount

- Default camera preset (`camera_mount_preset = "gimbal"`): eye **position**
  from the camera marker, orientation = gimbal forward, optionally trimmed by
  `camera_yaw_offset_deg`. The QYG calibration measured a 0.000° optical-axis
  offset, so the marker's own CAD yaw (3.7° left in `vehicle.glb`) is not used.
- `"cam_direction"`: full CAD marker pose (3.7° left), for model-faithful
  screenshots.
- `"qyg"` / `"model"`: experimental calibration mounts (`SimConfig.QYG_CAMERA_*`,
  `EgoRig.camera_mount_offset/rpy`).
- Without a camera marker (or description camera frames), the eye position falls
  back to `camera.mount_m` — the same key used as the fixed mount by the
  synthetic gimbal.

The resulting `gimbal_link → camera_link` transform is what the ROS backend
publishes, so the eye position/orientation must match the real calibration if
the feed is used for auto-aim validation.

## 7. Adding a robot

### 7.1 GLB model (Phase 1 route)

1. Export or convert the model to a Godot-imported `.glb` following §1–§2.
2. Run `godot --headless --path . --import`.
3. Add `config/ego/<id>.yaml` (copy an existing profile and adjust the values).
4. Select it with `ego.model: <id>` in a scenario, or
   `EgoRig.preset = "<id>"` in code.
5. Verify: `godot --headless --path . --script res://tests/ego_profiles_check.gd`
   (every profile must build) and, for the model itself,
   `godot --headless --path . --script res://tests/ego_model_check.gd`.

Any `.glb` that follows §1–§2 can replace the ego: the profile is the only
change (`asset.path` + `asset.unit_scale` / `floor_offset_m` + `gimbal` pivot
names). The `debug`, `infantry_light`, `sentry24` and `vehicle` profiles are
shipped examples of the same mechanism at different fidelity levels.

### 7.2 URDF/SDF model (Phase 5 route)

1. Author or export a robot description (URDF, `.xacro` subset or SDF 1.7).
2. Convert any ROS-frame meshes to the Godot frame with
   `tools/prepare_robot_model.py` (see `tools/README.md`); `.glb`/`.obj` meshes
   already in the Godot frame can be referenced directly.
3. Add `config/ego/<id>.yaml` whose `asset.path` points at the description
   (§9); name the yaw/pitch joints under `gimbal` and the camera frames under
   `camera`.
4. Add a scenario with `ego.model: <id>` and run/verify it.
5. Verify: `godot --headless --path . --script res://tests/urdf_sdf_check.gd`
   (loaders/rig) and `.../tests/phase5_ego_check.gd` (integration, camera/TF).

## 8. Failure behaviour

- Profile file missing/invalid: `EgoModelConfig` reports errors; an empty
  library makes `ScenarioSchema` reject every `ego.model` and the simulator
  falls back to the built-in Phase 1 world.
- Unknown `ego.model`: scenario validation error (the load falls back to the
  documented defaults and logs the error).
- Scene missing or no `gimbal.pitch_node`/`gimbal.synthetic`: `EgoRig` logs the
  error and builds the fallback box rig so the simulator still starts.
- Description missing / unparsable, or a mapped yaw/pitch joint that does not
  exist: `EgoRig` logs the error and builds the fallback box rig; parser
  warnings (unsupported xacro macros, unresolved `package://` meshes) are
  logged without aborting.
- Profiles are parsed once and cached; restart after editing YAML (tests may
  call `EgoModelConfig.reload()`).

## 9. URDF/SDF-backed models (Phase 5)

A profile whose `asset.path` ends in `.urdf`, `.xacro` or `.sdf` is built from a
robot description instead of an imported GLB scene.

- **Loaders.** `UrdfLoader.load_file(path)` (URDF, plus a documented `.xacro`
  subset: `xacro:arg`, `xacro:property`, `$(arg)`, `${expr}` arithmetic with
  `pi`/`radians()`/`degrees()`, relative `xacro:include`; `xacro:macro` is
  warned and removed) and `SdfLoader.load_file(path)` (SDF 1.7 link/joint
  poses, `relative_to`, `degrees`, PBR materials) both produce the same
  `RobotDescription`. Supported geometries: `box`, `cylinder`, `sphere`,
  `mesh`. Supported joint types: `fixed`, `revolute`, `continuous`,
  `prismatic`, `floating`, `planar` (the last two are static in the rig).
- **Frames.** URDF/SDF body frames (X forward, Y left, Z up, RPY = Rz·Ry·Rx)
  are converted to the Godot frame by the loader using `SimConfig` helpers;
  joint origins/axes and visual origins are stored already converted. Mesh
  files are **authored in the Godot frame** (use
  `tools/prepare_robot_model.py` for ROS-frame meshes); loaders never rotate
  mesh geometry.
- **Rig.** `RobotRig.build(description, options)` builds one `Node3D` per link
  and joint. `options`: `unit_scale`, `layers`, `visuals`, `mesh_root`.
  `set_joint_value(name, value)` drives revolute/continuous (radians) and
  prismatic (metres) joints about their authored axis.
- **Ego integration.** `EgoRig` uses the profile's `gimbal.yaw_joint` /
  `gimbal.pitch_joint` for `set_gimbal()`; the axis signs are normalized so
  positive operator yaw is left and positive pitch is up. The camera mount is
  derived from `camera.optical_frame` (or `camera.link` + the standard optical
  RPY if no optical frame is named), and `EgoRig.get_camera_link()` /
  `get_camera_optical_frame()` let `RosBackend` publish the description's own
  static camera TF. `camera_mount_preset` is ignored for description-backed
  egos because the description is authoritative.
- **Limitations.** Visual-only (no collision/inertial/joint dynamics; Phase 7),
  `floating`/`planar` joints static, `package://` / `model://` mesh URIs warn
  and are skipped, SDF `<include>`/sensors/plugins/nested models warn and are
  skipped, and `.dae` conversion needs Blender ≤ 4.x (Blender 5 removed the
  COLLADA importer). Samples and commands: `docs/PHASE5_ACCEPTANCE.md`.
