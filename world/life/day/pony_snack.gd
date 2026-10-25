extends Node3D
## A pony visibly eating (dev 2026-09-29: "eating food with mares"): during a day plan's "eat"
## step (world/life/day/actions/go_to.gd) a real food model sits at her mouth, follows her head,
## and shrinks bite by bite until the step ends. Pure dressing: nothing is bought
## or consumed from any stock.
const CATALOG := preload("res://world/food/food_catalog.gd")
const BITES := 5
var mare: Node3D
var food_id := "food:red-apple"
var _visual: Node3D
var _bone := -1
var _skeleton: Skeleton3D
var _timer := 3.0
var _bites := 0
## Carry mode (a "buy" step): a little shopping basket in her mouth for `carry_seconds`, taken
## home with her, not eaten.
var carry := false
var carry_seconds := 240.0
var _held_scene: PackedScene
var _lease_nav: WeakRef
var _lease_owner := ""
var _authored_transform := Transform3D.IDENTITY
## Local transform from the upper-lip frame to the authored prop origin.
## Setter allows bounded action ticks to tilt a held tool without another callback.
var offset := Transform3D.IDENTITY:
	set(value):
		offset = value
		if is_instance_valid(_visual) and _glide_left <= 0.0: _visual.transform = offset * _authored_transform
var _glide_from := Transform3D.IDENTITY
var _glide_left := 0.0
var _glide_total := 0.0

## Show the prop at `from` (holder frame, like offset) and ease it into `offset` over `seconds`:
## a letter floating out of a mailbox, a can tilting between half-second action beats.
## Per-frame work only while gliding.
func glide_from(from: Transform3D, seconds: float) -> void:
	_glide_from = from
	_glide_total = maxf(seconds, .001)
	_glide_left = _glide_total
	if is_instance_valid(_visual): _visual.transform = from * _authored_transform

## Ease from the current shown pose to a new offset.
func glide_to(to: Transform3D, seconds: float) -> void:
	var current := _visual.transform * _authored_transform.affine_inverse() if is_instance_valid(_visual) else offset
	offset = to
	glide_from(current, seconds)

## Visual-only carry. The action owns this returned holder and frees it on release.
## As with a basket, carry_seconds bounds lifetime even if an action loses its node.
static func hold(actor: Node3D, scene: PackedScene, local_offset: Transform3D) -> Node3D:
	if scene == null: return null
	return _carry(actor, scene, local_offset, "PonyCarry", 240.0)

static func _carry(actor: Node3D, scene: PackedScene, local_offset: Transform3D, node_name: String, seconds: float) -> Node3D:
	if not is_instance_valid(actor): return null
	var boop: Node = actor.get("boop_node")
	if boop == null or not is_instance_valid(boop.get("head_skeleton")): return null
	# Detach the old holder now: a queued one keeps its name until the frame ends, and the new
	# holder would be renamed and missed by the next replacement.
	for old: Node in actor.find_children(node_name, "", false, false):
		actor.remove_child(old)
		old.queue_free()
	var holder: Node3D = load("res://world/life/day/pony_snack.gd").new()
	holder.name = node_name
	holder.mare = actor
	holder.carry = true
	holder.carry_seconds = seconds
	holder._held_scene = scene
	if scene != null:
		var nav: Node = actor.get_node_or_null("Navigator")
		if is_instance_valid(nav):
			holder._lease_nav = weakref(nav)
			holder._lease_owner = str(nav.get("command_owner"))
	holder.offset = local_offset
	actor.add_child(holder)
	return holder

## The dish for a place: a Sugarcube Corner treat (a cupcake, a muffin or another pastry), Hayburger
## burgers, the stand's carrot dogs.
const SUGARCUBE_TREATS := ["cupcake", "cupcake", "blueberry-muffin", "chocolate-chip-muffin", "banana-nut-muffin", "croissant",
	"cinnamon-roll", "cherry-danish", "sprinkle-donut", "chocolate-chip-cookie", "strawberry-cake-slice"]
static func dish_for(place: String) -> String:
	if "sugarcube" in place: return "food:" + str(SUGARCUBE_TREATS.pick_random())
	if "burger" in place: return "food:hayburger"
	if "hotdog" in place: return "food:carrot-dog"
	return "food:red-apple"

## After buying something: she carries a basket for a while (bulk prompt package 12,
## "carry purchases home visibly").
static func carry_basket(actor: Node3D, seconds := 240.0) -> Node3D:
	return _carry(actor, null, Transform3D.IDENTITY, "PonyBasket", seconds)

static func attach(actor: Node3D, place: String) -> Node3D:
	var boop: Node = actor.get("boop_node")
	if boop == null or not is_instance_valid(boop.get("head_skeleton")): return null
	var snack: Node3D = load("res://world/life/day/pony_snack.gd").new()
	snack.name = "PonySnack"
	snack.mare = actor
	snack.food_id = dish_for(place)
	# Spike snacks on gems half the time, wherever he is.
	if actor.has_method("claw_frame") and randf() < 0.5: snack.food_id = "food:edible-gems"
	actor.add_child(snack)
	return snack

