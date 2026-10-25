extends RefCounted
## Serializable orchard ledger; no nodes, wallet calls or filesystem access.
const VERSION: int = 2
const REWARD: int = 20
var trees: Dictionary = {}
var _committing: bool = false

static func calendar(day: float, season_days: int) -> Dictionary:
	var length: int = maxi(1, season_days)
	var season: int = int(floor(maxf(day, 0.0) / length))
	var phase: float = fposmod(maxf(day, 0.0), length * 4.0) / length
	var growth: float = 0.0
	if phase < 2.0: growth = smoothstep(.25, 2.0, phase)
	elif phase < 3.0: growth = 1.0
	return {"cycle": season / 4, "ripe": season % 4 == 2, "growth": growth,
		"next_autumn": (int(season / 4) * 4 + 6) * length}

func available(id: String, day: float, season_days: int) -> bool:
	var now: Dictionary = calendar(day, season_days)
	var prior: Dictionary = trees.get(id, {})
	# A crop started ripe. Keep its attached fruit harvestable after a season
	# change; calendar changes must not strand an unpaid partial harvest.
	if not prior.is_empty() and not prior.paid:
		return prior.released.size() < int(prior.count)
	if not now.ripe: return false
	return prior.is_empty() or (prior.paid and int(prior.cycle) < int(now.cycle) and day >= float(prior.next_ripe_day))

func growth(id: String, day: float, season_days: int) -> float:
	var now: Dictionary = calendar(day, season_days)
	var prior: Dictionary = trees.get(id, {})
	if not prior.is_empty() and not prior.paid: return 1.0
	if not prior.is_empty() and (not prior.paid or int(prior.cycle) >= int(now.cycle)):
		return 0.0
	return float(now.growth)

func begin(id: String, count: int, day: float, season_days: int) -> bool:
	if _committing or id.is_empty() or count < 1 or count > 64 or not available(id, day, season_days): return false
	var prior: Dictionary = trees.get(id, {})
	if not prior.is_empty() and not prior.paid: return false
	var now: Dictionary = calendar(day, season_days)
	trees[id] = {"cycle": int(now.cycle), "count": count, "released": [], "collected": [], "paid": false,
		"next_ripe_day": int(now.next_autumn)}
	return true

## Stable original fruit indices, released exactly once by a certified strike.
func release_cluster(id: String, count: int) -> Array[int]:
	var indices: Array[int] = []
	if _committing or not trees.has(id) or count < 1 or count > 64: return indices
	var row: Dictionary = trees[id]
	if row.paid: return indices
	for index: int in remaining_canopy(id):
		row.released.append(index)
		indices.append(index)
		if indices.size() >= count: break
	return indices

func remaining_canopy(id: String) -> Array[int]:
	var indices: Array[int] = []
	var row: Dictionary = trees.get(id, {})
	if row.is_empty() or row.paid: return indices
	for index: int in int(row.count):
		if index not in row.released: indices.append(index)
	return indices

func collect(id: String, index: int) -> bool:
	if _committing or not is_outstanding(id, index): return false
	trees[id].collected.append(index)
	return true

## Frequent hand/provider checks need no temporary list of every loose index.
func is_outstanding(id: String, index: int) -> bool:
	var row: Dictionary = trees.get(id, {})
	return not row.is_empty() and not row.paid and index >= 0 and index < int(row.count) \
		and index in row.released and index not in row.collected

func outstanding(id: String) -> Array[int]:
	var indices: Array[int] = []
	var row: Dictionary = trees.get(id, {})
	if row.is_empty() or row.paid: return indices
	for index: int in row.released:
		if index not in row.collected: indices.append(index)
	return indices

func pending_payment(id: String) -> bool:
	var row: Dictionary = trees.get(id, {})
	return not row.is_empty() and not row.paid and row.collected.size() == int(row.count)

func receipt(id: String) -> String:
	return "apple-bucking:%s:%d" % [id, int(trees[id].cycle)] if trees.has(id) else ""

## Sink must durably commit BOTH proposed activity state and +20 bits, atomically.
## False leaves this ledger unpaid. Stable receipt supports retry after interruption.
func pay(id: String, sink: Callable, envelope: Dictionary) -> bool:
	if _committing or not pending_payment(id) or not sink.is_valid(): return false
	var proposed: Dictionary = snapshot()
	proposed.trees[id].paid = true
	var next: Dictionary = envelope.duplicate(true)
	next.ledger = proposed
	_committing = true
	var accepted: bool = sink.call(receipt(id), REWARD, next) == true
	_committing = false
	if accepted: trees[id].paid = true
	return accepted

func snapshot() -> Dictionary:
	return {"version": VERSION, "trees": trees.duplicate(true)}

static func valid(value: Variant) -> bool:
	if not value is Dictionary or (value.get("version") != 1 and value.get("version") != VERSION) or not value.get("trees") is Dictionary: return false
	if value.trees.size() > 1024: return false
	for id: Variant in value.trees:
		if not id is String or id.is_empty() or id.length() > 128: return false
		var row: Variant = value.trees[id]
		if not row is Dictionary or not row.get("paid") is bool or not row.get("collected") is Array: return false
		for key: String in ["cycle", "count", "next_ripe_day"]:
			var number: Variant = row.get(key)
			if not (number is int or number is float) or not is_finite(float(number)) or float(number) != floor(float(number)) or float(number) < 0: return false
		if row.count < 1 or row.count > 64 or row.cycle > 10000000 or row.next_ripe_day > 1000000000: return false
		var released: Dictionary = {}
		if value.version == VERSION:
			if not row.get("released") is Array: return false
			for index: Variant in row.released:
				if not (index is int or index is float) or not is_finite(float(index)) or float(index) != floor(float(index)): return false
				if index < 0 or index >= row.count or released.has(int(index)): return false
				released[int(index)] = true
		else:
			for index: int in int(row.count): released[index] = true
		var seen: Dictionary = {}
		for index: Variant in row.collected:
			if not (index is int or index is float) or not is_finite(float(index)) or float(index) != floor(float(index)): return false
			if index < 0 or index >= row.count or seen.has(int(index)) or not released.has(int(index)): return false
			seen[int(index)] = true
		if row.paid and seen.size() != int(row.count): return false
	return true

func restore(value: Variant) -> bool:
	if _committing or not valid(value): return false
	trees = value.trees.duplicate(true)
	# JSON numbers are floats; Array membership distinguishes them from ints.
	for id: String in trees:
		var row: Dictionary = trees[id]
		for key: String in ["cycle", "count", "next_ripe_day"]: row[key] = int(row[key])
		var indices: Array = []
		for index: Variant in row.collected: indices.append(int(index))
		row.collected = indices
		var released: Array = []
		if value.version == 1:
			for index: int in int(row.count): released.append(index)
		else:
			for index: Variant in row.released: released.append(int(index))
		row.released = released
	return true
