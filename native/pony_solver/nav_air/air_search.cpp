// See air_search.h.
#include "air_search.h"
#include "air_shorten.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>

namespace nav_air {

namespace {

using Clock = std::chrono::steady_clock;

constexpr float INF = std::numeric_limits<float>::infinity();
constexpr float INTERIOR_EPS = 1.0e-3f; // a goal region must reach this far inside a cell
constexpr uint32_t SEAL_PROBE_EARLY_CELLS = 256;

struct Key {
	uint64_t a, b;
};

inline bool key_eq(const Key &l, const Key &r) {
	return l.a == r.a && l.b == r.b;
}

inline bool key_less(const Key &l, const Key &r) {
	return l.a != r.a ? l.a < r.a : l.b < r.b;
}

inline Key key_of(const CellId &c) {
	const uint64_t mask = 0x1FFFFFull;
	Key k;
	k.a = ((uint64_t(uint32_t(c.tx)) & mask) << 42) | ((uint64_t(uint32_t(c.ty)) & mask) << 21) |
			(uint64_t(uint32_t(c.tz)) & mask);
	k.b = uint64_t(c.level & 1) | (uint64_t(c.coarse) << 1) | (c.level ? uint64_t(c.fine) << 10 : 0);
	return k;
}

const Key GOAL_KEY = {~0ull, ~0ull};

inline uint64_t mix(uint64_t h) {
	h ^= h >> 33;
	h *= 0xFF51AFD7ED558CCDull;
	h ^= h >> 33;
	h *= 0xC4CEB9FE1A85EC53ull;
	h ^= h >> 33;
	return h;
}

inline uint64_t hash_key(const Key &k) {
	return mix(k.a ^ mix(k.b + 0x9E3779B97F4A7C15ull));
}

inline float get(const Vec3 &v, int axis) {
	return axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
}

inline void set(Vec3 &v, int axis, float value) {
	(axis == 0 ? v.x : (axis == 1 ? v.y : v.z)) = value;
}

float box_distance(const Aabb &a, const Aabb &b) {
	const float dx = std::max(std::max(a.min.x - b.max.x, b.min.x - a.max.x), 0.0f);
	const float dy = std::max(std::max(a.min.y - b.max.y, b.min.y - a.max.y), 0.0f);
	const float dz = std::max(std::max(a.min.z - b.max.z, b.min.z - a.max.z), 0.0f);
	return std::sqrt(dx * dx + dy * dy + dz * dz);
}

inline bool finite(const Vec3 &v) {
	return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

AirTileKey tile_of(const Vec3 &p) {
	return AirTileKey{int32_t(std::floor(double(p.x) / AIR_TILE_SIZE)), int32_t(std::floor(double(p.y) / AIR_TILE_SIZE)),
		int32_t(std::floor(double(p.z) / AIR_TILE_SIZE))};
}

// Stamped open-addressing map CellKey -> node index. Starting a job bumps the stamp instead of
// clearing the table.
class StampedMap {
public:
	void reset() {
		++stamp_;
		used_ = 0;
		if (stamp_ == 0) {
			for (Slot &s : slots_) {
				s.stamp = 0;
			}
			stamp_ = 1;
		}
		if (slots_.empty()) {
			slots_.resize(1024);
		}
	}

	// Returns the stored value or -1; `inserted` set when a new slot was claimed with `value`.
	int32_t find_or_insert(const Key &key, int32_t value, bool &inserted) {
		if ((used_ + 1) * 2 > slots_.size()) {
			grow();
		}
		const size_t mask = slots_.size() - 1;
		size_t i = size_t(hash_key(key)) & mask;
		while (true) {
			Slot &s = slots_[i];
			if (s.stamp != stamp_) {
				s.stamp = stamp_;
				s.key = key;
				s.value = value;
				++used_;
				inserted = true;
				return value;
			}
			if (key_eq(s.key, key)) {
				inserted = false;
				return s.value;
			}
			i = (i + 1) & mask;
		}
	}

	int32_t find(const Key &key) const {
		if (slots_.empty()) {
			return -1;
		}
		const size_t mask = slots_.size() - 1;
		size_t i = size_t(hash_key(key)) & mask;
		while (true) {
			const Slot &s = slots_[i];
			if (s.stamp != stamp_) {
				return -1;
			}
			if (key_eq(s.key, key)) {
				return s.value;
			}
			i = (i + 1) & mask;
		}
	}

	size_t bytes() const { return slots_.capacity() * sizeof(Slot); }

private:
	struct Slot {
		Key key;
		int32_t value;
		uint32_t stamp = 0;
	};

	void grow() {
		std::vector<Slot> old;
		old.swap(slots_);
		slots_.assign(old.size() * 2, Slot());
		const uint32_t old_stamp = stamp_;
		stamp_ = 1;
		used_ = 0;
		const size_t mask = slots_.size() - 1;
		for (const Slot &s : old) {
			if (s.stamp != old_stamp) {
				continue;
			}
			size_t i = size_t(hash_key(s.key)) & mask;
			while (slots_[i].stamp == stamp_) {
				i = (i + 1) & mask;
			}
			slots_[i] = s;
			slots_[i].stamp = stamp_;
			++used_;
		}
	}

	std::vector<Slot> slots_;
	uint32_t stamp_ = 0;
	size_t used_ = 0;
};

struct Node {
	CellId cell;
	Key key;
	Vec3 p; // start point, cell centre, or (goal node) arrival point
	Vec3 via; // face centre where the route entered this cell (when has_via)
	float g;
	float h;
	int32_t parent;
	uint32_t goal_id;
	uint8_t closed;
	uint8_t has_via; // 1: parent -> via -> p (face edge); 0: straight parent -> p
	uint8_t verified; // straight segment certified (or needs no check)
};

struct HeapEntry {
	float f;
	float g;
	Key key;
	int32_t node;
};

// std heap keeps the "largest" on top: order so the smallest f, then the largest g (deepest), then
// the smallest key is on top. Total and deterministic.
struct HeapAfter {
	bool operator()(const HeapEntry &l, const HeapEntry &r) const {
		if (l.f != r.f) {
			return l.f > r.f;
		}
		if (l.g != r.g) {
			return l.g < r.g;
		}
		return key_less(r.key, l.key);
	}
};

bool same_cell(const CellId &a, const CellId &b) {
	return key_eq(key_of(a), key_of(b));
}

} // namespace

const char *air_status_name(AirStatus status) {
	switch (status) {
		case AirStatus::PENDING:
			return "PENDING";
		case AirStatus::COMPLETE:
			return "COMPLETE";
		case AirStatus::WAITING_FOR_GEOMETRY:
			return "WAITING_FOR_GEOMETRY";
		case AirStatus::BUDGET_EXHAUSTED:
			return "BUDGET_EXHAUSTED";
		case AirStatus::UNREACHABLE:
			return "UNREACHABLE";
		case AirStatus::CANCELLED:
			return "CANCELLED";
		case AirStatus::START_BLOCKED:
			return "START_BLOCKED";
		case AirStatus::GOAL_BLOCKED:
			return "GOAL_BLOCKED";
		case AirStatus::INVALID:
			return "INVALID";
	}
	return "?";
}

AirGoal AirGoal::point(const Vec3 &p) {
	AirGoal goal;
	goal.kind = AirGoalKind::POINT;
	goal.regions.push_back(AirGoalRegion{Aabb{p, p}, 0});
	return goal;
}

AirGoal AirGoal::hover(const Vec3 &centre, float half_extent) {
	const float e = std::max(0.0f, half_extent);
	AirGoal goal;
	goal.kind = AirGoalKind::REGION;
	goal.regions.push_back(AirGoalRegion{
			Aabb{Vec3{centre.x - e, centre.y - e, centre.z - e}, Vec3{centre.x + e, centre.y + e, centre.z + e}}, 0});
	return goal;
}

AirGoal AirGoal::region(const Aabb &box) {
	AirGoal goal;
	goal.kind = AirGoalKind::REGION;
	goal.regions.push_back(AirGoalRegion{box, 0});
	return goal;
}

AirGoal AirGoal::landing(const std::vector<AirGoalRegion> &approach_volumes) {
	AirGoal goal;
	goal.kind = AirGoalKind::LANDING;
	goal.regions = approach_volumes;
	return goal;
}

float air_distance(const Vec3 &a, const Vec3 &b) {
	const float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
	return std::sqrt(dx * dx + dy * dy + dz * dz);
}

float air_distance_to_box(const Vec3 &p, const Aabb &box) {
	const float dx = std::max(std::max(box.min.x - p.x, 0.0f), p.x - box.max.x);
	const float dy = std::max(std::max(box.min.y - p.y, 0.0f), p.y - box.max.y);
	const float dz = std::max(std::max(box.min.z - p.z, 0.0f), p.z - box.max.z);
	return std::sqrt(dx * dx + dy * dy + dz * dz);
}

Vec3 air_centre(const Aabb &box) {
	return Vec3{0.5f * (box.min.x + box.max.x), 0.5f * (box.min.y + box.max.y), 0.5f * (box.min.z + box.max.z)};
}

bool air_point_clear(const AirSpace &space, const Vec3 &p, bool *unknown) {
	// The cells whose closed boxes contain p: on each axis the cell below a grid plane joins in
	// when p lies on that plane.
	const float eps = 1.0e-4f;
	bool clear = true;
	bool saw_unknown = false;
	for (int corner = 0; corner < 8; ++corner) {
		Vec3 q = p;
		bool skip = false;
		for (int axis = 0; axis < 3 && !skip; ++axis) {
			if ((corner >> axis) & 1) {
				const float v = get(p, axis);
				const float grid = AIR_FINE_SIZE * std::round(v / AIR_FINE_SIZE);
				if (std::fabs(v - grid) > eps) {
					skip = true; // not on a plane along this axis: same cell as corner 0
				} else {
					set(q, axis, grid - eps * 4.0f);
				}
			}
		}
		if (skip) {
			continue;
		}
		const Cell c = space.sample(q);
		if (c != Cell::FREE) {
			clear = false;
			saw_unknown = saw_unknown || c == Cell::UNKNOWN;
		}
	}
	if (unknown != nullptr) {
		*unknown = saw_unknown;
	}
	return clear;
}

struct AirSearch::Impl {
	const AirSpace *space = nullptr;
	AirGoal goal;
	AirSearchLimits limits;
	Vec3 start{0, 0, 0};
	CellId start_cell{};
	Key start_key{0, 0};
	CellId goal_cell{};
	bool has_goal_cell = false;

