extends RefCounted
## How chatty the town is (dev 2026-10-14): a time-of-day curve times the player's AI setting
## "chattiness" (0..1, default 1). Lowering the setting quiets the day by that factor and the
## night by its square, so night is always relatively quieter still.

## [hour, day weight] points; linear between them, wrapping at midnight.
const CURVE := [[0.0, 0.03], [5.0, 0.03], [6.5, 0.35], [9.0, 0.85], [11.0, 1.0], [18.0, 1.0], [20.0, 0.55], [22.0, 0.22], [23.5, 0.05], [24.0, 0.03]]

static func day_weight(hours: float) -> float:
	var h := fposmod(hours, 24.0)
	for i in CURVE.size() - 1:
		var a: Array = CURVE[i]
		var b: Array = CURVE[i + 1]
		if h >= float(a[0]) and h <= float(b[0]):
			var t := (h - float(a[0])) / maxf(0.001, float(b[0]) - float(a[0]))
			return lerpf(float(a[1]), float(b[1]), t)
	return 1.0

## Multiplier on ambient chatter chances. Night share = 1 - day weight; it scales with
## setting^2, the day share with setting.
static func factor(hours: float, setting: float) -> float:
	var s := clampf(setting, 0.0, 1.0)
	var day := day_weight(hours)
	var nightness := clampf((1.0 - day) / 0.97, 0.0, 1.0)
	return day * lerpf(s, s * s, nightness)
