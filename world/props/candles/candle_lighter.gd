extends Node
## Lights and snuffs candle clusters (candle_cluster.gd): VR, touch a wick with a fingertip and
## press the trigger; desktop, look at a candle within reach and press E. Offers the usual hints.
const REACH := 0.06     # fingertip to wick, metres
const DESK_REACH := 2.2
var inventory: Node
var _trigger := {"left": true, "right": true}

func _ready() -> void:
	add_to_group("interaction_hint_sources")
	process_physics_priority = -45

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(inventory) or inventory._desktop: return
	for side: String in ["left", "right"]:
		var sample: Dictionary = inventory.hand_sample(side)
		var pulled: bool = sample.get("active", false) and float(sample.get("trigger", 0.0)) > (0.45 if _trigger[side] else 0.75)
		var near := _touched(Vector3(sample.get("tip", Vector3.INF))) if sample.get("active", false) else null
		# A fingertip at a wick owns the trigger: the seat/bed trigger must not also sit Anon down.
		var hand: Node = inventory.hands.get(side)
		if is_instance_valid(hand):
			if near != null: hand.set_meta("candle_reach", true)
			elif hand.has_meta("candle_reach"): hand.remove_meta("candle_reach")
		if pulled and not _trigger[side]:
			var cluster := near
			if cluster != null:
				cluster.toggle()
				inventory._haptic(side)
		_trigger[side] = pulled

func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(inventory) or not inventory._desktop: return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var cluster := _aimed()
		if cluster != null:
			cluster.toggle()
			get_viewport().set_input_as_handled()

func _touched(tip: Vector3) -> Node3D:
	if not tip.is_finite(): return null
	for cluster: Node3D in get_tree().get_nodes_in_group("candle_clusters"):
		if cluster.global_position.distance_squared_to(tip) > 0.09: continue
		if cluster.nearest_wick(tip).distance_to(tip) <= REACH: return cluster
	return null

func _aimed() -> Node3D:
	var camera: Camera3D = inventory.camera
	if not is_instance_valid(camera): return null
	var eye := camera.global_position
	var forward := -camera.global_basis.z
	var best: Node3D = null
	var best_angle := deg_to_rad(5.0)
	for cluster: Node3D in get_tree().get_nodes_in_group("candle_clusters"):
		var to: Vector3 = cluster.global_position + Vector3.UP * 0.08 - eye
		if to.length() > DESK_REACH: continue
		var angle := forward.angle_to(to)
		if angle < best_angle: best = cluster; best_angle = angle
	return best

func interaction_hint() -> Dictionary:
	if not is_instance_valid(inventory): return {}
	if inventory._desktop:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return {}
		var aimed := _aimed()
		if aimed == null: return {}
		return {"target": aimed, "point": aimed.global_position, "text": "[E] " + ("Snuff" if aimed.lit else "Light") + " candles"}
	for side: String in ["right", "left"]:
		var sample: Dictionary = inventory.hand_sample(side)
		if not sample.get("active", false): continue
		var cluster := _touched(Vector3(sample.get("tip", Vector3.INF)))
		if cluster != null:
			return {"target": cluster, "point": cluster.global_position, "text": "Trigger · " + ("snuff" if cluster.lit else "light") + " candles"}
	return {}
