extends RefCounted
## One baked colour glyph works in physical signs, Label3D and ordinary controls.
const SYMBOL := "\ue000"
const COIN := preload("res://world/ui/currency/bit_font.tres")
static var _fonts: Dictionary = {}
static var _words: RegEx
static func amount(value: int) -> String: return "%d %s" % [value, SYMBOL]
static func text(value: String) -> String:
	if _words == null:
		_words = RegEx.new(); _words.compile("(?i)\\bbits\\b")
	return _words.sub(value, SYMBOL, true)
static func font(base: Font = null) -> Font:
	if base == null: base = ThemeDB.fallback_font
	if base.has_meta("currency_font"): return base
	var key := base.get_instance_id()
	if not _fonts.has(key):
		var result := FontVariation.new(); result.base_font = base; result.fallbacks = [COIN]; result.set_meta("currency_font", true)
		_fonts[key] = result
	return _fonts[key]
static func apply(node: Node) -> void:
	if node is Label3D: node.font = font(node.font)
	elif node is Control:
		node.add_theme_font_override("font", font(node.get_theme_font("font")))
