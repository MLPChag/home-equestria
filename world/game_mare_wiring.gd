extends RefCounted
## Wires each new pony to the player: grabber, cuddle input, kisser, head guard, boops, AI registration and her schedule.
## Split out of game.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning game node; shared state stays there.

const GRABBER := preload("res://player/pony_grabber.gd")

var host: Node3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


## Grip near her chest grips picks her up (same wiring as the lab); her
## hoofsteps feed the ambience. Runs after she exists, not in _spawn_player.
func _wire_mare(mare: Node) -> void:
	if mare.has_method("set_body_scale") and not is_equal_approx(host.pony_scale_for(mare), 1.0): mare.set_body_scale(host.pony_scale_for(mare))
	if is_instance_valid(host.inventory) and "boop_node" in mare and is_instance_valid(mare.boop_node):
		mare.boop_node.hand_sampler=host.inventory.hand_sample
	var player_body: Node3D = host.player.find_child("Body", true, false)
	if player_body == null: player_body = host.player
	if player_body.get_node_or_null("NavObstacle") == null:
		var obstacle := NavigationObstacle3D.new()
		obstacle.name = "NavObstacle"; obstacle.radius = .4; obstacle.height = 1.8
		obstacle.avoidance_enabled = true; player_body.add_child(obstacle)
	var ambience: Node = host.get_node_or_null("Ambience")
	if ambience != null:
		ambience.connect_pony(mare)
	# One grabber for everypony: it targets whoever has the nearest free grip.
	if host.grabber == null:
		host.grabber = GRABBER.new()
		host.grabber.name = "PonyGrabber"
		host.grabber.debug_log = true
		host.add_child(host.grabber)
		host.grabber.setup(mare, host.player.find_child("PhysicsHandLeft", true, false),
			host.player.find_child("PhysicsHandRight", true, false),
			host.player.find_child("XRControllerLeft", true, false),
			host.player.find_child("XRControllerRight", true, false),
			host._find_camera(host.player), host.player.find_child("AnonBody", true, false))
		if is_instance_valid(host.inventory): host.inventory.pony_grabber = host.grabber
	else:
		host.grabber.add_pony(mare)
	if host.cuddle_input==null:
		host.cuddle_input=preload("res://world/relationships/cuddle/player_input.gd").new()
		host.cuddle_input.name="CuddleInput";host.add_child(host.cuddle_input);host.cuddle_input.setup(host)
		host.grabber.cuddle_input=host.cuddle_input
	host.cuddle_input.add_pony(mare)
	if host.director != null and "ai_profile" in mare:
		host.director.register_character(mare, String(mare.get("ai_profile")))
	# Her day (PonyPonyParadise schedule) against the zone's painted hot spots.
	var identity: Resource = mare.get("identity") if "identity" in mare else null
	if identity != null:
		if is_instance_valid(host.relationship_runtime): host.relationship_runtime.register_actor(mare)
		if is_instance_valid(host.social): host.social.register_actor(String(identity.id), mare)
		var schedule := PonySchedule.new()
		schedule.name = "Schedule"
		schedule.schedule_path = "res://world/ai/schedules/%s.json" % identity.id
		mare.add_child(schedule)
		# The map layers of the zone she stands in (not whichever zone happened to load
		# first): with streaming v2 several zones are resident around the plaza.
		var nav := mare.get_node_or_null("Navigator")
		var resident_layers: MapLayers = nav.map_layers() if nav != null else null
		if resident_layers == null:
			var zone_id: String = ZoneManager.zone_contains(mare.global_position)
			if zone_id != "": resident_layers = MapLayers.load_zone(zone_id)
		if resident_layers != null: schedule.bind_layers(resident_layers)
	if mare.has_method("arm_boop"):
		mare.arm_boop(host.player.find_child("PhysicsHandLeft", true, false),
			host.player.find_child("PhysicsHandRight", true, false),
			host.player.find_child("XRControllerLeft", true, false),
			host.player.find_child("XRControllerRight", true, false))
	if host.kisser == null:
		host.kisser = preload("res://player/pony_kisser.gd").new()
		host.kisser.name = "PonyKisser"
		host.add_child(host.kisser)
		host.kisser.setup(host._find_camera(host.player), host.player.get_node("Body") if host.xr_active else host.player,
			host.player.find_child("XRControllerLeft", true, false))
	host.kisser.add_pony(mare)
	if host.pony_head_guard==null:
		host.pony_head_guard=preload("res://player/pony_head_guard.gd").new()
		host.pony_head_guard.setup(host._find_camera(host.player),host.player.get_node("Body") if host.xr_active else host.player)
		host.add_child(host.pony_head_guard)
	host.pony_head_guard.add_pony(mare)
	print("[game] pony grabber armed: hands %s/%s controllers %s/%s" % [
		host.player.find_child("PhysicsHandLeft", true, false) != null,
		host.player.find_child("PhysicsHandRight", true, false) != null,
		host.player.find_child("XRControllerLeft", true, false) != null,
		host.player.find_child("XRControllerRight", true, false) != null])
