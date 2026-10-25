// Native pony navigation, wander sampling: see navigation_wander.h (dev 2026-10-20 multithreading).
// Each step names the walk_planner.gd line it ports. GDScript evaluates `pos.x - from.x` in double
// and Vector2()/Vector3 math in single precision; both are reproduced literally.
#include "navigation_wander.h"

#include <chrono>
#include <cmath>
#include <unordered_set>

namespace ponynav {

namespace {

inline uint32_t clz32(uint32_t value) {
#if defined(__GNUC__) || defined(__clang__)
	return uint32_t(__builtin_clz(value));
#else
	uint32_t count = 0;
	for (uint32_t bit = 0x80000000u; bit != 0 && !(value & bit); bit >>= 1) {
		++count;
	}
	return count;
#endif
}

// GDScript `float(a) - float(b)` (double) handed to a Vector2 constructor (single).
inline float sub_f(float a, float b) {
	return float(double(a) - double(b));
}

// Godot Vector2::length() / length_squared() with single-precision real_t.
inline float length2(float x, float y) {
	return std::sqrt(x * x + y * y);
}

inline float length_squared2(float x, float y) {
	return x * x + y * y;
}

// Godot Vector2::normalize().
inline void normalize2(float &x, float &y) {
	float l = x * x + y * y;
	if (l != 0) {
		l = std::sqrt(l);
		x /= l;
		y /= l;
	}
}

// Godot Vector3::distance_to(): (to - from).length(), x2 + y2 + z2 in that order.
inline float distance3(const Vec3f &from, const Vec3f &to) {
	const float x = to.x - from.x;
	const float y = to.y - from.y;
	const float z = to.z - from.z;
	const float x2 = x * x;
	const float y2 = y * y;
	const float z2 = z * z;
	return std::sqrt(x2 + y2 + z2);
}

// Godot Vector3::distance_squared_to().
inline float distance_squared3(const Vec3f &from, const Vec3f &to) {
	const float x = to.x - from.x;
	const float y = to.y - from.y;
	const float z = to.z - from.z;
	const float x2 = x * x;
	const float y2 = y * y;
	const float z2 = z * z;
	return x2 + y2 + z2;
}

// GDScript lerpf / clampf / maxf (Godot Math::lerp, CLAMP, MAX).
inline double lerp_d(double from, double to, double weight) {
	return from + (to - from) * weight;
}

inline double clamp_d(double value, double low, double high) {
	return value < low ? low : (value > high ? high : value);
}

inline double max_d(double a, double b) {
	return a < b ? b : a;
}

// walk_planner.gd neighbors() for a wander: no corridor, frontier marks are not needed, and the
// room check is plain body room (wander never seeds a cramped start).
void neighbors(GroundAccess &ground, Handle key, std::vector<Handle> &out) {
	out.clear();
	const FloorSpan &source = ground.span(key);
	const bool source_ok = ground.allowed(source);
	int32_t sx = 0;
	int32_t sz = 0;
	ground.cell(key, sx, sz);
	auto room = [&ground](Handle handle) { return ground.pure_room(handle); };
	for (int dir = 0; dir < 8; ++dir) {
		const GroundAccess::Column column = ground.column(sx + DIR_X[dir], sz + DIR_Z[dir]);
		if (column.chunk < 0) {
			continue;
		}
		if (!source_ok) {
			continue;
		}
		for (uint32_t i = 0; i < column.count; ++i) {
			const Handle other = make_handle(uint32_t(column.chunk), column.first + i);
			const FloorSpan &dest = ground.span(other);
			if (ground.edge(source, sx, sz, dir, other, dest, room)) {
				out.push_back(other);
			}
		}
	}
}

// walk_planner.gd _nearest(pos, 1.0): the closest allowed cell with body room within a metre.
Handle nearest(GroundAccess &ground, const Vec3f &position, double radius) {
	const int32_t cx = cell_coord(double(position.x));
	const int32_t cz = cell_coord(double(position.z));
	Handle best = NO_HANDLE;
	double best_d = radius * radius;
	const int32_t r = int32_t(std::ceil(radius / CELL));
	for (int32_t z = -r; z <= r; ++z) {
		for (int32_t x = -r; x <= r; ++x) {
			const GroundAccess::Column column = ground.column(cx + x, cz + z);
			if (column.chunk < 0) {
				continue;
			}
			for (uint32_t i = 0; i < column.count; ++i) {
				const Handle handle = make_handle(uint32_t(column.chunk), column.first + i);
				if (!ground.allowed(ground.span(handle))) {
					continue;
				}
				const float d = distance_squared3(ground.point(handle), position);
				if (double(d) <= best_d && ground.pure_room(handle)) {
					best_d = double(d);
					best = handle;
				}
			}
		}
	}
	return best;
}

bool finite3(const Vec3f &v) {
	return v.finite();
}

// walk_planner.gd _wander_weight().
double wander_weight(const Vec3f &pos, const WanderParams &params) {
	const Vec3f &from = params.from;
	const float distance = length2(sub_f(pos.x, from.x), sub_f(pos.z, from.z));
	const double radial = clamp_d(double(distance) / max_d(params.radius, CELL), 0.0, 1.0);
	double weight = .35 + 1.65 * radial * radial;
	if (finite3(params.interest)) {
		const double progress = (double(distance3(from, params.interest)) - double(distance3(pos, params.interest))) /
				max_d(params.radius, 1.0);
		weight *= std::exp(clamp_d(progress * 2.0, -1.2, 1.6));
	}
	for (const Vec3f &recent : params.recent) {
		const float separation = length2(sub_f(pos.x, recent.x), sub_f(pos.z, recent.z));
		if (double(separation) < 4.0) {
			weight *= lerp_d(.12, 1.0, double(separation) / 4.0);
		}
	}
	float hx = params.heading.x;
	float hz = params.heading.z;
	float tx = sub_f(pos.x, from.x);
	float tz = sub_f(pos.z, from.z);
	if (double(length_squared2(hx, hz)) > .01 && double(length_squared2(tx, tz)) > .01) {
		// A mild forward preference avoids repetitive reversals without forcing a line.
		normalize2(hx, hz);
		normalize2(tx, tz);
		const float dot = hx * tx + hz * tz;
		weight *= lerp_d(.78, 1.18, (double(dot) + 1.0) * .5);
	}
	return max_d(weight, .001);
}

} // namespace

void GodotPcg::seed(uint64_t seed_value) {
	// pcg32_srandom_r(&pcg, seed, DEFAULT_INC).
	state = 0;
	inc = (DEFAULT_INC << 1u) | 1u;
	rand();
	state += seed_value;
	rand();
}

uint32_t GodotPcg::rand() {
	// pcg32_random_r().
	const uint64_t old = state;
	state = old * 6364136223846793005ull + (inc | 1);
	const uint32_t xorshifted = uint32_t(((old >> 18u) ^ old) >> 27u);
	const uint32_t rot = uint32_t(old >> 59u);
	return (xorshifted >> rot) | (xorshifted << ((0u - rot) & 31u));
}

float GodotPcg::randf() {
	// RandomPCG::randf() (CLZ32 branch).
	const uint32_t proto_exp_offset = rand();
	if (proto_exp_offset == 0) {
		return 0;
	}
	return std::ldexp(float(rand() | 0x80000001u), -32 - int(clz32(proto_exp_offset)));
}

WanderOutput wander(GroundAccess &ground, const WanderParams &params, const std::atomic<bool> *cancel) {
	const auto started = std::chrono::steady_clock::now();
	const uint64_t rooms_before = ground.rooms_computed;
	WanderOutput out;
	auto finish = [&]() {
		out.rooms_computed = ground.rooms_computed - rooms_before;
		out.cpu_us = double(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count()) / 1000.0;
		out.found = out.destination.finite();
		return out;
	};
	// var start := _nearest(from); if start.y < 0: return Vector3.INF
	const Handle start = nearest(ground, params.from, 1.0);
	if (start == NO_HANDLE) {
		out.no_floor = true;
		return finish();
	}
	int32_t start_x = 0;
	int32_t start_z = 0;
	ground.cell(start, start_x, start_z);
	GodotPcg random(params.seed);
	std::vector<Handle> queue;
	queue.reserve(size_t(WANDER_LIMIT) + 64);
	queue.push_back(start);
	std::unordered_set<Handle> seen;
	seen.reserve(size_t(WANDER_LIMIT) * 2);
	seen.insert(start);
	const Vec3f none{ float(INF), float(INF), float(INF) };
	Vec3f chosen = none;
	double total = 0.0;
	Vec3f road_chosen = none;
	double road_total = 0.0;
	const bool has_home = finite3(params.home);
	std::vector<Handle> next_cells;
	size_t index = 0;
	while (index < queue.size() && int64_t(index) < WANDER_LIMIT) {
		if (index % 128 == 0 && cancel != nullptr && cancel->load(std::memory_order_relaxed)) {
			out.cancelled = true;
			out.destination = none;
			return finish();
		}
		const Handle key = queue[index];
		++index;
		const Vec3f pos = ground.point(key);
		const float distance = length2(sub_f(pos.x, params.from.x), sub_f(pos.z, params.from.z));
		if (double(distance) >= 3.0 &&
				(!has_home || double(length2(sub_f(pos.x, params.home.x), sub_f(pos.z, params.home.z))) <= params.leash)) {
			double weight = wander_weight(pos, params);
			const double trail = span_trail(ground.span(key));
			weight *= lerp_d(1.0, 14.0, trail);
			total += weight;
			const double roll = double(random.randf());
			++out.candidates;
			if (roll * total < weight) {
				chosen = pos;
			}
			if (trail > .5) {
				road_total += weight;
				if (roll * road_total < weight) {
					road_chosen = pos;
				}
			}
		}
		neighbors(ground, key, next_cells);
		for (const Handle next : next_cells) {
			if (!seen.insert(next).second) {
				continue;
			}
			int32_t nx = 0;
			int32_t nz = 0;
			ground.cell(next, nx, nz);
			if (double(length2(float(nx - start_x), float(nz - start_z))) * CELL <= params.radius) {
				queue.push_back(next);
			}
		}
	}
	out.visited = int64_t(index);
	// Once on a street, an unassigned stroll continues along it.
	if (!finite3(params.interest) && road_chosen.finite() && span_trail(ground.span(start)) > .5) {
		out.destination = road_chosen;
	} else {
		out.destination = chosen;
	}
	return finish();
}

} // namespace ponynav
