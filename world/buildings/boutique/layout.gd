extends RefCounted
## Metres. Measured RNL shell; origin just above source floor, +Z points out the original door.
# Published town terrain peaks 0.082713 m above the former .07 m room origin.
# Lift the lining 0.11 m, leaving over 2 cm clearance; the original shell/door stay put.
const FLOOR_LIFT := 0.11
const ORIGIN := Vector3(-0.17, 0.07 + FLOOR_LIFT, 0.02)
const RADIUS := 4.68
const UPPER := 4.18
const CEILING := 6.48
const ENTRY_LANDING_Z := 5.45
const ENTRY_TOE_Z := 6.8
# Published terrain across the 1.74 m toe spans -.708 to -.796 m. Bury its low edge 2 cm.
const ENTRY_TOE_Y := -.82
static func room() -> Dictionary:
	var approach_y := lerpf(0.0, ENTRY_TOE_Y, (6.0-ENTRY_LANDING_Z)/(ENTRY_TOE_Z-ENTRY_LANDING_Z))
	return {"radius":RADIUS, "upper_radius":RADIUS, "ground_y":0.0, "upper_y":UPPER,
		"ground_ceiling_y":UPPER-.14, "ceiling_y":CEILING,
		"door_position":Vector3(.007,0,4.95), "door_width":1.7, "door_height":3.58,
		"door_inside":Vector3(0,0,2.65), "door_approach":Vector3(0,approach_y,6.0),
		"stair":{"start_angle":80.0,"end_angle":285.0,"inner_radius":3.25,"outer_radius":4.53},
		"stair_hole":{"start_angle":165.0,"end_angle":293.0,"inner_radius":3.10,"outer_radius":RADIUS}}
