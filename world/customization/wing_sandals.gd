extends Node3D
## Baked footwear on the accepted foot bones. Only airborne wings process frames.
const SCENE := preload("res://world/customization/wing_sandals.scn")
var flight: RefCounted
var _attachments: Array[BoneAttachment3D] = []
var _wings: Array[Node3D] = []
var _sides := PackedFloat32Array()

static func apply(actor: Node, worn: bool, model: RefCounted = null) -> void:
	var old := actor.get_node_or_null("WingSandals")
	if not worn:
		if old != null: old.free()
		return
	if old != null: return
	var skeleton := actor.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null or skeleton.find_bone("LeftFoot") < 0 or skeleton.find_bone("RightFoot") < 0: return
	var script: Script = load("res://world/customization/wing_sandals.gd")
	var controller: Node3D = script.new(); controller.name = "WingSandals"; controller.flight = model
	actor.add_child(controller)
	controller.build(skeleton)

func build(skeleton: Skeleton3D) -> void:
	var pair := SCENE.instantiate()
	for fit: Node3D in pair.get_children():
		var attachment := BoneAttachment3D.new(); attachment.name = "Sandal" + str(fit.name)
		attachment.bone_name = fit.name; skeleton.add_child(attachment)
		_clear_owner(fit)
		fit.reparent(attachment, false)
		_attachments.append(attachment); _wings.append(fit.get_node("Wing"))
		_sides.append(float(fit.get_meta("side")))
	pair.free()
	if flight != null:
		flight.activity_changed.connect(_activity)
		visibility_changed.connect(func(): _activity(flight.active))
		_activity(flight.active)
	else: set_process(false)

func _clear_owner(node: Node) -> void:
	node.owner = null
	for child in node.get_children(): _clear_owner(child)

func _activity(value: bool) -> void:
	set_process(value and is_visible_in_tree())
	if not value:
		for wing in _wings: wing.rotation.z = 0.0

func _process(_delta: float) -> void:
	var angle := sin(flight.phase * TAU) * 0.55 if flight.beating else 0.22
	for i in _wings.size(): _wings[i].rotation.z = angle * _sides[i]

func _exit_tree() -> void:
	for attachment in _attachments:
		if is_instance_valid(attachment): attachment.queue_free()

static func display() -> Node3D:
	var pair := SCENE.instantiate() as Node3D
	# A carried pair has no skeleton: show the authored shapes in their rest frame.
	for fit: Node3D in pair.get_children(): fit.transform = Transform3D.IDENTITY
	return pair
