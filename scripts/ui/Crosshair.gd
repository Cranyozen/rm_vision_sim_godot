class_name Crosshair
extends Control

## Simple HUD reticle: marks the centre of the 3D view (in operator FPV this is
## the aim direction) and the centre of the fullscreen feed.

const COLOR := Color(0.20, 1.0, 0.55, 0.95)
const OUTLINE := Color(0.0, 0.05, 0.02, 0.75)
const GAP := 5.0
const LEN := 13.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit_to_parent()
	resized.connect(queue_redraw)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_fit_to_parent):
		vp.size_changed.connect(_fit_to_parent)


func _fit_to_parent() -> void:
	# set_anchors_preset() alone keeps the zero-sized rect this control had when
	# it was added, so the reticle drew into the top-left corner and was never
	# visible. Anchors and offsets must be set together.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	# Dark backing first: the field is bright white, so plain green is hard to
	# read without a contrasting edge.
	_stroke(c, OUTLINE, 4.0)
	_stroke(c, COLOR, 2.0)
	draw_circle(c, 2.0, OUTLINE)
	draw_circle(c, 1.5, COLOR)


func _stroke(c: Vector2, col: Color, width: float) -> void:
	draw_line(c + Vector2(-GAP - LEN, 0), c + Vector2(-GAP, 0), col, width)
	draw_line(c + Vector2(GAP, 0), c + Vector2(GAP + LEN, 0), col, width)
	draw_line(c + Vector2(0, -GAP - LEN), c + Vector2(0, -GAP), col, width)
	draw_line(c + Vector2(0, GAP), c + Vector2(0, GAP + LEN), col, width)
