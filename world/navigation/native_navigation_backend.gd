extends RefCounted
## Native navigation backend switch (docs/NAVIGATION_PHASE_1_2026_10_02.md,
## docs/NAVIGATION_PHASE_2_2026_10_02.md).
##
## The native search and follower are the default (DEFAULT_MODE); `off` keeps the GDScript
## WalkPlanner and navigator steering for comparison and rollback.
## `-- --native-navigation search` routes every WalkGridService route search ("path" jobs)
## through PonyNavigationNative instead; wander sampling stays in GDScript.
## `-- --native-navigation follow` adds the native continuous follower on top of the native
## search: routes become native corridors, world/characters/navigation/native_follow_driver.gd
## steps every following pony in one batch, and locomotion applies one (speed, yaw rate)
## command per tick through accept_navigation_motion(). Debug switch: only one implementation
## ever commands a pony.
## `-- --native-navigation-workers N` sets the shared native route-search workers (default: the
## autodetected search_concurrency(), at least two; shared by every zone's service). Only one implementation ever answers a request:
## the shadow comparison runs in tools/navigation/native_search_shadow.gd, never in the game.
##
## A requested native backend that this build cannot load is reported loudly (push_error and
## stderr) and the GDScript search keeps the ponies moving.

const CLASS_NAME := "PonyNavigationNative"
## Native search and continuous follower by default since October 2, 2026 (dev asked for the
## whole native navigation plan). `-- --native-navigation off` restores the GDScript navigation.
const DEFAULT_MODE := "follow"

static var _mode := ""
static var _native: RefCounted = null
static var _worlds: Dictionary = {}
static var _buckets: Dictionary = {}
static var _drained_frame := -1
static var _reported_missing := false


## "follow" (the default), "search" or "off".
static func mode() -> String:
	if _mode.is_empty():
		var args := preload("res://world/dev_tools.gd").user_args()
		var at := args.find("--native-navigation")
		_mode = args[at + 1] if at >= 0 and at + 1 < args.size() else DEFAULT_MODE
		if _mode not in ["follow", "search", "off"]:
			push_error("--native-navigation expects 'follow', 'search' or 'off', got '%s'; using the GDScript navigation" % _mode)
			_mode = "off"
	return _mode


## Fixtures choose the backend without command-line arguments.
static func set_mode(value: String) -> void:
	_mode = value


static func native_available() -> bool:
	return ClassDB.class_exists(CLASS_NAME)


## True when route searches should run natively ("search" or "follow"). Reports a missing build
## once, loudly.
static func search_enabled() -> bool:
	if mode() == "off":
		return false
	if native_available():
		return true
	_report_missing()
	return false


## True when ponies follow their routes with the native follower. A missing native build (or one
## from before phase 2, without step_batch) is reported loudly and the GDScript navigator keeps
## steering, so a pony never silently stops moving because of it.
static func follow_enabled() -> bool:
	if mode() != "follow":
		return false
	if native_available() and ClassDB.class_has_method(CLASS_NAME, "step_batch"):
		return true
	_report_missing()
	return false


static func _report_missing() -> void:
	if _reported_missing:
		return
	_reported_missing = true
	var message := "PonyNavigationNative%s is not in this build of native/pony_solver for %s; " % [
		"" if not native_available() else " follower (step_batch)", OS.get_name()] \
		+ "--native-navigation %s cannot run, ponies use the GDScript navigation" % mode()
	push_error(message)
	printerr(message)


static func instance() -> RefCounted:
	if _native == null and native_available():
		_native = ClassDB.instantiate(CLASS_NAME)
		var workers := _worker_argument()
		# dev 2026-10-20 multithreading: without the argument the route-search workers follow the
		# engine's thread pool (never fewer than the two this backend always had).
		_native.set_worker_count(workers if workers > 0 else maxi(2, search_concurrency()))
	return _native


static func _worker_argument() -> int:
	var args := preload("res://world/dev_tools.gd").user_args()
	var at := args.find("--native-navigation-workers")
	return clampi(int(args[at + 1]), 1, 64) if at >= 0 and at + 1 < args.size() else 0


