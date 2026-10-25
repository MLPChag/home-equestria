class_name WalkGrid
extends RefCounted
## World-aligned, lazily sampled columns. Geometry is shared; profiles decide traversal.
const CELL := 0.25
const CHUNK_CELLS := 64
const SPANS := 2
const PAINT_SCALE := 50.0
const SOLID := 1
const WATER := 2
const NO_CLEARANCE := 4
const EDGE := 8
const ROOF := 16
const PAINT_TRAIL := 32
const PAINT_FORD := 64
const PAINT_BLOCK := 128
const DIRECTIONS := [Vector2i(-1,0),Vector2i(1,0),Vector2i(0,-1),Vector2i(0,1),
	Vector2i(-1,-1),Vector2i(-1,1),Vector2i(1,-1),Vector2i(1,1)]
var chunks: Dictionary = {}
var _snapshot_frame := -1
var _snapshot_data := {}

static func column(point: Vector3) -> Vector2i:
	return Vector2i(floori(point.x/CELL),floori(point.z/CELL))

static func chunk_of(c: Vector2i) -> Vector2i:
	return Vector2i(floori(float(c.x)/CHUNK_CELLS),floori(float(c.y)/CHUNK_CELLS))

static func slot_of(key: Vector3i) -> int:
	return (posmod(key.z,CHUNK_CELLS)*CHUNK_CELLS+posmod(key.x,CHUNK_CELLS))*SPANS+key.y

## Every chunk change in WalkGridService (publish, evict, reset, repaint) sets
## _snapshot_frame = -1; between those the published views are the same objects, so the
## last snapshot stays valid. Rebuilding it every physics frame walked all 384 chunks.
func snapshot() -> Dictionary:
	if _snapshot_frame >= 0: return _snapshot_data
	var out := {}
	for c in chunks:
		if chunks[c].state == WalkChunk.State.READY: out[c] = chunks[c].view()
	_snapshot_frame = Engine.get_physics_frames()
	_snapshot_data = out
	return out

static func sample(data: Dictionary, key: Vector3i) -> Dictionary:
	var c := chunk_of(Vector2i(key.x,key.z))
	if not data.has(c) or key.y < 0 or key.y >= SPANS: return {}
	var a: Dictionary = data[c]
	var i := slot_of(key)
	if not (a.flags[i] & SOLID): return {}
	var trail := 0.0
	if a.has("trail_weight"):
		var surface: PackedByteArray = a.trail_weight
		if surface.size() > i: trail = float(surface[i])/255.0
	var paint := float(a.paint_cost[i/SPANS])/PAINT_SCALE
	if a.flags[i] & PAINT_TRAIL: trail = 1.0
	else: paint *= lerpf(1.0, .6, trail)
	return {"height":a.floor_y[i],"slope":a.slope_deg[i],"water":a.water_depth[i],
		"clearance":a.headroom[i],"flags":a.flags[i],"paint":paint,"trail":trail}

static func point(data: Dictionary, key: Vector3i) -> Vector3:
	var s := sample(data,key)
	return Vector3((key.x+.5)*CELL,s.get("height",NAN),(key.z+.5)*CELL)

static func profile(resource: Resource) -> Dictionary:
	return {"slope":float(resource.max_slope_degrees),"step":float(resource.step_height),
		"wade":float(resource.wade_depth),"swim":bool(resource.swim),
		"radius":float(resource.radius),"clearance":float(resource.clearance)}

static func allowed(s: Dictionary, p: Dictionary) -> bool:
	return not s.is_empty() and not (s.flags & (NO_CLEARANCE|PAINT_BLOCK)) \
		and s.slope <= p.slope and s.clearance + .001 >= p.clearance \
		and (s.water <= p.wade + .001 or p.swim)

static func connected(a: Dictionary, b: Dictionary, distance: float, p: Dictionary) -> bool:
	if not allowed(a,p) or not allowed(b,p): return false
	var rise := absf(a.height-b.height)
	if rise <= p.step + .0001: return true
	# Flat ledges cannot borrow the gradient allowance of a continuous ramp.
	var grade := rad_to_deg(atan2(rise,distance))
	return grade <= p.slope + .05 and maxf(a.slope,b.slope) >= grade - 1.5

static func has_room(data: Dictionary, key: Vector3i, p: Dictionary) -> bool:
	var center := sample(data,key)
	if not allowed(center,p): return false
	var r := ceili(p.radius/CELL)
	for z in range(-r,r+1):
		for x in range(-r,r+1):
			if x*x+z*z == 0 or Vector2(x,z).length()*CELL > p.radius: continue
			var found := false
			for span in SPANS:
				var other := sample(data,Vector3i(key.x+x,span,key.z+z))
				if connected(center,other,Vector2(x,z).length()*CELL,p): found = true; break
			if not found: return false
	return true

static func nearest(data: Dictionary, pos: Vector3, p: Dictionary, radius := 1.0) -> Vector3i:
	var c := column(pos)
	var best := Vector3i(0,-1,0)
	var best_d := radius*radius
	var r := ceili(radius/CELL)
	for z in range(-r,r+1):
		for x in range(-r,r+1):
			for span in SPANS:
				var key := Vector3i(c.x+x,span,c.y+z)
				var s := sample(data,key)
				if not allowed(s,p): continue
				var d := point(data,key).distance_squared_to(pos)
				if d <= best_d and has_room(data,key,p): best_d = d; best = key
	return best
