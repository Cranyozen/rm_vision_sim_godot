# Assets

Simulator assets, grouped by what they are rather than by file type. All paths
are Godot `res://` paths; everything under `assets/` is imported by Godot unless
noted otherwise. Run `godot --headless --path . --import` after changing any
imported file.

```text
assets/
  fields/                  field / venue visuals (scenario `field:` ids)
  armor/                   official armour modules used by TargetRig
  robots/
    vehicle/               full CAD vehicle (default `vehicle` ego profile)
    infantry/              light infantry chassis (`infantry_light` profile)
    debug/                 generated box robot (`debug` profile)
    sentry24/              simplified sentry GLB + URDF description + meshes
    phase5_gimbal/         hand-written Phase 5 sample URDF/SDF/xacro
```

## Conventions

- **Fields** (`fields/`): scene GLBs in the Godot frame (Y up, −Z forward);
  `FieldRegistry` adds the vertical offset and the simple perimeter collision.
- **Armour** (`armor/`): standalone armour modules extracted from the game
  assets; `ArmorPlate.gd` loads them by size (`small` / `large`). The original
  number/team variants are kept inside each module and toggled by node name.
- **Robots** (`robots/<id>/`): one directory per robot. A robot may ship:
  - a Godot-imported `.glb` scene used by a scene ego profile (`asset.path`), or
  - a URDF/SDF description + meshes used by a description ego profile
    (`asset.path` ending in `.urdf`/`.xacro`/`.sdf`), or
  - both, as different profiles/scenarios (e.g. `sentry24` GLB and
    `sentry24_urdf` description).
- **Mesh frames**: GLB scenes are authored in the Godot frame (metres, Y up,
  forward −Z). URDF/SDF mesh files are also expected in the Godot frame; use
  `tools/prepare_robot_model.py` to convert ROS-frame meshes. The URDF/SDF
  text itself is in the REP-103 body frame and is converted by the loaders.
- **Generated files**: `.import` files and `*.uid` files are Godot-generated;
  do not hand-edit them. Import settings live in `.import`; the actual imported
  resources are under `.godot/` (not committed).
- **Provenance / licences**: model and field assets are third-party game/CAD
  assets, not covered by the project MIT licence. See
  [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) before redistributing.

## Regeneration / conversion tools

| Asset group | Tool |
| --- | --- |
| armour modules | `tools/extract_armor.py` |
| debug robot | `tools/make_debug_robot.py` |
| simplified sentry GLB | `tools/build_sentry_glb.py` |
| sentry24 URDF + link meshes | `tools/build_sentry_urdf_assets.py` + `tools/prepare_sentry_urdf.py` |
| ROS-frame mesh → Godot-frame GLB | `tools/prepare_robot_model.py` |
| inspection / validation | `tools/glb_inspect.py`, `tools/mesh_health.py`, `tools/urdf_check/` |

Robot descriptions and profiles are documented in
[`docs/EGO_MODEL_CONTRACT.md`](../docs/EGO_MODEL_CONTRACT.md); the ego profile
files themselves live in `config/ego/`.
