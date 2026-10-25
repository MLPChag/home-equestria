extends RefCounted
## The show look of pony_locomotion.gd (split 2026-10-13): cel shading and outline hulls, the
## eye surfaces modelled into the export and the old runtime eye attachment. The materials and
## exports stay on the pony, and so does the per-tick iris, lid and outline update
## (_update_eyes); these static functions build the look. Calls back into the pony
## (`_coat_ao`, `_shade_of`, `_dress_eye_surface`, ...) go through `pony.` so subclass overrides
## still apply.

const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const EYELIDS := preload("res://world/characters/locomotion/pony_eyelids.gd")
const CEL_BASE := preload("res://addons/cel-shader/cel-shader-base.gdshader")
const CEL_CUTOUT := preload("res://addons/cel-shader/cel-shader-cutout.gdshader")
## Same cel shader with its occlusion include on; the coat multiplies a baked
## AO map so creases (muzzle, cheek-to-neck, ear roots, leg joins) read as the
## show's shadow tone instead of one flat colour (dev, 2026-09-07).
const CEL_OCCLUSION := preload("res://addons/cel-shader/cel-shader-occlusion.gdshader")
## Coat albedo with a very broad, very subtle cool/warm variation baked over
## Native body texture (tools: PIL multiply, see THIRD_PARTY.md).
const BODY_ALBEDO_VARIED := preload("res://world/characters/rainbow_dash/marebody_albedo_varied.png")
const OUTLINE_TINTED := preload("res://addons/cel-shader/outline-tinted.gdshader")
## Lit hull: the show's line is a darker shade of the local colour and shades
## with it, so the outline is the cel shader on an inverted hull.
const OUTLINE_LIT := preload("res://addons/cel-shader/cel-outline-lit.gdshader")
## Numbered shading looks so dev can pick one by number (lab: --shading N, keys F1..F6).
## outline: "tinted" = flat unshaded #6BABDA hull dimmed by daylight; "lit" = cel hull as drawn
## (rim normal away from the viewer, reads near black by day); "lit_facing" = cel hull lit with
## the facing normal (dark blue by day, black at night). two_tone: shadow band = guide shade
## #8CC7E7 ratio. variation: BODY_ALBEDO_VARIED over the coat instead of flat #9BDBF5.
const SHADING_VERSIONS := {
	1: {"name": "tinted outline, textured coat, plain bands", "outline": "tinted", "two_tone": false, "variation": true},
	2: {"name": "lit outline as drawn, textured coat, plain bands", "outline": "lit", "two_tone": false, "variation": true},
	3: {"name": "lit facing outline, flat coat, guide shade", "outline": "lit_facing", "two_tone": true, "variation": false},
	4: {"name": "lit facing outline, flat coat, plain bands", "outline": "lit_facing", "two_tone": false, "variation": false},
	5: {"name": "tinted outline, flat coat, guide shade", "outline": "tinted", "two_tone": true, "variation": false},
	6: {"name": "lit facing outline, textured coat, guide shade", "outline": "lit_facing", "two_tone": true, "variation": true},
}
const EYES_SOURCE := "res://world/characters/rainbow_dash/rainbow_dash_native.glb"
# Round 6: the iris is drawn by a found procedural anime-eye shader (CC0,
# addons/godotshaders/anime_eyes.gdshader) over a planar UV: gradient iris,
# pupil, two view-offset shines and a parallax sink, so the eye reads as a
# floating 2.5D surface instead of a decal on the face. Colours sampled from
# Native iris texture (rainbow_dash_Eye_R.png): #520831 top, #A61C6B bottom.
const EYE_SHADER := preload("res://addons/godotshaders/anime_eyes.gdshader")
const IRIS_TOP := Color("520831")
const IRIS_BOTTOM := Color("A61C6B")
const IRIS_LINE := Color("3A0A24")


## Tear down and rebuild the eyes with the current exports (lab tool).
static func rebuild_eyes(pony: Node) -> void:
	var skeleton: Skeleton3D = pony.find_child("Skeleton3D", true, false)
	if skeleton == null:
		return
	var old: Node = skeleton.get_node_or_null("EyeMount")
	if old != null:
		skeleton.remove_child(old)
		old.free()
	var materials: Dictionary = pony._eye_materials
	materials.clear()
	var meshes: Array[MeshInstance3D] = pony._eye_meshes
	meshes.clear()
	pony.eyelids = EYELIDS.new()
	pony._attach_eyes(skeleton)


