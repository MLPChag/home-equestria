class_name UnicornMagic
extends Node3D
## Every unicorn spell uses the accepted GMod MLP Magic Auras effect. The horn's
## anchor follows its skin's dominant bone; lifted objects and door bursts share MagicAura.
const COLORS_PATH := "res://world/characters/magic_colors.json"
const MAGIC_AURA := preload("res://world/characters/magic/magic_aura.gd")
const RISE_SECONDS := 0.18
const FALL_SECONDS := 0.4
static var _colors: Dictionary = {}
var color := Color(0.92, 0.26, 0.55)
var intensity := 0.0
var _horn: MeshInstance3D
var _skeleton: Skeleton3D
var _bone := -1
var _base_local := Vector3.ZERO
var _tip_local := Vector3.ZERO
var _built := false
var _aura: Node3D
var _anchor: Node3D
var _light: OmniLight3D
var _left := 0.0
var _held := false
var _visual_layer := 1


## The magic colour for a PonyIdentity: its own `magic_color` if set, else the colour guide
## entry for its id, else a bright version of its iris colour.
static func color_for(identity: Resource) -> Color:
	var own: Color = identity.get("magic_color") if identity.get("magic_color") != null else Color(0, 0, 0, 0)
	if own.a > 0.0: return Color(own, 1.0)
	if _colors.is_empty():
		var file := FileAccess.open(COLORS_PATH, FileAccess.READ)
		if file != null:
			var data: Variant = JSON.parse_string(file.get_as_text())
			if data is Dictionary: _colors = data.get("ponies", {})
		if _colors.is_empty(): _colors = {"_": null}
	var entry: Variant = _colors.get(str(identity.get("id")), null)
	if entry is Dictionary and str(entry.get("aura", "")).begins_with("#"):
		return Color(str(entry.aura))
	var iris: Color = identity.get("iris_color") if identity.get("iris_color") != null else Color.MEDIUM_PURPLE
	return Color.from_hsv(iris.h, clampf(iris.s, 0.45, 0.8), 0.95)


## The colour as the glow shows it: the canonical hue, pushed saturated and bright, so a pale
## canon magic (Celestia's cream, Trixie's pink) still reads unmistakably as its hue.
static func vivid(c: Color) -> Color:
	return Color.from_hsv(c.h, clampf(lerpf(c.s, 1.0, 0.5), 0.62, 1.0), 1.0)


## The magic's line colour, like a pony's outline: same hue, darker and more saturated.
static func ink(c: Color) -> Color:
	return Color.from_hsv(c.h, clampf(lerpf(c.s, 1.0, 0.7), 0.75, 1.0), 0.55)


## `horn` is the skinned horn mesh on the head skeleton.
func setup(horn: MeshInstance3D, magic_color: Color) -> void:
	_horn = horn
	color = magic_color
	set_process(false)

func is_lit() -> bool:
	return intensity > 0.0

func cast(seconds := 2.5) -> bool:
	if not _build(): return false
	_left = maxf(_left, seconds)
	set_process(true)
	return true

## Excited unicorn (excitement.gd): a brief horn flare with a small burst of sparkles at its tip.
func sparkle() -> bool:
	if not cast(.7): return false
	var tip := (_skeleton.global_transform * _skeleton.get_bone_global_pose(_bone)) * _tip_local
	burst(self, to_local(tip), vivid(color), .35, .09)
	return true

func hold(on: bool) -> void:
	if on and not _build(): return
	_held = on
	if on: set_process(true)

## First-person horn visibility persists across separate casts and recreated aura nodes.
func set_visual_layer(layer: int) -> void:
	_visual_layer = layer
	if is_instance_valid(_aura): _aura.set_visual_layer(layer)

func glow_object(target: Node, strength := 1.0) -> Array:
	if not target is Node3D: return []
	var aura: Node3D = MAGIC_AURA.create(target as Node3D, color, strength)
	return [aura] if aura != null else []

static func unglow_object(meshes: Array) -> void:
	for item in meshes:
		if not is_instance_valid(item): continue
		if (item as Object).has_method("is_magic_aura"): item.call("release")
		elif item is MeshInstance3D: (item as MeshInstance3D).material_overlay = null

