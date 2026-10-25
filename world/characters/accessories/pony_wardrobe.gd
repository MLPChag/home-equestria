extends Node
## Pony accessories by season and gifts (dev 2026-09-29: "hats and
## scarves and hoof socks that you can gift to your mare wife or see ponies walking around with if
## its the right temperature for it like theyll wear more accessories in winter"; "trixies
## accesories").
##
## Mare, stallion and filly scarves use fitted authored skins. Other accessory replacements
## are staged separately; accepted striped thigh highs stay unchanged.
## Canon ponies wear their show accessories by default (dev 2026-10-15: "add the default
## accessories for ponies like trixies cape and hat, nursie's nurse cap, etc"): DEFAULT_WEAR
## replaces seasonal clothing in the same slot; a gift still wins its slot.
## Every few seconds each loaded pony is dressed for the season: winter brings scarves and
## rare sourced hats (and socks for some), autumn scarves, summer cowpony hats for a few; each pony
## makes the same choices. Gifts from Anon (world/relationships/hand_feeding.gd hands them over)
## are worn whatever the season, and are saved in the world ("pony_gifts").
const KINDS := ["scarf", "beanie", "sunhat", "socks", "wizard_hat", "cape", "spa-necklace", "bowtie", "necktie", "cowpony-hat", "detective-hat", "nurse-cap", "cat-eye-glasses", "aviators", "goggles", "headphones"]
const WORN_NAMES := {"scarf":"a scarf", "beanie":"a detective hat", "sunhat":"a cowpony hat",
	"socks":"striped thigh-high socks", "wizard_hat":"a wizard hat", "cape":"a cape", "spa-necklace":"a spa pendant necklace", "bowtie":"a bow tie", "necktie":"a necktie", "cowpony-hat":"a cowpony hat", "detective-hat":"a detective hat", "nurse-cap":"a nurse cap", "cat-eye-glasses":"cat-eye glasses", "aviators":"aviator glasses", "goggles":"flight goggles", "headphones":"headphones"}
const COLOURS := [Color("c8423c"), Color("3f6fb5"), Color("e0b640"), Color("5a9a55"), Color("9b5bb5"), Color("e07aa8"), Color("f0ece0"), Color("3b3b45")]
const HEADWEAR := ["beanie", "sunhat", "cowpony-hat", "detective-hat", "nurse-cap", "wizard_hat", "goggles", "headphones"]
const TRIXIE := "trixie"
## Show defaults that reuse fitted adult-mare pieces. Hair-export defaults (Applejack's hat)
## and character attachments (Vinyl's glasses, Braeburn's hat) are owned elsewhere.
## Trixie's wizard hat and cape are left off for the 0.0.1-maredev release (dev 2026-10-23:
## "remove trixie's cape and hat for the release build we can add them later"); restore
## "trixie": {"wizard_hat": 0, "cape": 0} here to bring them back.
const DEFAULT_WEAR := {
	"nurse_redheart": {"nurse-cap": 0},
	"octavia_melody": {"bowtie": 0},
}
const THIGH_HIGHS := preload("res://world/characters/accessories/pony_thigh_highs.gd")
const FITTED := preload("res://world/characters/accessories/pony_fitted_accessories.gd")
## Original source props, now only for shop displays and held gifts.
const TRIXIE_SOURCE := "res://world/characters/accessories/trixie/"
const TRIXIE_COVERAGE := preload("res://world/characters/accessories/trixie/coverage.gd")
var game: Node
var _tick := 0.0

## Read at prompt construction, never every frame. Attached items, not gift history
## or seasonal wishes, establish what is currently worn.
static func situation_line(pony: Node) -> String:
	var items: PackedStringArray = []
	for piece: Node in pony.find_children("Wear_*", "", true, false):
		if piece.is_queued_for_deletion(): continue
		var kind := String(piece.name).trim_prefix("Wear_")
		if WORN_NAMES.has(kind) and not items.has(WORN_NAMES[kind]): items.append(WORN_NAMES[kind])
	if items.is_empty(): return "- You currently have no seasonal or gifted clothing equipped."
	return "- You are currently wearing %s. You know you are wearing these items; a comment about your hat or clothes can refer to them." % ", ".join(items)

func setup(host: Node) -> void:
	game = host
	add_to_group("pony_wardrobe")

func gifts() -> Dictionary:
	var state: Dictionary = game.world_context.state
	if not state.get("pony_gifts") is Dictionary: state["pony_gifts"] = {}
	return state.pony_gifts

## Validate before the inventory transaction so a failed consume cannot grant a gift.
func can_give(pony_id: String, item_id: String, pony: Node3D = null) -> bool:
	if pony_id == TRIXIE: return false
	var parts := item_id.split(":")
	if parts.size() != 3 or parts[1] not in KINDS: return false
	if not preload("res://world/shop/shop_items.gd").has(item_id): return false
	# Validate the recipient before taking the physical item from inventory.
	if (FITTED.has(parts[1]) or FITTED.OUTFIT.has(parts[1])) and not FITTED.supports_fitted(pony): return false
	return item_id not in gifts().get(pony_id, [])

