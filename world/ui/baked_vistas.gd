extends Node3D
## Offline world captures. No gameplay scene or live scenery is loaded by this node.
const VIEWS: Array[String] = ["above_ponyville", "golden_oak", "fluttershy_cottage", "zecora_hut", "town_square", "sweet_apple_acres"]
const DIRECTORY := "res://world/ui/baked_vistas/"
var view_name := ""
var environment: Environment

func setup(_camera: Camera3D, view: String = "") -> void:
	if view.is_empty():
		var settings := get_node_or_null("/root/Settings")
		view = str(settings.get_value("title/view")) if settings != null else "random"
	view_name = view if view in VIEWS else VIEWS[randi() % VIEWS.size()]
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("263a47")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var path := DIRECTORY.path_join(view_name + ".res")
	if ResourceLoader.exists(path):
		var cubemap := load(path) as Cubemap
		if cubemap != null:
			var shader := Shader.new()
			shader.code = "shader_type sky; uniform samplerCube panorama : source_color, filter_linear_mipmap; void sky() { COLOR = texture(panorama, EYEDIR).rgb; }"
			var material := ShaderMaterial.new()
			material.shader = shader
			material.set_shader_parameter("panorama", cubemap)
			var sky := Sky.new()
			sky.radiance_size = Sky.RADIANCE_SIZE_32
			sky.process_mode = Sky.PROCESS_MODE_QUALITY
			sky.sky_material = material
			environment.sky = sky
			environment.background_mode = Environment.BG_SKY
	else:
		push_warning("Opening capture missing: " + path)
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
