extends Node3D
## A finished painting as an owned item ("art:<id>", docs/PAINTING_STATION_2026_10_22.md
## section 9): the display frame with the saved PNG on its face. Loaded only where a painting
## exists. A missing file shows bare canvas (its PNG may still be on the worker; one retry).
## The origin is the frame's back centre and +Z points out of the wall, as home_furnishing.gd
## hangs it. Landscape paintings turn the frame 90 degrees and the image with it.
const REGISTRY := preload("res://world/painting/painting_registry.gd")
const SHUTDOWN := preload("res://world/shutdown_waits.gd")
const FRAME := "res://world/painting/models/art_frame.glb"
const SIZE := Vector3(0.58, 0.891, 0.03)
static var _icons: Dictionary = {}
var bounds := AABB(Vector3(-SIZE.x * 0.5, -SIZE.y * 0.5, 0.0), SIZE)
var art_id := ""
var orient := "P"
var _face: MeshInstance3D

## Called by briefcase_drops._make_item before the item enters the tree.
func configure_body(item: RigidBody3D, shape: CollisionShape3D) -> void:
	art_id = REGISTRY.art_id(str(item.get_meta("item_id", "")))
	var row := REGISTRY.art(art_id)
	orient = str(row.get("orient", "P"))
	var size := SIZE if orient == "P" else Vector3(SIZE.y, SIZE.x, SIZE.z)
	bounds = AABB(Vector3(-size.x * 0.5, -size.y * 0.5, 0.0), size)
	var box := BoxShape3D.new(); box.size = size
	shape.shape = box; shape.position = bounds.get_center()
	var label := str(row.get("label", ""))
	set_meta("ai_id", "painting:" + art_id)
	set_meta("ai_label", "a painting by Anon (%s)" % label if not label.is_empty() else "a painting by Anon")
	_build()

func _ready() -> void:
	if get_child_count() == 0: _build()
	add_to_group("ai_observable")
	if not _show() and is_inside_tree():
		if not await SHUTDOWN.seconds(self, 0.2): return
		_show()

func _build() -> void:
	if get_child_count() > 0: return
	var scene := load(FRAME) as PackedScene
	if scene == null: return
	var frame: Node3D = scene.instantiate()
	frame.name = "Frame"
	if orient == "L": frame.rotation.z = PI * 0.5
	add_child(frame)
	for mesh: GeometryInstance3D in frame.find_children("*", "GeometryInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_face = frame.find_child("ArtFace", true, false) as MeshInstance3D

## True when the picture is on the face (false: bare canvas for now).
func _show() -> bool:
	if _face == null: return false
	var image := _image(art_id)
	var material := StandardMaterial3D.new()
	material.roughness = 0.85
	# The same self-light as an easel canvas (easel_build.gd CANVAS_GLOW), for shaded walls.
	material.emission_enabled = true
	material.emission_energy_multiplier = 0.4
	if image == null:
		material.albedo_color = REGISTRY.CANVAS_COLOR
		material.emission = REGISTRY.CANVAS_COLOR
		_face.material_override = material
		return false
	if orient == "L": image.rotate_90(CLOCKWISE)
	image.generate_mipmaps()
	material.albedo_texture = ImageTexture.create_from_image(image)
	material.emission = Color.WHITE
	material.emission_texture = material.albedo_texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	_face.material_override = material
	return true

static func _image(id: String) -> Image:
	var file := REGISTRY.art_path(id)
	if file.is_empty() or not FileAccess.file_exists(file): return null
	var image := Image.load_from_file(file)
	return image if image != null and not image.is_empty() else null

## A 64 px thumbnail for the briefcase and the wrist hotbar.
static func icon(id: String) -> Texture2D:
	if _icons.has(id): return _icons[id]
	var picture := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	picture.fill(Color(0, 0, 0, 0))
	var image := _image(id)
	var inner := Rect2i(8, 4, 48, 56)
	if image != null:
		image.convert(Image.FORMAT_RGBA8)
		var scale := minf(56.0 / image.get_width(), 56.0 / image.get_height())
		image.resize(maxi(1, roundi(image.get_width() * scale)), maxi(1, roundi(image.get_height() * scale)), Image.INTERPOLATE_NEAREST)
		inner = Rect2i((64 - image.get_width()) / 2, (64 - image.get_height()) / 2, image.get_width(), image.get_height())
	picture.fill_rect(inner.grow(3), Color("8a6034"))
	if image != null: picture.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), inner.position)
	else: picture.fill_rect(inner, REGISTRY.CANVAS_COLOR)
	var texture := ImageTexture.create_from_image(picture)
	if image != null: _icons[id] = texture
	return texture
