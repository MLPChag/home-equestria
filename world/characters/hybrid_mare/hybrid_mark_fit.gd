extends RefCounted
## Correct the five transposed SVG sheets on the native skinned flank patches.
## Mesh positions, normals, indices, weights/binds and original textures stay intact.
const WIDTH := .094977
const HEIGHT := .141091
const LIMIT := Vector2(.088,.126)
static var cache := {}
static var dash_right_cache := {}
static var sheet_cache := {}

static func apply(mi: MeshInstance3D, texture: Texture2D, id: String) -> void:
	if id == "rainbow_dash":
		_fix_dash_right(mi)
		return
	if texture == null: return
	var key := id+":"+String(mi.name)+":"+str(mi.mesh.get_instance_id())
	if cache.has(key): mi.mesh=cache[key]; return
	# get_image() reads the sheet back from the GPU; both flank patches, and every reload of
	# the body mesh, fit against the same sheet. Keyed by the texture's file, else the object.
	var sheet_key:Variant=texture.resource_path if texture.resource_path!="" else texture.get_instance_id()
	if not sheet_cache.has(sheet_key):
		var image := texture.get_image()
		if image == null: return
		if image.is_compressed(): image.decompress()
		sheet_cache[sheet_key]=[image.get_used_rect(),image.get_size()]
	var rect:Rect2i=sheet_cache[sheet_key][0]
	var sheet_size:=Vector2(sheet_cache[sheet_key][1])
	# Intentionally blank adults (e.g. Sombra) have no artwork to fit.
	# Dividing by its empty rectangle used to write NaN into every UV.
	if rect.size.x == 0 or rect.size.y == 0:
		mi.hide()
		return
	var extent := Vector2(rect.size)/sheet_size
	var center := (Vector2(rect.position)+Vector2(rect.size)*.5)/sheet_size
	# The stored sheet is transposed: source-art X is texture V and Y is U.
	var artwork := Vector2(rect.size.y,rect.size.x)
	var scale := minf(LIMIT.x/artwork.x,LIMIT.y/artwork.y)
	var size := artwork*scale
	var left := String(mi.name).ends_with("_L") or String(mi.name).ends_with(".L")
	var mesh := ArrayMesh.new()
	for surface in mi.mesh.get_surface_count():
		var arrays := mi.mesh.surface_get_arrays(surface)
		var original: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var fitted := original.duplicate()
		for i in fitted.size():
			var local := (original[i]-Vector2(.463125,.505762))*Vector2(WIDTH,HEIGHT)
			# Both sides remain upright; the native U direction reverses across flanks.
			fitted[i] = center+Vector2(local.y/size.y*extent.x,local.x/size.x*extent.y*(-1.0 if left else 1.0))
		arrays[Mesh.ARRAY_TEX_UV]=fitted
		var flags: int = mi.mesh.surface_get_format(surface)&Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		mesh.add_surface_from_arrays(mi.mesh.surface_get_primitive_type(surface),arrays,[],{},flags)
		mesh.surface_set_material(surface,mi.mesh.surface_get_material(surface))
	cache[key]=mesh
	mi.mesh=mesh

static func _fix_dash_right(mi: MeshInstance3D) -> void:
	# Native Dash artwork is upright already. Only the right patch reverses its
	# front/back U axis: reflected left/right vertices have U_L + U_R == 1.
	# Match the left patch anatomically; do not use the other sheets' transpose/fit.
	if not (String(mi.name).ends_with("_R") or String(mi.name).ends_with(".R")):return
	if mi.mesh.get_meta("dash_right_uv_corrected",false):return
	var source:Mesh=mi.mesh
	var key:=source.get_instance_id()
	if dash_right_cache.has(key):mi.mesh=dash_right_cache[key];return
	var fixed:=ArrayMesh.new()
	for surface in source.get_surface_count():
		var arrays:=source.surface_get_arrays(surface)
		var uv:PackedVector2Array=arrays[Mesh.ARRAY_TEX_UV].duplicate()
		for i in uv.size():uv[i].x=1.-uv[i].x
		arrays[Mesh.ARRAY_TEX_UV]=uv
		fixed.add_surface_from_arrays(source.surface_get_primitive_type(surface),arrays,[],{},source.surface_get_format(surface)&Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		fixed.surface_set_material(surface,source.surface_get_material(surface))
	fixed.set_meta("dash_right_uv_corrected",true)
	dash_right_cache[key]=fixed
	mi.mesh=fixed
