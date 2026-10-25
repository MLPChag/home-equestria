// Native pony navigation, ground search (docs/NAVIGATION_PHASE_1_2026_10_02.md).
// Pure C++17, no Godot types. A port of world/navigation/walk_planner.gd plan(): the same
// traversal semantics (WalkGrid.allowed/connected/has_room, diagonal side crossings, slope,
// step, headroom, water, painted and trail costs), searched as a resumable deterministic A*
// over CSR floor spans, with a connected-component/portal corridor in front of it, and the
// same certified smoothing of the cell route.
#pragma once

#include "navigation_world.h"

#include <unordered_set>

namespace ponynav {

struct Vec3f {
	float x = 0.0f;
	float y = 0.0f;
	float z = 0.0f;
	Vec3f() = default;
	Vec3f(float p_x, float p_y, float p_z) :
			x(p_x), y(p_y), z(p_z) {}
	bool finite() const { return std::isfinite(x) && std::isfinite(y) && std::isfinite(z); }
};

// The GDScript cell key Vector3i(x, slot, z); slot -1 means none.
struct CellKey {
	int32_t x = 0;
	int32_t slot = -1;
	int32_t z = 0;
	bool valid() const { return slot >= 0; }
	bool operator==(const CellKey &other) const { return x == other.x && slot == other.slot && z == other.z; }
};

enum class RouteStatus : int32_t {
	PENDING = 0,
	COMPLETE = 1,
	// A usable prefix toward the goal: never an arrival.
	PARTIAL = 2,
	// The known reachable graph ends at chunks that are not sampled yet (see `frontier`).
	WAITING_FOR_GEOMETRY = 3,
	// The expansion cap stopped the search before a conclusion.
	BUDGET_EXHAUSTED = 4,
	// The whole known reachable graph was exhausted and no frontier remains.
	UNREACHABLE = 5,
	CANCELLED = 6,
	// A chunk the route depends on was republished or removed before delivery.
	STALE = 7,
	// No safe floor with body room at the start or destination.
	NO_FLOOR = 8,
	INVALID = 9,
};

const char *status_name(RouteStatus status);

// Search node: snapshot chunk index and span index. Valid only inside its snapshot.
using Handle = uint64_t;
constexpr Handle NO_HANDLE = ~uint64_t(0);
inline Handle make_handle(uint32_t chunk, uint32_t span) { return (uint64_t(chunk) << 32) | uint64_t(span); }
inline uint32_t handle_chunk(Handle handle) { return uint32_t(handle >> 32); }
inline uint32_t handle_span(Handle handle) { return uint32_t(handle & 0xffffffffu); }

// walk_grid.gd DIRECTIONS, in the same order (it decides deterministic expansion order).
constexpr int32_t DIR_X[8] = { -1, 1, 0, 0, -1, -1, 1, 1 };
constexpr int32_t DIR_Z[8] = { 0, 0, -1, 1, -1, 1, -1, 1 };

// Body-room offsets for one radius, in WalkGrid.has_room()'s order.
struct RoomOffsets {
	double radius = 0.0;
	int32_t reach = 0;
	std::vector<int32_t> dx;
	std::vector<int32_t> dz;
	std::vector<double> length;
};
RoomOffsets make_room_offsets(double radius);

// Read access to one snapshot for one movement profile. One instance per search (not shared
// between threads); the clearance cache it fills is shared and thread safe.
class GroundAccess {
public:
	struct Column {
		int32_t chunk = -1; // -1 when the chunk is not in the snapshot
		uint32_t first = 0;
		uint32_t count = 0;
	};

	GroundAccess(std::shared_ptr<const Snapshot> snapshot, std::shared_ptr<ClearanceCache> cache,
			const GroundProfile &profile);

	const Snapshot &snapshot() const { return *snap; }
	const std::shared_ptr<const Snapshot> &snapshot_ref() const { return snap; }
	const GroundProfile &profile() const { return prof; }
	double wade_floor() const { return wade_floor_value; }
	const RoomOffsets &body_offsets() const { return body; }