static func attach_eyes(pony: Node, skeleton: Skeleton3D) -> void:
	var packed: PackedScene = load(EYES_SOURCE)
	if packed == null:
		return
	var source := packed.instantiate()
	# Godot's importer turns the dots in Blender names into underscores.
	var wanted := {"Eye white_L": true, "Eye white_R": true, "Upper eyelid_L": true,
		"Upper eyelid_R": true, "Lash_L_0": true, "Lash_L_1": true, "Lash_R_0": true, "Lash_R_1": true}
	var lash := StandardMaterial3D.new()
	lash.albedo_color = Color(0.02, 0.02, 0.03)
	lash.roughness = 0.9
	# Rigid, in head-bone space: both exports share the same head rest, and
	# skinning the native copies onto the live rig left them a crumpled sliver.
	var head := skeleton.find_bone("pony_head")
	if head < 0:
		source.free()
		return
	var to_head := skeleton.get_bone_global_rest(head).affine_inverse()
	var mount := BoneAttachment3D.new()
	mount.name = "EyeMount"
	mount.bone_name = "pony_head"
	skeleton.add_child(mount)
	var materials: Dictionary = pony._eye_materials
	var meshes: Array[MeshInstance3D] = pony._eye_meshes
	var eye_scale: float = pony.eye_scale
	var eye_offset: Vector3 = pony.eye_offset
	var lashes := {"left": [], "right": []}
	var whites := {}
	for node in source.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not wanted.has(mi.name):
			continue
		var copy := MeshInstance3D.new()
		copy.name = mi.name
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var is_white := mi.name.begins_with("Eye white")
		var left := mi.name.ends_with("_L") or mi.name.begins_with("Lash_L")
		# The current body keeps the native closed eye bulges; the native whites sit
		# a hair beneath them, so grow whites and lids out along their normals
		# to sit on the bulge (lids a little further, above the white).
		copy.mesh = pony._rigid_in_head_space(mi.mesh, to_head, is_white, 0.006 if is_white else 0.0095, left)
		if is_white:
			var mat := ShaderMaterial.new()
			mat.shader = EYE_SHADER
			mat.set_shader_parameter("g_background_color", Color(0.94, 0.97, 1.0))
			mat.set_shader_parameter("g_iris_color_a", IRIS_TOP)
			mat.set_shader_parameter("g_iris_color_b", IRIS_BOTTOM)
			mat.set_shader_parameter("g_outline_color", IRIS_LINE)
			mat.set_shader_parameter("g_pupil_color", Color.BLACK)
			mat.set_shader_parameter("g_iris_shadow_color", Color(0.72, 0.72, 0.78))
			mat.set_shader_parameter("g_iris_shadow", Vector3(0.0, -0.22, 1.3))
			mat.set_shader_parameter("g_radius", pony.iris_radius)
			mat.set_shader_parameter("g_pupil_radius", minf(pony.pupil_radius * 1.2, 0.95))  # 20% bigger pupils (dev 2026-10-23)
			# Tall show iris: squeeze u so the circle reads as an upright ellipse.
			mat.set_shader_parameter("g_eye_scale", Vector2(1.3, 1.0))
			mat.set_shader_parameter("g_outline_radius", 0.02)
			mat.set_shader_parameter("g_specular_a", Vector3(-0.38, -0.36, 0.28))
			mat.set_shader_parameter("g_specular_b", Vector3(0.3, 0.32, 0.13))
			mat.set_shader_parameter("g_specular_view_offset_mult", Vector2(0.06, 0.03))
			mat.set_shader_parameter("g_specular_jitter", Vector2(0.0, 1.0))
			mat.set_shader_parameter("g_eye_movement_limits", Vector2(1.0, 1.0))
			copy.material_override = mat
			materials["left" if left else "right"] = mat
			meshes.append(copy)
			whites["left" if left else "right"] = copy
		else:
			copy.material_override = lash
			lashes["left" if left else "right"].append(copy)
		# Placement: scale about the eye's own centre, then nudge. eye_offset.x
		# is "outward": mirrored for her left eye.
		var center := copy.mesh.get_aabb().get_center()
		var nudge := Vector3(-eye_offset.x if left else eye_offset.x, eye_offset.y, eye_offset.z)
		copy.scale = Vector3.ONE * eye_scale
		copy.position = center * (1.0 - eye_scale) + to_head.basis * nudge
		mount.add_child(copy)
	source.free()
	var eyelids: RefCounted = pony.eyelids
	for side: String in ["left", "right"]:
		if whites.has(side):
			var white: MeshInstance3D = whites[side]
			var up_head: Vector3 = to_head.basis * Vector3.UP
			var height: float = absf(white.get_aabb().size.dot(up_head.abs())) * eye_scale
			eyelids.add_eye(mount, white, materials[side], lashes[side], up_head, height * pony.lash_travel)
	if "--debug-eyes" in preload("res://world/dev_tools.gd").user_args():
		pony._debug_eyes.call_deferred(mount)
	var lid_arg := preload("res://world/dev_tools.gd").user_args().find("--debug-lids")
	if lid_arg >= 0 and lid_arg + 1 < preload("res://world/dev_tools.gd").user_args().size():
		eyelids.closure = float(preload("res://world/dev_tools.gd").user_args()[lid_arg + 1])
		eyelids._apply()
		pony._lid_hold = true
	pony._update_eyes()


