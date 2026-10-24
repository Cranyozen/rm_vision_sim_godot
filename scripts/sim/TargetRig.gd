class_name TargetRig
extends Node3D

## Static four-armour target that mirrors a real robot's armour layout.
##
## Geometry (RoboMaster armour installation rules S120/S121/S124/S125):
## - four armour modules, two per group, each group on one body axis:
##   the +X/-X pair and the +Y/-Y pair; every plate faces outward along its
##   body axis (direction vectors = +X, -X, +Y, -Y within 5 deg);
## - each module is installed at 75 deg to the ground, i.e. its face normal is
##   15 deg above the horizon (ArmorPlate.MOUNT_TILT_DEG); the side-light-free
##   edges stay in the XY plane (roll = 0);
## - the two groups' plate-centre lines are perpendicular (each on a body
##   axis) and the plates have no lateral offset;
## - the lower group's plate-centre midpoint **is** the target centre (the rig
##   origin, `Center`); the other group is centred directly above it;
## - S124: the upper group sits at most 100 mm above the lower group;
## - S125: every armour lower edge is above the ground and at most 400 mm
##   above it.
##
## The rig's root is the ground anchor (`position.y` is the local floor
## height); all geometry hangs off the `Center` child, whose origin is the
## target centre. `get_center_global_transform()` is the TF map -> target pose.
##
## Body frame (same axes as the target-centre TF frame, REP-103):
## +X forward, +Y left, +Z up. Godot is Y-up, so body <-> Godot uses
## SimConfig.godot_to_body() / body_to_godot(). The per-plate strike-face
## poses returned by `get_armor_frames()` are expressed in this body frame
## with +X along the plate width, +Y up and +Z along the outward face normal
## (the RoboMaster/QYG armour convention), so RosBackend can publish them
## directly as TF.
##
## Per-target layout, set before `add_child()` (defaults satisfy the rules):
##   center_height_m       target centre above the field floor
##   group_height_offset_m upper group above the target centre (<= 100 mm)
##   x_group_span_m        centre-to-centre distance of the +X/-X pair
##   y_group_span_m        centre-to-centre distance of the +Y/-Y pair
##   lower_group           "x" or "y": which pair defines the target centre
## Values outside the rule-compliant range are clamped (with a warning), so a
## built target always passes `check_installation()`.

## Default target-centre height: the Phase 1 plate height (0.25 m).
const DEFAULT_CENTER_HEIGHT_M := 0.25
## Default upper-group offset: clearly above the centre, well inside S124.
const DEFAULT_GROUP_HEIGHT_OFFSET_M := 0.05
## Default plate-pair separation: the old 0.24 m / 0.30 m plate radius.
const SMALL_DEFAULT_SPAN_M := 0.48
const LARGE_DEFAULT_SPAN_M := 0.60
## S124: any two armour modules' lower edges differ by at most 100 mm.
const MAX_GROUP_HEIGHT_OFFSET_M := 0.100
## S125: every armour lower edge is at most 400 mm above the ground.
const MAX_LOWER_EDGE_HEIGHT_M := 0.400
## S125: the lower edge must not touch the ground.
const MIN_GROUND_CLEARANCE_M := 0.001

var team := "red"
var armor_size := "small"       ## small | large
var number := "1"
var yaw_deg := 0.0

## Target centre height above the field floor.
var center_height_m := DEFAULT_CENTER_HEIGHT_M
## Height of the upper pair above the target centre.
var group_height_offset_m := DEFAULT_GROUP_HEIGHT_OFFSET_M
## Plate-centre separation per group. <= 0 selects the default for the size.
var x_group_span_m := -1.0
var y_group_span_m := -1.0
## Pair at the target-centre height: "x" (+X/-X) or "y" (+Y/-Y).
var lower_group := "x"

var _center: Node3D = null
var _armor_frames: Array[Dictionary] = []


func _ready() -> void:
	rotation.y = deg_to_rad(yaw_deg)
	_clamp_to_rules()
	_build()


## Global pose of the target centre (the TF child frame of map).
func get_center_global_transform() -> Transform3D:
	if _center == null:
		return global_transform
	return _center.global_transform


## Strike-face frames in target-body coordinates. Each entry:
##   suffix             "armor_px" / "armor_nx" / "armor_py" / "armor_ny"
##   group              "x" | "y"
##   direction          "px" | "nx" | "py" | "ny" (S120 direction vector)
##   body_direction     unit outward direction in body XY (direction vector)
##   body_center        geometric centre of the armour module
##   body_position      centre of the strike face (front panel plane)
##   body_basis         columns = width, up, face normal (normal points out
##                      and 15 deg up)
##   lower_edge_m       height of the module's lowest edge above the floor
##   plate              the ArmorPlate node
func get_armor_frames() -> Array[Dictionary]:
	return _armor_frames


