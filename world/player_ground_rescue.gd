extends Node
## Puts the player back on the ground when he ends up under the world (dev 2026-10-18: "im stuck
## under the map": an autosave at y -53 under Ponyville, 40 m below the surface, with no way up
## because the world is solid from below too). Twice a second: if he is more than DEPTH below
## the terrain heightmap (far below: future pits, cellars or holes in the ground never trigger it,
## dev) and not inside a house, he goes back to the last place he stood on solid
## ground above it, or, with none yet (a save loaded down there), onto the open ground nearest
## the heightmap point above him. Nothing else changes; normal play never comes near this.

const DEPTH := 30.0
const CHECK := 0.5
const HOUSE := preload("res://world/buildings/house_interior.gd")
var game: Node
var _timer := 0.0
var _last_good := Vector3.INF

func setup(host: Node) -> void:
	game = host

func _physics_process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0: return
	_timer = CHECK
	if game == null or not is_instance_valid(WorldTerrain.instance): return
	var player := game.get("player") as Node3D
	if player == null or not player.is_inside_tree(): return
	var at := player.global_position
	var ground: float = WorldTerrain.instance.height_at(at)
	if not is_finite(ground): return
	var body := player as CharacterBody3D
	if at.y > ground - 1.0:
		if body == null or body.is_on_floor(): _last_good = at
		return
	if at.y > ground - DEPTH or HOUSE.at(get_tree(), at) != null: return
	var to := _last_good if _last_good.is_finite() and Vector2(_last_good.x - at.x, _last_good.z - at.z).length() < 200.0 else _open_ground(at)
	if not to.is_finite(): return
	print("[player] under the ground at %s (surface %.1f): back up to %s" % [at, ground, to])
	player.global_position = to + Vector3.UP * 0.2
	if body != null: body.velocity = Vector3.ZERO
	if player.has_method("reset_physics_interpolation"): player.reset_physics_interpolation()

## The first point near `at` where a ray from high above lands on the ground itself (within
## 0.6 m of the heightmap), not on a roof.
func _open_ground(at: Vector3) -> Vector3:
	var space := (game as Node3D).get_world_3d().direct_space_state
	for i in 40:
		var r := sqrt(float(i)) * 2.0
		var a := float(i) * 2.399963
		var p := Vector3(at.x + cos(a) * r, 0.0, at.z + sin(a) * r)
		var h: float = WorldTerrain.instance.height_at(p)
		if not is_finite(h): continue
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x, h + 40.0, p.z), Vector3(p.x, h - 2.0, p.z), 1))
		if hit.is_empty():
			# No collision streamed in here yet: the heightmap itself is the floor to come.
			if i == 0: return Vector3(p.x, h, p.z)
			continue
		if absf(Vector3(hit.position).y - h) < 0.6: return hit.position
	return Vector3(at.x, WorldTerrain.instance.height_at(at), at.z)
