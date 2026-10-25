extends RefCounted
## One rigid enlargement of the original OpenPony head, including its complete face rig.
## Pivot: centroid of the 40 shared head/body neck-rim positions, in OP model-root space.
## Only the body's existing neck loft is reshaped offline to meet that enlarged opening.
const HEAD_SCALE := 1.4
const HEAD_PIVOT := Vector3(0.0, 0.7861495, -0.21857725)
const BODY_PIVOT := Vector3(0.0, 0.6756495, -0.08837725)
const NECK_BOTTOM := 0.520
const NECK_TOP := 0.6955

static func head_frame() -> Transform3D:
	return Transform3D(Basis.from_scale(Vector3.ONE * HEAD_SCALE), HEAD_PIVOT * (1.0 - HEAD_SCALE))

static func neck_factor(p: Vector3) -> float:
	# Extend the transition down the neck, not just the last 6 cm at the jaw.
	# The rear mask keeps the withers/back outside this neck-only adjustment.
	return smoothstep(NECK_BOTTOM, NECK_TOP, p.y - 0.25 * p.z) * (1.0 - smoothstep(0.02, 0.12, p.z))

static func neck_point(p: Vector3) -> Vector3:
	return p + (p - BODY_PIVOT) * ((HEAD_SCALE - 1.0) * neck_factor(p))

## Differential of neck_point; normals follow the same smooth deformation.
static func neck_basis(p: Vector3) -> Basis:
	var t: float = clampf((p.y - 0.25 * p.z - NECK_BOTTOM) / (NECK_TOP - NECK_BOTTOM), 0.0, 1.0)
	var rear: float = clampf((p.z - 0.02) / 0.10, 0.0, 1.0)
	var mask: float = 1.0 - smoothstep(0.02, 0.12, p.z)
	var gradient: Vector3 = Vector3(0, 1, -0.25) * (6.0 * t * (1.0 - t) / (NECK_TOP - NECK_BOTTOM)) * mask
	gradient.z -= smoothstep(NECK_BOTTOM, NECK_TOP, p.y - 0.25 * p.z) * 6.0 * rear * (1.0 - rear) / 0.10
	var delta: Vector3 = (p - BODY_PIVOT) * (HEAD_SCALE - 1.0)
	var scale: float = 1.0 + (HEAD_SCALE - 1.0) * neck_factor(p)
	return Basis(Vector3.RIGHT * scale + delta * gradient.x, Vector3.UP * scale + delta * gradient.y, Vector3.BACK * scale + delta * gradient.z)
