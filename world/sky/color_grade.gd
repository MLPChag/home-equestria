extends RefCounted
## Storybook colour grade (dev 2026-09-30: "the game in general just needs some post processing
## and touch ups to really make everything shine"). A small 3D lookup table on the Environment's
## colour correction, after tonemapping: warm highlights and faintly cool shadows by day, honey
## highlights and violet shadows at golden hour, moonlit blue at night. Split toning only, so
## it never clips or shifts exposure; the sky controller's saturation and contrast stay as they
## were. Night -> day -> golden is baked once as STEPS tables on a worker thread at startup and
## the controller picks the nearest, so no frame builds a table. Setting video/color_grade.
const SIZE := 17
const STEPS := 9
## [shadow tint, highlight tint, strength] per mood; tints are RGB offsets at full weight.
## Shadow tints stay small: at dusk and night the shadows are most of the frame, and a
## bigger lift read as muddy violet and washed-out blue in the first review renders.
const NIGHT := [Vector3(-0.012, -0.004, 0.018), Vector3(-0.006, 0.0, 0.02), 1.0]
const DAY := [Vector3(-0.012, 0.0, 0.022), Vector3(0.03, 0.016, -0.018), 1.0]
const GOLDEN := [Vector3(0.008, -0.006, 0.012), Vector3(0.08, 0.035, -0.05), 1.0]
static var _tables: Array[ImageTexture3D] = []
static var _task := -1

static func start() -> void:
	if _task >= 0 or not _tables.is_empty(): return
	_task = WorkerThreadPool.add_task(_build_all, false, "color grade tables")

## Leaving the world: join the table build so no worker still holds it at quit.
static func finish() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1

static func ready() -> bool:
	if _tables.is_empty() and _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	return not _tables.is_empty()

## Table for daylight 0..1 and golden 0..1 (sky_controller's daylight() and golden_amount()).
static func table(daylight: float, golden: float) -> Texture3D:
	if not ready(): return null
	# Tables 0..4 run night -> day, 5..8 day -> golden.
	var index := roundi(clampf(daylight, 0.0, 1.0) * 4.0)
	if golden > 0.05 and daylight > 0.25: index = 4 + roundi(clampf(golden, 0.0, 1.0) * 4.0)
	return _tables[clampi(index, 0, STEPS - 1)]

static func _build_all() -> void:
	var built: Array[ImageTexture3D] = []
	for i in STEPS:
		var mood: Array
		if i <= 4: mood = _mix(NIGHT, DAY, float(i) / 4.0)
		else: mood = _mix(DAY, GOLDEN, float(i - 4) / 4.0)
		built.append(_build(mood))
	_tables = built

static func _mix(a: Array, b: Array, t: float) -> Array:
	return [(a[0] as Vector3).lerp(b[0], t), (a[1] as Vector3).lerp(b[1], t), lerpf(a[2], b[2], t)]

static func _build(mood: Array) -> ImageTexture3D:
	var shadow: Vector3 = mood[0]; var highlight: Vector3 = mood[1]; var strength: float = mood[2]
	var layers: Array[Image] = []
	for b in SIZE:
		var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
		for g in SIZE:
			for r in SIZE:
				var c := Vector3(r, g, b) / float(SIZE - 1)
				var luma := c.dot(Vector3(0.2126, 0.7152, 0.0722))
				var low := (1.0 - luma) * (1.0 - luma)
				var high := luma * luma
				var out := c + (shadow * low + highlight * high) * strength
				image.set_pixel(r, g, Color(clampf(out.x, 0.0, 1.0), clampf(out.y, 0.0, 1.0), clampf(out.z, 0.0, 1.0)))
		layers.append(image)
	var texture := ImageTexture3D.new()
	texture.create(Image.FORMAT_RGB8, SIZE, SIZE, SIZE, false, layers)
	return texture
