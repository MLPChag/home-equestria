extends "res://world/props/lamps/lamp.gd"
## Ponyville lamp kit (dev 2026-10-14: "add lamps to every house and recreate these lamps"), built
## with the Blender MCP in art-source/lamps-2026-10-14 and exported to world/props/lamps/kit:
## yellow glass with dark swirl lines, wrought iron, brass, an aubergine or blue vase base.
## Each lamp has one small shadowless light. At night the sky's lamp budget (the "night_lights"
## group, sky_controller._update_lamps / street_lamps.gd apply) brings it up and the glass glows.
## The shared LampSwitch turns a lamp on or off by hand; that holds until the next dawn or dusk,
## when the lamp goes back to following the night. Indoor lamps in a town house follow their
## household instead (the household lamps runtime, dev 2026-10-17): on while somepony who lives there
## is home and up after dark; a hand switch then holds until the household next switches.
const STREET := preload("res://world/street_lamps.gd")
const DIR := "res://world/props/lamps/kit/"
const SCRIPT_PATH := "res://world/props/lamps/kit_lamp.gd"
## Material names written by the Blender build (lib.py): these glow while the lamp is lit.
const GLOWING := {"lamp_glass": 1.5, "lamp_glass_lime": .9, "lamp_glow_inner": 2.2, "lamp_flame": 2.6}
## Light point in model metres (+Z is the front, away from a wall), range, night energy.
## outdoor: keeps off house interiors' render layer, like street lamps. overhead: the walk grid
## must not read the lamp's collider as floor.
const KINDS := {
	"table_lamp": {"light": Vector3(0, .42, 0), "range": 3.4, "energy": .75},
	"side_table_lamp": {"light": Vector3(0, 1.04, 0), "range": 3.6, "energy": .8},
	"cone_lamp": {"light": Vector3(0, .87, 0), "range": 3.8, "energy": .85},
	"pendant": {"light": Vector3(0, -.65, 0), "range": 4.2, "energy": .9, "overhead": true},
	"wall_sconce": {"light": Vector3(0, .13, .2), "range": 3.0, "energy": .6, "overhead": true},
	"candle_niche": {"light": Vector3(0, .16, .09), "range": 2.0, "energy": .3, "overhead": true},
	"wall_lantern": {"light": Vector3(0, -.15, .32), "range": 5.5, "energy": 1.4, "outdoor": true, "overhead": true},
}
## Indoor lamps only matter close by: they fade out between these distances (metres).
const INDOOR_FADE := Vector2(14.0, 6.0)
const LIGHT_COLOR := Color("ffd9a0")

var kind := ""
var _installed := false
var _manual := false
var _household := false
var _glow: Array[Dictionary] = []   # {mesh, surface, source}
static var _lit_materials: Dictionary = {}

## A whole lamp (model and switch) for direct placement. The node's origin is the model's origin:
## floor base, ceiling point (pendant) or wall point (wall pieces).
static func create(kind_name: String) -> Node3D:
	var lamp: Node3D = (load(SCRIPT_PATH) as GDScript).new()
	lamp.name = "Lamp_" + kind_name
	var model: Node3D = (load(DIR + kind_name + ".glb") as PackedScene).instantiate()
	model.name = "Model"
	lamp.add_child(model)
	lamp.install(kind_name, model)
	return lamp

## Lights up an existing kit model (the furnisher spawns house lamps like other furniture).
static func attach(model: Node3D, kind_name: String) -> Node3D:
	var lamp: Node3D = (load(SCRIPT_PATH) as GDScript).new()
	lamp.name = "Lamp"
	model.add_child(lamp)
	lamp.install(kind_name, model)
	return lamp

