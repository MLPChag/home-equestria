extends RefCounted
## Metadata-backed rest slots shared by authored beds. Callers keep their own defaults,
## shared-bed lanes and invalid-bed policy; no transform or tolerance is normalized here.
static func side(target: Node3D, fallback: Vector3) -> Vector3:
	var local: Vector3 = target.get_meta("side_local", fallback)
	return target.to_global(local)

static func rest(target: Node3D, local: Vector3) -> Transform3D:
	return Transform3D(Basis.looking_at(-target.global_basis.z, Vector3.UP), target.to_global(local))

static func on_mattress(target: Node3D, point: Vector3, fallback: Vector3) -> bool:
	var local := target.to_local(point)
	var top := float(target.get_meta("mattress_top", .6))
	var size: Vector3 = target.get_meta("bed_size", fallback)
	return absf(local.y - top) <= .4 and absf(local.x) < size.x * .5 + .12 and absf(local.z) < size.z * .5 + .12
