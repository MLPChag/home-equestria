extends MeshInstance3D
## Ink-outline pass, parented to whichever camera is live.
##
## The shader is Hannah "EMBYR" Crawford's High Quality Post Process Outline
## (MIT, see THIRD_PARTY.md) rather than one written here -- it already solves
## grazing-angle false edges and distance-remapped line width, which a
## first-pass edge detect gets wrong.
##
## It has to be a camera-child quad with a spatial shader because Forward+
## exposes the depth and normal-roughness buffers to spatial shaders only; a
## CanvasLayer/ColorRect cannot read them.
##
## Toggle with O. This look is an open art-direction question -- it sits
## differently from the "realistic lighting on stylized geometry" in VISION.md --
## so switching it off must stay trivial.

const SHADER_PATH := "res://shaders/post_outline.gdshader"
## The Mobile renderer (Quest builds) has no normal-roughness buffer: depth edges only.
const MOBILE_SHADER_PATH := "res://shaders/post_outline_mobile.gdshader"

## Named looks to A/B, since the point is comparing styles rather than landing
## on one number. Uniform names are the shader author's.
const STYLES := [
	{"name": "Off", "enabled": false},
	{
		"name": "Fine",  # thinnest usable line, pure black
		"enabled": true,
		"outlineColor": Color(0.0, 0.0, 0.0, 1.0),
		"max_thickness": 0.75, "min_thickness": 0.35,
		# Alpha stays at 1 out to a long distance so lines read as solid ink
		# rather than fading to grey a few metres away.
		"depth_threshold": 0.022, "normal_threshold": 0.62, "normal_smoothing": 0.30,
		"min_distance": 1.0, "max_distance": 260.0,
	},
	{
		"name": "Ink",  # slightly heavier, still thin
		"enabled": true,
		"outlineColor": Color(0.0, 0.0, 0.0, 1.0),
		"max_thickness": 1.05, "min_thickness": 0.45,
		"depth_threshold": 0.020, "normal_threshold": 0.55, "normal_smoothing": 0.28,
		"min_distance": 1.0, "max_distance": 240.0,
	},
	{
		"name": "Bold",  # comic-book weight, for comparison only
		"enabled": true,
		"outlineColor": Color(0.0, 0.0, 0.0, 1.0),
		"max_thickness": 1.7, "min_thickness": 0.7,
		"depth_threshold": 0.018, "normal_threshold": 0.48, "normal_smoothing": 0.22,
		"min_distance": 1.0, "max_distance": 240.0,
	},
]

var style_index := 2  # Ink by default (dev, 2026-09-08: "world outline should be ink")
var _mat: ShaderMaterial


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	# The author's setup requires flipped faces; the vertex shader writes clip
	# space directly, so the quad's own orientation is otherwise meaningless.
	quad.flip_faces = true
	mesh = quad

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH if RenderingServer.get_current_rendering_method() == "forward_plus" else MOBILE_SHADER_PATH)
	# Draw after character exclusion masks (126) and other transparent surfaces.
	_mat.render_priority = 127
	material_override = _mat

	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Never frustum-cull: its real position comes from the vertex shader, so its
	# bounds say nothing useful about where it draws.
	extra_cull_margin = 16384.0
	sorting_offset = 1000.0
	apply_style(style_index)


func apply_style(index: int) -> void:
	style_index = posmod(index, STYLES.size())
	var s: Dictionary = STYLES[style_index]
	visible = bool(s.get("enabled", false))
	if not visible:
		return
	for key in s:
		if key == "name" or key == "enabled":
			continue
		_mat.set_shader_parameter(key, s[key])


func set_style(name: String) -> void:
	for i in STYLES.size():
		if str(STYLES[i]["name"]) == name:
			apply_style(i)
			return


func style_name() -> String:
	return str(STYLES[style_index]["name"])


func cycle(step: int = 1) -> void:
	apply_style(style_index + step)
	print("[toon] style -> ", style_name())