	std::vector<Node> nodes;
	std::vector<HeapEntry> heap;
	StampedMap map;
	std::vector<Face> faces;
	int32_t goal_node = -1;
	int32_t best_partial = -1;
	// Best goal link that needs no certification: from a goal cell's own point to its arrival point.
	float goal_safe_g = INF;
	int32_t goal_safe_parent = -1;
	Vec3 goal_safe_q{0, 0, 0};
	uint32_t goal_safe_id = 0;
	bool coarse_phase = false;
	uint32_t coarse_cap = 0;

	// Coarse-first pass: coarse leaves, plus fine cells near the endpoints.
	bool allowed(const CellId &c) const {
		if (!coarse_phase || c.level == 0) {
			return true;
		}
		const Aabb b = space->bounds(c);
		const float r = limits.endpoint_fine_radius;
		if (air_distance_to_box(start, b) <= r) {
			return true;
		}
		for (const AirGoalRegion &g : goal.regions) {
			if (box_distance(b, g.box) <= r) {
				return true;
			}
		}
		return false;
	}

	// Clears the search state and seeds the start node (begin, and the switch to the full search).
	void seed() {
		nodes.clear();
		heap.clear();
		map.reset();
		goal_node = -1;
		best_partial = -1;
		goal_safe_g = INF;
		goal_safe_parent = -1;
		Node s;
		s.cell = start_cell;
		s.key = start_key;
		s.p = start;
		s.via = start;
		s.g = 0.0f;
		s.h = heuristic(start);
		s.parent = -1;
		s.goal_id = 0;
		s.closed = 0;
		s.has_via = 0;
		s.verified = 1;
		bool inserted;
		map.find_or_insert(s.key, 0, inserted);
		nodes.push_back(s);
		push(0);
	}

