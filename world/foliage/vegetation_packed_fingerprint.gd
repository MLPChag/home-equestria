extends RefCounted
## PCK resources have no source mtimes and exported scripts are bytecode.
## Hash actual packed contents once during terrain setup, never during frame updates.
const INPUTS := [
	"res://world/foliage/terrain_surface_color.gd",
	"res://world/terrain/gaea_material.gd",
	"res://world/terrain/grass_palette.json",
	"res://world/terrain/textures.json",
	"res://world/world_layout.json",
	"res://world/terrain/gaea/materials.f32",
	"res://world/terrain/gaea/surfaces.res",
	"res://world/biomes/authored/surface_index.json",
]

static func fingerprint(data_dir: String) -> String:
	if not DirAccess.dir_exists_absolute(data_dir): return ""
	var entries: Array = []
	var files := DirAccess.get_files_at(data_dir)
	files.sort()
	for file: String in files:
		if not file.ends_with(".res"): continue
		var path := data_dir.path_join(file)
		var digest := _digest(path)
		if digest.is_empty(): return ""
		entries.append([file, digest])
	if entries.is_empty(): return ""
	var keys: Array = ["vegetation-packed-v1", entries]
	for original: String in INPUTS:
		var digest := _digest(original)
		if digest.is_empty() and original.ends_with(".gd"):
			digest = _digest(original + "c")
		if digest.is_empty(): return ""
		keys.append([original, digest])
	keys.append("gaea-off" if "--gaea-materials-off" in preload("res://world/dev_tools.gd").user_args() else "gaea-on")
	return var_to_bytes(keys).hex_encode().sha256_text()

static func _digest(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or not file.is_open(): return ""
	var hash := HashingContext.new()
	if hash.start(HashingContext.HASH_SHA256) != OK: return ""
	var remaining := file.get_length()
	while remaining > 0:
		var bytes := file.get_buffer(mini(remaining, 1048576))
		if bytes.is_empty() or hash.update(bytes) != OK: return ""
		remaining -= bytes.size()
	return hash.finish().hex_encode()
