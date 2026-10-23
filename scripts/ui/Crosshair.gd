class_name Crosshair
extends Control

## Simple HUD reticle. Lives on the feed centre and in fullscreen feed mode.

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(queue_redraw)


func _draw() -> void:
	var c := size * 0.5
	var col := Color(0.20, 1.0, 0.55, 0.90)
	var gap := 5.0
	var ln := 13.0
	draw_line(c + Vector2(-gap - ln, 0), c + Vector2(-gap, 0), col, 2.0)
	draw_line(c + Vector2(gap, 0), c + Vector2(gap + ln, 0), col, 2.0)
	draw_line(c + Vector2(0, -gap - ln), c + Vector2(0, -gap), col, 2.0)
	draw_line(c + Vector2(0, gap), c + Vector2(0, gap + ln), col, 2.0)
	draw_circle(c, 2.0, col)