## Spike holds things in his claw (spike.gd claw_frame) instead of a pony's mouth.
var _claw := false

func _ready() -> void:
	var boop: Node = mare.get("boop_node")
	_skeleton = boop.head_skeleton
	_claw = mare.has_method("claw_frame")
	if _held_scene != null:
		# Same measured mouth point as Affection; new props author their bite grip at origin.
		_bone = _skeleton.find_bone("mFaceLipUpperCenter")
		if _bone < 0: _bone = _skeleton.find_bone("mFaceNoseBase")
	else:
		_bone = _skeleton.find_bone("mFaceNoseBase")
		if _bone < 0: _bone = _skeleton.find_bone("mFaceLipUpperCenter")
	top_level = true
	if carry:
		if _held_scene == null:
			_visual = _basket()
		else:
			var instance: Node = _held_scene.instantiate()
			if not instance is Node3D:
				instance.free(); queue_free(); return
			_visual = instance as Node3D
		_authored_transform = _visual.transform
		_visual.transform = offset * _authored_transform
		add_child(_visual)
		return
	var packed := CATALOG.scene(food_id)
	if packed == null: queue_free(); return
	_visual = packed.instantiate()
	if not _visual.prepare(): queue_free(); return
	add_child(_visual)

## A small woven basket with a handle, held by the handle.
static func _basket() -> Node3D:
	var root := Node3D.new(); root.name = "Basket"
	var wicker := StandardMaterial3D.new(); wicker.albedo_color = Color("b98a4e"); wicker.roughness = 0.95
	var body := CylinderMesh.new(); body.top_radius = 0.09; body.bottom_radius = 0.075; body.height = 0.09; body.material = wicker
	var bowl := MeshInstance3D.new(); bowl.mesh = body; bowl.position = Vector3(0, -0.12, 0); root.add_child(bowl)
	var handle := TorusMesh.new(); handle.inner_radius = 0.075; handle.outer_radius = 0.085; handle.material = wicker
	var arc := MeshInstance3D.new(); arc.mesh = handle; arc.rotation = Vector3(0, 0, PI * 0.5); arc.position = Vector3(0, -0.07, 0); root.add_child(arc)
	var fruit := SphereMesh.new(); fruit.radius = 0.035; fruit.height = 0.07
	var red := StandardMaterial3D.new(); red.albedo_color = Color("c0392b"); fruit.material = red
	for x: float in [-0.03, 0.03]:
		var apple := MeshInstance3D.new(); apple.mesh = fruit; apple.position = Vector3(x, -0.07, 0.01); root.add_child(apple)
	return root

func _exit_tree() -> void:
	# Generic activity props cannot survive an actor detached for streaming/replacement.
	if _held_scene != null and not is_queued_for_deletion(): queue_free()

func _process(delta: float) -> void:
	if _lease_nav != null:
		var nav: Node = _lease_nav.get_ref()
		# A live navigator detached from this mare no longer moves her: the lease is gone.
		if not is_instance_valid(nav) or not nav.is_inside_tree() or str(nav.get("command_owner")) != _lease_owner:
			queue_free(); return
	if _claw:
		if not is_instance_valid(mare): queue_free(); return
		global_transform = mare.claw_frame()
	elif not is_instance_valid(mare) or not is_instance_valid(_skeleton) or _bone < 0: queue_free(); return
	_place_at_mouth(delta)

func _place_at_mouth(delta: float) -> void:
	if not _claw:
		_follow_mouth()
	if carry:
		if _glide_left > 0.0 and is_instance_valid(_visual):
			_glide_left = maxf(_glide_left - delta, 0.0)
			var t := smoothstep(0.0, 1.0, 1.0 - _glide_left / _glide_total)
			_visual.transform = _glide_from.interpolate_with(offset, t) * _authored_transform
		carry_seconds -= delta
		if carry_seconds <= 0.0: queue_free()
		return
	_timer -= delta
	if _timer > 0.0: return
	_timer = randf_range(3.0, 6.0)
	_bites += 1
	if _claw: mare.play_gesture("eat")
	_visual.scale = Vector3.ONE * maxf(0.2, 1.0 - float(_bites) / BITES)
	if _bites >= BITES: queue_free()

func _follow_mouth() -> void:
	var nose: Transform3D = _skeleton.global_transform * _skeleton.get_bone_global_pose(_bone)
	var forward := -mare.global_basis.z.normalized()
	# Existing snack/basket dressing stays unchanged; generic tools use the actual lip.
	var at := nose.origin if _held_scene != null else nose.origin + forward * 0.05 - Vector3.UP * 0.07
	global_transform = Transform3D(mare.global_basis.orthonormalized(), at)
