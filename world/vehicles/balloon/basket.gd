extends RefCounted
## Physical fittings in metres, inside the existing RNL basket.
static func material(color:Color)->StandardMaterial3D:
 var m:=StandardMaterial3D.new();m.albedo_color=color;m.roughness=.85;return m
static func box(parent:Node3D,at:Vector3,size:Vector3,color:Color,solid:=false)->MeshInstance3D:
 var mesh:=BoxMesh.new();mesh.size=size
 var node:=MeshInstance3D.new();node.mesh=mesh;node.material_override=material(color);parent.add_child(node);node.position=at
 if solid:
  var cs:=CollisionShape3D.new();var shape:=BoxShape3D.new();shape.size=size;cs.shape=shape;parent.add_child(cs);cs.position=at
 return node
static func rod(parent:Node3D,a:Vector3,b:Vector3,r:float,color:Color)->MeshInstance3D:
 var mesh:=CylinderMesh.new();mesh.top_radius=r;mesh.bottom_radius=r;mesh.height=a.distance_to(b);mesh.radial_segments=10;mesh.rings=1
 var node:=MeshInstance3D.new();node.mesh=mesh;node.material_override=material(color);parent.add_child(node);node.position=(a+b)*.5
 var up:Vector3=(b-a).normalized();var axis:=Vector3.RIGHT if absf(up.dot(Vector3.RIGHT))<.95 else Vector3.FORWARD
 var x:Vector3=axis.cross(up).normalized();node.basis=Basis(x,up,x.cross(up));return node
static func label(parent:Node3D,at:Vector3,text:String,angle:=0.0)->void:
 var plate:=Label3D.new();plate.text=text;plate.font_size=40;plate.pixel_size=.0013;plate.modulate=Color("fff0bc");plate.outline_size=3;parent.add_child(plate);plate.position=at;plate.rotation.y=angle
