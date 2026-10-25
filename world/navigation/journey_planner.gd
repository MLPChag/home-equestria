extends RefCounted
## Coarse journey graph above the local walk grid. Only verified corridors are admitted.
## Detailed paths stay on edges; route selection does not search every metre of terrain.
class Search extends AStar3D:
	var costs: Dictionary = {}
	func _compute_cost(from: int, to: int) -> float: return float(costs[Vector2i(from,to)])
	func _estimate_cost(_from: int, _to: int) -> float: return 0.0

var places: Dictionary = {}
var corridors: Dictionary = {}

func add_place(id: String, position: Vector3) -> bool:
	if id.is_empty() or not position.is_finite(): return false
	places[id] = position; return true

func add_corridor(id: String, from: String, to: String, points: PackedVector3Array,
		mode: String, seconds: float, revision: String) -> bool:
	if not places.has(from) or not places.has(to) or from==to or revision.is_empty() or points.size()<2: return false
	if not is_finite(seconds) or seconds<=0 or mode not in ["walk","fly","train"]: return false
	if points[0].distance_to(places[from])>2 or points[-1].distance_to(places[to])>2: return false
	for point in points:
		if not point.is_finite(): return false
	corridors[id]={"id":id,"from":from,"to":to,"points":points,"mode":mode,"seconds":seconds,"revision":revision}
	return true

func invalidate(revision: String) -> void:
	for id in corridors.keys():
		if corridors[id].revision==revision:corridors.erase(id)

func plan(from: String, to: String, modes: Array = ["walk","train"], required_mode := "") -> Dictionary:
	if not places.has(from) or not places.has(to):return {"status":"needs_local_connection","legs":[]}
	if not required_mode.is_empty() and required_mode not in modes:return {"status":"unreachable","legs":[]}
	var graph:=Search.new();var ids:Array=places.keys();ids.sort();var indices:Dictionary={};var edges:Dictionary={}
	var layers:=1 if required_mode.is_empty() else 2
	for i in ids.size():
		indices[ids[i]]=i
		for layer in layers:graph.add_point(i+layer*ids.size(),places[ids[i]])
	# A second layer means the required mode has actually been used. Merely offering
	# a train alongside a faster walking shortcut must not turn a visit into a hike.
	var keys:Array=corridors.keys();keys.sort()
	for id in keys:
		var edge:Dictionary=corridors[id]
		if edge.mode not in modes:continue
		for layer in layers:
			var next_layer:=1 if layers==2 and (layer==1 or edge.mode==required_mode) else 0
			var pair:=Vector2i(indices[edge.from]+layer*ids.size(),indices[edge.to]+next_layer*ids.size())
			if graph.costs.has(pair) and graph.costs[pair]<=edge.seconds:continue
			graph.costs[pair]=edge.seconds;edges[pair]=edge
			if not graph.are_points_connected(pair.x,pair.y,false):graph.connect_points(pair.x,pair.y,false)
	var route:=graph.get_id_path(indices[from],indices[to]+(layers-1)*ids.size());var legs:=[];var seconds:=0.0
	for i in range(1,route.size()):
		var edge:Dictionary=edges[Vector2i(route[i-1],route[i])]
		legs.append(edge.duplicate(true));seconds+=float(edge.seconds)
	return {"status":"ready" if not route.is_empty() else "unreachable","legs":legs,"seconds":seconds}
