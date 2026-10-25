extends RefCounted
## PonySolverNative (docs/NATIVE_SOLVER_2026_09_25.md): the C++ copy of the pony's hot
## GDScript. create() returns an instance when the extension is loaded for this platform and
## the game was not started with `-- --native-solver off`; otherwise null, and every caller
## keeps its GDScript path. `-- --native-solver-skip <list>` keeps single systems in GDScript
## for A/B benches, comma-separated: contacts, self_collision, tail, probe, body, eyes,
## terrain_modifier, boop, bone_skip, clip_head, surface_contact, gait_sampling (the leg solve, FK and joint limits always go native;
## bone_skip keeps the terrain modifier writing every bone).
## `-- --native-solver-parallel off` solves each pony inline in her own tick instead of all
## HERO ponies of a physics tick at once on the WorkerThreadPool (pony_solve_batch.gd).

static var allowed := _allowed()
static var _skipped := _skip_list()
static var parallel := _parallel()


static func _allowed() -> bool:
	var args := preload("res://world/dev_tools.gd").user_args()
	var at := args.find("--native-solver")
	return not (at >= 0 and at + 1 < args.size() and args[at + 1] == "off")


static func _parallel() -> bool:
	var args := preload("res://world/dev_tools.gd").user_args()
	var at := args.find("--native-solver-parallel")
	return not (at >= 0 and at + 1 < args.size() and args[at + 1] == "off")


static func _skip_list() -> PackedStringArray:
	var args := preload("res://world/dev_tools.gd").user_args()
	var at := args.find("--native-solver-skip")
	return args[at + 1].split(",") if at >= 0 and at + 1 < args.size() else PackedStringArray()


## Whether `system` (one of the --native-solver-skip names) may use the native code.
static func enabled(system: String) -> bool:
	return not _skipped.has(system)


static func create() -> RefCounted:
	if allowed and ClassDB.class_exists("PonySolverNative"):
		return ClassDB.instantiate("PonySolverNative")
	return null
