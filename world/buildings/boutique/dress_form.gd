extends RefCounted
## Padded, headless pony tailoring form. The generated box torso failed visual review;
## its saved Tripo mesh stays intact and contributes only the accepted pedestal here.
const KIT:=preload("res://world/buildings/golden_oak/furniture_kit.gd")
static func build(parent:Node3D,at:Vector3)->void:
	var frame:=Node3D.new();frame.name="PonyTailoringForm";frame.position=at;frame.rotation.y=-.4;parent.add_child(frame)
	var packed:Node3D=load("res://world/buildings/shop_furnishings/models/pony_dress_form.scn").instantiate()
	var source:Mesh=(packed as MeshInstance3D).mesh
	var base:=ArrayMesh.new()
	for s in source.get_surface_count():
		var arrays:=source.surface_get_arrays(s);var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX];var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		var keep:=PackedInt32Array()
		for i in range(0,indices.size(),3):
			if maxf(vertices[indices[i]].y,maxf(vertices[indices[i+1]].y,vertices[indices[i+2]].y))<.48:keep.append_array(PackedInt32Array([indices[i],indices[i+1],indices[i+2]]))
		if keep.is_empty():continue
		arrays[Mesh.ARRAY_INDEX]=keep
		var st:=SurfaceTool.new();st.create_from_arrays(arrays);st.deindex();st.index();st.set_material(source.surface_get_material(s));st.commit(base)
	packed.free()
	var visual:=MeshInstance3D.new();visual.name="RetainedTripoPedestal";visual.mesh=base;frame.add_child(visual)
	var fabric:=KIT.material("e8cbad")
	_ellipsoid(frame,"PaddedBarrel",Vector3(0,.96,0),Vector3(.245,.27,.44),fabric)
	_ellipsoid(frame,"RoundedChest",Vector3(0,1.01,-.29),Vector3(.22,.3,.24),fabric)
	var neck:=_ellipsoid(frame,"UprightNeck",Vector3(0,1.23,-.35),Vector3(.14,.27,.16),fabric);neck.rotation.x=-.28
	for x:float in [-.16,.16]:
		for z:float in [-.27,.26]:_ellipsoid(frame,"SleeveStump",Vector3(x,.73,z),Vector3(.08,.2,.10),fabric)
	KIT.disc(frame,"NeckCap",.105,.045,Vector3(0,1.48,-.41),KIT.material("ab8b69"))
	KIT.box_body(frame,"PedestalSolid",Vector3(.45,.45,.45),Vector3(0,.225,0))
static func _ellipsoid(parent:Node3D,label:String,at:Vector3,radii:Vector3,material:Material)->MeshInstance3D:
	var mesh:=SphereMesh.new();mesh.radius=1;mesh.height=2;mesh.radial_segments=24;mesh.rings=12;mesh.material=material
	var visual:=MeshInstance3D.new();visual.name=label;visual.mesh=mesh;visual.position=at;visual.scale=radii;visual.visibility_range_end=45;visual.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;parent.add_child(visual)
	return visual