	StampedMap seal_map;
	std::vector<CellId> seal_queue;
	std::vector<Face> seal_faces;

	float heuristic(const Vec3 &p) const {
		float best = INF;
		for (const AirGoalRegion &r : goal.regions) {
			best = std::min(best, air_distance_to_box(p, r.box));
		}
		return best;
	}

	// Closest point of goal ∩ cell to p; false when this cell is not a goal cell.
	bool goal_point(const CellId &cell, const Aabb &b, const Vec3 &p, Vec3 &q, float &cost, uint32_t &id) const {
		if (goal.kind == AirGoalKind::POINT) {
			if (!has_goal_cell || !same_cell(cell, goal_cell)) {
				return false;
			}
			q = goal.regions[0].box.min;
			cost = air_distance(p, q);
			id = goal.regions[0].id;
			return true;
		}
		bool found = false;
		for (const AirGoalRegion &r : goal.regions) {
			Vec3 lo, hi, c;
			bool ok = true;
			for (int axis = 0; axis < 3 && ok; ++axis) {
				const float a = std::max(get(b.min, axis) + INTERIOR_EPS, get(r.box.min, axis));
				const float z = std::min(get(b.max, axis) - INTERIOR_EPS, get(r.box.max, axis));
				ok = a <= z;
				set(lo, axis, a);
				set(hi, axis, z);
				set(c, axis, std::min(std::max(get(p, axis), a), z));
			}
			if (!ok) {
				continue;
			}
			const float d = air_distance(p, c);
			if (!found || d < cost) {
				found = true;
				q = c;
				cost = d;
				id = r.id;
			}
		}
		return found;
	}

