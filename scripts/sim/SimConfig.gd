class_name SimConfig
extends RefCounted

## Single source of truth for Phase 1 constants.
##
## Camera model (see docs/ARCHITECTURE.md § Camera):
## The real QYG camera is a 1440x1080 sensor with fx/fy/cx/cy from
## camera_info.yaml (fx/fy differ by only 0.06%).  The simulator publishes a
## 1280x1024 feed, which is a **5:4 horizontal crop of the 4:3 sensor**
## (1350x1080, 45 px cropped from each side) scaled uniformly by 1024/1080.
## That keeps square pixels and the true vertical FOV (17.207 deg); the old
## "scale fx and fy independently" model could not be rendered by a perspective
## camera (it assumed non-square pixels) and made the horizontal FOV 6.6% too
## narrow.
##
## Godot's perspective camera always projects the optical axis at the image
## centre, while the QYG principal point is off-centre.  The feed therefore
## renders a slightly larger canvas (1350x1073) and crops 1280x1024 out of it,
## so the optical axis lands on (cx, cy) instead of the image centre.  The
## helper functions below derive the canvas, crop and intrinsics from the same
## numbers; do not hard-code them anywhere else.

const FEED_WIDTH := 1280
const FEED_HEIGHT := 1024

const ORIG_WIDTH := 1440.0
const ORIG_HEIGHT := 1080.0
const FX := 3571.1890927935297
const FY := 3569.0234714126823
const CX := 683.5999418028833
const CY := 565.5838917436471

## Width of the 5:4 crop taken from the 4:3 sensor: 1080 * 1280 / 1024.
const FEED_CROP_WIDTH := 1350.0
## Uniform scale from sensor pixels to feed pixels (1024 / 1080).
const FEED_SCALE := float(FEED_HEIGHT) / ORIG_HEIGHT

const FIELD_1V1_PATH := "res://assets/fields/rmul2027_1v1.glb"
const FIELD_3V3_PATH := "res://assets/fields/rmul2027_3v3.glb"
const EGO_VEHICLE_PATH := "res://assets/models/ego/vehicle.glb"
const EGO_INFANTRY_PATH := "res://assets/models/ego/infantry.glb"

## QYG gimbal_link -> camera_link mount (metres, radians). Kept as an
## alternative mount for comparing the feed against the real robot calibration.
const QYG_CAMERA_OFFSET := Vector3(0.0461892, 0.0, -0.0603874)
const QYG_CAMERA_RPY := Vector3(0.0, 0.091, 0.0)

## vehicle.glb's "CAM_DIRECTION" empty under GIMBAL: the model's own camera
## mount. Its translation is the camera position in gimbal space; its rotation
## is the CAD export's camera frame, where the view direction is local -Y and
## up is local -Z (the node carries a ~+90 deg X rotation and a 0.001 scale).
## Godot cameras look down -Z with +Y up, hence the -90 deg X correction below
## (stored in radians, matching Basis.from_euler).
const CAM_DIRECTION_NODE := "CAM_DIRECTION"
const CAM_DIRECTION_TO_CAMERA_RPY := Vector3(-PI / 2.0, 0.0, 0.0)

## Fallback camera location in gimbal space when the model has no
## CAM_DIRECTION node (i.e. the raw position the node would contribute).
const VEHICLE_CAMERA_OFFSET := Vector3(-0.002017, 0.1963421255, -0.0600251630)

## Camera mount orientation policy.
##
## The QYG bring-up calibration measured the optical axis on `gimbal_link +X`
## with a 0.000 deg angle to `camera_optical_frame +Z`, i.e. the camera looks
## exactly along the gimbal's forward axis.  The CAD `CAM_DIRECTION` node,
## however, carries a 3.7 deg left yaw.  Using it as the camera orientation
## makes both the FPV and the feed look 3.7 deg left of the aim axis (0.32 m at
## 5 m), which is the visible "the view is not where the robot aims" error.
##
## Default: "gimbal"  -> position from CAM_DIRECTION, orientation = gimbal
##                       forward + camera_yaw_offset_deg (0 = QYG calibrated).
##          "cam_direction" -> position + orientation from CAM_DIRECTION (the
##                       CAD model's own camera, 3.7 deg left).
##          "qyg" / "model" -> explicit calibration mounts (experimental; see
##                       EgoRig._make_camera_mount_transform).
const CAMERA_MOUNT_PRESET := "gimbal"
## Extra yaw applied to the gimbal-aligned mount (deg, + = left).  Use this to
## dial in a measured optical-axis offset without editing the rig.
const CAMERA_YAW_OFFSET_DEG := 0.0

