shader_type spatial;
// Far pony impostor (dev 2026-10-23: "impostor ponies ... swapping between a midwalk frame and a
// stand frame"). A camera-facing quad (Y axis only) standing on her feet; the atlas holds
// FRAMES views around her (column 0 = seen from the front, counterclockwise) in two rows:
// standing (top) and mid-stride (bottom). pony_impostors.gd bakes it from her far mesh.
render_mode cull_disabled, depth_prepass_alpha, diffuse_lambert, specular_disabled;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform float frames = 8.0;
uniform vec2 size = vec2(2.0, 2.0);     // quad width, height in metres
uniform float foot = 0.0;               // quad bottom relative to her root
instance uniform float pose = 0.0;      // 0 stand, 1 mid-stride
varying flat float v_frame;

void vertex() {
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 to_cam = CAMERA_POSITION_WORLD - centre;
	to_cam.y = 0.0;
	to_cam = length(to_cam) > 0.001 ? normalize(to_cam) : vec3(0.0, 0.0, 1.0);
	vec3 right = vec3(to_cam.z, 0.0, -to_cam.x);
	vec3 world = centre + right * VERTEX.x * size.x + vec3(0.0, VERTEX.y * size.y + foot, 0.0);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	NORMAL = (inverse(MODEL_MATRIX) * vec4(to_cam, 0.0)).xyz;
	// Which side of her the camera is on, relative to where she faces (-Z).
	vec3 fwd = -MODEL_MATRIX[2].xyz;
	fwd.y = 0.0;
	fwd = normalize(fwd);
	float side = fwd.z * to_cam.x - fwd.x * to_cam.z;
	float angle = atan(side, dot(fwd, to_cam));
	v_frame = mod(round(angle / (6.2831853 / frames)), frames);
}

void fragment() {
	vec2 uv = vec2((v_frame + UV.x) / frames, (pose + UV.y) * 0.5);
	vec4 c = texture(atlas, uv);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 1.0;
}
