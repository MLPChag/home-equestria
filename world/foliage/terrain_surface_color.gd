class_name TerrainSurfaceColor
extends RefCounted
## Low-pass local terrain albedo, sampled once when a grass root is built.
## CPU source images only: no viewport capture, GPU readback, or per-frame sampling.
var data: Object
var material: Object
var textures := {}
var images := {}
var means := {}

func palette_at(point: Vector3) -> Color:
	# A broad footprint ignores individual blades/texture flecks. Grass-family
	# neighbors contribute; a path or rock cannot turn a bordering tree grey.
	var result:=Color(0,0,0,0);var total:=0.0
	for offset: Vector2 in [Vector2.ZERO,Vector2(-8,0),Vector2(8,0),Vector2(0,-8),Vector2(0,8)]:
		var pos:=point+Vector3(offset.x,0,offset.y)
		var bits:=int(data.get_control(pos))
		if bits==0xffffffff:continue
		var base:=(bits>>27)&31;var over:=(bits>>22)&31;var blend:=float((bits>>14)&255)/255.0
		for pair: Array in [[base,1.0-blend],[over,blend]]:
			var id:=int(pair[0]);var weight:=float(pair[1])*(2.0 if offset==Vector2.ZERO else 1.0)
			if id not in [0,2,10,11,16,17] or weight<=0:continue
			var value:=_mean(id)
			if id in [0,2,17]:value=preload("res://world/terrain/gaea_material.gd").grass_mean(pos,value,1.0)
			if data.has_method("get_color"):
				var tint: Color=data.get_color(pos)
				if is_finite(tint.r):value*=tint.srgb_to_linear()
			result+=value*weight;total+=weight
	if total<=0:return Color(0,0,0,0)
	result/=total;result.a=1.0;return result

func _mean(id: int) -> Color:
	if means.has(id):return means[id]
	# Warm the shared source image once, then average in linear space.
	_texture(id,Vector2.ZERO,0)
	if not images.has(id):return Color(.1,.2,.05)
	var image: Image=images[id].duplicate();image.resize(16,16,Image.INTERPOLATE_LANCZOS)
	var value:=Color(0,0,0,0)
	for y in 16:
		for x in 16:value+=image.get_pixel(x,y).srgb_to_linear()
	value/=256.0
	var tint: Array=textures[id].get("albedo_color",[1,1,1])
	value*=Color(tint[0],tint[1],tint[2]).srgb_to_linear();value.a=1.0
	means[id]=value;return value

func bind_material(target: ShaderMaterial) -> void:
	if material == null: return
	for key in ["noise_texture", "noise1_scale", "noise1_angle", "noise1_offset", "noise2_scale",
			"macro_variation1", "macro_variation2", "enable_macro_variation"]:
		var value: Variant = material.get_shader_param(key)
		if value != null: target.set_shader_parameter(key, value)

func bind(terrain: Node) -> void:
	data = terrain.data
	material = terrain.material
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(WorldTerrain.TEXTURES))
	for row: Dictionary in doc.textures: textures[int(row.id)] = row

func sample_at(point: Vector3) -> Color:
	var xz := Vector2(point.x, point.z)
	var corner := xz.floor()
	var f := xz - corner
	var colors: Array[Color] = []
	var natural: Array[float] = []
	for offset in [Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN, Vector2.ONE]:
		var at: Vector2 = corner + offset
		var control := int(data.get_control(Vector3(at.x, point.y, at.y)))
		var base := (control >> 27) & 31
		var overlay := (control >> 22) & 31
		var blend := float((control >> 14) & 255) / 255.0
		var color := _texture(base, xz, control)
		if overlay != base and blend > 0.0:
			color = color.lerp(_texture(overlay, xz, control), blend)
		colors.append(color)
		natural.append(lerpf(1.0 if base in [0,2,17] else 0.0,1.0 if overlay in [0,2,17] else 0.0,blend))
	var result := colors[0].lerp(colors[1], f.x).lerp(colors[2].lerp(colors[3], f.x), f.y)
	var coverage:=lerpf(lerpf(natural[0],natural[1],f.x),lerpf(natural[2],natural[3],f.x),f.y)
	result=preload("res://world/terrain/gaea_material.gd").grass_mean(point,result,coverage)
	if data.has_method("get_color"):
		var tint: Color = data.get_color(point)
		if is_finite(tint.r): result *= tint.srgb_to_linear()
	result.a = 1.0
	return result

func _texture(id: int, point: Vector2, control: int) -> Color:
	if not textures.has(id): return Color(0.1, 0.2, 0.05)
	var row: Dictionary = textures[id]
	if not images.has(id):
		var image := preload("res://world/resource_image.gd").read(str(row.file))
		if image == null: return Color(0.1, 0.2, 0.05)
		# Match the average across a clump's footprint, retaining the texture's palette
		# and broad variation instead of importing unrelated grass asset colours.
		image.convert(Image.FORMAT_RGB8)
		image.resize(128, 128, Image.INTERPOLATE_LANCZOS)
		images[id] = image
	var scale := 0.9 - float((((control >> 7) & 7) + 3) % 8 + 1) * 0.1
	# Terrain3D decodes a negative angle, then rotate_vec2 applies its inverse.
	# Vector2.rotated uses the ordinary rotation, so its effective angle is positive.
	var angle := float((control >> 10) & 15) * (TAU / 16.0)
	var uv := (point * scale).rotated(angle) * float(row.get("uv_scale", 0.1)) - Vector2.ONE * 0.5
	var result := _repeat(images[id], uv).srgb_to_linear()
	var tint: Array = row.get("albedo_color", [1.0, 1.0, 1.0])
	return result * Color(float(tint[0]), float(tint[1]), float(tint[2])).srgb_to_linear()

static func _repeat(image: Image, uv: Vector2) -> Color:
	var size := Vector2(image.get_width(), image.get_height())
	var pixel := uv.posmodv(Vector2.ONE) * size - Vector2.ONE * 0.5
	var origin := Vector2i(pixel.floor())
	var f := pixel - Vector2(origin)
	var a := image.get_pixel(posmod(origin.x, image.get_width()), posmod(origin.y, image.get_height()))
	var b := image.get_pixel(posmod(origin.x + 1, image.get_width()), posmod(origin.y, image.get_height()))
	var c := image.get_pixel(posmod(origin.x, image.get_width()), posmod(origin.y + 1, image.get_height()))
	var d := image.get_pixel(posmod(origin.x + 1, image.get_width()), posmod(origin.y + 1, image.get_height()))
	return a.lerp(b, f.x).lerp(c.lerp(d, f.x), f.y)

static func pack(color: Color) -> float:
	# An unsigned 24-bit integer is represented exactly by a float32 custom channel.
	# Store sRGB to retain precision for the dark forest palette; shader decodes linear.
	var srgb := color.linear_to_srgb()
	return float((clampi(roundi(srgb.r * 255.0), 0, 255) << 16)
		| (clampi(roundi(srgb.g * 255.0), 0, 255) << 8) | clampi(roundi(srgb.b * 255.0), 0, 255))
