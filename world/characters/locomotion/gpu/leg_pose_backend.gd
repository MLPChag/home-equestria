extends RefCounted
## One local RenderingDevice, persistent buffers and one readback for the crowd.
const MAX_CHAIN := 8
const INPUT_FLOATS := 136
const OUTPUT_FLOATS := 40
const CONFIG_FLOATS := 100
var rd: RenderingDevice
var shader := RID()
var pipeline := RID()
var uniform_set := RID()
var inputs := RID()
var outputs := RID()
var configs := RID()
var capacity := 0
var ready := false
var last_error := ""
var timings := {}
var _config_data := PackedFloat32Array()
var _config_cache := {}
var _rigs := {}
var _input_data := PackedFloat32Array()
var _count := 0
var retry_legs := 0
var _submitted: Array[Dictionary]=[]
var _configs_dirty := false

func initialize() -> bool:
	if RenderingServer.get_rendering_device() == null:
		last_error="No RenderingDevice (headless or compatibility renderer)"; return false
	rd=RenderingServer.create_local_rendering_device()
	if rd==null: last_error="Could not create compute device"; return false
	var source:=RDShaderSource.new()
	source.source_compute=FileAccess.get_file_as_string("res://world/characters/locomotion/gpu/leg_pose.glsl").replace("#[compute]","")
	var spirv:=rd.shader_compile_spirv_from_source(source)
	last_error=spirv.compile_error_compute
	if not last_error.is_empty(): shutdown(); return false
	shader=rd.shader_create_from_spirv(spirv)
	if not shader.is_valid(): last_error="Compute shader creation failed"; shutdown(); return false
	pipeline=rd.compute_pipeline_create(shader)
	ready=pipeline.is_valid()
	return ready

func register(pony: Node) -> Array:
	var id:=pony.get_instance_id()
	if _rigs.has(id): return _rigs[id]
	var legs: Array=[]
	for leg: Dictionary in pony.profile.legs:
		var chain: Array[int]=[]
		var bone: int=leg.leaf
		while bone>=0:
			chain.push_front(bone)
			if bone==leg.root: break
			bone=pony.profile.parents[bone]
		if chain.size()>MAX_CHAIN or chain[0]!=leg.root or leg.proximal not in chain or leg.middle not in chain:
			last_error="Unsupported leg chain"; return []
		var mutable: Array[int]=[leg.root,leg.proximal,leg.middle,leg.leaf]
		var data:=PackedFloat32Array([chain.size(),chain.find(leg.proximal),chain.find(leg.middle),chain.size()-1])
		for index in mutable:
			if not pony.joint_limits.joints.has(index): last_error="Missing joint bounds"; return []
			var joint: Dictionary=pony.joint_limits.joints[index]
			_append_basis(data,joint.parent); _append_basis(data,joint.rest)
			var axis: Vector3=joint.axis
			data.append_array(PackedFloat32Array([axis.x,axis.y,axis.z,joint.lower,joint.upper,joint.swing]))
		# Exact serialized rig constants deduplicate the common Mane 6 body rig.
		var key:=Marshalls.raw_to_base64(data.to_byte_array())
		var config: int=_config_cache.get(key,-1)
		if config<0:
			config=_config_data.size()/CONFIG_FLOATS
			_config_data.append_array(data); _config_cache[key]=config; _configs_dirty=true
		legs.append({"chain":chain,"mutable":mutable,"config":config,"parent":pony.profile.parents[leg.root]})
	_rigs[id]=legs
	pony.tree_exiting.connect(unregister.bind(pony),CONNECT_ONE_SHOT)
	return legs

func unregister(pony: Node) -> void:
	_rigs.erase(pony.get_instance_id())

func begin() -> void:
	_count=0
	retry_legs=0
	_submitted.clear()
	_input_data.clear()

func append(pony: Node, frame: Transform3D, fk: Array[Transform3D]) -> bool:
	var legs:=register(pony)
	if legs.is_empty(): return false
	_submitted.append({"frame":frame,"fk":fk})
	for i in 4:
		var info: Dictionary=legs[i]
		var leg: Dictionary=pony.profile.legs[i]
		var foot: Dictionary=pony.feet[i]
		var at:=_input_data.size()
		_input_data.resize(at+INPUT_FLOATS)
		_input_data[at]=info.config
		_input_data[at+1]=0.0 if pony._held and not foot.valid else 1.0
		_input_data[at+2]=pony.profile.hip_height*.0001
		_input_data[at+3]=deg_to_rad(float(leg.get("max_flex_degrees",180.0)))
		_write_transform(_input_data,at+4,frame if info.parent<0 else fk[info.parent])
		for j in info.chain.size(): _write_transform(_input_data,at+16+j*12,pony.source_pose[info.chain[j]])
		_write_v3(_input_data,at+112,foot.target); _input_data[at+115]=deg_to_rad(22.0)
		_write_v3(_input_data,at+116,foot.dynamic_sole)
		_write_basis(_input_data,at+120,foot.basis)
		var line: Vector3=(fk[leg.leaf].origin-fk[leg.root].origin).normalized()
		var pole: Vector3=fk[leg.middle].origin-fk[leg.root].origin
		pole-=line*pole.dot(line)
		# Same bend-direction memory as the CPU solver: a straight leg keeps its last pole.
		if pole.length_squared()<0.0004:
			var remembered: Vector3=pony._leg_poles[i] if "_leg_poles" in pony else Vector3.ZERO
			pole=frame.basis*(remembered if remembered.length_squared()>0.0 else Vector3(leg.pole))
		elif "_leg_poles" in pony: pony._leg_poles[i]=frame.basis.inverse()*pole
		_write_v3(_input_data,at+132,pole)
		_count+=1
	return true