## Static install-pitch compensation for the imported vehicle model.
##
## vehicle.glb authors the gimbal head 25 deg nose-up: the area-weighted
## dominant planes of the `GIMBAL_MAIN` mesh measure +25.0 deg against the
## horizontal (top face +65 deg, front face +25 deg), while `CHASSIS` measures
## 0.0 deg with the same estimator - so the head is posed, not the whole model.
## The CAD `CAM_DIRECTION` / `SHOT_DIRECTION` markers are authored level in that
## same frame, so without compensation gimbal pitch 0 draws the head (and with
## it the visible camera/barrel housing) 25 deg up while the FPV and the feed
## look level.
##
## The rig therefore rotates the *visual* children of the pitch node by this
## angle about the joint origin.  The CAD markers stay directly on the pitch
## node, so the camera keeps the orientation the model authored for it.
const GIMBAL_REST_PITCH_DEG := -25.0
## Node names under GIMBAL that must not receive the compensation above.
const GIMBAL_MARKER_NODES := ["CAM_DIRECTION", "SHOT_DIRECTION"]
## Translation applied to the compensated visual pivot (metres).  The CAD poses
## the head by rotating about the joint origin, so a levelled head would dip its
## nose into the chassis; this lifts it back onto the yaw bracket.
const GIMBAL_VISUAL_OFFSET := Vector3(0.0, 0.0, 0.0)

# --- Phase 1 operator (first-person driving) --------------------------------

## Wide FPV camera for driving. The feed camera keeps the 17.2 deg vision
## intrinsics; this one is a human-readable operator view on the same mount.
const FPV_FOV_DEG := 70.0
const MOUSE_SENS_RAD_PER_PX := 0.0025     ## same feel as the free camera

const GIMBAL_YAW_SPEED_DPS := 90.0        ## Q / E keyboard backup
const GIMBAL_PITCH_SPEED_DPS := 60.0      ## R / F keyboard backup
const GIMBAL_PITCH_LIMIT_DEG := 20.0      ## Phase 1 operator pitch limit

const CHASSIS_SPEED_MPS := 2.0            ## W / S / A / D
const CHASSIS_BOOST_MULT := 1.8           ## Shift
const CHASSIS_FOLLOW_RATE := 8.0          ## chassis yaw chase rate in follow mode (1/s)

## Playable area: the perimeter collision inner face is at +/-2.5 m.
const FIELD_HALF_EXTENT := 2.5
const EGO_RADIUS := 0.30
const CHASSIS_LIMIT := FIELD_HALF_EXTENT - EGO_RADIUS

# --- REP-103 robot body frame <-> Godot world -------------------------------
#
# The target/robot body frame is the standard RoboMaster one (REP-103):
# +X forward, +Y left, +Z up. Godot is Y-up, and the ego looks along -Z at
# yaw = 0, so the mapping is the same one the ROS backend publishes:
#
#   body = (-godot.z, -godot.x, godot.y)
#   godot = (-body.y, body.z, -body.x)
#
# These helpers are the single place where that axis permutation lives:
# TargetRig places armour plates with them and RosBackend converts the
# resulting body-frame TF poses back to Godot for rclgd.

## Godot world vector -> target/robot body vector (REP-103).
static func godot_to_body(v: Vector3) -> Vector3:
	return Vector3(-v.z, -v.x, v.y)


## Target/robot body vector (REP-103) -> Godot world vector.
static func body_to_godot(v: Vector3) -> Vector3:
	return Vector3(-v.y, v.z, -v.x)


