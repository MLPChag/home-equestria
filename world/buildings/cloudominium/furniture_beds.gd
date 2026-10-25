extends RefCounted
## Original room-pack bed and bedside visuals; existing physical bed contracts retained.
const ROOM := preload("res://world/buildings/cloudominium/room_props.gd")
const SHAPES := preload("res://world/buildings/cloudominium/furniture_shapes.gd")
## Bedside table height (its top surface).
const TABLE_TOP := 0.56

## A cloud bed added under `parent`, its quilt and physics mattress level at `top`.
## Legacy palette/pillow arguments stay compatible; the source bed supplies its own art.
static func cloud_bed(parent: Node3D, label_text: String, at: Transform3D, width: float, length: float, top: float, _quilt: String, _pillows: int) -> Node3D:
	var bed:=Node3D.new();bed.name=label_text;bed.transform=at
	ROOM.add_visual(bed,"rd_bed",Vector3(width/2.0,top/.56,length/2.2))
	# Retain the accepted collision, household and shared-bed dimensions exactly.
	var tall:=clampf(width/2.0,.7,1.0);var head_z:=-length*.5-.07
	var solid:=SHAPES.body(bed,"Solid")
	SHAPES.box_shape(solid,Vector3(width+.1,top,length+.12),SHAPES.place(Vector3(0,top*.5,.06)))
	SHAPES.box_shape(solid,Vector3(width+.3,1.25*tall,.36),SHAPES.place(Vector3(0,.625*tall,head_z)))
	bed.set_meta("mattress_top",top);bed.set_meta("bed_size",Vector3(width,1.4*tall,length))
	bed.set_meta("size",Vector3(width+.3,1.5*tall,length+.5));bed.set_meta("side_local",Vector3(0,0,length*.5+.8))
	bed.set_meta("ai_label","bed");bed.add_to_group("ai_observable",true)
	parent.add_child(bed);return bed

## Small purple drum table with a drawer seam and a brass knob; its front is local +Z.
static func bedside_table(parent:Node3D,label_text:String,at:Transform3D)->Node3D:
	var piece:=Node3D.new();piece.name=label_text;piece.transform=at
	ROOM.add_visual(piece,"nightstand_cabinet_left" if label_text.ends_with("Left") else "nightstand_drawer_right")
	SHAPES.cylinder_shape(SHAPES.body(piece,"Solid"),.235,TABLE_TOP,Vector3(0,TABLE_TOP*.5,0))
	parent.add_child(piece);return piece

## The reference's pile of books lying flat, gently askew (seeded, the same every visit).
static func book_stack(parent: Node3D, at: Transform3D, count: int, seed_text: String) -> Node3D:
	var piece := Node3D.new()
	piece.name = "BookStack"
	piece.transform = at
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text)
	var covers: Array[String] = ["book", "#4f9a5b", "book", "#c9a236", "#3e6fb8", "book", "#8a3e8f"]
	var mesh := SHAPES.new()
	var y := 0.0
	for i in count:
		var size := Vector3(rng.randf_range(0.2, 0.26), rng.randf_range(0.035, 0.05), rng.randf_range(0.15, 0.19))
		mesh.tint = Color.WHITE.lerp(Color("c9b8ff"), rng.randf())
		mesh.book(SHAPES.place(Vector3(rng.randf_range(-0.012, 0.012), y, rng.randf_range(-0.012, 0.012)), rng.randf_range(-0.22, 0.22)), size, covers[i % covers.size()])
		y += size.y
	mesh.commit(piece, "Books")
	parent.add_child(piece)
	return piece

## The original framed photo, including its authored standing support.
static func picture_frame(parent:Node3D,at:Transform3D)->Node3D:
	var piece:=Node3D.new();piece.name="PictureFrame";piece.transform=at
	ROOM.add_visual(piece,"rd_picture");parent.add_child(piece);return piece