## Door handles and point spells use the same disc, source sparkles and sounds.
static func burst(parent: Node3D, local_position: Vector3, magic_color: Color, seconds := 1.6, size := 0.2) -> void:
	if not is_instance_valid(parent) or not parent.is_inside_tree(): return
	var holder := Node3D.new(); holder.name = "MagicBurst"
	parent.add_child(holder); holder.position = local_position
	var aura: Node3D = MAGIC_AURA.create(holder, magic_color, 1.0, maxf(size * .6, .05))
	if aura == null: holder.queue_free(); return
	var tween := holder.create_tween()
	tween.tween_interval(maxf(seconds, .1))
	tween.tween_callback(aura.release)
	tween.tween_interval(.8)
	tween.tween_callback(holder.queue_free)

func _process(delta: float) -> void:
	_left = maxf(_left - delta, 0.0)
	var target := 1.0 if (_held or _left > 0.0) else 0.0
	var rate := 1.0 / (RISE_SECONDS if target > intensity else FALL_SECONDS)
	intensity = move_toward(intensity, target, delta * rate)
	_apply()
	if intensity <= 0.0 and target <= 0.0: set_process(false)

func _apply() -> void:
	var lit := intensity > 0.0 and is_instance_valid(_skeleton)
	_light.visible = lit
	if not lit:
		if is_instance_valid(_aura): _aura.release()
		_aura = null
		return
	var bone_world := _skeleton.global_transform * _skeleton.get_bone_global_pose(_bone)
	var base := bone_world * _base_local
	var tip := bone_world * _tip_local
	_anchor.global_position = (base + tip) * .5
	var eased := intensity * intensity * (3.0 - 2.0 * intensity)
	if not is_instance_valid(_aura):
		_aura = MAGIC_AURA.create(_anchor, color, 1.0, maxf(base.distance_to(tip) * .5 * MAGIC_AURA.MARGIN, .05))
		if is_instance_valid(_aura): _aura.set_visual_layer(_visual_layer)
	if is_instance_valid(_aura): _aura.strength = eased
	_light.global_position = tip
	_light.light_energy = .35 * eased

func _build() -> bool:
	if _built: return is_instance_valid(_skeleton)
	if not is_instance_valid(_horn) or _horn.mesh == null or _horn.skin == null: return false
	_skeleton = _horn.get_node_or_null(_horn.skeleton) as Skeleton3D
	if _skeleton == null or not _measure_horn(): return false
	_built = true
	_anchor = Node3D.new(); _anchor.name = "HornMagicAnchor"; _anchor.top_level = true
	add_child(_anchor)
	_light = OmniLight3D.new(); _light.name = "HornMagicLight"
	_light.light_color = vivid(color); _light.omni_range = .8; _light.omni_attenuation = 1.6
	_light.shadow_enabled = false; _light.top_level = true
	add_child(_light)
	_apply()
	return true


## Horn base and tip in the dominant bone's frame, from the mesh's own vertices.
func _measure_horn() -> bool:
	var arrays := _horn.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	if verts.is_empty() or bones.is_empty(): return false
	var stride := bones.size() / verts.size()
	var totals := {}
	for i in bones.size():
		totals[bones[i]] = float(totals.get(bones[i], 0.0)) + weights[i]
	var bind := 0
	for b in totals:
		if float(totals[b]) > float(totals.get(bind, -1.0)): bind = b
	_bone = _horn.skin.get_bind_bone(bind)
	if _bone < 0: _bone = _skeleton.find_bone(_horn.skin.get_bind_name(bind))
	if _bone < 0: return false
	var aabb := _horn.mesh.get_aabb()
	var cut := aabb.position.y + aabb.size.y * 0.2
	var base := Vector3.ZERO
	var count := 0
	for v in verts:
		if v.y <= cut:
			base += v
			count += 1
	base /= maxf(count, 1)
	var tip := base
	for v in verts:
		if v.distance_squared_to(base) > tip.distance_squared_to(base): tip = v
	var to_bone := _horn.skin.get_bind_pose(bind)
	_base_local = to_bone * base
	_tip_local = to_bone * tip
	return stride > 0
