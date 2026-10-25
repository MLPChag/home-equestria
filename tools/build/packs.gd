extends RefCounted
## Extra resource packs shipped next to the executable (region packs, raw data pack).
## Call load_extra_packs() once, as early as possible (before anything reads res:// data from a
## pack): e.g. first line of the first autoload's _init. Source runs have no packs and skip.
## Packs load in name order; later packs replace files of earlier ones.

## Small preflight, not an integrity scan: these imported/model and terrain assets
## live in the Quest data pack, never in the code-only APK.
const ANDROID_REQUIRED_DATA := [
	"res://world/characters/hybrid_mare/stallion_body.glb",
	"res://world/terrain/data_half/terrain3d_00_02.res",
]
const MISSING_DATA := "Install the game's data (the OBB files, SideQuest does it with the APK), then reopen the game."

static func installation_problem(android_export: bool, exists: Callable) -> String:
	if not android_export: return ""
	for path: String in ANDROID_REQUIRED_DATA:
		if not bool(exists.call(path)): return MISSING_DATA
	return ""

## Shared app-file locations for resource packs and explicit key-file imports.
## user:// is internal on Quest; USB file transfer reaches the external aliases.
static func android_directories(user_data: String, external_roots: PackedStringArray = []) -> Array[String]:
	var dirs: Array[String] = [user_data]
	# Data downloaded on first launch for this exact app version (world/ui/quest_data_download.gd).
	var downloaded := user_data.path_join("quest-data").path_join(str(ProjectSettings.get_setting("application/config/version", "")))
	if downloaded not in dirs: dirs.append(downloaded)
	var package := user_data.get_base_dir().get_file()
	var roots: PackedStringArray = external_roots
	if roots.is_empty(): roots = PackedStringArray(["/storage/emulated/0", "/sdcard"])
	for root: String in roots:
		var external := root.path_join("Android/data").path_join(package).path_join("files")
		if external not in dirs: dirs.append(external)
	# OBB expansion files (dev 2026-10-23: "just dont make people do extra work"): SideQuest
	# installs main.<code>.<package>.obb (data) and patch.<code>.<package>.obb (raw) here with the
	# APK, and the app may read its own obb folder without a permission.
	for root: String in roots:
		var obb := root.path_join("Android/obb").path_join(package)
		if obb not in dirs: dirs.append(obb)
	return dirs

static func load_extra_packs() -> PackedStringArray:
	var loaded := PackedStringArray()
	if not OS.has_feature("template"): return loaded
	var exe := OS.get_executable_path()
	var main_pack := exe.get_basename() + ".pck"
	var dirs: Array[String] = [exe.get_base_dir()]
	if OS.has_feature("android"):
		dirs = android_directories(OS.get_user_data_dir())
	return _load_from_directories(dirs, main_pack)

static func _load_from_directories(dirs: Array[String], main_pack: String,
		mount: Callable = ProjectSettings.load_resource_pack) -> PackedStringArray:
	var loaded := PackedStringArray()
	var seen := {}
	for dir in dirs:
		if not DirAccess.dir_exists_absolute(dir): continue
		var names := DirAccess.get_files_at(dir)
		names.sort()
		for name in names:
			if name.get_extension().to_lower() not in ["pck", "obb"] or seen.has(name): continue
			var path := dir.path_join(name)
			if path == main_pack: continue
			if bool(mount.call(path, true)):
				seen[name] = true
				loaded.append(name)
			else: push_warning("[packs] could not load %s" % path)
	if not loaded.is_empty(): print("[packs] loaded ", ", ".join(loaded))
	return loaded
