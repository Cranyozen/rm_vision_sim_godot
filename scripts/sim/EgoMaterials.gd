class_name EgoMaterials
extends RefCounted

## Phase 5 ego PBR polish, model-agnostic.
##
## The source CAD exports have two material problems:
##   * `24sentry_simplified.glb` carries 47 materials with no metallic/roughness
##     authored at all (roughness 1.0, metallic 0.0), i.e. a flat plastic look;
##   * the vehicle's body map is textured, but many surfaces still have no
##     authored roughness, and the GLB textures use the default (nearest)
##     filtering, which crawls at grazing angles.
##
## `enhance(root)` walks every MeshInstance3D surface and, without touching the
## authored team/emissive lights:
##   * fills in sensible metallic/roughness where the source has none,
##   * enables anisotropic mipmap filtering on authored textures.
##
## It deliberately does **not** brighten or replace any albedo colour/texture:
## the rendered material stays as authored in the GLB (so it matches a Blender
## render of the same asset). The vehicle therefore renders as the dark robot
## the source material describes; use scene lighting/exposure to make it
## readable, not a material hack.
##
## Everything is applied as a per-surface override material so the shared GLB
## subresources are never mutated; the rig can be rebuilt (scenario reload)
## without leaking changed materials between instances.

## Roughness for surfaces where the source authored none (matte paint/metal).
const DEFAULT_ROUGHNESS := 0.55

## Metadata key guarding against a double enhance (Lead wires this into
## EgoRig._build(); the capture/dev scripts may also call it).
const ENHANCED_META := "ego_materials_enhanced"


## Improve every StandardMaterial3D surface under `root` in place (overrides).
static func enhance(root: Node3D) -> void:
	if root == null:
		return
	if root.has_meta(ENHANCED_META):
		return
	root.set_meta(ENHANCED_META, true)

	for mesh_instance in _mesh_instances(root):
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var base := mesh_instance.get_active_material(surface)
			if not (base is StandardMaterial3D):
				continue
			var std := base as StandardMaterial3D
			# Team colour bars, LEDs and any other authored emitter stay as-is.
			if std.emission_enabled:
				continue
			var improved := std.duplicate() as StandardMaterial3D
			var changed := _fill_missing_pbr(improved)
			changed = _improve_filtering(improved) or changed
			if changed:
				mesh_instance.set_surface_override_material(surface, improved)


## Fill in metallic/roughness when the source authored none.  The 24-sentry
## export writes every material as roughness 1.0 / metallic 0.0 with no
## metallic-roughness texture, which reads as flat plastic.
static func _fill_missing_pbr(std: StandardMaterial3D) -> bool:
	if std.roughness_texture != null or std.metallic_texture != null:
		return false
	if std.roughness < 0.999 or std.metallic > 0.001:
		return false
	var luminance := std.albedo_color.get_luminance()
	if luminance < 0.12:
		# Dark metal / anodised parts: a little shine, lower roughness.
		std.metallic = 0.35
		std.roughness = 0.48
	elif luminance < 0.45:
		# Painted metal panels.
		std.metallic = 0.15
		std.roughness = DEFAULT_ROUGHNESS
	else:
		# Bright plastics / painted fairings: keep metallic off.
		std.metallic = 0.0
		std.roughness = 0.62
	return true


## Anisotropic mipmapped filtering keeps the CAD surface detail stable at the
## grazing angles the 17.2 deg feed and the third-person view hit.
static func _improve_filtering(std: StandardMaterial3D) -> bool:
	if std.albedo_texture == null and std.metallic_texture == null \
			and std.roughness_texture == null and std.normal_texture == null:
		return false
	var wanted := BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if std.texture_filter == wanted:
		return false
	std.texture_filter = wanted
	return true


## All MeshInstance3D descendants (including the rig root itself).
static func _mesh_instances(root: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node := stack.pop_back() as Node
		if node == null:
			continue
		if node is MeshInstance3D:
			out.append(node as MeshInstance3D)
		for child in node.get_children():
			stack.append(child)
	return out
