extends RefCounted
## Eligible owned goods. Blankets retain their separate picnic deployment contract.
const SURFACES := {
	"goods:footstool": "floor", "goods:bedside-table": "floor",
	"goods:rug-round": "floor", "goods:doormat": "floor",
	"goods:floor-cushion": "floor", "goods:pillow": "floor",
	"goods:clock": "floor", "goods:cottage-tea-set": "floor",
	"goods:table-lamp": "floor", "goods:potted-plant": "floor",
	"goods:curtains": "wall", "goods:picture": "wall",
}

## Finished paintings ("art:<id>", world/painting/) hang like the framed picture.
static func has(id: String) -> bool:
	return SURFACES.has(id) or id.begins_with("art:")

static func wall(id: String) -> bool:
	return SURFACES.get(id, "") == "wall" or id.begins_with("art:")

static func valid_loan(loan: Dictionary) -> bool:
	if not loan.has("furnishing_home"): return true
	var home: Variant = loan.furnishing_home
	return home is String and not home.is_empty() and home.length() <= 120 and has(str(loan.get("id", ""))) and loan.has("world_transform") and not loan.get("equipped", false)
