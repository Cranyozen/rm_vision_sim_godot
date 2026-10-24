class_name TargetMotion
extends RefCounted

## Deterministic, time-based motion for a target rig (Phase 3).
##
## The pose is a pure function of the simulation time passed to `update()`, so
## reloading or restarting a scenario always produces the same pose (no
## integration drift). `TargetRig.step_motion()` applies the result to the rig
## root, and every TF frame derived from global transforms follows for free.
##
## Motion types
## - "static":   stays at the base pose; `is_moving()` is false.
## - "line":     straight path through `waypoints`. A single waypoint means
##               base position -> that waypoint.
## - "polyline": ordered waypoints. In "loop" mode the closing segment from
##               the last waypoint back to the first is part of the path;
##               "once" and "pingpong" traverse the open path only.
## - "spin":     rotates in place around +Y (yaw); the position never changes.
##
## Modes
## - "once":     stop at the end of the path / after one full 360 deg turn and
##               set `finished`.
## - "loop":     wrap around to the start (path) or keep turning (spin).
## - "pingpong": reverse at both ends; for spin the yaw sweeps
##               base_yaw <-> base_yaw + 360 deg.
##
## Path motion keeps the scenario yaw (targets do not face their travel
## direction); spin changes the yaw only. Lengths are metres, angles degrees,
## times seconds. Waypoint Y values are ignored: targets are floor anchored.

const TYPE_STATIC := "static"
const TYPE_LINE := "line"
const TYPE_POLYLINE := "polyline"
const TYPE_SPIN := "spin"

const MODE_ONCE := "once"
const MODE_LOOP := "loop"
const MODE_PINGPONG := "pingpong"

## One full spin turn in degrees; "once" stops here.
const FULL_TURN_DEG := 360.0
## Distance / angle comparison epsilon.
const EPS := 1e-9

var type: String = TYPE_STATIC
var mode: String = MODE_ONCE
var speed: float = 1.0                  ## Path speed in m/s.
var spin_deg_s: float = 90.0            ## Spin rate in deg/s (negative = clockwise).
var waypoints: Array[Vector3] = []      ## Field coordinates; Y is ignored.

## Pose produced by the last `update()` call.
var current_position: Vector3 = Vector3.ZERO
var current_yaw_deg: float = 0.0
## True once a "once" motion reached its end (path end / one full turn).
## Continuous modes never finish; "static" is complete from the start.
var finished: bool = false

var _base_position: Vector3 = Vector3.ZERO
var _base_yaw_deg: float = 0.0
var _points: Array[Vector3] = []
var _segment_lengths: Array[float] = []
var _total_length: float = 0.0
var _closed: bool = false


## Build a motion from a scenario-style dictionary. `base_position` is the
## rig's floor anchor and `base_yaw_deg` its scenario yaw.
func configure(config: Dictionary, base_position: Vector3, base_yaw_deg: float) -> void:
	_base_position = base_position
	_base_yaw_deg = base_yaw_deg
	type = _read_type(config.get("type", TYPE_STATIC))
	mode = _read_mode(config.get("mode", MODE_ONCE))
	speed = _read_float(config, "speed", 1.0)
	spin_deg_s = _read_float(config, "spin_deg_s", 90.0)
	waypoints = _read_waypoints(config.get("waypoints", []))

	_points.clear()
	_segment_lengths.clear()
	_closed = false
	match type:
		TYPE_LINE:
			_build_line_path()
		TYPE_POLYLINE:
			_build_polyline_path()
		_:
			pass
	_rebuild_segments()
	update(0.0)


## Evaluate the pose for a given simulation time. No state is integrated, so
## calling it with the same time always yields the same pose.
func update(sim_time_s: float) -> void:
	var t: float = maxf(sim_time_s, 0.0)
	finished = false
	match type:
		TYPE_SPIN:
			_update_spin(t)
		TYPE_LINE, TYPE_POLYLINE:
			_update_path(t)
		_:
			current_position = _base_position
			current_yaw_deg = _base_yaw_deg
			# A static target never has motion left to finish.
			finished = true


## Rig-level pose for the current sample.
func get_pose() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(current_yaw_deg)), current_position)


func is_moving() -> bool:
	return type != TYPE_STATIC


## Length of the configured path in metres (zero for static / spin). For a
## polyline in "loop" mode this includes the closing segment.
func path_length() -> float:
	return _total_length


static func from_config(config: Dictionary, base_position: Vector3, base_yaw_deg: float) -> TargetMotion:
	var motion := TargetMotion.new()
	motion.configure(config, base_position, base_yaw_deg)
	return motion


# --- path motion -------------------------------------------------------------

func _update_path(t: float) -> void:
	current_yaw_deg = _base_yaw_deg
	var travelled := speed * t
	var distance := 0.0
	if _total_length <= EPS:
		# Degenerate path: stay at its single point (only meaningful for "once").
		distance = 0.0
		if mode == MODE_ONCE:
			finished = true
	elif mode == MODE_ONCE:
		distance = clampf(travelled, 0.0, _total_length)
		finished = travelled >= _total_length - EPS
	elif mode == MODE_LOOP:
		distance = fposmod(travelled, _total_length)
	else:
		# Pingpong: triangle wave over two path lengths.
		var period := 2.0 * _total_length
		var phase := fposmod(travelled, period)
		distance = phase if phase <= _total_length else period - phase
	current_position = _sample_path(distance)


