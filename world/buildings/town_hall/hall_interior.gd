extends "res://world/buildings/authored_home.gd"
## Public ground-floor hall. Reuses authored entry travel without residential work.
func _ready() -> void:
	super._ready()
	set_process(false); set_physics_process(false)

func inside() -> Vector3: return center()

func contains(at: Vector3, lighting: bool = false) -> bool:
	if super.contains(at, lighting): return true
	if not lighting: return false
	# Placement recovery asks about supported surfaces with lighting=true. The
	# open entrance's two authored ramps are walkable, not an accidental rooftop.
	# Keep ordinary indoor membership limited to the room above.
	var p := to_local(at) * 26.0
	if absf(p.x) > 1.775 or p.z < 6.8 or p.z > 12.35: return false
	var surface := 0.805
	if p.z > 9.56: surface = lerpf(0.0, -1.03, (p.z - 9.56) / (12.35 - 9.56))
	elif p.z > 7.12: surface = lerpf(0.805, 0.0, (p.z - 7.12) / (9.56 - 7.12))
	return absf(p.y - surface) < 0.03

func _init() -> void:
	home_kind = "town_hall"
