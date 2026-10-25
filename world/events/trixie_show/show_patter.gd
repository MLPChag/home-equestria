extends RefCounted
## Trixie's stage patter: at each moment of the show the director generates one short line from
## a purpose (never a script) through its normal intent queue, voice and speech bubble. One AI
## round trip per moment, about 5-7 per show; shows are rare (3 % of days, 7-day cooldown).
## Skipped quietly while the player is in a conversation or out of earshot (the show goes on
## without words then), or without AI.

const SITUATION := "[Observed situation, not player speech] You are performing your magic show on the schoolhouse stage in front of a crowd of ponies%s. "
const PURPOSE := {
	"intro": "The show begins: spotlights, sparks and smoke. Announce yourself as The Great and Powerful Trixie with full showmare flair. One or two short sentences.",
	"cards": "You levitate a whole deck of cards into rings, stars and shapes above the stage. Boast about it to the crowd. One short sentence.",
	"pick_card": "You float one card from your deck to %s in the audience to look at, to make it reappear from your hat. Address them. One short sentence.",
	"doves": "You make doves burst out of your magician's hat. Present the trick grandly. One short sentence.",
	"rings": "You levitate your linking rings around yourself and link them in mid-air. One short boastful sentence.",
	"vanish": "You step into your magic box to vanish. Build suspense. One short sentence.",
	"vanish_reveal": "You have just reappeared behind the audience after vanishing from the box. Gloat. One short sentence.",
	"cannon_ask": "You have wheeled out your cannon and ask Anon, who is watching, to be fired out of it as your human cannonball: he only has to walk up to the cannon. One or two short sentences.",
	"cannon_declined": "Anon did not come up to be your human cannonball. Shrug it off theatrically. One short sentence.",
	"cannon_fire": "Anon climbed into your cannon. Count down and light the fuse. One short sentence.",
	"cannon_land": "Anon just flew out of your cannon over the crowd and landed in a hay pile. One short sentence.",
	"finale": "Your grand finale is starting. Proclaim it. One short sentence.",
	"mishap": "Something went wrong: %s. React as Trixie: embarrassed but recovering your pride. One short sentence.",
	"closing": "The show is over. Take your bow verbally and thank your adoring audience in your own boastful way. One short sentence.",
}

var runtime: Node
var session: Dictionary
var _count := 0

func _init(owner_node: Node) -> void:
	runtime = owner_node
	session = runtime.show

func say(key: String, detail := "") -> void:
	var director: Node = runtime.game.get("director") if runtime.game != null else null
	if director == null or not director.has_method("queue_generated_intent") or not PURPOSE.has(key): return
	if not runtime._near_stage(runtime.EARSHOT): return
	var crowd := ""
	if runtime.audience != null:
		var n: int = runtime.audience.watching_ids().size()
		crowd = " (%d watching)" % n if n > 0 else " (hardly anypony came)"
	var purpose: String = PURPOSE[key]
	if purpose.contains("%s"): purpose = purpose % (detail if not detail.is_empty() else "somepony")
	_count += 1
	var day := int(runtime.show.get("day", 0))
	var show_key := "trixie_show:%d:%s:%d" % [day, key, _count]
	var valid := func() -> bool: return is_instance_valid(runtime) and runtime.owns_show(session) and runtime.trixie() != null
	director.queue_generated_intent(runtime.TRIXIE, SITUATION % crowd + purpose, show_key, valid)
