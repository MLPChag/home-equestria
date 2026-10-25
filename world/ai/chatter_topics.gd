extends RefCounted
## Shared by ambient exchanges and player-chat lulls. Solicit from supplied
## observations/history, never inject a fictional event as a random topic.
const IDLE_GUIDANCE := """Idle conversation (ponies have lives, not just weather): pick ONE topic that fits this speaker and company: your day so far, what is on your mind, your story, plans, wants and worries, opinions of ponies you know, something you heard (say who told you; hearsay can be wrong or exaggerated), a memory the moment brings up, or what is actually happening here. Weather and scenery only when something about them is unusual. A short exchange is fine, silence is fine. Never invent events beyond your memory sections, prices, quantities or statistics. If Anon is visibly busy, do not demand his attention. Pony-to-pony ambient chatter is not addressed to Anon."""

static func seed_line() -> String:
	return IDLE_GUIDANCE