static func build(ship:CharacterBody3D)->void:
 var wood:=Color("955d31");var brass:=Color("c99545");var rope:=Color("d7be80")
 # Narrow planks, collision only on a single deck shape.
 for i:int in 12:box(ship,Vector3(-1.375+i*.25,.18,0),Vector3(.243,.16,2.6),wood.lightened(.04*(i%3)))
 var floor_shape:=CollisionShape3D.new();var floor_box:=BoxShape3D.new();floor_box.size=Vector3(3,.18,2.7);floor_shape.shape=floor_box;floor_shape.position.y=.17;ship.add_child(floor_shape)
 # Painted outside, warm wooden liner inside; one clean shell, no overlapping imported walls.
 var purple:=Color("a877ad");var gold:=Color("e2bb62")
 for x:float in [-1.5,1.5]:
  box(ship,Vector3(x,.82,0),Vector3(.14,1.28,2.7),purple,true)
  box(ship,Vector3(x-signf(x)*.077,.8,0),Vector3(.012,1.14,2.55),wood)
  box(ship,Vector3(x,1.46,0),Vector3(.21,.14,2.86),gold)
 box(ship,Vector3(0,.82,1.35),Vector3(3,1.28,.14),purple,true)
 box(ship,Vector3(0,.8,1.273),Vector3(2.85,1.14,.012),wood)
 box(ship,Vector3(0,1.46,1.35),Vector3(3.2,.14,.21),gold)
 for x:float in [-1.03,1.03]:
  box(ship,Vector3(x,.82,-1.35),Vector3(.95,1.28,.14),purple,true)
  box(ship,Vector3(x,.8,-1.273),Vector3(.9,1.14,.012),wood)
  box(ship,Vector3(x,1.46,-1.35),Vector3(.95,.14,.21),gold)
 for y:float in [.3,.6,.9,1.2]:
  for x:float in [-1.576,1.576]:box(ship,Vector3(x,y,0),Vector3(.018,.035,2.62),purple.darkened(.15))
  box(ship,Vector3(0,y,1.426),Vector3(2.98,.035,.018),purple.darkened(.15))
 for x:float in [-1.5,1.5]:
  for z:float in [-1.35,1.35]:box(ship,Vector3(x,.88,z),Vector3(.2,1.45,.2),gold)
 # Hinged gate, closes before lift; a short ramp reaches the deck from the ground.
 var gate:=AnimatableBody3D.new();gate.name="Gate";gate.collision_layer=1;gate.collision_mask=0;gate.sync_to_physics=false;ship.add_child(gate);gate.position=Vector3(-.55,.26,-1.35)
 box(gate,Vector3(.55,.55,0),Vector3(1.1,1.1,.1),purple,true)
 box(gate,Vector3(.55,1.14,0),Vector3(1.1,.12,.16),gold)
 var ramp:=AnimatableBody3D.new();ramp.name="Ramp";ramp.collision_layer=1;ramp.collision_mask=0;ramp.sync_to_physics=false;ship.add_child(ramp);ramp.position=Vector3(0,.17,-1.82);ramp.rotation.x=-.18
 box(ramp,Vector3.ZERO,Vector3(1.05,.09,1.1),wood,true)
 # Compact rear bench and a strapped fuel cylinder.
 box(ship,Vector3(0,.55,1.02),Vector3(2.5,.12,.48),Color("714633"),true)
 for x:float in [-1.05,1.05]:box(ship,Vector3(x,.37,1.02),Vector3(.12,.3,.38),wood,true)
 rod(ship,Vector3(1.12,.27,.58),Vector3(1.12,.95,.58),.16,Color("5e6974"))
 for y:float in [.4,.8]:box(ship,Vector3(1.12,y,.58),Vector3(.34,.06,.33),brass)
 # Burner cage and four rope runs over pulley wheels.
 box(ship,Vector3(0,2.75,0),Vector3(.6,.12,.5),Color("4e4149"))
 var flame:=MeshInstance3D.new();flame.name="Flame";var cone:=CylinderMesh.new();cone.bottom_radius=.13;cone.top_radius=.025;cone.height=.55;flame.mesh=cone
 var fire:=material(Color("ffc15c"));fire.emission_enabled=true;fire.emission=Color("ff852b");fire.emission_energy_multiplier=2;flame.material_override=fire;ship.add_child(flame);flame.position.y=3.04;flame.hide()
 for index:int in 2:
  var x:float=-.8 if index==0 else .8
  var wheel:=MeshInstance3D.new();var ring:=TorusMesh.new();ring.inner_radius=.045;ring.outer_radius=.085;ring.rings=12;ring.ring_segments=8;wheel.mesh=ring;wheel.material_override=material(brass);ship.add_child(wheel);wheel.position=Vector3(x,2.55,.85);wheel.rotation.x=PI*.5;wheel.name="LiftPulley" if index==0 else "VentPulley"
  rod(wheel,Vector3(-.055,0,0),Vector3(.055,0,0),.012,wood)
  rod(ship,Vector3(x,2.55,.85),Vector3(0,2.8,0),.012,rope)
  var line:=rod(ship,Vector3(x,1.55,.85),Vector3(x,2.55,.85),.012,rope);line.name="LiftLine" if index==0 else "VentLine"
  var control:=StaticBody3D.new();control.name="Lift" if index==0 else "Vent";control.collision_layer=1<<21;control.collision_mask=0;ship.add_child(control);control.position=Vector3(x,1.52,.85)
  box(control,Vector3.ZERO,Vector3(.24,.06,.065),Color("df7546") if index==0 else Color("729dd3"),true)
  label(ship,Vector3(x,1.1,1.25),"LIFT\nPull to rise" if index==0 else "VENT\nPull to descend",PI)
 var helm:=StaticBody3D.new();helm.name="Helm";helm.collision_layer=1<<21;helm.collision_mask=0;ship.add_child(helm);helm.position=Vector3(0,1.3,.9)
 rod(helm,Vector3(0,-.4,0),Vector3.ZERO,.028,brass);box(helm,Vector3.ZERO,Vector3(.38,.065,.065),wood,true)
 label(ship,Vector3(0,.78,1.25),"SKY HELM\nTilt to steer\nRelease to hover",PI)
 var bell:=StaticBody3D.new();bell.name="GateBell";bell.collision_layer=1<<21;bell.collision_mask=0;ship.add_child(bell);bell.position=Vector3(.68,1.15,-1.45)
 box(bell,Vector3.ZERO,Vector3(.12,.16,.1),brass,true)
 label(ship,Vector3(.95,1.36,-1.43),"GATE",PI)
 box(ship,Vector3(-1.425,.82,0),Vector3(.025,.6,.8),Color("573744"))
 label(ship,Vector3(-1.40,.85,0),"PONYVILLE SKY BALLOON\nBring a friend aboard\nLIFT to rise • VENT to land\nRelease controls to hover",PI*.5)
