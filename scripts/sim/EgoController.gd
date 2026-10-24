class_name EgoController
extends RefCounted

## Phase 1 operator controller: owns the ego's world pose and drives the
## EgoRig from operator input. Phase 2 will feed GimbalCmd / ChassisCmd into
## the same entry points, so input mapping stays in Main.gd.
##
## Conventions (match the ROS side, see docs/ARCHITECTURE.md):
## - chassis_yaw_deg / gimbal_yaw_deg are **world** yaw in degrees, 0 = facing
##   -Z (Godot forward), positive = turn left (ROS REP-103, right-handed +Y).
## - gimbal_pitch_deg is positive up, clamped to
##   SimConfig.GIMBAL_PITCH_LIMIT_DEG.
## - The rig's GimbalYaw is local to the chassis, so
##   local_yaw = gimbal_yaw_deg - chassis_yaw_deg.
## - chassis_position is on the floor (y = 0).
##
## Chassis translation is omnidirectional (mecanum), relative to the chassis
## heading. In follow mode the chassis yaw chases the gimbal yaw, which is the
## usual infantry driving feel; with follow off the robot strafes while the
## gimbal keeps looking where the operator points it.

var ego: EgoRig
var chassis_position := Vector3.ZERO
var chassis_yaw_deg := 0.0
var gimbal_yaw_deg := 0.0
var gimbal_pitch_deg := 0.0
var chassis_speed_mps := 0.0
var follow_gimbal := true
## Half extents (x, z) of the current field's playable area. Phase 3 scenarios
## change field at runtime, so the limit is per-scenario instead of the Phase 1
## constant; defaults to the 1v1 field for backwards compatibility.
var field_half_extents := Vector2(SimConfig.FIELD_HALF_EXTENT, SimConfig.FIELD_HALF_EXTENT)


func _init(rig: EgoRig = null, start_position := Vector3.ZERO) -> void:
	ego = rig
	chassis_position = start_position
	chassis_position.y = 0.0
	apply_to_rig()


func reset(start_position := Vector3.ZERO) -> void:
	chassis_position = start_position
	chassis_position.y = 0.0
	chassis_yaw_deg = 0.0
	gimbal_yaw_deg = 0.0
	gimbal_pitch_deg = 0.0
	chassis_speed_mps = 0.0
	follow_gimbal = true
	_clamp_position()
	apply_to_rig()


## Place the robot at a scenario pose: chassis position + heading. The gimbal
## starts looking the same way as the chassis (operator-forward), matching the
## Phase 1 reset behaviour.
func place(position: Vector3, yaw_deg: float) -> void:
	chassis_position = Vector3(position.x, 0.0, position.z)
	chassis_yaw_deg = wrapf(yaw_deg, -180.0, 180.0)
	gimbal_yaw_deg = chassis_yaw_deg
	gimbal_pitch_deg = 0.0
	chassis_speed_mps = 0.0
	follow_gimbal = true
	_clamp_position()
	apply_to_rig()


## Scenario field bounds (per-axis half extents of the playable area).
func set_field_bounds(half_extents: Vector2) -> void:
	field_half_extents = half_extents
	_clamp_position()
	apply_to_rig()


# --- gimbal -----------------------------------------------------------------

func set_gimbal(yaw_deg: float, pitch_deg: float) -> void:
	gimbal_yaw_deg = wrapf(yaw_deg, -180.0, 180.0)
	gimbal_pitch_deg = clampf(pitch_deg, -SimConfig.GIMBAL_PITCH_LIMIT_DEG, SimConfig.GIMBAL_PITCH_LIMIT_DEG)
	apply_to_rig()


func add_gimbal_yaw(delta_deg: float) -> void:
	set_gimbal(gimbal_yaw_deg + delta_deg, gimbal_pitch_deg)


func add_gimbal_pitch(delta_deg: float) -> void:
	set_gimbal(gimbal_yaw_deg, gimbal_pitch_deg + delta_deg)


## Mouse look, in the same convention as the free camera: right / down are
## positive `relative` px and must turn the view right / down.
func apply_mouse_look(relative: Vector2) -> void:
	var sens := rad_to_deg(SimConfig.MOUSE_SENS_RAD_PER_PX)
	set_gimbal(gimbal_yaw_deg - relative.x * sens, gimbal_pitch_deg - relative.y * sens)


# --- chassis ----------------------------------------------------------------

## `forward` = W(+1) / S(-1), `strafe` = D(+1) / A(-1), both in [-1, 1].
## Translation is relative to the chassis heading; the radius-limited play
## area keeps the robot inside the perimeter collision.
func move_chassis(forward: float, strafe: float, boost: bool, delta: float) -> void:
	var local := Vector3(strafe, 0.0, -forward)
	if local.length_squared() > 1.0:
		local = local.normalized()
	var speed := SimConfig.CHASSIS_SPEED_MPS * (SimConfig.CHASSIS_BOOST_MULT if boost else 1.0)
	var world := local.rotated(Vector3.UP, deg_to_rad(chassis_yaw_deg)) * speed * delta
	var before := chassis_position
	chassis_position += world
	chassis_position.y = 0.0
	_clamp_position()
	var dt := maxf(delta, 1e-6)
	chassis_speed_mps = (chassis_position - before).length() / dt


## Rotate the chassis by `delta_deg` (positive = left). Used by the Phase 2
## `/cmd_chassis` angular velocity; follows the same world-yaw convention.
func rotate_chassis(delta_deg: float) -> void:
	chassis_yaw_deg = wrapf(chassis_yaw_deg + delta_deg, -180.0, 180.0)


## Clamp the chassis into the current field's playable area, keeping the ego
## radius away from the perimeter collision (per-axis for the 3v3 rectangle).
func _clamp_position() -> void:
	var limit := Vector2(
		maxf(field_half_extents.x - SimConfig.EGO_RADIUS, 0.0),
		maxf(field_half_extents.y - SimConfig.EGO_RADIUS, 0.0))
	chassis_position.x = clampf(chassis_position.x, -limit.x, limit.x)
	chassis_position.z = clampf(chassis_position.z, -limit.y, limit.y)
	chassis_position.y = 0.0


## One simulation step: follow the gimbal (if enabled) and push the pose into
## the rig. Call once per rendered frame, after the input handlers.
func step(delta: float) -> void:
	if follow_gimbal and delta > 0.0:
		var t := clampf(SimConfig.CHASSIS_FOLLOW_RATE * delta, 0.0, 1.0)
		chassis_yaw_deg = rad_to_deg(lerp_angle(
			deg_to_rad(chassis_yaw_deg), deg_to_rad(gimbal_yaw_deg), t))
	apply_to_rig()


func apply_to_rig() -> void:
	if ego == null:
		return
	ego.position = Vector3(chassis_position.x, 0.0, chassis_position.z)
	ego.set_chassis_yaw(chassis_yaw_deg)
	ego.set_gimbal(wrapf(gimbal_yaw_deg - chassis_yaw_deg, -180.0, 180.0), gimbal_pitch_deg)
