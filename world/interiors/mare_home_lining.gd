extends RefCounted
## Authored interior linings. A house type whose design is listed in linings/approved.json gets
## its rebuilt room (linings/<design>_lining.scn, built in metres at the type's reference town
## scale) in every town instance. All eight designs are approved; the older room layers it
## replaces are retired here (house cleaning 2026-10-13).
const LININGS := "res://world/interiors/linings/"
## Town scale each lining was measured at (tools/interiors/export_house_contracts.gd).
const REFERENCE_SCALE := {
	"house_a": 9.67520140845228, "house_b": 9.89124237962852, "house_c": 9.50402333358744,
	"house_d": 10.1157696416576, "house_e": 12.0199721190309, "house_f": 12.0543678071654,
	"house_g": 11.5527961975297, "house_h": 11.8801764427189,
}
static var _approved: Dictionary = {}
## Review fixtures (tools/interiors/capture_linings.gd) install every built lining unapproved.
static var review_all := false
static var _loaded := false

static func install(home: Node3D) -> void:
	var house: Node3D = home.get_parent()
	if home.has_node("AuthoredLining"): return
	var design := house.scene_file_path.get_file().get_basename()
	if _is_approved(design): _install_type(home, design)

static func _is_approved(design: String) -> bool:
	if not _loaded:
		_loaded = true
		var path := LININGS + "approved.json"
		if FileAccess.file_exists(path):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed is Dictionary:
				for name: Variant in (parsed as Dictionary).get("approved", []): _approved[str(name)] = true
	return (review_all or _approved.has(design)) and REFERENCE_SCALE.has(design) and ResourceLoader.exists(LININGS + design + "_lining.scn")

static func _install_type(home: Node3D, design: String) -> void:
	var lining := (load(LININGS + design + "_lining.scn") as PackedScene).instantiate() as Node3D
	# Built in metres in the house root frame: under the root's own town scale, 1/reference
	# keeps each instance's small size difference. Set before add_child (Jolt keeps entry scale).
	var metres := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE / float(REFERENCE_SCALE[design])), Vector3.ZERO)
	lining.transform = home.transform.affine_inverse() * metres
	_mark_surfaces(lining)
	home.add_child(lining)
	# Past LINING_RANGE the windows show a glow card instead of the room.
	preload("res://world/buildings/window_glow/window_glow.gd").add_house(home.get_parent())
	var retire: Array = []
	var info := LININGS + design + "_lining.json"
	if FileAccess.file_exists(info):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(info))
		if parsed is Dictionary: retire = (parsed as Dictionary).get("hide", [])
	# Deferred once: HouseInterior._ready is still dressing the shell (room-face visibility,
	# floor material) and its parent is busy setting up children.
	Callable(_retire_legacy).call_deferred(home, retire)

## Every town house carries a lining (up to ~20k triangles, several 1-2k textures): performance
## pass 2026-10-13. The exterior shell casts the house's sun shadow; only lining walls and
## ceilings cast (inner partitions), and the lining stops drawing past LINING_RANGE. Beyond that
## the house shows no interior: world/buildings/window_glow/ puts a glow card on each window.
## Installed in _ready, so house_interior's door-shut interior range (Very Low tier) collects these
## meshes with the rest of the room and caps them nearer still.
const LINING_RANGE := 60.0
static func _mark_surfaces(lining: Node3D) -> void:
	for mesh: MeshInstance3D in lining.find_children("*", "MeshInstance3D", true, false):
		if str(mesh.name).begins_with("Architecture"):
			mesh.set_meta("interior_attachment_surface", true)
		# Walls and ceilings still cast: for several types the lining is the only inner wall or
		# floor above, and window sun must not leak through it. Paint, trim and decals cast none.
		var structural := str(mesh.name) in ["Architecture_Walls", "Architecture_Ceiling"] or str(mesh.name).contains("Wall") or str(mesh.name).contains("Ceiling")
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if structural else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = LINING_RANGE
		mesh.visibility_range_end_margin = 6.0
		mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

## The packed shell's old room layers that this lining replaces (linings/<design>_lining.json
## "hide": shell node paths with "/" written as "__", export_house_contracts.gd). Their drawing
## goes; collision stays: a piece with children (its collider) keeps its node and loses only its
## mesh, a bare piece is freed. Pieces HouseInterior no longer builds (floor underlay, skirting,
## wing frame) are simply absent.
static func _retire_legacy(home: Node3D, names: Array) -> void:
	if not is_instance_valid(home) or home.is_queued_for_deletion(): return
	var house := home.get_parent()
	for name: Variant in names:
		# The shell's ExteriorRoomFace also backs the thatch tufts and wall seams: retired, the
		# sky showed through holes from outside (dev 2026-10-14). The lining covers it indoors.
		if str(name).contains("ExteriorRoomFace"): continue
		var nodes: Array[Node] = []
		var exact := house.get_node_or_null(NodePath(str(name).replace("__", "/")))
		if exact != null: nodes.append(exact)
		else: nodes = house.find_children(str(name).get_slice("__", str(name).get_slice_count("__") - 1), "GeometryInstance3D", true, false)
		for node: Node in nodes:
			if node is MeshInstance3D and node.get_child_count() > 0: (node as MeshInstance3D).mesh = null
			elif node is GeometryInstance3D and node.get_child_count() > 0: (node as GeometryInstance3D).visible = false
			elif node is GeometryInstance3D:
				# Drop the mesh first: freed in the frame the house spawns, its own override
				# material died before the engine's first update of the instance, which then
				# read it ('Parameter "material" is null', ExteriorRoomFace).
				if node is MeshInstance3D: (node as MeshInstance3D).mesh = null
				node.queue_free()
