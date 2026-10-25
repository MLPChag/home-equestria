class_name OceanFFT
extends RefCounted
## Multi-cascade FFT ocean (Tessendorf) with a Horvath/JONSWAP spectrum, ported from Tidewater
## (github.com/dgreenheck/tidewater, src/ocean/OceanFFT.js, MIT) from WGSL to Godot compute GLSL.
##
## Each frame runs two FFT dispatches for all cascades:
##   1. row pass: time-evolves the spectrum (h0 -> h(k,t)), builds 4 packed complex fields and
##      performs a 256-point radix-2 IFFT per row in workgroup memory.
##   2. column pass: IFFT per column, sign correction, Jacobian based foam accumulation, and
##      writes displacement / derivative array textures.
## followed by a mip chain per texture (a 2x2 box reduce per level; Tidewater does levels 1-5 in
## one kernel through workgroup memory, here one small dispatch per level and texture).
##
## Packed complex fields (two real fields per complex IFFT):
##   c0 = Dx + i Dz        c1 = Dy + i dDx/dz
##   c2 = dDy/dx + i dDy/dz  c3 = dDx/dx + i dDz/dz
## Textures (Texture2DRD per cascade, rgba16f, mipmapped; Tidewater uses one 2D array, but Godot
## 4.5 cannot view one mip level of all layers of an array for storage):
##   displacement[c] (Dx, Dy, Dz, foam), derivatives[c] (dDy/dx, dDy/dz, dDx/dx, dDz/dz)
## Needs the Forward+/Mobile renderer (a RenderingDevice); `available()` is false otherwise and
## the ocean falls back to the classic plane. All RenderingDevice work runs on the render thread.

const N := 256
const HALF := 128
const GRAVITY := 9.81
## Non-integer ratios between cascade sizes avoid visible repetition.
const DEFAULT_CASCADE_SIZES: Array[float] = [733.0, 157.0, 33.3, 7.1]
const MIP_LEVELS := 9

class WaveSystem:
	var scale := 1.0
	var wind_speed := 8.0        # m/s
	var wind_direction := 20.0   # degrees
	var fetch := 200.0           # km
	var spread_blend := 0.9
	var swell := 0.2
	var peak_enhancement := 3.3
	var short_waves_fade := 0.01
	func _init(o: Dictionary = {}) -> void:
		for k in o: set(k, o[k])

var cascades := 4
var sizes: Array[float] = []
var depth := 500.0
var local := WaveSystem.new({"wind_speed": 7.0, "wind_direction": 25.0, "fetch": 120.0, "spread_blend": 0.85, "swell": 0.05})
var swell := WaveSystem.new({"scale": 0.48, "wind_speed": 6.0, "wind_direction": 5.0, "fetch": 1200.0, "spread_blend": 1.0, "swell": 0.9, "short_waves_fade": 0.1})
var choppiness := 0.9
## foam starts where a cascade compresses the surface below this Jacobian (per-cascade J stays
## close to 1: 0.85 gives ~0.3% whitecap cover at 7 m/s, 0.9 several % in fresh wind)
var foam_bias := 0.58
var foam_gain := 3.0
var foam_decay := 0.35
var foam_add := 2.5
var seed := 1337
var time := 0.0
var time_scale := 1.0
## GPU time of the last frame's FFT compute (ms), when `profile` is on (RenderingDevice timestamps).
var profile := false
var compute_ms := 0.0
var displacement: Array[Texture2DRD] = []
var derivatives: Array[Texture2DRD] = []

var _rd: RenderingDevice
var _ready := false
var _needs_spectrum := true
var _rids: Array[RID] = []
var _params: RID
var _h0a: RID
var _h0: RID
var _wave: RID
var _tmp: RID
var _foam: RID
var _disp_tex: Array[RID] = []
var _deriv_tex: Array[RID] = []
var _pipelines := {}   # name -> [shader, pipeline]
var _sets := {}        # name -> uniform set
var _mip_sets: Array = []   # per level: [disp set, deriv set]

