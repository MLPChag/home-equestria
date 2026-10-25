extends RefCounted
## Read the same Terrain3D controls that draw the road. Called only while deriving
## navigation columns, inside the service's existing time budget; no renderer readback.
var data: Object
var trail_ids := {}

func bind(source: Object, texture_rows: Array) -> void:
	data = source
	for row: Dictionary in texture_rows:
		if row.get("navigation_trail", false): trail_ids[int(row.id)] = true

func control_weight(control: int) -> float:
	var base := (control >> 27) & 31
	var overlay := (control >> 22) & 31
	var blend := float((control >> 14) & 255) / 255.0
	return lerpf(1.0 if trail_ids.has(base) else 0.0, 1.0 if trail_ids.has(overlay) else 0.0, blend)

const CORNERS := [Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN, Vector2.ONE]
## Reused per call (main thread only); float32 storage keeps the old rounding.
var _weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])

func weight_at(point: Vector3) -> float:
	if not is_instance_valid(data): return 0.0
	var corner := Vector2(point.x, point.z).floor()
	var f := Vector2(point.x, point.z) - corner
	for i in 4:
		var p: Vector2 = corner + CORNERS[i]
		_weights[i] = control_weight(int(data.get_control(Vector3(p.x, point.y, p.y))))
	return lerpf(lerpf(_weights[0], _weights[1], f.x), lerpf(_weights[2], _weights[3], f.x), f.y)

## Every column's weight_at() for a walk chunk in one go (2026-10-24 script profile: the per-column
## version asked Terrain3D 16,384 times per chunk). Native PonyTrailWeights reads each terrain vertex
## once with the same float32/double steps; without it, the per-column path. Index row * cells + column.
func chunk_weights(coord: Vector2i, cell: float, cells: int) -> PackedFloat64Array:
	var weights := PackedFloat64Array()
	if not is_instance_valid(data): return weights
	if ClassDB.class_exists(&"PonyTrailWeights"):
		var mask := 0
		for id: int in trail_ids:
			if id >= 0 and id < 32: mask |= 1 << id
		var native: PackedFloat64Array = ClassDB.class_call_static(&"PonyTrailWeights", &"chunk_weights", data, coord, cell, cells, mask)
		return native
	weights.resize(cells * cells)
	for row in cells:
		for column in cells:
			weights[row * cells + column] = weight_at(Vector3((coord.x * cells + column + .5) * cell, 0, (coord.y * cells + row + .5) * cell))
	return weights
