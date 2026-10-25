extends RefCounted
## Shared homes, not claims about biological parentage. First member keeps their house.
## Dinky/Derpy, Ruby/Berry and Noi/Golden Harvest are this world's guardian choices.
## Fillies without represented parents keep individual homes until a guardian is chosen.
const FAMILIES := [
	["applejack", "big_mcintosh", "apple_bloom"],
	# Spike lives with Twilight in the Golden Oak Library (dev 2026-10-18: "add spike").
	["twilight_sparkle", "spike"],
	["rarity", "sweetie_belle"],
	["derpy_hooves", "dinky_doo"],
	["berry_punch", "ruby_pinch"],
	["golden_harvest", "noi"],
	# User requested a random background guardian; selected once, retained across launches.
	["comet_tail", "archer"],
]

static func members(id: String) -> Array:
	for family: Array in FAMILIES:
		if id in family: return family
	return [id]

static func bedtime_key(id: String) -> String:
	return str(members(id)[0])