## A gift from Anon ("wear:<kind>:<colour index>"); she keeps and wears it.
func give(pony_id: String, item_id: String, pony: Node3D = null) -> bool:
	if not can_give(pony_id, item_id, pony): return false
	var list: Array = gifts().get(pony_id, [])
	list.append(item_id); gifts()[pony_id] = list
	if game.world_context.has_method("_changed"): game.world_context._changed()
	return true

func _season() -> String:
	var weather: Node = game.get_node_or_null("Weather")
	return str(weather.get("season")) if weather != null else "spring"

func _physics_process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0 or game == null: return
	_tick = 4.0
	var season := _season()
	for pony: Variant in game.mares:
		if not is_instance_valid(pony) or not (pony as Node3D).is_inside_tree(): continue
		var identity: Resource = pony.get("identity")
		if identity == null: continue
		dress(pony, str(identity.id), season)

## What she wears now: {kind: colour index}.
func wanted(id: String, season: String) -> Dictionary:
	var result := {}
	var roll := absi(hash(id))
	var colour := roll % COLOURS.size()
	match season:
		"winter":
			result.scarf = colour
			if roll % 12 == 0: result.beanie = (colour + 3) % COLOURS.size()
			if roll % 2 == 0: result.socks = (colour + 5) % COLOURS.size()
		"autumn":
			if roll % 5 < 3: result.scarf = colour
		"summer":
			if roll % 16 == 0: result.sunhat = 2
	var defaults: Dictionary = DEFAULT_WEAR.get(id, {})
	for kind: String in defaults:
		var default_slot := FITTED.slot(kind)
		for other: String in result.keys():
			if not default_slot.is_empty() and FITTED.slot(other) == default_slot: result.erase(other)
		result[kind] = int(defaults[kind])
	# Trixie keeps her showmare outfit; gifts are not fitted to her covered mane yet.
	if id == TRIXIE: return result
	for gift: String in gifts().get(id, []):
		var parts := gift.split(":")
		if parts.size() != 3: continue
		# The latest gift wins within its physical slot, preserving gift history.
		var slot := FITTED.slot(parts[1])
		if not slot.is_empty():
			for kind: String in result.keys():
				if FITTED.slot(kind) == slot: result.erase(kind)
		result[parts[1]] = int(parts[2])
	return result

func dress(pony: Node3D, id: String, season: String) -> void:
	var want := wanted(id, season)
	if not FITTED.supports_fitted(pony):
		for kind: String in want.keys():
			if FITTED.has(kind) or FITTED.OUTFIT.has(kind): want.erase(kind)
	var worn: Dictionary = pony.get_meta("wardrobe", {})
	if worn == want: return
	for kind: String in worn.keys():
		if not want.has(kind) or int(want[kind]) != int(worn[kind]):
			for old: Node in pony.find_children("Wear_" + kind + "*", "", true, false):
				# Release the name before attaching its replacement in this tick.
				# Deferred deletion alone renames the new piece, losing awareness
				# and preventing the next outfit change from finding it.
				old.get_parent().remove_child(old)
				old.queue_free()
	for kind: String in want:
		if worn.has(kind) and int(worn[kind]) == int(want[kind]): continue
		_attach(pony, kind, COLOURS[int(want[kind]) % COLOURS.size()])
	pony.set_meta("wardrobe", want.duplicate())
	_update_original_hat(pony, want)

## Canonical hair exports can include a hat. Replace it while a gift is worn,
## including cached near/far meshes, and restore it when the gift is removed.
func _update_original_hat(pony: Node3D, want: Dictionary) -> void:
	var hair: Node3D = pony.get("hair")
	var identity: Resource = pony.get("identity")
	if hair == null or identity == null: return
	var original_hats: Array[MeshInstance3D] = []
	for name: String in identity.accessories:
		if not name.ends_with("Hat"): continue
		var mesh := hair.find_child(name, true, false) as MeshInstance3D
		if mesh != null: original_hats.append(mesh)
	if original_hats.is_empty(): return
	var covered := false
	for kind: String in HEADWEAR:
		if want.has(kind): covered = true; break
	if covered == bool(pony.get_meta("wardrobe_covers_hat", false)): return
	var variant := str(pony.get_meta("geometry_variant", "")).replace("|wardrobe-hat", "")
	pony.refresh_geometry_variant(variant + ("|wardrobe-hat" if covered else ""))
	for mesh: MeshInstance3D in original_hats: mesh.visible = not covered
	pony.set_meta("wardrobe_covers_hat", covered)

