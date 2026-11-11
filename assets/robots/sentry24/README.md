# 24-sentry robot description (URDF)

The 2024/2025 sentry, converted from the Onshape CAD assembly
(`24哨兵-总装.glb`, 3.1 M instanced triangles) into a robot description the
simulator's Phase 5 loader (`UrdfLoader` + `RobotRig`) and ROS tools can use.

| file | purpose |
| --- | --- |
| `robot.urdf` | **simulator variant**: what `config/ego/sentry24_urdf.yaml` loads |
| `robot_rviz.urdf` | **ROS viewer variant** (RViz / Foxglove): same links and joints, mesh visuals carry the Godot→REP-103 rotation |
| `manifest.json` | measured link frames / joint axes (Godot frame) the URDF was generated from |
| `meshes/*.obj` | one Godot-frame mesh per link (Y up, -Z forward, metres) |

## Chain

```
base_link
├─ wheel_front_left_joint    continuous,  axle        → wheel_front_left
├─ wheel_front_right_joint   continuous,  axle        → wheel_front_right
├─ steer_rear_left_joint     revolute Z, ±180°        → steer_rear_left
│    └─ wheel_rear_left_joint  continuous, axle       → wheel_rear_left
├─ steer_rear_right_joint    revolute Z, ±180°        → steer_rear_right
│    └─ wheel_rear_right_joint continuous, axle       → wheel_rear_right
└─ gimbal_yaw_joint          revolute Z, ±180°        → gimbal_yaw_link
     └─ gimbal_pitch_joint   revolute Y, ±30°         → gimbal_pitch_link
          ├─ camera_joint    fixed                    → camera_link
          │    └─ camera_optical_joint (fixed, -90° 0 -90°) → camera_optical_frame
          └─ shot_joint      fixed                    → shot_direction
```

* `gimbal_yaw_link` carries the hopper / dial / big-yaw hardware (yaws only).
* `gimbal_pitch_link` carries the launcher head — barrel, friction wheels, aim
  camera (yaws and pitches).
* The yaw pivot is the big-yaw bearing (`body (0.0075, 0.0003, 0.1400) m`); the
  pitch pivot is the measured launcher pitch bearing
  (`body (0.0671, -0.0297, 0.3550) m`), i.e. **two distinct axes**, not one
  shared point.
* Single-footprint numbers: 0.473 × 0.595 m, 0.453 m tall, chassis bottom on
  `y = 0`, camera eye at `body (0.204, 0.034, 0.398) m`.

## Frames and mesh convention

The URDF itself is authored in the **REP-103 body frame** (+X forward, +Y left,
+Z up); the sim loader converts every pose and axis to the Godot frame with
`SimConfig.body_to_godot()`. As the Phase 5 mesh convention requires, `meshes/`
are authored in the **Godot frame** (Y up, -Z forward), so the sim renders them
without any rotation. `robot_rviz.urdf` exists for tools that expect mesh
coordinates in the body frame; it adds `rpy="1.570796 -0 -1.570796"` to each mesh
visual and is otherwise identical.

## Loading

```bash
# simulator (Phase 5 path): ego.model: sentry24_urdf
godot --path . -- --scenario=res://scenarios/sentry24_urdf.yaml
```

```bash
# RViz: publish the description and a static TF for base_link
ros2 run robot_state_publisher robot_state_publisher \
  --ros-args -p robot_description:="$(cat robot_rviz.urdf)"
ros2 run tf2_ros static_transform_publisher 0 0 0 0 0 0 map base_link
```

The simulator also publishes the gimbal/camera chain on `/tf` when the ROS
backend is enabled (`gimbal_link`, `camera_link`, `camera_optical_frame`).

## Regenerating

```bash
# 1. measure the CAD and write meshes + manifest.json (Blender 5.x)
blender --background --python tools/build_sentry_urdf_assets.py -- \
    --src 24哨兵-总装.glb --outdir assets/robots/sentry24
# 2. URDF (sim variant) and ROS viewer variant
python3 tools/prepare_sentry_urdf.py --manifest assets/robots/sentry24/manifest.json \
    --out assets/robots/sentry24/robot.urdf
python3 tools/prepare_sentry_urdf.py --manifest assets/robots/sentry24/manifest.json \
    --out assets/robots/sentry24/robot_rviz.urdf --ros-visuals
```

Meshes are simplified with the same weld → dissolve → decimate → hole-fill
pipeline as `tools/build_sentry_glb.py` (~245 k triangles total, 18 MB of OBJ).
Mass values in the `<inertial>` blocks are estimates (~19 kg total); the Phase 5
rig is visual-only, so they only matter for ROS tools.
