extends RefCounted
## AnonPony's cutie mark: a grey question mark (Anonfilly's mark), drawn at run time so no image
## file needs a Godot import. A hook (a ring segment), a short stem and a round dot, each a
## distance test with a 2 px antialiased edge, on a transparent 256 x 256 sheet with mipmaps.
##
## Every mark sheet is stored transposed (hybrid_mark_fit.gd: "source-art X is texture V and Y
## is U"; octavia_melody.png and drwhooves.png lie on their side), so the upright glyph below is
## written with the art's rows along the image's x axis. hybrid_mark_fit reads the used rect, so
## the sheet must never be empty, and it caches the fit by this texture's instance id.

const SIZE := 256
const MARK_COLOR := Color("57575d")
## Upright art coordinates (x right, y down), in pixels of the 256 px sheet.
const HOOK_CENTER := Vector2(128.0, 96.0)
const HOOK_RADIUS := 54.0
const STROKE := 26.0
## The hook starts left of the centre, runs over the top and down the right side, and ends
## straight below the centre (160 + 290 = 450 degrees), where the stem begins.
const HOOK_START_DEGREES := 160.0
const HOOK_SWEEP_DEGREES := 290.0
const STEM_FROM := Vector2(128.0, 150.0)
const STEM_TO := Vector2(128.0, 178.0)
const DOT_CENTER := Vector2(128.0, 214.0)
const DOT_RADIUS := 17.0
## Width of the antialiased edge in pixels.
const EDGE := 2.0

static var _texture: ImageTexture


static func texture() -> ImageTexture:
	if _texture != null:
		return _texture
	var data := PackedByteArray()
	data.resize(SIZE * SIZE * 4)
	var r := MARK_COLOR.r8
	var g := MARK_COLOR.g8
	var b := MARK_COLOR.b8
	for y in SIZE:
		for x in SIZE:
			# Transposed sheet: image x is the art's row, image y the art's column.
			var art := Vector2(float(y) + 0.5, float(x) + 0.5)
			var coverage := 0.0
			# The glyph spans art x 61..195 and y 29..231; skip the empty margin.
			if art.x > 48.0 and art.x < 208.0 and art.y > 16.0 and art.y < 244.0:
				coverage = clampf(0.5 - _distance(art) / EDGE, 0.0, 1.0)
			var i := (y * SIZE + x) * 4
			# Transparent pixels keep the mark's colour, so filtering and mipmaps add no dark fringe.
			data[i] = r
			data[i + 1] = g
			data[i + 2] = b
			data[i + 3] = roundi(coverage * 255.0)
	var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, data)
	image.generate_mipmaps()
	_texture = ImageTexture.create_from_image(image)
	return _texture


## Signed distance in pixels from `p` (upright art coordinates) to the glyph: negative inside.
static func _distance(p: Vector2) -> float:
	var half := STROKE * 0.5
	var start := deg_to_rad(HOOK_START_DEGREES)
	var sweep := deg_to_rad(HOOK_SWEEP_DEGREES)
	var offset := p - HOOK_CENTER
	var hook: float
	if fposmod(atan2(offset.y, offset.x) - start, TAU) <= sweep:
		hook = absf(offset.length() - HOOK_RADIUS) - half
	else:
		# Past either end of the ring segment: round caps.
		var first := HOOK_CENTER + Vector2(cos(start), sin(start)) * HOOK_RADIUS
		var last := HOOK_CENTER + Vector2(cos(start + sweep), sin(start + sweep)) * HOOK_RADIUS
		hook = minf(p.distance_to(first), p.distance_to(last)) - half
	var stem := p.distance_to(Geometry2D.get_closest_point_to_segment(p, STEM_FROM, STEM_TO)) - half
	var dot := p.distance_to(DOT_CENTER) - DOT_RADIUS
	return minf(hook, minf(stem, dot))
