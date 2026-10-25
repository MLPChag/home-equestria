extends Node
## Relationship-selected rest contact, layered through the existing bounded cuddle solver.
const SESSION := preload("res://world/relationships/cuddle/session.gd")
var mare: CharacterBody3D
var partner: Node3D
var surface: Node3D
var session: Node
var _owns_session := false
var _mode := "none"
var _scan := 0.0
var _retry := 0.0
var shoulder_target := Vector3.INF
var contact_distance := INF
const QUIET_SECONDS := 60.0
var _quiet := 0.0
var _owns_sleep := false
var _sleep_style := ""
var _player_was_asleep := false
var skull_center := Vector3.INF
var skull_radius := 0.0
var head_contact := Vector3.INF
var contact_kind := "skull"
var solver_target_distance := INF
var _shoulder_avatar: Node3D
var _shoulder_cache: Dictionary = {}
var _shoulder_bones: Dictionary = {}
var _cheek_bones: Dictionary = {}
var legacy_contact_distance := INF
var _cloth_surface:RefCounted
var _cloth_avatar:Node3D

func _cache_shoulders() -> void:
	if not is_instance_valid(_shoulder_avatar) or not _shoulder_avatar.is_inside_tree(): return
	var skeleton: Skeleton3D = _shoulder_avatar._skeleton
	if not is_instance_valid(skeleton) or not skeleton.is_inside_tree(): return
	for name: String in _shoulder_bones:
		var index: int = _shoulder_bones[name]
		_shoulder_cache[name] = (skeleton.global_transform * skeleton.get_bone_global_pose(index)).origin

func diagnostic_state() -> Dictionary:
	var report := {"mode": _mode, "target": var_to_str(shoulder_target), "gap": contact_distance, "legacy_proxy_gap": legacy_contact_distance, "solver_gap": solver_target_distance, "head_contact_kind": contact_kind, "cloth_vertices": _cloth_surface._starts.size()-1 if _cloth_surface!=null else 0, "cloth_queries": _cloth_surface.query_count if _cloth_surface!=null else 0, "head_rebuilds": _cloth_surface.rebuild_count if _cloth_surface!=null else 0, "head_rebuild_usec": _cloth_surface.rebuild_usec if _cloth_surface!=null else 0, "surface_bind_usec": _cloth_surface.bind_usec if _cloth_surface!=null else 0, "envelope_rebuilds": _cloth_surface.envelope_rebuilds if _cloth_surface!=null else 0, "contact_cache_hits": _cloth_surface.cache_hits if _cloth_surface!=null else 0, "head_contact": var_to_str(head_contact), "session": is_instance_valid(session)}
	if is_instance_valid(session):
		report.merge({"enabled": session.enabled, "blend": session.blend, "cooldown_ms": session._cooldown - Time.get_ticks_msec(), "can_begin": session.can_begin(partner), "support_matches": session.support == surface, "held": mare.is_held(), "speed": mare.actual_speed, "willing": session.willing(), "posture": mare.posture_status(), "origin_gap": mare.global_position.distance_to(session._origin), "partner_gap": session._gap(partner), "grips": session.grips.keys()})
	var avatar: Node3D = partner.find_child("CouchAnonBody", true, false)
	if avatar != null:
		report.avatar_transform = var_to_str(avatar.global_transform)
		report.head_target = var_to_str(avatar._head_target.global_transform)
		report.hip_target = var_to_str(avatar._hip_target.global_transform)
		var bones := {}
		for name: String in ["LeftUpperArm", "RightUpperArm", "LeftShoulder", "RightShoulder"]:
			var index: int = avatar._skeleton.find_bone(name)
			if index >= 0: bones[name] = var_to_str(avatar._skeleton.global_transform * avatar._skeleton.get_bone_global_pose(index))
		report.shoulder_bones_outside_modifier = bones
	return report