func install(kind_name: String, model: Node3D) -> void:
	kind = kind_name
	var spec: Dictionary = KINDS.get(kind, KINDS.table_lamp)
	var visual: MeshInstance3D = null
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if visual == null: visual = mesh
		for surface: int in mesh.mesh.get_surface_count():
			var source: Material = mesh.mesh.surface_get_material(surface)
			if source != null and GLOWING.has(source.resource_name):
				_glow.append({"mesh": mesh, "surface": surface, "source": source})
	if visual == null: return
	var glow_light := OmniLight3D.new()
	glow_light.name = "LampLight"
	glow_light.position = spec.light
	glow_light.light_color = LIGHT_COLOR
	glow_light.omni_range = float(spec.range)
	glow_light.omni_attenuation = .9
	glow_light.shadow_enabled = false
	glow_light.light_bake_mode = Light3D.BAKE_DISABLED
	glow_light.light_energy = 0.0
	glow_light.visible = false
	glow_light.set_meta("night_energy", float(spec.energy))
	glow_light.distance_fade_enabled = true
	if spec.get("outdoor", false):
		glow_light.light_cull_mask &= ~(1 << 16)
		glow_light.distance_fade_begin = STREET.fade_begin()
		glow_light.distance_fade_length = 20.0
	else:
		glow_light.distance_fade_begin = INDOOR_FADE.x
		glow_light.distance_fade_length = INDOOR_FADE.y
		# sky_controller re-applies the street-lamp fade to the whole group on a quality change;
		# this marks the short indoor fade that should be kept.
		glow_light.set_meta("indoor_lamp_fade", INDOOR_FADE)
	add_child(glow_light)
	# The visual is the model's own mesh: put this node at the model origin so the collider
	# (built from visual.transform) lands on it.
	transform = Transform3D.IDENTITY
	configure(visual, glow_light, true)
	if spec.get("overhead", false): collider.set_meta("navigation_ceiling", true)
	glow_light.visibility_changed.connect(_light_shown)
	_installed = true
	_follow_night()
	# Indoor lamps follow their household; the household lamps runtime finds them in this group.
	if not spec.get("outdoor", false): add_to_group("household_lamps")

func _enter_tree() -> void:
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	if clock != null and not clock.phase_changed.is_connected(_on_phase):
		clock.phase_changed.connect(_on_phase)


## Its household switched it (household lamps runtime): held like a hand switch, but not let go at dawn or
## dusk; only the household's next switch (or the player's hand) changes it.
func set_household(value: bool) -> void:
	if not _installed or not is_instance_valid(light): return
	set_lit(value)
	_household = true

func _exit_tree() -> void:
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	if clock != null and clock.phase_changed.is_connected(_on_phase):
		clock.phase_changed.disconnect(_on_phase)

## Hand switching (LampSwitch toggle). The base configure() call is not a hand switch.
func set_lit(value: bool) -> void:
	if not _installed or not is_instance_valid(light): return
	_manual = true
	light.remove_from_group(STREET.GROUP)
	light.light_energy = float(light.get_meta("night_energy", 1.0))
	light.visible = value
	lit = value
	_show_glow(value)

func is_manual() -> bool:
	return _manual

func _on_phase(_phase: int) -> void:
	if _manual and not _household: _follow_night()

## Back under the sky's night lamp budget; the sky applies the current level once per frame batch.
func _follow_night() -> void:
	_manual = false
	if not is_instance_valid(light): return
	light.add_to_group(STREET.GROUP, true)
	light.set_meta("night_needs_update", true)
	_light_shown()
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.call_group_flags(SceneTree.GROUP_CALL_DEFERRED | SceneTree.GROUP_CALL_UNIQUE, "sky_controller", "_refresh_lamps")

func _light_shown() -> void:
	if _manual or not is_instance_valid(light): return
	lit = light.visible
	_show_glow(lit)

func _show_glow(on: bool) -> void:
	for entry: Dictionary in _glow:
		var mesh: MeshInstance3D = entry.mesh
		if not is_instance_valid(mesh): continue
		mesh.set_surface_override_material(int(entry.surface), lit_material(entry.source) if on else null)

## One shared glowing copy per source material: every lit lamp of a kind uses the same one.
static func lit_material(source: Material) -> Material:
	if _lit_materials.has(source): return _lit_materials[source]
	var copy: Material = source.duplicate()
	if copy is BaseMaterial3D:
		var glass := copy as BaseMaterial3D
		glass.emission_enabled = true
		glass.emission = glass.albedo_color
		glass.emission_energy_multiplier = float(GLOWING.get(source.resource_name, 1.0))
	_lit_materials[source] = copy
	return copy
