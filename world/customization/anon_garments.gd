extends RefCounted
## Anon's modular body (dev 2026-10-01): a neutral unclothed base with separate garments on the
## one accepted skeleton. The player avatar and the wardrobe mirror assemble the same parts.
##   Body: BodyTorso (bare torso and arms), BodyLegs (built legs), BodyFeet (bare feet), plus the
##   head and hands left in head_smd.
##   Garments: "top" = torso0_smd (jacket, shirt and tie are one mesh in the source model),
##   "trousers" = Trousers (split out of head_smd), "shoes" = feet0_smd.
## Meshes come from tools/anon/build_modular_body.gd; they share head_smd's Skin.
const DIR := "res://world/characters/anon/modular/"
const GARMENTS := ["top", "trousers", "shoes"]
const LABELS := {"top": "Jacket, shirt & tie", "trousers": "Trousers", "shoes": "Shoes"}
## Garment -> mesh nodes it shows when worn.
const SHOWS := {"top": ["torso0_smd"], "trousers": ["Trousers"], "shoes": ["feet0_smd"]}
## Body parts hidden while a garment is worn, so skin cannot poke through cloth. Bare feet sit
## inside the shoes and stay visible: the ankle above a shoe is the foot itself.
const COVERS := {"top": ["BodyTorso"], "trousers": ["BodyLegs"], "shoes": []}
const BODY := {"BodyTorso": "body_torso", "BodyLegs": "body_legs", "BodyFeet": "body_feet"}

## Idempotent. Returns the skeleton, or null for an actor without Anon's rig.
static func assemble(actor: Node) -> Skeleton3D:
	if actor == null: return null
	var skeleton := actor.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null: return null
	var head := skeleton.get_node_or_null("head_smd") as MeshInstance3D
	if head == null or skeleton.has_node("Trousers"): return skeleton
	var original: Material = head.get_surface_override_material(0)
	var trousers := _part(skeleton, "Trousers", load(DIR + "trousers.res"), head)
	trousers.set_surface_override_material(0, original)
	# Skin parts carry seam alpha (tools/anon/build_modular_body.gd): their outline thins to
	# nothing at the open neck, wrist, waist and ankle edges instead of drawing black rings.
	var skin_material: Material = original
	if original is ShaderMaterial and original.next_pass is ShaderMaterial:
		skin_material = original.duplicate()
		var outline: ShaderMaterial = original.next_pass.duplicate()
		outline.set_shader_parameter("width_from_vertex_alpha", true)
		skin_material.next_pass = outline
	head.mesh = load(DIR + "head_skin.res")
	head.set_surface_override_material(0, skin_material)
	for node_name: String in BODY:
		var part := _part(skeleton, node_name, load(DIR + BODY[node_name] + ".res"), head)
		part.set_surface_override_material(0, skin_material)
		part.visible = false
	return skeleton

static func _part(skeleton: Skeleton3D, node_name: String, mesh: Mesh, like: MeshInstance3D) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = node_name
	part.mesh = mesh
	part.skin = like.skin
	part.cast_shadow = like.cast_shadow
	part.layers = like.layers
	skeleton.add_child(part)
	part.skeleton = part.get_path_to(skeleton)
	return part

## worn: garment -> bool. Missing garments count as worn.
static func apply(actor: Node, worn: Dictionary) -> void:
	var skeleton := assemble(actor)
	if skeleton == null or not skeleton.has_node("Trousers"): return
	for garment: String in GARMENTS:
		var on: bool = bool(worn.get(garment, true))
		for node_name: String in SHOWS[garment]:
			var node := skeleton.get_node_or_null(node_name) as Node3D
			if node != null: node.visible = on
		for node_name: String in COVERS[garment]:
			var node := skeleton.get_node_or_null(node_name) as Node3D
			if node != null: node.visible = not on
	var feet := skeleton.get_node_or_null("BodyFeet") as Node3D
	if feet != null: feet.visible = true
