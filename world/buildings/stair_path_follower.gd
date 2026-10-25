extends RefCounted
## Follow the original centre line between authored storeys. The caller retains its exact
## ground threshold and flat-route policy (including actor-aware routing at Golden Oak).
static func waypoint(home: Node3D, from: Vector3, to: Vector3, path: Array[Vector3], upper_y: float, ground_y: float, ground_margin: float, flat: Callable) -> Vector3:
	var a := home.to_local(from)
	var b := home.to_local(to)
	if path.size() < 2: return flat.call(from, to)
	var going_up := b.y >= upper_y - .25
	var on_stairs := a.y > ground_y + ground_margin and a.y < upper_y - .04
	var change_floor := (a.y >= upper_y - .04) != going_up
	if not on_stairs and not change_floor: return flat.call(from, to)
	var foot := path[0]
	var landing := path[-1]
	if a.y <= ground_y + ground_margin and a.distance_to(foot) > .55:
		return flat.call(from, home.to_global(foot))
	var landing_start: Vector3 = path[maxi(0, path.size() - 3)]
	var on_landing := a.distance_to(Geometry3D.get_closest_point_to_segment(a, landing_start, landing)) <= .55
	if a.y >= upper_y - .04 and not on_landing:
		return flat.call(from, home.to_global(landing))
	var segment := 0
	var best := INF
	for i in path.size() - 1:
		var closest := Geometry3D.get_closest_point_to_segment(a, path[i], path[i + 1])
		var distance := a.distance_squared_to(closest)
		if distance < best:
			best = distance
			segment = i
	var index := segment + 1 if going_up else segment
	if a.distance_to(path[index]) < .22:
		index = clampi(index + (1 if going_up else -1), 0, path.size() - 1)
	return home.to_global(path[index])
