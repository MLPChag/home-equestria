extends RefCounted
## Show lash tips per character, as the three UV triangles openpony_lashes.gdshader draws at
## the outer upper corner of each eye (U increases away from the nose; smaller V is further
## from the lid, i.e. "up"). Dash's measured triangles are the STANDARD base; the other styles
## bend, lengthen and thicken those.

const IDENTITY := preload("res://world/characters/hybrid_mare/pony_identity.gd")

## Dash: (a, b) = base on the lid rim, c = the tip.
const STANDARD := [
	Vector2(0.692, 0.605), Vector2(0.672, 0.582), Vector2(0.876, 0.532),
	Vector2(0.675, 0.591), Vector2(0.647, 0.574), Vector2(0.830, 0.469),
	Vector2(0.651, 0.582), Vector2(0.621, 0.567), Vector2(0.752, 0.433),
]


## Returns {tips: PackedVector2Array(9), thickness: float, curl: float}.
static func tips_for(style: int) -> Dictionary:
	match style:
		IDENTITY.LashStyle.PINKIE:
			# Thinner tips that curve upward.
			return {"tips": _bend(1.0, deg_to_rad(-15.0), 0.75), "thickness": 0.75, "curl": 0.35}
		IDENTITY.LashStyle.FLUTTERSHY:
			# Long lashes sweeping outward and down (droopy eye).
			return {"tips": _bend(1.6, deg_to_rad(18.0), 1.0), "thickness": 1.0, "curl": 0.15}
		IDENTITY.LashStyle.RARITY:
			# Long, thick, curled.
			return {"tips": _bend(1.4, deg_to_rad(-8.0), 1.4), "thickness": 1.4, "curl": 0.55}
	return {"tips": PackedVector2Array(STANDARD), "thickness": 1.0, "curl": 0.0}


## Scale each tip's length about its base midpoint, rotate it (negative = toward smaller V,
## up) and widen the base.
static func _bend(length: float, angle: float, width: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 3:
		var a: Vector2 = STANDARD[i * 3]
		var b: Vector2 = STANDARD[i * 3 + 1]
		var c: Vector2 = STANDARD[i * 3 + 2]
		var mid := (a + b) * 0.5
		var half := (a - b) * 0.5 * width
		var tip := mid + ((c - mid) * length).rotated(angle)
		out.append(mid + half)
		out.append(mid - half)
		out.append(tip)
	return out
