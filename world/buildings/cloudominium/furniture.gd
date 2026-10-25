extends Node3D
## Rainbow Dash's Cloudominium furnishings (dev 2026-09-28), in the shared room frame of
## layout.gd: origin at the ground-floor centre on the threshold, +Z to the front door, metres.
## References: art/references/cloudominium-2026-09-28/ (sources.json).
##   Hall: the Wonderbolt statue on its stone pedestal.
##   Lounge: cloud sofa (a couch) and armchair, two glass tables, the green lamp, bolt curtains, rug.
##   Music corner: red chaise (a couch) with the pink blanket, the flying V leaning on its amp,
##   Wonderbolts poster, Celestia's sun banner, star ball, books and comics, the helmet bust.
##   Upstairs: her cloud bed, a guest cloud bed, bedside tables with books and a picture frame,
##   the uniform closet and the trophy shelf.
## Placed by the layout's zones and windows, clear of the door path, the stair and its foot, and
## the architecture's columns (architecture_ornament.gd: the door pair, the stair-foot column and
## the free column by the flight).
## Beds follow golden_oak/interior.gd and house_interior.gd: ensure_bed(), bed_side(),
## bed_rest(), on_mattress(); metas bed_size, mattress_top and side_local.
## dev: "make sure the mares TOUCH the bed not float off of it. slightly clip into the bed as to
## simulate depressing into the foam." Each cloud bed's physics mattress is level with its drawn
## quilt at mattress_top; bed_rest() starts a sleeper on it and pony_posture.gd presses her into
## the drawn cloud (world/life/couch/mattress.gd measures the bed's meshes).
const LAYOUT := preload("res://world/buildings/cloudominium/layout.gd")
const SHAPES := preload("res://world/buildings/cloudominium/furniture_shapes.gd")
const BEDS := preload("res://world/buildings/cloudominium/furniture_beds.gd")
const LOUNGE := preload("res://world/buildings/cloudominium/furniture_lounge.gd")
const MUSIC := preload("res://world/buildings/cloudominium/furniture_music.gd")
const DISPLAY := preload("res://world/buildings/cloudominium/furniture_display.gd")
const GUEST_REST := preload("res://world/relationships/shared_bed.gd")
const CANDLES := preload("res://world/props/candles/candles.gd")
const OWNER := "rainbow_dash"
## Her bed: quilt and physics mattress height, and its size (wide enough for Anon beside her;
## home.gd lays sharers 0.48 m either side of the middle).
const BED_TOP := 0.56
const BED_WIDTH := 2.0
const BED_LENGTH := 2.2

var layout: Dictionary = {}
var radius := 4.2
var ground_y := 0.0
var upper_y := 4.8
var beds: Dictionary = {}
var _built := false

func build(room: Dictionary = {}) -> void:
	if _built:
		return
	# Jolt keeps the scale a body enters with: refuse an inherited scale before adding any.
	if is_inside_tree() and not global_basis.get_scale().is_equal_approx(Vector3.ONE):
		push_error("Cloudominium furniture requires a unit-scale frame before build().")
		return
	_built = true
	layout = room if not room.is_empty() else LAYOUT.defaults()
	radius = float(layout.get("radius", 4.2))
	ground_y = float(layout.get("ground_y", 0.0))
	upper_y = float(layout.get("upper_y", 4.8))
	_build_hall(_zone("entrance_statue"))
	_build_lounge(_zone("lounge"))
	_build_music(_zone("music_corner"))
	_build_bedroom(_zone("bedroom"))
	_build_trophies(_zone("trophy_wall"))
	_set_walk_points()
	# Anon's physical bed rest (shared_bed.gd, no relationship needed, as in Golden Oak).
	# home.gd adopts it by this name and points it at the house's bed interface.
	var rest := GUEST_REST.new()
	rest.name = "GuestBedRest"
	rest.set("house", self)
	add_child(rest)

func _build_hall(zone: Dictionary) -> void:
	var angle := float(zone.get("angle", 180.0))
	var distance := float(zone.get("distance", 2.6))
	var stair: Dictionary = layout.get("stair", {})
	# Where the curved stair passes behind her, keep the spread wings inside its inner rail.
	if _within(angle, float(stair.get("start_angle", 150.0)), float(stair.get("end_angle", 290.0))):
		distance = minf(distance, float(stair.get("inner_radius", 2.7)) - 0.8)
	DISPLAY.wonderbolt_statue(self, SHAPES.facing_centre(distance, angle, ground_y))

