extends RefCounted
## Policy hook only; physical naps remain the activity system's responsibility.
static func closeness(stage: String, welcomes_hug: bool, blocked: bool) -> String:
	if blocked or not welcomes_hug: return "none"
	match stage:
		"friend": return "beside"
		"close_friend": return "shoulder"
		"dating", "engaged", "married": return "snuggle"
	return "none"
