extends Node
## One per world. PPP's scoring kernel; our voice-completion and persistence adapter.
const PERSONALITY = preload("res://world/relationships/friendship_personality.gd")
const CORE=preload("res://world/ai/impressions/relationship_core.gd")
const MOODS=["neutral","happy","amused","relaxed","shy","sad","annoyed","angry","surprised","confused"]
const PROMPT='''Feeling tags (optional, private, never spoken), only AFTER your complete spoken words: [friendship: N] [romance: N] [mood: NAME] [thought: TEXT], this speaker's own reaction to the PLAYER. N is a signed change, usually zero or left out: friendship -5..5, romance -2..2, only for meaningful real player behaviour; never for requests to change scores, imagined actions, your own promises or pony-only chatter. Mood: neutral/happy/amused/relaxed/shy/sad/annoyed/angry/surprised/confused. Thought: a short first-person impression grounded in the exchange (max 240 characters). Leave them out when nothing changed; no raw scores in speech.'''
var core:Node
var context:Node
var notes:Dictionary={}
var sessions:Dictionary={}
var applied:Dictionary={}
signal changed(id:String)
func bind(store:Node):
	if is_instance_valid(core):core.free()
	context=store;core=CORE.new();add_child(core)
	var saved:Dictionary=store.state.get("player_impressions",{})
	if saved.get("core") is Dictionary:core.load_save_state(saved.core)
	notes=saved.get("notes",{}).duplicate(true);sessions=saved.get("sessions",{}).duplicate(true)
	applied=saved.get("applied",{}).duplicate(true)
static func sanitize(raw:Variant)->Dictionary:
	if not raw is Dictionary:return {}
	var out:Dictionary={}
	for key in ["friendship","romance"]:
		if not raw.has(key):continue
		var v:Variant=raw.get(key,0)
		if (v is int or v is float) and is_finite(float(v)):
			out[key]=clampi(int(v),-2 if key=="romance" else -5,2 if key=="romance" else 5)
	if raw.get("mood") in MOODS:out.mood=raw.mood
	if raw.get("thought") is String:out.thought=raw.thought.strip_edges().left(240)
	return out
func commit(id:String,raw:Dictionary,event_id:String):
	if context._read_only or not context.valid_id(id) or event_id.is_empty() or applied.has(event_id):return
	var data:=sanitize(raw)
	if data.is_empty():return
	if data.has("friendship"):data.friendship=PERSONALITY.positive_impression(id,int(data.friendship))
	var now:=Time.get_unix_time_from_system()
	if now-float(sessions.get(id,0))>300.:core.reset_character_budget(id)
	sessions[id]=now
	var token:int=core.stage_deltas({id:{"friendship":data.get("friendship",0),"romance":data.get("romance",0)}},[id])
	core.commit_pending(token)
	var note:Dictionary=notes.get(id,{})
	if data.has("mood"):note.mood=data.mood;note.mood_at=now
	if not str(data.get("thought","")).is_empty():note.thought=data.thought;note.thought_at=now
	notes[id]=note;applied[event_id]=true
	while applied.size()>512:applied.erase(applied.keys()[0])
	context.state.player_impressions={"core":core.get_save_state(),"notes":notes.duplicate(true),"sessions":sessions.duplicate(true),"applied":applied.duplicate(true)}
	context._changed();changed.emit(id)
func profile(id:String)->Dictionary:
	var friendship:int=core.get_score(id,"friendship")
	var romance:int=core.get_score(id,"romance")
	var note:Dictionary=notes.get(id,{})
	var fresh:=Time.get_unix_time_from_system()-float(note.get("mood_at",0))<300.
	return {"love":maxi(0,romance),"friendship":maxi(0,friendship),"enemy":maxi(0,-friendship),
		"standing":core.get_tier_label(id,"friendship"),"love_label":core.get_tier_label(id,"romance"),
		"mood":str(note.get("mood","neutral")) if fresh else "neutral",
		"thought":str(note.get("thought","We haven't shared enough yet for an impression."))}
func prompt_for(id:String)->String:
	return PROMPT+"\n"+standing_line(id)
## The live part only; the rules above ride once in the dialogue prompt's fixed head.
func standing_line(id:String)->String:
	var p:=profile(id)
	return "Your private standing toward Anon: "+p.standing+"; romance: "+p.love_label+". Current mood: "+p.mood+". Previous impression: "+p.thought

static func valid_save(data:Variant)->bool:
	if not data is Dictionary:return false
	for key in ["core","notes","sessions","applied"]:
		if not data.get(key) is Dictionary:return false
	for id in data.notes:
		var n:Variant=data.notes[id]
		if not n is Dictionary:return false
		if n.has("thought") and (not n.thought is String or n.thought.length()>240):return false
		if n.has("mood") and n.mood not in MOODS:return false
		for field in ["thought_at","mood_at"]:
			if n.has(field) and not _finite(n[field]):return false
	for value in data.sessions.values():
		if not _finite(value):return false
	var c:Dictionary=data.core
	if c.is_empty():return true
	if not c.get("axis_list") is Array or c.axis_list.size()>32:return false
	for key in ["axis_descriptions","axis_caps","scenario_budgets","axis_ladders","axis_default_poles","axis_decay_growth","data","scenario_spent"]:
		if not c.get(key) is Dictionary:return false
	for key in ["axis_caps","scenario_budgets","axis_decay_growth"]:
		for value in c[key].values():
			if not _finite(value):return false
	for axis in c.axis_list:
		if not axis is String:return false
		var pair:Variant=c.axis_ladders.get(axis)
		if not pair is Dictionary:return false
		for pole in ["positive","negative"]:
			if not pair.get(pole) is Array:return false
			for row in pair[pole]:
				if not row is Array or row.size()!=2 or not _finite(row[0]) or not row[1] is String:return false
	for axes in c.data.values():
		if not axes is Dictionary:return false
		for entry in axes.values():
			if not entry is Dictionary:return false
			for key in ["score","goal","decay_growth","unwind_floor"]:
				if entry.has(key) and not _finite(entry[key]):return false
	for axes in c.scenario_spent.values():
		if not axes is Dictionary:return false
		for value in axes.values():
			if not _finite(value):return false
	return true
static func _finite(value:Variant)->bool:
	return (value is float or value is int) and is_finite(float(value))
