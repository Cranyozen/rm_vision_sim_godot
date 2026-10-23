class_name SimConfig
extends RefCounted

## Single source of truth for Phase 1 constants.
## QYG camera intrinsics are the real rm_bringup camera_info.yaml values at
## 1440x1080; the feed renders at 1280x1024 and scales fx/fy/cx/cy.

const FEED_WIDTH := 1280
const FEED_HEIGHT := 1024

const ORIG_WIDTH := 1440.0
const ORIG_HEIGHT := 1080.0
const FX := 3571.1890927935297
const FY := 3569.0234714126823
const CX := 683.5999418028833
const CY := 565.5838917436471

const FIELD_1V1_PATH := "res://assets/fields/rmul2027_1v1.glb"
const FIELD_3V3_PATH := "res://assets/fields/rmul2027_3v3.glb"
const EGO_VEHICLE_PATH := "res://assets/models/ego/vehicle.glb"
const EGO_INFANTRY_PATH := "res://assets/models/ego/infantry.glb"

## QYG gimbal_link -> camera_link mount (metres, radians).
const QYG_CAMERA_OFFSET := Vector3(0.0461892, 0.0, -0.0603874)
const QYG_CAMERA_RPY := Vector3(0.0, 0.091, 0.0)

## vehicle.glb "CAM_DIRECTION" is the visual camera location in gimbal space.
const VEHICLE_CAMERA_OFFSET := Vector3(0.0, 0.1963421255, -0.0600251630)

static func feed_intrinsics() -> Dictionary:
	var sx := float(FEED_WIDTH) / ORIG_WIDTH
	var sy := float(FEED_HEIGHT) / ORIG_HEIGHT
	return {
		"width": FEED_WIDTH,
		"height": FEED_HEIGHT,
		"fx": FX * sx,
		"fy": FY * sy,
		"cx": CX * sx,
		"cy": CY * sy,
	}

static func vertical_fov_deg() -> float:
	var k := feed_intrinsics()
	return rad_to_deg(2.0 * atan(float(FEED_HEIGHT) / (2.0 * float(k["fy"]))))
