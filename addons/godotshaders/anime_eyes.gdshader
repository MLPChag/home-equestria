// "Anime Style Eyes (Procedural Eye Shader)", godotshaders.com, CC0.
// https://godotshaders.com/shader/anime-style-eyes-procedural-anime-eye-shader/
// Verbatim except for the marked HOME-EQUESTRIA edits: a parallax term that
// sinks the iris behind the sclera by `g_iris_depth` (view-space normal, so
// it needs no tangents) and antialiased circle edges for headset viewing.
shader_type spatial;
// HOME-EQUESTRIA: unshaded (the author's own alternative); with ambient off
// the shadow side of a cartoon eye went pitch black. g_brightness follows the
// time of day from script so the eyes still dim at night.
// cull_disabled: the export's winding repair can flip the recessed card
// faces, and a culled card shows the inside of the head through the dome.
render_mode unshaded, cull_disabled;

// this value should be controled with your script
uniform vec3 g_eye_direction = vec3(0.0, 0.0, 1.0); // in world coordinates

uniform vec2 g_eye_movement_limits = vec2(0.2, 0.2); // in UV space
uniform vec2 g_eye_scale = vec2(1.2, 1.0);
uniform vec3 g_iris_shadow = vec3(0.0, 0.25, 1.5); // xy = position offset, z = scale
uniform float g_outline_radius : hint_range(0.0, 1.0, 0.001) = 0.01;
uniform float g_radius = 0.2;
uniform float g_pupil_radius = 0.5; // relative size
uniform float g_specular_outline_radius : hint_range(0.0, 1.0, 0.001) = 0.01;
uniform vec2 g_specular_view_offset_mult = vec2(0.05, 0.025);
uniform vec3 g_specular_a = vec3(0.35, 0.35, 0.3); // xy = position, z = size (all relative to the eye
uniform vec3 g_specular_b = vec3(-0.35, -0.35, 0.15); // xy = position, z = size (all relative to the eye
uniform vec2 g_specular_jitter = vec2(0.05, 25.0); // size and speed
uniform vec3 g_outline_color : source_color = vec3(0.0, 0.0, 0.0);
uniform vec3 g_pupil_color : source_color = vec3(0.0, 0.0, 0.0);
uniform vec3 g_iris_color_a : source_color = vec3(0.3, 1.0, 0.3);
uniform vec3 g_iris_color_b : source_color = vec3(0.5, 0.5, 1.0);
uniform vec3 g_iris_shadow_color : source_color = vec3(0.7, 0.7, 0.7); // shadow
uniform vec3 g_specular_color : source_color = vec3(0.95, 0.975, 1.0);
uniform vec3 g_background_color : source_color = vec3(1.0, 1.0, 1.0);
// HOME-EQUESTRIA: iris parallax depth (UV units per unit of view-space normal
// tilt) and edge softness (UV units) for antialiasing.
uniform float g_iris_depth = 0.04;
uniform float g_edge_softness = 0.006;
uniform float g_brightness = 1.0;
// HOME-EQUESTRIA: eyelid. Everything above v = g_lid_closure (UV.y runs top to
// bottom) becomes the lid colour, so blinks and half-lids hug the eye surface.
uniform float g_lid_closure = 0.0;
uniform vec3 g_lid_color : source_color = vec3(0.55, 0.78, 0.9);
// HOME-EQUESTRIA: card mode. The UV is a planar map of the whole eye socket
// (an ellipse inscribed in the UV square). g_iris_shift slides the iris in UV
// directly (the mesh is skinned, so a world direction would not map onto the
// card's frame). The lid edge morphs from the socket's top arc through a
// straight line to its bottom arc as it closes; g_rim_line darkens the rim.
uniform vec2 g_iris_shift = vec2(0.0, 0.0);
// The white is a clean ellipse of this radius (1 = the socket's extent);
// outside it the card wears the lid colour, so a ragged socket edge never
// shows as a ragged eye. g_gloss is a view-angle sheen: glassy, not a window.
uniform float g_white_radius = 0.93;
uniform float g_gloss = 0.35;
uniform float g_rim_line = 0.0;
// Beyond the white: a thin lid-colour crease, then the coat colour so the
// card's ragged geometric edge disappears against the head.
uniform float g_crease = 0.04;
uniform vec3 g_coat_color : source_color = vec3(0.61, 0.86, 0.96);
// The export's UV v runs bottom-up; the lid closes from the top.
uniform float g_lid_flip = 1.0;
uniform float g_lid_line = 0.015;
uniform vec3 g_line_color : source_color = vec3(0.02, 0.02, 0.03);

// returns 0 if position is inside the circle, otherwise returns 1
float circle(vec2 position, float radius)
{
	// HOME-EQUESTRIA: smoothstep instead of step so edges do not alias in stereo.
	return smoothstep(radius - g_edge_softness, radius + g_edge_softness, length(position - vec2(0.5)));
}

// fills a circle
vec3 fill_circle(vec2 position, vec3 outside_color, vec3 inside_color, float radius)
{
	float c = circle(position, radius);
	return mix(inside_color, outside_color, c);
}

// strokes a circle
vec3 stroke_circle(vec2 position, vec3 outside_color, vec3 inside_color, float circle_radius, 
	float stroke_size)
{
	float outside = circle(position, circle_radius);
	float inside = circle(position, circle_radius - stroke_size);
	return mix(outside_color, inside_color, inside - outside);
}

// fills a circle but also cuts it with anothed circle mask
vec3 fill_masked_circle(
	vec2 mask_position, float mask_radius, vec3 mask_color, 
	vec2 position, float radius, vec3 outside_color, vec3 inside_color)
{
	vec3 in_out_color = fill_circle(position, outside_color, inside_color, radius);
	return fill_circle(mask_position, mask_color, in_out_color, mask_radius);
}

