// Native pony navigation, wander sampling (dev 2026-10-20 multithreading).
// Pure C++17, no Godot types. A port of world/navigation/walk_planner.gd wander() and
// _wander_weight(): breadth-first walk of the body-room component from her feet (the same
// neighbors(), _via() and has_room() rules as the route search, through GroundAccess), with a
// weighted reservoir pick of the destination. Positions are single precision like Godot's
// Vector3/Vector2 and are combined in the same order; weights are doubles like GDScript floats,
// so the same snapshot, inputs and random stream give the same destination bit for bit.
//
// Threads: one wander runs on one thread. It reads an immutable Snapshot and the thread-safe
// ClearanceCache (navigation_world.h); everything else it touches is its own.
#pragma once

#include "navigation_ground.h"

#include <atomic>
#include <cstdint>
#include <vector>

namespace ponynav {

// Godot's RandomPCG (core/math/random_pcg.h, thirdparty/misc/pcg.cpp) with the default stream.
// `seed(s)` matches RandomNumberGenerator.seed = s, `randf()` matches RandomNumberGenerator.randf()
// (and the global randf(), which is the same generator), including the clz exponent trick.
class GodotPcg {
public:
	static constexpr uint64_t DEFAULT_INC = 1442695040888963407ull;
	explicit GodotPcg(uint64_t seed_value = 12047754176567800795ull) { seed(seed_value); }
	void seed(uint64_t seed_value);
	uint32_t rand();
	float randf();

private:
	uint64_t state = 0;
	uint64_t inc = 0;
};

struct WanderParams {
	Vec3f from;
	double radius = 0.0;
	// Vector3.INF (any component not finite) means "none", exactly like the GDScript checks.
	Vec3f interest = Vec3f(float(INF), float(INF), float(INF));
	Vec3f home = Vec3f(float(INF), float(INF), float(INF));
	double leash = INF;
	// context.recent and context.heading.
	std::vector<Vec3f> recent;
	Vec3f heading;
	// Seed of this search's own random stream (drawn on the main thread; never the global RNG,
	// which concurrent searches would race on).
	uint64_t seed = 0;
};

struct WanderOutput {
	bool found = false;
	// Vector3.INF when nothing was chosen (no floor, cancelled, or no cell 3 m away).
	Vec3f destination = Vec3f(float(INF), float(INF), float(INF));
	bool cancelled = false;
	bool no_floor = false;
	int64_t visited = 0;
	int64_t candidates = 0;
	double cpu_us = 0.0;
	uint64_t rooms_computed = 0;
};

constexpr int64_t WANDER_LIMIT = 6000;

// walk_planner.gd wander(snapshot, from, settings, radius, interest, home, leash, context).
// `cancel` (may be null) is polled every 128 cells like WalkPlanner._cancelled().
WanderOutput wander(GroundAccess &ground, const WanderParams &params, const std::atomic<bool> *cancel);

} // namespace ponynav