func execute() -> PackedFloat32Array:
	if not ready or _count==0: return PackedFloat32Array()
	var started:=Time.get_ticks_usec()
	_reserve()
	var bytes:=_input_data.to_byte_array()
	rd.buffer_update(inputs,0,bytes.size(),bytes)
	var uploaded:=Time.get_ticks_usec()
	var list:=rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,pipeline)
	rd.compute_list_bind_uniform_set(list,uniform_set,0)
	rd.compute_list_set_push_constant(list,PackedInt32Array([_count,0,0,0]).to_byte_array(),16)
	rd.compute_list_dispatch(list,ceili(float(_count)/64),1,1)
	rd.compute_list_end()
	rd.submit()
	# Current-tick collision consumers require this result. Sync once per BATCH,
	# never per pony; no multi-frame delay or stale contact pose is introduced.
	rd.sync()
	var data:=rd.buffer_get_data(outputs,0,_count*OUTPUT_FLOATS*4).to_float32_array()
	var finished:=Time.get_ticks_usec()
	timings={"legs":_count,"upload_ms":(uploaded-started)/1000.0,"dispatch_wait_read_ms":(finished-uploaded)/1000.0,"total_ms":(finished-started)/1000.0}
	return data

func apply(pony: Node, result: PackedFloat32Array, pony_index: int) -> bool:
	var legs: Array=_rigs[pony.get_instance_id()]
	var start:=pony_index*4*OUTPUT_FLOATS
	if result.size()<start+4*OUTPUT_FLOATS: return false
	# Reject the entire mare's output before writing if the device returned NaNs.
	for i in range(start,start+4*OUTPUT_FLOATS):
		if not is_finite(result[i]): return false
	for i in 4:
		var at:=start+i*OUTPUT_FLOATS
		for j in 4:
			var basis:=_read_basis(result,at+j*9)
			var expected: Basis=pony.source_pose[legs[i].mutable[j]].basis
			if absf(basis.determinant())<.000001 or basis.get_scale().distance_to(expected.get_scale())>.0001: return false
	for i in 4:
		var at:=start+i*OUTPUT_FLOATS
		if result[at+39]>.5:
			retry_legs+=1
			var job: Dictionary=_submitted[pony_index]
			pony._solve_leg(i,job.frame,job.fk,pony.feet[i].target)
			continue
		for j in 4:
			var bone: int=legs[i].mutable[j]
			pony.corrected_pose[bone].basis=_read_basis(result,at+j*9)
		if result[at+36]>.5: pony.feet[i].limited=true
		pony.feet[i].correction_angle=result[at+37]
	return true

func _reserve() -> void:
	var rebuild:=false
	if _count>capacity:
		capacity=maxi(64,nearest_po2(_count))
		_free_uniform()
		if inputs.is_valid(): rd.free_rid(inputs)
		if outputs.is_valid(): rd.free_rid(outputs)
		inputs=rd.storage_buffer_create(capacity*INPUT_FLOATS*4)
		outputs=rd.storage_buffer_create(capacity*OUTPUT_FLOATS*4)
		rebuild=true
	if _configs_dirty:
		_free_uniform()
		if configs.is_valid(): rd.free_rid(configs)
		configs=rd.storage_buffer_create(_config_data.size()*4,_config_data.to_byte_array())
		_configs_dirty=false; rebuild=true
	if rebuild:
		var uniforms: Array[RDUniform]=[]
		for binding in 3:
			var uniform:=RDUniform.new(); uniform.uniform_type=RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			uniform.binding=binding; uniform.add_id([inputs,configs,outputs][binding]); uniforms.append(uniform)
		uniform_set=rd.uniform_set_create(uniforms,shader,0)

func _free_uniform() -> void:
	if uniform_set.is_valid(): rd.free_rid(uniform_set); uniform_set=RID()

func shutdown() -> void:
	ready=false
	if rd==null: return
	_free_uniform()
	for rid in [inputs,outputs,configs,pipeline,shader]:
		if rid.is_valid(): rd.free_rid(rid)
	rd.free(); rd=null
	inputs=RID(); outputs=RID(); configs=RID(); pipeline=RID(); shader=RID()

static func _write_v3(data: PackedFloat32Array, at: int, v: Vector3) -> void:
	data[at]=v.x; data[at+1]=v.y; data[at+2]=v.z

static func _write_basis(data: PackedFloat32Array, at: int, b: Basis) -> void:
	_write_v3(data,at,b.x); _write_v3(data,at+3,b.y); _write_v3(data,at+6,b.z)

static func _write_transform(data: PackedFloat32Array, at: int, t: Transform3D) -> void:
	_write_basis(data,at,t.basis); _write_v3(data,at+9,t.origin)

static func _append_basis(data: PackedFloat32Array, b: Basis) -> void:
	data.append_array(PackedFloat32Array([b.x.x,b.x.y,b.x.z,b.y.x,b.y.y,b.y.z,b.z.x,b.z.y,b.z.z]))

static func _read_basis(data: PackedFloat32Array, at: int) -> Basis:
	return Basis(Vector3(data[at],data[at+1],data[at+2]),Vector3(data[at+3],data[at+4],data[at+5]),Vector3(data[at+6],data[at+7],data[at+8]))
