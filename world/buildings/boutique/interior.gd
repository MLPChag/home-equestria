extends Node3D
const ARCHITECTURE := preload("res://world/buildings/boutique/architecture.gd")
const KIT := preload("res://world/buildings/golden_oak/furniture_kit.gd")
const PROPS := preload("res://world/buildings/boutique/props.gd")
const REST := preload("res://world/relationships/shared_bed.gd")
const SEAT := preload("res://world/life/seat.gd")
var beds: Dictionary = {}
var stair_path: Array[Vector3] = []
func build(layout: Dictionary) -> void:
	stair_path = ARCHITECTURE.build(self, layout)
	var upper: float = layout.upper_y
	_make_bed("rarity", "rarity_bed", Vector3(-1.45, upper, 2.9), Vector3(1.72, 2.2, 2.3))
	_make_bed("sweetie_belle", "sweetie_bed", Vector3(1.6, upper, 2.65), Vector3(1.3, 1.2, 2.0))
	for spec:Dictionary in [{"at":Vector3(-2.25,0,-1.55),"yaw":0.0,"size":Vector3(1.0,2.2,.4)}, {"at":Vector3(-3.05,0,-1.18),"yaw":.5,"size":Vector3(.75,1.75,.3)}, {"at":Vector3(-1.45,0,-1.18),"yaw":-.5,"size":Vector3(.75,1.75,.3)}]:
		var mirror := PROPS.place(self, "boutique_mirror", spec.at, spec.size, spec.yaw)
		var mirror_size: Vector3 = mirror.get_meta("size")
		KIT.box_body(mirror, "MirrorStand", Vector3(mirror_size.x, .14, mirror_size.z), Vector3(0, .07, 0))
	var sewing := PROPS.place(self, "sewing_table", Vector3(.2, 0, -2.6), Vector3(1.65, 1.65, .65), PI)
	var sewing_size: Vector3 = sewing.get_meta("size")
	KIT.box_body(sewing, "WorkTable", Vector3(sewing_size.x, .76, sewing_size.z), Vector3(0, .38, 0))
	var chaise := PROPS.place(self, "boutique_chaise", Vector3(-2.6, 0, .25), Vector3(1.7, 1.05, .72), PI*.5)
	var chaise_size: Vector3 = chaise.get_meta("size")
	KIT.box_body(chaise, "SeatSupport", Vector3(chaise_size.x, .38, chaise_size.z), Vector3(0, .19, 0))
	var seat := SEAT.new(); seat.position = Vector3(0, .4, 0); seat.rotation.y = PI; seat.depth = .45; chaise.add_child(seat)
	preload("res://world/buildings/boutique/dress_form.gd").build(self,Vector3(1.75,0,-1.55))
	_rug(Vector3(0, .009, .2), 1.42, "f4d4b1", "a45188")
	_rug(Vector3(-1.55, upper+.009, 1.5), .79, "e8bd68", "ac6eac")
	_rug(Vector3(1.6, upper+.009, 1.5), .74, "e8bd68", "a2d2cd")
	_lamps(upper)
	_bedroom_details(upper)
	preload("res://world/buildings/boutique/shelves.gd").install(self)
	# Stable approach vertices join the central aisle, stair foot/landing and the bedroom doors.
	var ground: Array[Vector3] = [Vector3(0,0,3.9),Vector3(0,0,2.5),Vector3(0,0,1.2),Vector3(1.5,0,1.1),Vector3(2.1,0,.4),Vector3(1.65,0,-.3),Vector3(.5,0,-1.4),Vector3(-.9,0,-.2),stair_path[0]]
	var loft: Array[Vector3] = [stair_path[-1],Vector3(-2.65,upper,1.45),Vector3(-1.9,upper,1.4),Vector3(-1.55,upper,.35),Vector3(0,upper,.35),Vector3(1.6,upper,.35),Vector3(-1.45,upper,1.25),Vector3(1.6,upper,1.1)]
	set_meta("stair_path",stair_path); set_meta("ground_walk_points",ground); set_meta("loft_walk_points",loft)
	set_meta("review_views",{
		"shop":{"eye":Vector3(.1,1.7,4.05),"target":Vector3(0,1.5,-1.7)},
		"stairs":{"eye":Vector3(-1.3,1.7,1.2),"target":Vector3(2.6,2.1,-2.2)},
		"rarity":{"eye":Vector3(-1.6,upper+1.6,.3),"target":Vector3(-1.55,upper+.9,2.9)},
		"sweetie":{"eye":Vector3(1.6,upper+1.6,.35),"target":Vector3(1.6,upper+.6,2.9)}})
