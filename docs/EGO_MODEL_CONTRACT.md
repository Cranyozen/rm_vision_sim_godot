# Ego model contract

This is the normative contract for an ego (own robot) model in the simulator.
Any robot that follows it can be added with a profile file only — no GDScript
change. The implementation lives in:

- `scripts/sim/EgoRig.gd` — the single, profile-driven rig builder.
- `scripts/sim/EgoModelConfig.gd` — profile loading, defaults and validation.
- `config/ego/*.yaml` — one profile per robot (`vehicle`, `infantry_light`,
  `debug` ship in-tree).
- `scripts/scenario/ScenarioSchema.gd` — accepts exactly the discovered profile
  ids as `ego.model`.

## 1. Frame and units

| Aspect | Requirement |
| --- | --- |
| Engine | Godot 4.7 Forward+, scene imported as `PackedScene` (`.glb`/`.gltf`) |
| Units | Metres |
| Up axis | `+Y` |
| Forward at yaw 0 | `−Z` |
| Right | `+X` |
| Origin | Chassis centre on the ground plane (`y = 0` after `floor_offset_m`) |
| Chassis yaw | Rotation around world `Y`; positive = left turn |

The rig composes `EgoRoot (chassis yaw) → GimbalYaw → GimbalPitch →
CameraMount`. `EgoRig.set_gimbal(yaw_deg, pitch_deg)` is the only gimbal control
entry point; `EgoController` owns the world pose.

## 2. Required node structure

```
<Ego model root>
├─ BASE / CHASSIS / ...              # chassis meshes (names are free)
└─ GIMBAL                            # pivot node, found by name (profile `gimbal_node`)
   ├─ GIMBAL_MAIN / BARREL / ...     # gimbal head meshes (names are free)
   ├─ CAM_DIRECTION                  # camera eye position, empty Node3D
   └─ SHOT_DIRECTION                 # optional aim marker, empty Node3D
```

- `GIMBAL` (name configurable): the node is re-parented under the explicit yaw
  pivot, reset to identity (`position = 0`, `rotation = 0`) and used as the pitch
  joint. Its authored translation is preserved as the pivot position
  (`EgoRig._build_gimbal_from_model`).
- `CAM_DIRECTION` (name configurable via `camera_marker_node`): an empty node
  whose **translation in gimbal space** is the camera eye position. Its rotation
  is optional for the default `gimbal` mount (position only) and required only
  for the `cam_direction` camera preset, where it is interpreted as the CAD
  camera frame: view direction = local `−Y`, up = local `−Z`; a `−90°` X
  correction turns it into a Godot camera pose.
- `SHOT_DIRECTION`: optional aim marker; not used by the default camera. It is
  listed in `marker_nodes` so the install-pitch compensation never rotates it.
- Nodes listed in `marker_nodes` stay directly on the pitch joint; every other
  child is re-parented under `GimbalVisual` and receives
  `gimbal_rest_pitch_deg` about the joint origin.

Meshes are visual only: the rig does not need collision shapes, physics bodies,
skeletons, animations, LODs or UVs. After building, all
`GeometryInstance3D.layers` are forced to `2` (the ego layer); the feed camera
culls layer `1`, so the ego is invisible in the published image unless the
operator enables self-view (`F2`).

## 3. Pose and size rules

- `unit_scale`: multiply the imported scene root. Assets authored in
  millimetres use `0.001` (e.g. `infantry.glb`); metre assets use `1.0`.
- `floor_offset_m`: lift the scene root so the chassis bottom sits on `y = 0`.
  For `vehicle.glb` the chassis bottom is at `y = −0.2101`, so the profile uses
  `0.2101`.
- `gimbal_rest_pitch_deg`: cancels an install pitch baked into the visual head
  (`vehicle.glb` is authored 25° nose-up → `−25`). Author new assets level and
  leave this at `0`.
- `gimbal_visual_offset_m`: optional translation for the compensated visual
  pivot (`[0, 0, 0]` unless the levelled head would clip the chassis).
- `hide_node_prefixes`: imported nodes whose names start with a prefix are
  hidden at load time (detached sub-assemblies such as `激光检测总装`). The
  source GLB is never modified.