## Empty when the built layout satisfies S120/S121/S124/S125, otherwise one
## human-readable message per violation. Used by tests/acceptance tooling.
func check_installation() -> Array[String]:
	var violations: Array[String] = []
	if _armor_frames.size() != 4:
		violations.append("expected 4 armour modules, built %d" % _armor_frames.size())
		return violations

	var down := Vector3(0.0, 0.0, -1.0)
	var x_centers: Array[Vector3] = []
	var y_centers: Array[Vector3] = []
	var min_edge := INF
	var max_edge := -INF

	for frame in _armor_frames:
		var suffix: String = frame["suffix"]
		var body_basis: Basis = frame["body_basis"]
		var normal := body_basis.z
		# S120: face-normal line vs -Z line = 75 deg (15 deg above horizon).
		var tilt := rad_to_deg(acos(clampf(absf(normal.dot(down)), 0.0, 1.0)))
		if absf(tilt - (90.0 - ArmorPlate.MOUNT_TILT_DEG)) > 5.0:
			violations.append("S120 %s: face normal is %.1f deg from -Z (expected 75)" % [suffix, tilt])
		# S120: the normal's horizontal projection is the direction vector and
		# must match its body axis within 5 deg.
		var direction := Vector3(normal.x, normal.y, 0.0)
		if direction.length_squared() > 0.0:
			var expected: Vector3 = frame["body_direction"]
			var error := rad_to_deg(acos(clampf(
				direction.normalized().dot(expected), -1.0, 1.0)))
			if error > 5.0:
				violations.append("S120 %s: direction vector is %.1f deg off its body axis" % [suffix, error])

		var group: String = frame["group"]
		var module_center: Vector3 = frame["body_center"]
		if group == "x":
			x_centers.append(module_center)
		else:
			y_centers.append(module_center)

		# S125: lower edge above the ground and at most 400 mm above it.
		var lower: float = frame["lower_edge_m"]
		min_edge = minf(min_edge, lower)
		max_edge = maxf(max_edge, lower)
		if lower <= 0.0:
			violations.append("S125 %s: lower edge touches the ground (%.3f m)" % [suffix, lower])
		if lower > MAX_LOWER_EDGE_HEIGHT_M + 1e-6:
			violations.append("S125 %s: lower edge is %.3f m above the ground (max 0.400)" % [suffix, lower])

	# S121: the X-axis and Y-axis plate-centre lines are perpendicular, and a
	# plate mounted on one axis is offset at most 50 mm across the other axis.
	if x_centers.size() == 2 and y_centers.size() == 2:
		var x_line: Vector3 = x_centers[1] - x_centers[0]
		var y_line: Vector3 = y_centers[1] - y_centers[0]
		if absf(x_line.normalized().dot(y_line.normalized())) > 1e-3:
			violations.append("S121: X-axis and Y-axis armour centre lines are not perpendicular")
		for center in y_centers:
			if absf(center.x) > 0.050 + 1e-6:
				violations.append("S121: Y-axis armour offset on X = %.3f m (max 0.050)" % center.x)
		for center in x_centers:
			if absf(center.y) > 0.050 + 1e-6:
				violations.append("S121: X-axis armour offset on Y = %.3f m (max 0.050)" % center.y)
	else:
		violations.append("S121: expected two armour modules per body axis")

	# S124: any two modules' lower edges differ by at most 100 mm.
	if max_edge - min_edge > MAX_GROUP_HEIGHT_OFFSET_M + 1e-6:
		violations.append("S124: armour lower edges span %.3f m (max 0.100)" % (max_edge - min_edge))

	return violations


# --- build -------------------------------------------------------------------

