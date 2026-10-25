extends RefCounted
## AnonPony's PonyIdentity (docs/ANONPONY_DESIGN_2026_10_01.md, section 3). The player chooses
## race, sex, age and eye colour only; everything else is fixed: the green coat of the Second Life
## "Anonpony Box" preset, a messy near-black mane (a recoloured owned background pony's hair,
## player_pony.gd), a question-mark mark.
##
## The base is a background pony's identity, duplicated, so its fitted hair comes along
## (hair_scene, hair_prefix, tail_mount_offset, mane_offset and the tail_* knobs).

const PLAYER_FORM := preload("res://world/life/player_form.gd")
const ANON_MARK := preload("res://world/characters/player_pony/anon_mark.gd")
## Spiky and messy, textured (mares and fillies); messy and untextured (stallions and colts).
## Both have short tails (0.124 and 0.126): a long standard tail is art follow-up for dev.
const MARE_HAIR_SOURCE := "res://world/characters/background/vinyl_scratch.tres"
const STALLION_HAIR_SOURCE := "res://world/characters/background/thunderlane.tres"
## Own hair, fitted by the hair library pipeline and packed by tools/anonpony/build_hair.gd, all
## with the Revamped Source Factory "template_modern" tail (dev 2026-10-01: the Vinyl Scratch
## mane "sucks"). Mares and fillies: the Anonfilly mane. Stallions and colts: the SFM Rainbow
## Dash mane's top with the Anonfilly back.
const ANON_HAIR_SCENE := "res://world/characters/player_pony/hair/anon_pony_hair.scn"
const ANON_STALLION_HAIR_SCENE := "res://world/characters/player_pony/hair/anon_stallion_hair.scn"
const ANON_HAIR_PREFIX := "AnonPony"
const ANON_TAIL_TERMINAL := 0.197038
## The coat tint of the preset's "[OP] BOM OpenPony Blank" layer, (0.60, 0.86, 0.48) on every
## channel; the line and shade are darker steps of it (dev 2026-10-01: "green pony").
const COAT_FILL := Color(0.6, 0.86, 0.48)
const COAT_LINE := Color("62a04e")
const COAT_SHADE := Color("8ac56e")
const MANE_LINE := Color("101012")


static func build(form: Dictionary) -> PonyIdentity:
	var race := str(form.get("race", "earth"))
	if race not in ["earth", "unicorn", "pegasus"]: race = "earth"
	var sex := str(form.get("sex", "mare"))
	if sex not in ["mare", "stallion"]: sex = "mare"
	var age := str(form.get("age", "adult"))
	if age not in ["adult", "young"]: age = "adult"
	var stallion := sex == "stallion"
	var source := load(STALLION_HAIR_SOURCE if stallion else MARE_HAIR_SOURCE) as PonyIdentity
	if source == null:
		push_warning("AnonPony: hair source missing; using the default identity's hair")
	var identity: PonyIdentity = source.duplicate(true) as PonyIdentity if source != null else PonyIdentity.new()
	var own_hair := ANON_STALLION_HAIR_SCENE if stallion else ANON_HAIR_SCENE
	if ResourceLoader.exists(own_hair):
		# Own hair: no shipped tail anchors to borrow, so they are built at run time.
		identity.hair_scene = own_hair
		identity.hair_prefix = ANON_HAIR_PREFIX
		identity.tail_terminal_length = ANON_TAIL_TERMINAL
		identity.tail_mount_offset = Vector3(0.0, 0.075, -0.025)
		identity.mane_offset = Vector3.ZERO
	elif source != null:
		# player_pony.gd borrows this pony's shipped tail anchors (same hair scene).
		identity.set_meta(&"hair_source_id", str(source.id))
	var defaults := PonyIdentity.new()
	# Per variant: the tail-anchor, dock and mark caches are keyed by id. Eyes change no geometry.
	identity.id = "anon_pony_%s_%s_%s" % [race, sex, age]
	identity.display_name = "Anon"
	match race:
		"unicorn": identity.race = PonyIdentity.Race.UNICORN
		"pegasus": identity.race = PonyIdentity.Race.PEGASUS
		_: identity.race = PonyIdentity.Race.EARTH
	identity.stallion = stallion
	identity.filly = age == "young"
	identity.wing_scale = 1.0
	identity.can_fly = true
	identity.coat_fill = COAT_FILL
	identity.coat_line = COAT_LINE
	identity.coat_shade = COAT_SHADE
	identity.mane_line = MANE_LINE
	identity.iris_color = PLAYER_FORM.eye_color(str(form.get("eyes", "")))
	identity.lash_style = PonyIdentity.LashStyle.STANDARD
	identity.eyeshadow_color = Color(defaults.eyeshadow_color, 0.0)
	identity.accessories = defaults.accessories
	# Alpha 0: UnicornMagic derives the glow from the iris (no colour-guide entry for this id).
	identity.magic_color = Color(0.0, 0.0, 0.0, 0.0)
	identity.heart_colors = defaults.heart_colors
	identity.blush_color = defaults.blush_color
	identity.ai_profile = ""
	identity.cutie_mark = ANON_MARK.texture()
	return identity
