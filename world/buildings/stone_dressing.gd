extends RefCounted
## Stone dressing for the town's ramps, stoops and foundations (dev 2026-10-17: "replace all ramps
## with something a little more stylized... like theyre just untextured grey slabs"). Every ramp and
## foundation keeps its mesh and collider; its flat colour becomes cartoon flagstone, mapped in
## world space (these meshes have no UVs worth using), so stones run continuously across a ramp,
## its landing and the foundation under it. One shared material per kind and root. Applied once to
## the town at load (game_town_adapters.gd).
const TEXTURE := preload("res://world/buildings/stone/flagstone_albedo.png")
## A fixed shader (a generated triplanar StandardMaterial3D shader was freed out of order at quit).
const SHADER := preload("res://world/buildings/stone/flagstone.gdshader")
## Metres one texture tile covers: ramps and stoops a little finer than foundations.
const RAMP_TILE := 1.6
const FOUNDATION_TILE := 2.2

## The materials live on the dressed root (freed with it), not in static variables that would
## outlast the renderer at quit.
static func apply(root: Node) -> int:
	if "--no-stone-dressing" in preload("res://world/dev_tools.gd").user_args(): return 0   # A/B checks
	var materials := {"ramp": _make(RAMP_TILE, Color.WHITE), "foundation": _make(FOUNDATION_TILE, Color(0.93, 0.9, 0.86))}
	root.set_meta("stone_dressing", materials)
	var count := 0
	for node: Node in root.find_children("*", "MeshInstance3D", true, false):
		var kind := kind_of(String(node.name))
		if kind.is_empty(): continue
		(node as MeshInstance3D).material_override = materials[kind]
		count += 1
	return count

## "ramp", "foundation" or "" from a node name (house StoneRamp/StoopTread, plot and landmark
## foundations, landmark ramps, the barn approach).
static func kind_of(label: String) -> String:
	var low := label.to_lower()
	# A ramp's room face belongs to the house interior's own surfaces (left alone: overriding it
	# left dangling material references at quit).
	if low.contains("roomface"): return ""
	if low.begins_with("stoneramp") or low.begins_with("stooptread") or low.ends_with("_ramp") or low == "barnapproach" or low.begins_with("thresholdramp"): return "ramp"
	if low.begins_with("foundation") or low.ends_with("_foundation") or low.begins_with("fittedfoundation"): return "foundation"
	return ""

static func _make(tile: float, tint: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("albedo_texture", TEXTURE)
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("tile", tile)
	return m
