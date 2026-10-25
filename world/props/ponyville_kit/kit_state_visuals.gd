extends Node3D
## Small authored activity parts remain batched. Only committed state updates slots.
const STATE := preload("res://world/props/ponyville_kit/kit_state.gd")
const FITS := preload("res://world/props/ponyville_kit/kit_fits.gd")
const FOLDER := "res://world/props/ponyville_kit/activity/"
const CELL := 48.0
var _state: Node
var _bindings: Dictionary = {}

func setup(dressing: Node3D, rows: Array) -> void:
	_state = STATE.for_node(dressing)
	if _state == null: return
	var groups := {}
	for row: Dictionary in rows:
		var kind := str(row.kind)
		if kind not in ["mailbox", "log_pile"]: continue
		var fit := FITS.get_kind(kind)
		if fit.is_empty() or (kind == "mailbox" and not bool(fit.get("base_flag_removed", false))): continue
		var key := "%s|%d|%d" % [kind, floori(float(row.x) / CELL), floori(float(row.z) / CELL)]
		if not groups.has(key): groups[key] = []
		(groups[key] as Array).append(row)
	for key: String in groups:
		var kind := key.get_slice("|", 0)
		var fit := FITS.get_kind(kind)
		var roles: Dictionary = {"flag": "mailbox_flag", "letter": "letter"} if kind == "mailbox" else {"whole": "log_whole", "half_a": "log_half_a", "half_b": "log_half_b"}
		for role: String in roles:
			_build(groups[key], role, str(roles[role]), fit)
	_state.changed.connect(_changed)
	for id: String in _bindings: _changed(id, _state.snapshot(id))

func _build(rows: Array, role: String, asset: String, fit: Dictionary) -> void:
	var fields: Array = ["flag_up", "flag_down"] if role == "flag" else ["letter_rest" if role == "letter" else role]
	for field: String in fields:
		if not FITS.transform(fit.get(field)).origin.is_finite(): return
	if not ResourceLoader.exists(FOLDER + asset + ".scn"): return
	var packed := load(FOLDER + asset + ".scn") as PackedScene
	if packed == null: return
	var scene := packed.instantiate() as Node3D
	if scene == null: return
	var meshes: Array = scene.find_children("*", "MeshInstance3D", true, false)
	if scene is MeshInstance3D: meshes.push_front(scene)
	for mesh: MeshInstance3D in meshes:
		if mesh.mesh == null: continue
		var imported := mesh.transform
		var parent := mesh.get_parent() as Node3D if mesh != scene else null
		while parent != null:
			imported = parent.transform * imported
			parent = parent.get_parent() as Node3D if parent != scene else null
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh.mesh
		mm.instance_count = rows.size()
		var mmi := MultiMeshInstance3D.new()
		mmi.name = asset + "_state"
		mmi.multimesh = mm
		mmi.visibility_range_end = 90.0
		mmi.visibility_range_end_margin = 8.0
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		for index: int in rows.size():
			var row: Dictionary = rows[index]
			var placement := Transform3D(Basis(Vector3.UP, float(row.yaw)), Vector3(float(row.x), preload("res://world/props/ponyville_kit/kit_lifts.gd").y(row), float(row.z)))
			if not _bindings.has(str(row.id)): _bindings[str(row.id)] = []
			(_bindings[str(row.id)] as Array).append({"mesh": mm, "index": index, "role": role,
				"placement": placement, "imported": imported, "fit": fit})
	scene.free()

func _changed(id: String, state: Dictionary) -> void:
	for binding: Dictionary in _bindings.get(id, []):
		var role := str(binding.role)
		var field := role
		var visible := true
		match role:
			"flag": field = "flag_up" if bool(state.mail_pending) else "flag_down"
			"letter":
				field = "letter_rest"
				visible = bool(state.mail_pending)
			"whole": visible = int(state.split_count) == 0
			"half_a", "half_b": visible = int(state.split_count) > 0
		var local := FITS.transform(binding.fit.get(field))
		if not local.origin.is_finite(): continue
		var transform: Transform3D = binding.placement * local * binding.imported
		if not visible: transform.basis = transform.basis.scaled(Vector3.ONE * .00001)
		(binding.mesh as MultiMesh).set_instance_transform(int(binding.index), transform)

func _exit_tree() -> void:
	if is_instance_valid(_state) and _state.changed.is_connected(_changed): _state.changed.disconnect(_changed)
	_bindings.clear()
