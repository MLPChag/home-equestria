extends RefCounted
## One observed event per pickup, including desktop and independent VR hands.
var elapsed := 0.0
var start := Vector3.ZERO
var head_start := Vector3.ZERO
var active := false
var sent := false
func update(actor: Node3D, delta: float) -> void:
	if not actor.get("_held"):
		active = false; elapsed = 0.0; sent = false
		return
	var camera: Camera3D = preload("res://world/player_view.gd").camera(actor)
	var head: Vector3 = camera.global_position if camera != null else actor.global_position
	if not active:
		active = true; start = actor.global_position; head_start = head
	elapsed += delta
	if sent: return
	var moved: bool = Vector2(head.x-head_start.x, head.z-head_start.z).length() >= 1.5 and actor.global_position.distance_to(start) >= 1.5
	if elapsed >= 5.0 or moved:
		sent = true
		actor.emit_signal("physical_reaction", "carried_away" if moved else "carried")
