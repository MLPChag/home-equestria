
	vec4 gaea_style=vec4(0.0);
	float gaea_amount=0.0;
	float gaea_favorite=0.0;
	if (gaea_enabled) {
		vec2 guv=((v_vertex.xz-gaea_origin)/gaea_cell+vec2(.5))/gaea_samples;
		gaea_style=textureLod(gaea_field,guv,0.0);
		float natural=0.0;float rock_weight=0.0;float bank_weight=0.0;
		float grass_weight=0.0;
		bool fully_natural=true;
		for (int gi=0;gi<4;gi++) {
			uint gc=control[gi];int base=int((gc>>27u)&31u);int over=int((gc>>22u)&31u);
			float mixw=float((gc>>14u)&255u)/255.0;
			float gw=bilerp ? weights[gi] : (gi==3 ? 1.0 : 0.0);
			float eligible=mix(gaea_natural(base),gaea_natural(over),mixw);
			if (gw>0.0 && eligible<1.0) fully_natural=false;
			natural+=gw*eligible;
			grass_weight+=gw*mix((base==0 || base==2 || base==17) ? 1.0 : 0.0,(over==0 || over==2 || over==17) ? 1.0 : 0.0,mixw);
			rock_weight+=gw*mix(gaea_rock(base),gaea_rock(over),mixw);
			bank_weight+=gw*mix(base==18 ? 1.0 : 0.0,over==18 ? 1.0 : 0.0,mixw);
		}
		if (fully_natural) natural=1.0;
		gaea_amount=gaea_style.a*natural;
		gaea_style.r=max(gaea_style.r,rock_weight/max(natural,.001));
		gaea_style.r=max(gaea_style.r,smoothstep(.10,.40,1.0-normalize(w_normal).y));
		gaea_style.b=bank_weight/max(natural,.001);
		gaea_favorite=gaea_grass_weight(v_vertex.xz)*grass_weight/max(natural,.001);
		if (gaea_original_grass) {
			// Restore the original painted grass, including native color/macro detail.
			gaea_amount*=1.0-gaea_favorite*(1.0-gaea_style.r);
			gaea_favorite=0.0;
		}
	}
