extends RefCounted
## Reviewed room-pack visuals; the existing furniture roots retain physical contracts.
const ROOT := "res://world/buildings/cloudominium/models/room_pack/"
static var _scenes:Dictionary={}

static func add_visual(parent:Node3D,id:String,size:Vector3=Vector3.ONE)->MeshInstance3D:
	if not _scenes.has(id):_scenes[id]=load(ROOT+id+".scn")
	var packed:PackedScene=_scenes[id]
	var visual:=packed.instantiate() as MeshInstance3D
	visual.scale=size
	parent.add_child(visual)
	return visual

static func ceiling_lamps(parent:Node3D,positions:Array[Vector3])->void:
	if not _scenes.has("rd_lamp_ceiling"):_scenes.rd_lamp_ceiling=load(ROOT+"rd_lamp_ceiling.scn")
	var source:MeshInstance3D=(_scenes.rd_lamp_ceiling as PackedScene).instantiate()
	var batch:=MultiMesh.new();batch.transform_format=MultiMesh.TRANSFORM_3D;batch.mesh=source.mesh
	batch.instance_count=positions.size()
	for i in positions.size():batch.set_instance_transform(i,Transform3D(Basis.IDENTITY,positions[i]))
	var view:=MultiMeshInstance3D.new();view.name="RoomCeilingLamps";view.multimesh=batch
	view.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	view.visibility_range_end=45;view.visibility_range_end_margin=3
	view.set_meta("room_source_asset","rd_lamp_ceiling")
	parent.add_child(view);source.free()
