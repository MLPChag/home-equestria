extends Node
## Quest first launch (dev 2026-10-23: "download the apk ON the quest, double click it, and it just
## works"): the APK carries code and scenes only, so its data packs come from the GitHub release of
## this exact app version (one APK never mixes with another version's data). An APK is a zip and
## Android cannot install one over 4 GB; a release file must be under 2 GiB, so the 3.9 GB data
## pack is published in parts and joined here. Files land in user://quest-data/<version>/, which
## tools/build/packs.gd mounts on every later launch; other versions' folders are removed once
## this one is complete. A dropped connection or a full disk retries, keeping finished parts.

signal progress(text: String)
signal finished

const MANIFEST := "res://world/ui/quest_data_manifest.json"
const RELEASES := "https://github.com/homedevanon/home-equestria/releases/download/%s/%s"
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const COPY_CHUNK := 8 * 1024 * 1024

## Tests point these at a local server and their own list.
var url_format := RELEASES
var manifest_path := MANIFEST
var _http: HTTPRequest
var _total := 0
var _done := 0


static func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))


static func folder() -> String:
	return "user://quest-data/" + version()


func start() -> void:
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path)) if FileAccess.file_exists(manifest_path) else null
	if not (manifest is Dictionary):
		progress.emit("This build has no data download list. Install the full game data, then reopen."); return
	DirAccess.make_dir_recursive_absolute(folder())
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.download_chunk_size = 1 << 20
	add_child(_http)
	var targets: Array = manifest.get("targets", [])
	for target: Dictionary in targets:
		for part: Dictionary in target.parts: _total += int(part.size)
	set_process(true)
	for target: Dictionary in targets:
		var path := folder().path_join(str(target.name))
		var size := 0
		for part: Dictionary in target.parts: size += int(part.size)
		while not _complete(path, size):
			if not await _fetch_target(target, path): return
		_done += size
	for target: Dictionary in targets:
		ProjectSettings.load_resource_pack(folder().path_join(str(target.name)), true)
	_remove_other_versions()
	set_process(false)
	progress.emit("Game data ready.")
	finished.emit()


## Download each missing part, then join them into the pack. False only when the tree is leaving.
func _fetch_target(target: Dictionary, path: String) -> bool:
	var base := _done
	for part: Dictionary in target.parts:
		var part_path := folder().path_join(str(part.name))
		if not _complete(part_path, int(part.size)):
			_http.download_file = ProjectSettings.globalize_path(part_path)
			_part_base = base
			if _http.request(url_format % [version(), str(part.name)]) != OK:
				if not await _retry("Could not start the download. Retrying..."): return false
				return true
			var result: Array = await _http.request_completed
			if int(result[0]) != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200 or not _complete(part_path, int(part.size)):
				if not await _retry("Download interrupted (%s). Retrying..." % _reason(result)): return false
				return true
		base += int(part.size)
	# The later parts are appended to the first one, so joining needs only one part's extra space.
	# An interrupted join leaves the first part too long; it is downloaded again on the retry.
	progress.emit("Unpacking game data...")
	var first := ProjectSettings.globalize_path(folder().path_join(str(target.parts[0].name)))
	if target.parts.size() > 1:
		var out := FileAccess.open(first, FileAccess.READ_WRITE)
		if out == null:
			return await _retry("Not enough space for the game data (about 6.5 GB needed while installing). Retrying...")
		out.seek_end()
		for part: Dictionary in target.parts.slice(1):
			var part_path := ProjectSettings.globalize_path(folder().path_join(str(part.name)))
			var source := FileAccess.open(part_path, FileAccess.READ)
			if source == null: out.close(); return true
			while source.get_position() < source.get_length():
				out.store_buffer(source.get_buffer(COPY_CHUNK))
				if out.get_error() != OK:
					source.close(); out.close()
					return await _retry("Not enough space for the game data (about 6.5 GB needed while installing). Retrying...")
				if not await SHUTDOWN.frame(self): source.close(); out.close(); return false
			source.close()
		out.close()
		for part: Dictionary in target.parts.slice(1): DirAccess.remove_absolute(ProjectSettings.globalize_path(folder().path_join(str(part.name))))
	DirAccess.rename_absolute(first, ProjectSettings.globalize_path(path))
	return true


var _part_base := 0

func _process(_delta: float) -> void:
	if _http == null or _total <= 0: return
	var got := _part_base + maxi(0, _http.get_downloaded_bytes())
	progress.emit("Downloading game data: %.1f of %.1f GB (%d%%)" % [got / 1e9, _total / 1e9, roundi(100.0 * got / _total)])


func _retry(text: String) -> bool:
	progress.emit(text)
	return await SHUTDOWN.seconds(self, 5.0)


static func _reason(result: Array) -> String:
	return "HTTP %d" % int(result[1]) if int(result[0]) == HTTPRequest.RESULT_SUCCESS else "error %d" % int(result[0])


static func _complete(path: String, size: int) -> bool:
	if not FileAccess.file_exists(path): return false
	var file := FileAccess.open(path, FileAccess.READ)
	return file != null and file.get_length() == size


func _remove_other_versions() -> void:
	var root := ProjectSettings.globalize_path("user://quest-data")
	for name in DirAccess.get_directories_at(root):
		if name == version(): continue
		var dir := root.path_join(name)
		for file in DirAccess.get_files_at(dir): DirAccess.remove_absolute(dir.path_join(file))
		DirAccess.remove_absolute(dir)
