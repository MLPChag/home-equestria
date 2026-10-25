extends "res://world/relationships/shared_nap_grass.gd"
## An unfolded owned blanket. Ground rest owns seating/pose; picnic owns food and packing.
const SIZE := Vector2(2.4, 2.0)
const GRID := Vector2i(12, 10)
const POINT_COUNT := (GRID.x + 1) * (GRID.y + 1)
var heights: Array = []
var _cloth_support: StaticBody3D
var loan_token := ""
var inventory: Node
var _cloth: MeshInstance3D

func _ready() -> void:
	temporary = false
	seat_offsets = [Vector3(-.7, .02, .12), Vector3(.7, .02, .12)]
	super._ready()
	autonomous = false # Nearby ponies join only through a generated accepted invitation.
	layout()
	for seat: Node3D in seats:
		seat.for_player = true
		seat.add_to_group("player_seats")
	for seat: Node3D in seats: seat.position.y = height_at(Vector2(seat.position.x, seat.position.z)) + .025
	_build_cloth()
	add_to_group("picnic_blankets")

func _build_cloth() -> void:
	_cloth = MeshInstance3D.new(); _cloth.name = "PicnicFabric"
	var builder := SurfaceTool.new(); builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in GRID.y:
		for x in GRID.x:
			for corner: Vector2i in [Vector2i(x, z), Vector2i(x, z + 1), Vector2i(x + 1, z), Vector2i(x + 1, z), Vector2i(x, z + 1), Vector2i(x + 1, z + 1)]:
				var uv := Vector2(float(corner.x) / GRID.x, float(corner.y) / GRID.y)
				builder.set_uv(uv)
				builder.set_normal(_local_normal(Vector2((uv.x - .5) * SIZE.x, (uv.y - .5) * SIZE.y)))
				builder.add_vertex(Vector3((uv.x - .5) * SIZE.x, _vertex_height(corner.x, corner.y), (uv.y - .5) * SIZE.y))
	var mesh: ArrayMesh = builder.commit()
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode cull_disabled;
void fragment() {
	vec2 cells = floor(UV * vec2(12.0, 10.0));
	float checked = mod(cells.x + cells.y, 2.0);
	vec3 cream = vec3(0.90, 0.80, 0.64);
	vec3 red = vec3(0.58, 0.20, 0.18);
	float border = step(0.035, UV.x) * step(0.035, UV.y) * step(UV.x, 0.965) * step(UV.y, 0.965);
	ALBEDO = mix(cream, mix(cream, red, checked * 0.78), border);
	ROUGHNESS = 0.98;
}
"""
	var material := ShaderMaterial.new(); material.shader = shader
	mesh.surface_set_material(0, material); _cloth.mesh = mesh; add_child(_cloth)
	# Collision follows the same tessellation: food and bodies use the draped surface.
	_cloth_support = StaticBody3D.new(); _cloth_support.name = "BlanketSupport"; _cloth_support.collision_layer = 1; _cloth_support.collision_mask = 0
	var collision := CollisionShape3D.new(); collision.shape = mesh.create_trimesh_shape()
	(collision.shape as ConcavePolygonShape3D).backface_collision = true
	_cloth_support.add_child(collision); add_child(_cloth_support)

func _vertex_height(x: int, z: int) -> float:
	return float(heights[z * (GRID.x + 1) + x]) if heights.size() == POINT_COUNT else 0.0

## Match the two triangle planes, rather than bilinear interpolation across their diagonal.
func height_at(point: Vector2) -> float:
	var grid_point: Vector2 = (point / SIZE + Vector2(.5, .5)) * Vector2(GRID)
	grid_point = grid_point.clamp(Vector2.ZERO, Vector2(GRID))
	var x: int = mini(floori(grid_point.x), GRID.x - 1)
	var z: int = mini(floori(grid_point.y), GRID.y - 1)
	var tx: float = grid_point.x - x; var tz: float = grid_point.y - z
	var a: float = _vertex_height(x, z); var b: float = _vertex_height(x + 1, z)
	var c: float = _vertex_height(x, z + 1); var d: float = _vertex_height(x + 1, z + 1)
	return a + (b - a) * tx + (c - a) * tz if tx + tz <= 1.0 else d + (c - d) * (1.0 - tx) + (b - d) * (1.0 - tz)

func surface_point(point: Vector2) -> Vector3:
	return to_global(Vector3(point.x, height_at(point), point.y))

func _local_normal(point: Vector2) -> Vector3:
	var dx := Vector3(.02, height_at(point + Vector2(.01, 0)) - height_at(point - Vector2(.01, 0)), 0)
	var dz := Vector3(0, height_at(point + Vector2(0, .01)) - height_at(point - Vector2(0, .01)), .02)
	return dz.cross(dx).normalized()

func surface_normal(point: Vector2) -> Vector3:
	return global_basis * _local_normal(point)

func pick_shape() -> ConvexPolygonShape3D:
	var points := PackedVector3Array()
	for z in range(GRID.y + 1):
		for x in range(GRID.x + 1):
			var at := Vector3((float(x) / GRID.x - .5) * SIZE.x, _vertex_height(x, z), (float(z) / GRID.y - .5) * SIZE.y)
			points.append(at); points.append(at - Vector3.UP * .012)
	var shape := ConvexPolygonShape3D.new(); shape.points = points
	return shape


## A generated, accepted meal plan is required by the caller. This claims only a free seat.
func accept_meal(actor: Node3D, plan_id: String = "") -> bool:
	var seating: Node = get_tree().get_first_node_in_group("pony_seating")
	var nav: Node = actor.get_node_or_null("Navigator") if is_instance_valid(actor) else null
	if seating == null or not seating._ready_done or nav == null or actor.get("sleeping") == true or actor.get("_held") == true: return false
	if not str(nav.get("reserved_by")).is_empty() or actor.global_position.distance_to(global_position) > 3.5: return false
	if not (nav.command_owner.is_empty() or nav.command_owner.begins_with("life:") or nav.command_owner.begins_with("bond:")): return false
	if actor.has_method("action_interruption_reason") and not actor.action_interruption_reason().is_empty(): return false
	if _ponies.has(actor.get_instance_id()): return true
	for seat: Node3D in seats:
		if not seat.free_for(actor): continue
		var token: String = "leisure:picnic:" + loan_token
		var previous := {"owner": nav.command_owner, "wander": nav.wander_enabled, "style": actor.sleep_style}
		var rest := {"posture": "sit", "owner": token, "front": approach(seat), "rest": pony_transform(seat), "couch": self}
		if not seating.sit(actor, 3.5, seat, rest): return false
		nav.command_owner = token
		_ponies[actor.get_instance_id()] = {"actor": actor, "seat": seat, "previous": previous, "token": token, "elapsed": 0.0, "sleep": false, "waking": false, "meal_plan": plan_id, "meal_complete": false}
		return true
	return false

## Finished meals can linger while Anon remains; a cancelled/replaced invitation
## or his departure releases only this picnic's seating, never a newer command.
func maintain_meals(active_plans: Dictionary, player_here: bool) -> void:
	for id: int in _ponies.keys():
		var entry: Dictionary = _ponies[id]
		if not entry.has("meal_plan"): continue # A separately invited nap owns itself.
		var actor: Node3D = entry.actor if is_instance_valid(entry.actor) else null
		var pony_id: String = str(actor.get_meta("relationship_id", "")) if actor != null else ""
		var plan_id: String = str(active_plans.get(pony_id, ""))
		if player_here and ((not plan_id.is_empty() and plan_id == entry.meal_plan) or (entry.meal_complete and plan_id.is_empty())): continue
		var nav: Node = actor.get_node_or_null("Navigator") if actor != null else null
		_release_pony(id, nav != null and nav.command_owner == entry.token)

func complete_meal(actor: Node3D, plan_id: String) -> void:
	if not is_instance_valid(actor): return
	var entry: Dictionary = _ponies.get(actor.get_instance_id(), {})
	if entry.get("meal_plan", "") == plan_id: entry.meal_complete = true

func occupied() -> bool:
	for seat: Node3D in seats:
		if not seat.free_for(): return true
	return not _ponies.is_empty()

func rest_word() -> String: return "picnic blanket"
func rest_frame(seat: Node3D) -> Node3D: return seat
func sleep_eye(seat: Node3D) -> Vector3: return seat.to_global(Vector3(0, .28, -.28))
func rest_floor(seat: Node3D) -> float: return seat.global_position.y + .12
func rest_contains(seat: Node3D, head: Vector3) -> bool: return head.distance_to(sleep_eye(seat)) < 1.1
func touch_zone(point: Vector3) -> bool:
	var at := to_local(point)
	return absf(at.x) <= SIZE.x * .5 and absf(at.z) <= SIZE.y * .5 and absf(at.y - height_at(Vector2(at.x, at.z))) < .3
func contains(point: Vector3, height := .5) -> bool:
	var at := to_local(point)
	return absf(at.x) <= SIZE.x * .5 + .04 and absf(at.z) <= SIZE.y * .5 + .04 and at.y - height_at(Vector2(at.x, at.z)) > -.06 and at.y - height_at(Vector2(at.x, at.z)) < height

func approach(seat: Node3D) -> Vector3:
	# Approach from the clear ground beside the nearest edge, as normal furniture does.
	# Asking the ground navigator to stand on the thin cloth support can create a
	# duplicate floor/ceiling column before Seating takes over the boarding arc.
	var local: Vector3 = to_local(seat.global_position)
	local.x = (1.0 if local.x >= 0.0 else -1.0) * (SIZE.x * .5 + .35)
	local.y = height_at(Vector2(local.x, local.z))
	var at: Vector3 = to_global(local)
	var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * .4, at - Vector3.UP * .5, 1)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(ray)
	return hit.position if not hit.is_empty() and hit.normal.y >= .90 else at

func _exit_tree() -> void:
	if is_inside_tree():
		var runtime: Node = get_tree().get_first_node_in_group("picnic_runtime")
		if runtime != null: runtime.forget_blanket(get_parent(), self)
	super._exit_tree()