	int32_t chunk_index(const ChunkKey &key);
	Column column(int32_t x, int32_t z);
	const GroundChunk &chunk(uint32_t index) const { return *snap->chunks[index]; }
	const FloorSpan &span(Handle handle) const { return snap->chunks[handle_chunk(handle)]->spans[handle_span(handle)]; }
	void cell(Handle handle, int32_t &x, int32_t &z) const;
	CellKey key(Handle handle) const;
	Handle find(const CellKey &key);
	Vec3f point(Handle handle) const;

	// WalkGrid.allowed(sample, profile).
	bool allowed(const FloorSpan &span) const;
	// walk_planner.gd _link_from(): `b` must be allowed; `a` is the caller's proven source.
	bool link_from(const FloorSpan &a, const FloorSpan &b, double distance) const;
	// walk_planner.gd _link(): both allowed.
	bool link(const FloorSpan &a, const FloorSpan &b, double distance) const;
	// WalkGrid.has_room() at the profile radius, cached per chunk neighbourhood revision.
	bool pure_room(Handle handle);
	// WalkGrid.has_room() at another radius (route smoothing clearance), memoised per search.
	bool room_radius(Handle handle, double radius);
	// The (chunk, profile) layer; created on first use from the clearance cache.
	ProfileLayer &layer(uint32_t chunk);
	bool layer_touched(uint32_t chunk) const { return chunk < layers.size() && layers[chunk] != nullptr; }
	// Flood-fill components and border portals of one chunk (idempotent, thread safe).
	void ensure_components(uint32_t chunk);

	// One walk_planner.gd neighbors() candidate: an edge from `source` (allowed, at cell sx, sz)
	// in direction `dir` to `dest`. `room` decides body room (pure or seeded).
	template <typename RoomFn>
	bool edge(const FloorSpan &source, int32_t sx, int32_t sz, int dir, Handle dest_handle, const FloorSpan &dest,
			RoomFn &&room) {
		if (!link_from(source, dest, direction_distance(dir))) {
			return false;
		}
		if (!room(dest_handle)) {
			return false;
		}
		if (DIR_X[dir] != 0 && DIR_Z[dir] != 0) {
			if (!via(source, sx + DIR_X[dir], sz, dest, room) || !via(source, sx, sz + DIR_Z[dir], dest, room)) {
				return false;
			}
		}
		return true;
	}

	static double direction_distance(int dir);

	uint64_t rooms_computed = 0;
	uint64_t components_built = 0;

private:
	template <typename RoomFn>
	bool via(const FloorSpan &source, int32_t x, int32_t z, const FloorSpan &dest, RoomFn &&room) {
		const Column side = column(x, z);
		if (side.chunk < 0) {
			return false;
		}
		const GroundChunk &owner = chunk(uint32_t(side.chunk));
		for (uint32_t i = 0; i < side.count; ++i) {
			const Handle middle_handle = make_handle(uint32_t(side.chunk), side.first + i);
			const FloorSpan &middle = owner.spans[side.first + i];
			if (room(middle_handle) && link_from(source, middle, CELL) && link_from(middle, dest, CELL)) {
				return true;
			}
		}
		return false;
	}
	bool compute_room(Handle handle, const RoomOffsets &offsets);
	void build_components(uint32_t chunk, ProfileLayer &target);

