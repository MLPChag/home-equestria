extends RefCounted
## furnish style extracted from interior_furnisher.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.

const PROP_DIR := "res://world/props/household/"
const FURNITURE_SHADER := preload("res://world/interiors/furniture.gdshader")


static func _pick_style(context: RefCounted) -> void:
	var names: Array = (context._kit as Dictionary).styles.keys()
	names.sort()
	var total := 0.0
	for n in names: total += float((context._kit as Dictionary).styles[n].get("weight", 1.0))
	var roll := (context.rng as RandomNumberGenerator).randf() * total
	context.style_name = names[-1]
	for n in names:
		roll -= float((context._kit as Dictionary).styles[n].get("weight", 1.0))
		if roll <= 0.0: context.style_name = n; break
	context.style = (context._kit as Dictionary).styles[(context.style_name as String)]
	var finishes: Array = (context.style as Dictionary).get("finishes", ["honey oak"])
	context.finish_name = finishes[(context.rng as RandomNumberGenerator).randi_range(0, finishes.size() - 1)]
	context.finish = (context._kit as Dictionary).finishes.get((context.finish_name as String), {"keep": true})
	var palettes: Array = (context.style as Dictionary).get("palettes", [])
	if not palettes.is_empty():
		context.palette_name = palettes[(context.rng as RandomNumberGenerator).randi_range(0, palettes.size() - 1)]
		context.palette = (context._kit as Dictionary).palettes.get((context.palette_name as String), {})

static func _chance(context: RefCounted, id: String, step: Dictionary) -> float:
	return clampf(float(step.get("chance", 1.0)) * float((context.style as Dictionary).get("chance", {}).get(id, 1.0)), 0.0, 1.0)

static func _fabric_colour(context: RefCounted, model: String) -> Color:
	var accent := Color.html((context.palette as Dictionary).get("fabric", "98b08b"))
	var linen := (context._linen_colour() as Color)
	match model:
		"sofa", "footstool": return linen.darkened(.18)
		"curtains": return linen.lerp(accent,.18)
		"armchair", "chaise-longue": return accent.lerp(linen,.28)
	return accent

static func _linen_colour(context: RefCounted) -> Color:
	# Keep sheets and large neutral surfaces light, including mustard/blush palettes.
	return Color("eee5d5").lerp(Color.html((context.palette as Dictionary).get("linen","eee5d5")),.25)

static func _material(context: RefCounted, model: String, source: Material) -> Material:
	var key := "%s|%s|%s" % [model, (context.finish_name as String), (context.palette_name as String)]
	if (context._materials as Dictionary).has(key): return (context._materials as Dictionary)[key]
	var base := source as StandardMaterial3D
	var mask_path := PROP_DIR + model + "_mask.png"
	if base == null or base.albedo_texture == null or not ResourceLoader.exists(mask_path): return source
	var m := ShaderMaterial.new()
	m.shader = FURNITURE_SHADER
	m.set_shader_parameter("albedo_tex", base.albedo_texture)
	m.set_shader_parameter("mr_tex", base.roughness_texture if base.roughness_texture != null else base.metallic_texture)
	m.set_shader_parameter("mask_tex", load(mask_path))
	if not (context.finish as Dictionary).get("keep", false) and (context.finish as Dictionary).has("color"):
		m.set_shader_parameter("wood_color", Color.html((context.finish as Dictionary).color))
		m.set_shader_parameter("wood_mix", 1.0)
		m.set_shader_parameter("wood_contrast", float((context.finish as Dictionary).get("contrast", 1.0)))
		m.set_shader_parameter("wood_roughness", float((context.finish as Dictionary).get("roughness", -1.0)))
	if (context.palette as Dictionary).has("fabric"):
		m.set_shader_parameter("fabric_color", (context._fabric_colour(model) as Color))
		m.set_shader_parameter("fabric_mix", 1.0)
	if (context.palette as Dictionary).has("linen"):
		m.set_shader_parameter("linen_color", (context._linen_colour() as Color))
		m.set_shader_parameter("linen_mix", 1.0)
	(context._materials as Dictionary)[key] = m
	return m

static func _dress_bed(context: RefCounted, bed: Node3D) -> void:
	for mi: MeshInstance3D in bed.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var source := mi.get_active_material(i) as StandardMaterial3D
			if source == null: continue
			var colour := ""
			match str(source.resource_name):
				"linen": colour = (context._linen_colour() as Color).to_html(false)
				"sage": colour = (context.palette as Dictionary).get("fabric", "")
				"timber": colour = (context.finish as Dictionary).get("color", "")
			if colour == "": continue
			var key := "bed|%s|%s" % [source.resource_name, colour]
			if not (context._materials as Dictionary).has(key):
				var copy := source.duplicate() as StandardMaterial3D
				copy.albedo_color = Color.html(colour)
				(context._materials as Dictionary)[key] = copy
			mi.set_surface_override_material(i, (context._materials as Dictionary)[key])

