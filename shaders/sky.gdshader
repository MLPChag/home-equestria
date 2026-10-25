shader_type sky;
render_mode use_half_res_pass;

// Replaces PhysicalSkyMaterial, which cannot draw stars or a moon and collapses
// to pure black once the sun is down -- night was unnavigable and had no sky at
// all. This is an approximation of atmospheric scattering rather than a physical
// model, which is the right trade here: the art direction wants a *cozy* sky,
// and hand-authored colours hit that more reliably than a scattering model does.
//
// SkyController drives daylight/golden and the palette; everything else is here.

group_uniforms Palette;
uniform vec3 day_zenith : source_color = vec3(0.18, 0.38, 0.78);
uniform vec3 day_horizon : source_color = vec3(0.62, 0.78, 0.95);
uniform vec3 golden_horizon : source_color = vec3(1.00, 0.48, 0.18);
uniform vec3 golden_zenith : source_color = vec3(0.28, 0.30, 0.62);
uniform vec3 night_zenith : source_color = vec3(0.012, 0.022, 0.065);
uniform vec3 night_horizon : source_color = vec3(0.045, 0.065, 0.135);
uniform vec3 ground_color : source_color = vec3(0.10, 0.11, 0.10);

group_uniforms Blend;
uniform float daylight : hint_range(0.0, 1.0) = 1.0;
uniform float golden : hint_range(0.0, 1.0) = 0.0;
uniform float exposure = 1.0;

group_uniforms Sun;
uniform float sun_size : hint_range(0.0, 0.2) = 0.0011;   // 1-cos(radius): about 2.7 degrees, a bit big for the cartoon look
uniform float sun_glow_size = 32.0;
uniform float sun_glow_strength = 0.55;

group_uniforms Moon;
// 0.030 was a 14 degree disc (dev: "the moon is huge"); 0.0025 is ~4 degrees,
// still a show moon, eight times the real one.
uniform float moon_size : hint_range(0.0, 0.2) = 0.0007;  // about 2.1 degrees
uniform vec3 moon_color : source_color = vec3(0.95, 0.96, 1.0);
uniform float moon_glow_strength = 0.30;
// NASA CGI Moon Kit colour map (public domain), equirectangular, near side at
// longitude 0. moon_albedo_gain lifts the map's dark grey to a bright disc.
uniform sampler2D moon_texture : source_color, filter_linear_mipmap;
uniform float moon_albedo_gain = 6.0;
uniform float moon_rotation = 0.0;

group_uniforms Stars;
uniform float star_density : hint_range(0.0, 1.0) = 0.06;
uniform float star_brightness = 1.4;
uniform float star_twinkle_speed = 1.7;

group_uniforms Clouds;
// Tiling coverage mask (world/sky/clouds_tile.png, derived from CC0 alphas):
// white where a cloud is. Drawn as flat show-style puffs on a plane above the
// viewer, drifting with the wind. No noise, no scattering: two tones and a
// crisp edge, which also holds up in stereo.
uniform sampler2D cloud_texture : repeat_enable, filter_linear;
uniform float cloud_height = 600.0;
uniform float cloud_scale = 0.0004;
uniform vec2 cloud_wind = vec2(0.0035, 0.0012);
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.95;
uniform vec3 cloud_lit : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shade : source_color = vec3(0.72, 0.80, 0.92);
// A lower, broader layer occupies only the far horizon. It shares the sky
// texture and colour treatment, so it costs no geometry, draw pass, or froxel
// volume. Coverage is a mask threshold: higher values make smaller banks.
uniform float cloud_bank_height : hint_range(100.0, 1200.0) = 420.0;
uniform float cloud_bank_scale : hint_range(0.00005, 0.001) = 0.00022;
uniform float cloud_bank_coverage : hint_range(0.15, 0.85) = 0.48;
uniform float cloud_bank_opacity : hint_range(0.0, 1.0) = 0.68;
// Licensed painted silhouettes in the existing sky pass, no extra draw nodes.
uniform bool grassy_clouds_enabled = false;
uniform sampler2D grassy_cloud1 : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D grassy_cloud2 : source_color, filter_linear_mipmap, repeat_disable;
uniform float grassy_cloud_brightness = 3.0;
uniform float grassy_cloud_highlight = 8.0;