static func available() -> bool:
	return RenderingServer.get_rendering_device() != null

func _init(cascade_count := 4, cascade_sizes: Array[float] = DEFAULT_CASCADE_SIZES) -> void:
	cascades = clampi(cascade_count, 1, 4)
	sizes = cascade_sizes.slice(0, cascades)
	for c in cascades:
		displacement.append(Texture2DRD.new())
		derivatives.append(Texture2DRD.new())
	RenderingServer.call_on_render_thread(_create)

func set_cascade_sizes(value: Array[float]) -> void:
	sizes = value.slice(0, cascades)
	_needs_spectrum = true

## Call after changing a WaveSystem, choppiness or depth: the spectrum is rebuilt on the next
## update. The random phases stay the same, so waves change height smoothly instead of jumping.
func update_spectrum() -> void:
	_needs_spectrum = true

func update(dt: float) -> void:
	time += dt * time_scale
	RenderingServer.call_on_render_thread(_dispatch.bind(dt))

func free_resources() -> void:
	RenderingServer.call_on_render_thread(_free)

# ------------------------------------------------------------------ render thread

func _create() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null: return
	var C := cascades
	var total := N * N * C
	_params = _rd.uniform_buffer_create(_param_bytes().size(), _param_bytes())
	_h0a = _rd.storage_buffer_create(total * 16)
	_h0 = _rd.storage_buffer_create(total * 16)
	_wave = _rd.storage_buffer_create(total * 16)
	_tmp = _rd.storage_buffer_create(total * 32)
	var zero := PackedByteArray(); zero.resize(total * 4)
	_foam = _rd.storage_buffer_create(total * 4, zero)
	_rids.append_array([_params, _h0a, _h0, _wave, _tmp, _foam])
	var level0_disp: Array[RID] = []
	var level0_deriv: Array[RID] = []
	for c in C:
		_disp_tex.append(_texture()); _deriv_tex.append(_texture())
		displacement[c].texture_rd_rid = _disp_tex[c]
		derivatives[c].texture_rd_rid = _deriv_tex[c]
		level0_disp.append(_level_view(_disp_tex[c], 0))
		level0_deriv.append(_level_view(_deriv_tex[c], 0))
	_rids.append_array(_disp_tex); _rids.append_array(_deriv_tex)
	_pipeline("init", _init_code(), [_ubo(0, _params), _ssbo(1, _h0a), _ssbo(2, _wave)])
	_pipeline("conjugate", _conjugate_code(), [_ssbo(0, _h0a), _ssbo(1, _h0)])
	_pipeline("rows", _row_code(), [_ubo(0, _params), _ssbo(1, _h0), _ssbo(2, _wave), _ssbo(3, _tmp)])
	_pipeline("columns", _column_code(), [_ubo(0, _params), _ssbo(1, _tmp), _ssbo(2, _foam), _images(3, level0_disp), _images(4, level0_deriv)])
	var mip_shader := _compile("mips", _mip_code())
	_pipelines["mips"] = [mip_shader, _rd.compute_pipeline_create(mip_shader)]
	for texture: RID in _disp_tex + _deriv_tex:
		var previous := _level_view(texture, 0)
		var chain := []
		for level in range(1, MIP_LEVELS):
			var view := _level_view(texture, level)
			chain.append(_rd.uniform_set_create([_image(0, previous), _image(1, view)], mip_shader, 0))
			previous = view
		_mip_sets.append(chain)
	_ready = true

func _texture() -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.width = N; format.height = N; format.depth = 1
	format.array_layers = 1; format.mipmaps = MIP_LEVELS
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var rid := _rd.texture_create(format, RDTextureView.new(), [])
	_rd.texture_clear(rid, Color(0, 0, 0, 0), 0, MIP_LEVELS, 0, 1)
	return rid

func _level_view(texture: RID, level: int) -> RID:
	var view := _rd.texture_create_shared_from_slice(RDTextureView.new(), texture, 0, level, 1, RenderingDevice.TEXTURE_SLICE_2D)
	_rids.append(view)
	return view

