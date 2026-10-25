class_name MapLayers
extends RefCounted
## Painted map layers for a zone: hot spots, trails, spawns (JSON) and cell-resolution raster
## masks (PNG, R8) that ponies and the walk grid read. Independent of the mesh: positions are
## XZ in zone-local metres, heights are snapped to the ground at use time.
##
## Files: `res://world/zones/<zone>/map_layers/layers.json` + `paint_<layer>.png` (published),
## overlaid by the same names under `user://map_paint/<zone>/` (work in progress). Both are
## optional; a zone without paint simply has no layers.

const VERSION := 1
const RASTER_LAYERS := ["trail", "avoid", "block", "ford", "lake", "bridge"]
const HOT_SPOT_KINDS := ["social", "shop", "home", "work", "scenic"]
## Route cost multipliers per raster layer (1 = neutral); block is impassable.
const COSTS := {"trail": 0.6, "avoid": 3.0, "block": INF, "ford": 0.8, "lake": 1.0, "bridge": 1.0}

var zone_id := ""
var cell := 0.25
## World XZ of raster texel (0,0) and the raster size in cells.
var origin := Vector2(-256.0, -512.0)
var size := Vector2i(2048, 2048)
var hot_spots: Array = []   # {id, pos: Vector2, radius, kind, capacity, faces: Vector2|null}
var trails: Array = []      # {id, points: Array[Vector2], width}
var spawns: Array = []      # {id, pos: Vector2}
var rasters: Dictionary = {}  # layer -> Image (FORMAT_R8), lazily created
var dirty := false


static func published_dir(id: String) -> String:
	return "res://world/zones/%s/map_layers" % id


static func working_dir(id: String) -> String:
	return "user://map_paint/%s" % id


## Published data first, the working copy on top (same idiom as ai_config.gd).
static func load_zone(id: String) -> MapLayers:
	var layers := MapLayers.new()
	layers.zone_id = id
	for dir in [published_dir(id), working_dir(id)]:
		layers._load_dir(dir)
	return layers


func _load_dir(dir: String) -> void:
	var raster_names: Array = RASTER_LAYERS
	var json_path := dir.path_join("layers.json")
	if FileAccess.file_exists(json_path):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
		if data is Dictionary:
			# Saved documents are complete snapshots. Upserting them resurrected
			# published hot spots that the working copy had deliberately deleted.
			if bool(data.get("snapshot",false)):
				hot_spots.clear(); trails.clear(); spawns.clear(); rasters.clear()
			_merge_json(data)
			raster_names = data.get("rasters",RASTER_LAYERS)
	for layer in raster_names:
		if layer not in RASTER_LAYERS: continue
		var png := dir.path_join("paint_%s.png" % layer)
		if ResourceLoader.exists(png) or FileAccess.file_exists(png):
			var image := preload("res://world/resource_image.gd").read(png)
			if image != null:
				image.convert(Image.FORMAT_R8)
				if image.get_size() == size:
					rasters[layer] = image


func _merge_json(data: Dictionary) -> void:
	cell = float(data.get("cell", cell))
	var o: Array = data.get("origin", [origin.x, origin.y])
	origin = Vector2(float(o[0]), float(o[1]))
	var sz: Array = data.get("size", [size.x, size.y])
	size = Vector2i(int(sz[0]), int(sz[1]))
	for spot in data.get("hot_spots", []):
		_upsert(hot_spots, {"id": String(spot.get("id", "")), "pos": _v2(spot.get("pos", [0, 0])),
			"radius": float(spot.get("radius", 4.0)), "kind": String(spot.get("kind", "social")),
			"capacity": int(spot.get("capacity", 3)),
			"faces": _v2(spot.faces) if spot.get("faces") != null else null})
	for trail in data.get("trails", []):
		var points: Array = []
		for p in trail.get("points", []): points.append(_v2(p))
		_upsert(trails, {"id": String(trail.get("id", "")), "points": points, "width": float(trail.get("width", 2.0))})
	for spawn in data.get("spawns", []):
		_upsert(spawns, {"id": String(spawn.get("id", "")), "pos": _v2(spawn.get("pos", [0, 0]))})


static func _v2(a: Variant) -> Vector2:
	return Vector2(float(a[0]), float(a[1])) if a is Array and a.size() >= 2 else Vector2.ZERO


static func _upsert(list: Array, entry: Dictionary) -> void:
	for i in list.size():
		if list[i].id == entry.id:
			list[i] = entry
			return
	list.append(entry)


func to_json() -> Dictionary:
	var out := {"version": VERSION, "snapshot":true, "cell": cell, "origin": [origin.x, origin.y], "size": [size.x, size.y],
		"rasters":rasters.keys(), "hot_spots": [], "trails": [], "spawns": []}
	for s in hot_spots:
		out.hot_spots.append({"id": s.id, "pos": [s.pos.x, s.pos.y], "radius": s.radius, "kind": s.kind,
			"capacity": s.capacity, "faces": [s.faces.x, s.faces.y] if s.faces != null else null})
	for t in trails:
		var pts: Array = []
		for p in t.points: pts.append([p.x, p.y])
		out.trails.append({"id": t.id, "points": pts, "width": t.width})
	for s in spawns:
		out.spawns.append({"id": s.id, "pos": [s.pos.x, s.pos.y]})
	return out


