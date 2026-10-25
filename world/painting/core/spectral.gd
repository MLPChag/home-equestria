extends RefCounted
## Real-paint colour mixing (docs/DESIGN.md 2.16): a GDScript port of spectral.js 3.0.0
## (Ronald van Wijnen, MIT, https://github.com/rvanwijnen/spectral.js). The JS source is
## docs/reference/mixlab/spectral.js. Pure static math, no Node dependency.
##
## The model, as in spectral.js:
## - 8-bit sRGB -> linear RGB (sRGB transfer, GAMMA 2.4) -> a reflectance spectrum of SIZE = 38
##   samples, built from 7 base spectra (white, cyan, magenta, yellow, red, green, blue).
## - Kubelka-Munk single-constant mixing: KS = (1 - R)^2 / (2 R) per sample; the mixed KS is the
##   concentration-weighted mean, concentration = factor^2 x strength^2 x luminance (luminance =
##   max(EPSILON, Y)); KM(KS) = 1 + KS - sqrt(KS^2 + 2 KS) gives the mixed reflectance.
## - Reflectance -> XYZ (CIE 1931 colour matching functions x D65) -> linear RGB -> 8-bit sRGB.
##   Out-of-gamut results go through the spectral.js gamut map (binary search on OKLCh chroma
##   with a JND of 0.03), exactly as Color.toString() does.
##
## Bit-exact port: every operation keeps the JS order (sums left to right, x ** 2 as x * x,
## x ** 0.5 as sqrt). The tables are stored as IEEE-754 bit patterns, because Godot's float
## literal parser is not always correctly rounded (1.2268798758459243 parses 1 ulp off).
## tests/test_spectral.gd checks the 96 cases of tests/fixtures/spectral_golden.json.
##
## Colours in: Godot Colors, quantised to 8-bit sRGB (r8, g8, b8) like a parsed hex string.
## Colours out: 8-bit sRGB Colors (Color8), alpha 1.

const SIZE := 38
const GAMMA := 2.4
## Number.EPSILON (2^-52).
const EPSILON := 2.220446049250313e-16
## gamutMap() defaults of spectral.js.
const GAMUT_JND := 0.03
const GAMUT_E := 0.0001
const EMPTY := Color(0, 0, 0, 0)
## Per-colour cache (0xRRGGBB -> [luminance, KS x 38]) is cleared when it holds this many colours.
const CACHE_LIMIT := 8192

static var _tables_ready: bool = false
static var _base: PackedFloat64Array      # 7 x 38: W, C, M, Y, R, G, B
static var _cmf: PackedFloat64Array       # 3 x 38
static var _rgb_xyz: PackedFloat64Array   # 3 x 3 each, row after row
static var _xyz_rgb: PackedFloat64Array
static var _xyz_lms: PackedFloat64Array
static var _lms_xyz: PackedFloat64Array
static var _lms_lab: PackedFloat64Array
static var _lab_lms: PackedFloat64Array
static var _uncompand8: PackedFloat64Array   # uncompand(i / 255) for i in 0..255
static var _cache: Dictionary = {}           # int 0xRRGGBB -> PackedFloat64Array


# --- public API ---------------------------------------------------------------------------

## spectral.mix([colors[0], factors[0]], ...).toString() as a Color: the Kubelka-Munk mix,
## gamut mapped, 8-bit, alpha 1. [param strengths] are the tinting strengths (an empty array means
## 1.0 for every colour). One colour still goes through the reflectance round trip, as in
## spectral.js. Returns EMPTY for no colours, mismatched sizes or factors that are all 0.
static func mix(colors: Array[Color], factors: PackedFloat64Array,
		strengths: PackedFloat64Array = PackedFloat64Array()) -> Color:
	var xyz: PackedFloat64Array = _mix_xyz(colors, factors, strengths)
	if xyz.is_empty():
		return EMPTY
	return _srgb8_color(_xyz_to_srgb8(xyz))


