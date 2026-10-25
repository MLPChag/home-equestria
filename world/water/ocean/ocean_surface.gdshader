shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx, shadows_disabled;

// The sea surface (world/water/ocean/world_ocean.gd). Ported from Tidewater
// (github.com/dgreenheck/tidewater, MIT): WaterSurface.js (FFT cascades, per-cascade shallow-water
// attenuation, foam coverage and pattern) and ShoreWaves.js (depth-aware shoreline waves that
// shoal, plunge and run up the sand as swash), from WGSL. Changed for the game: shaded with cel
// bands and a hard sun glint instead of Tidewater's physically based water (no refraction, no
// subsurface), crisper foam, and colours from the region's sea mood. The coast field (travel time,
// shoreward direction, exposure, ground height) is baked by tools/ocean/bake_coast.py.
//
// The mesh is CDLOD (as Tidewater's core/CDLOD.js): one MultiMesh of GRID x GRID patches, each
// instance a quadtree node (transform: origin and size; INSTANCE_CUSTOM: lod, morph start, morph
// end). Vertices morph onto the next coarser grid as their distance to `lod_camera` approaches the
// node's range, so neighbouring nodes of different lods meet without cracks, and the quadtree is
// fixed in the world, so nothing swims.

#define SHORE_GRAVITY 9.81
#define SHORE_TAU 6.28318530718
#define SHORE_BEACH_SLOPE 0.066
#define SHORE_SWASH_UP 0.4
#define SHORE_SWASH_DOWN 0.55
#define SHORE_SWASH_OVERSHOOT 1.2
#define WATER_SHORE_DEEP 26.0

// one texture per cascade (OceanFFT)
uniform sampler2D ocean_displacement[4] : filter_linear_mipmap, repeat_enable;
uniform sampler2D ocean_derivatives[4] : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float cascade_size[4];
uniform int cascade_count = 4;
uniform float foam_weight[4];
uniform float foam_bias = 0.58;
uniform float amplitude = 1.0;
uniform float foam_coverage = 1.0;
uniform float foam_scale = 0.09;
uniform sampler2D foam_texture : filter_linear_mipmap_anisotropic, repeat_enable;

// coast field: A = (ground above sea level, effective depth, dir.x * exposure, dir.z * exposure), T = travel time (s)
uniform sampler2D coast_a : filter_linear, repeat_disable;
uniform sampler2D coast_t : filter_linear, repeat_disable;
uniform vec4 coast_rect = vec4(-8192.0, -8192.0, 18432.0, 14336.0);
uniform float sea_level = -80.0;
uniform float ocean_time = 0.0;

// shore waves (ShoreParams)
uniform float shore_period = 9.0;
uniform float shore_amplitude = 0.34; // offshore amplitude (H/2)
uniform float shore_variation = 0.55;
uniform float shore_gamma = 0.78;
// fraction of the break depth over which the lip plunges (see ShoreWaves.js)
uniform float shore_break_span = 0.13;
uniform float shore_curl = 1.0;
uniform float shore_runup = 1.0;
uniform float shore_enabled = 1.0;

// look
uniform vec3 deep_color : source_color = vec3(0.07, 0.25, 0.45);
uniform vec3 shallow_color : source_color = vec3(0.16, 0.62, 0.66);
uniform vec3 surf_color : source_color = vec3(0.45, 0.85, 0.80);
uniform vec3 foam_color : source_color = vec3(0.93, 0.97, 1.0);
uniform vec3 sky_tint : source_color = vec3(0.62, 0.75, 0.9);
uniform float reflection_strength = 0.55;
uniform float glint_strength = 2.5;
uniform float glint_power = 380.0;
uniform float displacement_fade_start = 2500.0;
uniform float displacement_fade_end = 5000.0;
uniform int debug_mode = 0; // 1: cascades, 2: coast depth, 3: foam coverage, 4: shore phase

uniform float grid_size = 32.0;
uniform vec3 lod_camera;

