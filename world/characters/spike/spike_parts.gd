extends RefCounted
## Small helper objects Spike carries under the same names as a pony's (pony_locomotion.gd), so
## code that asks a pony about her hoof hold, her carry pose, a throw or her stuck recovery gets
## a sensible answer from him too. He has no hooves to hold, no wings and no posed carry rig: the
## carry is his "carried" clip and the body following the hands, the throw a plain ballistic arc.

## A pony's raised/held foreleg (pony_hoof_hold.gd). Spike's claws are not held: never active.
class HoofHold extends RefCounted:
	var leg_index := -1
	func active() -> bool: return false
	func release() -> void: pass
	func reset() -> void: pass
	func raise(_side: int, _seconds := 1.8) -> bool: return false
	func push_door(_side: int, _point: Vector3, _seconds := 1.3) -> bool: return false
	func update(_point: Vector3) -> void: pass
	func candidate(_point: Vector3, _reach: float = .09) -> Dictionary: return {}
	func begin(_hit: Dictionary, _point: Vector3) -> bool: return false
	func owns(_i: int) -> bool: return false
	func grip() -> Transform3D: return Transform3D.IDENTITY
	func bind(_actor: Node) -> void: pass

## Being picked up: `blend` eases the carried clip in and out; the hands' targets live on the actor.
class Carry extends RefCounted:
	var actor: Node3D
	var blend := 0.0
	var grip_name := ""
	var look_target := Vector3.INF
	var _on := false
	func bind(owner: Node3D) -> void: actor = owner
	func active() -> bool: return _on
	func begin(grip: String, player_head: Vector3) -> void:
		_on = true; grip_name = grip; look_target = player_head
	func end() -> void:
		_on = false; grip_name = ""
	func reset() -> void:
		_on = false; blend = 0.0; grip_name = ""
	func advance(delta: float) -> void:
		blend = move_toward(blend, 1.0 if _on else 0.0, delta * 4.0)
	## Grip points: under his arms (chest, left_chest, right_chest) and his middle (belly).
	func grip_transform(grip: String) -> Transform3D:
		var basis := actor.global_basis.orthonormalized()
		var s: float = actor.body_scale
		var local := Vector3(0, 0.33, -0.02)
		match grip:
			"left_chest": local = Vector3(0.11, 0.33, -0.02)
			"right_chest": local = Vector3(-0.11, 0.33, -0.02)
			"belly": local = Vector3(0, 0.22, -0.08)
			"back": local = Vector3(0, 0.3, 0.1)
		return Transform3D(basis, actor.global_position + basis * (local * s))

## Thrown by the player: flies on a ballistic arc until he lands, then hops up.
class Throw extends RefCounted:
	var actor: CharacterBody3D
	var _active := false
	var _velocity := Vector3.ZERO
	var _air := 0.0
	func bind(owner: CharacterBody3D) -> void: actor = owner
	func active() -> bool: return _active
	func cancel() -> void: _active = false
	func launch(momentum: Vector3) -> bool:
		if momentum.length() < 0.5: return false
		_velocity = momentum.limit_length(9.0)
		_active = true; _air = 0.0
		return true
	func hop() -> void: pass
	## One physics step while thrown; returns true while it still owns the body.
	func step(delta: float) -> bool:
		if not _active: return false
		_air += delta
		_velocity.y -= 9.8 * delta
		actor.velocity = _velocity
		actor.move_and_slide()
		_velocity = actor.velocity
		if _air > 0.15 and actor.is_on_floor():
			_active = false
			actor.velocity = Vector3.ZERO
			actor.emit_signal("audio_landed", actor.global_position, absf(_velocity.y))
			return false
		return true

## A pony's water-escape helper (pony_water_escape.gd): he never needs rescuing from water by it.
class WaterEscape extends RefCounted:
	var active := false
	func reset() -> void: active = false

## A pony's stuck-placement recovery flags (placement_recovery.gd); stuck_rescue.gd clears these.
class Recovery extends RefCounted:
	var pending := false
	var _roof := false
	func picked_up(_actor: Node) -> void: pending = false