	void record_frontier(const CellId &cell, std::vector<AirTileKey> &frontier) const {
		const Aabb b = space->bounds(cell);
		const Vec3 centre = air_centre(b);
		const float out = AIR_FINE_SIZE * 0.25f;
		bool added = false;
		for (int axis = 0; axis < 3; ++axis) {
			for (int side = 0; side < 2; ++side) {
				Vec3 p = centre;
				set(p, axis, side ? get(b.max, axis) + out : get(b.min, axis) - out);
				const AirTileKey t = tile_of(p);
				if (space->tile_revision(t.x, t.y, t.z) != 0) {
					continue;
				}
				added = true;
				add_frontier(t, frontier);
			}
		}
		if (!added) {
			add_frontier(AirTileKey{cell.tx, cell.ty, cell.tz}, frontier); // UNKNOWN cells inside a tile
		}
	}

	void add_frontier(const AirTileKey &t, std::vector<AirTileKey> &frontier) const {
		for (const AirTileKey &f : frontier) {
			if (f.x == t.x && f.y == t.y && f.z == t.z) {
				return;
			}
		}
		if (frontier.size() < limits.max_frontier_tiles) {
			frontier.push_back(t);
		}
	}

	enum class Seal { OPEN, SEALED, NO_GOAL_CELL, UNKNOWN_GOAL };

