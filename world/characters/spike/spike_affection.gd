extends Node
## Spike's answer to a pony's affection node (pony_affection.gd, named "Affection" so the
## relationship runtime, kisser, director and fidgets find it). He is a child: a kiss from the
## player is a forehead kiss (he goes red and grins), a hug is a hug, and [buck_player] becomes a
## grumpy little back-kick with a tail swish. Stretch and yawn fidgets play as clips.

var spike: CharacterBody3D
var kind := ""
var afterglow_left := 0.0
var elapsed := 0.0
var target := Vector3.ZERO
var amount := 0.0
var deep := false
var initiated_by_pony := false
var eye := Vector3.INF
var face := Basis.IDENTITY
var _return_serial := -1
var _left := 0.0
var _fidget := ""
var _buck_left := -1.0
var _fidget_left := 0.0

func mouth_point() -> Vector3:
	return spike.global_transform * (Vector3(0, 0.44, -0.24) * float(spike.body_scale))

func begin(value: String, point: Vector3, by_him := false) -> bool:
	if spike.sleeping and value != "cuddle": return false
	target = point
	initiated_by_pony = by_him
	match value:
		"kiss":
			# A forehead kiss: short, no hold, no deep kiss.
			kind = "forehead"
			_left = 1.6
			if spike.boop_node != null: spike.boop_node.play_kiss()
			spike.expressions.fluster(3.0)
			spike.physical_reaction.emit("forehead_kiss")
			afterglow_left = 4.0
			return true
		"cuddle", "hug":
			kind = "hug"
			_left = 6.0
			spike.set_meta("affection_active", true)
			return true
	return false

func end() -> void:
	if kind == "hug": spike.remove_meta("affection_active")
	kind = ""
	_left = 0.0

func cancel_afterglow() -> void:
	afterglow_left = 0.0

func kissing_face() -> bool:
	return false

func buck(_player: Node) -> bool:
	if not spike.play_action("kick"): return false
	_buck_left = 1.1
	spike.set_dialogue_expression("annoyed")
	spike.finish_dialogue_expression()
	return true

func work_buck() -> bool: return false
func cancel_work_buck() -> void: pass
func buck_time() -> float: return 1.1 - _buck_left if _buck_left >= 0.0 else -1.0

func fidget(what: String, _left_side := true) -> bool:
	if not _fidget.is_empty() or spike.is_speaking(): return false
	var played: bool = spike.play_action("cheer") if what == "stretch" else (spike.play_gesture("shrug") if what == "yawn" else false)
	if not played: return false
	_fidget = what
	_fidget_left = 1.6
	if what == "yawn": spike.mouth_hold(1.2, 0.9)
	return true

func fidget_active() -> bool: return not _fidget.is_empty()
func cancel_fidget() -> void: _fidget = ""

func _process(delta: float) -> void:
	elapsed += delta
	afterglow_left = maxf(0.0, afterglow_left - delta)
	if _buck_left >= 0.0:
		_buck_left -= delta
		if _buck_left < 0.0: _buck_left = -1.0
	if not _fidget.is_empty():
		_fidget_left -= delta
		if _fidget_left <= 0.0: _fidget = ""
	if kind.is_empty(): return
	_left -= delta
	if _left <= 0.0: end()