varying vec3 v_lag;        // rest world x, effective depth, rest world z
varying float v_foam;
varying vec3 v_shore_n;
varying float v_shore_foam;
varying float v_swash;
varying float v_height;
varying float v_ground;    // ground above sea level (m)
varying vec2 v_surf_mask;  // clear plunging face, whitewater roller relief

float sat(float x) { return clamp(x, 0.0, 1.0); }

// ------------------------------------------------------------ coast field

vec4 coast_sample(vec2 xz) {
	vec2 uv = (xz - coast_rect.xy) / coast_rect.zw;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec4(-200.0, 600.0, 0.0, 0.0);
	return textureLod(coast_a, uv, 0.0);
}
float coast_time(vec2 xz) {
	vec2 uv = (xz - coast_rect.xy) / coast_rect.zw;
	return textureLod(coast_t, clamp(uv, vec2(0.0), vec2(1.0)), 0.0).r;
}

// per-cascade amplitude attenuation in shallow water (long waves feel the bottom first)
float cascade_attenuation(int c, float depth) {
	float d0 = min(40.0, cascade_size[c] * 0.08);
	float floor_amt = c == 0 ? 0.0 : (c == 1 ? 0.05 : (c == 2 ? 0.25 : 0.5));
	float a = smoothstep(0.0, d0, depth);
	return mix(floor_amt * smoothstep(0.0, 0.6, depth), 1.0, a);
}

// ------------------------------------------------------------ shore waves (ShoreWaves.js)

float shoreHash1(float x) { return fract(sin(x * 127.1 + 311.7) * 43758.5453); }

// a bar with rip channels cut through it every ~100 m: bigger waves over the bar, smaller in the channels
vec2 shoreBar(float along) {
	float w = sin(along * 0.021 + 1.9) * 1.4 + sin(along * 0.009 + 0.3) * 0.9;
	float r = sin(along * 0.059 + w);
	float width = 0.8 + sin(along * 0.017 + 4.1) * 0.08;
	float rip = smoothstep(width, 0.985, r);
	float bar = 0.9 + (sin(along * 0.031 + 7.3) * 0.6 + sin(along * 0.083 + 1.1) * 0.4) * 0.14;
	return vec2(bar * (1.0 - rip * 0.58), rip);
}

// along-shore phase wobble (in periods): crests bend over the uneven bottom
float shoreWobble(float along) {
	return sin(along * 0.029 + 0.7) * 0.07 + sin(along * 0.083 + 2.1) * 0.035
		+ sin(along * 0.19 + 0.4) * 0.022 + sin(along * 0.37 + 2.6) * 0.011
		+ shoreBar(along).y * 0.045;
}

// sets of ~7 waves with larger ones in the middle, per-wave randomness, along-shore peaks
float shoreWaveAmp(float m, float along) {
	float waveSet = abs(sin(m * 0.448798950513)) * 0.6 + 0.55;
	float rnd = (shoreHash1(m) - 0.5) * 2.0;
	float warp = sin(along * 0.016 + m * 0.9) * 1.6;
	float a1 = sin(along * 0.062 + m * 1.7 + warp);
	float a2 = sin(along * 0.13 + m * 4.1 + 1.3 - warp * 0.7);
	float a3 = sin(along * 0.29 + m * 2.3 + warp * 0.5) * 0.6 + sin(along * 0.47 + m * 5.9 + 0.8) * 0.4;
	float alongV = a1 * 0.6 + a2 * 0.4 + a3 * 0.28;
	return max(shore_amplitude * waveSet * (1.0 + rnd * shore_variation * 0.5 + alongV * shore_variation * 0.7) * shoreBar(along).x, 0.02);
}

struct ShoreBreak {
	float db; float b; float Ash; float p; float meanP; float crestPeak; float yc; float yt;
	float H; float wBore; float Xi; float Hb; float ycB; float ytB; float Xc; float Wt;
};