## Write layers.json and the touched rasters into `dir` (user:// working copy or res:// publish).
func save_to(dir: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for layer in rasters:
		if (rasters[layer] as Image).save_png(dir.path_join("paint_%s.png" % layer)) != OK: return false
	var f := FileAccess.open(dir.path_join("layers.json"), FileAccess.WRITE)
	if f == null:
		return false
	var document := to_json()
	document["saved_usec"] = Time.get_ticks_usec()
	f.store_string(JSON.stringify(document, "  "))
	f.close()
	dirty = false
	return true


func save_working() -> bool:
	return save_to(working_dir(zone_id))


func publish() -> bool:
	return save_to(published_dir(zone_id))


## Raster access. World XZ -> texel; outside the raster reads 0.
func cell_of(xz: Vector2) -> Vector2i:
	return Vector2i(int(floor((xz.x - origin.x) / cell)), int(floor((xz.y - origin.y) / cell)))


func world_of(texel: Vector2i) -> Vector2:
	return origin + (Vector2(texel) + Vector2(0.5, 0.5)) * cell


func raster(layer: String) -> Image:
	if not rasters.has(layer):
		rasters[layer] = Image.create(size.x, size.y, false, Image.FORMAT_R8)
	return rasters[layer]


func value_at(layer: String, xz: Vector2) -> float:
	if not rasters.has(layer):
		return 0.0
	var t := cell_of(xz)
	if t.x < 0 or t.y < 0 or t.x >= size.x or t.y >= size.y:
		return 0.0
	return (rasters[layer] as Image).get_pixelv(t).r


func flags_at(xz: Vector2) -> Dictionary:
	var out := {}
	for layer in RASTER_LAYERS:
		out[layer] = value_at(layer, xz) > 0.5
	return out


## Route cost multiplier from every painted layer at a point (INF = painted block).
func cost_at(xz: Vector2) -> float:
	var cost := 1.0
	for layer in ["trail", "avoid", "block", "ford"]:
		if value_at(layer, xz) > 0.5:
			cost *= COSTS[layer]
	return cost


## Paint a disc (value 1) or erase it (value 0) on a layer.
func paint(layer: String, centre: Vector2, radius: float, value: float = 1.0) -> void:
	var image := raster(layer)
	var c := cell_of(centre)
	var r := int(ceil(radius / cell))
	for y in range(maxi(c.y - r, 0), mini(c.y + r + 1, size.y)):
		for x in range(maxi(c.x - r, 0), mini(c.x + r + 1, size.x)):
			if world_of(Vector2i(x, y)).distance_to(centre) <= radius:
				image.set_pixel(x, y, Color(value, 0.0, 0.0, 1.0))
	dirty = true


## Trails also rasterise into the trail layer so the planner reads them as one thing.
func rasterise_trail(trail: Dictionary) -> void:
	var points: Array = trail.points
	var width: float = trail.width
	for i in points.size():
		paint("trail", points[i], width * 0.5)
		if i > 0:
			var a: Vector2 = points[i - 1]
			var b: Vector2 = points[i]
			var steps := int(ceil(a.distance_to(b) / (cell * 2.0)))
			for k in range(1, steps):
				paint("trail", a.lerp(b, float(k) / float(steps)), width * 0.5)


func hot_spot(id: String) -> Dictionary:
	for s in hot_spots:
		if s.id == id:
			return s
	return {}


## Hot spots by distance, optionally of one kind.
func nearest_hot_spots(xz: Vector2, kind := "", limit := 5) -> Array:
	var out: Array = []
	for s in hot_spots:
		if kind == "" or s.kind == kind:
			out.append(s)
	out.sort_custom(func(a, b): return a.pos.distance_to(xz) < b.pos.distance_to(xz))
	return out.slice(0, limit)


func add_hot_spot(id: String, pos: Vector2, kind := "social", radius := 4.0, capacity := 3) -> Dictionary:
	var entry := {"id": id, "pos": pos, "radius": radius, "kind": kind, "capacity": capacity, "faces": null}
	_upsert(hot_spots, entry)
	dirty = true
	return entry


func remove_nearest(xz: Vector2, max_distance := 3.0) -> String:
	var best := ""
	var best_d := max_distance
	var best_list: Array = []
	for list in [hot_spots, spawns]:
		for s in list:
			var d: float = s.pos.distance_to(xz)
			if d < best_d:
				best_d = d
				best = s.id
				best_list = list
	if best != "":
		for i in best_list.size():
			if best_list[i].id == best:
				best_list.remove_at(i)
				break
		dirty = true
	return best
