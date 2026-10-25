extends RefCounted
## Dip and rinse detection by distance math in palette-local space (docs/DESIGN.md 2.5, 2.16,
## 4.7). No Area3D, no Node dependency.
##
## Targets and result codes:
## - Pigment blobs: codes 0..n-1 (n = the number of blob positions given to configure(), 6 for the
##   classic palette, 10 for the easel palette).
## - Mixing wells: WELL_BASE + i (100, 101, ...).
## - The rinse cup: RINSE (-2). Nothing: NONE (-1).
##
## Heights: every dip height is measured from the paint surface of the target (the top of the
## blob, the top of the well dish; configure()), not from the board top. "d" below is the tip
## height above that surface (negative = into the paint).
##
## Dips:
## - Only the target (blob or well) whose centre is nearest to the tip in the horizontal (x, z)
##   plane can count, and only within BLOB_RADIUS / WELL_RADIUS of it.
## - A press starts when the tip is on a target and DIP_MIN_BELOW <= d <= PRESS_START_ABOVE (the
##   tip touches the paint, 3 mm tolerance). With light touches off (the classic layout, 2.5) it
##   counts at once as a normal dip. With light touches on (the paint layout, 2.16) it is pending
##   until it is decided:
##   - normal dip: d goes to -LIGHT_DEPTH (6 mm into the paint) or lower while the tip is still on
##     the target. It counts at that tick. A press that starts that deep counts at once.
##   - light touch: the press ends first (d rises above PRESS_END_ABOVE, or the tip leaves the
##     target horizontally). It counts at that tick, with last_light = true.
##   So a shallow dab counts when the brush lifts, and a deeper press counts as it goes in.
## - After a dip the detector is disarmed. It arms again when the tip rises more than
##   REARM_HEIGHT above the surface of the dipped target, or when its horizontal distance to that
##   target is more than REARM_DISTANCE. One dab gives one dip; a slide from blob to blob gives one
##   dip per blob.
## - A rinse counts when the horizontal distance to the cup centre is CUP_RADIUS or less and the
##   tip is below the water surface. The rinse arms again when the tip rises above the rim.
## - reset() drops a pending press; the brush calls it on every pick-up and drop.

const BLOB_RADIUS := 0.025
const WELL_RADIUS := 0.025
## A press starts at this height above the paint surface or lower.
const PRESS_START_ABOVE := 0.003
## No press starts deeper than this (a tip far under the paint is not a dab).
const DIP_MIN_BELOW := -0.020
## A press that goes this far into the paint is a normal dip; a shallower one is light.
const LIGHT_DEPTH := 0.006
## A pending press ends (a light touch) when the tip rises above this height over the surface.
const PRESS_END_ABOVE := 0.006
## Re-arm after a dip: the tip rises this far above the surface of the dipped target...
const REARM_HEIGHT := 0.020
## ...or moves this far from its centre horizontally (more than the 0.025 m target radius, so a
## wobble on the target never re-arms; less than the 0.065 m target spacing).
const REARM_DISTANCE := 0.035
const CUP_RADIUS := 0.035
const NONE := -1
const RINSE := -2
const WELL_BASE := 100

## True when the last dip that update() returned was a light touch. False after a normal dip, a
## rinse and reset().
var last_light: bool = false

var _blob_xz: PackedVector2Array = PackedVector2Array()
var _well_xz: PackedVector2Array = PackedVector2Array()
var _blob_surface_y: float = 0.0
var _well_surface_y: float = 0.0
var _light_touch: bool = true
var _cup_xz: Vector2 = Vector2.ZERO
var _water_y: float = 0.0
var _rim_y: float = 0.0
var _has_cup: bool = false

var _armed: bool = true
var _last_target: int = NONE
var _pending: int = NONE
var _rinse_armed: bool = true


## [param blob_xz] is indexed by pigment index (any count below WELL_BASE), [param well_xz] by
## well index. The heights are palette-local y values. A rim at or below the water disables the cup.
## [param blob_surface_y] and [param well_surface_y] are the paint surfaces (blob top, dish top)
## that the dip heights are measured from; NAN uses [param board_top_y]. [param light_touch] false
## (the classic layout) makes every press a normal dip that counts at once.
func configure(blob_xz: PackedVector2Array, board_top_y: float, cup_xz: Vector2, water_y: float,
		rim_y: float, well_xz: PackedVector2Array = PackedVector2Array(),
		blob_surface_y: float = NAN, well_surface_y: float = NAN, light_touch: bool = true) -> void:
	_blob_xz = blob_xz.slice(0, WELL_BASE)
	if blob_xz.size() > WELL_BASE:
		push_warning("PaintingDipDetector: only the first %d blobs are used" % WELL_BASE)
	_well_xz = well_xz.duplicate()
	_blob_surface_y = board_top_y if is_nan(blob_surface_y) else blob_surface_y
	_well_surface_y = board_top_y if is_nan(well_surface_y) else well_surface_y
	_light_touch = light_touch
	_cup_xz = cup_xz
	_water_y = water_y
	_rim_y = rim_y
	_has_cup = rim_y > water_y
	reset()