func _build_lounge(zone: Dictionary) -> void:
	var from := float(zone.get("from", 35.0))
	var to := from + fposmod(float(zone.get("to", 125.0)) - from, 360.0)
	var windows := _windows(false, from, to)
	# The sofa stands in front of the later window with curtains either side (lounge
	# reference), kept clear of the column that closes the lounge by the stair foot.
	var target := lerpf(from, to, 0.8)
	var sofa_angle := target
	var nearest := INF
	for window: Dictionary in windows:
		var a := from + fposmod(float(window.get("angle", 0.0)) - from, 360.0)
		if absf(a - target) < nearest:
			nearest = absf(a - target)
			sofa_angle = a
	var stair: Dictionary = layout.get("stair", {})
	var column := from + fposmod(float(stair.get("start_angle", 150.0)) - 20.0 - from, 360.0)
	sofa_angle = minf(sofa_angle, column - 24.0)
	var sofa_at := SHAPES.facing_centre(SHAPES.against_wall(radius, 1.02, 0.47, 0.3), sofa_angle, ground_y)
	LOUNGE.oval_rug(self, "SwirlRug", sofa_at * SHAPES.place(Vector3(0, 0, 1.3)), Vector2(1.35, 0.95))
	LOUNGE.cloud_sofa(self, sofa_at)
	var coffee := sofa_at * Vector3(0, 0, 1.45)
	LOUNGE.glass_table(self, "CoffeeTable", coffee, 0.36, 0.46)
	var candle_rng := RandomNumberGenerator.new(); candle_rng.seed = hash("cloudominium:coffee_candles")
	CANDLES.cluster(self, global_transform * Transform3D(Basis.IDENTITY, coffee + Vector3(0.1, 0.46, -0.05)), candle_rng, 4)
	var side := sofa_at * Vector3(1.38, 0, -0.1)
	LOUNGE.glass_table(self, "LampTable", side, 0.3, 0.6)
	LOUNGE.lamp(self, side + Vector3.UP * 0.6)
	var chair := SHAPES.polar(radius * 0.7, lerpf(from, to, 0.33), ground_y)
	var look := coffee - chair
	LOUNGE.cloud_armchair(self, Transform3D(Basis(Vector3.UP, atan2(look.x, look.z)), chair))
	for window: Dictionary in windows:
		LOUNGE.curtains(self, window, radius, ground_y)

func _build_music(zone: Dictionary) -> void:
	var from := float(zone.get("from", -110.0))
	var to := from + fposmod(float(zone.get("to", -35.0)) - from, 360.0)
	# The chaise along the free wall between the corner's window and the door column, its tall
	# scroll arm doorward; banner above it, poster beside the banner.
	var chaise_angle := lerpf(from, to, 0.82)
	var chaise_at := SHAPES.facing_centre(SHAPES.against_wall(radius, 0.95, 0.4, 0.12), chaise_angle, ground_y)
	MUSIC.chaise(self, chaise_at, -1.0)
	MUSIC.banner(self, _on_wall(chaise_angle - 1.5, .9, ground_y + 3.1, .008))
	# Solid lining between the measured windows; leave room for the 10-degree roll.
	MUSIC.poster(self, _on_wall(-72.0, .40, ground_y + 2.15, .008))
	MUSIC.star_ball(self, chaise_at * Vector3(0.95, 0.16, 0.7))
	MUSIC.floor_books(self, chaise_at * SHAPES.place(Vector3(-0.2, 0, 0.85), 0.3))
	# The flying V leans back on its amp under the corner's window.
	var amp_angle := lerpf(from, to, 0.48)
	var amp_distance := SHAPES.against_wall(radius, 0.26, 0.14, 0.08)
	MUSIC.amp(self, SHAPES.facing_centre(amp_distance, amp_angle, ground_y))
	MUSIC.flying_v(self, SHAPES.facing_centre(amp_distance - 0.27, amp_angle, ground_y) * Transform3D(Basis(Vector3.RIGHT, -0.26), Vector3.ZERO))
	# The helmet bust inside the stair's sweep, clear of the free column that holds the landing.
	var stair: Dictionary = layout.get("stair", {})
	var bust_distance := minf(radius * 0.55, float(stair.get("inner_radius", 2.7)) - 0.45)
	MUSIC.helmet_bust(self, SHAPES.facing_centre(bust_distance, lerpf(from, to, 0.2), ground_y))

