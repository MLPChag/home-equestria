extends RefCounted
## Reference palette and forms: lilac hall, mulberry velvet, cream diamonds, gold trim,
## a wide curved stair and two separate rooms upstairs. Native geometry; no baked room image.
const PAPER := preload("res://world/interiors/special_wallpaper.gd")
const BUILD := preload("res://world/buildings/cloudominium/architecture_mesh.gd")
const STAIR := preload("res://world/buildings/cloudominium/architecture_stair.gd")
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
const LAYOUT := preload("res://world/buildings/boutique/layout.gd")
const COLOURS := {"wall":"9980ae","floor":"a182ad","ceiling":"ece0ef","column":"c9b5df","iron":"785687","gold":"eac064","cream":"f5e8dc","plum":"a5457d","pink":"d587ba","blue":"9ed4e6"}
static func builder() -> BUILD:
	var mesh:=BUILD.new()
	for key:String in COLOURS:mesh.use_material(key, PAPER.boutique() if key == "wall" else KIT.material(COLOURS[key]))
	return mesh
static func build(parent:Node3D,layout:Dictionary)->Array[Vector3]:
	var mesh:=builder();var r:float=layout.radius;var upper:float=layout.upper_y;var ceiling:float=layout.ceiling_y
	# Continuous floor discs, with the upper stair opening cut from its annular band.
	for level:float in [0.0,upper,ceiling]:
		for segment in 144:
			var a:=TAU*segment/144;var b:=TAU*(segment+1)/144;var middle:float=(a+b)*.5
			var hole:=level==upper and rad_to_deg(middle)>165 and rad_to_deg(middle)<293
			var outer:=3.10 if hole else r
			var material:="ceiling" if level==ceiling else "floor"
			mesh.tri(material,Vector3(0,level,0),STAIR.polar(outer,a,level),STAIR.polar(outer,b,level),Vector3.DOWN if level==ceiling else Vector3.UP)
			if level==upper:
				mesh.tri("ceiling",Vector3(0,level-.14,0),STAIR.polar(outer,a,level-.14),STAIR.polar(outer,b,level-.14),Vector3.DOWN)
	# Segmented curved lining leaves the measured front door and six existing windows open.
	for segment in 144:
		var a:=TAU*segment/144;var b:=TAU*(segment+1)/144;var angle:float=rad_to_deg((a+b)*.5)
		var door:=angle<11 or angle>349
		var window:=false
		for center:float in [45,90,135,225,270,315]:
			if absf(angle-center)<15:window=true
		var levels:Array[float]=[0.0,.7,3.6,4.05,ceiling]
		for n in levels.size()-1:
			var bottom:float=levels[n];var top:float=levels[n+1]
			if door and bottom<3.6:continue
			if window and bottom>=.7 and top<=4.05:continue
			mesh.quad("wall",STAIR.polar(r,a,bottom),STAIR.polar(r,b,bottom),STAIR.polar(r,b,top),STAIR.polar(r,a,top),-STAIR.outward((a+b)*.5))
		for y:float in [.13,.95,3.73,ceiling-.16]:
			if door and y<3.6:continue
			if window and y>.7 and y<4.05:continue
			mesh.quad("gold" if y>3.6 else "plum",STAIR.polar(r-.015,a,y),STAIR.polar(r-.015,b,y),STAIR.polar(r-.015,b,y+.07),STAIR.polar(r-.015,a,y+.07),-STAIR.outward((a+b)*.5))
	preload("res://world/buildings/boutique/window_reveals.gd").build(mesh,r,layout.window_glass)
	# The circular lining lies inside the original leaf plane. Close that depth around
	# the existing doorway, overlapping its measured wood edges without moving the hinge.
	var jamb_x := sin(deg_to_rad(10))*r
	var jamb_z := cos(deg_to_rad(10))*r
	for side: float in [-1,1]:
		mesh.quad("cream",Vector3(side*jamb_x,0,jamb_z),Vector3(side*.81,-.13,4.99),Vector3(side*.81,3.50,4.99),Vector3(side*jamb_x,3.6,jamb_z),Vector3(-side,0,0))
	mesh.quad("cream",Vector3(-jamb_x,3.6,jamb_z),Vector3(jamb_x,3.6,jamb_z),Vector3(.81,3.50,4.99),Vector3(-.81,3.50,4.99),Vector3.DOWN)
	# Front threshold joins the circular floor to the source leaf; its approach is measured
	# separately against live terrain by the runtime, with no terrain edits.
	mesh.box("floor",Vector3(0,-.055,4.95),Vector3(1.74,.11,1.0))
	# Join the lifted lining to the unchanged exterior landing with a visible,
	# collidable slope over the original scenery steps, ending below published terrain.
	# The hinge and exterior stay unchanged; the approach keeps its horizontal location.
	var ramp := preload("res://world/buildings/stair_brush.gd").build({"center_x":0.0,
		"width":1.74,"back_z":4.95,"height":0.0,"landing_z":LAYOUT.ENTRY_LANDING_Z,
		"toe_z":LAYOUT.ENTRY_TOE_Z,"toe_y":LAYOUT.ENTRY_TOE_Y})
	ramp.name="DoorwayFloorTransition";parent.add_child(ramp)
	(ramp.get_node("StoneRamp") as MeshInstance3D).material_override=KIT.material(COLOURS.floor)
	var structure:=mesh.commit(parent,"BoutiqueStructure")
	for surface: int in mesh.baked_keys.size():
		if mesh.baked_keys[surface] == "wall": structure.set_surface_override_material(surface, PAPER.boutique(true))
	var body:=StaticBody3D.new();body.name="MeasuredRoomCollision";parent.add_child(body)
	var collision:=CollisionShape3D.new();var shape:=structure.mesh.create_trimesh_shape();shape.backface_collision=true;collision.shape=shape;body.add_child(collision)
	var stairs:=builder();var built:Dictionary=STAIR.build(parent,stairs,layout);stairs.commit(parent,"CurvedLavenderStair")
	var decor:=builder()
	# The upper landing opens onto a cross-hall. Bedroom partitions stop at the hallway.
	decor.box("wall",Vector3(0,upper+1.05,2.65),Vector3(.12,2.1,3.15))
	KIT.box_body(parent,"BedroomPartition",Vector3(.12,2.1,3.15),Vector3(0,upper+1.05,2.65))
	for x:float in [-1.65,1.65]:
		for side:float in [-.88,.88]:
			decor.box("cream",Vector3(x+side,upper+1.0,.92),Vector3(.12,2.0,.14))
			KIT.box_body(parent,"BedroomDoorPost",Vector3(.12,2.0,.14),Vector3(x+side,upper+1.0,.92))
		decor.box("plum",Vector3(x,upper+2.06,.92),Vector3(1.88,.20,.18))
	# Diamond columns and little curling scrolls are native ornaments, after the reference.
	for angle:float in [20,70,110,155,205,250,290,340]:
		var at:=STAIR.polar(r-.08,deg_to_rad(angle),0)
		for y:float in [.45,1.1,1.75,2.4,3.05,5.2,5.85]:
			var frame:=Transform3D(Basis(Vector3.UP,deg_to_rad(angle)),at+Vector3.UP*y)
			decor.extrude("cream",PackedVector2Array([Vector2(0,.26),Vector2(.14,0),Vector2(0,-.26),Vector2(-.14,0)]),frame,.035)
		for y:float in [3.7,6.22]:
			var points:=PackedVector3Array()
			for k in 28:
				var turn:=float(k)/27*TAU*1.25;var radius:=.20*(1.0-float(k)/32)
				points.append(at+Vector3(cos(turn)*radius,y+sin(turn)*radius,0))
			decor.tube("cream",points,.018,6)
	decor.commit(parent,"DiamondCorniceAndRoomTrim")
	# Two hanging mulberry changing curtains define a dressing nook away from the stair.
	var curtain:=builder()
	for n in 18:
		var x:float=-2.8+n*.075
		curtain.box("plum" if n%2==0 else "pink",Vector3(x,1.12,-2.25),Vector3(.086,2.2,.07))
	curtain.box("gold",Vector3(-2.16,2.25,-2.25),Vector3(1.5,.1,.14))
	curtain.commit(parent,"ChangingCurtain")
	# The freestanding privacy divider carries its rod on two floor-mounted posts.
	# Their tops overlap the existing bar; the curtain and dressing space stay put.
	var supports:=builder()
	for x:float in [-2.87,-1.45]:
		supports.box("gold",Vector3(x,1.13,-2.25),Vector3(.055,2.28,.055))
		supports.box("gold",Vector3(x,.025,-2.25),Vector3(.13,.05,.13))
		KIT.box_body(parent,"ChangingCurtainPostLeft" if x<-2 else "ChangingCurtainPostRight",Vector3(.055,2.28,.055),Vector3(x,1.13,-2.25))
	supports.commit(parent,"ChangingCurtainSupports")
	var path:Array[Vector3]=[];path.assign(built.path)
	parent.set_meta("stair_path",path)
	return path
