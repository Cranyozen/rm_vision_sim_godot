# Phase 1 acceptance

Phase 1 is complete only after **you** run it and confirm the checklist below.
Phase 2 (rclgd / ROS) will not start before that.

## 1. Commands

```bash
cd <path-to-this-repo>

# first run / after asset changes
godot --headless --path . --import

# headless parse check (no GLB instantiation)
godot --headless --path . --script res://tests/phase1_smoke.gd

# headless ego-model check (vehicle.glb laser detection parts are hidden)
godot --headless --path . --script res://tests/ego_model_check.gd

# normal run
godot --path .
```

Expected smoke result:

```
OK  res://scripts/app/Main.gd  (GDScript)
...
feed intrinsics: { "width": 1280, "height": 1024, ... }
feed vertical fov deg: 17.2074...
PHASE1_SMOKE: PASS
```

## 2. Visual checklist

- [ ] A 1600×900 window opens with the 1v1 field, a light-grey floor, two large
      centre cover walls and the perimeter.
- [ ] Four armour-plate targets are visible: red `3` (4 plates), blue `2`
      (4 plates), red large `1` (2 plates), blue `5` (1 plate). Plates float at
      ~0.25 m and use the official Bevy game armour modules (AM02 small from
      `vehicle.glb`, AM12 large from `HERO.glb`, extracted to
      `assets/models/armor/armor_small.glb` / `armor_large.glb`): white 3D
      number geometry flush on the front face and a red or blue emissive team
      light bar on each side, mounted at ~75° to the ground like the real
      module (top edge leaning back, front normal tilted 15° up). The number
      must read correctly (not mirrored) and the light bars must be the team's
      colour.
- [ ] The ego vehicle is visible near the bottom centre (third-person camera),
      with its real `vehicle.glb` chassis and gimbal. No detached parts float
      above the gimbal: the source model's `激光检测总装` (laser detection
      assembly) meshes are hidden.
- [ ] HUD top-left shows field/ego/FPS/frame time/gimbal/target count.
- [ ] HUD bottom-right shows the 1280×1024 feed preview with the red `3` target
      visible (slightly right of centre because of the QYG camera's 0.091 rad
      yaw mount offset).
- [ ] HUD top-right lists the controls.

## 3. Interaction checklist

- [ ] `Q` / `E` rotate the gimbal yaw; the feed view pans left/right and the
      HUD yaw value changes.
- [ ] `R` / `F` tilt the gimbal pitch; the feed view moves up/down; pitch stops
      at ±20°.
- [ ] `F1` shows the feed fullscreen; `F1` again (or `Esc`) returns to the
      preview.
- [ ] `F2` makes the ego model appear in the feed (self-FPV); `F2` hides it
      again. The feed's camera view itself does not move.
- [ ] `F3` switches the main view between third-person and FPV debug cameras.
- [ ] `F4` enters free camera: the mouse looks around, `WASD` pans relative to
      the view, `E` / `F` move up / down, `Shift` = 3× speed, wheel changes
      speed. The HUD shows `Camera: FREE …`. `Esc` returns to the debug camera
      and releases the mouse.
- [ ] While the free camera is active, `Q`/`E`/`R`/`F` do **not** move the
      gimbal (E/F are vertical movement); the feed preview keeps following the
      gimbal.
- [ ] `F5` resets the pose (yaw/pitch 0, ego back at (0, 0, 2.2), FPV/debug
      toggles reset, free camera off).
- [ ] `Esc` quits when no fullscreen feed is open and the free camera is off.

## 4. Performance checklist

- [ ] With V-Sync on, the HUD FPS settles at the monitor rate (120 on the
      development machine); on a 60 Hz monitor it should be 60.
- [ ] `godot --path . --quit-after 600 --print-fps` prints at least 60 FPS.
- [ ] No red errors in the terminal during a 30 s run.

Measured reference on this machine (AMD Radeon 780M, Vulkan): 120 FPS,
8.33 ms/frame, 1600×900 window + 1280×1024 feed viewport.

## 5. Known limitations (expected in Phase 1)

- The ego chassis is very dark; this is the source model's near-black paint.
  Shape, gimbal chain and camera mount are correct. Phase 5 improves materials.
- No target motion, no scenario YAML, no UI scene selector (Phase 3).
- 3v3 field is present in `assets/` but not selectable yet.
- No ROS topics, no JPEG, no distortion, no firing.
- Collision is a simple floor + perimeter; field cover is visual only.
- Feed preview uses the QYG `gimbal2camera` mount; the vehicle model's own
  `CAM_DIRECTION` is visual reference only.

## 6. How to report

Reply with either:

- `P1 PASS`, or
- a short list of issues (what you did, what you expected, what happened, and
  a screenshot if visual). I will fix Phase 1 before starting Phase 2.

Reference image: `docs/phase1_view.png`.
