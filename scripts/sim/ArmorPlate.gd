class_name ArmorPlate
extends Node3D

## A single RM armour module (target = plates only, no target chassis).
## Local convention: +Z is the front face, +Y is up, origin at the module
## centre. That matches `TargetRig`, which turns each plate to face outward.
##
## Mounting: the real AM01/AM12 module is installed at 75 deg to the ground
## (the top edge leans back toward the robot), so `_ready()` leans the whole
## plate by `MOUNT_TILT_DEG`; the front normal then points 15 deg upward.
##
## Geometry and skin come straight from the Bevy simulator's official robot
## assets: `assets/models/armor/armor_small.glb` is the AM02 module extracted
## from Bevy's `vehicle.glb` and `armor_large.glb` is the AM12 module extracted
## from `HERO.glb` (tools/extract_armor.py). The number is white geometry, not
## a texture decal, and the team light bars are emissive meshes; Bevy shows the
## armour by toggling those children's visibility, and so does this class.
##
## Node names in the extracted GLBs:
##   BODY, BODY_BASE, PANEL_CENTER            -- armour shell
##   STICKER_2 / STICKER_3 / ... / STICKER_B  -- number geometry
##   LIGHT_L_RED / LIGHT_R_RED                -- red team light bars
##   LIGHT_L_BLUE / LIGHT_R_BLUE              -- blue team light bars

var team := "red"
var armor_size := "small"       ## small | large
var number := "1"

const ARMOR_MODELS := {
	"small": preload("res://assets/models/armor/armor_small.glb"),
	"large": preload("res://assets/models/armor/armor_large.glb"),
}

## Measured envelope of the extracted game modules (width, height, depth) in
## metres; see docs/ARCHITECTURE.md §4.1. The origin is the bbox centre and
## +Z is the front face, so the strike-face plane is at depth * 0.5.
const ARMOR_ENVELOPES := {
	"small": Vector3(0.1410, 0.1299, 0.0192),
	"large": Vector3(0.2360, 0.1322, 0.0192),
}

## Height of the sticker plane above the module origin (front panel).
const STICKER_Z := 0.0096

## Centre of the strike face relative to the module origin, along local +Z.
const STRIKE_FACE_Z := STICKER_Z

## TargetRig supplies the full installation pose (yaw + the 75 deg mounting
## angle), so this module must not add its own mount tilt on top of it.
var external_pose := false

## The real module is installed at 75 deg to the ground: the top edge leans
## back, so the front normal points 15 deg upward. Rotating about X by -15 deg
## does exactly that in the +Z-front convention above.
const MOUNT_TILT_DEG := 15.0


func _ready() -> void:
	if not external_pose:
		rotation.x = -deg_to_rad(MOUNT_TILT_DEG)
	_build()


## Measured envelope for an armour size name, with a small fallback so an
## unknown name never crashes a target build.
static func envelope_for(size_name: String) -> Vector3:
	return ARMOR_ENVELOPES.get(size_name, ARMOR_ENVELOPES["small"])


## Vertical distance from the module centre down to its lowest edge when the
## module is installed at `tilt_deg` to the ground. TargetRig uses this for the
## S124/S125 lower-edge checks (the 15 deg lean also drops the front/back
## corners by `depth / 2 * sin(tilt)`).
static func lower_edge_drop(size_name: String, tilt_deg := MOUNT_TILT_DEG) -> float:
	var envelope := envelope_for(size_name)
	var tilt := deg_to_rad(tilt_deg)
	return envelope.y * 0.5 * cos(tilt) + envelope.z * 0.5 * sin(tilt)


func _build() -> void:
	var packed: PackedScene = ARMOR_MODELS.get(armor_size, ARMOR_MODELS["small"])
	var model: Node3D = packed.instantiate()
	model.name = "ArmorModel"
	add_child(model)

	var wanted_sticker := "STICKER_" + number
	var wanted_light := "_RED" if team == "red" else "_BLUE"
	var found_sticker := false
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var nm := String(mi.name)
		mi.layers = 1
		if nm.begins_with("STICKER_"):
			mi.visible = nm == wanted_sticker
			found_sticker = found_sticker or mi.visible
			# A flat sticker 0.12 mm in front of the panel should not cast a
			# shadow onto its own backing plate.
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		elif nm.begins_with("LIGHT_"):
			mi.visible = nm.ends_with(wanted_light)
		else:
			mi.visible = true

	if not found_sticker:
		_add_number_label()


## The official model does not carry every label for every size (small armour
## has no "1", large armour has no "2"). Fall back to a label so a
## hand-authored target never silently loses its number.
func _add_number_label() -> void:
	var label := Label3D.new()
	label.name = "NumberLabel"
	label.text = number
	label.font_size = 96
	label.pixel_size = 0.0010
	label.outline_size = 0
	label.modulate = Color(0.94, 0.94, 0.94, 1.0)
	label.position = Vector3(0.0, 0.0, STICKER_Z + 0.0002)
	label.double_sided = true
	label.layers = 1
	add_child(label)