ShoreBreak shoreBreakParams(float A, float d) {
	ShoreBreak P;
	// break depth for this wave (Green's law shoaling, H = gamma d)
	P.db = pow(A * 3.556 / shore_gamma, 0.8);
	P.b = (P.db - d) / (P.db * shore_break_span); // <0 shoaling, 0..1 plunging, >1 bore
	float shoal = pow(10.0 / clamp(d, 0.35, 10.0), 0.25);
	P.Ash = A * shoal;
	P.p = mix(1.0, 3.0, smoothstep(-2.5, 0.0, P.b));
	P.meanP = 1.0 / sqrt((P.p + 0.25) * PI);
	P.crestPeak = 1.0 + smoothstep(-1.0, 0.3, P.b) * 0.22;
	P.yc = P.Ash * 2.0 * (1.0 - P.meanP) * P.crestPeak;
	P.yt = P.Ash * -2.0 * P.meanP * P.crestPeak;
	P.H = P.yc - P.yt;
	P.wBore = smoothstep(0.85, 1.35, P.b);
	P.Xi = P.H * 0.8;
	P.Hb = min(P.H * 0.6, max(d, 0.0) * 0.75) * (smoothstep(0.0, 0.3, d) * 0.7 + 0.3);
	P.ycB = mix(P.yc, P.yt * 0.6 + P.Hb, P.wBore);
	P.ytB = mix(P.yt, P.yt * 0.6, P.wBore);
	P.Xc = mix(0.0, P.Xi - P.Hb * 0.55, P.wBore) * smoothstep(0.03, 0.3, P.Hb);
	P.Wt = mix(P.H * mix(0.25, 0.55, smoothstep(0.1, 0.9, P.b)), P.Hb * 0.6 + 0.08, P.wBore);
	return P;
}

float shoreFaceFill(float b, float s) {
	float k = (1.0 - s) * 0.45;
	return smoothstep(k + 0.9, k + 1.08, b);
}

float shoreWhitewater(float xi, float lam, ShoreBreak P) {
	float landed = smoothstep(0.86, 0.99, P.b);
	float spread = sat((P.b - 0.9) / 0.45);
	float reach = P.Xi * 0.25 + spread * (P.Xi * 0.9 + 1.0);
	float impact = landed * smoothstep(reach, reach * 0.6, abs(xi - P.Xi)) * (1.0 - smoothstep(1.4, 1.9, P.b));
	float toe = P.Xc + P.Wt;
	float faceFill = shoreFaceFill(P.b, sat((xi - P.Xc) / max(P.Wt, 0.05)));
	float ahead = exp((xi - toe) * -3.0) * P.wBore;
	float behind = exp((P.Xc - xi) / lam * -16.0) * P.wBore;
	float roller = xi > toe ? ahead : (xi < P.Xc ? behind : max(faceFill, P.wBore));
	return sat(max(impact, roller));
}

// cross-section: x shoreward displacement, y height, z foam (or face), w b (or roller)
vec4 shoreProfile(float u, float lam, ShoreBreak P, bool withFoam, out vec2 faceRoller) {
	float skew = smoothstep(-3.0, 0.0, P.b) * 0.55;
	float phi = u - skew * (1.0 - cos(u * SHORE_TAU)) / SHORE_TAU;
	float c = max((cos(phi * SHORE_TAU) + 1.0) * 0.5, 0.0);
	float yPre = P.Ash * 2.0 * (pow(c, P.p) - P.meanP) * P.crestPeak;
	float Q = smoothstep(-3.0, 0.0, P.b) * 0.25 + 0.1;
	float xPre = sin(u * SHORE_TAU) * P.Ash * Q;
	float uf = 0.09;
	bool inFace = u > -uf;
	float th = clamp(-u / uf, 0.0, 1.0) * 1.5707963;
	float fx = mix(1.0 - cos(th), sin(th), P.wBore);
	float fy = mix(1.0 - sin(th), cos(th), P.wBore);
	float sTr = clamp((-u - uf) / (0.5 - uf), 0.0, 1.0);
	float ul = u * lam;
	float xFront = (inFace ? P.Xc + P.Wt * fx : mix(P.Xc + P.Wt, lam * 0.5, sTr)) + ul;
	float yFront = inFace ? P.ytB + (P.ycB - P.ytB) * fy : P.ytB;
	float cb = pow(max((cos(u * (SHORE_TAU * 0.85)) + 1.0) * 0.5, 0.0), P.p);
	float yBack = P.ytB + (P.ycB - P.ytB) * mix(cb, exp(u * -7.0), P.wBore);
	float xBack = P.Xc * exp(u * -6.0) * smoothstep(0.5, 0.35, u) + xPre * (1.0 - P.wBore);
	bool front = u < 0.0;
	float wC = smoothstep(-0.35, 0.25, P.b) * shore_curl;
	float x = mix(xPre, front ? xFront : xBack, wC);
	float y = mix(yPre, front ? yFront : yBack, wC);
	float foam = 0.0;
	faceRoller = vec2(0.0);
	if (withFoam) {
		foam = shoreWhitewater(x - u * lam, lam, P);
		bool onFace = front && inFace;
		float faceFill = shoreFaceFill(P.b, fx);
		faceRoller.x = (onFace ? 1.0 : 0.0) * smoothstep(-0.4, 0.0, P.b) * (1.0 - faceFill);
		faceRoller.y = (front ? (inFace ? 1.0 : 0.0) : exp(u * -25.0)) * P.wBore * P.Hb * wC;
	}
	return vec4(x, y, foam, P.b);
}

