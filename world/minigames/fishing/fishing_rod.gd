extends Node3D
## A rod shared by desktop, tracked hands and pony companions. Grip, cast, watch the float,
## lift on a bite, then turn the reel. Its line always queries the real water/solid collision.
signal fish_landed(rod: Node3D, at: Vector3)
const SFX := preload("res://world/audio/interaction_sounds.gd")
const LINE := preload("res://world/minigames/fishing/fishing_line.gd")
var line: RefCounted = LINE.new()
var holder: String = ""
var grip: StaticBody3D
var visual: Node3D
var bobber: MeshInstance3D
var _string: MeshInstance3D
var _material: StandardMaterial3D
var _rest: Transform3D
var _reel: Node3D
var _reel_angle: float = 0
var player_excludes: Array[RID] = []

func _ready() -> void:
	visual = (load("res://world/props/household/fishing-rod.scn") as PackedScene).instantiate(); add_child(visual)
	_reel = visual.find_child("reel crank*",true,false) as Node3D
	grip = StaticBody3D.new(); grip.collision_layer = 2; grip.collision_mask = 0; grip.set_meta("fishing_rod",self); add_child(grip)
	var shape: CapsuleShape3D = CapsuleShape3D.new(); shape.radius = .075; shape.height = .38
	var collider: CollisionShape3D = CollisionShape3D.new(); collider.shape = shape; grip.add_child(collider)
	bobber = MeshInstance3D.new(); var sphere: SphereMesh = SphereMesh.new(); sphere.radius = .045; sphere.height = .09; bobber.mesh = sphere
	var float_material: StandardMaterial3D = StandardMaterial3D.new(); float_material.albedo_color = Color("db6650"); float_material.roughness = .5
	bobber.material_override = float_material; add_child(bobber); bobber.top_level = true
	_material = StandardMaterial3D.new(); _material.albedo_color = Color("e7ddbb"); _material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_string = MeshInstance3D.new(); add_child(_string); _string.top_level = true; _string.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rest = global_transform
	line.rng.randomize(); line.reset(tip()); line.caught.connect(_landed)
	line.changed.connect(func(state: String):
		if state in ["waiting", "bite"]: SFX.play_at(self, "splash", line.bobber))

func tip() -> Vector3: return to_global(Vector3(0,1.45,0))

func take(who: String) -> bool:
	if not holder.is_empty(): return false
	_rest = global_transform; holder = who; grip.collision_layer = 0; line.reset(tip())
	set_physics_process(true)
	SFX.play_at(self, "prop_rod_take")
	return true

func put_back() -> void:
	if not holder.is_empty(): SFX.play_at(self, "prop_rod_return", _rest.origin)
	holder = ""; global_transform = _rest; grip.collision_layer = 2; line.reset(tip())

func cast(direction: Vector3, strength: float = 1.0) -> bool:
	if holder.is_empty() or not line.cast(tip(), direction, strength): return false
	set_physics_process(true)
	SFX.play_event(self, "prop_cast", {"intensity": clampf(strength, .3, 1.0)}, tip())
	return true

func reel(metres: float) -> void:
	if holder.is_empty(): return
	if line.reel(metres,tip()):
		SFX.play_event(self, "prop_reel", {"intensity": clampf(absf(metres) * 2.0, .35, .8)})
		_reel_angle += metres*TAU/1.2
		if is_instance_valid(_reel): _reel.rotation.x = _reel_angle

func _physics_process(delta: float) -> void:
	line.tick(delta,tip(),_sweep)
	bobber.visible = line.state != "ready"
	_string.visible = bobber.visible
	# A rod at rest hides its float: moving the hidden float every tick only re-sent its transform.
	# Racked and uncast, it has nothing to do until take() or cast() wakes it (2026-10-14).
	if not _string.visible:
		if holder.is_empty(): set_physics_process(false)
		return
	bobber.global_position = line.bobber
	var mesh: ImmediateMesh = ImmediateMesh.new(); mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP,_material)
	var start: Vector3 = tip(); var end: Vector3 = line.bobber
	for i in range(13):
		var t: float = i/12.0
		mesh.surface_add_vertex(start.lerp(end,t)+Vector3.DOWN*(sin(t*PI)*(.015 if line.state=="hooked" else .12)))
	mesh.surface_end(); _string.mesh = mesh

func _sweep(from: Vector3, to: Vector3) -> Dictionary:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from,to,1 | (1<<15))
	var excludes: Array[RID] = player_excludes.duplicate()
	excludes.append(grip.get_rid()); query.exclude = excludes; query.hit_back_faces = true
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return {}
	var body: CollisionObject3D = hit.collider as CollisionObject3D
	return {"position":hit.position,"water":body != null and (body.collision_layer & (1<<15)) != 0}

func _landed(at: Vector3) -> void:
	fish_landed.emit(self,at)
