class_name ZoneProcessor
extends RefCounted
## Makes a raw zone export usable.
##
## The source project drove its maps with runtime scene logic that decided which seasonal and
## event variants were visible. That logic was IL2CPP and exported as empty
## stubs, so a raw import shows *every* variant at once -- the winter river
## stacked on the normal one, a 10 km flood plane, a storm dome around the
## camera, debug world-bounds geometry. This prunes back to one coherent state
## and attaches collision.
##
## Runs at load rather than as a bake step: the prune list is tuning data that
## changes often, and a bake would mean re-emitting ~150 MB of geometry per edit
## for no runtime gain.

const NIGHT_LIGHT_GROUP := "night_lights"
const CEL_SHADER := "res://addons/cel-shader/cel-shader-base.gdshader"
const CEL_CUTOUT_SHADER := "res://addons/cel-shader/cel-shader-cutout.gdshader"
const TOON_WATER_SHADER := "res://addons/godotshaders/toon_water.gdshader"
const VEGETATION_SCALE := preload("res://world/foliage/vegetation_scale.gd")
const TERRAIN_OWNERSHIP := preload("res://world/terrain/terrain_ownership.gd")

## Matching is by suffix of the node path relative to the zone root, so
## "Weather/Flood" matches ".../SceneManager/Weather/Flood" and everything under it.
static func process(root: Node, config: Dictionary) -> Dictionary:
	var stats := {"pruned": 0, "lod_removed": 0, "hidden": 0, "collided": 0, "shadow_off": 0}
	stats["omitted_visuals"] = preload("res://world/zone_visual_filter.gd").apply(root, config.get("omit_materials", []))

	var prune: Array = config.get("prune", [])
	var hide: Array = config.get("hide", [])
	var hide_materials: Array = config.get("hide_materials", [])
	var collide: Array = config.get("collide", [])
	var no_shadow: Array = config.get("no_shadow", [])

	# Collect first, mutate after -- editing the tree mid-walk drops siblings.
	var all: Array = []
	_collect(root, "", all)

	for entry in all:
		var node: Node = entry[0]
		var path: String = entry[1]
		if not is_instance_valid(node):
			continue
		if _matches(path, prune):
			node.get_parent().remove_child(node)
			node.queue_free()
			stats["pruned"] += 1

	all.clear()
	_collect(root, "", all)
	# Unity's exported LOD variants have no Godot visibility controller. Keep
	# the full-detail sibling once, rather than render/collide all levels at once.
	# This is opt-in per zone and never removes an orphan or a node with children.
	for entry in all:
		var node: Node = entry[0]
		if _matches(entry[1], config.get("select_exported_lods", [])) and _has_lod_replacement(node):
			node.get_parent().remove_child(node)
			node.queue_free()
			stats["lod_removed"] += 1
	if stats["lod_removed"] > 0:
		all.clear()
		_collect(root, "", all)
	if bool(config.get("vegetation_scale", false)) and not VEGETATION_SCALE.source_scale_requested():
		stats["vegetation_scaled"] = _apply_vegetation_scale(all)
		var ownership := TERRAIN_OWNERSHIP.prune_foreign_owned_plants(root as Node3D, config)
		stats["foreign_terrain_plants_removed"] = ownership.removed
		stats["foreign_terrain_landmarks_kept"] = ownership.landmarks
		all.clear()
		_collect(root, "", all)

	for entry in all:
		var node: Node = entry[0]
		var path: String = entry[1]
		if not is_instance_valid(node) or not node is VisualInstance3D:
			continue
		var vis := node as VisualInstance3D

		if _matches(path, hide):
			vis.visible = false
			stats["hidden"] += 1
		elif node is MeshInstance3D and _material_matches(node as MeshInstance3D, hide_materials):
			vis.visible = false
			stats["hidden"] += 1

		if _matches(path, no_shadow) and node is GeometryInstance3D:
			(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			stats["shadow_off"] += 1

	# Collision is added after pruning so removed variants never contribute, and
	# it deliberately includes hidden geometry: the world-bounds walls are
	# invisible but must still block the player.
	for entry in all:
		var node: Node = entry[0]
		var path: String = entry[1]
		if not is_instance_valid(node) or not node is MeshInstance3D:
			continue
		if not _matches(path, collide):
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		_add_trimesh_collision(mi, root)
		stats["collided"] += 1

	# Look: the CC0 toon water on the river, and eldskald's cel shader on every
	# Keep the physical water tag even when a quality preset skips its shader.
	for entry in all:
		if entry[0] is MeshInstance3D and _matches(entry[1],config.get("toon_water",[])):
			entry[0].add_to_group("navigation_water")
	# Look: the CC0 toon water on the river, and eldskald's cel shader on every
	# opaque or alpha-cut surface so the town shades in the same bands as the
	# ponies. Alpha-blended and double-sided materials keep their originals;
	# the cel base shader is single-sided and opaque.
	# The first headset session reported poor frame time. These look overrides
	# remain desktop-only pending stereo measurements; surface count alone does
	# not identify shader cost or prove pipeline-compilation stalls.
	var in_xr: bool = Engine.get_main_loop().root.get_node_or_null("Quality") != null \
			and bool(Engine.get_main_loop().root.get_node("Quality").get("xr_mode"))
	var look_allowed := not in_xr or bool(config.get("look_in_xr", false))
	# A process-local diagnostic; never edit zone.json for an A/B measurement.
	var args := preload("res://world/dev_tools.gd").user_args()
	look_allowed = look_allowed or ("--perf-stereo" in args and "--profile-look" in args)
	stats["water"] = _apply_toon_water(all, config.get("toon_water", [])) if look_allowed else 0
	# Cel bands are cheap surface shading and can be switched on for the
	# headset separately from the water's per-eye screen copy (dev,
	# 2026-09-06 evening: "add back light cel shading on everything").
	# Headset cel bands (dev, 2026-09-06 evening: "add back light cel shading
	# on everything"). The eldskald pass measured free in the desktop proxy on
	# an idle GPU (7.7 vs 7.1 ms; an earlier 27 ms reading was a headset game
	# sharing the GPU). `cel_in_xr: "builtin"` swaps in Godot's own toon
	# diffuse on material copies instead; `--profile-no-cel` turns both off
	# for an A/B run.
	var cel_setting: Variant = config.get("cel_in_xr", false)
	var cel_in_xr := bool(cel_setting) and not ("--perf-stereo" in args and "--profile-no-cel" in args)
	var cel_on := bool(config.get("cel_shade", false))
	if in_xr and not look_allowed and cel_in_xr and cel_on:
		if str(cel_setting) == "builtin":
			stats["cel_shaded"] = _apply_builtin_toon(all, config)
		else:
			stats["cel_shaded"] = _apply_cel_shading(all, config)
	else:
		stats["cel_shaded"] = _apply_cel_shading(all, config) if look_allowed and cel_on else 0
	stats["lamps"] = _add_night_lights(root, config.get("night_lights", {}))
	stats["mountain_rock"] = preload("res://world/terrain/mountain_materials.gd").apply(root, config)
	return stats


static func _apply_vegetation_scale(all: Array) -> int:
	var scaled := 0
	for entry in all:
		var node: Node = entry[0]
		if not node is Node3D: continue
		var name := str(node.name).to_lower()
		if name.contains("_") or name.contains("lod"): continue
		if _has_vegetation_ancestor(node): continue
		var category := "tree" if name.begins_with("everfreetree") or name.begins_with("tree0") else ""
		var plant := name.begins_with("everfreebush") or name.begins_with("bush") or name.begins_with("fern") or name.begins_with("brambles") or name.contains("thorn")
		if category.is_empty() and not plant: continue
		# The full path retains landmark ownership when the visible child itself has
		# a generic exported name such as EverfreeTree04.
		if VEGETATION_SCALE.apply_native(node as Node3D, category, str(entry[1])) < 0.999:
			scaled += 1
	return scaled


static func _has_vegetation_ancestor(node: Node) -> bool:
	var parent := node.get_parent()
	while parent != null:
		var name := str(parent.name).to_lower()
		if name.begins_with("everfreetree") or name.begins_with("tree0") or name.begins_with("everfreebush") or name.begins_with("bush") or name.begins_with("fern") or name.begins_with("brambles") or name.contains("thorn"):
			return true
		parent = parent.get_parent()
	return false


static func _apply_toon_water(all: Array, patterns: Array) -> int:
	if patterns.is_empty():
		return 0
	var shader: Shader = load(TOON_WATER_SHADER)
	var material := ShaderMaterial.new()
	material.shader = shader
	# A river, not the open sea: small ripples, dense pattern, soft foam.
	material.set_shader_parameter("wave_amplitude", 0.03)
	material.set_shader_parameter("wave_frequency", 0.9)
	material.set_shader_parameter("tile", Vector2(18.0, 18.0))
	material.set_shader_parameter("distortion_speed", 1.2)
	material.set_shader_parameter("water_transparency", 0.75)
	material.set_shader_parameter("water_depth_factor", 0.35)
	material.set_shader_parameter("foam_width", 0.35)
	var count := 0
	for entry in all:
		var node: Node = entry[0]
		if not is_instance_valid(node) or not node is MeshInstance3D or not _matches(entry[1], patterns):
			continue
		(node as MeshInstance3D).material_override = material
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		count += 1
	return count


## Built-in toon lighting on copies of the town's BaseMaterial3Ds; same skip
## rules as the shader pass, one copy per source material.
static func _apply_builtin_toon(all: Array, config: Dictionary) -> int:
	var skip: Array = config.get("cel_shade_skip", [])
	var cache: Dictionary = {}
	var count := 0
	for entry in all:
		var node: Node = entry[0]
		if not is_instance_valid(node) or not node is MeshInstance3D or _matches(entry[1], skip):
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.material_override != null or not mi.visible:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s)
			if not src is BaseMaterial3D:
				continue
			var b := src as BaseMaterial3D
			if b.cull_mode != BaseMaterial3D.CULL_BACK or b.emission_enabled:
				continue
			var key := b.get_rid()
			var mat: BaseMaterial3D = cache.get(key)
			if mat == null:
				mat = b.duplicate() as BaseMaterial3D
				mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
				mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				cache[key] = mat
			mi.set_surface_override_material(s, mat)
			count += 1
	return count