## dev 2026-10-20 multithreading: how many searches may run at once, autodetected from the
## engine's WorkerThreadPool exactly as main.cpp sizes it: threading/worker_pool/max_threads
## (-1 = OS.get_processor_count()) times threading/worker_pool/low_priority_thread_ratio, clamped
## to [1, threads - 1] (WorkerThreadPool::init). Searches are low-priority pool tasks, so this is
## how many of them the pool runs side by side; frame-critical engine tasks keep the rest.
static func search_concurrency() -> int:
	var threads := int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1))
	if threads <= 0:
		threads = OS.get_processor_count()
	var ratio := float(ProjectSettings.get_setting("threading/worker_pool/low_priority_thread_ratio", 0.3))
	return clampi(int(threads * ratio), 1, maxi(1, threads - 1))


## dev 2026-10-20 multithreading: native wander searches (PonyWanderJob on the WorkerThreadPool)
## and several searches at once per service. Needs the native search and a build with wander_job.
static func wander_enabled() -> bool:
	return search_enabled() and ClassDB.class_exists("PonyWanderJob") and ClassDB.class_has_method(CLASS_NAME, "wander_job")


## One native world per walk-grid service (zone). Returns -1 when the class is missing.
static func acquire_world() -> int:
	var native := instance()
	if native == null:
		return -1
	var id: int = native.create_world()
	_worlds[id] = true
	return id


## Cancels the world's searches. The last release shuts the workers down (joins them).
static func release_world(id: int) -> void:
	if _native == null or not _worlds.has(id):
		return
	_native.destroy_world(id)
	_worlds.erase(id)
	_buckets.erase(id)
	if _worlds.is_empty():
		_native.shutdown()
		_native = null
		_drained_frame = -1


## Finished searches for one world. The native queue is drained once per physics frame and
## sorted into per-world buckets, so zones never consume each other's results.
static func take_results(id: int) -> Array:
	if _native == null:
		return []
	var frame := Engine.get_physics_frames()
	if frame != _drained_frame:
		_drained_frame = frame
		var drained: Array = _native.poll_results()
		for result: Dictionary in drained:
			var world: int = int(result.get("world", -1))
			if not _worlds.has(world):
				continue
			if not _buckets.has(world):
				_buckets[world] = []
			var bucket: Array = _buckets[world]
			bucket.append(result)
	var mine: Array = _buckets.get(id, [])
	_buckets.erase(id)
	return mine


## WalkChunk.view() arrays, converted once per published revision.
static func publish_view(id: int, coord: Vector2i, view: Dictionary) -> int:
	if _native == null:
		return 0
	var trail: PackedByteArray = view.get("trail_weight", PackedByteArray())
	var revision: int = _native.publish_walk_chunk(id, coord, view.floor_y, view.slope_deg, view.water_depth,
		view.headroom, view.flags, view.paint_cost, trail)
	return revision


static func remove_chunk(id: int, coord: Vector2i) -> void:
	if _native != null:
		_native.remove_chunk(id, coord)


## WalkGrid.profile() dictionary -> native movement profile (values already body-scaled).
static func profile_of(settings: Dictionary) -> Dictionary:
	return {"radius": float(settings.radius), "clearance": float(settings.clearance), "step": float(settings.step),
		"slope": float(settings.slope), "wade": float(settings.wade), "swim": bool(settings.swim), "scale": 1.0, "mask": 1}


## Native result -> the WalkPlanner.plan() dictionary the service and navigators expect.
static func legacy_result(result: Dictionary) -> Dictionary:
	var status: int = int(result.get("status", 9))
	var frontier: Array = result.get("frontier", [])
	var path: PackedVector3Array = result.get("path", PackedVector3Array())
	var out := {"path": path, "expanded": int(result.get("expanded", 0)), "reason": str(result.get("reason", "")),
		"frontier": frontier, "native_status": str(result.get("status_name", "")),
		"native_ms": float(result.get("cpu_ms", 0.0))}
	if status != 1:
		out.path = PackedVector3Array()
	if status == 7:
		out["stale"] = true
	return out
