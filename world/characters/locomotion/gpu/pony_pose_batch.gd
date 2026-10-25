extends Node
## Completes all current-tick contact poses together, before deferred skinning.
const BACKEND := preload("res://world/characters/locomotion/gpu/leg_pose_backend.gd")
const SOLVER := preload("res://world/characters/locomotion/limb_solver.gd")
const GROUP := &"pony_pose_batch"
var backend: RefCounted
var available := false
var statistics := {}
var _jobs: Array[Dictionary]=[]

static func for_pony(pony: Node) -> Node:
	if "--gpu-poses" not in preload("res://world/dev_tools.gd").user_args(): return null
	var tree:=pony.get_tree()
	var existing: Node=tree.root.get_meta(GROUP) if tree.root.has_meta(GROUP) else null
	if is_instance_valid(existing): return existing
	var batch:=load("res://world/characters/locomotion/gpu/pony_pose_batch.gd").new() as Node
	batch.name="PonyPoseBatch"
	tree.root.set_meta(GROUP,batch)
	tree.root.call_deferred("add_child",batch)
	return batch

func _ready() -> void:
	process_physics_priority=1000
	backend=BACKEND.new()
	available=backend.initialize()
	add_to_group(GROUP)
	print("[gpu-poses] ","Ready: batched current-tick leg solver" if available else "CPU fallback: "+backend.last_error)

func enqueue(pony: Node, delta: float, frame: Transform3D, fk: Array[Transform3D]) -> void:
	_jobs.append({"pony":pony,"delta":delta,"frame":frame,"fk":fk,"tick":pony._tick})
	pony._gpu_pose_pending=true

func _physics_process(_delta: float) -> void:
	flush()

func flush() -> void:
	if _jobs.is_empty(): return
	var started:=Time.get_ticks_usec()
	var jobs:=_jobs; _jobs=[]
	var accepted: Array[Dictionary]=[]
	backend.begin()
	var fallbacks:=0
	for job in jobs:
		if not is_instance_valid(job.pony) or not job.pony.is_inside_tree(): continue
		if job.pony._tick!=job.tick:
			job.pony._gpu_pose_pending=false
			push_error("GPU pose batch missed its physics tick"); continue
		if available and backend.append(job.pony,job.frame,job.fk): accepted.append(job)
		else: _cpu_fallback(job); fallbacks+=1
	var packed_at:=Time.get_ticks_usec()
	var result: PackedFloat32Array=backend.execute()
	var computed_at:=Time.get_ticks_usec()
	for i in accepted.size():
		var job: Dictionary=accepted[i]
		if backend.apply(job.pony,result,i):
			job.pony._complete_gpu_pose(job.delta,job.frame,job.fk)
		else: _cpu_fallback(job); fallbacks+=1
	var completed:=Time.get_ticks_usec()
	statistics={"ponies":accepted.size(),"fallbacks":fallbacks,"retry_legs":backend.retry_legs,"pack_ms":(packed_at-started)/1000.0,"compute_sync_ms":(computed_at-packed_at)/1000.0,"apply_finish_ms":(completed-computed_at)/1000.0,"total_ms":(completed-started)/1000.0,"backend":backend.timings}

func _cpu_fallback(job: Dictionary) -> void:
	var pony: Node=job.pony
	pony._gpu_pose_pending=false
	# Temporarily bypass scheduling; use the exact existing synchronous path.
	var batch: Node=pony._pose_batch
	pony._pose_batch=null
	pony._solve_pose(job.delta)
	pony._finish_joint_constraints()
	pony._pose_batch=batch
	pony.modifier.prepared=pony.corrected_pose if pony.corrections_enabled or pony._held or pony.carry.blend>0 else pony.source_pose.duplicate()

func _exit_tree() -> void:
	available=false
	if backend!=null: backend.shutdown()
