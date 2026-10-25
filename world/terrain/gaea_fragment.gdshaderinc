
	if (gaea_amount>.001) {
		ALBEDO=mix(ALBEDO,gaea_albedo(v_vertex,w_normal,gaea_style,gaea_favorite)*color_map.rgb,gaea_amount);
	}

	// Seasons: green ground turns toward the season's colour (value kept); winter snow
	// settles on flat ground in soft drifts, leaving slopes and paths showing through.
	{
		vec3 s_luma = vec3(.2126, .7152, .0722);
		vec3 s_chroma = ALBEDO / max(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), .0001);
		float s_green = smoothstep(.02, .18, s_chroma.g - s_chroma.r) * smoothstep(.02, .2, s_chroma.g - s_chroma.b);
		vec3 s_turned = season_ground.rgb * (dot(ALBEDO, s_luma) / max(dot(season_ground.rgb, s_luma), .00001));
		ALBEDO = mix(ALBEDO, s_turned, clamp(season_ground.a * s_green, 0.0, 1.0));
		if (season_snow > .001) {
			float s_drift = .5 + .25 * (sin(v_vertex.x * .21 + sin(v_vertex.z * .13)) + sin(v_vertex.z * .17 + v_vertex.x * .05));
			float s_cover = smoothstep(.55, .85, w_normal.y) * smoothstep(1.0 - season_snow, 1.0 - season_snow + .35, s_drift + season_snow * .5);
			ALBEDO = mix(ALBEDO, vec3(.9, .93, .98), clamp(s_cover, 0.0, 1.0));
		}
	}

	// Snow caps (dev 2026-09-24): above ~700 m on ground flat enough to hold it; the line
	// wanders +-30 m so it does not read as a contour. Canterlot's city sits below 510 m.
	{
		vec3 c_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float c_line = 700.0 + 30.0 * (sin(c_world.x * .004 + sin(c_world.z * .003) * 2.0) + sin(c_world.z * .005 + c_world.x * .001));
		float c_cover = smoothstep(c_line - 60.0, c_line + 80.0, c_world.y) * smoothstep(.35, .62, normalize(w_normal).y);
		ALBEDO = mix(ALBEDO, vec3(.92, .94, .98), clamp(c_cover, 0.0, 1.0));
	}