func _make_bed(id: String, asset: String, at: Vector3, size: Vector3) -> void:
	var bed := PROPS.place(self, asset, at, size, PI)
	var actual: Vector3 = bed.get_meta("size")
	var top := PROPS.mattress_top(bed)
	bed.set_meta("bed_size",actual);bed.set_meta("mattress_top",top)
	bed.set_meta("side_local",Vector3(0,0,actual.z*.5+.5))
	bed.set_meta("sleeper_id",id);bed.set_meta("house",self)
	KIT.box_body(bed,"MattressSupport",Vector3(actual.x*.88,top-.04,actual.z*.91),Vector3(0,(top-.04)*.5,0))
	if id=="sweetie_belle":
		# A clean folded quilt end masks the generated texture smear inside the footboard.
		# Keep the original asset; the narrow cloth insert sits between its carved rails.
		var cloth:=ARCHITECTURE.builder();cloth.use_material("mint_cloth",KIT.material("83d9c6"))
		# Small folds and a rounded turn over the carved rail give the cloth real depth.
		for column in 20:
			var x0:float=-.43+column*.043;var x1:float=x0+.043
			for row in 10:
				var t0:float=float(row)/10;var t1:float=float(row+1)/10
				cloth.quad("mint_cloth",_quilt_point(x0,t0,actual.z),_quilt_point(x1,t0,actual.z),_quilt_point(x1,t1,actual.z),_quilt_point(x0,t1,actual.z),Vector3.BACK)
			var a:=_quilt_point(x0,1,actual.z);var b:=_quilt_point(x1,1,actual.z)
			var crest_a:=Vector3(x0,.97-.16*pow(x0/.43,2),actual.z*.44);var crest_b:=Vector3(x1,.97-.16*pow(x1/.43,2),actual.z*.44)
			cloth.quad("mint_cloth",a,b,crest_b,crest_a,Vector3.UP)
			cloth.quad("mint_cloth",crest_a,crest_b,Vector3(x1,.64,actual.z*.34),Vector3(x0,.64,actual.z*.34),Vector3.UP)
		cloth.commit(bed,"FoldedMintQuiltEnd")
	beds[id]=bed
	REST.for_bed(bed)
	print("[boutique] ",id," bed size=",actual," mattress=",top," approach=",bed.position+bed.basis*Vector3(bed.get_meta("side_local")))
func _rug(at:Vector3,radius:float,edge:String,fill:String)->void:
	KIT.disc(self,"FloralRugBorder",radius,.01,at,KIT.material(edge))
	KIT.disc(self,"FloralRug",radius-.055,.012,at+Vector3.UP*.004,KIT.material(fill))
	for n in 12:
		var angle:=TAU*n/12
		var position:=at+Vector3(sin(angle)*(radius-.18),.014,cos(angle)*(radius-.18))
		KIT.disc(self,"RugPetal",.075,.009,position,KIT.material(edge))
func _lamps(upper:float)->void:
	for at:Vector3 in [Vector3(0,3.3,.4),Vector3(-.72,upper+2.26,1.0),Vector3(.72,upper+2.26,1.0)]:
		KIT.disc(self,"PendantGold",.19,.08,at,KIT.material("eac064"))
		var shade:=MeshInstance3D.new();var cone:=CylinderMesh.new();cone.top_radius=.11;cone.bottom_radius=.24;cone.height=.24;cone.radial_segments=12;cone.material=KIT.material("b56b9f");shade.mesh=cone;shade.position=at-Vector3.UP*.1;add_child(shade)
		KIT.disc(self,"PendantFringe",.245,.035,at-Vector3.UP*.225,KIT.material("eac064"))
		var light:=OmniLight3D.new();light.position=at-Vector3.UP*.25;light.light_color=Color("ffe6cd");light.light_energy=.4;light.omni_range=5.2;light.shadow_enabled=false;light.distance_fade_enabled=true;light.distance_fade_begin=25;light.distance_fade_length=10;add_child(light)
func ensure_bed(id:String="")->Node3D:
	return beds.get("sweetie_belle" if id.to_lower().contains("sweetie") else "rarity") as Node3D
