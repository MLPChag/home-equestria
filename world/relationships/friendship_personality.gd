extends RefCounted
## Observed experiences only. These weights never change romance or consent gates.
const PROFILES := {
	"pinkie_pie": {"familiarity": 2.5, "values": "You readily welcome new friends and warm to meaningful conversation and shared fun. Friendship is not romantic consent."},
	"fluttershy": {"familiarity": 0.8, "values": "You warm patiently to gentle, considerate company, quiet walks and visits. Pressure does not build trust."},
	"rainbow_dash": {"familiarity": 1.0, "values": "Shared activities and keeping your word matter more than flattering talk. Reliability earns your trust."},
	"twilight_sparkle": {"familiarity": 1.1, "values": "Curiosity, thoughtful conversation and real practical help build your friendship."},
	"applejack": {"familiarity": 1.0, "values": "Consistent company, honest follow-through and real practical help build your friendship."},
	"rarity": {"familiarity": 1.1, "values": "Thoughtful consideration, meaningful generosity and time together build your friendship. Repeated gifts do not buy romance."},
	"spike": {"familiarity": 1.6, "values": "Being treated like a grown-up dragon, sharing a snack (gems especially) and having fun together build your friendship. You are a kid: friendship only, never romance."},
}

static func gains(id: String, kind: String, previous: int = 0) -> Dictionary:
	var familiarity: float = 2.0 if kind == "conversation" else 8.0
	var trust: float = 0.5 if kind in ["conversation", "gift"] else 5.0
	var profile: Dictionary = PROFILES.get(id, {})
	familiarity *= float(profile.get("familiarity", 1.0))
	match id:
		"fluttershy":
			if kind in ["walk", "fishing", "visit"]: trust += 1.0
		"rainbow_dash":
			if kind in ["walk", "fishing", "orchard", "place"]: trust += 2.0
		"twilight_sparkle":
			if kind == "conversation": familiarity += 1.5
			if kind == "orchard": trust += 1.0
		"applejack":
			if kind == "orchard": trust += 2.0
			if previous > 0 and kind not in ["conversation", "gift"]: trust += 0.5
		"spike":
			if kind in ["gift", "meal"]: trust += 1.5
		"rarity":
			if kind == "gift": trust += 2.0
			if kind in ["visit", "meal"]: trust += 1.0
	return {"familiarity": familiarity, "trust": trust}

static func kept_plan_trust(id: String) -> float:
	return 7.0 if id in ["rainbow_dash", "applejack"] else 5.0

static func prompt(id: String) -> String:
	return str((PROFILES.get(id, {}) as Dictionary).get("values", "Friendship grows through meaningful exchanges, shared experiences and kept promises."))

## Scale only earned positive friendship tags. Core still owns caps, scenario budgets,
## replay protection and saturation. Negative boundaries and romance remain unchanged.
static func positive_impression(id: String, amount: int) -> int:
	if amount <= 0: return amount
	var factor: float = float((PROFILES.get(id, {}) as Dictionary).get("familiarity", 1.0))
	return clampi(roundi(float(amount) * factor), 1, 5)
