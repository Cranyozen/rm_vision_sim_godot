# Phase 5 sample robot: phase5_gimbal

Development-only sample robot description used by
`tests/urdf_sdf_check.gd` and as the reference for the Phase 5 loaders
(`UrdfLoader` / `SdfLoader` / `RobotDescription` / `RobotRig`).

The same simple two-axis gimbal camera head is authored in three formats:

| File | Format | Notes |
| --- | --- | --- |
| `robot.urdf` | URDF | plain values, all primitive + mesh visual types |
| `robot.sdf` | SDF 1.7 | link `<pose>` relative to the model, joint pose relative to the child, PBR material |
| `robot.urdf.xacro` | xacro subset | args, properties, `${...}` arithmetic, relative `<xacro:include>` of `fragments/base.xacro` |

Chain: `base_link -> gimbal_yaw_joint (body Z) -> gimbal_yaw_link ->
gimbal_pitch_joint (body Y) -> gimbal_pitch_link -> camera_joint (fixed) ->
camera_link -> camera_optical_joint (fixed, RPY -pi/2 0 -pi/2) ->
camera_optical_frame`. A prismatic `slider_joint` on `base_link` exercises the
sliding joint type.

Conventions:

- URDF/SDF files are authored in the robot body frame (metres, +X forward,
  +Y left, +Z up); the loaders convert every pose/axis to the Godot frame
  (Y up, -Z forward) using `SimConfig`'s body helpers.
- `meshes/head.obj` is authored in the **Godot frame** (Y up, -Z forward).
  The Phase 5 mesh convention is "URDF/SDF mesh files are Godot-frame assets";
  use `tools/prepare_robot_model.py` to convert ROS/URDF-frame meshes.
- `fragments/base.xacro` is only pulled in by `robot.urdf.xacro`; it proves the
  relative include path and property sharing between files.

These files are tiny hand-written samples, not production robot models.
