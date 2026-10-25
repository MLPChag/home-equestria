extends RefCounted
## Transfer a blocked approach to a mare without bypassing move_and_slide.
## Players stay collision-limited; the mare decides how much balanced give is safe.
static func transfer(player: CharacterBody3D, attempted: Vector3, delta: float) -> void:
	var seen: Array[Object] = []
	for i in player.get_slide_collision_count():
		var contact := player.get_slide_collision(i)
		var other := contact.get_collider()
		if other == null or other in seen or not other.has_method("receive_body_contact"):
			continue
		seen.append(other)
		var direction := -contact.get_normal()
		direction.y = 0.0
		if direction.length_squared() < 0.25: continue
		direction = direction.normalized()
		var approach := maxf(0.0, attempted.dot(direction))
		if approach > 0.01:
			other.receive_body_contact(direction * minf(120.0, approach * 80.0), delta)