- The model should be roughly infantry-sized (about 0.5 m footprint); avoid
  visible geometry floating above the gimbal.

## 4. Profile file

One YAML file per robot under `config/ego/`, named `<id>.yaml`. The `id` must be
unique; `scenario.ego.model` and `EgoRig.preset` use it.

```yaml
schema_version: 1
id: vehicle                       # required, unique
display_name: Vehicle (full CAD)  # UI / diagnostics label
scene_path: res://assets/models/ego/vehicle.glb   # required
unit_scale: 1.0                   # 0.001 for millimetre assets
floor_offset_m: 0.2101            # chassis bottom -> y = 0
gimbal_node: GIMBAL               # "" when the asset has no pivot node
gimbal_rest_pitch_deg: -25.0      # install-pitch compensation
gimbal_visual_offset_m: [0.0, 0.0, 0.0]
marker_nodes: [CAM_DIRECTION, SHOT_DIRECTION]     # never compensated
camera_marker_node: CAM_DIRECTION
camera_mount_fallback_m: [-0.002017, 0.1963421255, -0.0600251630]
hide_node_prefixes:
  - "激光检测总装"
synthetic_gimbal: {}              # optional, see §5
```

Defaults for every optional key are in `EgoModelConfig.DEFAULTS`; unknown keys
are dropped with a warning, invalid required values are reported as errors and
the rig falls back to the box rig.

> Known parser limitation: the vendored `YAMLParser` reads a **single-element
> flow sequence** (`key: ["x"]`) as an empty array. Use the block form for
> single-element lists:
>
> ```yaml
> hide_node_prefixes:
>   - "激光检测总装"
> ```

## 5. Synthetic gimbal (chassis-only assets)

An asset without a `GIMBAL` node can declare `synthetic_gimbal`; the rig then
builds the pivot chain and the fixed camera mount from the profile:

```yaml
gimbal_node: ""
synthetic_gimbal:
  yaw_joint_m: [0.0, 0.152, 0.0]    # rig-space joint positions
  pitch_joint_m: [0.0, 0.045, 0.0]
  camera_mount_m: [0.0, 0.035, -0.11]
  parts:
    - name: PITCH_BODY
      attach: pitch        # model | yaw | pitch
      shape: box           # box | cylinder
      size: [0.16, 0.075, 0.13]
      position: [0.0, 0.02, -0.02]
      rotation_deg: [0.0, 0.0, 0.0]
      color: [0.06, 0.07, 0.08]       # RGB or RGBA
```

Cylinder parts additionally take `radius` and `height`. Parts marked
`attach: model` are parented to the loaded chassis instead of a gimbal joint.
With a synthetic gimbal the camera mount is fixed to `camera_mount_m`; camera
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
- Without a camera marker, the eye position falls back to
  `camera_mount_fallback_m`; with a synthetic gimbal it is `camera_mount_m`.

The resulting `gimbal_link → camera_link` transform is what the ROS backend
publishes, so the eye position/orientation must match the real calibration if
the feed is used for auto-aim validation.

## 7. Adding a robot

1. Export or convert the model to a Godot-imported `.glb` following §1–§2.
2. Run `godot --headless --path . --import`.
3. Add `config/ego/<id>.yaml` (copy an existing profile and adjust the values).
4. Select it with `ego.model: <id>` in a scenario, or
   `EgoRig.preset = "<id>"` in code.
5. Verify: `godot --headless --path . --script res://tests/ego_profiles_check.gd`
   (every profile must build) and, for the model itself,
   `godot --headless --path . --script res://tests/ego_model_check.gd`.

## 8. Failure behaviour

- Profile file missing/invalid: `EgoModelConfig` reports errors; an empty
  library makes `ScenarioSchema` reject every `ego.model` and the simulator
  falls back to the built-in Phase 1 world.
- Unknown `ego.model`: scenario validation error (the load falls back to the
  documented defaults and logs the error).
- Scene missing or no `GIMBAL`/`synthetic_gimbal`: `EgoRig` logs the error and
  builds the fallback box rig so the simulator still starts.
- Profiles are parsed once and cached; restart after editing YAML (tests may
  call `EgoModelConfig.reload()`).