## Map a travelled distance (already clamped / wrapped) to a point on the path.
func _sample_path(distance: float) -> Vector3:
	if _points.is_empty():
		return _base_position
	if _points.size() == 1:
		return _points[0]
	var remaining := distance
	var last_segment := _segment_lengths.size() - 1
	for i in _segment_lengths.size():
		var segment_length: float = _segment_lengths[i]
		if remaining <= segment_length or i == last_segment:
			var from: Vector3 = _points[i]
			var to: Vector3 = _points[(i + 1) % _points.size()]
			var ratio := 0.0
			if segment_length > EPS:
				ratio = clampf(remaining / segment_length, 0.0, 1.0)
			return from.lerp(to, ratio)
		remaining -= segment_length
	return _points[_points.size() - 1]


func _build_line_path() -> void:
	var points := _floor_points(waypoints)
	if points.size() >= 2:
		_points = points
		_closed = false
	elif points.size() == 1:
		# One waypoint: travel from the scenario position to it.
		_points = [_floor_point(_base_position), points[0]]
		_closed = false
	else:
		push_warning("TargetMotion: 'line' needs at least one waypoint; staying at the base position")
		_points = [_floor_point(_base_position)]


func _build_polyline_path() -> void:
	var points := _floor_points(waypoints)
	if points.size() < 2:
		push_warning("TargetMotion: 'polyline' needs at least two waypoints; staying at the base position")
		_points = [_floor_point(_base_position)]
		return
	_points = points
	# Only "loop" closes the path (last -> first); "once"/"pingpong" go open.
	_closed = mode == MODE_LOOP


func _floor_points(points: Array[Vector3]) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for point in points:
		result.append(_floor_point(point))
	return result


## Target floor anchor: waypoint heights are always ignored.
func _floor_point(point: Vector3) -> Vector3:
	return Vector3(point.x, 0.0, point.z)


func _rebuild_segments() -> void:
	_segment_lengths.clear()
	_total_length = 0.0
	if _points.size() < 2:
		return
	var segment_count := _points.size() - 1
	if _closed:
		segment_count += 1
	for i in segment_count:
		var from: Vector3 = _points[i]
		var to: Vector3 = _points[(i + 1) % _points.size()]
		var length := from.distance_to(to)
		_segment_lengths.append(length)
		_total_length += length


# --- spin motion -------------------------------------------------------------

func _update_spin(t: float) -> void:
	current_position = _base_position
	if is_zero_approx(spin_deg_s):
		current_yaw_deg = _base_yaw_deg
		# No turn is possible: a "once" spin is already complete.
		finished = mode == MODE_ONCE
		return

	var direction_sign := 1.0 if spin_deg_s >= 0.0 else -1.0
	var raw := spin_deg_s * t
	if mode == MODE_ONCE:
		var delta := minf(raw, FULL_TURN_DEG) if direction_sign > 0.0 else maxf(raw, -FULL_TURN_DEG)
		current_yaw_deg = _base_yaw_deg + delta
		finished = absf(delta) >= FULL_TURN_DEG - EPS
	elif mode == MODE_LOOP:
		current_yaw_deg = _base_yaw_deg + raw
	else:
		# Pingpong: triangle wave between base_yaw and base_yaw + one turn,
		# travelling in the sign direction of spin_deg_s.
		var magnitude := absf(raw)
		var phase := fposmod(magnitude, 2.0 * FULL_TURN_DEG)
		var turn := phase if phase <= FULL_TURN_DEG else 2.0 * FULL_TURN_DEG - phase
		current_yaw_deg = _base_yaw_deg + direction_sign * turn


# --- config parsing ----------------------------------------------------------

func _read_type(value: Variant) -> String:
	var requested := String(value).to_lower()
	if requested in [TYPE_STATIC, TYPE_LINE, TYPE_POLYLINE, TYPE_SPIN]:
		return requested
	push_warning("TargetMotion: unknown type '%s'; using 'static'" % requested)
	return TYPE_STATIC


func _read_mode(value: Variant) -> String:
	var requested := String(value).to_lower()
	if requested in [MODE_ONCE, MODE_LOOP, MODE_PINGPONG]:
		return requested
	push_warning("TargetMotion: unknown mode '%s'; using 'once'" % requested)
	return MODE_ONCE


func _read_float(config: Dictionary, key: String, default_value: float) -> float:
	var value: Variant = config.get(key, default_value)
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return float(value)
	push_warning("TargetMotion: '%s' is not a number; using %.3f" % [key, default_value])
	return default_value


func _read_waypoints(value: Variant) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if not (value is Array):
		if value != null:
			push_warning("TargetMotion: 'waypoints' is not an array; ignored")
		return result
	for entry in value:
		var point := _point_from(entry)
		if point.is_finite():
			result.append(point)
		else:
			push_warning("TargetMotion: ignoring waypoint that is not [x, y, z]")
	return result


## Accepts a Vector3, an [x, y, z] array or an {x, y, z} dictionary; returns a
## non-finite vector for unsupported entries.
func _point_from(entry: Variant) -> Vector3:
	if entry is Vector3:
		var vector: Vector3 = entry
		return vector
	if entry is Array:
		var array: Array = entry
		if array.size() >= 3:
			return Vector3(float(array[0]), float(array[1]), float(array[2]))
		return Vector3(NAN, NAN, NAN)
	if entry is Dictionary:
		var dict: Dictionary = entry
		if dict.has("x") and dict.has("y") and dict.has("z"):
			return Vector3(float(dict["x"]), float(dict["y"]), float(dict["z"]))
	return Vector3(NAN, NAN, NAN)
