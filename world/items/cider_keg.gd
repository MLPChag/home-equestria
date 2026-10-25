extends RefCounted
## Sweet Apple Acres cider keg (dev 2026-10-14: "a mug for cider so anons can drink cider with
## their waifus, or buy a jug of cider from aj's farm for bits with a little bucket"). Sold at the
## farm stall beside the orchard sign (world/shop/shop_world.gd), carried in a little bucket, and
## bought with two empty cider mugs (world/shop/shop_purchase.gd). Bring an empty mug to the keg
## (either one in hand) and it fills (world/items/cider_pour.gd); drink by tilting the mug to your
## mouth, or hand it to a pony and she drinks it (world/relationships/hand_feeding.gd). Drinking
## with ponies close by is a shared meal (world/life/player_needs.gd).
## The pours left are part of the item id ("goods:cider-keg" full, "goods:cider-keg:<n>" after
## pours), so every save, drop and briefcase path keeps them without new save fields.
## Identity and looks only: no preloads, so the item catalogue can load it safely.
const ID := "goods:cider-keg"
const SERVINGS := 8
const MUG_FULL := "food:sweet-apple-acres-cider"
const MUG_EMPTY := "food-empty:sweet-apple-acres-cider"
const BUCKET := "res://world/props/household/fishing-bucket.scn"
const KEG := "res://world/props/ponyville_kit/barrel.glb"

static func is_keg(id: String) -> bool:
	if id == ID: return true
	if not id.begins_with(ID + ":"): return false
	var rest := id.substr(ID.length() + 1)
	return rest.is_valid_int() and int(rest) >= 0 and int(rest) < SERVINGS and str(int(rest)) == rest

static func servings(id: String) -> int:
	if id == ID: return SERVINGS
	return int(id.substr(ID.length() + 1)) if is_keg(id) else 0

static func id_for(left: int) -> String:
	return ID if left >= SERVINGS else "%s:%d" % [ID, clampi(left, 0, SERVINGS - 1)]

static func definition(id: String) -> Dictionary:
	if not is_keg(id): return {}
	var left := servings(id)
	var state := "full" if left >= SERVINGS else ("empty" if left == 0 else "%d of %d mugs left" % [left, SERVINGS])
	return {"name": "Cider keg (%s)" % state if left < SERVINGS else "Cider keg",
		"description": "Sweet Apple Acres cider in a little keg, in its carrying bucket. Bring an empty cider mug to it and it fills: %d mugs a keg. Comes with two mugs, one for you and one for her." % SERVINGS,
		"stack": 1, "price_bits": 40, "size_m": 0.34, "shop": true}

## The keg sitting in its bucket, from existing models (no new geometry). Returns the local
## bounds the inventory uses for collision; the base rests at y = 0.
static func build_visual(parent: Node3D) -> AABB:
	var bucket: Node3D = (load(BUCKET) as PackedScene).instantiate()
	bucket.name = "Bucket"
	# The source bucket is 0.36 m wide and 0.31 m to the rim: a little carrying bucket instead.
	bucket.scale = Vector3.ONE * 0.62
	parent.add_child(bucket)
	var keg: Node3D = (load(KEG) as PackedScene).instantiate()
	keg.name = "Keg"
	# 0.9 m kitchen barrel down to a 0.19 m keg standing on the bucket floor, under the handle.
	keg.scale = Vector3.ONE * 0.21
	keg.position = Vector3(0.0, 0.03, 0.0)
	parent.add_child(keg)
	for mesh: GeometryInstance3D in parent.find_children("*", "GeometryInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return AABB(Vector3(-0.115, 0.0, -0.115), Vector3(0.23, 0.30, 0.23))