func _build_bedroom(zone: Dictionary) -> void:
	var from := float(zone.get("from", 20.0))
	var to := from + fposmod(float(zone.get("to", 180.0)) - from, 360.0)
	# The second tier is narrower than the hall: bedroom pieces stand against its own lining.
	var wall := float(layout.get("upper_radius", radius))
	# Her bed against the widest wall between the bedroom windows, its foot to the room.
	var bed_angle := _widest_gap(true, from, to)
	var bed_distance := SHAPES.against_wall(wall, BED_WIDTH * 0.5 + 0.1, BED_LENGTH * 0.5 + 0.35, 0.12)
	var bed_at := SHAPES.facing_centre(bed_distance, bed_angle, upper_y)
	var own := BEDS.cloud_bed(self, "RainbowDashBed", bed_at, BED_WIDTH, BED_LENGTH, BED_TOP, "quilt", 2)
	# Her side of the foot: home.gd gives her the +X half when Anon shares the bed.
	own.set_meta("side_local", Vector3(BED_WIDTH * 0.24, 0, BED_LENGTH * 0.5 + 0.8))
	_keep_bed("rainbow", own)
	var table_x := BED_WIDTH * 0.5 + 0.36
	var table_z := -BED_LENGTH * 0.5 + 0.38
	BEDS.bedside_table(self, "BedsideTableLeft", bed_at * SHAPES.place(Vector3(-table_x, 0, table_z)))
	BEDS.bedside_table(self, "BedsideTableRight", bed_at * SHAPES.place(Vector3(table_x, 0, table_z)))
	BEDS.book_stack(self, bed_at * SHAPES.place(Vector3(table_x, BEDS.TABLE_TOP, table_z - 0.02), 0.2), 6, "cloudominium:bedside_books")
	BEDS.picture_frame(self, bed_at * SHAPES.place(Vector3(-table_x, BEDS.TABLE_TOP, table_z - 0.02), 0.35))
	# Candles beside her bed and on the coffee table (dev 2026-09-28), lit by a trigger on a wick.
	var candle_rng := RandomNumberGenerator.new(); candle_rng.seed = hash("cloudominium:candles")
	CANDLES.cluster(self, global_transform * bed_at * SHAPES.place(Vector3(-table_x + 0.07, BEDS.TABLE_TOP, table_z + 0.12)), candle_rng, 3)
	CANDLES.cluster(self, global_transform * bed_at * SHAPES.place(Vector3(table_x - 0.08, BEDS.TABLE_TOP, table_z + 0.14)), candle_rng, 1)
	LOUNGE.oval_rug(self, "BedsideRug", bed_at * SHAPES.place(Vector3(-0.1, 0, BED_LENGTH * 0.5 + 0.75)), Vector2(0.85, 0.5))
	# A smaller guest cloud bed on the solid floor well before the stair hole opens (dev
	# 2026-09-28: at the old spot it blocked the top of the stair). Other sleepers (and Anon,
	# until he lives here) rest in it.
	var guest_width := 1.3
	var guest_length := 2.0
	var guest_angle := fposmod(float(layout.get("stair_hole", {}).get("start_angle", 295.0)) - 50.0, 360.0)
	var guest_distance := SHAPES.against_wall(wall, guest_width * 0.5 + 0.1, guest_length * 0.5 + 0.3, 0.12)
	var guest := BEDS.cloud_bed(self, "GuestCloudBed", SHAPES.facing_centre(guest_distance, guest_angle, upper_y), guest_width, guest_length,
		BED_TOP - 0.04, "cloud_fabric", 1)
	_keep_bed("guest", guest)
	set_meta("guest_bed", guest)
	DISPLAY.uniform_closet(self, SHAPES.facing_centre(SHAPES.against_wall(wall, 0.62, 0.32, 0.1), lerpf(from, to, 0.92), upper_y))

func _build_trophies(zone: Dictionary) -> void:
	var angle := float(zone.get("from", -150.0))
	# Hung on the wall at the zone's start, but wholly over solid floor: the gallery rail along
	# the well's first edge (architecture_stair.gd) would otherwise run up under the shelf.
	var hole: Dictionary = layout.get("stair_hole", {})
	var clear := float(hole.get("start_angle", 215.0)) - 12.0
	if fposmod(angle - clear, 360.0) < 180.0:
		angle = clear
	var distance := SHAPES.against_wall(float(layout.get("upper_radius", radius)), 0.66, 0.18, 0.02)
	DISPLAY.trophy_shelf(self, SHAPES.facing_centre(distance, angle, upper_y + 1.05))

func _keep_bed(key: String, bed: Node3D) -> void:
	bed.set_meta("house", self)
	beds[key] = bed

