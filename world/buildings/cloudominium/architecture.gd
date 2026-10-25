extends Node3D
## Rainbow Dash's Cloudominium architecture inside the shell's room frame (dev 2026-09-28).
## References: art/references/cloudominium-2026-09-28/ (sources.json). Entrance hall: pale
## Ionic columns, the gold bolt pair over the door, black iron swirl stair rail and gallery
## ring, recessed round ceiling lights. Living room: the pale curved stair along the wall.
## Lounge: the rainbow painted across the upper wall.
## build(layout) takes shell.gd's corrected layout. Metas: "stair_path" (Array[Vector3], local:
## ground floor at the stair foot, every tread, the level top, onto the upper floor),
## "upper_landing", "stair_foot", "column_positions" (bases) and "column_radius".
## Walkable stair and landing are on layer 1; railings, columns and sills block on layer 1.
const MESH := preload("res://world/buildings/cloudominium/architecture_mesh.gd")
const STAIR := preload("res://world/buildings/cloudominium/architecture_stair.gd")
const ORNAMENT := preload("res://world/buildings/cloudominium/architecture_ornament.gd")

var stair_path: Array[Vector3] = []
var upper_landing := Vector3.ZERO
var _built := false

func build(layout: Dictionary) -> void:
	if _built:
		return
	# Refuse inherited scale before creating bodies; Jolt keeps the scale a body entered with.
	if is_inside_tree() and not global_basis.get_scale().is_equal_approx(Vector3.ONE):
		push_error("Cloudominium architecture requires a unit-scale frame before build().")
		return
	_built = true
	var mesh := MESH.new()
	var stair := STAIR.build(self, mesh, layout)
	var spec: Dictionary = stair.spec
	var landing: Vector3 = stair.landing
	stair_path.assign(stair.path)
	upper_landing = landing
	var columns := ORNAMENT.columns(self, mesh, layout, spec)
	ORNAMENT.windows(self, mesh, layout)
	ORNAMENT.door_bolts(mesh, layout)
	ORNAMENT.rainbow(mesh, layout)
	ORNAMENT.lights(self, mesh, layout)
	mesh.commit(self, "ArchitectureMesh")
	set_meta("stair_path", stair_path)
	set_meta("upper_landing", upper_landing)
	set_meta("stair_foot", stair_path[0])
	set_meta("column_positions", columns)
	set_meta("column_radius", ORNAMENT.COLUMN_CLEARANCE)
