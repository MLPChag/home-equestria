extends RefCounted
## Opt-in solid type for information/settings pages; branding keeps its authored font.
const REGULAR := preload("res://world/books/fonts/AtkinsonHyperlegible-Regular.ttf")
const BOLD := preload("res://world/books/fonts/AtkinsonHyperlegible-Bold.ttf")
const ITALIC := preload("res://world/books/fonts/AtkinsonHyperlegible-Italic.ttf")
static var _theme: Theme
static func make() -> Theme:
	if _theme != null: return _theme
	_theme = Theme.new(); _theme.default_font = REGULAR
	_theme.set_font("normal_font", "RichTextLabel", REGULAR)
	_theme.set_font("bold_font", "RichTextLabel", BOLD)
	_theme.set_font("italics_font", "RichTextLabel", ITALIC)
	_theme.set_font("bold_italics_font", "RichTextLabel", BOLD)
	_theme.set_color("default_color", "RichTextLabel", Color("f4f7fa"))
	for type_name: String in ["Label", "Button", "RichTextLabel"]:
		_theme.set_color("font_color", type_name, Color("f4f7fa"))
		_theme.set_constant("outline_size", type_name, 0)
		_theme.set_constant("shadow_outline_size", type_name, 0)
		_theme.set_color("font_shadow_color", type_name, Color.TRANSPARENT)
	for type_name:String in ["VScrollBar", "HScrollBar"]:
		for part:String in ["scroll", "grabber", "grabber_highlight", "grabber_pressed"]:
			var bar:=StyleBoxFlat.new()
			bar.bg_color=Color("425362") if part=="scroll" else Color("b9d7df")
			bar.set_corner_radius_all(9)
			bar.content_margin_left=14;bar.content_margin_right=14
			bar.content_margin_top=14;bar.content_margin_bottom=14
			_theme.set_stylebox(part,type_name,bar)
	return _theme