	// Floods the goal's FREE component (bounded). SEALED: it closed without reaching the start or
	// touching UNKNOWN, so no route exists. OPEN: no proof (cap, start reached, or unknown touched).
	Seal seal_probe(uint32_t cap, uint32_t &visited) {
		seal_map.reset();
		seal_queue.clear();
		visited = 0;
		if (cap == 0) {
			return Seal::OPEN;
		}
		if (goal.kind == AirGoalKind::POINT) {
			if (!has_goal_cell) {
				return Seal::OPEN;
			}
			bool inserted;
			seal_map.find_or_insert(key_of(goal_cell), 0, inserted);
			seal_queue.push_back(goal_cell);
		} else {
			// Every leaf meeting a goal region: enumerate the fine voxels the regions touch.
			uint64_t voxels = 0;
			for (const AirGoalRegion &r : goal.regions) {
				uint64_t count = 1;
				for (int axis = 0; axis < 3; ++axis) {
					const double lo = std::floor(double(get(r.box.min, axis)) / AIR_FINE_SIZE);
					const double hi = std::floor(double(get(r.box.max, axis)) / AIR_FINE_SIZE);
					count *= uint64_t(std::max(0.0, hi - lo + 1.0));
				}
				voxels += count;
			}
			if (voxels > uint64_t(cap) * 8) {
				return Seal::OPEN; // too large to enumerate: no proof attempted
			}
			bool any_unknown = false;
			for (const AirGoalRegion &r : goal.regions) {
				int64_t lo[3], hi[3];
				for (int axis = 0; axis < 3; ++axis) {
					lo[axis] = int64_t(std::floor(double(get(r.box.min, axis)) / AIR_FINE_SIZE));
					hi[axis] = int64_t(std::floor(double(get(r.box.max, axis)) / AIR_FINE_SIZE));
				}
				for (int64_t z = lo[2]; z <= hi[2]; ++z) {
					for (int64_t y = lo[1]; y <= hi[1]; ++y) {
						for (int64_t x = lo[0]; x <= hi[0]; ++x) {
							const Vec3 c{(float(x) + 0.5f) * AIR_FINE_SIZE, (float(y) + 0.5f) * AIR_FINE_SIZE,
								(float(z) + 0.5f) * AIR_FINE_SIZE};
							CellId leaf;
							if (!space->locate(c, leaf)) {
								any_unknown = true;
								continue;
							}
							const Cell s = space->state(leaf);
							Vec3 q;
							float cost;
							uint32_t id;
							if (!goal_point(leaf, space->bounds(leaf), c, q, cost, id)) {
								continue;
							}
							if (s == Cell::UNKNOWN) {
								any_unknown = true;
							}
							if (s != Cell::FREE) {
								continue;
							}
							bool inserted;
							seal_map.find_or_insert(key_of(leaf), 0, inserted);
							if (inserted) {
								seal_queue.push_back(leaf);
							}
						}
					}
				}
			}
			if (seal_queue.empty()) {
				return any_unknown ? Seal::UNKNOWN_GOAL : Seal::NO_GOAL_CELL;
			}
			if (any_unknown) {
				return Seal::OPEN;
			}
		}
		for (size_t head = 0; head < seal_queue.size(); ++head) {
			const CellId cell = seal_queue[head];
			if (++visited > cap) {
				return Seal::OPEN;
			}
			if (key_eq(key_of(cell), start_key) || space->touches_unknown(cell)) {
				return Seal::OPEN;
			}
			space->neighbours(cell, seal_faces);
			for (const Face &f : seal_faces) {
				bool inserted;
				seal_map.find_or_insert(key_of(f.to), 0, inserted);
				if (inserted) {
					seal_queue.push_back(f.to);
				}
			}
		}
		return Seal::SEALED;
	}

	void push(int32_t index) {
		const Node &n = nodes[size_t(index)];
		heap.push_back(HeapEntry{n.g + limits.heuristic_weight * n.h, n.g, n.key, index});
		std::push_heap(heap.begin(), heap.end(), HeapAfter());
	}

	bool better_partial(int32_t candidate) const {
		if (best_partial < 0) {
			return true;
		}
		const Node &a = nodes[size_t(candidate)];
		const Node &b = nodes[size_t(best_partial)];
		if (a.h != b.h) {
			return a.h < b.h;
		}
		if (a.g != b.g) {
			return a.g < b.g;
		}
		return key_less(a.key, b.key);
	}