func _attach(pony: Node3D, kind: String, colour: Color) -> void:
	var body: Skeleton3D = pony.get("skeleton")
	if FITTED.has(kind):
		FITTED.attach_fitted(pony, kind)
		return
	if FITTED.OUTFIT.has(kind):
		var piece := FITTED.attach_outfit(pony, kind)
		if piece != null and kind == "wizard_hat":
			# Her derived mane drops only the strands under the brim; removal restores it.
			TRIXIE_COVERAGE.apply(pony, true)
			piece.tree_exited.connect(TRIXIE_COVERAGE.hat_removed.bind(pony))
		return
	match kind:
		"scarf":
			if FITTED.supports(pony):
				FITTED.attach_scarf(pony, colour)
				return
			# Around the neck: the ring's axis follows the neck toward the head.
			var up := Vector3.UP
			if body != null and body.find_bone("pony_neck1") >= 0 and body.find_bone("pony_head") >= 0:
				up = (_bone_world(body, "pony_head").origin - _bone_world(body, "pony_neck1").origin).normalized()
			_on_bone(body, "pony_neck1", kind, _legacy_scarf(colour), pony, Vector3.ZERO, _basis_with_up(pony, up))
		"socks":
			THIGH_HIGHS.attach(pony, colour)

static func _bone_world(skeleton: Skeleton3D, bone: String) -> Transform3D:
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone))

## A basis turned from the pony's own (x right, y up, -z forward) so its y points along `up`.
static func _basis_with_up(pony: Node3D, up: Vector3) -> Basis:
	var frame := pony.global_basis.orthonormalized()
	var axis := frame.y.cross(up)
	if axis.length() < 0.0001: return frame
	return Basis(axis.normalized(), frame.y.angle_to(up)) * frame

## Parent `piece` to a bone. With `pony` given, the piece is laid out in the pony's body frame
## (`frame`, offset in that frame from the bone) as she stands now, then follows the bone.
func _on_bone(skeleton: Skeleton3D, bone: String, kind: String, piece: Node3D, pony: Node3D = null, offset := Vector3.ZERO, frame := Basis.IDENTITY) -> void:
	if skeleton == null or skeleton.find_bone(bone) < 0: piece.free(); return
	var attachment := BoneAttachment3D.new()
	attachment.name = "Wear_" + kind
	attachment.bone_name = bone
	skeleton.add_child(attachment)
	attachment.add_child(piece)
	if pony != null:
		var at := _bone_world(skeleton, bone)
		var scale := pony.global_basis.get_scale().x
		piece.transform = at.affine_inverse() * Transform3D(frame.scaled(Vector3.ONE * scale), at.origin + frame * offset * scale)
	for mesh: GeometryInstance3D in piece.find_children("*", "GeometryInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

static func _mat(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new(); m.albedo_color = colour; m.roughness = 0.95
	return m

static func _mesh(parent: Node3D, mesh: Mesh, colour: Color, at := Vector3.ZERO, rot := Vector3.ZERO, scale := Vector3.ONE) -> MeshInstance3D:
	var node := MeshInstance3D.new(); node.mesh = mesh; node.material_override = _mat(colour)
	node.position = at; node.rotation = rot; node.scale = scale
	parent.add_child(node)
	return node

static func _scarf(colour: Color) -> Node3D:
	return FITTED.display_scarf(colour)

## Retained for bodies whose replacement fit has not yet been validated.
static func _legacy_scarf(colour: Color) -> Node3D:
	var root := Node3D.new(); root.name = "Scarf"
	var ring := TorusMesh.new(); ring.inner_radius = 0.075; ring.outer_radius = 0.115; ring.rings = 24; ring.ring_segments = 10
	_mesh(root, ring, colour, Vector3(0, 0.03, 0), Vector3.ZERO, Vector3(1.0, 1.6, 1.0))
	var stripe := TorusMesh.new(); stripe.inner_radius = 0.106; stripe.outer_radius = 0.12; stripe.rings = 24; stripe.ring_segments = 6
	_mesh(root, stripe, colour.lightened(0.45), Vector3(0, 0.03, 0))
	var tail := BoxMesh.new(); tail.size = Vector3(0.05, 0.14, 0.02)
	_mesh(root, tail, colour, Vector3(0.03, -0.04, 0.11), Vector3(0.3, 0, 0.15))
	_mesh(root, tail, colour, Vector3(-0.02, -0.06, 0.115), Vector3(0.35, 0, -0.1))
	return root

## Legacy inventory IDs retain their stock keys, now showing the authored replacements.
static func _beanie(_colour: Color) -> Node3D:
	return FITTED.display_fitted("beanie")

static func _sunhat() -> Node3D:
	return FITTED.display_fitted("sunhat")

## Original Source props for shop displays and held gifts; canonical textures are retained.
static func _wizard_hat(_colour: Color) -> Node3D:
	if not ResourceLoader.exists(TRIXIE_SOURCE.path_join("hat.scn")): return Node3D.new()
	var scene := load(TRIXIE_SOURCE.path_join("hat.scn")) as PackedScene
	return scene.instantiate() as Node3D if scene != null else Node3D.new()

static func _cape(_colour: Color) -> Node3D:
	if not ResourceLoader.exists(TRIXIE_SOURCE.path_join("cape.scn")): return Node3D.new()
	var scene := load(TRIXIE_SOURCE.path_join("cape.scn")) as PackedScene
	return scene.instantiate() as Node3D if scene != null else Node3D.new()

## The shop and held accessory use the same shaped, knitted thigh highs as the wearer.
static func _sock(colour: Color) -> Node3D:
	return THIGH_HIGHS.display_pair(colour)