func _ubo(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; u.binding = binding; u.add_id(rid); return u

func _ssbo(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = binding; u.add_id(rid); return u

func _images(binding: int, rids: Array[RID]) -> RDUniform:
	# a GLSL array of images: one id per cascade, padded to 4 with the last one
	var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u.binding = binding
	for i in 4: u.add_id(rids[mini(i, rids.size() - 1)])
	return u

func _image(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; u.binding = binding; u.add_id(rid); return u

func _compile(name: String, code: String) -> RID:
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = code
	var spirv := _rd.shader_compile_spirv_from_source(source)
	if spirv.compile_error_compute != "":
		push_error("ocean %s shader: %s" % [name, spirv.compile_error_compute])
	var shader := _rd.shader_create_from_spirv(spirv, "ocean_" + name)
	_rids.append(shader)
	return shader

func _pipeline(name: String, code: String, uniforms: Array) -> void:
	var shader := _compile(name, code)
	var pipeline := _rd.compute_pipeline_create(shader)
	_pipelines[name] = [shader, pipeline]
	_sets[name] = _rd.uniform_set_create(uniforms, shader, 0)

func _param_bytes(dt := 0.0) -> PackedByteArray:
	var f := PackedFloat32Array()
	for i in 4: f.append_array([sizes[i] if i < sizes.size() else 1.0, 0.0, 0.0, 0.0])
	for i in 4:
		# Unused slots (the headset runs 3 cascades) stay zero; `sizes` only holds the used ones.
		if i >= cascades:
			f.append_array([0.0, 0.0, 0.0, 0.0])
			continue
		var low := 0.0001 if i == 0 else (TAU / sizes[i]) * 6.0
		var high := 9999.0 if i >= cascades - 1 else (TAU / sizes[i + 1]) * 6.0
		f.append_array([low, high, 0.0, 0.0])
	var sys_a := PackedFloat32Array(); var sys_b := PackedFloat32Array()
	for s: WaveSystem in [local, swell]:
		var fetch_m := maxf(1.0, s.fetch) * 1000.0
		var u := maxf(0.1, s.wind_speed)
		var alpha := 0.076 * pow(GRAVITY * fetch_m / (u * u), -0.22)
		var peak_omega := 22.0 * pow(u * fetch_m / (GRAVITY * GRAVITY), -0.33)
		sys_a.append_array([s.scale, deg_to_rad(s.wind_direction), s.spread_blend, s.swell])
		sys_b.append_array([alpha, peak_omega, s.peak_enhancement, s.short_waves_fade])
	f.append_array(sys_a); f.append_array(sys_b)
	f.append_array([choppiness, foam_bias, foam_gain, foam_decay, foam_add, time, depth, dt, float(seed), float(cascades), 0.0, 0.0])
	return f.to_byte_array()

func _dispatch(dt: float) -> void:
	if not _ready: return
	if profile: _read_timestamps()
	var bytes := _param_bytes(dt)
	_rd.buffer_update(_params, 0, bytes.size(), bytes)
	var C := cascades
	if profile: _rd.capture_timestamp("ocean_fft_begin")
	var list := _rd.compute_list_begin()
	if _needs_spectrum:
		_needs_spectrum = false
		_run(list, "init", Vector3i(N / 16, N / 16, C))
		_rd.compute_list_add_barrier(list)
		_run(list, "conjugate", Vector3i(N / 16, N / 16, C))
		_rd.compute_list_add_barrier(list)
	_run(list, "rows", Vector3i(N, C, 1))
	_rd.compute_list_add_barrier(list)
	_run(list, "columns", Vector3i(N, C, 1))
	_rd.compute_list_add_barrier(list)
	var mips: Array = _pipelines["mips"]
	_rd.compute_list_bind_compute_pipeline(list, mips[1])
	for level in range(1, MIP_LEVELS):
		var size := N >> level
		var groups := maxi(1, (size + 7) / 8)
		for chain: Array in _mip_sets:
			_rd.compute_list_bind_uniform_set(list, chain[level - 1], 0)
			_rd.compute_list_dispatch(list, groups, groups, 1)
		_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	if profile: _rd.capture_timestamp("ocean_fft_end")

func _read_timestamps() -> void:
	var begin := -1
	for i in _rd.get_captured_timestamps_count():
		var name := _rd.get_captured_timestamp_name(i)
		if name == "ocean_fft_begin": begin = i
		elif name == "ocean_fft_end" and begin >= 0:
			compute_ms = float(_rd.get_captured_timestamp_gpu_time(i) - _rd.get_captured_timestamp_gpu_time(begin)) / 1000000.0

func _run(list: int, name: String, groups: Vector3i) -> void:
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[name][1])
	_rd.compute_list_bind_uniform_set(list, _sets[name], 0)
	_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)

func _free() -> void:
	if _rd == null: return
	_ready = false
	for t in displacement + derivatives: t.texture_rd_rid = RID()
	# Freeing a texture also frees its shared views and the uniform sets that use them, and a
	# shader its pipelines: free the owners only, buffers after the sets that use them.
	for rid in _disp_tex + _deriv_tex: if _rd.texture_is_valid(rid): _rd.free_rid(rid)
	for name in _pipelines: if _pipelines[name][0].is_valid(): _rd.free_rid(_pipelines[name][0])
	for rid in [_params, _h0a, _h0, _wave, _tmp, _foam]: if rid.is_valid(): _rd.free_rid(rid)
	_rids.clear(); _sets.clear(); _mip_sets.clear(); _pipelines.clear(); _disp_tex.clear(); _deriv_tex.clear()

# ------------------------------------------------------------------ GLSL

const COMMON := """
#version 450
#define N 256u
#define HALF 128u
#define FFT_G 9.81
#define PI 3.14159265358979
#define TWO_PI 6.28318530717959
layout(set = 0, binding = 0, std140) uniform Params {
	vec4 sizes[4];     // x: cascade tile size (m)
	vec4 cuts[4];      // x: low wavenumber cut, y: high cut
	vec4 sysA[2];      // per system: scale, angle, spreadBlend, swell
	vec4 sysB[2];      // per system: alpha, peakOmega, gamma, shortWavesFade
	float choppiness; float foamBias; float foamGain; float foamDecay;
	float foamAdd; float time; float depth; float dt;
	float seedF; float cascadesF; float pad0; float pad1;
} ocean;
uint fftBitReverse8(uint v) {
	uint r = v;
	r = ((r & 0x55u) << 1u) | ((r >> 1u) & 0x55u);
	r = ((r & 0x33u) << 2u) | ((r >> 2u) & 0x33u);
	r = ((r & 0x0Fu) << 4u) | ((r >> 4u) & 0x0Fu);
	return r;
}
// complex multiply of two packed complex numbers (v.xy, v.zw) by scalar complex w
vec4 fftCmul2(vec4 v, vec2 w) {
	return vec4(v.x * w.x - v.y * w.y, v.x * w.y + v.y * w.x, v.z * w.x - v.w * w.y, v.z * w.y + v.w * w.x);
}
// PCG hash
uint fftPcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}
float fftToUnit(uint h) { return float(h >> 8u) * (1.0 / 16777216.0) + (0.5 / 16777216.0); }
"""

func _init_code() -> String:
	return COMMON + """
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 1, std430) restrict buffer H0 { vec4 h0[]; };
layout(set = 0, binding = 2, std430) restrict buffer Wave { vec4 waveData[]; };

float dispersion(float k) { return sqrt(k * FFT_G * tanh(min(k * ocean.depth, 20.0))); }
float dispersionDerivative(float k) {
	float kd = min(k * ocean.depth, 20.0);
	float th = tanh(kd);
	float ch = cosh(kd);
	return FFT_G * (ocean.depth * k / (ch * ch) + th) / dispersion(k) * 0.5;
}
float tmaCorrection(float omega) {
	float omegaH = omega * sqrt(ocean.depth / FFT_G);
	float a = omegaH * omegaH * 0.5;
	float b = 1.0 - pow(2.0 - omegaH, 2.0) * 0.5;
	return omegaH <= 1.0 ? a : (omegaH < 2.0 ? b : 1.0);
}
float jonswap(float omega, vec4 sysA, vec4 sysB) {
	float alpha = sysB.x; float peakOmega = sysB.y; float gamma = sysB.z;
	float sigma = omega <= peakOmega ? 0.07 : 0.09;
	float d = omega - peakOmega;
	float r = exp(-d * d / (sigma * sigma * peakOmega * peakOmega * 2.0));
	float inv = 1.0 / omega;
	float po = peakOmega * inv;
	return sysA.x * tmaCorrection(omega) * alpha * (FFT_G * FFT_G)
		* pow(inv, 5.0) * exp(pow(po, 4.0) * -1.25) * pow(abs(gamma), r);
}
float normalisationFactor(float s) {
	float s2 = s * s; float s3 = s2 * s; float s4 = s3 * s;
	float lo = s4 * -0.000564 + s3 * 0.00776 - s2 * 0.044 + s * 0.192 + 0.163;
	float hi = s4 * -4.80e-08 + s3 * 1.07e-05 - s2 * 9.53e-04 + s * 5.90e-02 + 3.93e-01;
	return s < 5.0 ? lo : hi;
}
float directionSpectrum(float theta, float omega, vec4 sysA, vec4 sysB) {
	float peakOmega = sysB.y;
	float ratio = omega / peakOmega;
	float spreadPower = omega > peakOmega ? pow(abs(ratio), -2.5) * 9.77 : pow(abs(ratio), 5.0) * 6.97;
	float s = spreadPower + tanh(min(ratio, 20.0)) * 16.0 * sysA.w * sysA.w;
	float dTheta = theta - sysA.y;
	float cos2s = normalisationFactor(s) * pow(abs(cos(dTheta * 0.5)), s * 2.0);
	float cosT = cos(dTheta);
	float base = cosT * cosT * (2.0 / PI) * (cosT > 0.0 ? 1.0 : 0.0);
	return mix(base, cos2s, sysA.z);
}
float shortWavesFade(float k, vec4 sysB) { return exp(-sysB.w * sysB.w * k * k); }

void main() {
	int x = int(gl_GlobalInvocationID.x); int y = int(gl_GlobalInvocationID.y); int c = int(gl_GlobalInvocationID.z);
	int idx = c * int(N * N) + y * int(N) + x;
	float L = ocean.sizes[c].x;
	float dk = TWO_PI / L;
	float kx = float(x - int(HALF)) * dk;
	float kz = float(y - int(HALF)) * dk;
	float kLen = length(vec2(kx, kz));
	vec4 outH = vec4(0.0);
	vec4 outW = vec4(kx, kz, 0.0, 0.0);
	if (kLen >= ocean.cuts[c].x && kLen <= ocean.cuts[c].y) {
		float omega = dispersion(kLen);
		float dOmega = dispersionDerivative(kLen);
		float theta = atan(kz, kx);
		float S0 = jonswap(omega, ocean.sysA[0], ocean.sysB[0]) * directionSpectrum(theta, omega, ocean.sysA[0], ocean.sysB[0]) * shortWavesFade(kLen, ocean.sysB[0]);
		float S1 = jonswap(omega, ocean.sysA[1], ocean.sysB[1]) * directionSpectrum(theta, omega, ocean.sysA[1], ocean.sysB[1]) * shortWavesFade(kLen, ocean.sysB[1]);
		float S = max(S0 + S1, 0.0);
		// E|h0|^2 = S(k) dk^2 / 2 so that var(height) = sum S(k) dk^2 (h has both +k and -k terms)
		float amp = sqrt(S * abs(dOmega) / kLen * dk * dk) * 0.5;
		// gaussian random pair (Box-Muller)
		uint seed = uint(idx) * 4u + uint(ocean.seedF) * 7919u;
		float u1 = fftToUnit(fftPcg(seed));
		float u2 = fftToUnit(fftPcg(seed + 1u));
		float r = sqrt(log(u1) * -2.0);
		outH = vec4(r * cos(u2 * TWO_PI) * amp, r * sin(u2 * TWO_PI) * amp, 0.0, 0.0);
		outW = vec4(kx, kz, 1.0 / kLen, omega);
	}
	h0[idx] = outH;
	waveData[idx] = outW;
}
"""

func _conjugate_code() -> String:
	return """
#version 450
#define N 256
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict readonly buffer H0A { vec4 h0a[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer H0 { vec4 h0[]; };
void main() {
	int x = int(gl_GlobalInvocationID.x); int y = int(gl_GlobalInvocationID.y); int c = int(gl_GlobalInvocationID.z);
	int base = c * N * N;
	int idx = base + y * N + x;
	int xm = (N - x) % N;
	int ym = (N - y) % N;
	vec2 hm = h0a[base + ym * N + xm].xy;
	vec2 cur = h0a[idx].xy;
	h0[idx] = vec4(cur.x, cur.y, hm.x, -hm.y);
}
"""

const STAGES := """
	for (uint s = 0u; s < 8u; s++) {
		uint halfSpan = 1u << s;
		uint pos = t & (halfSpan - 1u);
		uint i = ((t >> s) << (s + 1u)) | pos;
		uint j = i + halfSpan;
		float ang = float(pos) * PI / float(halfSpan);
		vec2 w = vec2(cos(ang), sin(ang));
		uint i2 = i * 2u; uint j2 = j * 2u;
		vec4 a0 = fftShared[i2]; vec4 a1 = fftShared[i2 + 1u];
		vec4 b0 = fftCmul2(fftShared[j2], w); vec4 b1 = fftCmul2(fftShared[j2 + 1u], w);
		fftShared[i2] = a0 + b0;
		fftShared[i2 + 1u] = a1 + b1;
		fftShared[j2] = a0 - b0;
		fftShared[j2 + 1u] = a1 - b1;
		memoryBarrierShared(); barrier();
	}
"""

func _row_code() -> String:
	return COMMON + """
layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 1, std430) restrict readonly buffer H0 { vec4 h0[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer Wave { vec4 waveData[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer Tmp { vec4 tmp[]; };
shared vec4 fftShared[512];
void main() {
	uint t = gl_LocalInvocationID.x;
	uint row = gl_WorkGroupID.x;
	uint c = gl_WorkGroupID.y;
	uint base = c * N * N + row * N;
	float time = ocean.time;
	for (uint e = 0u; e < 2u; e++) {
		uint x = t + e * HALF;
		uint idx = base + x;
		vec4 w = waveData[idx];
		vec4 hv = h0[idx];
		float ph = w.w * time;
		float cs = cos(ph); float sn = sin(ph);
		// h = h0 * e^{i w t} + conj(h0(-k)) * e^{-i w t}
		float hr = hv.x * cs - hv.y * sn + hv.z * cs + hv.w * sn;
		float hi = hv.x * sn + hv.y * cs - hv.z * sn + hv.w * cs;
		float kx = w.x; float kz = w.y; float ik = w.z;
		float fx = kx * ik; float fz = kz * ik;
		// Dx_hat = i kx/k h, Dz_hat = i kz/k h  ->  c0 = Dx + i Dz
		vec2 c0 = vec2(-(fx * hi + fz * hr), fx * hr - fz * hi);
		// c1 = Dy + i dDx/dz,  dDx/dz_hat = -kx kz / k h
		float q = -(kx * kz * ik);
		vec2 c1 = vec2(hr - q * hi, hi + q * hr);
		// c2 = dDy/dx + i dDy/dz
		vec2 c2 = vec2(-(kx * hi + kz * hr), kx * hr - kz * hi);
		// c3 = dDx/dx + i dDz/dz
		float a = -(kx * kx * ik); float b = -(kz * kz * ik);
		vec2 c3 = vec2(a * hr - b * hi, a * hi + b * hr);
		uint r = fftBitReverse8(x) * 2u;
		fftShared[r] = vec4(c0, c1);
		fftShared[r + 1u] = vec4(c2, c3);
	}
	memoryBarrierShared(); barrier();
""" + STAGES + """
	for (uint e = 0u; e < 2u; e++) {
		uint x = t + e * HALF;
		uint o = (base + x) * 2u;
		tmp[o] = fftShared[x * 2u];
		tmp[o + 1u] = fftShared[x * 2u + 1u];
	}
}
"""

func _column_code() -> String:
	return COMMON + """
layout(local_size_x = 128, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 1, std430) restrict readonly buffer Tmp { vec4 tmp[]; };
layout(set = 0, binding = 2, std430) restrict buffer Foam { float foam[]; };
layout(set = 0, binding = 3, rgba16f) uniform restrict writeonly image2D dispOut[4];
layout(set = 0, binding = 4, rgba16f) uniform restrict writeonly image2D derivOut[4];
shared vec4 fftShared[512];
void main() {
	uint t = gl_LocalInvocationID.x;
	uint col = gl_WorkGroupID.x;
	uint c = gl_WorkGroupID.y;
	uint base = c * N * N;
	for (uint e = 0u; e < 2u; e++) {
		uint y = t + e * HALF;
		uint idx = base + y * N + col;
		uint r = fftBitReverse8(y) * 2u;
		fftShared[r] = tmp[idx * 2u];
		fftShared[r + 1u] = tmp[idx * 2u + 1u];
	}
	memoryBarrierShared(); barrier();
""" + STAGES + """
	float lambda = ocean.choppiness;
	for (uint e = 0u; e < 2u; e++) {
		uint y = t + e * HALF;
		uint idx = base + y * N + col;
		float sgn = ((col + y) & 1u) == 0u ? 1.0 : -1.0;
		vec4 A = fftShared[y * 2u] * sgn;
		vec4 B = fftShared[y * 2u + 1u] * sgn;
		float Dx = A.x; float Dz = A.y; float Dy = A.z; float Dxz = A.w;
		float Dyx = B.x; float Dyz = B.y; float Dxx = B.z; float Dzz = B.w;
		float jxx = lambda * Dxx + 1.0;
		float jzz = lambda * Dzz + 1.0;
		float jxz = lambda * Dxz;
		float J = jxx * jzz - jxz * jxz;
		// Persistent foam: generated where the surface compresses (J < bias),
		// then slowly decays so whitecaps leave trailing foam patches.
		float prev = foam[idx];
		float gen = clamp((ocean.foamBias - J) * ocean.foamGain, 0.0, 1.0);
		float f = prev * exp(-ocean.foamDecay * ocean.dt) + gen * ocean.foamAdd * ocean.dt;
		float fNew = clamp(max(f, gen * 0.5), 0.0, 1.5);
		foam[idx] = fNew;
		ivec2 uv = ivec2(int(col), int(y));
		imageStore(dispOut[c], uv, vec4(lambda * Dx, Dy, lambda * Dz, fNew));
		imageStore(derivOut[c], uv, vec4(Dyx, Dyz, lambda * Dxx, lambda * Dzz));
	}
}
"""

func _mip_code() -> String:
	return """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba16f) uniform restrict readonly image2D src;
layout(set = 0, binding = 1, rgba16f) uniform restrict writeonly image2D dst;
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst);
	if (p.x >= size.x || p.y >= size.y) return;
	ivec2 s = p * 2;
	vec4 v = (imageLoad(src, s) + imageLoad(src, s + ivec2(1, 0)) + imageLoad(src, s + ivec2(0, 1)) + imageLoad(src, s + ivec2(1, 1))) * 0.25;
	imageStore(dst, p, v);
}
"""
