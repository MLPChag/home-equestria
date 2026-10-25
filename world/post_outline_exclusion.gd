extends RefCounted
## Mask opaque character surfaces and their existing hulls out of world ink.
## No additional camera, lighting pass, skeleton or colour/depth writes.

const MASK := preload("res://shaders/post_outline_mask.gdshader")
const META := &"post_outline_exclusion"


## False when there is no world ink to exclude from (the headset: game.gd attaches the ink
## outline on desktop only). The masks would then be two wasted passes per pony surface.
static var enabled := true


static func apply_to(mesh: MeshInstance3D, hull_width: float = 0.0) -> void:
	if not enabled or mesh.mesh == null:
		return
	if mesh.has_meta(META):
		return
	# Do not replace a caller's material overlay.
	if mesh.material_overlay != null:
		push_warning("Post-outline exclusion: existing overlay on %s" % mesh.name)
		return
	var mask := ShaderMaterial.new()
	mask.shader = MASK
	mask.render_priority = 126
	if hull_width > 0.0:
		var hull := ShaderMaterial.new()
		hull.shader = MASK
		hull.render_priority = 126
		hull.set_shader_parameter("grow", hull_width)
		hull.set_shader_parameter("back_faces_only", true)
		mask.next_pass = hull
	mesh.material_overlay = mask
	mesh.set_meta(META, true)