static func _apply_cel_shading(all: Array, config: Dictionary) -> int:
	var skip: Array = config.get("cel_shade_skip", [])
	var base: Shader = load(CEL_SHADER)
	var cutout: Shader = load(CEL_CUTOUT_SHADER)
	var cache: Dictionary = {}
	var count := 0
	for entry in all:
		var node: Node = entry[0]
		if not is_instance_valid(node) or not node is MeshInstance3D or _matches(entry[1], skip):
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.material_override != null or not mi.visible:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s)
			if not src is BaseMaterial3D:
				continue
			var b := src as BaseMaterial3D
			if b.cull_mode != BaseMaterial3D.CULL_BACK or b.emission_enabled:
				continue
			var shader: Shader
			if b.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
				shader = base
			elif b.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
				shader = cutout
			else:
				continue
			var key := b.get_rid()
			var mat: ShaderMaterial = cache.get(key)
			if mat == null:
				mat = ShaderMaterial.new()
				mat.shader = shader
				mat.resource_name = b.resource_name
				mat.set_shader_parameter("color", b.albedo_color)
				if b.albedo_texture != null:
					mat.set_shader_parameter("base_texture", b.albedo_texture)
				mat.set_shader_parameter("uv_scale", Vector2(b.uv1_scale.x, b.uv1_scale.y))
				mat.set_shader_parameter("uv_offset", Vector2(b.uv1_offset.x, b.uv1_offset.y))
				mat.set_shader_parameter("specular", Color(0.12, 0.12, 0.12, 0.15))
				mat.set_shader_parameter("fresnel", Color(0.10, 0.10, 0.10, 0.12))
				if shader == cutout:
					mat.set_shader_parameter("alpha_cutoff", b.alpha_scissor_threshold)
				cache[key] = mat
			mi.set_surface_override_material(s, mat)
			count += 1
	return count


