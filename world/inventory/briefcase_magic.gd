extends RefCounted
## AnonPony forms and her magic: which pony form she has, and the glow on whatever a unicorn holds.
## Split out of briefcase_inventory.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning briefcase_inventory node; shared state stays there.

## Her own held thing floats close to her eyes: its aura is this faint and its hum this quiet.
const OWN_AURA := 0.3

var host: Node3D
## A unicorn's carried thing glows in her magic and her horn stays lit while she holds it
## (docs/ANONPONY_DESIGN_2026_10_01.md section 9). The magic is always reached through
## PonyForm.magic(), which keeps the horn aura out of her own view. Checked every tick, so the glow
## ends however the thing leaves: stashed, thrown, set down, swapped, eaten, fed or shelved. An open
## book is read without it, so its pages stay clear.
var _magic: Node
var _magic_item := 0
var _magic_id := ""
var _magic_meshes: Array = []
## Earth ponies and pegasi have no horn: their held thing wears the same magic aura alone, in the
## colour their eyes give them (UnicornMagic.color_for).
var _magic_aura: Node3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


## True while the player is AnonPony (world/life/player_form.gd); always false in room-scale VR.
func _pony() -> bool:
	return host.is_inside_tree() and host.PLAYER_FORM.is_pony(host.PLAYER_FORM.active(host.get_tree()))


## AnonPony's form node (any race), else null (player/pony_form.gd).
func _pony_form() -> Node:
	if not host.is_inside_tree(): return null
	var form: Node = host.PONY_FORM.find(host.get_tree())
	if form == null or not is_instance_valid(form.get("avatar")): return null
	return form


## AnonPony's form node when she is a unicorn, else null (player/pony_form.gd).
func _unicorn_form() -> Node:
	if not host.is_inside_tree(): return null
	var form: Node = host.PONY_FORM.find(host.get_tree())
	if form == null or not is_instance_valid(form.get("avatar")) or not form.is_unicorn(): return null
	return form


func _sync_magic() -> void:
	var item: Variant = host.held.get("desktop")
	var form: Node = null
	if is_instance_valid(item) and not host._book_open(item): form = _pony_form()
	var want: int = (item as Node).get_instance_id() if form != null else 0
	if want == _magic_item and (want == 0 or str((item as Node).get_meta("item_id", "")) == _magic_id): return
	_release_magic()
	if want == 0: return
	if not form.is_unicorn():
		var identity: Variant = (form.get("avatar") as Node).get("identity")
		var color: Color = host.UNICORN_MAGIC.color_for(identity) if identity is Resource else Color.MEDIUM_PURPLE
		_magic_aura = host.MAGIC_AURA.create(item as Node3D, color, OWN_AURA)
		_magic_item = want; _magic_id = str((item as Node).get_meta("item_id", ""))
		return
	var magic: Node = form.magic()
	if magic == null: return
	_magic = magic; _magic_item = want; _magic_id = str((item as Node).get_meta("item_id", ""))
	# Re-glowed when the item changes (a drink emptied): its meshes may have changed with it.
	_magic_meshes = magic.glow_object(item, OWN_AURA)
	magic.hold(true)


## The glow comes off at once when this item leaves the mouth, not one tick later.
func _unglow(item: Node) -> void:
	if _magic_item != 0 and is_instance_valid(item) and item.get_instance_id() == _magic_item: _release_magic()


func _release_magic() -> void:
	if _magic_item == 0: return
	# The GMod aura owns its own visual nodes; releasing it never changes a mesh overlay
	# or the interaction outline's saved material.
	host.UNICORN_MAGIC.unglow_object(_magic_meshes)
	if is_instance_valid(_magic_aura) and _magic_aura.has_method("release"): _magic_aura.release()
	_magic_aura = null
	if is_instance_valid(_magic): _magic.hold(false)
	_magic = null; _magic_item = 0; _magic_id = ""; _magic_meshes = []