// depth under the crest of the wave this parcel belongs to (breaking is a property of the wave)
float shoreBreakDepth(vec2 xz, vec2 dir, float u, float lam, float d) {
	float dc = coast_sample(xz + dir * (u * lam)).y;
	return mix(dc, d, smoothstep(0.3, 0.5, abs(u)));
}

// run-up of the most recent wave: returns (tau, Rt, inland, RhMax); su/sb/isUp recomputed by callers
vec4 shoreSwashRunup(float Ts, float exposure, float along, float groundH) {
	float Tp = shore_period;
	float inland = max(groundH, 0.0) / SHORE_BEACH_SLOPE;
	float ss = (ocean_time - Ts) / Tp + shoreWobble(along);
	float ms = floor(ss);
	float tau = ss - ms;
	float Am = shoreWaveAmp(ms, along);
	float RhMax = Am * 2.1 * shore_runup * sat(exposure * 1.4) / SHORE_BEACH_SLOPE;
	float su = sat(tau / SHORE_SWASH_UP);
	float sb = sat((tau - SHORE_SWASH_UP) / SHORE_SWASH_DOWN);
	bool isUp = tau < SHORE_SWASH_UP;
	float Rh = (isUp ? 1.0 - pow(1.0 - su, 1.5) : 1.0 - pow(sb, 1.6)) * RhMax - 0.3;
	float lobes = sin(along * 0.61 + ms * 2.3) * 0.5 + sin(along * 1.73 + ms * 5.1) * 0.3 + sin(along * 4.3 + ms * 1.7) * 0.2;
	float Rt = max(Rh + lobes * (max(Rh, 0.0) * 0.07 + 0.35), 0.35) * shore_enabled;
	return vec4(tau, Rt, inland, RhMax);
}

