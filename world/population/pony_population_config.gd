extends RefCounted
## One home region per named pony. Config contains IDs, never executable paths.
const LIVE_PATH := "user://population/roster.json"
const DRAFT_PATH := "user://population/roster_draft.json"
const SIX := {
	"rainbow_dash": "res://world/characters/hybrid_mare/hybrid_mare.tscn",
	"twilight_sparkle": "res://world/characters/mane6/twilight_sparkle.tscn",
	"rarity": "res://world/characters/mane6/rarity.tscn",
	"pinkie_pie": "res://world/characters/mane6/pinkie_pie.tscn",
	"applejack": "res://world/characters/mane6/applejack.tscn",
	"fluttershy": "res://world/characters/mane6/fluttershy.tscn"}
const PRINCESSES := {
	"celestia": "res://world/characters/princesses/celestia.tscn",
	"luna": "res://world/characters/princesses/luna.tscn"}
const RETIRED := ["hitch_trailblazer", "aunt_holiday", "auntie_lofty", "bright_mac", "pear_butter", "sandbar"]
const FIRST_STALLIONS := ["big_mcintosh", "shining_armor", "braeburn"]
const STALLION_ROSTER_VERSION := 2
const STALLIONS := {
	"drwhooves": "ponyville",
	"soarin": "cloudsdale",
	"thunderlane": "cloudsdale",
	"braeburn": "appleloosa",
	"caramel": "ponyville",
	"pokey_pierce": "ponyville",
	"noteworthy": "ponyville",
	"night_light": "canterlot",
	"sunburst": "crystal_empire",
	"double_diamond": "starlights_village",
	"party_favor": "starlights_village",
	"dr_caballeron": "everfree",
	"prince_blueblood": "canterlot",
	"shining_armor": "canterlot",
	"igneous_rock": "rock_farm",
	"big_mcintosh": "ponyville",
	"flash_sentry": "crystal_empire",
	"jackpot": "los_pegasus",
	"comet_tail": "ponyville",
	"king_sombra": "crystal_empire",
	"compass_star": "canterlot"
}
const HOUSEHOLDS = preload("res://world/population/pony_households.gd")
## One-time activation for existing worlds; later roster edits remain authoritative.
const FILLIES := {
	"apple_bloom": "ponyville", "sweetie_belle": "ponyville", "scootaloo": "ponyville",
	"diamond_tiara": "ponyville", "silver_spoon": "ponyville", "dinky_doo": "ponyville",
	"ruby_pinch": "ponyville", "archer": "ponyville", "noi": "ponyville", "spike": "ponyville"}
var assignments: Dictionary = {}
var nearby_limit := 24
var social_groups := true
var error := ""
var filly_households_added := false
var zecora_added := false
## dev 2026-10-18: "add spike". Added once to existing worlds; later roster edits stay authoritative.
var spike_added := false
## dev 2026-10-15: "add linky to ponyville, as well as flitter, and amethyst star." Moved
## once in existing worlds (Linky was still in Los Pegasus); later roster edits stay authoritative.
const PONYVILLE_NEWCOMERS := ["shoeshine", "flitter", "amethyst_star"]
var newcomers_moved := false
## Bon Bon lives in Ponyville (dev 2026-10-23: "move bonbon to ponyville permanently"); existing
## installs had her in Canterlot.
const PONYVILLE_MOVES_2026_10_23 := ["sweetie_drops"]
var bonbon_moved := false

static func catalogue() -> Dictionary:
	var result := SIX.duplicate()
	result.merge(PRINCESSES)
	result["zecora"] = "res://world/characters/zecora/zecora.tscn"
	result["spike"] = "res://world/characters/spike/spike.tscn"
	var path := "res://world/characters/background/catalog.json"
	if FileAccess.file_exists(path):
		var extra: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if extra is Dictionary:
			for id: String in extra:
				if id not in RETIRED and not result.has(id) and ResourceLoader.exists(str(extra[id])): result[id] = str(extra[id])
	return result

static func regions() -> Array:
	return WorldLayout.regions().filter(func(r): return int(r.get("phase", 0)) < 7)

static func pony_name(id: String) -> String:
	if id == "shoeshine": return "Linky (Shoeshine)"
	return id.replace("_", " ").capitalize()