## Lab flags: --debug-lids <closure> holds the lids, --debug-gaze <yaw rad> holds the gaze.
static func read_eye_debug_args(pony: Node) -> void:
	var args := preload("res://world/dev_tools.gd").user_args()
	var i := args.find("--debug-lids")
	if i >= 0 and i + 1 < args.size():
		pony.eyelids.closure = float(args[i + 1])
		pony._lid_hold = true
	if "--debug-eyes" in args:
		pony._debug_eyes.call_deferred(pony)
	i = args.find("--hide")
	if i >= 0 and i + 1 < args.size():
		for node in pony.find_children("*", "MeshInstance3D", true, false):
			if String(node.name).begins_with(args[i + 1]):
				(node as MeshInstance3D).visible = false
	i = args.find("--debug-gaze")
	if i >= 0 and i + 1 < args.size():
		pony._debug_gaze = float(args[i + 1])


## Eye parts modelled into the export, recognised by material name. Returns
## true when the surface was handled here (no cel/outline for these).
static func dress_eye_surface(pony: Node, mi: MeshInstance3D, si: int, src: BaseMaterial3D) -> bool:
	var name := src.resource_name
	if name.begins_with("EyeCard"):
		var side := "left" if name.ends_with("_L") else "right"
		var mat := ShaderMaterial.new()
		mat.shader = EYE_SHADER
		mat.set_shader_parameter("g_background_color", Color(0.96, 0.98, 1.0))
		mat.set_shader_parameter("g_iris_color_a", IRIS_TOP)
		mat.set_shader_parameter("g_iris_color_b", IRIS_BOTTOM)
		mat.set_shader_parameter("g_outline_color", IRIS_LINE)
		mat.set_shader_parameter("g_pupil_color", Color.BLACK)
		mat.set_shader_parameter("g_iris_shadow_color", Color(0.78, 0.78, 0.84))
		mat.set_shader_parameter("g_iris_shadow", Vector3(0.0, -0.18, 1.25))
		# Reference: iris ~0.75 of the eye's height and ~0.45 of its width, pupil
		# ~0.6 of the iris; big shine top-left inside the pupil, small one low-right.
		mat.set_shader_parameter("g_radius", pony.iris_radius)
		mat.set_shader_parameter("g_pupil_radius", minf(pony.pupil_radius * 1.2, 0.95))  # 20% bigger pupils (dev 2026-10-23)
		mat.set_shader_parameter("g_eye_scale", Vector2(1.5, 1.0))
		mat.set_shader_parameter("g_outline_radius", 0.015)
		mat.set_shader_parameter("g_specular_a", Vector3(-0.3, -0.36, 0.34))
		mat.set_shader_parameter("g_specular_b", Vector3(0.32, 0.46, 0.11))
		mat.set_shader_parameter("g_specular_view_offset_mult", Vector2(0.05, 0.03))
		mat.set_shader_parameter("g_specular_jitter", Vector2(0.0, 1.0))
		mat.set_shader_parameter("g_iris_depth", 0.05)
		mat.set_shader_parameter("g_lid_color", EYELIDS.LID_COLOR)
		mat.set_shader_parameter("g_coat_color", Color("9BDBF5"))
		mat.set_shader_parameter("g_rim_line", 0.0)
		mat.set_shader_parameter("g_edge_softness", 0.004)
		mi.set_surface_override_material(si, mat)
		# The card is a 768-triangle fan; import-time LOD simplification chews
		# the pole into a ring of rim colour at the pupil centre. Full detail.
		mi.lod_bias = 100.0
		var materials: Dictionary = pony._eye_materials
		materials[side] = mat
		var meshes: Array[MeshInstance3D] = pony._eye_meshes
		if not meshes.has(mi):
			meshes.append(mi)
		return true
	if name.begins_with("EyeDome"):
		# Round 8b: the "window" is gone (dev); the card is glassy itself. Any
		# dome left in an older export is hidden.
		mi.visible = false
		return true
	if name.begins_with("EyeLash"):
		var lash := StandardMaterial3D.new()
		lash.albedo_color = Color(0.02, 0.02, 0.03)
		lash.roughness = 0.9
		lash.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.set_surface_override_material(si, lash)
		return true
	if name.begins_with("CoatLine"):
		# Drawn lines on the coat (nostrils): the outline colour, lit like the
		# coat so they darken in shadow and at night.
		# Two-sided: thin strokes come out of the export with unreliable winding.
		var line_mat := StandardMaterial3D.new()
		line_mat.albedo_color = Color("4A86BD")
		line_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		line_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		line_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.set_surface_override_material(si, line_mat)
		return true
	if name.begins_with("LidCoat"):
		# Geometry lids (round 9): skin over the eye, coat-coloured, cel shaded.
		# No outline hull on them: the hull scribbled dark bits over the socket
		# ring where the lid grids overlap the skin (dev: "wrinkles").
		var lid := ShaderMaterial.new()
		lid.shader = CEL_BASE
		lid.set_shader_parameter("color", Color("9BDBF5"))
		lid.set_shader_parameter("specular", Color(0.1, 0.1, 0.1, 0.1))
		lid.set_shader_parameter("fresnel", Color(0.1, 0.1, 0.1, 0.1))
		mi.set_surface_override_material(si, lid)
		return true
	if name.begins_with("EyeSocketWall"):
		# Two-sided: the wall ring's winding is not trustworthy after the export
		# repair, and a culled wall shows the head's inside (dev, round 8).
		var wall := StandardMaterial3D.new()
		wall.albedo_color = EYELIDS.LID_COLOR
		wall.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		wall.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		wall.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.set_surface_override_material(si, wall)
		return true
	return false


