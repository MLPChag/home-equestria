extends RefCounted
## The viewport and camera the player actually sees through.
##
## Normally that is the root viewport. With the embedded spectator (player/spectator_view.gd,
## dev 2026-10-11, Vivecraft style) the headset renders in its own SubViewport while the game
## window shows the spectator camera; gameplay (culling, LOD, sounds, "is the player looking")
## must keep using the headset's view, not the spectator's.

static var xr_viewport: Viewport


static func viewport(node: Node) -> Viewport:
	if is_instance_valid(xr_viewport):
		return xr_viewport
	return node.get_viewport() if node != null and node.is_inside_tree() else null


static func camera(node: Node) -> Camera3D:
	var vp := viewport(node)
	return vp.get_camera_3d() if vp != null else null