## Armed, no pending press, no last target, rinse armed, last_light false.
func reset() -> void:
	_armed = true
	_last_target = NONE
	_pending = NONE
	_rinse_armed = true
	last_light = false


## One tick. Returns a pigment index (0..n-1), a well code (WELL_BASE + i), RINSE, or NONE.
## After a dip, last_light tells a light touch from a normal dip. A non-finite tip is NONE and
## does not change the state.
func update(tip_local: Vector3) -> int:
	if not tip_local.is_finite():
		return NONE
	var xz := Vector2(tip_local.x, tip_local.z)

	if _has_cup:
		if not _rinse_armed and tip_local.y > _rim_y:
			_rinse_armed = true
		if _rinse_armed and tip_local.y < _water_y and xz.distance_to(_cup_xz) <= CUP_RADIUS:
			_rinse_armed = false
			_pending = NONE
			last_light = false
			return RINSE

	if _pending != NONE:
		var d_press: float = tip_local.y - surface_y(_pending)
		var on_target: bool = d_press <= PRESS_END_ABOVE and nearest_target(xz) == _pending \
				and xz.distance_to(target_xz(_pending)) <= target_radius(_pending)
		if not on_target:
			return _register(_pending, true)    # the press ended before it went deep
		if d_press <= -LIGHT_DEPTH:
			return _register(_pending, false)
		return NONE

	if not _armed:
		if _last_target == NONE or tip_local.y - surface_y(_last_target) > REARM_HEIGHT:
			_armed = true
		elif xz.distance_to(target_xz(_last_target)) > REARM_DISTANCE:
			_armed = true
	if not _armed:
		return NONE

	var target: int = nearest_target(xz)
	if target == NONE or xz.distance_to(target_xz(target)) > target_radius(target):
		return NONE
	var d: float = tip_local.y - surface_y(target)
	if d < DIP_MIN_BELOW or d > PRESS_START_ABOVE:
		return NONE
	if not _light_touch or d <= -LIGHT_DEPTH:
		return _register(target, false)
	_pending = target
	return NONE


## The pigment index of the blob whose centre is nearest to [param xz]; NONE without blobs.
## Wells are not considered. On a tie the lower index wins.
func nearest_blob(xz: Vector2) -> int:
	var best: int = NONE
	var best_d2: float = INF
	for i: int in _blob_xz.size():
		var d2: float = xz.distance_squared_to(_blob_xz[i])
		if d2 < best_d2:
			best_d2 = d2
			best = i
	return best


## The code (pigment index or WELL_BASE + i) of the blob or well whose centre is nearest to
## [param xz]; NONE without targets. On a tie a blob wins over a well, and the lower index wins.
func nearest_target(xz: Vector2) -> int:
	var best: int = nearest_blob(xz)
	var best_d2: float = INF if best == NONE else xz.distance_squared_to(_blob_xz[best])
	for i: int in _well_xz.size():
		var d2: float = xz.distance_squared_to(_well_xz[i])
		if d2 < best_d2:
			best_d2 = d2
			best = WELL_BASE + i
	return best


## The palette-local (x, z) centre of a target code; Vector2.INF for an unknown code.
func target_xz(code: int) -> Vector2:
	if code >= 0 and code < _blob_xz.size():
		return _blob_xz[code]
	if is_well(code) and well_index(code) < _well_xz.size():
		return _well_xz[well_index(code)]
	return Vector2.INF


## The palette-local y of the paint surface of a target code (blob top or dish top).
func surface_y(code: int) -> float:
	return _well_surface_y if is_well(code) else _blob_surface_y


## False for the classic layout: every press is a normal dip that counts at once.
func has_light_touch() -> bool:
	return _light_touch


## BLOB_RADIUS for a blob, WELL_RADIUS for a well.
func target_radius(code: int) -> float:
	return WELL_RADIUS if is_well(code) else BLOB_RADIUS


func pigment_count() -> int:
	return _blob_xz.size()


func well_count() -> int:
	return _well_xz.size()


## True while a dip can count (for tests and debugging).
func is_armed() -> bool:
	return _armed


## The target of the press in progress (not decided yet), or NONE.
func pending_target() -> int:
	return _pending


## True for a pigment code (0..WELL_BASE-1).
static func is_pigment(code: int) -> bool:
	return code >= 0 and code < WELL_BASE


## True for a well code (WELL_BASE or more).
static func is_well(code: int) -> bool:
	return code >= WELL_BASE


## The well index of a well code; -1 for other codes.
static func well_index(code: int) -> int:
	return code - WELL_BASE if code >= WELL_BASE else -1


## The code of well [param index].
static func well_code(index: int) -> int:
	return WELL_BASE + index


func _register(code: int, light: bool) -> int:
	_pending = NONE
	_armed = false
	_last_target = code
	last_light = light
	return code