func _shoulder_point(camera: Camera3D, facing: Basis, side: float) -> Vector3:
	var avatar: Node3D = _shoulder_avatar if is_instance_valid(_shoulder_avatar) else partner.find_child("CouchAnonBody", true, false)
	if avatar == null: avatar = partner.find_child("AnonBody", true, false)
	if avatar != null and is_instance_valid(avatar.get("_skeleton")):
		var skeleton: Skeleton3D = avatar._skeleton
		if _shoulder_avatar != avatar:
			if is_instance_valid(_shoulder_avatar) and is_instance_valid(_shoulder_avatar.get("_skeleton")):
				var old: Skeleton3D = _shoulder_avatar._skeleton
				if old.skeleton_updated.is_connected(_cache_shoulders): old.skeleton_updated.disconnect(_cache_shoulders)
			_shoulder_avatar = avatar; _shoulder_cache.clear(); _shoulder_bones.clear()
			for name: String in ["LeftUpperArm", "RightUpperArm", "LeftShoulder", "RightShoulder"]:
				var index := skeleton.find_bone(name)
				if index >= 0: _shoulder_bones[name] = index
			# SkeletonModifier3D poses are temporary; capture after modifiers and before
			# Godot restores the standing source pose, exactly as Anon's hand cache does.
			if not skeleton.skeleton_updated.is_connected(_cache_shoulders): skeleton.skeleton_updated.connect(_cache_shoulders)
		var best := Vector3.INF
		var best_distance := INF
		var anchors: Array[Vector3] = []
		for name: String in ["LeftUpperArm", "RightUpperArm"]:
			if _shoulder_cache.has(name): anchors.append(_shoulder_cache[name])
		if anchors.is_empty():
			for name: String in ["LeftShoulder", "RightShoulder"]:
				if _shoulder_cache.has(name): anchors.append(_shoulder_cache[name])
		for point: Vector3 in anchors:
			var distance := point.distance_to(mare.listen_point())
			if distance < best_distance: best = point; best_distance = distance
		if best.is_finite():
			var radius := .075
			if _mode == "snuggle" and surface.rest_word() == "bed" and mare.get_meta("shared_nap_on_top", false) and _shoulder_cache.has("LeftUpperArm") and _shoulder_cache.has("RightUpperArm"):
				# Partners may rest across the chest. Use the same .16m torso
				# support radius as the existing cuddle contact model.
				var shoulders: Vector3 = (_shoulder_cache.LeftUpperArm + _shoulder_cache.RightUpperArm) * .5
				best = avatar._hip_target.global_position.lerp(shoulders, .65)
				radius = .16
			var boop: Node = mare.get("boop_node")
			if boop != null and boop._head_bone >= 0:
				var head: Transform3D = boop.head_skeleton.global_transform * boop.head_skeleton.get_bone_global_pose(boop._head_bone)
				skull_center = head * boop.SKULL_LOCAL
				skull_radius = boop.SKULL_RADIUS * head.basis.get_scale().x
				var outward := skull_center - best
				if outward.length_squared() < .00001: outward = Vector3.UP
				head_contact = skull_center - outward.normalized() * skull_radius
				contact_kind = "skull"
				var gap := absf(head_contact.distance_to(best) - radius)
				# Lower-cheek bones are the visible face's own contact landmarks.
				# A cheek can rest on a shoulder even while the skull centre remains
				# beyond neck reach; do not confuse a grab marker with skin contact.
				if _cheek_bones.is_empty():
					for name: String in boop.CHEEK_BONES.values():
						var index: int = boop.head_skeleton.find_bone(name)
						if index >= 0: _cheek_bones[name] = index
				for name: String in _cheek_bones:
					var bone: int = _cheek_bones[name]
					var cheek: Vector3 = (boop.head_skeleton.global_transform * boop.head_skeleton.get_bone_global_pose(bone)).origin
					var cheek_gap := absf(cheek.distance_to(best) - radius)
					if cheek_gap < gap:
						gap = cheek_gap; head_contact = cheek; contact_kind = name
				outward = head_contact - best
				var legacy_target:Vector3=best + outward.normalized() * radius if outward.length_squared() > .00001 else best + Vector3.UP * radius
				legacy_contact_distance=head_contact.distance_to(legacy_target)
				if is_instance_valid(avatar):
					if _cloth_avatar!=avatar:
						if _cloth_surface!=null:_cloth_surface.finish()
						_cloth_avatar=avatar
						_cloth_surface=preload("res://world/relationships/posed_shoulder_surface.gd").new()
						if not _cloth_surface.bind(avatar,mare):_cloth_surface.finish();_cloth_surface=null
					if _cloth_surface!=null:
						var actual:Dictionary=_cloth_surface.contact()
						if not actual.is_empty():
							head_contact=actual.head;contact_kind=actual.kind
							return actual.shoulder
				return legacy_target
			return best + Vector3.UP * .15
	return camera.global_position - Vector3.UP * .12 + facing.x * side * .22 + facing.z * .14