static func _has_lod_replacement(node: Node) -> bool:
	if not node is MeshInstance3D or node.mesh == null or node.get_child_count() != 0:
		return false
	var name := str(node.name)
	var base := ""
	var original_base := ""
	# Godot appends a number to globally repeated glTF names: e.g.
	# Dynamic LOD 12 -> Dynamic LOD 02, Tree_LOD219 -> Tree19.
	if name.begins_with("Dynamic LOD 1"):
		var suffix := name.trim_prefix("Dynamic LOD 1")
		if not suffix.is_empty() and not suffix.is_valid_int():return false
		base = "Dynamic LOD 0" + suffix
	elif name.contains("_LOD"):
		var split := name.rfind("_LOD")
		var level := name.substr(split + 4)
		if level.is_empty() or not level.is_valid_int() or level[0] not in ["1", "2"]:return false
		original_base = name.left(split).strip_edges()
		base = original_base + level.substr(1)
	else:
		return false
	var fallback_matches := 0
	for sibling in node.get_parent().get_children():
		if sibling == node or not sibling is MeshInstance3D or sibling.mesh == null:
			continue
		if sibling.mesh.get_surface_count() == 0:
			continue
		# The export rounds equivalent LOD scales slightly differently.
		var a: Transform3D = node.transform
		var b: Transform3D = sibling.transform
		if a.origin.distance_to(b.origin) < 0.0001 and a.basis.x.distance_to(b.basis.x) < 0.0001 and a.basis.y.distance_to(b.basis.y) < 0.0001 and a.basis.z.distance_to(b.basis.z) < 0.0001:
			var sibling_name := str(sibling.name).strip_edges()
			if sibling_name == base:return true
			# Name collisions can offset the counters (Tree32 vs Tree3_LOD1).
			# Accept only an unambiguous sibling with the same actual materials.
			if not original_base.is_empty() and sibling_name.begins_with(original_base):
				var suffix := sibling_name.trim_prefix(original_base)
				if suffix.is_valid_int() and _same_materials(node, sibling):
					fallback_matches += 1
	return fallback_matches == 1


