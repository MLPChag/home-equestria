// Deterministic resumable 3D A* over AirSpace face neighbours (navigation overhaul phase 4).
// Plain C++17, no Godot types: phase 5 binds it.
//
// Graph: one node per leaf cell. The start node sits at the start point; every other node at its
// cell centre. Edge A -> B costs |pA - f| + |f - pB| where f is the centre of the shared face
// rectangle, so a face edge never leaves the FREE cells it crosses. The goal is a virtual node:
// a cell whose interior meets a goal region gets an edge to the closest point of that region
// inside the cell. Heuristic: 3D distance from the node point to the nearest goal region, times
// heuristic_weight. With weight 1 and any_angle off it is consistent, expanded nodes are final and
// the route is optimal on the face graph (tests compare it with Dijkstra).
//
// any_angle (default): Lazy Theta*. A neighbour is first offered the straight segment from the
// expanding cell's parent; when that node is expanded the segment is certified with the same
// supercover test as shortening (every touched fine voxel FREE, UNKNOWN fails). If it does not
// certify, the node takes its best expanded face neighbour instead. Face-only search pays a
// Manhattan-like cost on diagonals, which makes A* flood everything below that cost; any-angle
// costs are close to straight-line distance, so the Euclidean heuristic is tight again.
// The route's straight segments are therefore all certified; neighbours stay face neighbours,
// so connectivity, UNKNOWN handling and exhaustiveness are unchanged.
//
// Statuses: COMPLETE (route ends inside a goal region), PENDING (slice budget spent, call
// advance() again), WAITING_FOR_GEOMETRY (no route in known space and the frontier reaches
// UNKNOWN; frontier_tiles() lists missing tiles), BUDGET_EXHAUSTED (the total expansion cap
// stopped it), UNREACHABLE (all known reachable FREE space exhausted without touching UNKNOWN,
// or the goal's own known component is sealed), CANCELLED, START_BLOCKED / GOAL_BLOCKED (endpoint
// in SOLID), INVALID (bad input). A partial route is a prefix and never arrives.
#pragma once

#include "air_space.h"

#include <atomic>
#include <cstddef>

namespace nav_air {

enum class AirStatus : uint8_t {
	PENDING = 0,
	COMPLETE = 1,
	WAITING_FOR_GEOMETRY = 2,
	BUDGET_EXHAUSTED = 3,
	UNREACHABLE = 4,
	CANCELLED = 5,
	START_BLOCKED = 6,
	GOAL_BLOCKED = 7,
	INVALID = 8,
};

const char *air_status_name(AirStatus status);

enum class AirGoalKind : uint8_t {
	POINT = 0, // arrive exactly at a 3D point (same X/Z at another height is a different goal)
	REGION = 1, // hover: arrive anywhere inside a box
	LANDING = 2, // reach one of several approach volumes; the route reports which footprint id
};

struct AirGoalRegion {
	Aabb box;
	uint32_t id = 0; // footprint id for LANDING, 0 otherwise
};

struct AirGoal {
	AirGoalKind kind = AirGoalKind::POINT;
	std::vector<AirGoalRegion> regions;

	static AirGoal point(const Vec3 &p);
	static AirGoal hover(const Vec3 &centre, float half_extent);
	static AirGoal region(const Aabb &box);
	static AirGoal landing(const std::vector<AirGoalRegion> &approach_volumes);
};

struct AirSearchLimits {
	uint32_t slice_expansions = 4096; // per advance()
	double slice_seconds = 0.002; // per advance(); <= 0 means no time limit
	uint32_t total_expansions = 250000; // BUDGET_EXHAUSTED beyond this
	uint32_t seal_probe_cells = 4096; // goal-side flood proving a sealed goal; 0 = off
	uint32_t max_frontier_tiles = 64;
	bool any_angle = true; // Lazy Theta* (see above); false = plain face-graph A*
	// > 1 trades optimality for fewer expansions (cost bounded by weight x optimum on the face graph).
	// 1.25 measured on the 200 m course: routes within 0.1 % (median) of weight 1, ~6x fewer expansions.
	float heuristic_weight = 1.25f;
	// Coarse-first: search coarse leaves only (plus fine cells within endpoint_fine_radius of the
	// start or a goal region) before the full search. A route it finds is a route of the full
	// graph; when it finds none (or spends coarse_share of the budget) the full search runs with
	// the remaining budget and alone decides UNREACHABLE / WAITING_FOR_GEOMETRY.
	bool coarse_first = true;
	float endpoint_fine_radius = 8.0f;
	float coarse_share = 0.25f;
};

struct AirTileKey {
	int32_t x, y, z;
};

struct AirRoute {
	std::vector<Vec3> points; // start, cell centres (with the face centre before a face edge), arrival
	std::vector<CellId> cells; // cells of the route's cell points, start cell first
	float cost = 0.0f;
	uint32_t goal_id = 0;
	bool arrives = false; // false for a partial prefix
};

struct AirSearchStats {
	uint32_t expansions = 0;
	uint32_t slices = 0;
	uint32_t seal_probe_cells = 0;
	uint32_t nodes = 0;
	uint32_t heap_pushes = 0;
	uint32_t los_checks = 0; // any-angle segment certifications
	uint32_t los_failures = 0;
	uint32_t coarse_expansions = 0; // spent in the coarse-first pass
	bool used_full_search = false;
	bool touched_unknown = false;
	double seconds = 0.0; // CPU time spent inside begin()/advance()
};

class AirSearch {
public:
	AirSearch();
	~AirSearch();
	AirSearch(const AirSearch &) = delete;
	AirSearch &operator=(const AirSearch &) = delete;

	// Starts a job, reusing this object's scratch (stamped, never cleared per job). The space must
	// stay alive and unchanged until the job ends. Returns PENDING or an immediate verdict.
	AirStatus begin(const AirSpace &space, const Vec3 &start, const AirGoal &goal, const AirSearchLimits &limits);
	AirStatus advance(); // one slice (expansion and time budget)
	AirStatus run_to_end(); // advance() until not PENDING
	void cancel(); // any thread; the job answers CANCELLED at its next check
	AirStatus status() const { return status_; }

	const AirRoute &route() const { return route_; } // COMPLETE only
	// Best prefix toward the goal (closest expanded cell). Never arrives. False if none.
	bool partial_route(AirRoute &out) const;
	const std::vector<AirTileKey> &frontier_tiles() const { return frontier_; }
	const AirSearchStats &stats() const { return stats_; }

private:
	struct Impl;
	Impl *impl_;
	AirStatus status_ = AirStatus::INVALID;
	AirRoute route_;
	std::vector<AirTileKey> frontier_;
	AirSearchStats stats_;
	std::atomic<bool> cancelled_{false};
};

// Point helpers shared with shortening and tests.
float air_distance(const Vec3 &a, const Vec3 &b);
float air_distance_to_box(const Vec3 &p, const Aabb &box);
Vec3 air_centre(const Aabb &box);
// True when every cell whose closed box contains p is FREE; `unknown` reports UNKNOWN among them.
bool air_point_clear(const AirSpace &space, const Vec3 &p, bool *unknown = nullptr);

} // namespace nav_air
