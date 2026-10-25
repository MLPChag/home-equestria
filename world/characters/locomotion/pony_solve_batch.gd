extends Node
## Solves every queued pony's pose for this physics tick at once (docs/NATIVE_SOLVER_2026_09_25.md).
## Each free HERO pony (not held, no hoof held) gathers her solve inputs at the point of her tick
## where she used to solve inline, then waits here. This node runs after every pony
## (process_physics_priority 800) and before the deferred skeleton update, solves all of them on
## the WorkerThreadPool (PonySolverNative.solve_batch), and applies each result on the main
## thread. Every pony's solve is independent, so the result is the serial one bit for bit.
## `-- --native-solver-parallel off` keeps the inline serial solve.
const GROUP := &"pony_solve_batch"
const NATIVE := preload("res://world/characters/locomotion/native_solver.gd")
const PROFILE := preload("res://tools/crowd_cpu_profile.gd")
## dev 2026-10-20 multithreading: each pony's solve starts on the WorkerThreadPool the moment she
## enqueues (PonySolverNative.solve_kick), so it runs on another core while the main thread ticks
## the remaining ponies and every other node up to this flush, which then only waits for what is
## left. Same solve_run() on the same gathered inputs, applied at the same point: identical
## results. false = the previous behaviour (everything starts at the flush). Needs a pony_solver
## binary with solve_kick; an older one keeps the flush-time solve.
const KICK_ON_ENQUEUE := true
static var _can_kick := ClassDB.class_has_method(&"PonySolverNative", &"solve_kick")
var _ponies: Array = []


## The tree's batch, created on first use; null when the parallel solve is switched off.
static func for_pony(pony: Node) -> Node:
	if not NATIVE.parallel or not pony.is_inside_tree():
		return null
	var tree := pony.get_tree()
	var existing: Node = tree.root.get_meta(GROUP) if tree.root.has_meta(GROUP) else null
	if is_instance_valid(existing):
		return existing
	var batch := (load("res://world/characters/locomotion/pony_solve_batch.gd") as Script).new() as Node
	batch.name = "PonySolveBatch"
	tree.root.set_meta(GROUP, batch)
	tree.root.call_deferred("add_child", batch)
	return batch


func _ready() -> void:
	process_physics_priority = 800
	# Whatever was queued is solved even while the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS


func enqueue(pony: Node) -> void:
	_ponies.append(pony)
	if KICK_ON_ENQUEUE and _can_kick:
		pony._native.solve_kick()


func _physics_process(_delta: float) -> void:
	flush()


func flush() -> void:
	if _ponies.is_empty():
		return
	var started := Time.get_ticks_usec() if PROFILE.enabled else 0
	var ponies := _ponies
	_ponies = []
	var live: Array = []
	var natives: Array = []
	for pony in ponies:
		if is_instance_valid(pony) and pony.is_inside_tree():
			live.append(pony)
			natives.append(pony._native)
	if not natives.is_empty():
		_solve(natives)
		for pony in live:
			pony._apply_solve()
	if PROFILE.enabled:
		PROFILE.record("solve_batch", started)


## The parity test overrides this to run the serial and the parallel solve and compare them.
func _solve(natives: Array) -> void:
	natives[0].solve_batch(natives, true)