## Candidate standing points on each storey in open floor; home.gd keeps those a pony fits.
func _set_walk_points() -> void:
	var ground: Array[Vector3] = [Vector3(0, ground_y, 1.2), Vector3(0, ground_y, -0.6)]
	for spot: Vector2 in [Vector2(1.3, 60.0), Vector2(1.4, 135.0), Vector2(1.4, -60.0), Vector2(1.3, -115.0), Vector2(2.0, 30.0), Vector2(2.0, -30.0)]:
		ground.append(SHAPES.polar(spot.x * radius / 4.2, spot.y, ground_y))
	var upper: Array[Vector3] = [Vector3(0, upper_y, 0)]
	for spot: Vector2 in [Vector2(0.75, 55.0), Vector2(0.75, 125.0), Vector2(1.5, 180.0), Vector2(1.6, 200.0), Vector2(1.4, -45.0), Vector2(1.0, 20.0), Vector2(1.6, 250.0)]:
		upper.append(SHAPES.polar(spot.x * radius / 4.2, spot.y, upper_y))
	set_meta("ground_walk_points", ground)
	set_meta("upper_walk_points", upper)
	set_meta("loft_walk_points", upper)

## Her own bed for Rainbow Dash (or no id); every other sleeper gets the guest bed.
## home.gd decides when Anon shares hers.
func ensure_bed(id: String = "") -> Node3D:
	var key := id.to_lower()
	var mine := key.is_empty() or key == OWNER or key.contains("rainbow")
	var result: Variant = beds.get("rainbow" if mine else "guest")
	if not is_instance_valid(result):
		result = beds.get("rainbow")
	if not is_instance_valid(result):
		return null
	return result as Node3D

func bed_shared(_id: String = "") -> bool:
	return false

func bed_side(id: String = "") -> Vector3:
	var bed := ensure_bed(id)
	if bed == null:
		return Vector3.INF
	var side: Vector3 = bed.get_meta("side_local", Vector3(0, 0, 1.8))
	return bed.to_global(side)

## Head to the pillows, on the physics mattress (pony_posture then presses her into the cloud).
func bed_rest(id: String = "") -> Transform3D:
	var bed := ensure_bed(id)
	if bed == null:
		return Transform3D(Basis.IDENTITY, Vector3.INF)
	var top := float(bed.get_meta("mattress_top", BED_TOP))
	return Transform3D(Basis.looking_at(-bed.global_basis.z, Vector3.UP), bed.to_global(Vector3(0, top, 0.15)))

func on_mattress(point: Vector3, id: String = "") -> bool:
	var bed := ensure_bed(id)
	if bed == null:
		return false
	var local := bed.to_local(point)
	var top := float(bed.get_meta("mattress_top", BED_TOP))
	var size: Vector3 = bed.get_meta("bed_size", Vector3(BED_WIDTH, 1.4, BED_LENGTH))
	return absf(local.y - top) <= 0.4 and absf(local.x) < size.x * 0.5 + 0.12 and absf(local.z) < size.z * 0.5 + 0.12

func _zone(key: String) -> Dictionary:
	var zones: Dictionary = layout.get("zones", {})
	if not zones.has(key):
		zones = LAYOUT.defaults().get("zones", {})
	var zone: Dictionary = zones.get(key, {})
	return zone

## Layout windows on one storey whose angle lies within [from, to] degrees.
func _windows(upper: bool, from: float, to: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for item: Variant in layout.get("windows", []):
		if not item is Dictionary:
			continue
		var window: Dictionary = item
		var high := float(window.get("y", 0.0)) >= upper_y
		if high == upper and _within(float(window.get("angle", 0.0)), from, to):
			result.append(window)
	return result

## Middle of the widest stretch of wall between the storey's windows within [from, to].
func _widest_gap(upper: bool, from: float, to: float) -> float:
	var marks: Array[float] = [from]
	var inside: Array[float] = []
	for window: Dictionary in _windows(upper, from, to):
		inside.append(from + fposmod(float(window.get("angle", 0.0)) - from, 360.0))
	inside.sort()
	marks.append_array(inside)
	marks.append(from + fposmod(to - from, 360.0))
	var best := (from + to) * 0.5
	var widest := -1.0
	for i in marks.size() - 1:
		if marks[i + 1] - marks[i] > widest:
			widest = marks[i + 1] - marks[i]
			best = (marks[i] + marks[i + 1]) * 0.5
	return best

## A flat wall piece's frame at `degrees`, `y`: its edges `gap` off the round wall.
func _on_wall(degrees: float, half_width: float, y: float, gap: float) -> Transform3D:
	var reach := radius - gap
	return SHAPES.facing_centre(sqrt(maxf(reach * reach - half_width * half_width, 0.0)), degrees, y)

static func _within(angle: float, from: float, to: float) -> bool:
	return fposmod(angle - from, 360.0) <= fposmod(to - from, 360.0)