	void build_route(int32_t last, AirRoute &out, bool arrives) const {
		out = AirRoute();
		std::vector<int32_t> chain;
		for (int32_t i = last; i >= 0; i = nodes[size_t(i)].parent) {
			chain.push_back(i);
		}
		std::reverse(chain.begin(), chain.end());
		for (size_t k = 0; k < chain.size(); ++k) {
			const Node &n = nodes[size_t(chain[k])];
			if (k > 0 && n.has_via) {
				out.points.push_back(n.via);
			}
			if (!key_eq(n.key, GOAL_KEY)) {
				out.cells.push_back(n.cell);
			}
			const Vec3 &p = n.p;
			if (out.points.empty() || air_distance(out.points.back(), p) > 0.0f) {
				out.points.push_back(p);
			}
		}
		const Node &end = nodes[size_t(last)];
		out.cost = end.g;
		out.goal_id = end.goal_id;
		out.arrives = arrives;
	}
};

AirSearch::AirSearch() :
		impl_(new Impl()) {}

AirSearch::~AirSearch() {
	delete impl_;
}

void AirSearch::cancel() {
	cancelled_.store(true, std::memory_order_relaxed);
}

AirStatus AirSearch::begin(const AirSpace &space, const Vec3 &start, const AirGoal &goal, const AirSearchLimits &limits) {
	const Clock::time_point t0 = Clock::now();
	Impl &m = *impl_;
	cancelled_.store(false, std::memory_order_relaxed);
	route_ = AirRoute();
	frontier_.clear();
	stats_ = AirSearchStats();
	m.space = &space;
	m.goal = goal;
	m.limits = limits;
	m.start = start;
	m.nodes.clear();
	m.heap.clear();
	m.map.reset();
	m.goal_node = -1;
	m.best_partial = -1;
	m.has_goal_cell = false;
	m.goal_safe_g = INF;
	m.goal_safe_parent = -1;

	auto finish = [&](AirStatus s) {
		stats_.seconds += std::chrono::duration<double>(Clock::now() - t0).count();
		status_ = s;
		return s;
	};

	bool valid = finite(start) && !goal.regions.empty() && (goal.kind != AirGoalKind::POINT || goal.regions.size() == 1) &&
			std::isfinite(limits.heuristic_weight) && limits.heuristic_weight >= 1.0f;
	for (const AirGoalRegion &r : goal.regions) {
		valid = valid && finite(r.box.min) && finite(r.box.max) && r.box.min.x <= r.box.max.x &&
				r.box.min.y <= r.box.max.y && r.box.min.z <= r.box.max.z;
	}
	if (!valid) {
		return finish(AirStatus::INVALID);
	}

	// Start: every cell touching the start point must be FREE.
	bool unknown = false;
	if (!space.locate(start, m.start_cell) || !air_point_clear(space, start, &unknown)) {
		if (unknown || space.sample(start) == Cell::UNKNOWN) {
			m.add_frontier(tile_of(start), frontier_);
			stats_.touched_unknown = true;
			return finish(AirStatus::WAITING_FOR_GEOMETRY);
		}
		return finish(AirStatus::START_BLOCKED);
	}
	m.start_key = key_of(m.start_cell);

	if (goal.kind == AirGoalKind::POINT) {
		const Vec3 g = goal.regions[0].box.min;
		bool goal_unknown = false;
		const bool located = space.locate(g, m.goal_cell);
		if (!located || !air_point_clear(space, g, &goal_unknown)) {
			if (!located || goal_unknown) {
				m.add_frontier(tile_of(g), frontier_);
				stats_.touched_unknown = true;
				return finish(AirStatus::WAITING_FOR_GEOMETRY);
			}
			return finish(AirStatus::GOAL_BLOCKED);
		}
		m.has_goal_cell = true;
	}

	// Small sealed goal volumes are proven unreachable before any forward search.
	uint32_t probed = 0;
	const Impl::Seal seal = m.seal_probe(std::min(SEAL_PROBE_EARLY_CELLS, limits.seal_probe_cells), probed);
	stats_.seal_probe_cells += probed;
	if (seal == Impl::Seal::SEALED) {
		return finish(AirStatus::UNREACHABLE);
	}
	if (seal == Impl::Seal::NO_GOAL_CELL) {
		return finish(AirStatus::GOAL_BLOCKED);
	}
	if (seal == Impl::Seal::UNKNOWN_GOAL) {
		for (const AirGoalRegion &r : goal.regions) {
			m.add_frontier(tile_of(air_centre(r.box)), frontier_);
		}
		stats_.touched_unknown = true;
		return finish(AirStatus::WAITING_FOR_GEOMETRY);
	}

	m.coarse_phase = limits.coarse_first;
	m.coarse_cap = uint32_t(double(limits.total_expansions) * double(std::max(0.0f, std::min(1.0f, limits.coarse_share))));
	if (m.coarse_phase && m.coarse_cap == 0) {
		m.coarse_phase = false;
	}
	stats_.used_full_search = !m.coarse_phase;
	m.seed();
	stats_.heap_pushes = 1;
	stats_.nodes = 1;
	return finish(AirStatus::PENDING);
}

AirStatus AirSearch::advance() {
	if (status_ != AirStatus::PENDING) {
		return status_;
	}
	const Clock::time_point t0 = Clock::now();
	Impl &m = *impl_;
	const AirSpace &space = *m.space;
	++stats_.slices;
	const bool timed = m.limits.slice_seconds > 0.0;
	const Clock::time_point deadline = t0 + std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(m.limits.slice_seconds));

	auto finish = [&](AirStatus s) {
		stats_.seconds += std::chrono::duration<double>(Clock::now() - t0).count();
		stats_.nodes = uint32_t(m.nodes.size());
		status_ = s;
		return s;
	};