static func _same_materials(a: MeshInstance3D, b: MeshInstance3D) -> bool:
	var first := {}
	var second := {}
	for i in a.mesh.get_surface_count():
		var material := a.get_active_material(i)
		if material != null:first[material] = true
	for i in b.mesh.get_surface_count():
		var material := b.get_active_material(i)
		if material != null:second[material] = true
	return not first.is_empty() and first == second


## Ponyville ships 98 lamp posts and 35 candle lanterns as ordinary props with no
## lights attached -- the source project lit them some other way. Attaching an omni light to
## each is the cheapest possible route to a village that reads as inhabited
## after dark, which is most of what "cozy" means here.
##
## Shadows are off: 130 shadow-casting lights would be ruinous, and a lamp's
## value is the pool of warm light under it, not the shadows it casts.
static func _add_night_lights(root: Node, cfg: Dictionary) -> int:
	var patterns: Array = cfg.get("match", [])
	if patterns.is_empty():
		return 0

	var color := Color(1.0, 0.76, 0.45)
	var c: Array = cfg.get("color", [])
	if c.size() >= 3:
		color = Color(float(c[0]), float(c[1]), float(c[2]))

	var energy: float = float(cfg.get("energy", 3.0))
	var light_range: float = float(cfg.get("range", 9.0))
	var height: float = float(cfg.get("height", 1.4))

	var made := 0
	var all: Array = []
	_collect(root, "", all)
	for entry in all:
		var node: Node = entry[0]
		if not (node is Node3D):
			continue
		var name := str(node.name)
		var matched := false
		for p in patterns:
			if name.begins_with(str(p)):
				matched = true
				break
		if not matched:
			continue
		var light := OmniLight3D.new()
		light.light_cull_mask &= ~(1<<16) # House interiors use their own light sources.
		light.light_color = color
		light.light_energy = 0.0
		light.omni_range = light_range
		light.shadow_enabled = false
		# World up, not the node's local Y: 107 lamp nodes carry a -90 deg X
		# rotation from import, which put their lights 1.6 m sideways on the
		# ground (dev, round 5: "the lamp lights are in the wrong places").
		# Nodes with a mesh get the light at the top of that mesh instead.
		light.position = _lantern_position(node as Node3D, root, height)
		light.add_to_group(NIGHT_LIGHT_GROUP)
		light.set_meta("night_energy", energy)
		(node as Node3D).add_child(light)
		if "--debug-lights" in preload("res://world/dev_tools.gd").user_args() and made < 8:
			print("[lights] %s (%s) light local %s" % [node.name, node.get_class(), light.position.snapped(Vector3.ONE * 0.01)])
		made += 1
	return made


## The node's basis expressed in the zone root's frame (root itself excluded).
## MeshInstance3D.create_trimesh_collision with two departures, both because Jolt cooks every
## trimesh on the main thread when the body enters the tree (ZoneManager attaches bodies a
## few ms per frame, so one shape must stay small):
## - meshes above _SPLIT_ABOVE_TRIS (Unity "Dynamic LOD" batches of 50-90k tris cook in
##   25-40 ms) become several bodies, split along the longest axis into ~_SPLIT_TARGET_TRIS
##   chunks;
## - props authored in millimetres under a node scale of 80-500 (Canterlot petals and ropes,
##   Appleloosa kitchenware) get the scale baked into the shape data and an inverse-scaled
##   body, because Jolt validates the *unscaled* triangles and rejects them as degenerate
##   ("Need triangles to create a mesh shape!"). Uniform scale is exact; these cases are.
const _RESCALE_ABOVE := 4.0
const _SPLIT_ABOVE_TRIS := 16000
const _SPLIT_TARGET_TRIS := 10000
static func _add_trimesh_collision(mi: MeshInstance3D, root: Node) -> void:
	var s := _basis_to_root(mi, root).get_scale()
	var rescale := maxf(s.x, maxf(s.y, s.z)) > _RESCALE_ABOVE and minf(s.x, minf(s.y, s.z)) > 0.0
	var faces := mi.mesh.get_faces()
	if not rescale and faces.size() / 3 <= _SPLIT_ABOVE_TRIS:
		mi.create_trimesh_collision()
		return
	if rescale:
		for i in faces.size():
			faces[i] = faces[i] * s
	var chunks := _split_faces(faces)
	for i in chunks.size():
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(chunks[i])
		var col := CollisionShape3D.new()
		col.shape = shape
		var body := StaticBody3D.new()
		body.name = mi.name + "_col" + ("" if chunks.size() == 1 else str(i + 1))
		if rescale:
			body.basis = Basis.IDENTITY.scaled(Vector3.ONE / s)
		body.add_child(col)
		mi.add_child(body)