func defaults() -> void:
	assignments.clear()
	for id: String in SIX: assignments[id] = "ponyville"
	for id: String in PRINCESSES: assignments[id] = "canterlot"
	for id: String in STALLIONS:
		if catalogue().has(id): assignments[id] = STALLIONS[id]
	for id: String in FILLIES:
		if catalogue().has(id): assignments[id] = FILLIES[id]
	filly_households_added = false
	_add_filly_households(catalogue())
	assignments["zecora"] = "everfree"
	zecora_added = true
	assignments["spike"] = "ponyville"
	spike_added = true
	newcomers_moved = true
	bonbon_moved = true
	nearby_limit = 24; social_groups = true; error = ""
	# dev's own region setup is the default (2026-09-29): it overrides the code defaults above.
	_add_default_background(catalogue(), true)

## The shipped population (dev 2026-09-29: "my current region setup should be the default"):
## default_assignments.json is dev's own population file. A fresh install takes it whole
## (`override`); an existing install only gains the ponies it never assigned (a tester's
## fresh 0.3.0 install had no background mares at all, since the code defaults never placed
## them). The population tool still overrides everything per install.
const DEFAULT_ASSIGNMENTS := "res://world/population/default_assignments.json"
var background_added := false
func _add_default_background(available: Dictionary, override := false) -> void:
	var region_ids := {}
	for r: Dictionary in regions(): region_ids[str(r.id)] = true
	if FileAccess.file_exists(DEFAULT_ASSIGNMENTS):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(DEFAULT_ASSIGNMENTS))
		if data is Dictionary and data.get("assignments") is Dictionary:
			for id: String in data.assignments:
				var region := str(data.assignments[id])
				if id in RETIRED or not available.has(id) or not region_ids.has(region): continue
				if assignments.has(id) and not override: continue
				assignments[id] = region
			if override:
				var limit: Variant = data.get("nearby_limit", nearby_limit)
				if limit is float or limit is int: nearby_limit = clampi(int(limit), 1, 64)
				if data.get("social_groups") is bool: social_groups = data.social_groups
	background_added = true

func as_dict() -> Dictionary:
	return {"version": 1, "assignments": assignments.duplicate(), "nearby_limit": nearby_limit, "social_groups": social_groups, "stallions_added": true, "stallion_roster_version": STALLION_ROSTER_VERSION, "filly_households_added": filly_households_added, "zecora_added": zecora_added, "spike_added": spike_added, "background_added": background_added, "newcomers_moved": newcomers_moved, "bonbon_moved": bonbon_moved}

func apply_data(data: Variant, available: Dictionary = {}) -> bool:
	error = ""
	if not data is Dictionary or data.get("version") != 1 or not data.get("assignments") is Dictionary:
		error = "Invalid population file; expected version 1 and pony assignments."; return false
	var migration: Variant = data.get("stallion_roster_version", 0)
	if not (migration is float or migration is int) or not is_finite(float(migration)) or float(migration) != floorf(float(migration)) or int(migration) < 0 or int(migration) > STALLION_ROSTER_VERSION:
		error = "Invalid stallion roster migration version."; return false
	if not data.get("stallions_added", false) is bool:
		error = "Invalid stallion roster migration flag."; return false
	if available.is_empty(): available = catalogue()
	var region_ids := {}
	for r: Dictionary in regions(): region_ids[str(r.id)] = true
	for id in data.assignments:
		if id in RETIRED: continue
		if not available.has(id): error = "Unavailable pony: " + str(id); return false
		if not region_ids.has(data.assignments[id]): error = "Unknown region for " + str(id); return false
	var limit: Variant = data.get("nearby_limit", 24)
	if not (limit is float or limit is int) or not is_finite(float(limit)) or float(limit) != floorf(float(limit)) or int(limit) < 1 or int(limit) > 64:
		error = "Nearby population limit must be a whole number from 1 to 64."; return false
	if not data.get("social_groups", true) is bool: error = "Invalid social groups setting."; return false
	if not data.get("filly_households_added", false) is bool: error = "Invalid filly household migration flag."; return false
	if not data.get("zecora_added", false) is bool: error = "Invalid Zecora migration flag."; return false
	if not data.get("spike_added", false) is bool: error = "Invalid Spike migration flag."; return false
	if not data.get("newcomers_moved", false) is bool: error = "Invalid Ponyville newcomer migration flag."; return false
	if not data.get("bonbon_moved", false) is bool: error = "Invalid Bon Bon migration flag."; return false
	assignments = data.assignments.duplicate()
	for id: String in RETIRED: assignments.erase(id)
	nearby_limit = int(limit); social_groups = data.get("social_groups", true)
	filly_households_added = data.get("filly_households_added", false)
	if not filly_households_added: _add_filly_households(available)
	zecora_added = data.get("zecora_added", false)
	if not zecora_added and available.has("zecora"):
		# Add her once; preserve every existing assignment and later roster removals.
		if not assignments.has("zecora"): assignments["zecora"] = "everfree"
		zecora_added = true
	spike_added = data.get("spike_added", false)
	if not spike_added and available.has("spike"):
		if not assignments.has("spike"): assignments["spike"] = "ponyville"
		spike_added = true
	background_added = data.get("background_added", false) is bool and data.get("background_added", false)
	if not background_added: _add_default_background(available)
	newcomers_moved = data.get("newcomers_moved", false)
	if not newcomers_moved:
		for id: String in PONYVILLE_NEWCOMERS:
			if available.has(id): assignments[id] = "ponyville"
		newcomers_moved = true
	bonbon_moved = data.get("bonbon_moved", false)
	if not bonbon_moved:
		for id: String in PONYVILLE_MOVES_2026_10_23:
			if available.has(id): assignments[id] = "ponyville"
		bonbon_moved = true
	return true