## OKLab of the mix before the gamut map (spectral.mix(...).OKLab): [L, a, b] in float64.
## Empty for the same inputs that make mix() return EMPTY.
static func mix_oklab(colors: Array[Color], factors: PackedFloat64Array,
		strengths: PackedFloat64Array = PackedFloat64Array()) -> PackedFloat64Array:
	var xyz: PackedFloat64Array = _mix_xyz(colors, factors, strengths)
	if xyz.is_empty():
		return PackedFloat64Array()
	return _xyz_to_oklab(xyz)


## OKLab of [param c] as spectral.js computes it for new Color(hex).OKLab: through the
## reflectance spectrum (sRGB -> linear -> R -> XYZ -> OKLab), as float64 [L, a, b].
static func to_oklab64(c: Color) -> PackedFloat64Array:
	_ensure_tables()
	return _xyz_to_oklab(_r_to_xyz(_srgb8_to_r(c.r8, c.g8, c.b8)))


## to_oklab64() as a Vector3 (float32 precision; enough for distances and display).
static func to_oklab(c: Color) -> Vector3:
	var lab: PackedFloat64Array = to_oklab64(c)
	return Vector3(lab[0], lab[1], lab[2])


## Euclidean distance in OKLab (deltaEOK of spectral.js) between two colours, in float64.
static func oklab_distance(a: Color, b: Color) -> float:
	return delta_eok(to_oklab64(a), to_oklab64(b))


## deltaEOK of two float64 OKLab triples.
static func delta_eok(lab1: PackedFloat64Array, lab2: PackedFloat64Array) -> float:
	var dl: float = lab1[0] - lab2[0]
	var da: float = lab1[1] - lab2[1]
	var db: float = lab1[2] - lab2[2]
	return sqrt(dl * dl + da * da + db * db)


## The sRGB transfer, inverse (0..1 -> linear).
static func uncompand(x: float) -> float:
	return pow((x + 0.055) / 1.055, GAMMA) if x > 0.04045 else x / 12.92


## The sRGB transfer (linear -> 0..1).
static func compand(x: float) -> float:
	return 1.055 * pow(x, 1.0 / GAMMA) - 0.055 if x > 0.0031308 else x * 12.92


## Kubelka-Munk K/S of a reflectance sample.
static func ks(r: float) -> float:
	return (1.0 - r) * (1.0 - r) / (2.0 * r)


## The reflectance of a K/S value.
static func km(k: float) -> float:
	return 1.0 + k - sqrt(k * k + 2.0 * k)


## The reflectance spectrum (SIZE samples) of an 8-bit sRGB colour (lRGB_to_R of spectral.js).
static func reflectance(c: Color) -> PackedFloat64Array:
	_ensure_tables()
	return _srgb8_to_r(c.r8, c.g8, c.b8)


## Drops the per-colour cache (tests; memory).
static func clear_cache() -> void:
	_cache.clear()


# --- mixing -------------------------------------------------------------------------------

# XYZ of the KM mix; empty for invalid input.
static func _mix_xyz(colors: Array[Color], factors: PackedFloat64Array,
		strengths: PackedFloat64Array) -> PackedFloat64Array:
	var n: int = colors.size()
	if n == 0 or factors.size() != n or (strengths.size() != 0 and strengths.size() != n):
		if n != 0:
			push_error("PaintingSpectral.mix: %d colours, %d factors, %d strengths" % [
				n, factors.size(), strengths.size()])
		return PackedFloat64Array()
	_ensure_tables()
	var data: Array[PackedFloat64Array] = []
	var conc := PackedFloat64Array()
	conc.resize(n)
	var total: float = 0.0
	for j: int in n:
		var d: PackedFloat64Array = _color_data(colors[j])
		data.append(d)
		var f: float = factors[j]
		var s: float = strengths[j] if strengths.size() == n else 1.0
		# factor ** 2 * tintingStrength ** 2 * luminance, left to right.
		conc[j] = f * f * (s * s) * d[0]
		total += conc[j]
	if not (total > 0.0):
		return PackedFloat64Array()
	var r := PackedFloat64Array()
	r.resize(SIZE)
	for i: int in SIZE:
		var ks_mix: float = 0.0
		for j: int in n:
			ks_mix += data[j][i + 1] * conc[j]
		r[i] = km(ks_mix / total)
	return _r_to_xyz(r)


