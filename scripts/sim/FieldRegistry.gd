class_name FieldRegistry
extends RefCounted

## Phase 3 field catalogue: the single place that maps a scenario `field:` id
## to the visual scene, its vertical offset and the simple collision geometry.
##
## Fields:
##   rmul2027_1v1  visual GLB (play surface already at y = 0)
##   rmul2027_3v3  visual GLB; authored with the play surface at y = 0.10, so
##                 the node is shifted by FIELD_3V3_Y_OFFSET (-0.10 m)
##   flat          generated 20 x 20 m plane, no visible walls (long range)
##
## Collision is deliberately separate from the visual node (it is built at the
## world origin, not under the shifted GLB) and is always the same simple
## perimeter: a floor box plus four wall boxes whose inner faces sit exactly at
## the field's playable half extents.
##
## Scenario loading rebuilds both nodes when the field changes; see
## Main._build_field() / Main._clear_field().

## Ordered field ids (UI order).
const FIELD_IDS := [SimConfig.FIELD_1V1, SimConfig.FIELD_3V3, SimConfig.FIELD_FLAT]


static func is_valid(field_id: String) -> bool:
	return FIELD_IDS.has(field_id)


## Static description of a field. Only `id` and `path`/`y_offset`/`half_extents`
## are meaningful; unknown ids return the 1v1 spec (with an empty id).
static func get_spec(field_id: String) -> Dictionary:
	match field_id:
		SimConfig.FIELD_1V1:
			return {
				"id": SimConfig.FIELD_1V1,
				"label": "1v1",
				"path": SimConfig.FIELD_1V1_PATH,
				"y_offset": 0.0,
				"half_extents": SimConfig.FIELD_1V1_HALF_EXTENTS,
				"floor_size": SimConfig.FIELD_1V1_HALF_EXTENTS * 2.0,
				"visible_walls": true,
			}
		SimConfig.FIELD_3V3:
			return {
				"id": SimConfig.FIELD_3V3,
				"label": "3v3",
				"path": SimConfig.FIELD_3V3_PATH,
				"y_offset": SimConfig.FIELD_3V3_Y_OFFSET,
				"half_extents": SimConfig.FIELD_3V3_HALF_EXTENTS,
				"floor_size": SimConfig.FIELD_3V3_HALF_EXTENTS * 2.0,
				"visible_walls": true,
			}
		SimConfig.FIELD_FLAT:
			return {
				"id": SimConfig.FIELD_FLAT,
				"label": "flat",
				"path": "",
				"y_offset": 0.0,
				"half_extents": SimConfig.FIELD_FLAT_HALF_EXTENTS,
				"floor_size": SimConfig.FIELD_FLAT_SIZE,
				"visible_walls": false,
			}
	push_warning("FieldRegistry: unknown field '%s'; using 1v1" % field_id)
	return get_spec(SimConfig.FIELD_1V1)


## Human-readable label for the HUD/UI ("1v1", "3v3", "flat").
static func label(field_id: String) -> String:
	return String(get_spec(field_id)["label"])


## Build the visual field node (GLB instance or generated flat plane). The node
## is already offset so its play surface is at y = 0.
static func build_visual(field_id: String) -> Node3D:
	var spec := get_spec(field_id)
	var root := Node3D.new()
	root.name = "Field"
	root.position = Vector3(0.0, float(spec["y_offset"]), 0.0)

	var path := String(spec["path"])
	if path != "":
		var packed := load(path) as PackedScene
		if packed != null:
			var instance := packed.instantiate()
			if instance is Node3D:
				(instance as Node3D).name = "FieldModel"
				root.add_child(instance)
				return root
			instance.free()
		push_warning("FieldRegistry: %s missing, using generated floor" % path)

	root.add_child(_build_flat_floor(Vector2(spec["floor_size"])))
	return root


## Build the perimeter collision body at the world origin. Kept separate from
## the visual node because the 3v3 GLB is shifted vertically; collision is
## always anchored to the play surface (y = 0).
static func build_collision(field_id: String) -> StaticBody3D:
	var spec := get_spec(field_id)
	var half: Vector2 = spec["half_extents"]
	var floor_size: Vector2 = spec["floor_size"]
	var thickness := SimConfig.FIELD_WALL_THICKNESS
	var height := SimConfig.FIELD_WALL_HEIGHT

	var body := StaticBody3D.new()
	body.name = "FieldCollision"
	body.collision_layer = 1
	body.collision_mask = 1

	_add_box_shape(body, Vector3(0.0, -SimConfig.FIELD_FLOOR_THICKNESS * 0.5, 0.0),
		Vector3(floor_size.x, SimConfig.FIELD_FLOOR_THICKNESS, floor_size.y))
	var wall_y := height * 0.5
	# North / south (±Z).
	_add_box_shape(body, Vector3(0.0, wall_y, -(half.y + thickness * 0.5)),
		Vector3(half.x * 2.0 + thickness * 2.0, height, thickness))
	_add_box_shape(body, Vector3(0.0, wall_y, half.y + thickness * 0.5),
		Vector3(half.x * 2.0 + thickness * 2.0, height, thickness))
	# West / east (±X).
	_add_box_shape(body, Vector3(-(half.x + thickness * 0.5), wall_y, 0.0),
		Vector3(thickness, height, half.y * 2.0))
	_add_box_shape(body, Vector3(half.x + thickness * 0.5, wall_y, 0.0),
		Vector3(thickness, height, half.y * 2.0))
	return body


## Per-axis chassis limit for a field (half extents minus the ego radius).
static func chassis_limit(field_id: String) -> Vector2:
	var half: Vector2 = get_spec(field_id)["half_extents"]
	return Vector2(maxf(half.x - SimConfig.EGO_RADIUS, 0.0),
		maxf(half.y - SimConfig.EGO_RADIUS, 0.0))


static func _build_flat_floor(size: Vector2) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "FlatFloor"
	var plane := PlaneMesh.new()
	plane.size = size
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.19, 0.21, 0.23)
	mat.roughness = 0.95
	mat.metallic = 0.0
	mi.material_override = mat
	mi.layers = 1
	return mi


static func _add_box_shape(body: StaticBody3D, centre: Vector3, size: Vector3) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = centre
	body.add_child(shape)
