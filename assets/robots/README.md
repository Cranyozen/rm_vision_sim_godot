# Robot assets

One directory per robot. Both ego model routes live here:

- **GLB profiles** load a Godot-imported scene (`asset.path` ending in
  `.glb` in `config/ego/<id>.yaml`).
- **Description profiles** load a URDF/SDF (`asset.path` ending in
  `.urdf`/`.xacro`/`.sdf`) and build the link/joint tree with `UrdfLoader` /
  `SdfLoader` + `RobotRig`.

| Directory | Used by | Contents |
| --- | --- | --- |
| `vehicle/` | `vehicle` profile / default scenario | `vehicle.glb` (full CAD, ~29 MB) + its two embedded-texture PNG extracts |
| `infantry/` | `infantry_light` profile | `infantry.glb`, chassis-only GLB in millimetres |
| `debug/` | `debug` profile / `debug_robot` scenario | `debug_robot.glb`, generated box robot |
| `sentry24/` | `sentry24` (GLB) and `sentry24_urdf` (URDF) profiles | `24sentry_simplified.glb`, `robot.urdf`, `robot_rviz.urdf`, `manifest.json`, `meshes/*.obj` |
| `phase5_gimbal/` | `urdf_gimbal` / `sdf_gimbal` sample profiles | hand-written URDF/SDF/xacro + OBJ head |

Robot mesh conventions:

- GLB scenes are in the Godot frame: metres, +Y up, forward = −Z at yaw 0,
  origin at the chassis centre on the ground.
- URDF/SDF text is in the REP-103 body frame; the loaders convert it. URDF/SDF
  mesh files (`meshes/*.obj`, converted `.glb`) must be in the **Godot frame**.
- Use `tools/prepare_robot_model.py` for ROS-frame meshes. See
  `../README.md` for the full asset conventions and tool list.

Per-robot regeneration and chain details are in each directory's `README.md`
where present (`sentry24/`, `phase5_gimbal/`). Profiles are in `config/ego/`,
scenarios in `config/scenarios/`.