static func closeness(actor: Node) -> String:
	if not is_instance_valid(actor) or not actor.has_meta("relationship_runtime"): return "none"
	var runtime: Node = actor.get_meta("relationship_runtime")
	if not is_instance_valid(runtime) or not runtime.bonds.has_method("rest_closeness"): return "none"
	return str(runtime.bonds.rest_closeness(str(actor.get_meta("relationship_id", ""))))

static func attach(actor: CharacterBody3D, body: Node3D, rest: Node3D) -> Node:
	var existing := actor.get_node_or_null("SharedNapCompany")
	if existing != null: return existing
	var node := load("res://world/relationships/shared_nap_company.gd").new() as Node
	node.name = "SharedNapCompany"; node.mare = actor; node.partner = body; node.surface = rest
	actor.add_child(node)
	return node

func _physics_process(delta: float) -> void:
	if not is_instance_valid(mare) or not is_instance_valid(partner) or not is_instance_valid(surface): finish(); return
	var nav := mare.get_node_or_null("Navigator")
	var mode := closeness(mare)
	if mode == "none" or not partner.get_meta("couch_sleeping", false) or (nav != null and "reserved_by" in nav and not str(nav.reserved_by).is_empty()): finish(); return
	if mode != _mode and is_instance_valid(session):
		for solver: Node in session.solvers:
			if solver.targets.has("fore_L_5") and solver.targets.fore_L_5.get("shared_nap_target", false): solver.targets.erase("fore_L_5")
	_update_sleep(delta)
	_mode = mode
	mare.set_meta("shared_nap_closeness", mode)
	if mode == "beside":
		_release_cloth_surface()
		_release_targets()
		if _owns_session and is_instance_valid(session): session.end(); _owns_session = false
		return
	if not is_instance_valid(session):
		session = mare.get_node_or_null("CuddleSession")
		if session == null:
			session = SESSION.new(); session.name = "CuddleSession"; session.mare = mare; mare.add_child(session)
	_retry = maxf(0.0, _retry - delta)
	if is_instance_valid(session) and not session.enabled and _retry <= 0.0:
		_retry = .5
		if session.begin(partner, surface): _owns_session = true
	if not is_instance_valid(session) or not session.enabled or session.support != surface: return
	if mare.get_meta("shared_nap_on_top",false):
		# Her body rests on the player; preserve the native curled sleep instead
		# of forcing the higher head down onto a lower shoulder.
		_release_targets()
		return
	_scan -= delta
	if _scan > 0.0: return
	_scan = .05
	# Head and foreleg targets share the conservative production CCD/joint constraints.
	# Tracked head/controller local transforms are never changed by this company pose.
	var camera: Camera3D = preload("res://world/player_view.gd").camera(partner)
	if camera == null or not partner.is_ancestor_of(camera):
		var cameras: Array[Node] = partner.find_children("*", "Camera3D", true, false)
		camera = cameras[0] as Camera3D if not cameras.is_empty() else null
	if camera == null: return
	var facing: Basis = surface.rest_frame(partner.get("seat")).global_basis.orthonormalized()
	var side := signf((mare.global_position - camera.global_position).dot(facing.x))
	if side == 0.0: side = 1.0
	head_contact = Vector3.INF
	var shoulder := _shoulder_point(camera, facing, side)
	if not shoulder.is_finite(): return
	shoulder_target = shoulder
	for solver: Node in session.solvers:
		if solver.tail: continue
		for id: String in (["head", "fore_L_5"] if mode == "snuggle" else ["head"]):
			if not solver.regions.has(id): continue
			var player_held := false
			for grip: Dictionary in session.grips.values():
				if grip.solver == solver and grip.id == id: player_held = true
			if player_held:
				if id == "head": mare.set_meta("shared_nap_head_supported", false)
				continue
			var at: Vector3 = solver.point(id)
			var goal := shoulder - Vector3.UP * .13 - facing.x * side * .10
			if id == "head":
				goal = at + shoulder - head_contact if head_contact.is_finite() else shoulder
				contact_distance = head_contact.distance_to(shoulder) if head_contact.is_finite() else at.distance_to(shoulder)
				solver_target_distance = at.distance_to(goal)
			if not solver.targets.has(id):
				if solver.take(id, Transform3D(Basis.IDENTITY, at)): solver.targets[id].shared_nap_target = true
			if id == "head": mare.set_meta("shared_nap_head_supported", solver.targets.get(id, {}).get("shared_nap_target", false))
			if solver.targets.has(id):
				if solver.targets[id].get("shared_nap_target", false): solver.targets[id].goal = at + (goal - at).limit_length(.22)

