extends RefCounted
## Shared native flight pose sampling for gameplay and the review lab.
const SOURCE := "res://world/characters/hybrid_mare/pony_flight.json"
## Parsed once (re-read if the file changes); poses only read it.
static var _source: Variant
static var _source_time := -1
## Built clips shared by every pose with the same _layout_key(); the Animations are
## only interpolated, never edited.
static var _built: Dictionary = {}
var pony: CharacterBody3D
var clips: Dictionary
var libraries: Dictionary = {}
var standing: Array[Transform3D] = []
var wing_bones: Dictionary = {}
var clip := "hover"
var time := 0.0
var playing := true
var wings_only := false
var speed := 1.0
var source_loop_pose := true
## Hybrid head is larger than the native head. Relax the extended cruising neck.
## 1 = original source; 0 = neutral neck bend. Bone lengths and head aim stay fixed.
var neck_reach := 0.35
var _neck_bones: Array[int] = []

func bind(actor: CharacterBody3D, pause_ground := true) -> void:
	pony = actor
	for bone_name in ["pony_neck1", "pony_neck2", "pony_head"]:
		_neck_bones.append(pony.skeleton.find_bone(bone_name))
	standing = pony.corrected_pose.duplicate()
	if pause_ground: pony.motion_paused = true
	pony.animation.pause()
	var modified := FileAccess.get_modified_time(SOURCE)
	if _source == null or modified != _source_time:
		_source = JSON.parse_string(FileAccess.get_file_as_string(SOURCE)); _source_time = modified; _built.clear()
	clips = _source
	var key := _layout_key()
	if _built.has(key):
		libraries = _built[key].libraries; wing_bones = _built[key].wing_bones
		return
	libraries = {}; wing_bones = {}
	for name: String in clips:
		var data: Dictionary = clips[name]
		var anim := Animation.new(); anim.length = data.length
		var track_bones: Array[int] = []
		for channel: Dictionary in data.tracks:
			var b: int = pony.skeleton.find_bone(channel.bone); assert(b >= 0)
			if String(channel.bone).begins_with("pony_Wing") or String(channel.bone).begins_with("pony_Feather"): wing_bones[b] = true
			var type := Animation.TYPE_ROTATION_3D if channel.kind == "rotation" else (Animation.TYPE_POSITION_3D if channel.kind == "position" else Animation.TYPE_SCALE_3D)
			var track := anim.add_track(type); track_bones.append(b)
			for i in data.times.size():
				var v: Array = channel.values[i]
				if type == Animation.TYPE_ROTATION_3D: anim.rotation_track_insert_key(track, data.times[i], Quaternion(v[0],v[1],v[2],v[3]))
				elif type == Animation.TYPE_POSITION_3D: anim.position_track_insert_key(track, data.times[i], pony.profile.native_position(b,Vector3(v[0],v[1],v[2])))
				else: anim.scale_track_insert_key(track, data.times[i], Vector3(v[0],v[1],v[2]))
		libraries[name] = {"animation":anim, "bones":track_bones}
	_built[key] = {"libraries":libraries, "wing_bones":wing_bones}

## Everything the build reads from the pony: source bone indices and, on rebased bodies,
## the rest and native origins profile.native_position uses. Not the per-pony profile itself.
func _layout_key() -> Array:
	var natives: Dictionary = pony.profile.native_rest_positions
	var key: Array = [natives.is_empty()]
	for name: String in clips:
		for channel: Dictionary in clips[name].tracks:
			var b: int = pony.skeleton.find_bone(channel.bone)
			key.append(b)
			if channel.kind == "position" and b >= 0 and not natives.is_empty():
				key.append(pony.profile.rest[b].origin); key.append(natives.get(channel.bone))
	return key

func choose(name: String) -> void:
	clip = name; time = 0.0; playing = true
	apply()

func advance(delta: float) -> void:
	if playing and clip in clips:
		var length: float = clips[clip].length
		time += delta * speed
		if clips[clip].loop: time = fposmod(time, length)
		else: time = minf(time, length)
	apply()

func seek(value: float) -> void:
	if clip not in clips: return
	time = clampf(value, 0.0, clips[clip].length); playing = false
	apply()

func apply() -> void:
	var pose: Array[Transform3D] = standing.duplicate() if wings_only or clip == "folded" else pony.profile.rest.duplicate()
	if clip in libraries:
		var item: Dictionary = libraries[clip]
		var anim: Animation = item.animation
		var close_loop: bool = source_loop_pose and clips[clip].get("loop_pose",false)
		var phase := clampf(time / anim.length,0.0,1.0)
		for track in anim.get_track_count():
			var b: int = item.bones[track]
			if wings_only and not b in wing_bones: continue
			match anim.track_get_type(track):
				Animation.TYPE_ROTATION_3D:
					var q := anim.rotation_track_interpolate(track,time)
					if close_loop:
						var correction := anim.rotation_track_interpolate(track,anim.length).inverse() * anim.rotation_track_interpolate(track,0.0)
						q = q * Quaternion.IDENTITY.slerp(correction,phase)
					pose[b].basis = Basis(q).scaled_local(pose[b].basis.get_scale())
				Animation.TYPE_POSITION_3D:
					pose[b].origin = anim.position_track_interpolate(track,time)
					if close_loop: pose[b].origin += phase * (anim.position_track_interpolate(track,0.0)-anim.position_track_interpolate(track,anim.length))
				Animation.TYPE_SCALE_3D:
					var scale := anim.scale_track_interpolate(track,time)
					if close_loop: scale += phase * (anim.scale_track_interpolate(track,0.0)-anim.scale_track_interpolate(track,anim.length))
					pose[b].basis = pose[b].basis.orthonormalized().scaled_local(scale)
	_relax_cruising_neck(pose)
	pony.source_pose = pose; pony.corrected_pose = pose; pony.modifier.prepared = pose
	pony.pivot.transform = Transform3D.IDENTITY

func _relax_cruising_neck(pose: Array[Transform3D]) -> void:
	if wings_only or clip not in ["fly", "glide_start", "glide"] or neck_reach >= 1.0: return
	if _neck_bones.size() != 3 or -1 in _neck_bones: return
	var lower := _neck_bones[0]; var upper := _neck_bones[1]; var head := _neck_bones[2]
	var original_head := pose[lower].basis * pose[upper].basis * pose[head].basis
	for b in [lower, upper]:
		var neutral: Quaternion = pony.profile.rest[b].basis.orthonormalized().get_rotation_quaternion()
		var native := pose[b].basis.orthonormalized().get_rotation_quaternion()
		pose[b].basis = Basis(neutral.slerp(native,clampf(neck_reach,0.0,1.0))).scaled_local(pose[b].basis.get_scale())
	# Counter-rotate the head so she continues looking ahead as the neck tucks back.
	pose[head].basis = (pose[lower].basis * pose[upper].basis).inverse() * original_head
