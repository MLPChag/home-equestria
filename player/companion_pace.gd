extends RefCounted
## Opt-in pace matching. Poll nearby moving residents four times a second, not per frame.
## Keep the selected companion while nearby; a pause must not switch to a passing stranger.
const RANGE := 14.0
const DEFAULT_SPEED := 2.2
var enabled := false
var _remaining := 0.0
var _speed := DEFAULT_SPEED
var _companion: Node3D

func toggle() -> void:
	enabled = not enabled
	_remaining = 0.0
	_companion = null
	_speed = DEFAULT_SPEED
	print("[player] Companion pace ", "on" if enabled else "off")

func speed(player: Node3D, delta: float) -> float:
	_remaining -= delta
	if _remaining > 0.0: return _speed
	_remaining = 0.25
	if is_instance_valid(_companion) and player.global_position.distance_squared_to(_companion.global_position) > RANGE * RANGE:
		_companion = null
	if not is_instance_valid(_companion):
		var nearest := RANGE * RANGE
		for actor: Node in player.get_tree().get_nodes_in_group("sim_ponies"):
			if actor == player or not actor is Node3D or actor.get_node_or_null("Navigator") == null: continue
			var velocity: Variant = actor.get("velocity")
			if not velocity is Vector3 or Vector2(velocity.x, velocity.z).length_squared() < 0.01: continue
			var distance := player.global_position.distance_squared_to(actor.global_position)
			if distance < nearest:
				nearest = distance
				_companion = actor
	if is_instance_valid(_companion):
		var nav: Node = _companion.get_node_or_null("Navigator")
		var velocity: Variant = _companion.get("velocity")
		if nav != null and velocity is Vector3 and Vector2(velocity.x, velocity.z).length_squared() >= 0.01:
			# Requested travel pace avoids copying acceleration, corner braking and footstep noise.
			var pace := float(nav.get("pace"))
			var cap := float(nav.get("command_speed_limit"))
			if is_finite(pace) and pace > 0.0: _speed = clampf(minf(pace, cap), 0.15, 4.0)
	else:
		_speed = DEFAULT_SPEED
	return _speed
