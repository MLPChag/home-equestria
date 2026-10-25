extends RefCounted
## Deterministic distance-based service. No scene nodes, wall-clock catchup or model calls.
var route: Dictionary
var distance := 24.0
var speed := 0.0
var arrivals := 0
var direction := 1
var dwell := 60.0
var ticket: Dictionary = {}
var travellers: Array[String] = []
var points := PackedVector3Array()
var distances := PackedFloat64Array()
const ACCELERATION := .35
const BRAKING := .5
const END_MARGIN := 24.0
const PASSENGER_CAPACITY := 6

func configure(data: Dictionary) -> void:
	route = data
	points.clear()
	for value in route.points: points.append(Vector3(value[0], value[1], value[2]))
	distances = PackedFloat64Array(route.distances)
	distance = END_MARGIN; speed = 0; direction = 1; dwell = float(route.dwell_seconds)
	arrivals = 0; ticket.clear(); travellers.clear()

func station() -> String:
	if speed > .001 or dwell <= 0: return ""
	return str(route.from) if distance < route.length * .5 else str(route.to)

func destination() -> String:
	return str(route.to) if direction > 0 else str(route.from)

func issue_ticket(from: String, to: String) -> bool:
	if from == to or from not in [route.from, route.to] or to not in [route.from, route.to]: return false
	ticket = {"from":from, "to":to, "service":route.id, "status":"issued", "price":0}
	return true

func board(from: String) -> bool:
	if station() != from or ticket.get("status") != "issued" or ticket.get("from") != from: return false
	ticket.status = "aboard"
	return true

func advance(delta: float, clear := true) -> void:
	# Small bounded integration steps keep acceleration/stopping independent of frame rate.
	var remaining := clampf(delta, 0.0, 1.0)
	while remaining > .000001:
		var step := minf(remaining, 1.0 / 60.0); remaining -= step
		if dwell > 0:
			if clear: dwell = maxf(0, dwell - step)
			continue
		var end := float(route.length) - END_MARGIN if direction > 0 else END_MARGIN
		var gap := absf(end - distance)
		var wanted := minf(float(route.cruise_speed), sqrt(2 * BRAKING * maxf(0, gap - .05))) if clear else 0.0
		var next := move_toward(speed, wanted, (ACCELERATION if wanted > speed else BRAKING) * step)
		var travel := minf(gap, (speed + next) * .5 * step)
		distance += travel * direction; speed = next
		if gap < .06 and speed < .3:
			distance = end; speed = 0; direction *= -1; dwell = float(route.dwell_seconds); arrivals += 1

func position(at: float) -> Vector3:
	var value := clampf(at, 0, distances[-1])
	var index := clampi(distances.bsearch(value), 1, distances.size() - 1)
	return points[index-1].lerp(points[index], (value-distances[index-1]) / (distances[index]-distances[index-1]))

func frame(at: float) -> Transform3D:
	var forward := (position(at + 2.5) - position(at - 2.5)).normalized()
	var right := forward.cross(Vector3.UP).normalized()
	return Transform3D(Basis(right, right.cross(forward), -forward), position(at))

func checkpoint() -> Dictionary:
	return {"version":1,"route":route.id,"revision":route.revision,"distance":distance,"speed":speed,
		"direction":direction,"arrivals":arrivals,"dwell":dwell,"ticket":ticket.duplicate(true),"travellers":travellers.duplicate()}

static func valid(data: Variant) -> bool:
	if not data is Dictionary or data.get("version") not in [1,1.0]: return false
	if not data.get("route") is String or not data.get("revision") is String: return false
	for key in ["distance","speed","direction","dwell","arrivals"]:
		if not (data.get(key) is int or data.get(key) is float) or not is_finite(float(data[key])): return false
	if data.distance < 0 or data.distance > 100000 or data.speed < 0 or data.speed > 30 or data.direction not in [-1,-1.0,1,1.0] or data.dwell < 0 or data.dwell > 3600: return false
	if not data.get("ticket") is Dictionary or not data.get("travellers") is Array or data.travellers.size() > PASSENGER_CAPACITY: return false
	var seen := {}
	for id in data.travellers:
		if not id is String or id.is_empty() or seen.has(id): return false
		seen[id] = true
	if data.arrivals < 0 or data.arrivals != int(data.arrivals): return false
	if data.has("player_aboard"):
		if not data.player_aboard is bool: return false
		if data.player_aboard:
			if data.get("player_car") not in [0,0.0,1,1.0] or not data.get("player_local") is Array or data.player_local.size()!=3: return false
			for n in data.player_local:
				if not (n is int or n is float) or not is_finite(float(n)): return false
			if absf(data.player_local[0])>2.4 or absf(data.player_local[2])>6.5 or data.player_local[1]<-1 or data.player_local[1]>4:return false
	var passenger_state:Variant=data.get("passenger_state",{})
	if not passenger_state is Dictionary or passenger_state.size()>PASSENGER_CAPACITY:return false
	var seats:Dictionary={}
	for id in passenger_state:
		var row:Variant=passenger_state[id]
		if id not in data.travellers or not row is Dictionary or not row.get("visiting") is bool or not row.get("returning") is bool:return false
		if row.has("car") or row.has("slot"):
			if row.get("car") not in [0,0.0,1,1.0] or not row.get("slot") is Array or row.slot.size()!=3:return false
			if row.slot[0]!=0 or row.slot[1]!=0 or row.slot[2] not in [-3.5,0,0.0,3.5]:return false
			var seat:=Vector2i(int(row.car),roundi((float(row.slot[2])+3.5)/3.5))
			if seats.has(seat):return false
			seats[seat]=true
		if not row.get("walk") is Array or row.walk.size()>8:return false
		if not (row.get("wait") is int or row.get("wait") is float) or not is_finite(float(row.wait)) or row.wait<0 or row.wait>3600:return false
		var positions:Array=[row.get("position")];positions.append_array(row.walk)
		for pos in positions:
			if not pos is Array or pos.size()!=3:return false
			for n in pos:
				if not (n is int or n is float) or not is_finite(float(n)) or absf(n)>8:return false
	if not data.ticket.is_empty():
		for key in ["from","to","service","status"]:
			if not data.ticket.get(key) is String: return false
		if data.ticket.status not in ["issued","aboard","used"] or data.ticket.get("price") != 0: return false
	return true

func restore(data: Dictionary) -> bool:
	if not valid(data) or data.route != route.id: return false
	if not data.ticket.is_empty() and (data.ticket.service != route.id or data.ticket.from not in [route.from,route.to] or data.ticket.to not in [route.from,route.to] or data.ticket.from == data.ticket.to): return false
	if data.revision == route.revision:
		if data.distance < END_MARGIN or data.distance > float(route.length)-END_MARGIN or data.speed > float(route.cruise_speed)+.001:return false
		if data.dwell>0:
			var endpoint:=END_MARGIN if data.direction>0 else float(route.length)-END_MARGIN
			if absf(data.distance-endpoint)>.001 or data.speed>.001:return false
	ticket = data.ticket.duplicate(true); travellers.assign(data.travellers)
	arrivals = int(data.arrivals)
	if not ticket.is_empty(): ticket.price = 0
	if data.revision != route.revision:
		distance = END_MARGIN; speed = 0; dwell = route.dwell_seconds; direction = 1
		if ticket.get("status") == "aboard": ticket = {}
		return true
	distance = data.distance; speed = data.speed; direction = int(data.direction); dwell = data.dwell; arrivals = int(data.arrivals)
	return true
