extends RefCounted
## Presentation preference only: never writes the world's clock or save data.
const PATH := "user://title_time.cfg"
const NAMES := ["Dawn", "Morning", "Afternoon", "Golden hour", "Sunset", "Moonlight"]
const HOURS := [6.2, 9.0, 14.0, 17.0, 18.1, 22.0]

static func choose(rng: RandomNumberGenerator, previous: int) -> int:
	if previous < 0 or previous >= HOURS.size(): return rng.randi_range(0, HOURS.size() - 1)
	return (previous + rng.randi_range(1, HOURS.size() - 1)) % HOURS.size()

static func next_launch(path: String = PATH) -> Dictionary:
	var config := ConfigFile.new()
	config.load(path)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var index := choose(rng, int(config.get_value("title", "last_phase", -1)))
	config.set_value("title", "last_phase", index)
	var error := config.save(path)
	if error != OK: push_warning("Could not save title time preference: %s" % error_string(error))
	return {"index": index, "name": NAMES[index], "hours": HOURS[index] + rng.randf_range(-0.12, 0.12)}
