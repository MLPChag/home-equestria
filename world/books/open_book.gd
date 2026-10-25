extends Node3D
## The physical open book (dev 2026-09-26): two hinged halves (board + page block), each page
## printed with a typeset page texture (book_typesetter.gd), and a leaf that swings over the
## spine when you turn a page. Built in the book's own frame: the spine runs along Z at x = 0,
## the pages face +Y, the head of the page is at -Z, the left half lies toward -X.
## `open_amount` goes 0 (shut, the left half lying face down on the right) to 1 (open flat
## with a slight V).

signal flipped
const W := 0.276        # one page's width (m); the closed book is book_item.gd SIZE
const H := 0.32        # page height
const T := 0.016        # half the page block
const BOARD := 0.0035
const OPEN_V := 0.07    # each half tilts up this much (radians) when fully open

var open_amount := 0.0:
	set(value):
		open_amount = clampf(value, 0.0, 1.0)
		_pose()
var left_half: Node3D
var right_half: Node3D
var leaf: Node3D
var _left_page: MeshInstance3D
var _right_page: MeshInstance3D
var _leaf_front: MeshInstance3D
var _leaf_back: MeshInstance3D
var _flipping := false
static var _meshes := {}

func build(cover: Color) -> void:
	var board := StandardMaterial3D.new()
	board.albedo_color = cover
	board.roughness = 0.62
	var paper := StandardMaterial3D.new()
	paper.albedo_color = Color(0.93, 0.9, 0.81)
	paper.roughness = 0.95
	left_half = _half(-1.0, board, paper)
	right_half = _half(1.0, board, paper)
	_left_page = left_half.get_node("Page")
	_right_page = right_half.get_node("Page")
	leaf = Node3D.new()
	leaf.name = "Leaf"
	add_child(leaf)
	_leaf_front = _page_quad("Front", 1.0, false)
	_leaf_back = _page_quad("Back", 1.0, true)
	leaf.add_child(_leaf_front)
	leaf.add_child(_leaf_back)
	leaf.visible = false
	var spine := MeshInstance3D.new()
	spine.name = "Spine"
	var box := BoxMesh.new()
	box.size = Vector3(0.012, BOARD, H + 0.008)
	spine.mesh = box
	spine.position = Vector3(0, -T - BOARD * 0.5, 0)
	spine.material_override = board
	add_child(spine)
	_pose()

## One half: the board under a page block, and the printed page quad on top.
func _half(side: float, board: Material, paper: Material) -> Node3D:
	var half := Node3D.new()
	half.name = "Left" if side < 0 else "Right"
	add_child(half)
	var cover := MeshInstance3D.new()
	var cover_box := BoxMesh.new()
	cover_box.size = Vector3(W + 0.004, BOARD, H + 0.008)
	cover.mesh = cover_box
	cover.position = Vector3(side * (W + 0.004) * 0.5, -T * 2.0 - BOARD * 0.5 + T, 0)
	cover.material_override = board
	half.add_child(cover)
	var block := MeshInstance3D.new()
	var block_box := BoxMesh.new()
	block_box.size = Vector3(W - 0.004, T, H - 0.004)
	block.mesh = block_box
	block.position = Vector3(side * (W * 0.5 + 0.002), -T * 0.5, 0)
	block.material_override = paper
	half.add_child(block)
	var page := _page_quad("Page", side, false)
	half.add_child(page)
	return half

## A printed page: a quad just above the page block, u across from the page's left edge,
## v down from its head. `back` faces -Y and mirrors u, for the reverse of the turning leaf.
func _page_quad(node_name: String, side: float, back: bool) -> MeshInstance3D:
	var key := "%s_%s" % [side, back]
	if not _meshes.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var y := 0.0006 * (-1.0 if back else 1.0)
		var x0 := 0.0 if side > 0 else -W
		var x1 := W if side > 0 else 0.0
		var corners := [Vector3(x0, y, -H * 0.5), Vector3(x1, y, -H * 0.5), Vector3(x1, y, H * 0.5), Vector3(x0, y, H * 0.5)]
		var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		if back:
			uvs = [Vector2(1, 0), Vector2(0, 0), Vector2(0, 1), Vector2(1, 1)]
		var normal := Vector3.DOWN if back else Vector3.UP
		# Godot's front faces are clockwise seen from the normal's side.
		var order := [0, 1, 2, 0, 2, 3] if not back else [0, 2, 1, 0, 3, 2]
		for i in order:
			st.set_normal(normal)
			st.set_uv(uvs[i])
			st.add_vertex(corners[i])
		_meshes[key] = st.commit()
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = _meshes[key]
	var m := StandardMaterial3D.new()
	m.roughness = 0.95
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.albedo_color = Color(0.93, 0.9, 0.81)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func set_pages(left: Texture2D, right: Texture2D) -> void:
	_set_texture(_left_page, left)
	_set_texture(_right_page, right)

func _set_texture(mi: MeshInstance3D, texture: Texture2D) -> void:
	var m := mi.material_override as StandardMaterial3D
	m.albedo_texture = texture
	m.albedo_color = Color.WHITE if texture != null else Color(0.93, 0.9, 0.81)


func _pose() -> void:
	if left_half == null: return
	# Shut: the left half lies face down on the right one (rotated a half turn about the spine).
	var t := smoothstep(0.0, 1.0, open_amount)
	left_half.rotation = Vector3(0, 0, lerpf(-PI + 0.02, -OPEN_V, t))
	right_half.rotation = Vector3(0, 0, lerpf(0.0, OPEN_V, t))

func flipping() -> bool: return _flipping

## Turns one leaf. dir > 0: the right page lifts and lands on the left (next spread); its front
## shows `from_page` (the right page being turned), its back `to_page` (the new left page).
## dir < 0 the other way. Call set_pages for the uncovered page before, and the landed one after.
func flip(dir: int, from_page: Texture2D, to_page: Texture2D, seconds := 0.42) -> void:
	if _flipping: return
	_flipping = true
	_set_texture(_leaf_front if dir > 0 else _leaf_back, from_page)
	_set_texture(_leaf_back if dir > 0 else _leaf_front, to_page)
	leaf.visible = true
	var start := OPEN_V if dir > 0 else PI - OPEN_V
	var finish := PI - OPEN_V if dir > 0 else OPEN_V
	leaf.rotation = Vector3(0, 0, start)
	var tween := create_tween()
	tween.tween_method(func(a: float):
		leaf.rotation = Vector3(0, 0, a)
		leaf.position = Vector3(0, 0.004 * sin(a), 0), start, finish, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_callback(func():
		leaf.visible = false
		_flipping = false
		flipped.emit())