	for (uint32_t count = 0; count < m.limits.slice_expansions; ++count) {
		if (cancelled_.load(std::memory_order_relaxed)) {
			return finish(AirStatus::CANCELLED);
		}
		if (timed && count > 0 && (count & 15) == 0 && Clock::now() >= deadline) {
			break;
		}
		if (m.coarse_phase && (m.heap.empty() || stats_.coarse_expansions >= m.coarse_cap)) {
			// No coarse route: the full search decides, with the remaining budget.
			m.coarse_phase = false;
			stats_.used_full_search = true;
			stats_.touched_unknown = false;
			frontier_.clear();
			m.seed();
			++stats_.heap_pushes;
			continue;
		}
		if (m.heap.empty()) {
			if (stats_.touched_unknown) {
				// Known space is exhausted; a sealed goal component still proves UNREACHABLE.
				uint32_t probed = 0;
				const Impl::Seal seal = m.seal_probe(m.limits.seal_probe_cells, probed);
				stats_.seal_probe_cells += probed;
				return finish(seal == Impl::Seal::SEALED ? AirStatus::UNREACHABLE : AirStatus::WAITING_FOR_GEOMETRY);
			}
			return finish(AirStatus::UNREACHABLE);
		}
		std::pop_heap(m.heap.begin(), m.heap.end(), HeapAfter());
		const HeapEntry entry = m.heap.back();
		m.heap.pop_back();
		Node &popped = m.nodes[size_t(entry.node)];
		if (popped.closed || entry.g != popped.g) {
			continue; // superseded heap entry
		}
		if (entry.node == m.goal_node) {
			Node &gn = popped;
			if (!gn.verified) {
				++stats_.los_checks;
				if (!air_segment_clear(space, m.nodes[size_t(gn.parent)].p, gn.p)) {
					// The straight arrival does not certify: take the best arrival from a goal cell.
					++stats_.los_failures;
					gn.g = m.goal_safe_g;
					gn.parent = m.goal_safe_parent;
					gn.p = m.goal_safe_q;
					gn.via = m.goal_safe_q;
					gn.goal_id = m.goal_safe_id;
					gn.has_via = 0;
					gn.verified = 1;
					m.push(entry.node);
					++stats_.heap_pushes;
					continue;
				}
				gn.verified = 1;
			}
			m.build_route(entry.node, route_, true);
			return finish(AirStatus::COMPLETE);
		}
		if (stats_.expansions >= m.limits.total_expansions) {
			m.heap.push_back(entry); // keep the job intact for diagnostics
			std::push_heap(m.heap.begin(), m.heap.end(), HeapAfter());
			return finish(AirStatus::BUDGET_EXHAUSTED);
		}
		if (!popped.verified) {
			// Lazy Theta*: certify the straight segment from the parent now, or fall back to the
			// best expanded face neighbour (the expanding cell that offered it is one).
			++stats_.los_checks;
			if (!air_segment_clear(space, m.nodes[size_t(popped.parent)].p, popped.p)) {
				++stats_.los_failures;
				space.neighbours(popped.cell, m.faces);
				float best = INF;
				int32_t best_parent = -1;
				Vec3 best_via = popped.p;
				for (const Face &face : m.faces) {
					const int32_t other = m.map.find(key_of(face.to));
					if (other < 0 || !m.nodes[size_t(other)].closed) {
						continue;
					}
					const Vec3 via = air_centre(face.overlap);
					const Node &o = m.nodes[size_t(other)];
					const float cost = o.g + air_distance(o.p, via) + air_distance(via, popped.p);
					if (cost < best) {
						best = cost;
						best_parent = other;
						best_via = via;
					}
				}
				Node &fixed = m.nodes[size_t(entry.node)];
				if (best_parent < 0) {
					fixed.closed = 1; // cannot happen: the offering cell is an expanded neighbour
					continue;
				}
				fixed.g = best;
				fixed.parent = best_parent;
				fixed.via = best_via;
				fixed.has_via = 1;
			}
			m.nodes[size_t(entry.node)].verified = 1;
		}
		Node &current = m.nodes[size_t(entry.node)];
		current.closed = 1;
		++stats_.expansions;
		if (m.coarse_phase) {
			++stats_.coarse_expansions;
		}
		const int32_t index = entry.node;
		if (m.better_partial(index)) {
			m.best_partial = index;
		}
		const CellId cell = current.cell;
		const Vec3 p = current.p;
		const float g = current.g;
		const int32_t grand = m.limits.any_angle ? current.parent : -1;
		const Vec3 grand_p = grand >= 0 ? m.nodes[size_t(grand)].p : p;
		const float grand_g = grand >= 0 ? m.nodes[size_t(grand)].g : 0.0f;
		const Aabb b = space.bounds(cell);

		if (!m.coarse_phase && space.touches_unknown(cell)) {
			stats_.touched_unknown = true;
			m.record_frontier(cell, frontier_);
		}

		Vec3 q;
		float goal_cost = 0.0f;
		uint32_t goal_id = 0;
		if (m.goal_point(cell, b, p, q, goal_cost, goal_id)) {
			const float safe = g + goal_cost;
			if (safe < m.goal_safe_g) {
				m.goal_safe_g = safe;
				m.goal_safe_parent = index;
				m.goal_safe_q = q;
				m.goal_safe_id = goal_id;
			}
			float proposed = safe;
			int32_t parent = index;
			uint8_t verified = 1;
			if (grand >= 0) {
				const float lazy = grand_g + air_distance(grand_p, q);
				if (lazy < safe) {
					proposed = lazy;
					parent = grand;
					verified = 0;
				}
			}
			if (m.goal_node < 0) {
				Node gnode;
				gnode.cell = cell;
				gnode.key = GOAL_KEY;
				gnode.p = q;
				gnode.via = q;
				gnode.g = INF;
				gnode.h = 0.0f;
				gnode.parent = -1;
				gnode.goal_id = goal_id;
				gnode.closed = 0;
				gnode.has_via = 0;
				gnode.verified = 1;
				m.nodes.push_back(gnode);
				m.goal_node = int32_t(m.nodes.size() - 1);
			}
			Node &gn = m.nodes[size_t(m.goal_node)];
			if (proposed < gn.g) {
				gn.g = proposed;
				gn.p = q;
				gn.via = q;
				gn.parent = parent;
				gn.goal_id = goal_id;
				gn.cell = cell;
				gn.has_via = 0;
				gn.verified = verified;
				m.push(m.goal_node);
				++stats_.heap_pushes;
			}
		}

		space.neighbours(cell, m.faces);
		for (const Face &face : m.faces) {
			if (!m.allowed(face.to)) {
				continue;
			}
			const Key k = key_of(face.to);
			bool inserted;
			const int32_t slot = m.map.find_or_insert(k, int32_t(m.nodes.size()), inserted);
			if (inserted) {
				Node n;
				n.cell = face.to;
				n.key = k;
				n.p = air_centre(space.bounds(face.to));
				n.via = n.p;
				n.g = INF;
				n.h = m.heuristic(n.p);
				n.parent = -1;
				n.goal_id = 0;
				n.closed = 0;
				n.has_via = 0;
				n.verified = 1;
				m.nodes.push_back(n);
			}
			Node &n = m.nodes[size_t(slot)];
			if (n.closed) {
				continue;
			}
			const Vec3 via = air_centre(face.overlap);
			float proposed;
			int32_t parent;
			uint8_t has_via;
			if (grand >= 0) {
				proposed = grand_g + air_distance(grand_p, n.p); // certified when n is expanded
				parent = grand;
				has_via = 0;
			} else {
				proposed = g + air_distance(p, via) + air_distance(via, n.p);
				parent = index;
				has_via = 1;
			}
			if (!(proposed < n.g)) {
				continue;
			}
			n.g = proposed;
			n.parent = parent;
			n.via = via;
			n.has_via = has_via;
			n.verified = has_via;
			m.push(slot);
			++stats_.heap_pushes;
		}
	}
	return finish(AirStatus::PENDING);
}

AirStatus AirSearch::run_to_end() {
	while (advance() == AirStatus::PENDING) {
	}
	return status_;
}

bool AirSearch::partial_route(AirRoute &out) const {
	if (impl_->best_partial < 0) {
		return false;
	}
	impl_->build_route(impl_->best_partial, out, false);
	return true;
}

} // namespace nav_air