// ------------------------------------------------------------ vertex

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float node_size = length(MODEL_MATRIX[0].xyz);
	float spacing0 = node_size / grid_size;
	vec2 grid = VERTEX.xz * grid_size;
	vec2 at = origin.xz + grid * spacing0;
	float dist = distance(lod_camera, vec3(at.x, sea_level, at.y));
	float morph = sat((dist - INSTANCE_CUSTOM.y) / max(INSTANCE_CUSTOM.z - INSTANCE_CUSTOM.y, 1e-3));
	grid -= fract(grid * 0.5) * 2.0 * morph;
	vec2 lag = origin.xz + grid * spacing0;
	float spacing = spacing0 * (1.0 + morph);
	vec2 rel = lag - lod_camera.xz;

	vec4 coast = coast_sample(lag);
	float ground = coast.x;
	float depth = coast.y;
	vec3 disp = vec3(0.0);
	float foam = 0.0;
	float fade = 1.0 - smoothstep(displacement_fade_start, displacement_fade_end, length(rel));
	for (int c = 0; c < cascade_count; c++) {
		// band-limit to the mesh spacing to avoid aliasing / swimming
		float texel = cascade_size[c] / 256.0;
		float level = max(log2(spacing / texel) + 0.7, 0.0);
		float att = cascade_attenuation(c, depth);
		vec2 uv = lag / cascade_size[c];
		vec4 s = textureLod(ocean_displacement[c], uv, level);
		disp += s.xyz * att;
		float fv = s.w;
		if (level < 1.5) { fv = textureLod(ocean_displacement[c], uv, 1.5).w; }
		foam += fv * foam_weight[c] * att;
	}
	disp *= amplitude * fade;

	vec3 extra = vec3(0.0);
	vec3 shoreN = vec3(0.0, 1.0, 0.0);
	float shoreFoam = 0.0;
	float swash = 0.0;
	vec2 surfMask = vec2(0.0);
	float y_rel = disp.y;
	bool nearShore = depth < WATER_SHORE_DEEP && shore_enabled > 0.0 && ground < 3.0;
	float swashLevel = -1e4;
	if (nearShore) {
		float T = coast_time(lag);
		vec2 dirE = coast.zw;
		float exposure = length(dirE);
		vec2 dir = dirE / max(exposure, 1e-4);
		float along = dot(lag, vec2(-dir.y, dir.x));
		float s = (ocean_time - T) / shore_period + shoreWobble(along);
		float d = depth;
		float cw = sqrt(clamp(d, 0.3, 25.0) * SHORE_GRAVITY);
		float lam = cw * shore_period;
		float m = floor(s + 0.5);
		float u = s - m;
		float A0 = shoreWaveAmp(m, along);
		float An = shoreWaveAmp(m + sign(u), along);
		float A = mix(A0, An, smoothstep(0.32, 0.5, abs(u)) * 0.5);
		float dB = shoreBreakDepth(lag, dir, u, lam, d);
		// offshore fade-in (FFT covers deep water) and fade on land (the swash sheet takes over)
		float env = smoothstep(26.0, 13.0, d) * smoothstep(-0.25, 0.05, d) * sat(exposure * 1.4) * shore_enabled;
		// Coarse patches far away cannot hold the wave profile (a triangle spans several crests and
		// the vertices land on random phases): fade the shape out, keep an even surf-zone foam.
		float resolve = 1.0 - smoothstep(lam / 16.0, lam / 8.0, spacing);
		float e = 0.15;
		ShoreBreak P = shoreBreakParams(A, dB);
		vec2 fr0; vec2 fr1;
		vec4 s0 = shoreProfile(u, lam, P, true, fr0);
		vec4 s1 = shoreProfile(u - e / lam, lam, P, false, fr1);
		surfMask = fr0 * env * resolve;
		extra = vec3(dir.x * s0.x, s0.y, dir.y * s0.x) * env * resolve;
		float dX = e + (s1.x - s0.x) * env * resolve;
		float dY = (s1.y - s0.y) * env * resolve;
		vec3 tAlong = vec3(dir.x * dX, dY, dir.y * dX);
		vec3 tAcross = vec3(-dir.y, 0.0, dir.x);
		vec3 n = normalize(cross(tAcross, tAlong) + vec3(0.0, 1e-4, 0.0));
		shoreN = normalize(vec3(n.x, max(n.y, 0.04), n.z));
		shoreFoam = mix(smoothstep(4.0, 1.0, d) * 0.35 * env, s0.z * env, resolve);
		// swash: run-up of the most recent wave on the sand
		vec4 swr = shoreSwashRunup(T, exposure, along, ground);
		float front = swr.y - swr.z;
		float fm = front + SHORE_SWASH_OVERSHOOT;
		// (thicker than Tidewater's 3-12 cm: our coast heights are a 16 m grid, a few dm off the
		// rendered sand, so a thinner sheet would vanish under it or hover over it in patches)
		float thick = clamp(min(fm * 0.3, max(fm - 0.1, 0.0) * (SHORE_BEACH_SLOPE * 0.22) + 0.15), -1.5, 0.3);
		swashLevel = ground + thick;
		float uprush = smoothstep(0.46, 0.32, swr.x);
		float edgeFoam = smoothstep(0.8, 0.0, front) * smoothstep(-0.05, 0.05, front) * uprush * smoothstep(0.0, 1.0, swr.y);
		shoreFoam = max(shoreFoam, edgeFoam * 0.9);
	}
	vec3 total = disp + extra;
	float y = total.y;
	if (nearShore) {
		// thin run-up sheet on the sand: take whichever surface is higher (smooth max)
		float k = 0.04;
		float hmx = sat((swashLevel - y) / k * 0.5 + 0.5);
		float smax = mix(y, swashLevel, hmx) + hmx * (1.0 - hmx) * k;
		swash = smoothstep(-0.02, 0.03, swashLevel - y);
		y = smax;
		float still = 1.0 - hmx;
		shoreN = normalize(mix(shoreN, vec3(0.0, 1.0, 0.0), hmx));
		total = vec3(total.x * still, total.y, total.z * still);
		surfMask *= still;
	}
	// hide the water sheet well below dry land (beyond the swash zone): the rendered sand is only
	// known to a few dm here, and a sheet just under it shows through in patches
	float below = ground < 3.0 ? ground - 1.5 : min(ground - 3.0, -1.5);
	y = (y < ground && swash < 0.5) ? min(y, below) : y;

	vec3 world = vec3(lag.x + total.x, sea_level + y, lag.y + total.z);
	VERTEX = vec3((world.x - origin.x) / node_size, world.y - origin.y, (world.z - origin.z) / node_size);
	v_lag = vec3(lag.x, depth, lag.y);
	v_foam = foam;
	v_shore_n = shoreN;
	v_shore_foam = shoreFoam;
	v_swash = swash;
	v_height = total.y;
	v_ground = ground;
	v_surf_mask = surfMask;
}