## Clamp the requested layout into the rule-compliant ranges so the built
## target cannot violate S124/S125; the defaults already comply.
func _clamp_to_rules() -> void:
	if armor_size != "small" and armor_size != "large":
		push_warning("TargetRig(%s): armor_size '%s' is not 'small'/'large'; using 'small'"
			% [name, armor_size])
		armor_size = "small"

	if lower_group != "x" and lower_group != "y":
		push_warning("TargetRig(%s): lower_group '%s' is not 'x'/'y'; using 'x'" % [name, lower_group])
		lower_group = "x"

	if group_height_offset_m < 0.0 or group_height_offset_m > MAX_GROUP_HEIGHT_OFFSET_M:
		push_warning("TargetRig(%s): group_height_offset_m %.3f outside the S124 range [0, 0.100]; clamped"
			% [name, group_height_offset_m])
		group_height_offset_m = clampf(group_height_offset_m, 0.0, MAX_GROUP_HEIGHT_OFFSET_M)

	var default_span := SMALL_DEFAULT_SPAN_M if armor_size == "small" else LARGE_DEFAULT_SPAN_M
	var min_span := ArmorPlate.envelope_for(armor_size).x
	x_group_span_m = _clamp_span("x_group_span_m", x_group_span_m, default_span, min_span)
	y_group_span_m = _clamp_span("y_group_span_m", y_group_span_m, default_span, min_span)

	# S125 leaves room for both groups: the upper group is the tallest, the
	# lower group's lower edge must still clear the floor.
	var drop := ArmorPlate.lower_edge_drop(armor_size)
	var min_center := drop + MIN_GROUND_CLEARANCE_M
	var max_center := MAX_LOWER_EDGE_HEIGHT_M + drop - group_height_offset_m
	if center_height_m < min_center:
		push_warning("TargetRig(%s): center_height_m %.3f would put an armour lower edge on the ground; clamped to %.3f"
			% [name, center_height_m, min_center])
		center_height_m = min_center
	elif center_height_m > max_center:
		push_warning("TargetRig(%s): center_height_m %.3f would put an armour lower edge above 0.400 m; clamped to %.3f"
			% [name, center_height_m, max_center])
		center_height_m = max_center


func _clamp_span(property: String, value: float, default_value: float, min_value: float) -> float:
	if value <= 0.0:
		return default_value
	if value < min_value:
		push_warning("TargetRig(%s): %s %.3f m is smaller than one armour width; clamped to %.3f m"
			% [name, property, value, min_value])
		return min_value
	return value


func _build() -> void:
	_center = Node3D.new()
	_center.name = "Center"
	_center.position = Vector3(0.0, center_height_m, 0.0)
	add_child(_center)

	var tilt := deg_to_rad(ArmorPlate.MOUNT_TILT_DEG)
	var cos_tilt := cos(tilt)
	var sin_tilt := sin(tilt)
	var up_body := Vector3(0.0, 0.0, 1.0)
	var drop := ArmorPlate.lower_edge_drop(armor_size)
	var upper_group := "y" if lower_group == "x" else "x"
	var heights := {lower_group: 0.0, upper_group: group_height_offset_m}

	# +X/-X first, then +Y/-Y, each + before -, so the frame suffixes are
	# armour_px, armour_nx, armour_py, armour_ny.
	for group in ["x", "y"]:
		var span: float = x_group_span_m if group == "x" else y_group_span_m
		var axis_body: Vector3 = Vector3(1.0, 0.0, 0.0) if group == "x" else Vector3(0.0, 1.0, 0.0)
		var height: float = heights[group]
		for sign in [1.0, -1.0]:
			var direction: Vector3 = axis_body * float(sign)
			var normal: Vector3 = direction * cos_tilt + up_body * sin_tilt
			var up: Vector3 = -direction * sin_tilt + up_body * cos_tilt
			var side: Vector3 = up.cross(normal)
			var plate_center: Vector3 = direction * (span * 0.5) + up_body * height
			var strike_center: Vector3 = plate_center + normal * ArmorPlate.STRIKE_FACE_Z
			var body_basis := Basis(side, up, normal)

			var plate := ArmorPlate.new()
			plate.team = team
			plate.armor_size = armor_size
			plate.number = number
			plate.external_pose = true
			# The node's local axes are the semantic plate frame (width, up,
			# normal), so map each frame axis into Godot rather than rotating
			# the whole rotation matrix.
			plate.name = "Armor_" + _suffix_for(group, sign).trim_prefix("armor_")
			plate.transform = Transform3D(
				SimConfig.body_axes_to_godot(body_basis),
				SimConfig.body_to_godot(plate_center))
			_center.add_child(plate)

			_armor_frames.append({
				"suffix": _suffix_for(group, sign),
				"group": group,
				"direction": _suffix_for(group, sign).trim_prefix("armor_"),
				"body_direction": direction,
				"body_center": plate_center,
				"body_position": strike_center,
				"body_basis": body_basis,
				"lower_edge_m": center_height_m + height - drop,
				"plate": plate,
			})


func _suffix_for(group: String, sign: float) -> String:
	return "armor_p" + group if sign > 0.0 else "armor_n" + group