func bed_side(id:String="")->Vector3:
	var bed:=ensure_bed(id)
	return bed.to_global(bed.get_meta("side_local"))
func bed_rest(id:String="")->Transform3D:
	var bed:=ensure_bed(id);var top:float=bed.get_meta("mattress_top")
	return Transform3D(Basis.looking_at(-bed.global_basis.z,Vector3.UP),bed.to_global(Vector3(0,top,.15)))
func on_mattress(point:Vector3,id:String="")->bool:
	var bed:=ensure_bed(id);var at:=bed.to_local(point);var size:Vector3=bed.get_meta("bed_size");var top:float=bed.get_meta("mattress_top")
	return absf(at.y-top)<=.4 and absf(at.x)<size.x*.5+.12 and absf(at.z)<size.z*.5+.12

func _bedroom_details(upper:float)->void:
	var kit:=KIT.new()
	var clock_support: Node3D
	for at:Vector3 in [Vector3(-.4,upper,2.5),Vector3(.42,upper,2.65)]:
		var table := kit.prop("bedside-table",at,PI)
		add_child(table)
		if clock_support == null: clock_support = table
	# A compact wall vanity and its oval glass fit the outer side of Rarity's room,
	# beyond the landing and clear of her bed approach.
	var wood:=KIT.material("ae749f");var gold:=KIT.material("eac064")
	KIT.box(self,"RarityVanity",Vector3(.72,.68,.42),Vector3(-2.75,upper+.34,3.02),wood,true)
	for y:float in [.23,.48]:
		KIT.box(self,"VanityDrawer",Vector3(.64,.20,.025),Vector3(-2.75,upper+y,2.795),KIT.material("d8b6d5"))
		KIT.disc(self,"DrawerPull",.04,.045,Vector3(-2.75,upper+y,2.76),gold).rotation.x=PI*.5
	PROPS.place(self,"boutique_mirror",Vector3(-2.75,upper+.68,3.05),Vector3(.56,1.15,.2),PI)
	# The imported bedside top is measured by the kit's real metre collision box.
	# Its .505 m height is lower than the vanity; the old shared .68 m offset floated.
	var solid: StaticBody3D = clock_support.get_node("Solid")
	var shape: CollisionShape3D = solid.get_child(0)
	var support_top := solid.position.y + (shape.shape as BoxShape3D).size.y*.5
	add_child(kit.prop("clock",clock_support.position+Vector3.UP*support_top,PI))
	# Sweetie's low teal keepsake chest and a soft toy sit against her far wall.
	KIT.box(self,"SweetieToyChest",Vector3(.72,.42,.5),Vector3(2.73,upper+.21,2.8),KIT.material("71b9b6"),true)
	KIT.box(self,"SweetieChestLid",Vector3(.77,.075,.54),Vector3(2.73,upper+.455,2.8),KIT.material("dbc0a2"))
	KIT.box(self,"ChestLatch",Vector3(.08,.15,.03),Vector3(2.73,upper+.38,2.53),gold)
	var plush:=Node3D.new();plush.name="SweetiePlush";plush.position=Vector3(2.73,upper+.51,2.8);add_child(plush)
	var fabric:=KIT.material("f2d4d9")
	preload("res://world/buildings/boutique/dress_form.gd")._ellipsoid(plush,"Body",Vector3(0,.14,0),Vector3(.11,.15,.095),fabric)
	preload("res://world/buildings/boutique/dress_form.gd")._ellipsoid(plush,"Head",Vector3(0,.34,0),Vector3(.12,.11,.10),fabric)
	for side:float in [-1,1]:
		preload("res://world/buildings/boutique/dress_form.gd")._ellipsoid(plush,"Ear",Vector3(side*.075,.47,0),Vector3(.035,.11,.025),fabric)
		preload("res://world/buildings/boutique/dress_form.gd")._ellipsoid(plush,"Eye",Vector3(side*.04,.35,-.093),Vector3(.014,.02,.014),KIT.material("68485f"))

func _quilt_point(x:float,t:float,length:float)->Vector3:
	var edge:=absf(x/.43)
	var top:=.90-.16*edge*edge
	var hem:=.24+.025*cos(x*17)
	return Vector3(x,lerpf(hem,top,t),length*.504+.02*cos(x*23)+.012*sin(t*PI))
