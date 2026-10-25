extends RefCounted
## Bodies turned to each other for a pony conversation (dev 2026-10-14: "they LOOK at each other and be
## polite and make eye contact"; Twilight greeted Lemon Hearts while they faced opposite ways).
## Two ponies face each other; three or more face the circle centre. The navigator's face_point turns
## the body (it also holds her where she stands); the director's conversation targets keep heads and
## eyes on whoever is speaking. Seated, lying, held or walking-company ponies keep their posture and
## only look. On release a face point this helper wrote goes back to its earlier owner's value only
## while that owner still commands her; otherwise it is cleared, so no stale point freezes a pony.
## No per-frame work: the director refreshes targets a few times a second while a chat runs.

const SETTLE_DEGREES := 25.0
const REFRESH_SECONDS := 0.25

var members: Array[String] = []
var _saved: Dictionary = {}    # id -> {"point": face_point before, "owner": command_owner before}
var _written: Dictionary = {}  # id -> last face_point written here
var _refresh := 0.0


func active() -> bool:
	return not members.is_empty()


func begin(ids: Array[String], characters: Dictionary) -> void:
	release(characters)
	if ids.size() < 2: return
	members = ids.duplicate()
	for id in members:
		var nav := _nav(characters, id)
		if nav != null: _saved[id] = {"point": nav.face_point, "owner": str(nav.command_owner)}
	_apply(characters)


## Called from the director's frame loop while a conversation is active.
func tick(delta: float, characters: Dictionary) -> void:
	if members.is_empty(): return
	_refresh -= delta
	if _refresh > 0.0: return
	_refresh = REFRESH_SECONDS
	_apply(characters)


## Everyone who can turn is turned toward her partner or the circle (within SETTLE_DEGREES) and no
## longer walking up.
func settled(characters: Dictionary) -> bool:
	for id in members:
		var actor := _node(characters, id)
		if actor == null or not can_turn(actor): continue
		var nav := _nav(characters, id)
		if nav != null and nav.get("_has_target") == true: return false
		var goal := target_for(id, characters)
		if not goal.is_finite(): continue
		var toward := goal - actor.global_position
		toward.y = 0.0
		var forward := -actor.global_basis.z
		forward.y = 0.0
		if toward.length() < 0.3 or forward.length() < 0.01: continue
		if rad_to_deg(forward.angle_to(toward)) > SETTLE_DEGREES: return false
	return true


func release(characters: Dictionary) -> void:
	for id: String in _written.keys():
		var nav := _nav(characters, id)
		if nav == null: continue
		var point: Vector3 = nav.face_point
		var mine: Vector3 = _written[id]
		if not (point.is_finite() and point.distance_to(mine) < 0.01): continue
		var saved: Dictionary = _saved.get(id, {})
		var owner := str(saved.get("owner", ""))
		var earlier: Vector3 = saved.get("point", Vector3.INF)
		nav.face_point = earlier if owner != "" and str(nav.command_owner) == owner and earlier.is_finite() else Vector3.INF
	members.clear()
	_saved.clear()
	_written.clear()
	_refresh = 0.0


## Where this member's body should face: her partner, or the centre of a larger circle.
func target_for(id: String, characters: Dictionary) -> Vector3:
	if members.size() == 2:
		var partner: Node3D = _node(characters, members[1] if members[0] == id else members[0])
		return partner.global_position if partner != null else Vector3.INF
	var centre := Vector3.ZERO
	var count := 0
	for other in members:
		var node := _node(characters, other)
		if node == null: continue
		centre += node.global_position
		count += 1
	return centre / count if count >= 2 else Vector3.INF


## Standing on her own hooves and free to turn: never a seated, lying, held or flying pony.
static func can_turn(actor: Node3D) -> bool:
	if actor.has_method("is_held") and actor.is_held(): return false
	if actor.has_meta("seated") or actor.get("sleeping") == true: return false
	if actor.has_method("posture_status") and str(actor.posture_status().get("kind", "stand")) != "stand": return false
	var flight: Variant = actor.get("flight")
	if flight != null and flight is Object and flight.has_method("active") and flight.active(): return false
	return true


func _apply(characters: Dictionary) -> void:
	for id in members:
		var actor := _node(characters, id)
		var nav := _nav(characters, id)
		if actor == null or nav == null or not can_turn(actor): continue
		var goal := target_for(id, characters)
		if not goal.is_finite(): continue
		var flat := goal - actor.global_position
		flat.y = 0.0
		if flat.length() < 0.3: continue
		nav.face_point = goal
		_written[id] = goal


static func _node(characters: Dictionary, id: String) -> Node3D:
	var node: Variant = characters.get(id, {}).get("node")
	return node if node is Node3D and is_instance_valid(node) and (node as Node3D).is_inside_tree() else null


static func _nav(characters: Dictionary, id: String) -> Node:
	var actor := _node(characters, id)
	if actor == null: return null
	var nav := actor.get_node_or_null("Navigator")
	return nav if nav != null and "face_point" in nav else null