	std::shared_ptr<const Snapshot> snap;
	std::shared_ptr<ClearanceCache> cache;
	GroundProfile prof;
	double step_limit = 0.0;
	double grade_limit = 0.0;
	double wade_floor_value = 0.01;
	RoomOffsets body;
	std::vector<std::shared_ptr<ProfileLayer>> layers;
	// One-entry lookup memo. A validity flag, not a sentinel key: every 64-bit value is a
	// real chunk key (~0 is chunk (-1, -1)).
	bool cached_valid = false;
	uint64_t cached_key = 0;
	int32_t cached_index = -1;
	struct RadiusMemo {
		RoomOffsets offsets;
		std::unordered_map<Handle, bool> known;
	};
	std::vector<std::unique_ptr<RadiusMemo>> radius_memos;
};

// A disc the route must keep its cells out of (phase 2: local obstruction evidence for a replan
// or an alternate route). Cells whose centre is inside have no body room for that search.
struct SearchBlock {
	double x = 0.0;
	double z = 0.0;
	double radius = 0.0;
	bool operator==(const SearchBlock &other) const { return x == other.x && z == other.z && radius == other.radius; }
};

struct SearchOptions {
	bool any_floor = false;
	bool relaxed = false;
	bool use_corridor = true;
	bool allow_partial = false;
	bool smooth = true;
	int64_t expansion_limit = 100000;
	// > 0: every cell with body room within this XZ radius of the destination is a goal.
	// 0: walk_planner.gd's endpoint policy (nearest room cell within 1 m, else 3 m reach).
	double goal_radius = 0.0;
	// Zero heuristic (Dijkstra): a slower reference for correctness tests.
	bool dijkstra = false;
	// Phase 2 (follower backend only; 0 keeps walk_planner.gd's behaviour). A start with no body
	// room within a metre seeds every allowed cell connected to her own cell within this many
	// metres (capsule-sized floor, not full body room), so she can leave a deep nook along it.
	// The seeded prefix of the route is not smoothed.
	double escape_reach = 0.0;
	// Phase 2: discs the search keeps out of (obstruction evidence). Disables the coarse corridor.
	std::vector<SearchBlock> blocked;
};

struct SearchOutput {
	RouteStatus status = RouteStatus::PENDING;
	// For PARTIAL: what stopped the search (BUDGET_EXHAUSTED or WAITING_FOR_GEOMETRY).
	RouteStatus limited_by = RouteStatus::PENDING;
	std::string reason;
	std::vector<Vec3f> path;
	std::vector<Vec3f> partial_path;
	std::vector<CellKey> raw_cells;
	double raw_cost = 0.0;
	int64_t expanded = 0;
	int64_t coarse_expanded = 0;
	bool corridor_used = false;
	bool corridor_widened = false;
	// The component graph proved the outcome without a cell search.
	bool coarse_certified = false;
	std::vector<ChunkKey> frontier;
	std::vector<std::pair<ChunkKey, uint64_t>> dependencies;
	CellKey start;
	CellKey goal;
	bool start_cramped = false;
	int64_t goal_count = 0;
	int32_t smoothing_checks = 0;
	uint64_t rooms_computed = 0;
	uint64_t components_built = 0;
	double cpu_us = 0.0;
	int32_t slices = 0;
};

class GroundSearch {
public:
	GroundSearch(std::shared_ptr<const Snapshot> snapshot, std::shared_ptr<ClearanceCache> cache,
			const GroundProfile &profile, const Vec3f &from, const Vec3f &to, const SearchOptions &options);
	~GroundSearch();
	GroundSearch(const GroundSearch &) = delete;
	GroundSearch &operator=(const GroundSearch &) = delete;

	// Runs at most `expansion_budget` cell expansions and roughly `time_budget_us` (<= 0: no
	// limit) and returns PENDING when work remains; the state is kept for the next slice.
	RouteStatus advance(int64_t expansion_budget, int64_t time_budget_us, const std::atomic<bool> *cancel);
	RouteStatus run_to_completion(const std::atomic<bool> *cancel = nullptr);
	bool finished() const;
	// Ends the search as CANCELLED without more work (the scheduler's atomic cancel).
	void cancel();
	const SearchOutput &output() const;
	GroundAccess &access();

private:
	struct Impl;
	std::unique_ptr<Impl> impl;
};

// Read-only cell report for tests and the shadow lab (walk_grid.gd sample/allowed/has_room).
struct CellReport {
	bool present = false;
	FloorSpan span;
	double paint = 0.0;
	double trail = 0.0;
	bool allowed = false;
	bool room = false;
	uint32_t component = NO_COMPONENT;
};
CellReport report_cell(GroundAccess &ground, const CellKey &key, bool with_component);

} // namespace ponynav
