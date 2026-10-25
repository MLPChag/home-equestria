extends RefCounted
## interior range extracted from house_interior.gd.
## State and callback dispatch stay on the owning instance; authored transforms and order are unchanged.




static func limit_range(root:Node,end:float,fade:bool) -> void:
	var nodes:Array[Node]=[root]
	nodes.append_array(root.find_children("*","GeometryInstance3D",true,false))
	for node in nodes:
		var gi:=node as GeometryInstance3D
		# Keep anything that already stops sooner (furniture 40 m, shelf books 30 m).
		if gi==null or (gi.visibility_range_end>0.0 and gi.visibility_range_end<=end):continue
		gi.visibility_range_end=end
		gi.visibility_range_end_margin=4.0 if fade else 6.0
		gi.visibility_range_fade_mode=GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF if fade else GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

static func _apply_interior_range(context: Node3D) -> void:
	# Looked up, not named: SceneTree fixtures load this script before autoload globals exist.
	var quality:Node=context.get_node_or_null("/root/Quality")
	context._range_cap=float(quality.get_value("interior_range",0.0)) if quality!=null else 0.0
	if (context._range_cap as float)<=0.0:return
	(context._range_originals as Dictionary).clear()
	for node in context.find_children("*","GeometryInstance3D",true,false):
		var gi:=node as GeometryInstance3D
		if gi==null:continue
		# Approved room architecture stays to 60 m, overlapping the 55–59 m
		# window glow. The door's shorter cap applies to ordinary room contents.
		if gi.find_parent("AuthoredLining")!=null:continue
		(context._range_originals as Dictionary)[gi]=gi.visibility_range_end
	context._set_interior_range(false)
	var timer:=context.get_node_or_null("InteriorRangeTimer") as Timer
	if timer==null:
		timer=Timer.new();timer.name="InteriorRangeTimer";timer.wait_time=0.5;timer.autostart=true;context.add_child(timer)
		timer.timeout.connect(context._tend_interior_range)

static func _tend_interior_range(context: Node3D) -> void:
	var leaf:=(context.door() as Node)
	var open:bool=leaf!=null and leaf.has_method("opening_angle") and absf(float(leaf.opening_angle()))>0.3
	if open!=(context._range_door_open as bool):context._set_interior_range(open)

static func _set_interior_range(context: Node3D, open:bool) -> void:
	context._range_door_open=open
	for gi:GeometryInstance3D in (context._range_originals as Dictionary):
		if not is_instance_valid(gi):continue
		var own:float=float((context._range_originals as Dictionary)[gi])
		if open:
			gi.visibility_range_end=own
		else:
			gi.visibility_range_end=(context._range_cap as float) if own<=0.0 or own>(context._range_cap as float) else own
			gi.visibility_range_end_margin=2.0
			gi.visibility_range_fade_mode=GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

## Far door detail (perf push 2026-10-14). Every house door drew its pulls, leaf board and inside
## artwork at any distance (about 2-3 draws per house in every town view).
## - The pulls are a 4 cm bar, about a pixel wide past 30 m: they fade out over the 8 m up to PULL_RANGE.
## - While a door is shut, the back of its leaf (the leaf board and the inside artwork) can only be
##   seen from the room or through a window, and the room's lining stops at LINING_RANGE
##   (mare_home_lining.gd; the far-window glow covers the panes from 55-59 m). Shut, they stop at
##   that range too; open, they get their own ranges back.
## Read from the house side every half second (no change to hinged_door.gd): a door opened far
## away shows its back within half a second, while the leaf is still nearly closed.
const PULL_RANGE := 40.0
const PULL_FADE := 8.0
const SHUT_BACK_RANGE := 60.0
const SHUT_BACK_MARGIN := 6.0
const DOOR_SHUT := 0.02   # radians, hinged_door.gd SHUT
const BACK_PARTS := ["LeafThickness", "InsideArtwork"]

static func start_door_detail(context: Node3D) -> void:
	if context.get_node_or_null("DoorDetailTimer") != null: return
	var timer := Timer.new(); timer.name = "DoorDetailTimer"; timer.wait_time = 0.5; timer.autostart = true
	context.add_child(timer)
	timer.timeout.connect(Callable(context, "_tend_door_detail"))

## `doors`: per door, its last open state and its parts' own ranges (kept between calls).
static func tend_door_detail(context: Node3D, doors: Dictionary) -> void:
	var house: Node = context.get_parent()
	if house == null: return
	if doors.is_empty():
		for child: Node in house.get_children():
			if child.is_in_group("house_doors") and child.has_method("opening_angle"): doors[child] = {"open": -1, "parts": {}}
		if doors.is_empty(): return
	for door: Variant in doors:
		if not is_instance_valid(door): continue
		var leaf: Node3D = door
		var entry: Dictionary = doors[door]
		# The door builds its pulls deferred (and can rebuild them): set the range when they appear.
		var pulls: GeometryInstance3D = leaf.get_node_or_null("PullHandles") as GeometryInstance3D
		if pulls != null and pulls.visibility_range_end != PULL_RANGE:
			pulls.visibility_range_end = PULL_RANGE
			pulls.visibility_range_end_margin = PULL_FADE
			pulls.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		var parts: Dictionary = entry.parts
		if parts.is_empty():
			for part_name: String in BACK_PARTS:
				var part: GeometryInstance3D = leaf.get_node_or_null(part_name) as GeometryInstance3D
				if part != null: parts[part] = [part.visibility_range_end, part.visibility_range_end_margin, part.visibility_range_fade_mode]
		var open: int = 1 if absf(float(leaf.call("opening_angle"))) >= DOOR_SHUT else 0
		if open == int(entry.open): continue
		entry.open = open
		for key: Variant in parts:
			if not is_instance_valid(key): continue
			var gi: GeometryInstance3D = key
			var own: Array = parts[key]
			var end: float = own[0]
			if open == 0 and (end <= 0.0 or end > SHUT_BACK_RANGE):
				gi.visibility_range_end = SHUT_BACK_RANGE
				gi.visibility_range_end_margin = SHUT_BACK_MARGIN
				gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			else:
				gi.visibility_range_end = end
				gi.visibility_range_end_margin = own[1]
				gi.visibility_range_fade_mode = own[2]
