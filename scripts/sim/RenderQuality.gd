class_name RenderQuality
extends RefCounted

## Phase 5 world-rendering quality presets.
##
## `Main._build_environment()` used to create the WorldEnvironment and the
## key/fill lights inline.  This module owns that setup now so the quality tier
## is a data choice instead of a code edit (Phase 6 adds performance tiers, the
## UI gets a switch, and the vision feed keeps one opinion about exposure).
##
## The feed is 1280x1024 and feeds QYG's YOLO armour detector, so the preset is
## deliberately conservative: glow is barely visible, there is no SSR / SSAO
## light bleed onto emissive team bars, and exposure stays at the value the
## Phase 4 closed-loop measurements were taken with.  "Better looking" must not
## mean "harder to detect".
##
## Presets:
##   high  - SSAO + soft PSSM shadows + subtle glow (default, desktop GPU)
## Any unknown preset falls back to `high` with a warning so scenario/profile
## typos never leave the world unlit.

const PRESET_HIGH := "high"
const DEFAULT_PRESET := PRESET_HIGH
const PRESETS: Array[String] = [PRESET_HIGH]

## Directional shadow atlas.  Per-light shadow map size is not exposed in Godot
## 4 (only the global atlas is), so the 4096 map requested for the quality tier
## is applied through RenderingServer; the 4-split PSSM mode then splits it.
const SHADOW_ATLAS_SIZE := 4096
const SHADOW_ATLAS_16_BITS := true


## Build the world environment and its key/fill lights under `parent`.
## Returns the created WorldEnvironment (lights are added as siblings).
static func build_environment(parent: Node,
		quality_preset: String = DEFAULT_PRESET) -> WorldEnvironment:
	if parent == null:
		push_error("RenderQuality: build_environment needs a parent node")
		return null
	if not PRESETS.has(quality_preset):
		push_warning("RenderQuality: unknown quality preset '%s'; using '%s'"
			% [quality_preset, DEFAULT_PRESET])
		quality_preset = DEFAULT_PRESET

	# The shadow atlas is a rendering-server setting, not an Environment one.
	# Safe in headless: the dummy renderer accepts it and ignores it.
	RenderingServer.directional_shadow_atlas_set_size(SHADOW_ATLAS_SIZE,
		SHADOW_ATLAS_16_BITS)

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = _make_environment(quality_preset)
	parent.add_child(we)

	_add_key_light(parent, quality_preset)
	_add_fill_light(parent)
	return we


static func _make_environment(quality_preset: String) -> Environment:
	var env := Environment.new()

	# Sky / ambient: same palette the Phase 1-4 feeds were validated against,
	# with a slightly deeper ground so the white field floor keeps its edges.
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.11, 0.19, 0.30)
	sky_mat.sky_horizon_color = Color(0.52, 0.60, 0.68)
	sky_mat.ground_bottom_color = Color(0.042, 0.046, 0.052)
	sky_mat.ground_horizon_color = Color(0.28, 0.30, 0.32)
	sky_mat.sun_angle_max = 32.0
	sky_mat.sun_curve = 0.12
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.66, 0.72, 0.82)
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.82
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# Exposure is part of the Phase 4 detector contract: keep it at the value
	# the QYG closed loop was measured with.
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.05

	# Ambient occlusion: contact shadows under the chassis and inside the
	# field cover, which is what sells the "high fidelity" look at 1-3 m.
	# Kept moderate because a hard AO pass over the white floor darkens the
	# floor bands the detector uses for light-bar separation.
	if quality_preset == PRESET_HIGH:
		env.ssao_enabled = true
		env.ssao_radius = 1.1
		env.ssao_intensity = 2.0
		env.ssao_power = 1.5
		env.ssao_detail = 0.5
		env.ssao_horizon = 0.06
		env.ssao_sharpness = 0.98
		env.ssao_light_affect = 0.12
		env.ssao_ao_channel_affect = 0.0

	# Glow: only the emissive team bars / LEDs (emission energy > 1) should
	# bloom.  Very low intensity + level 2+ only keeps thin detector-relevant
	# edges crisp; level 1 (the thinnest blur) is what smears light bars.
	env.glow_enabled = true
	env.set_glow_level(1, 0.0)
	env.set_glow_level(2, 0.6)
	env.set_glow_level(3, 0.8)
	env.set_glow_level(4, 0.6)
	env.set_glow_level(5, 0.3)
	env.glow_intensity = 0.12
	env.glow_strength = 0.9
	env.glow_bloom = 0.02
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 1.15
	env.glow_hdr_scale = 2.0
	env.glow_normalized = true
	env.glow_mix = 0.0

	# No SSR / SDFGI / SSIL: they cost frames on integrated GPUs and SSR on the
	# glossy white field would add streak artefacts to the feed.
	return env


static func _add_key_light(parent: Node, quality_preset: String) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48.0, -35.0, 0.0)
	sun.light_color = Color(1.0, 0.95, 0.88)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 45.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.20
	sun.directional_shadow_split_3 = 0.50
	sun.directional_shadow_fade_start = 0.9
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.035
	sun.shadow_normal_bias = 1.6
	if quality_preset == PRESET_HIGH:
		# A non-zero angular diameter enables the (PCSS) soft shadow filter.
		# 0.25 deg + a wider PCF blur is the size/penumbra trade-off that still
		# holds ~85-95 FPS on the integrated Radeon 780M; the physically exact
		# 0.53 deg sun costs ~18 FPS there for a nearly identical look.
		sun.light_angular_distance = 0.25
		sun.shadow_blur = 1.6
	parent.add_child(sun)


## Soft cool fill from the opposite side so the ego's near-black paint and the
## armour undersides stay readable in the third-person view and the FPV.
static func _add_fill_light(parent: Node) -> void:
	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.rotation_degrees = Vector3(-22.0, 145.0, 0.0)
	fill.light_color = Color(0.62, 0.72, 0.90)
	fill.light_energy = 0.32
	fill.shadow_enabled = false
	parent.add_child(fill)

# --- LOD policy -------------------------------------------------------------
# The ego/field GLBs are imported with `meshes/generate_lods=true` (importer
# default, confirmed by tests/phase5_render_check.gd), so distant field detail
# uses the generated LOD chain automatically.  No manual visibility ranges are
# set here on purpose: the whole world is viewed within ~10 m (17.2 deg feed,
# 2.6 m third-person camera), where a range cutoff would pop the ego out at
# normal gameplay distance.  LOD bias for the ego stays at the default (1.0) so
# the close-up hero look and the feed stay identical.  If Phase 6 adds larger
# fields, add distance-based visibility here rather than per model.
