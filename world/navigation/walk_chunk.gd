class_name WalkChunk
extends Resource
## One 64x64-cell (16 m) tile of the walk grid. Every column stores up to two
## floor spans, highest first, so a bridge deck over a river bed or a roof over a
## floor both survive. Arrays are flat: column index `lz * 64 + lx`, span slot
## `column * 2 + span`. Cached under user:// as a binary resource; ROOF bits are
## stripped on save because reachability depends on the live seeds.

enum State { QUEUED, SAMPLING, SAMPLED, DERIVING, READY }

@export var coord := Vector2i.ZERO
## Local floor height per span slot; NAN when the slot is empty.
@export var floor_y := PackedFloat32Array()
## Surface slope in whole degrees per span slot.
@export var slope_deg := PackedByteArray()
## Water above the span floor in metres (0 = dry).
@export var water_depth := PackedFloat32Array()
## Free height above the span floor; INF for open sky.
@export var headroom := PackedFloat32Array()
## WalkGrid flag bits per span slot.
@export var flags := PackedByteArray()
## Painted route cost per column, `cost * WalkGrid.PAINT_SCALE`; 255 = painted block.
@export var paint_cost := PackedByteArray()
## Visible terrain trail strength per floor span; roofs do not inherit the road below.
@export var trail_weight := PackedByteArray()
@export var sample_ms := 0.0
@export var derive_ms := 0.0
@export var query_count := 0

var state := State.QUEUED
## Bumped whenever a cell is (re)sampled; a derive result older than this is stale.
var sample_revision := 0
var from_cache := false
## Chunks needing an erosion pass; cached chunks only need the reachability flood.
var needs_erosion := true
var last_used_frame := 0
var painted := false
var _cached_view := {}


func allocate() -> void:
	var slots := WalkGrid.CHUNK_CELLS * WalkGrid.CHUNK_CELLS * WalkGrid.SPANS
	floor_y.resize(slots)
	floor_y.fill(NAN)
	slope_deg.resize(slots)
	slope_deg.fill(0)
	water_depth.resize(slots)
	water_depth.fill(0.0)
	headroom.resize(slots)
	headroom.fill(INF)
	trail_weight.resize(slots)
	trail_weight.fill(0)
	flags.resize(slots)
	flags.fill(0)
	paint_cost.resize(WalkGrid.CHUNK_CELLS * WalkGrid.CHUNK_CELLS)
	paint_cost.fill(int(WalkGrid.PAINT_SCALE))


func is_allocated() -> bool:
	return flags.size() == WalkGrid.CHUNK_CELLS * WalkGrid.CHUNK_CELLS * WalkGrid.SPANS


## GDScript packed arrays are shared references. Duplicate once per published
## revision, not per frame, so live paint cannot race a worker's geometry view.
func view() -> Dictionary:
	if _cached_view.is_empty():
		_cached_view = {"floor_y":floor_y.duplicate(),"slope_deg":slope_deg.duplicate(),
			"water_depth":water_depth.duplicate(),"headroom":headroom.duplicate(),
			"flags":flags.duplicate(),"paint_cost":paint_cost.duplicate(),"trail_weight":trail_weight.duplicate()}
	return _cached_view

func cache_copy() -> WalkChunk:
	var copy := WalkChunk.new()
	copy.coord = coord
	copy.floor_y = floor_y.duplicate(); copy.slope_deg = slope_deg.duplicate()
	copy.water_depth = water_depth.duplicate(); copy.headroom = headroom.duplicate()
	copy.flags = flags.duplicate(); copy.paint_cost = paint_cost.duplicate()
	copy.trail_weight = trail_weight.duplicate()
	return copy


func clear_column(column: int) -> void:
	for span in WalkGrid.SPANS:
		var slot := column * WalkGrid.SPANS + span
		floor_y[slot] = NAN
		slope_deg[slot] = 0
		water_depth[slot] = 0.0
		headroom[slot] = INF
		flags[slot] = 0
		if trail_weight.size() > slot: trail_weight[slot] = 0
	paint_cost[column] = int(WalkGrid.PAINT_SCALE)


func span_count() -> int:
	var count := 0
	for slot in flags.size():
		if flags[slot] & WalkGrid.SOLID:
			count += 1
	return count