func _add_filly_households(available: Dictionary) -> void:
	for id: String in FILLIES:
		if available.has(id) and not assignments.has(id): assignments[id] = FILLIES[id]
	for family: Array in HOUSEHOLDS.FAMILIES:
		var child: String = family.back()
		if assignments.get(child, "") != "ponyville": continue
		for id: String in family:
			if available.has(id): assignments[id] = "ponyville"
	filly_households_added = true

func load_file(path: String = LIVE_PATH) -> bool:
	if not FileAccess.file_exists(path): defaults(); return true
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null and FileAccess.file_exists(path + ".previous"):
		data = JSON.parse_string(FileAccess.get_file_as_string(path + ".previous"))
	# An update may drop a pony or a region: forget those assignments, keep the rest.
	if data is Dictionary and data.get("assignments") is Dictionary:
		var known := catalogue(); var region_ids := {}
		for r: Dictionary in regions(): region_ids[str(r.id)] = true
		for id in data.assignments.keys():
			if not known.has(id) or not region_ids.has(str(data.assignments[id])): data.assignments.erase(id)
	if not apply_data(data): return false
	var needs_filly_save: bool = not data.get("filly_households_added", false)
	var needs_zecora_save: bool = not data.get("zecora_added", false) and zecora_added
	var needs_spike_save: bool = not data.get("spike_added", false) and spike_added
	var needs_newcomer_save: bool = not data.get("newcomers_moved", false)
	var needs_bonbon_save: bool = not data.get("bonbon_moved", false)
	if needs_bonbon_save:
		var original_list := ProjectSettings.globalize_path(path)
		var bonbon_backup := original_list + ".before-bonbon-ponyville"
		if not FileAccess.file_exists(bonbon_backup) and DirAccess.copy_absolute(original_list, bonbon_backup) != OK:
			error = "Could not back up the resident list."; return false
	if needs_newcomer_save:
		var absolute := ProjectSettings.globalize_path(path)
		var backup := absolute + ".before-ponyville-newcomers"
		if not FileAccess.file_exists(backup) and DirAccess.copy_absolute(absolute, backup) != OK:
			error = "Could not back up the resident list."; return false
	if needs_filly_save:
		var original := ProjectSettings.globalize_path(path)
		var copy := original + ".before-filly-households"
		if not FileAccess.file_exists(copy) and DirAccess.copy_absolute(original, copy) != OK:
			error = "Could not back up the resident list."; return false
	if int(data.get("stallion_roster_version", 0)) < STALLION_ROSTER_VERSION:
		var available := catalogue()
		for id: String in STALLIONS:
			# The first release already gave these three to this save. Respect later removals.
			if bool(data.get("stallions_added", false)) and id in FIRST_STALLIONS: continue
			if available.has(id) and not assignments.has(id): assignments[id] = STALLIONS[id]
		var absolute := ProjectSettings.globalize_path(path)
		var backup := absolute + ".before-stallions-v2"
		if not FileAccess.file_exists(backup) and DirAccess.copy_absolute(absolute, backup) != OK:
			error = "Could not back up the resident list."; return false
		return save_file(path)
	if needs_filly_save: return save_file(path)
	if needs_zecora_save or needs_spike_save or needs_newcomer_save or needs_bonbon_save: return save_file(path)
	return true

func assign(id: String, region_id: String) -> void:
	if region_id == "": assignments.erase(id)
	else: assignments[id] = region_id

func residents(region_id: String) -> Array:
	var result := []
	for id in assignments:
		if assignments[id] == region_id: result.append(id)
	return result

func save_file(path: String = LIVE_PATH) -> bool:
	# Validate before replacing anything, and rename only a fully flushed file.
	if not apply_data(as_dict()): return false
	if preload("res://world/save_file.gd").write(path, as_dict()) != OK:
		error = "Could not replace population file; previous settings retained."; return false
	return true
