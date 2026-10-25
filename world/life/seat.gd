extends Node3D
## An invisible seat you can put anywhere (dev 2026-09-26): on a sofa, a wall, a rock, a cloud.
## Place it at the sitting surface with its -Z pointing the way the sitter faces. Ponies find it
## through Seating (walk up, hop on, sit) and Anon sits on it with E (desktop) or by aiming the
## right controller at it and pulling the trigger (VR).
##
## A pony sitting here may overlap any StaticBody3D named "SeatUpper" beside this node (a
## backrest, arms); give the seat surface itself a solid body underneath so she is supported.

## How deep the seat is front to back (metres); ponies stand this far in front before hopping on.
@export var depth := 0.45
@export var for_ponies := true
@export var for_player := true
@export var floor_sit := false

func _enter_tree() -> void:
	add_to_group("pony_seats")
	if for_player: add_to_group("player_seats")
	var seating := get_tree().get_first_node_in_group("pony_seating")
	if seating != null and for_ponies: seating.register_seat(self)

func _ready() -> void:
	set_meta("depth", depth)
	if floor_sit: set_meta("floor_sit", true)

func _exit_tree() -> void:
	var seating := get_tree().get_first_node_in_group("pony_seating") if is_inside_tree() else null
	if seating != null: seating.unregister_seat(self)

## Nobody (pony or player) is sitting here.
func free_for(who: Object = null) -> bool:
	var occupant: Variant = get_meta("occupant") if has_meta("occupant") else null
	return occupant == null or not is_instance_valid(occupant) or occupant == who