func _release_targets() -> void:
	if is_instance_valid(mare) and mare.has_meta("shared_nap_head_supported"): mare.remove_meta("shared_nap_head_supported")
	if not is_instance_valid(session): return
	for solver: Node in session.solvers:
		for id: String in solver.targets.keys():
			if solver.targets[id].get("shared_nap_target", false): solver.release(id)

func _release_cloth_surface()->void:
	if _cloth_surface!=null:_cloth_surface.finish()
	_cloth_surface=null;_cloth_avatar=null

func finish() -> void:
	_release_cloth_surface()
	_wake_owned_sleep()
	_release_targets()
	if _owns_session and is_instance_valid(session): session.end()
	if is_instance_valid(mare) and mare.has_meta("shared_nap_closeness"): mare.remove_meta("shared_nap_closeness")
	queue_free()

func _exit_tree() -> void:
	_release_cloth_surface()
	_wake_owned_sleep()
	_release_targets()
	if _owns_session and is_instance_valid(session): session.end()
	if is_instance_valid(mare) and mare.has_meta("shared_nap_closeness"): mare.remove_meta("shared_nap_closeness")

func _update_sleep(delta: float) -> void:
	var asleep: bool = partner.get_meta("shared_rest_sleeping", false)
	var handled: bool = is_instance_valid(session) and not session.grips.is_empty()
	var quiet: bool = not handled and not mare.get("conversing") and not mare.is_speaking()
	_quiet = _quiet + delta if quiet else 0.0
	if _player_was_asleep and not asleep: player_woke()
	_player_was_asleep = asleep
	if not quiet:
		_wake_owned_sleep()
	elif (asleep or _quiet >= QUIET_SECONDS) and not mare.sleeping:
		_sleep_style = mare.sleep_style
		_owns_sleep = true
		mare.sleep_style = "head_down"
		mare.sleeping = true

## The sleep service calls this before its waking autosave, not one physics tick later.
func player_woke() -> void:
	_quiet = 0.0
	_player_was_asleep = false
	_wake_owned_sleep()

func _wake_owned_sleep() -> void:
	if _owns_sleep and is_instance_valid(mare):
		mare.sleeping = false
		mare.sleep_style = _sleep_style
	_owns_sleep = false
