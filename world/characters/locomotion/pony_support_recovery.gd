extends RefCounted
## Re-seating a pony that lost her floor (split from pony_locomotion.gd, 2026-10-13). The big
## world only has terrain collision in a window around the camera and zone bodies arrive seconds
## after a zone loads; the pony's _maintain_support() calls _recover_support() a few times a
## second while she is unsupported. State (`_heightmap_supported`, ...) stays on the pony.

const ROSTER_PLACEMENT := preload("res://world/navigation/roster_placement.gd")


static func support_ray(pony: CharacterBody3D, above: float) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(pony.global_position + Vector3.UP * above,
		pony.global_position - Vector3.UP * 8.0, pony.floor_mask, [pony.get_rid()])
	return pony.get_world_3d().direct_space_state.intersect_ray(query)


static func is_house_floor(pony: CharacterBody3D, point: Vector3) -> bool:
	for home in pony.get_tree().get_nodes_in_group("house_interiors"):
		if home.contains(point): return true
	return false


## Re-seat the body on the ground beneath (or above, when she has sunk under it). With
## no collision at all here, hold the terrain heightmap height instead of falling.
static func recover(pony: CharacterBody3D) -> void:
	# Look just above the hooves first. Starting 3 m up found eaves and roofs over a
	# pony beside or inside a house and lifted her onto them (2026-09-22); the high
	# start is only for a pony sunk under collision that arrived late, and there it
	# may land on a building only when that surface is a house floor.
	var hit: Dictionary = pony._support_ray(0.6)
	if hit.is_empty():
		hit = pony._support_ray(3.0)
		if not hit.is_empty() and ROSTER_PLACEMENT.building(hit.collider) and not pony._is_house_floor(hit.position):
			hit = {}
	if not hit.is_empty():
		pony._heightmap_supported = false
		var surface: float = hit.position.y
		if pony.global_position.y < surface - 0.03 or pony.global_position.y > surface + 0.6:
			print("[pony] %s re-seated on the floor (%.2f -> %.2f)" % [pony.name, pony.global_position.y, surface])
			pony.global_position.y = surface + 0.02
			pony.velocity = Vector3.ZERO
			pony._initialized = false
			pony._spawn_settle = 0.35
		return
	var terrain: float = WorldTerrain.instance.height_at(pony.global_position) if is_instance_valid(WorldTerrain.instance) else NAN
	if is_finite(terrain):
		if absf(pony.global_position.y - terrain) > 0.05:
			pony.global_position.y = terrain + 0.02
		pony.velocity.y = 0.0
		pony._heightmap_supported = true
