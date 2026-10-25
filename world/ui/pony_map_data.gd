extends RefCounted
## Map observations only; never instantiate a pony or load terrain for a marker.
const ICON_INDEX := "res://world/ui/pony_map_icons.json"
const ICON_ATLAS := "res://world/ui/pony_map_icons.png"
static var icons: Dictionary = {}
static var atlas: Texture2D
## Kept for tools/test_pony_map_markers.gd: nothing outside the live roster is sampled.
var refreshes := 0

static func load_icons() -> void:
	if not icons.is_empty(): return
	if not FileAccess.file_exists(ICON_INDEX): return
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(ICON_INDEX))
	if not document is Dictionary: return
	icons = document.get("icons", {})
	var image: Image = preload("res://world/resource_image.gd").read(ICON_ATLAS)
	if image != null: atlas = ImageTexture.create_from_image(image)

static func appearance(id: String, identity: Resource = null) -> Dictionary:
	load_icons()
	var icon: Dictionary = icons.get(id, {})
	var color: Array = icon.get("coat", [.6,.7,.8,1.0])
	return {"name": identity.display_name if identity != null else str(icon.get("name",id.replace("_"," ").capitalize())),
		"coat": identity.coat_fill if identity != null else Color(color[0],color[1],color[2],1), "icon_id":id}

func sample(reference: Node3D, _force := false) -> Array:
	if not is_instance_valid(reference) or not reference.is_inside_tree(): return []
	var tree := reference.get_tree()
	var space := reference.get_world_3d()
	var markers: Array = []
	var live_ids := {}
	for actor in tree.get_nodes_in_group("sim_ponies"):
		if not actor is Node3D or actor.is_queued_for_deletion() or actor.get_world_3d()!=space: continue
		if not "identity" in actor or actor.identity==null: continue
		var id: String=actor.identity.id
		var row:=appearance(id,actor.identity)
		var key: String="pony:"+id
		if live_ids.has(id): key+="@"+str(actor.get_instance_id())
		row.merge({"id":key,"kind":"pony","position":Vector2(actor.global_position.x,actor.global_position.z),"tracking":"Live"})
		markers.append(row); live_ids[id]=true
	# Only ponies actually out in the world (dev 2026-09-23: "ponies that literally are not
	# there when I open the map"). Unloaded residents' simulated or saved spots are not shown.
	return markers