# [luminance, KS x 38] of an 8-bit colour, cached.
static func _color_data(c: Color) -> PackedFloat64Array:
	var key: int = (c.r8 << 16) | (c.g8 << 8) | c.b8
	var hit: Variant = _cache.get(key)
	if hit != null:
		return hit
	var r: PackedFloat64Array = _srgb8_to_r(c.r8, c.g8, c.b8)
	var xyz: PackedFloat64Array = _r_to_xyz(r)
	var d := PackedFloat64Array()
	d.resize(SIZE + 1)
	d[0] = maxf(EPSILON, xyz[1])
	for i: int in SIZE:
		d[i + 1] = ks(r[i])
	if _cache.size() >= CACHE_LIMIT:
		_cache.clear()
	_cache[key] = d
	return d


# --- conversions (spectral.js names in the comments) -----------------------------------------

# sRGB_to_lRGB + lRGB_to_R.
static func _srgb8_to_r(r8: int, g8: int, b8: int) -> PackedFloat64Array:
	var l0: float = _uncompand8[clampi(r8, 0, 255)]
	var l1: float = _uncompand8[clampi(g8, 0, 255)]
	var l2: float = _uncompand8[clampi(b8, 0, 255)]
	var w: float = minf(minf(l0, l1), l2)
	l0 -= w
	l1 -= w
	l2 -= w
	var c: float = minf(l1, l2)
	var m: float = minf(l0, l2)
	var y: float = minf(l0, l1)
	var r: float = maxf(0.0, minf(l0 - l2, l0 - l1))
	var g: float = maxf(0.0, minf(l1 - l2, l1 - l0))
	var b: float = maxf(0.0, minf(l2 - l1, l2 - l0))
	var out := PackedFloat64Array()
	out.resize(SIZE)
	for i: int in SIZE:
		out[i] = maxf(EPSILON, w * _base[i] + c * _base[SIZE + i] + m * _base[2 * SIZE + i]
				+ y * _base[3 * SIZE + i] + r * _base[4 * SIZE + i] + g * _base[5 * SIZE + i]
				+ b * _base[6 * SIZE + i])
	return out