// ------------------------------------------------------------ fragment

void fragment() {
	vec2 lag = v_lag.xz;
	float depth = v_lag.y;
	float footprint = length(fwidth(lag));
	vec4 d = vec4(0.0);
	for (int c = 0; c < cascade_count; c++) {
		d += texture(ocean_derivatives[c], lag / cascade_size[c]) * cascade_attenuation(c, depth);
	}
	d *= amplitude;
	vec2 slopes = vec2(d.x / max(d.z + 1.0, 0.2), d.y / max(d.w + 1.0, 0.2));
	float jac = (d.z + 1.0) * (d.w + 1.0);

	// base normal: large shoreline waves (per-vertex) perturbed by FFT detail (reoriented normal mapping)
	vec3 sn = clamp(v_shore_n, vec3(-1.0), vec3(1.0)) + vec3(0.0, 1e-3, 0.0);
	vec3 Ns0 = sn / max(length(sn), 1e-4);
	vec3 Ns = normalize(vec3(Ns0.x, max(Ns0.y, 0.12), Ns0.z));
	vec3 nd = normalize(vec3(-slopes.x, 1.0, -slopes.y));
	vec3 tq = Ns + vec3(0.0, 1.0, 0.0);
	vec3 uq = vec3(slopes.x, 1.0, slopes.y) * nd.y;
	vec3 normal = normalize(tq * (dot(tq, uq) / tq.y) - uq);

	// whitecaps: persistent (per vertex) + fresh where the surface is compressed right now
	float fresh = sat((foam_bias - 0.15 - jac) * 2.0);
	float face = sat(v_surf_mask.x);
	float coverage = sat((v_shore_foam * (1.0 - face * 0.7) + v_foam + fresh) * foam_coverage);
	// foam pattern: an irregular bubbly mat thresholded by coverage; crisp edges (stylized)
	vec2 fuv = lag * foam_scale;
	vec4 p1 = texture(foam_texture, fuv);
	vec2 r2 = vec2(fuv.x * 0.8 - fuv.y * 0.6, fuv.x * 0.6 + fuv.y * 0.8);
	vec4 p2 = texture(foam_texture, r2 * 2.37 + vec2(0.31, 0.77));
	float pattern = p1.x * 0.62 + p2.x * 0.38;
	float thresh = 1.05 - coverage * 1.1;
	float soft = 0.015 + footprint * 0.05;
	float foam = step(0.001, coverage) * smoothstep(thresh - soft, thresh + soft, pattern);
	foam = mix(foam, coverage * 0.85, smoothstep(0.3, 2.0, footprint));

	// colour: shallow turquoise over sand, deep blue offshore (true depth under the water)
	float true_depth = max(-v_ground, 0.0);
	vec3 col = mix(shallow_color, deep_color, smoothstep(1.0, 14.0, true_depth) * 0.6 + smoothstep(14.0, 60.0, depth) * 0.4);
	// crests glow a little where the wave is thin (stylized stand-in for Tidewater's light through the crest)
	col = mix(col, surf_color, sat(v_height * 0.35) * 0.5 + sat(v_surf_mask.x) * 0.35);
	// large, slow colour patches (the foam texture's mottle channel at ~450 m), a stand-in for
	// Tidewater's SeaDetail gusts and slicks so the open sea is not one flat colour
	float mottle = texture(foam_texture, lag / 450.0 + vec2(ocean_time * 0.0007, 0.0)).b;
	col *= mix(0.92, 1.07, mottle);
	// stylized: troughs a shade darker, crests a shade lighter (two soft steps)
	float tone = smoothstep(-0.5, -0.1, v_height) * 0.5 + smoothstep(0.2, 0.7, v_height) * 0.5;
	col *= mix(0.84, 1.1, tone);
	// sky reflection at grazing angles, in two crisp bands (cel look) instead of a smooth Fresnel
	vec3 nv = normalize((VIEW_MATRIX * vec4(normal, 0.0)).xyz);
	float fres = pow(1.0 - sat(dot(nv, VIEW)), 3.0);
	float bands = smoothstep(0.16, 0.2, fres) * 0.45 + smoothstep(0.42, 0.46, fres) * 0.55;
	col = mix(col, sky_tint, bands * reflection_strength);
	col = mix(col, foam_color, foam);
	if (debug_mode == 1) {
		col = vec3(sat(d.x * 4.0 + 0.5), sat(d.y * 4.0 + 0.5), 0.3);
	} else if (debug_mode == 2) {
		col = vec3(sat(-v_ground / 20.0), sat(depth / 60.0), sat(v_ground / 5.0));
	} else if (debug_mode == 3) {
		col = vec3(coverage);
	} else if (debug_mode == 4) {
		col = vec3(fract((ocean_time - coast_time(lag)) / shore_period), v_swash, v_shore_foam);
	}
	ALBEDO = col;
	NORMAL = nv;
	ROUGHNESS = 1.0;
	SPECULAR = 1.0 - foam;
	// see-through over the sand in the shallows and in the swash sheet; foam is opaque
	float alpha = mix(0.35, 1.0, smoothstep(0.0, 2.5, true_depth));
	alpha = mix(alpha, 0.55, v_swash * smoothstep(0.3, 0.0, true_depth));
	ALPHA = max(alpha, foam);
}

// ------------------------------------------------------------ light: cel bands + a hard sun glint

void light() {
	float ndl = dot(NORMAL, LIGHT);
	// three bands like the cel-shaded world; water never goes fully dark in its own shade
	float band = ndl > 0.35 ? 1.0 : (ndl > 0.0 ? 0.72 : 0.48);
	DIFFUSE_LIGHT += band * ATTENUATION * LIGHT_COLOR / PI;
	vec3 H = normalize(VIEW + LIGHT);
	float spec = pow(max(dot(NORMAL, H), 0.0), glint_power);
	float glint = smoothstep(0.25, 0.45, spec) * step(0.0, ndl);
	// SPECULAR_AMOUNT is 0.16 x the fragment's SPECULAR (0 on foam)
	SPECULAR_LIGHT += glint * glint_strength * (SPECULAR_AMOUNT / 0.16) * ATTENUATION * LIGHT_COLOR;
}