static func debug_eyes(pony: Node, mount: Node3D) -> void:
	if not await SHUTDOWN.frame(pony) or not await SHUTDOWN.frame(pony): return
	var nost: MeshInstance3D = pony.find_child("Nostrils", true, false)
	if nost != null:
		var aabb := nost.global_transform * nost.get_aabb()
		print("[eyes] nostrils aabb %s visible=%s material=%s" % [aabb, nost.is_visible_in_tree(), nost.get_active_material(0)])
	var meshes: Array[MeshInstance3D] = pony._eye_meshes
	for mi in meshes:
		print("[eyes] %s visible=%s global=%s aabb=%s mount_global=%s" % [mi.name, mi.is_visible_in_tree(),
			mi.global_position.snapped(Vector3.ONE * 0.01), mi.get_aabb(), mount.global_position.snapped(Vector3.ONE * 0.01)])


## Rest-space geometry moved into head-bone space, bones and weights dropped.
## Eye whites also get UV2 = planar projection across the surface's own rest
## bounds: u along the body (-Z forward), v down from the top, for the iris.
static func rigid_in_head_space(mesh: Mesh, to_head: Transform3D, with_uv2: bool, push: float = 0.0, mirror_u: bool = false) -> ArrayMesh:
	var out := ArrayMesh.new()
	var normal_basis := to_head.basis.inverse().transposed()
	for si in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var lo := Vector3.INF
		var hi := -Vector3.INF
		for v in verts:
			lo = lo.min(v)
			hi = hi.max(v)
		var span := (hi - lo).max(Vector3.ONE * 0.0001)
		var uv2 := PackedVector2Array()
		uv2.resize(verts.size())
		var moved := PackedVector3Array()
		moved.resize(verts.size())
		var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		for i in verts.size():
			# Both axes in units of the height span, so the texture keeps its
			# aspect on the eye instead of being squeezed to the white's width.
			var u := (hi.z - verts[i].z) / span.y
			# v runs down like a texture; the left eye's u is mirrored so both
			# irises slide the same way for one gaze.
			uv2[i] = Vector2(span.z / span.y - u if mirror_u else u, (hi.y - verts[i].y) / span.y)
			var v := verts[i]
			if push != 0.0 and i < source_normals.size():
				v += source_normals[i].normalized() * push
			moved[i] = to_head * v
		arrays[Mesh.ARRAY_VERTEX] = moved
		if arrays[Mesh.ARRAY_NORMAL] != null:
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var rotated := PackedVector3Array()
			rotated.resize(normals.size())
			for i in normals.size():
				rotated[i] = (normal_basis * normals[i]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = rotated
		arrays[Mesh.ARRAY_TANGENT] = null
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		if with_uv2:
			arrays[Mesh.ARRAY_TEX_UV] = uv2
			arrays[Mesh.ARRAY_TEX_UV2] = uv2
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


## Dress a model (or one MeshInstance3D) in the show cel look.
static func apply_show_shading(pony: Node, model: Node) -> void:
	pony._read_eye_debug_args()
	var preset: Dictionary = SHADING_VERSIONS.get(pony.shading_version, SHADING_VERSIONS[3])
	pony.coat_variation = preset.variation
	var coat_variation: bool = preset.variation
	var identity: Resource = pony.identity
	var outline_width: float = pony.outline_width
	var outlines: Array[ShaderMaterial] = pony._outline_materials
	var cache: Dictionary = {}
	var meshes: Array = [model] if model is MeshInstance3D else model.find_children("*", "MeshInstance3D", true, false)
	for node in meshes:
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var lower := mi.name.to_lower()
		if "cutie" in lower:
			continue  # textured decal with an alpha border; keep as exported
		var line: Color = pony.mane_line() if ("mane" in lower or "tail" in lower) else pony.coat_line()
		for si in mi.mesh.get_surface_count():
			# Remember the export's material so a later re-dress (set_shading_version) starts
			# from the same source instead of the cel material it already wears.
			var memo := "source_material_%d" % si
			var src: BaseMaterial3D = mi.get_meta(memo) if mi.has_meta(memo) else mi.get_active_material(si) as BaseMaterial3D
			if src == null:
				continue
			if not mi.has_meta(memo):
				mi.set_meta(memo, src)
			if pony._dress_eye_surface(mi, si, src):
				continue
			var ao: Texture2D = pony._coat_ao(mi)
			# Meshes sharing a source material still get their own occlusion map (wings vs body).
			var wing_coat := mi.name.begins_with("wing folded") or mi.name == "OpenPonyDock"
			var flat_coat := wing_coat or (mi.name.begins_with("MareBody") and not coat_variation)
			var key := "%s|%s|%s|%s|%s" % [src.get_rid(), line.to_html(false), ao.resource_path if ao != null else "", flat_coat,
				identity.id if identity != null else ""]
			var mat: ShaderMaterial = cache.get(key)
			if mat == null:
				mat = ShaderMaterial.new()
				mat.shader = CEL_CUTOUT if src.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR else CEL_BASE
				if ao != null and mat.shader == CEL_BASE:
					mat.shader = CEL_OCCLUSION
					mat.set_shader_parameter("ao_map", ao)
					mat.set_shader_parameter("ao_light_affect", pony.ao_light_affect)
				mat.set_shader_parameter("color", src.albedo_color)
				# Flat show hex on the coat: leave the sampler untouched (its default is white;
				# assigning null samples black) instead of the export's texture.
				if src.albedo_texture != null and not flat_coat:
					mat.set_shader_parameter("base_texture", src.albedo_texture)
				if mi.name.begins_with("MareBody") or wing_coat:
					if coat_variation and not wing_coat:
						mat.set_shader_parameter("base_texture", BODY_ALBEDO_VARIED)
					else:
						mat.set_shader_parameter("color", pony.coat_fill())
				var fill: Color = mat.get_shader_parameter("color")
				if preset.two_tone:
					mat.set_shader_parameter("shadow_color", pony._shade_of(fill))
				mat.set_shader_parameter("specular", Color(0.1, 0.1, 0.1, 0.1))
				mat.set_shader_parameter("fresnel", Color(0.1, 0.1, 0.1, 0.1))
				if mat.shader == CEL_CUTOUT:
					mat.set_shader_parameter("alpha_cutoff", src.alpha_scissor_threshold)
				# The show's line is the guide's exact hex (coat #6BABDA, mane/tail #1B98D1) and
				# it must go black with the light (dev, 2026-09-08): the lit hull, whose rim normal
				# is flipped to face the viewer so the line sits in the coat's own band, with the
				# same guide shade ratio in shadow. The unshaded tinted hull stayed visible in the dark.
				var outline := ShaderMaterial.new()
				if preset.outline == "tinted":
					outline.shader = OUTLINE_TINTED
					outline.set_shader_parameter("outline_color", line)
					outline.set_shader_parameter("outline_width", outline_width)
					outlines.append(outline)
				else:
					outline.shader = OUTLINE_LIT
					outline.set_shader_parameter("color", line)
					if preset.two_tone:
						outline.set_shader_parameter("shadow_color", pony._shade_of(line))
					outline.set_shader_parameter("face_viewer", preset.outline == "lit_facing")
					outline.set_shader_parameter("outline_width", outline_width)
					outline.set_shader_parameter("specular", Color(0.0, 0.0, 0.0, 0.0))
					outline.set_shader_parameter("fresnel", Color(0.0, 0.0, 0.0, 0.0))
				mat.next_pass = outline
				cache[key] = mat
			mi.set_surface_override_material(si, mat)