static func _split_faces(faces: PackedVector3Array) -> Array[PackedVector3Array]:
	var tris := faces.size() / 3
	if tris <= _SPLIT_ABOVE_TRIS:
		return [faces]
	var parts := int(ceil(float(tris) / float(_SPLIT_TARGET_TRIS)))
	var lo := faces[0]
	var hi := faces[0]
	var keys: Array = []
	keys.resize(tris)
	for t in tris:
		var c := (faces[t * 3] + faces[t * 3 + 1] + faces[t * 3 + 2]) / 3.0
		keys[t] = c
		lo = lo.min(c)
		hi = hi.max(c)
	var axis := (hi - lo).max_axis_index()
	var order: Array = []
	order.resize(tris)
	for t in tris:
		order[t] = [float(keys[t][axis]), t]
	order.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array[PackedVector3Array] = []
	var per := int(ceil(float(tris) / float(parts)))
	for p in parts:
		var chunk := PackedVector3Array()
		for k in range(p * per, mini(tris, (p + 1) * per)):
			var t: int = order[k][1]
			chunk.append(faces[t * 3])
			chunk.append(faces[t * 3 + 1])
			chunk.append(faces[t * 3 + 2])
		if not chunk.is_empty():
			out.append(chunk)
	return out


static func _basis_to_root(node: Node, root: Node) -> Basis:
	var b := Basis.IDENTITY
	var n := node
	while n != null and n != root:
		if n is Node3D:
			b = (n as Node3D).basis * b
		n = n.get_parent()
	return b


## Light position in the matched node's local frame: `height` straight up in
## world terms for bare markers; 0.25 m under the mesh top for lamps with a
## mesh (the node itself or its first MeshInstance3D child).
static func _lantern_position(node: Node3D, root: Node, height: float) -> Vector3:
	var up_local := (_basis_to_root(node, root).inverse() * Vector3.UP).normalized()
	var mi: MeshInstance3D = node as MeshInstance3D
	if mi == null:
		for child in node.get_children():
			if child is MeshInstance3D:
				mi = child
				break
	if mi == null or mi.mesh == null:
		return up_local * height
	var aabb := mi.get_aabb()
	var to_node := Transform3D.IDENTITY if mi == node else mi.transform
	var center := to_node * aabb.get_center()
	var up_in_mesh := (to_node.basis.inverse() * up_local).normalized()
	var half := aabb.size * 0.5
	var extent := absf(up_in_mesh.x) * half.x + absf(up_in_mesh.y) * half.y + absf(up_in_mesh.z) * half.z
	return center + up_local * maxf(extent - 0.25, 0.2)


static func load_config(zone_dir: String) -> Dictionary:
	var path := zone_dir.path_join("zone.json")
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func _collect(node: Node, prefix: String, out: Array) -> void:
	for child in node.get_children():
		var path := prefix + "/" + str(child.name) if prefix != "" else str(child.name)
		out.append([child, path])
		_collect(child, path, out)


static func _matches(path: String, patterns: Array) -> bool:
	for p in patterns:
		var pat := str(p)
		if path == pat or path.ends_with("/" + pat) or path.contains("/" + pat + "/") or path.begins_with(pat + "/"):
			return true
	return false


static func _material_matches(mi: MeshInstance3D, names: Array) -> bool:
	if names.is_empty():
		return false
	for s in mi.mesh.get_surface_count():
		var mat := mi.get_active_material(s)
		if mat == null:
			continue
		var n := mat.resource_name
		for want in names:
			if n == str(want):
				return true
	return false
