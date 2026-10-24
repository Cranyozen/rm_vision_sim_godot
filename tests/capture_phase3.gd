extends SceneTree

## Dev-only: render the current scenario and save window + feed screenshots.
##
## Usage (windowed, real GPU):
##   godot --path . --script res://tests/capture_phase3.gd
##   godot --path . --script res://tests/capture_phase3.gd -- --scenario=res://scenarios/3v3_spin.yaml
##
## The scenario selection is the same as the simulator's (`--scenario=...` after
## `--`, see ScenarioStore.startup_scenario_path). Two window shots are taken
## ~1.5 s apart so target motion is visible as a difference, plus one
## 1280x1024 feed image.
##
## Writes tests/phase3_view_a.png, tests/phase3_view_b.png,
## tests/phase3_feed.png (all gitignored). Run on a real GPU: software Mesa
## renders black frames and that is a GPU-permission issue, not a code bug.

const SHOT_A_FRAME := 90
const SHOT_B_FRAME := 210

var _frames := 0
var _main: Node
var _open_panel := false


func _initialize() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	# `--panel` opens the scenario UI for the first shot (UI review only).
	_open_panel = OS.get_cmdline_user_args().has("--panel")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 60 and _open_panel:
		_main._set_scenario_panel_open(true)
	if _frames == SHOT_A_FRAME:
		_save_window("res://tests/phase3_view_a.png")
		_save_feed("res://tests/phase3_feed.png")
		return false
	if _frames == SHOT_B_FRAME:
		if _open_panel:
			_main._set_scenario_panel_open(false)
		_save_window("res://tests/phase3_view_b.png")
		var scenario = _main._scenario_path if _main._scenario_path != "" else "(fallback)"
		print("capture: scenario ", scenario, " field ", _main._field_id,
			" targets ", _main._targets.size())
		quit(0)
		return true
	return false


func _save_window(path: String) -> void:
	# get_texture().get_image() returns a stale frame unless a draw is forced.
	RenderingServer.force_draw(false)
	var image := root.get_texture().get_image()
	if image == null:
		printerr("capture: no viewport image")
		return
	var err := image.save_png(path)
	print("capture: ", path, " ", image.get_width(), "x", image.get_height(), " err=", err)


func _save_feed(path: String) -> void:
	if _main == null:
		return
	var image: Image = _main.get_feed_image()
	if image == null:
		printerr("capture: feed image unavailable (headless / no renderer)")
		return
	var err := image.save_png(path)
	print("capture: ", path, " ", image.get_width(), "x", image.get_height(), " err=", err)
