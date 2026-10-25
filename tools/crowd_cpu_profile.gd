extends RefCounted
## Opt-in inclusive wall timings; no profiling calls in the normal runtime.
static var totals: Dictionary = {}
static var calls: Dictionary = {}
static var first_tick := -1
static var histograms: Dictionary = {}
## Set by the crowd lab under --profile-cpu; link/modifier callbacks time themselves only then.
static var enabled := false

static func record(label: String, started: int) -> void:
	if first_tick < 0: first_tick = Engine.get_physics_frames()
	var elapsed:=Time.get_ticks_usec()-started
	totals[label] = totals.get(label, 0) + elapsed
	calls[label] = calls.get(label, 0) + 1
	# Fixed 50-us buckets, bounded per scope, captures expensive individual calls
	# without storing one object per ray/leg on every frame.
	if not histograms.has(label):
		var buckets:=PackedInt32Array();buckets.resize(2001);histograms[label]=buckets
	histograms[label][mini(2000,int(elapsed/50))]+=1

static func report() -> Dictionary:
	var result := {}
	var ticks := maxi(1, Engine.get_physics_frames() - first_tick)
	for label in totals:
		result[label] = {"total_ms":totals[label]/1000.0,"ms_per_physics_tick":totals[label]/(1000.0*ticks),"calls":calls[label],"us_per_call":float(totals[label])/calls[label]}
		if histograms.has(label):
			var accumulated:=0
			for bucket in 2001:
				accumulated+=histograms[label][bucket]
				if accumulated>=int(ceil(calls[label]*.95)):
					if bucket==2000:result[label]["call_p95_lower_us"]=100000
					else:result[label]["call_p95_upper_us"]=(bucket+1)*50
					break
	result["physics_ticks"] = ticks
	return result

static func reset() -> void:
	totals.clear(); calls.clear();histograms.clear(); first_tick = Engine.get_physics_frames()

static func attach(node: Node, replacement: Script) -> void:
	# Keep all authored scene exports when selecting the profiling subclass.
	var saved := {}
	for prop in node.get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and prop.usage & PROPERTY_USAGE_STORAGE:
			saved[prop.name] = node.get(prop.name)
	node.set_script(replacement)
	for key in saved: node.set(key,saved[key])
