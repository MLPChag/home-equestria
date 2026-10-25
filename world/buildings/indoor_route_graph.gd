extends RefCounted
## Shared visibility-graph search. Each home supplies its existing clear-sweep contract;
## cache policy, polygon validation and point generation stay with that home.
static func next(points: Array[Vector3], clear: Callable) -> Vector3:
	var distance: Array[float] = []
	var previous: Array[int] = []
	var done: Array[bool] = []
	for i in points.size():
		distance.append(INF); previous.append(-1); done.append(false)
	distance[0] = 0.0
	for iteration in points.size():
		var next := -1
		for i in points.size():
			if not done[i] and (next < 0 or distance[i] < distance[next]): next = i
		if next < 0 or not is_finite(distance[next]): break
		if next == 1:
			var step := 1
			while previous[step] > 0: step = previous[step]
			return points[step]
		done[next] = true
		for i in points.size():
			var cost := distance[next] + points[next].distance_to(points[i])
			if done[i] or cost >= distance[i]: continue
			if clear.call(points[next], points[i]):
				distance[i] = cost; previous[i] = next
	return points[0]

## Query dimensions/exclusions belong to the caller, including the cottage's cached capsule.
static func sweep(space: PhysicsDirectSpaceState3D, query: PhysicsShapeQueryParameters3D) -> bool:
	if not space.intersect_shape(query, 1).is_empty(): return false
	var sweep := space.cast_motion(query)
	return sweep.size() == 2 and sweep[0] >= .9999