# R_to_XYZ: CMF (3 x 38) times R, each row summed left to right.
static func _r_to_xyz(r: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(3)
	for row: int in 3:
		var acc: float = 0.0
		var o: int = row * SIZE
		for i: int in SIZE:
			acc += _cmf[o + i] * r[i]
		out[row] = acc
	return out


# utils.mulMatVec for a 3 x 3 matrix stored row after row.
static func _mul3(m: PackedFloat64Array, v: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(3)
	for row: int in 3:
		out[row] = 0.0 + m[row * 3] * v[0] + m[row * 3 + 1] * v[1] + m[row * 3 + 2] * v[2]
	return out


# XYZ_to_OKLab.
static func _xyz_to_oklab(xyz: PackedFloat64Array) -> PackedFloat64Array:
	var lms: PackedFloat64Array = _mul3(_xyz_lms, xyz)
	for i: int in 3:
		lms[i] = _cbrt(lms[i])
	return _mul3(_lms_lab, lms)


# OKLab_to_XYZ.
static func _oklab_to_xyz(lab: PackedFloat64Array) -> PackedFloat64Array:
	var lms: PackedFloat64Array = _mul3(_lab_lms, lab)
	for i: int in 3:
		lms[i] = pow(lms[i], 3.0)
	return _mul3(_lms_xyz, lms)


# lRGB_to_OKLab.
static func _lrgb_to_oklab(lrgb: PackedFloat64Array) -> PackedFloat64Array:
	return _xyz_to_oklab(_mul3(_rgb_xyz, lrgb))


# Math.cbrt: pow() on |x| and one Newton step, so the result is within about 1 ulp of the true
# cube root (V8 uses the fdlibm cbrt, error < 0.667 ulp).
static func _cbrt(x: float) -> float:
	if x == 0.0 or not is_finite(x):
		return x
	var ax: float = absf(x)
	var y: float = pow(ax, 1.0 / 3.0)
	y = y - (y * y * y - ax) / (3.0 * y * y)
	return y if x > 0.0 else -y


# Math.round: the nearest integer, halves toward +infinity.
static func _round_js(x: float) -> float:
	var f: float = floorf(x)
	return f + 1.0 if x - f >= 0.5 else f


static func _in_gamut(lrgb: PackedFloat64Array) -> bool:
	for v: float in lrgb:
		if not (v >= 0.0 and v <= 1.0):
			return false
	return true


# lRGB_to_sRGB: Math.round(compand(x) * 255) per channel.
static func _lrgb_to_srgb8(lrgb: PackedFloat64Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(3)
	for i: int in 3:
		out[i] = int(_round_js(compand(lrgb[i]) * 255.0))
	return out


# new Color(R) followed by toString() (method 'map'): the 8-bit sRGB of a mix result.
static func _xyz_to_srgb8(xyz: PackedFloat64Array) -> PackedInt32Array:
	var lrgb: PackedFloat64Array = _mul3(_xyz_rgb, xyz)
	if _in_gamut(lrgb):
		return _lrgb_to_srgb8(lrgb)
	return _gamut_map(xyz, lrgb)


# gamutMap(color) of spectral.js; returns the sRGB of the mapped colour.
static func _gamut_map(xyz: PackedFloat64Array, lrgb: PackedFloat64Array) -> PackedInt32Array:
	var lab: PackedFloat64Array = _xyz_to_oklab(xyz)
	var l: float = lab[0]
	if l >= 1.0:
		return PackedInt32Array([255, 255, 255])
	if l <= 0.0:
		return PackedInt32Array([0, 0, 0])
	# OKLab_to_OKLCh
	var hue: float = (atan2(lab[2], lab[1]) * 180.0) / PI
	if hue < 0.0:
		hue += 360.0
	var lo: float = 0.0
	var hi: float = sqrt(lab[1] * lab[1] + lab[2] * lab[2])
	var lo_in_gamut: bool = true
	var current: PackedFloat64Array = lrgb
	var clipped: PackedFloat64Array = _lrgb_to_oklab(_clamp01(current))
	var e: float = delta_eok(clipped, _lrgb_to_oklab(current))
	if e < GAMUT_JND:
		return _lrgb_to_srgb8(_mul3(_xyz_rgb, _oklab_to_xyz(clipped)))
	while hi - lo > GAMUT_E:
		var chroma: float = (lo + hi) / 2.0
		# OKLCh_to_OKLab
		var probe := PackedFloat64Array([l, chroma * cos((hue * PI) / 180.0),
				chroma * sin((hue * PI) / 180.0)])
		current = _mul3(_xyz_rgb, _oklab_to_xyz(probe))
		if lo_in_gamut and _in_gamut(current):
			lo = chroma
		else:
			clipped = _lrgb_to_oklab(_clamp01(current))
			e = delta_eok(clipped, probe)
			if e < GAMUT_JND:
				if GAMUT_JND - e < GAMUT_E:
					break
				lo_in_gamut = false
				lo = chroma
			else:
				hi = chroma
	return _lrgb_to_srgb8(_mul3(_xyz_rgb, _oklab_to_xyz(clipped)))


static func _clamp01(v: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(v.size())
	for i: int in v.size():
		out[i] = minf(maxf(v[i], 0.0), 1.0)
	return out


static func _srgb8_color(c: PackedInt32Array) -> Color:
	return Color8(clampi(c[0], 0, 255), clampi(c[1], 0, 255), clampi(c[2], 0, 255))


static func _ensure_tables() -> void:
	if _tables_ready:
		return
	_base = _decode(_BASE_SPECTRA_BITS)
	_cmf = _decode(_CMF_BITS)
	_rgb_xyz = _decode(_RGB_XYZ_BITS)
	_xyz_rgb = _decode(_XYZ_RGB_BITS)
	_xyz_lms = _decode(_XYZ_LMS_BITS)
	_lms_xyz = _decode(_LMS_XYZ_BITS)
	_lms_lab = _decode(_LMS_LAB_BITS)
	_lab_lms = _decode(_LAB_LMS_BITS)
	_uncompand8 = PackedFloat64Array()
	_uncompand8.resize(256)
	for i: int in 256:
		_uncompand8[i] = uncompand(i / 255.0)
	_tables_ready = true


static func _decode(bits: PackedInt64Array) -> PackedFloat64Array:
	return bits.to_byte_array().to_float64_array()


# --- tables -------------------------------------------------------------------------------
# The constants of spectral.js 3.0.0 as IEEE-754 binary64 bit patterns (int64), generated by node
# from docs/reference/mixlab/spectral.js (Buffer.writeDoubleLE + readBigInt64LE). The decimal
# values are in that file.

## BASE_SPECTRA W, C, M, Y, R, G, B (7 x 38), row after row.
const _BASE_SPECTRA_BITS: PackedInt64Array = [
	4607187646250547142, 4607187645910118425, 4607187644413257873, 4607187636997992906, 4607187609641947160, 4607187519240491350,
	4607187305235486697, 4607186908343435347, 4607186315546452802, 4607185554611444284, 4607184692942859341, 4607183806277457015,
	4607182957727861074, 4607181993353683245, 4607180814049469534, 4607180064404219363, 4607179802673762180, 4607180004242010349,
	4607180612283224327, 4607181521055320007, 4607182510702840793, 4607183070866914637, 4607183589641498595, 4607184021167122928,
	4607184344259106289, 4607184563564800325, 4607184703069321097, 4607184784052548121, 4607184828658474184, 4607184851738998305,
	4607184863030391856, 4607184868288448139, 4607184870929496950, 4607184872224184610, 4607184872806399612, 4607184873093140513,
	4607184873213493313, 4607184873248272001, 4606917472045855384, 4606917539571211071, 4606917835462989006, 4606919289741864014,
	4606924530734856638, 4606940694670869493, 4606972913355387594, 4607016574693921342, 4607058842419031406, 4607091888770573464,
	4607114799066909146, 4607129687776926614, 4607139039903525741, 4607144199002777888, 4607145604739935471, 4607142842588139119,
	4607133758315427206, 4607112304198401591, 4607058447787784096, 4606893678051317098, 4606203201171273288, 4603004902104265773,
	4594720350429028431, 4588441320798233384, 4584705491663045792, 4582074207261485383, 4580903672615580846, 4580355104442515623,
	4580011300913348030, 4579749318490006585, 4579624962714252395, 4579567881963675798, 4579539405377931442, 4579525490491581958,
	4579519239882650241, 4579516161571906626, 4579514868361451838, 4579514493785911125, 4607098413672460619, 4607098395366607075,
	4607098314818749936, 4607097914226187545, 4607096413385704245, 4607091185611953993, 4607076913951166748, 4607040921939890589,
	4606947645301390911, 4606658360477956406, 4605537617082213921, 4601462357372873481, 4594156350569692301, 4587904810558929490,
	4584078592327748986, 4581800463269740615, 4581460726490631863, 4582612886089931032, 4585525309243547892, 4590144447906976558,
	4596567451481822047, 4603050536409139756, 4605523668163174048, 4606397150489576276, 4606699090958287993, 4606821479576283163,
	4606878521258520470, 4606906131700387742, 4606919899804895312, 4606926659976411142, 4606929881880671188, 4606931363587620767,
	4606932103488248668, 4606932465216763761, 4606932627745552281, 4606932707796706067, 4606932741428189482, 4606932751169652792,
	4581725144472379769, 4581726333587782867, 4581731566444204602, 4581757590181307906, 4581854980309202739, 4582192522342017587,
	4583100357253121571, 4584986941600215851, 4587641403257234993, 4591924152273756505, 4597783582908238626, 4602992308548211781,
	4605361231373056631, 4606384830351853913, 4606766267846824088, 4606923386300270065, 4606995997912201648, 4607032720224832153,
	4607051465350937628, 4607060236565254488, 4607062967581336940, 4607061883400749444, 4607058820001064468, 4607055062338817030,
	4607051588579407508, 4607048904497884765, 4607047054772678009, 4607045926435436838, 4607045287360197546, 4607044951525098588,
	4607044785627678957, 4607044707941307529, 4607044668849240739, 4607044649673745926, 4607044641044094948, 4607044636790608869,
	4607044635003017929, 4607044634485173372, 4584709179061552576, 4584707953802192289, 4584702585470846550, 4584676209933818589,
	4584498107635342903, 4583914458972707559, 4582760670760976654, 4581218936469523128, 4579343204396839485, 4577087859156877443,
	4575434299483982896, 4573450000553953185, 4572210937014139686, 4571526735812822763, 4571330787919705678, 4571669115536293976,
	4572810592032419676, 4575517971665595973, 4578991746855136077, 4584728918589247858, 4592436638962576693, 4602026924985107180,
	4605804816360366802, 4606670678461851892, 4606901953986977208, 4606984536644458488, 4607020682322324049, 4607037615675557610,
	4607045919056186797, 4607049961412094211, 4607051880120322235, 4607052760811118978, 4607053200167830729, 4607053414855328433,
	4607053511293359365, 4607053558787275380, 4607053578739646434, 4607053584518805601, 4576662323823631299, 4576663524739335011,
	4576668808885483168, 4576695088627417501, 4576793546054675887, 4577136490433953229, 4578072675684499417, 4580297088329671338,
	4583354756662026815, 4588743679462993169, 4595870811438129879, 4603314545675796933, 4605934631386794912, 4606694940977706753,
	4606916395551799630, 4606987986066802943, 4606998573138956043, 4606962044491894690, 4606842746105741234, 4606489959503266322,
	4605321837849386956, 4601945095169556225, 4595854032003504832, 4591018278872892364, 4587995358302037784, 4586016054631914725,
	4585092661889050190, 4584626541166483361, 4584180450108307155, 4583961390439937635, 4583856979907812588, 4583808961603369919,
	4583784982991043088, 4583773260052089634, 4583767992782459006, 4583765398462620095, 4583764308523488047, 4583763992819173449,
	4606996913302102342, 4606996876862046657, 4606996716503519820, 4606995919019386423, 4606992934480877723, 4606982589280957961,
	4606954755724171023, 4606886968994631668, 4606723769129275647, 4606289356155306911, 4605049067668899160, 4602064927592400021,
	4596419294169275502, 4590987650457221132, 4586749432990709132, 4583863314611881842, 4581573777286422397, 4580421750009073976,
	4579520091090009655, 4578993690271572060, 4578855382933178256, 4578964027590508887, 4579200688549916280, 4579479689754062243,
	4579734496063485538, 4579930484440043685, 4580065292737322661, 4580147448673152693, 4580177390572377555, 4580189608458529131,
	4580195642400722370, 4580198467478248021, 4580199889048180319, 4580200586379792591, 4580200900208307014, 4580201054892914628,
	4580201119901637062, 4580201138733945959,
]
## CIE.CMF x, y, z (3 x 38), CIE 1931 colour matching functions weighted by D65.
const _CMF_BITS: PackedInt64Array = [
	4544401851383010097, 4552226820555015171, 4562810559965754008, 4570831641730117029, 4578002294649280561, 4582369081466138528,
	4585141358089043597, 4585525334549286866, 4584832801405878215, 4581777276248122457, 4577201266211895490, 4569746106569182148,
	4557815797219193563, 4561889198412640301, 4573883126664820232, 4580518118382300762, 4583926449738843030, 4586310909660891193,
	4588267984642873243, 4589670290347135571, 4590649030951921658, 4590870459946438079, 4591183192886633876, 4590789594663250359,
	4589773784640291160, 4587457213276185343, 4585273157724684996, 4581845011726883178, 4578368867862198331, 4574495170655157972,
	4570135167343873032, 4564549328847286760, 4560238457164116444, 4556150237956356776, 4550367407322656099, 4546654753423145658,
	4542360521356704888, 4536523046689305051, 4521316237280292885, 4528939978910039998, 4539701034692945642, 4547357490984983726,
	4555159139994349725, 4561914998028258922, 4567408963113184205, 4571500742284859921, 4574361681636627334, 4576853893989445866,
	4579944332035922316, 4581830629228627627, 4584977572901489720, 4587555373280347270, 4589737425447133899, 4590993866571747744,
	4591455780707259111, 4591722942642924165, 4591448800637129118, 4590917652442642756, 4590346632767517604, 4589242002011150677,
	4587905775419166499, 4586306766621357916, 4584717361273636569, 4581676972167152421, 4579143431297069067, 4575824475848602953,
	4571988166616385660, 4567891153694440617, 4563450334632896888, 4558135030657995428, 4553762949507595984, 4549559353757303450,
	4544131668517480083, 4540199497929138084, 4535847109813318209, 4530139048355676422, 4554262196904772028, 4562424249705994683,
	4572775651288213934, 4580832222738201768, 4588386567433560887, 4592853882882229180, 4595413926647668701, 4596237107175124294,
	4595872344253520169, 4594210267560824503, 4591090122703129218, 4587063392542866701, 4583769645603279157, 4580308585881935897,
	4575595657615441274, 4571603144000659365, 4566770811923213452, 4561084891816998741, 4555443186424105535, 4551194497556006456,
	4549649651252520200, 4546439768683211357, 4544655893986020729, 4539129266546520638, 4535274875888922254, 4526266270064190257,
	4520087114574529430, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0,
]
## CONVERSION.RGB_XYZ (3 x 3), row after row.
const _RGB_XYZ_BITS: PackedInt64Array = [
	4601100592117526702, 4600113286708316952, 4595670525981687698, 4596829147871394355, 4604616886335687448, 4589866425216086747,
	4581228950558139516, 4593253309717046302, 4606736852038626911,
]
## CONVERSION.XYZ_RGB (3 x 3), row after row.
const _XYZ_RGB_BITS: PackedInt64Array = [
	4614480434311357501, -4613769459376498552, -4620718243999835929, -4616466646751127804, 4611127425713396241, 4586149535949532530,
	4588177960434001525, -4626854972115883891, 4607438995690332369,
]
## CONVERSION.XYZ_LMS (3 x 3), row after row.
const _XYZ_LMS_BITS: PackedInt64Array = [
	4605552317838416470, 4600191143509574908, -4629560849248754401, 4584914266525689544, 4606545491472397524, 4585369816424856321,
	4587103885741322796, 4598431736144858531, 4603881711073709048,
]
## CONVERSION.LMS_XYZ (3 x 3), row after row.
const _LMS_XYZ_BITS: PackedInt64Array = [
	4608204194924334977, -4620172466507113974, 4598740710351532451, -4637363634666032350, 4607688113605429268, -4633540289881495621,
	-4633204366125223845, -4622107468077886324, 4609825689597049131,
]
## CONVERSION.LMS_LAB (3 x 3), row after row.
const _LMS_LAB_BITS: PackedInt64Array = [
	4596750434405226279, 4605323492974124226, -4652027268745312944, 4611586932626243310, -4610720914496595969, 4601788794568819767,
	4583123553312118693, 4605225800330356207, -4617912913652429140,
]
## CONVERSION.LAB_LMS (3 x 3), row after row.
const _LAB_LMS_BITS: PackedInt64Array = [
	4607182418800017408, 4600811406583922688, 4596943170058584063, 4607182418800017408, -4631101119588728830, -4634106438128500736,
	4607182418800017408, -4632259601654349821, -4614876883849314304,
]
