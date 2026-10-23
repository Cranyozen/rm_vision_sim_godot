class_name TargetRig
extends Node3D

## Static armour-plate target for Phase 1. 1 / 2 / 4 plates around a square.
## The plate centres sit at the same half-width as the real robot's armour
## (vehicle.glb armour faces are at ~±0.227 m), so a 4-plate target spans
## ~0.48 m — comparable to the 0.52 m ego footprint, not a tiny box.
## Plates hang at 0.25 m above the field; no chassis, no physics.

var team := "red"
var armor_size := "small"       ## small | large
var number := "1"
var armors := 4                 ## 1 | 2 | 4
var yaw_deg := 0.0

const SMALL_RADIUS := 0.24
const LARGE_RADIUS := 0.30


func _ready() -> void:
	rotation.y = deg_to_rad(yaw_deg)
	_build()


func _build() -> void:
	var radius := SMALL_RADIUS if armor_size == "small" else LARGE_RADIUS
	var angles: Array[float] = []
	match armors:
		4:
			angles = [0.0, PI * 0.5, PI, PI * 1.5]
		2:
			angles = [0.0, PI]
		_:
			angles = [0.0]

	for angle in angles:
		var plate := ArmorPlate.new()
		plate.team = team
		plate.armor_size = armor_size
		plate.number = number
		plate.position = Vector3(sin(angle) * radius, 0.25, -cos(angle) * radius)
		plate.rotation.y = -angle + PI
		add_child(plate)