// draws a circle with stroke and fill colors
vec3 draw_circle(vec2 position, vec3 outside_color, vec3 stroke_color, vec3 fill_color, 
	float circle_radius, float stroke_size) 
{
	float outside_outline_val = circle(position, circle_radius);
	vec3 outside_outline_color = mix(stroke_color, outside_color, outside_outline_val);
	float inside_color_val = circle(position, circle_radius - stroke_size);
	return mix(fill_color, outside_outline_color, inside_color_val);	
}

void fragment() {
	// this is for the specular jitter
	float spc_jitter = 1.0 + (g_specular_jitter.x * sin(TIME * g_specular_jitter.y));		
	
	// HOME-EQUESTRIA: use the face normal from screen derivatives, not the
	// interpolated vertex normal. The card is a fan; its pole vertex came out
	// of the export with a flipped normal, which drew a ring of rim colour
	// at the pupil centre through the parallax and gloss terms.
	vec3 face_n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	if (face_n.z < 0.0) { face_n = -face_n; }
	// compute the specular dynamic offset 
	vec2 specular_offset = face_n.xy * g_specular_view_offset_mult; 
	
	// compute local eye direction
	vec3 local_eye_direction = mat3(inverse(MODEL_MATRIX)) * normalize(g_eye_direction);
	
	// limit eye movement
	vec2 eye_position = (local_eye_direction.xy * g_eye_movement_limits);
	
	// convert from local space to uv space
	eye_position.y = -eye_position.y;
	eye_position += 0.5;
	
	// HOME-EQUESTRIA: parallax. The iris sits behind the sclera surface, so
	// where the surface tilts away from the viewer the iris slides the other way.
	// Sign: a sunken iris seen at an angle shifts toward the viewer's side, so
	// from the front both irises read inward (the old sign made them diverge).
	eye_position += face_n.xy * vec2(1.0, -1.0) * g_iris_depth;
	eye_position += g_iris_shift;
	
	// compute final uv with horizontal and vertical scaling 
	vec2 uv = ((UV - eye_position) * g_eye_scale) + vec2(0.5);

	// HOME-EQUESTRIA: shines share the iris's aspect (the show's big shine is a
	// tall ellipse), so they use the same scaled uv.
	vec2 uv_specular = uv;
	
	// compute iris color (gradient)
	vec3 iris_color = mix(g_iris_color_a, g_iris_color_b, smoothstep(-g_radius, g_radius, uv.y - 0.5));
	
	// set initial color	
	vec3 current_color = g_background_color;
	
	// draw iris + shadow
	current_color = fill_masked_circle(uv, g_radius, current_color, uv - g_iris_shadow.xy, g_radius * g_iris_shadow.z, iris_color * g_iris_shadow_color, iris_color);
			
	// draw pupil
	current_color = fill_circle(uv, current_color, g_pupil_color, g_radius * g_pupil_radius); 

	// draw specular dots
	current_color = draw_circle(uv_specular + specular_offset + g_specular_a.xy * g_radius, current_color, g_outline_color, g_specular_color, g_specular_a.z * g_radius * spc_jitter, g_specular_outline_radius * g_radius);
	current_color = draw_circle(uv_specular + specular_offset + g_specular_b.xy * g_radius, current_color, g_outline_color, g_specular_color, g_specular_b.z * g_radius * spc_jitter, g_specular_outline_radius * g_radius);
	
	// draw outline
	current_color = stroke_circle(uv, current_color, g_outline_color, g_radius, g_outline_radius);
	
	// draw outside (to avoid specular dots outside the eye)
	current_color = fill_circle(uv, g_background_color, current_color, g_radius); 

	// HOME-EQUESTRIA: rim line and lid. The socket ellipse is inscribed in UV.
	vec2 e = (UV - vec2(0.5)) * 2.0;
	float rr = length(e);
	float rim = smoothstep(g_white_radius - g_rim_line - g_edge_softness, g_white_radius - g_rim_line + g_edge_softness, rr);
	current_color = mix(current_color, g_line_color, rim);
	float outside = smoothstep(g_white_radius - g_edge_softness, g_white_radius + g_edge_softness, rr);
	float beyond = smoothstep(g_white_radius + g_crease - g_edge_softness, g_white_radius + g_crease + g_edge_softness, rr);
	// Lid edge: top arc (closure 0) -> straight (0.5) -> bottom arc (1), in a
	// v that runs top-down regardless of the export's UV orientation.
	float vy = mix(UV.y, 1.0 - UV.y, g_lid_flip);
	float arc = 0.5 * sqrt(max(0.0, 1.0 - e.x * e.x));
	float v_edge = mix(0.5 - arc, 0.5 + arc, g_lid_closure);
	float lid = 1.0 - smoothstep(v_edge - g_edge_softness, v_edge + g_edge_softness, vy);
	float lid_line = lid * smoothstep(v_edge - g_lid_line - g_edge_softness, v_edge - g_lid_line + g_edge_softness, vy);
	current_color = mix(current_color, g_lid_color, lid);
	current_color = mix(current_color, g_line_color, lid_line * step(0.01, g_lid_closure));
	current_color = mix(current_color, g_lid_color, outside);
	current_color = mix(current_color, g_coat_color, beyond);
	
	// HOME-EQUESTRIA: glassy sheen toward grazing view angles, inside the white only.
	float fres = pow(1.0 - clamp(dot(face_n, normalize(VIEW)), 0.0, 1.0), 3.0);
	current_color = mix(current_color, vec3(1.0), fres * g_gloss * (1.0 - outside));
	
	// set final color
	ALBEDO = current_color * g_brightness; // HOME-EQUESTRIA: day/night level
}