## Map an orthonormal body-frame **frame** to Godot axes: each frame axis
## (matrix column) is mapped as a vector. Use this for Node3D.basis when the
## node's local axes are the frame axes (armour plate placement).
static func body_axes_to_godot(b: Basis) -> Basis:
	return Basis(body_to_godot(b.x), body_to_godot(b.y), body_to_godot(b.z))


## Convert a body-frame **rotation** to the equivalent Godot rotation:
## R_godot = M^T R_body M. Use this for a TF transform built in body
## coordinates (RosBackend publishes armour strike-face poses with it).
static func body_basis_to_godot(b: Basis) -> Basis:
	return Basis(
		body_to_godot(b * godot_to_body(Vector3.RIGHT)),
		body_to_godot(b * godot_to_body(Vector3.UP)),
		body_to_godot(b * godot_to_body(Vector3.BACK)))



## Focal length of the rendered feed in feed pixels (square pixels).  The
## source fx/fy differ by 0.06%; the renderer has one focal length, and that
## difference is below the simulator's angular resolution.
static func feed_focal_px() -> float:
	return FY * FEED_SCALE


## Principal point of the 5:4 sensor crop, before integer canvas rounding.
static func _feed_theoretical_principal() -> Vector2:
	var crop_x0 := (ORIG_WIDTH - FEED_CROP_WIDTH) * 0.5
	var sx := FEED_WIDTH / FEED_CROP_WIDTH
	var sy := FEED_HEIGHT / ORIG_HEIGHT
	return Vector2((CX - crop_x0) * sx, CY * sy)


## Render-target size used to simulate the off-centre principal point: the
## canvas is centred on the projection centre, and the 1280x1024 crop is taken
## so that the projection centre lands on the principal point.
static func feed_canvas_size() -> Vector2i:
	var p := _feed_theoretical_principal()
	var half_w: float = maxf(p.x, float(FEED_WIDTH) - p.x)
	var half_h: float = maxf(p.y, float(FEED_HEIGHT) - p.y)
	return Vector2i(int(ceil(half_w * 2.0)), int(ceil(half_h * 2.0)))


## Region of the canvas that becomes the published feed image.
static func feed_crop_rect() -> Rect2i:
	var p := _feed_theoretical_principal()
	var canvas := feed_canvas_size()
	var x0 := int(round(float(canvas.x) * 0.5 - p.x))
	var y0 := int(round(float(canvas.y) * 0.5 - p.y))
	x0 = clampi(x0, 0, canvas.x - FEED_WIDTH)
	y0 = clampi(y0, 0, canvas.y - FEED_HEIGHT)
	return Rect2i(x0, y0, FEED_WIDTH, FEED_HEIGHT)


## Intrinsics of the published 1280x1024 feed.  cx/cy are derived from the
## actual integer crop, so the published camera_info matches the rendered
## image exactly (sub-pixel rounding of the crop is included).
static func feed_intrinsics() -> Dictionary:
	var canvas := feed_canvas_size()
	var crop := feed_crop_rect()
	var f := feed_focal_px()
	return {
		"width": FEED_WIDTH,
		"height": FEED_HEIGHT,
		"fx": f,
		"fy": f,
		"cx": float(canvas.x) * 0.5 - float(crop.position.x),
		"cy": float(canvas.y) * 0.5 - float(crop.position.y),
	}


## Vertical FOV of the canvas camera; it is wider than the published feed
## because the canvas also contains the margins used for the principal-point
## shift.
static func feed_canvas_fov_deg() -> float:
	var canvas := feed_canvas_size()
	return rad_to_deg(2.0 * atan(float(canvas.y) / (2.0 * feed_focal_px())))


## Vertical FOV of the published 1280x1024 feed (17.207 deg).
static func vertical_fov_deg() -> float:
	return rad_to_deg(2.0 * atan(float(FEED_HEIGHT) / (2.0 * feed_focal_px())))

## Horizontal FOV of the published feed (21.42 deg = the 5:4 crop of the
## sensor's 22.80 deg).  Kept for tests and Phase 2 camera_info.
static func horizontal_fov_deg() -> float:
	var k := feed_intrinsics()
	return rad_to_deg(2.0 * atan(float(FEED_WIDTH) / (2.0 * float(k["fx"]))))