vec4 grassy_cloud_layer(vec3 dir, float sectors, float elevation, float row) {
	float yaw = mod(atan(dir.x, -dir.z) + PI + TIME * 0.00012, TAU);
	float cell = floor(yaw * sectors / TAU);
	float seed = fract(sin(cell * 127.1 + row * 37.1) * 43758.5453);
	float midpoint = (cell + 0.36 + seed * 0.28) * TAU / sectors;
	float local_yaw = yaw - midpoint;
	float altitude = asin(clamp(dir.y, -1.0, 1.0));
	bool second = fract(seed * 23.0) > 0.5;
	float width = mix(0.34, 0.65, fract(seed * 17.0));
	float height = width / (second ? 1.92 : 2.58);
	float middle_alt = elevation + seed * (row < 0.5 ? 0.25 : 0.18);
	vec2 stamp = vec2(local_yaw / width + 0.5, 0.5 - (altitude - middle_alt) / height);
	if (stamp.x < 0.0 || stamp.x > 1.0 || stamp.y < 0.0 || stamp.y > 1.0) return vec4(0.0);
	// Actual UV0 crops; UV1 is the native lightmap, not the silhouette.
	vec2 uv = second ? mix(vec2(0.01056, 0.32886), vec2(0.94629, 0.81543), stamp)
		: mix(vec2(0.05237, 0.27588), vec2(0.97461, 0.63330), stamp);
	vec4 native_mask = second ? texture(grassy_cloud2, uv) : texture(grassy_cloud1, uv);
	vec3 tint = vec3(mix(grassy_cloud_brightness, grassy_cloud_highlight, native_mask.b));
	tint *= mix(vec3(1.0), vec3(1.0, 0.70, 0.43), golden * daylight * 0.65);
	tint *= mix(0.035, 1.0, daylight);
	return vec4(tint, native_mask.g * smoothstep(0.01, 0.10, dir.y));
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

// Point stars on a direction-space lattice: one candidate per cell, jittered so
// the lattice never reads as a grid.
float stars(vec3 dir, float t) {
	vec3 p = dir * 260.0;
	vec3 cell = floor(p);
	vec3 f = p - cell;
	float pick = hash13(cell);
	if (pick < 1.0 - star_density) {
		return 0.0;
	}
	vec3 centre = vec3(hash13(cell + 1.7), hash13(cell + 3.3), hash13(cell + 7.1));
	float d = length(f - centre);
	float core = smoothstep(0.16, 0.0, d);
	float mag = 0.35 + 0.65 * hash13(cell + 11.9);
	float twinkle = 0.75 + 0.25 * sin(t * star_twinkle_speed + hash13(cell + 5.5) * 40.0);
	return core * mag * twinkle;
}

group_uniforms VolumeClouds;
// Volumetric cloud layer (dev 2026-09-23: clouds above us, moving, changing day to day,
// thicker and greyer for weather). Raymarched through a slab in the half-resolution pass
// and composited over the sky; SkyController drives coverage, wind and day seed, the
// weather drives coverage/density/darkness.
uniform bool volume_clouds = false;
uniform sampler3D cloud_noise : filter_linear_mipmap, repeat_enable;
uniform float cloud_base = 700.0;
uniform float cloud_thickness = 650.0;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;
uniform float cloud_density : hint_range(0.0, 4.0) = 1.0;
uniform float cloud_darkness : hint_range(0.0, 1.0) = 0.0;
uniform vec2 cloud_drift = vec2(6.0, 2.0);      // metres per second
// Where the wind has carried the clouds so far (metres), accumulated by SkyController each
// frame. drift*TIME made every change of wind jump the whole field by that change times the
// seconds since launch, so after an hour the clouds raced (dev 2026-09-23).
uniform vec2 cloud_offset = vec2(0.0);
uniform vec2 cloud_seed = vec2(0.0);
uniform float cloud_shape_scale = 0.00032;      // noise repeats per metre (shape)
uniform int cloud_steps = 28;

float cloud_hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

// Density at a world point in the slab: broad coverage from a low-frequency slice, puffy
// shape from two noise octaves, a cumulus profile (flat base, rounded towers).
float cloud_density_at(vec3 p, float time) {
	float h = (p.y - cloud_base) / cloud_thickness;
	if (h < 0.0 || h > 1.0) return 0.0;
	vec3 q = p + vec3(cloud_offset.x, 0.0, cloud_offset.y);
	vec2 wq = q.xz * cloud_shape_scale * 0.18 + cloud_seed;
	float weather = texture(cloud_noise, vec3(wq, 0.37)).r;
	float cover = smoothstep(1.0 - cloud_coverage - 0.12, 1.0 - cloud_coverage + 0.18, weather);
	if (cover <= 0.0) return 0.0;
	vec3 sp = q * cloud_shape_scale + vec3(cloud_seed.x, 0.0, cloud_seed.y);
	float shape = texture(cloud_noise, sp).r * 0.62 + texture(cloud_noise, sp * 2.7 + vec3(0.13)).r * 0.26
		+ texture(cloud_noise, sp * 7.3 + vec3(0.41)).r * 0.12;
	// Towers rise where the weather is strongest; bases stay flat and soft.
	float top = mix(0.35, 1.0, cover);
	float profile = smoothstep(0.0, 0.08, h) * (1.0 - smoothstep(top * 0.55, top, h));
	// Heavy weather: a mottled, lumpy underside instead of an even lid.
	float lumps = mix(1.0, 0.55 + texture(cloud_noise, sp * 1.9 + vec3(0.7)).r * 0.9, smoothstep(0.7, 0.95, cloud_coverage));
	float d = shape * profile * cover * lumps - (0.52 - cloud_coverage * 0.25);
	// steep ramp: crisp, billowy edges instead of haze
	return smoothstep(0.0, 0.09, d) * 1.6 * cloud_density;
}

// Light reaching a point from the sun: a few steps through the cloud toward it.
float cloud_light(vec3 p, vec3 to_sun, float time) {
	float od = 0.0;
	float step_len = cloud_thickness * 0.14;
	for (int i = 1; i <= 4; i++) od += cloud_density_at(p + to_sun * step_len * float(i), time);
	return exp(-od * step_len * 0.009);
}

vec4 volume_cloud_layer(vec3 ro, vec3 rd, vec3 sky_col, float time, vec2 jitter_seed) {
	if (abs(rd.y) < 0.004) return vec4(0.0);
	float t0 = (cloud_base - ro.y) / rd.y;
	float t1 = (cloud_base + cloud_thickness - ro.y) / rd.y;
	if (t0 > t1) { float s = t0; t0 = t1; t1 = s; }
	t0 = max(t0, 0.0);
	if (t1 <= 0.0) return vec4(0.0);
	t1 = min(t1, t0 + 9000.0);
	float max_d = 30000.0;
	if (t0 > max_d) return vec4(0.0);
	int steps = cloud_steps;
	float dt = (t1 - t0) / float(steps);
	// Half a step of dither against banding (a full step read as visible grain without TAA).
	float t = t0 + dt * (0.25 + 0.5 * cloud_hash(jitter_seed));
	vec3 to_sun = LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.0, 1.0, 0.0);
	float sun_up = clamp(to_sun.y * 4.0, 0.0, 1.0);
	vec3 sun_col = LIGHT0_ENABLED ? LIGHT0_COLOR * LIGHT0_ENERGY * sun_up : vec3(0.0);
	vec3 moon_col = LIGHT1_ENABLED ? LIGHT1_COLOR * LIGHT1_ENERGY * 0.6 : vec3(0.0);
	float cos_sun = dot(rd, to_sun);
	// silver lining: forward scattering toward the sun
	float phase = mix(0.6, 1.0, 0.5 + 0.5 * cos_sun) + pow(max(cos_sun, 0.0), 8.0) * 1.6;
	// Overcast light is grey, not sky blue.
	vec3 sky_grey = vec3(dot(sky_col, vec3(0.3, 0.45, 0.25)));
	vec3 amb_sky = mix(sky_col, sky_grey * vec3(0.95, 0.97, 1.0), cloud_darkness);
	vec3 ambient_top = amb_sky * 1.1 + vec3(0.06);
	vec3 ambient_bottom = amb_sky * mix(0.42, 0.3, cloud_darkness);
	float trans = 1.0;
	vec3 light = vec3(0.0);
	for (int i = 0; i < steps; i++) {
		vec3 p = ro + rd * t;
		float d = cloud_density_at(p, time);
		if (d > 0.001) {
			float h = clamp((p.y - cloud_base) / cloud_thickness, 0.0, 1.0);
			float sun_t = cloud_light(p, to_sun, time);
			float powder = 1.0 - exp(-d * 2.0);
			vec3 amb = mix(ambient_bottom, ambient_top, h);
			vec3 lit = sun_col * sun_t * phase * mix(0.6, 1.0, powder) + amb + moon_col * h * 0.3;
			lit *= mix(1.0, 0.42, cloud_darkness);
			float absorb = d * dt * 0.009;
			float a = 1.0 - exp(-absorb);
			light += trans * a * lit;
			trans *= 1.0 - a;
			if (trans < 0.02) break;
		}
		t += dt;
	}
	float alpha = 1.0 - trans;
	// Distant cloud melts into the sky's own haze toward the horizon.
	float haze = smoothstep(4000.0, max_d, t0);
	vec3 col = alpha > 0.0001 ? light / alpha : sky_col;
	col = mix(col, sky_col, haze * 0.85);
	return vec4(col, alpha * (1.0 - haze * 0.6));
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float up = clamp(dir.y, -1.0, 1.0);

	// Horizon-to-zenith blend. The power curve keeps the horizon band tight so
	// the warm sunset colour stays near the skyline instead of washing upward.
	float h = pow(clamp(1.0 - abs(up), 0.0, 1.0), 3.0);

	vec3 zenith = mix(night_zenith, day_zenith, daylight);
	vec3 horizon = mix(night_horizon, day_horizon, daylight);
	zenith = mix(zenith, golden_zenith, golden * daylight * 0.8);
	horizon = mix(horizon, golden_horizon, golden * daylight);

	vec3 col = mix(zenith, horizon, h);

	// Stars fade with any daylight at all; a star visible at dusk reads as a bug.
	float night = 1.0 - smoothstep(0.0, 0.35, daylight);
	if (night > 0.001 && up > -0.05) {
		float s = stars(dir, TIME);
		col += vec3(s) * star_brightness * night * smoothstep(-0.05, 0.25, up);
	}

	// LIGHT0 is the sun, LIGHT1 the moon (see world/main.tscn light order).
	if (LIGHT0_ENABLED) {
		float sun_d = dot(dir, LIGHT0_DIRECTION);
		float disk = smoothstep(1.0 - sun_size, 1.0 - sun_size * 0.35, sun_d);
		float glow = pow(max(sun_d, 0.0), sun_glow_size) * sun_glow_strength;
		col += LIGHT0_COLOR * (disk * 6.0 + glow * (1.0 + golden * 2.5));
	}

	if (LIGHT1_ENABLED) {
		float moon_d = dot(dir, LIGHT1_DIRECTION);
		float disk = smoothstep(1.0 - moon_size, 1.0 - moon_size * 0.5, moon_d);
		// Real maria: project the view ray onto the disc, map to the near-side
		// hemisphere and sample the NASA colour map.
		vec3 m_right = normalize(cross(vec3(0.0, 1.0, 0.0), LIGHT1_DIRECTION));
		vec3 m_up = cross(LIGHT1_DIRECTION, m_right);
		float disc_r = sqrt(max(2.0 * moon_size - moon_size * moon_size, 0.0001));
		vec2 off = clamp(vec2(dot(dir, m_right), dot(dir, m_up)) / disc_r, -1.0, 1.0);
		float zz = sqrt(max(1.0 - dot(off, off), 0.0));
		float lon = atan(off.x, zz) + moon_rotation;
		float lat = asin(clamp(off.y, -1.0, 1.0));
		vec2 moon_uv = vec2(lon / (2.0 * PI) + 0.5, 0.5 - lat / PI);
		vec3 moon_albedo = texture(moon_texture, moon_uv).rgb * moon_albedo_gain;
		// Phase: the surface normal at this point against the real sun direction
		// gives the terminator; a trace of earthshine keeps the dark limb legible.
		vec3 moon_n = normalize(m_right * off.x + m_up * off.y - LIGHT1_DIRECTION * zz);
		float lit = smoothstep(-0.03, 0.08, dot(moon_n, LIGHT0_DIRECTION));
		float centre_lit = clamp(dot(-LIGHT1_DIRECTION, LIGHT0_DIRECTION) * 0.5 + 0.5, 0.0, 1.0);
		float glow = pow(max(moon_d, 0.0), 400.0) * moon_glow_strength * (0.15 + 0.85 * centre_lit);
		col += moon_color * (disk * moon_albedo * (0.05 + 0.95 * lit) + glow) * night;
	}

	if (volume_clouds && AT_HALF_RES_PASS) {
		// Dither seed from the view direction, fixed in the sky: the old SCREEN_UV + TIME seed
		// re-rolled every frame and differed per eye, so the clouds crawled with moving grain
		// (dev 2026-09-25). This one holds still and is the same in both eyes.
		vec3 seed_dir = normalize(dir) * 997.0;
		vec4 layer = volume_cloud_layer(POSITION, dir, col, TIME, floor(seed_dir.xz + seed_dir.y * vec2(0.37, 0.61)));
		COLOR = layer.rgb * exposure;
		ALPHA = layer.a;
	} else if (volume_clouds) {
		if (!AT_CUBEMAP_PASS) {
			vec4 layer = HALF_RES_COLOR;
			col = mix(col * exposure, layer.rgb, layer.a) / max(exposure, 0.0001);
		} else {
			// Reflections and ambient: an overcast sky is greyer and darker overall.
			col = mix(col, vec3(dot(col, vec3(0.33))) * mix(1.0, 0.55, cloud_darkness), cloud_coverage * 0.45);
		}
		col = mix(col, ground_color, smoothstep(0.0, -0.12, up));
		COLOR = col * exposure;
	} else {
	// Clouds: intersect the view ray with flat layers. POSITION anchors the
	// masks in world space, so walking does not drag the whole sky along with
	// the viewer. The bank occupies low angles and the old layer stays overhead.
	vec2 toward_sun = vec2(0.0, 0.004);
	if (LIGHT0_ENABLED) {
		toward_sun = normalize(LIGHT0_DIRECTION.xz + vec2(0.0001)) * 0.006;
	}
	vec3 cloud_tint = cloud_shade;
	// The same two-tone palette follows the sun, golden hour, and night for both
	// layers. Bank detail doubles as its lighting breakup, avoiding another
	// texture lookup and a uniformly white horizon wall.
	if (!grassy_clouds_enabled && up > 0.012 && up < 0.30) {
		vec2 bank_plane = POSITION.xz + dir.xz / max(up, 0.012) * cloud_bank_height;
		vec2 bank_uv = bank_plane * cloud_bank_scale + cloud_wind * TIME * 0.62;
		float bank_broad = texture(cloud_texture, bank_uv).r;
		float bank_detail = texture(cloud_texture, bank_uv * 2.37 + vec2(0.31, 0.17)).r;
		float bank_mask = bank_broad * (0.78 + bank_detail * 0.34);
		float bank_body = smoothstep(cloud_bank_coverage, cloud_bank_coverage + 0.18, bank_mask);
		float bank_band = smoothstep(0.018, 0.052, up) * (1.0 - smoothstep(0.16, 0.28, up));
		float bank_lit = smoothstep(0.32, 0.76, bank_detail);
		cloud_tint = mix(cloud_shade, cloud_lit, bank_lit);
		cloud_tint = mix(cloud_tint, cloud_tint * vec3(1.0, 0.72, 0.5), golden * daylight);
		cloud_tint *= mix(0.08, 1.0, daylight);
		col = mix(col, cloud_tint, bank_body * bank_band * cloud_bank_opacity);
	}

	// The original overhead layer. The lit tone
	// comes from a sample nudged toward the sun in UV space, which gives each
	// puff a bright cap and a shaded belly without any lighting model.
	if (!grassy_clouds_enabled && up > 0.02) {
		vec2 plane = POSITION.xz + dir.xz / up * cloud_height;
		vec2 uv = plane * cloud_scale + cloud_wind * TIME;
		float body = texture(cloud_texture, uv).r;
		float cap = texture(cloud_texture, uv + toward_sun).r;
		float lit = smoothstep(0.35, 0.75, cap);
		cloud_tint = mix(cloud_shade, cloud_lit, lit);
		// Warm at golden hour, dim at night, gone right at the horizon.
		cloud_tint = mix(cloud_tint, cloud_tint * vec3(1.0, 0.72, 0.5), golden * daylight);
		cloud_tint *= mix(0.08, 1.0, daylight);
		float fade = smoothstep(0.02, 0.14, up);
		col = mix(col, cloud_tint, body * cloud_opacity * fade);
	}

	if (grassy_clouds_enabled && up > 0.01) {
		vec4 clouds = grassy_cloud_layer(dir, 8.0, 0.18, 0.0);
		col = mix(col, clouds.rgb, clouds.a);
		vec4 high_clouds = grassy_cloud_layer(dir, 5.0, 0.67, 1.0);
		col = mix(col, high_clouds.rgb, high_clouds.a);
	}
	// Below the horizon fades to ground rather than mirroring the sky, so the
	// distant terrain edge does not sit against an obviously wrong band.
	col = mix(col, ground_color, smoothstep(0.0, -0.12, up));

	COLOR = col * exposure;
	}
}
