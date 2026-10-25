extends RefCounted
## Pure canvas math (docs/DESIGN.md 2.3, 2.7, 2.16, 4.6): canvas-local position -> uv -> cell,
## positional cell hysteresis for a moving tool, contact hysteresis per tool on a canvas-local z
## value, the "pushed through" limits and the surface size.
##
## Canvas-local space: the surface is a centred quad in the XY plane, +Z points to the user.
## The uv/cell formula is the one of xr-tools objects/viewport_2d_in_3d_body.gd
## global_to_viewport() (MIT): u = x / width + 0.5, v = 0.5 - y / height.
## No Node dependency.

const BRUSH_ENTER_Z := 0.004
const BRUSH_EXIT_Z := 0.010
const BRUSH_THROUGH_Z := -0.060
const SPONGE_ENTER_Z := 0.008
const SPONGE_EXIT_Z := 0.015
const SPONGE_THROUGH_Z := -0.080
## The hover band (2.3) is BRUSH_EXIT_Z < z <= HOVER_MAX_Z, for both tools.
const HOVER_MAX_Z := 0.080
const NO_CELL := Vector2i(-1, -1)
## Positional hysteresis (2.16): a tool keeps its cell until the point is this many cells past
## the cell edge.
const STICKY_MARGIN := 0.3

## The sponge tool name (same value as PaintingPaintSession.SPONGE). Any other name uses the brush
## limits.
const SPONGE := &"sponge"

const BASE_HEIGHT_M := 1.314
const MAX_WIDTH_M := 0.96

var size_m: Vector2 = Vector2(0.81, 1.314)
var cols: int = 45
var rows: int = 73


func configure(p_size_m: Vector2, p_cols: int, p_rows: int) -> void:
	size_m = p_size_m
	cols = maxi(1, p_cols)
	rows = maxi(1, p_rows)


## u = x / width + 0.5, v = 0.5 - y / height. (0, 0) is the top-left corner of the surface.
func local_to_uv(local: Vector3) -> Vector2:
	if size_m.x <= 0.0 or size_m.y <= 0.0:
		return Vector2(-1.0, -1.0)
	return Vector2(local.x / size_m.x + 0.5, 0.5 - local.y / size_m.y)


## The cell at [param uv]; NO_CELL outside [0, 1) or for a non-finite uv.
func uv_to_cell(uv: Vector2) -> Vector2i:
	if not uv.is_finite() or uv.x < 0.0 or uv.y < 0.0 or uv.x >= 1.0 or uv.y >= 1.0:
		return NO_CELL
	# mini(): a uv just below 1.0 can round up to cols in the multiply.
	return Vector2i(mini(floori(uv.x * cols), cols - 1), mini(floori(uv.y * rows), rows - 1))


## The cell under a canvas-local point (z is ignored); NO_CELL off the surface.
func local_to_cell(local: Vector3) -> Vector2i:
	return uv_to_cell(local_to_uv(local))


## The centre cell for an n x n footprint (PaintingCanvasModel.square_rect) under a canvas-local point,
## so that the square is centred on the point as well as the grid allows (2.3, 2.4). Odd n: the
## cell under the point. Even n: the square's centre is a grid corner, so this is the cell whose
## bottom-right corner is the corner nearest to the point (error at most half a cell, not 0 to 1
## cell). NO_CELL off the surface; clamped to the grid at the edges.
##
## [param prev] is the cell of the previous tick of a touch (NO_CELL = no hysteresis). The result
## stays [param prev] while the point is less than STICKY_MARGIN cells past its edge, so tracking
## jitter at a cell edge does not alternate between two cells (each change re-blends the wet
## canvas, 2.16). A move to a neighbouring cell centre or further always changes the cell.
func local_to_center_cell(local: Vector3, size: int, prev: Vector2i = NO_CELL) -> Vector2i:
	var cell: Vector2i = local_to_cell(local)
	if cell == NO_CELL:
		return cell
	var shift: float = 0.0 if maxi(1, size) % 2 == 1 else 0.5
	var uv: Vector2 = local_to_uv(local)
	var p := Vector2(uv.x * cols - shift, uv.y * rows - shift)
	if shift > 0.0:
		cell = Vector2i(clampi(floori(p.x), 0, cols - 1), clampi(floori(p.y), 0, rows - 1))
	if prev == cell or prev.x < 0 or prev.y < 0 or prev.x >= cols or prev.y >= rows:
		return cell
	if p.x > prev.x - STICKY_MARGIN and p.x < prev.x + 1.0 + STICKY_MARGIN \
			and p.y > prev.y - STICKY_MARGIN and p.y < prev.y + 1.0 + STICKY_MARGIN:
		return prev
	return cell


## The canvas-local centre of [param cell] (z = 0). Not clipped to the canvas.
func cell_to_local(cell: Vector2i) -> Vector3:
	var uv := Vector2((cell.x + 0.5) / float(cols), (cell.y + 0.5) / float(rows))
	return Vector3((uv.x - 0.5) * size_m.x, (0.5 - uv.y) * size_m.y, 0.0)


## Contact hysteresis (2.3): contact starts at z <= enter, continues while z <= exit, and ends
## when z is below the "pushed through" limit. A non-finite z is no contact.
func update_contact(z: float, was_touching: bool, tool: StringName) -> bool:
	if not is_finite(z) or z < through_limit(tool):
		return false
	if tool == SPONGE:
		return z <= (SPONGE_EXIT_Z if was_touching else SPONGE_ENTER_Z)
	return z <= (BRUSH_EXIT_Z if was_touching else BRUSH_ENTER_Z)


## True in the hover band in front of the surface: BRUSH_EXIT_Z < z <= HOVER_MAX_Z (2.3).
func is_hover(z: float) -> bool:
	return is_finite(z) and z > BRUSH_EXIT_Z and z <= HOVER_MAX_Z


## The "pushed through" z of [param tool]: below it there is no contact.
func through_limit(tool: StringName) -> float:
	return SPONGE_THROUGH_Z if tool == SPONGE else BRUSH_THROUGH_Z


## The surface size for a grid (2.7): the height is [param height_m] and the cells are square.
## When the width would exceed [param max_width_m], the width is max_width_m instead.
static func surface_size_for(p_cols: int, p_rows: int, height_m: float = BASE_HEIGHT_M,
		max_width_m: float = MAX_WIDTH_M) -> Vector2:
	var c: float = maxi(1, p_cols)
	var r: float = maxi(1, p_rows)
	var width: float = height_m * c / r
	if width > max_width_m:
		return Vector2(max_width_m, max_width_m * r / c)
	return Vector2(width, height_m)
