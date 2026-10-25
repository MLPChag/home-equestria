extends RefCounted
## Four fitted, skinned thigh highs; no rigid per-bone tubes or changes to pony collision.
const SHADER := preload("res://world/characters/accessories/thigh_highs/knit.gdshader")
const DIRECTORY := "res://world/characters/accessories/thigh_highs/"
static func material(colour: Color) -> ShaderMaterial:
	var result := ShaderMaterial.new()
	result.shader = SHADER
	result.set_shader_parameter("stripe_color", colour)
	return result
static func attach(pony: Node3D, colour: Color) -> MeshInstance3D:
	var body := pony.find_child("MareBody", true, false) as MeshInstance3D
	if body == null or body.skin == null: return null
	var old := body.get_parent().get_node_or_null("Wear_socks")
	if old != null:
		body.get_parent().remove_child(old)
		old.queue_free()
	var identity: Resource = pony.get("identity")
	var variant := "mare"
	if identity != null:
		if identity.get("stallion") == true: variant = "stallion"
		elif identity.get("filly") == true: variant = "filly"
	var node := MeshInstance3D.new()
	node.name = "Wear_socks"
	node.mesh = load(DIRECTORY + variant + ".res")
	node.skin = body.skin
	node.transform = body.transform
	node.material_override = material(colour)
	node.extra_cull_margin = 0.5
	body.get_parent().add_child(node)
	node.skeleton = node.get_path_to(pony.get("skeleton"))
	if pony.is_inside_tree():
		var form:Node=pony.get_tree().get_first_node_in_group("player_pony_form")
		if form!=null and form.get("avatar")==pony:form.refresh_body_visibility()
	return node
## Shop/hand representation: the same shaped front pair in its unposed rest shape.
static func display_pair(colour: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "StripedThighHighs"
	var source := load(DIRECTORY + "mare.res") as ArrayMesh
	var mesh := ArrayMesh.new()
	for surface in 2:
		var arrays := source.surface_get_arrays(surface)
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var item := MeshInstance3D.new()
	item.mesh = mesh
	item.material_override = material(colour)
	root.add_child(item)
	return root
