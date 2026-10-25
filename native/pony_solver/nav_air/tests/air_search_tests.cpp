// Standalone tests for the air search slice (nav_air: air_search, air_shorten, air_dynamic) on the
// in-memory TestAirSpace and, when built with -DAIR_WITH_STORAGE, on real tiles voxelized from
// triangles by the storage half (air_tiles / air_voxelize). No Godot.
// Build: build_air_search_tests.sh OUTPUT_DIR. Each test answers a behaviour question.
#include "../air_dynamic.h"
#include "../air_search.h"
#include "../air_shorten.h"
#include "../air_test_space.h"
#ifdef AIR_WITH_STORAGE
#include "../air_voxelize.h"
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <map>
#include <queue>
#include <random>
#include <set>
#include <thread>
#include <tuple>

using namespace nav_air;

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition, label)                                                    \
	do {                                                                           \
		++checks;                                                                  \
		if (!(condition)) {                                                        \
			++failures;                                                            \
			std::printf("  FAIL %s (%s:%d)\n", label, __FILE__, __LINE__);        \
		}                                                                          \
	} while (0)

void section(const char *name) {
	std::printf("[%s]\n", name);
}

Aabb box(float x0, float y0, float z0, float x1, float y1, float z1) {
	return Aabb{Vec3{x0, y0, z0}, Vec3{x1, y1, z1}};
}

Vec3 v3(float x, float y, float z) {
	return Vec3{x, y, z};
}

// Closed arena: interior box FREE, everything else in the covering tiles SOLID (>= one coarse
// cell of shell), so exhausting it proves UNREACHABLE.
void make_arena(TestAirSpace &s, const Aabb &interior) {
	s.add_tiles(box(interior.min.x - 4, interior.min.y - 4, interior.min.z - 4, interior.max.x + 4, interior.max.y + 4,
						interior.max.z + 4),
			Cell::SOLID);
	s.fill_box(interior, Cell::FREE);
}

double seconds_since(std::chrono::steady_clock::time_point t0) {
	return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

AirSearchLimits unlimited() {
	AirSearchLimits l;
	l.slice_expansions = 1u << 30;
	l.slice_seconds = 0.0;
	l.total_expansions = 1u << 30;
	return l;
}

struct Outcome {
	AirStatus status;
	AirRoute route;
	std::vector<Vec3> shortened;
	AirSearchStats stats;
	std::vector<AirTileKey> frontier;
};

Outcome solve(const AirSpace &space, const Vec3 &start, const AirGoal &goal, AirSearchLimits limits = unlimited()) {
	AirSearch search;
	Outcome o;
	search.begin(space, start, goal, limits);
	o.status = search.run_to_end();
	o.route = search.route();
	o.stats = search.stats();
	o.frontier = search.frontier_tiles();
	if (o.status == AirStatus::COMPLETE) {
		air_shorten(space, o.route.points, o.shortened);
	}
	return o;
}

float polyline_length(const std::vector<Vec3> &p) {
	float total = 0.0f;
	for (size_t i = 0; i + 1 < p.size(); ++i) {
		total += air_distance(p[i], p[i + 1]);
	}
	return total;
}

bool all_cells_free(const AirSpace &space, const AirRoute &route) {
	for (const CellId &c : route.cells) {
		if (space.state(c) != Cell::FREE) {
			return false;
		}
	}
	return !route.cells.empty();
}

// Points of a polyline sampled every `step` metres (for geometric assertions on routes).
std::vector<Vec3> densify(const std::vector<Vec3> &p, float step) {
	std::vector<Vec3> out;
	for (size_t i = 0; i + 1 < p.size(); ++i) {
		const float l = air_distance(p[i], p[i + 1]);
		const int n = std::max(1, int(std::ceil(l / step)));
		for (int k = 0; k < n; ++k) {
			const float t = float(k) / float(n);
			out.push_back(v3(p[i].x + (p[i + 1].x - p[i].x) * t, p[i].y + (p[i + 1].y - p[i].y) * t,
					p[i].z + (p[i + 1].z - p[i].z) * t));
		}
	}
	if (!p.empty()) {
		out.push_back(p.back());
	}
	return out;
}

bool same_points(const std::vector<Vec3> &a, const std::vector<Vec3> &b) {
	if (a.size() != b.size()) {
		return false;
	}
	for (size_t i = 0; i < a.size(); ++i) {
		if (a[i].x != b[i].x || a[i].y != b[i].y || a[i].z != b[i].z) {
			return false;
		}
	}
	return true;
}

// ---------------------------------------------------------------------------------------------
// Supercover against brute force.

using Voxel = std::tuple<int32_t, int32_t, int32_t>;

bool collect(void *ctx, int32_t x, int32_t y, int32_t z, float) {
	static_cast<std::set<Voxel> *>(ctx)->insert(Voxel(x, y, z));
	return true;
}

std::set<Voxel> cover(const Vec3 &a, const Vec3 &b) {
	std::set<Voxel> s;
	air_supercover(a, b, collect, &s);
	return s;
}

// Voxels whose closed box, grown by `grow` metres, meets the segment (exact slab test in double).
std::set<Voxel> brute(const Vec3 &a, const Vec3 &b, double grow) {
	std::set<Voxel> s;
	const double A[3] = {a.x, a.y, a.z}, B[3] = {b.x, b.y, b.z};
	int lo[3], hi[3];
	for (int k = 0; k < 3; ++k) {
		lo[k] = int(std::floor(std::min(A[k], B[k]) / 0.5)) - 2;
		hi[k] = int(std::floor(std::max(A[k], B[k]) / 0.5)) + 2;
	}
	for (int z = lo[2]; z <= hi[2]; ++z) {
		for (int y = lo[1]; y <= hi[1]; ++y) {
			for (int x = lo[0]; x <= hi[0]; ++x) {
				const int v[3] = {x, y, z};
				double t0 = 0.0, t1 = 1.0;
				bool hit = true;
				for (int k = 0; k < 3 && hit; ++k) {
					const double l = v[k] * 0.5 - grow, h = (v[k] + 1) * 0.5 + grow;
					const double d = B[k] - A[k];
					if (d == 0.0) {
						hit = A[k] >= l && A[k] <= h;
						continue;
					}
					double ta = (l - A[k]) / d, tb = (h - A[k]) / d;
					if (ta > tb) {
						std::swap(ta, tb);
					}
					t0 = std::max(t0, ta);
					t1 = std::min(t1, tb);
					hit = t0 <= t1;
				}
				if (hit) {
					s.insert(Voxel(x, y, z));
				}
			}
		}
	}
	return s;
}

void test_supercover() {
	section("supercover: every voxel the segment touches, ties on edges and corners included");
	// Through an XY edge (4 voxels around the edge line), a 3D corner (8), lying in a plane (both sides).
	{
		const std::set<Voxel> s = cover(v3(0.25f, 0.25f, 0.1f), v3(0.75f, 0.75f, 0.1f));
		const std::set<Voxel> want = {Voxel(0, 0, 0), Voxel(1, 0, 0), Voxel(0, 1, 0), Voxel(1, 1, 0)};
		CHECK(s == want, "diagonal through an edge touches the two side voxels");
	}
	{
		const std::set<Voxel> s = cover(v3(0.25f, 0.25f, 0.25f), v3(0.75f, 0.75f, 0.75f));
		CHECK(s.size() == 8, "diagonal through a corner touches all eight voxels");
	}
	{
		const std::set<Voxel> s = cover(v3(0.5f, 0.2f, 0.2f), v3(0.5f, 0.2f, 1.2f));
		const std::set<Voxel> want = {Voxel(0, 0, 0), Voxel(1, 0, 0), Voxel(0, 0, 1), Voxel(1, 0, 1), Voxel(0, 0, 2),
			Voxel(1, 0, 2)};
		CHECK(s == want, "segment lying in a voxel plane covers both sides");
	}
	{
		const std::set<Voxel> s = cover(v3(-0.5f, -0.5f, 0.2f), v3(-0.5f, -0.5f, 0.3f));
		CHECK(s.size() == 4, "segment on an edge line covers the four voxels around it (negative coords)");
	}
	// Random segments, many with grid-snapped endpoints so ties are frequent.
	std::mt19937 rng(12345);
	std::uniform_real_distribution<float> any(-3.0f, 3.0f);
	std::uniform_int_distribution<int> snap(-12, 12);
	int missing = 0, extra = 0;
	const int trials = 4000;
	for (int i = 0; i < trials; ++i) {
		Vec3 a, b;
		const int mode = i % 4;
		if (mode == 0) {
			a = v3(any(rng), any(rng), any(rng));
			b = v3(any(rng), any(rng), any(rng));
		} else {
			const float q = mode == 1 ? 0.25f : 0.5f;
			a = v3(snap(rng) * q, snap(rng) * q, snap(rng) * q);
			b = v3(snap(rng) * q, snap(rng) * q, snap(rng) * q);
			if (mode == 3) {
				b.y = a.y; // planar
			}
		}
		const std::set<Voxel> s = cover(a, b);
		for (const Voxel &v : brute(a, b, 0.0)) {
			missing += s.count(v) ? 0 : 1;
		}
		const std::set<Voxel> loose = brute(a, b, 1.0e-4);
		for (const Voxel &v : s) {
			extra += loose.count(v) ? 0 : 1;
		}
	}
	std::printf("  %d random segments: %d touched voxels missed, %d reported voxels not touched\n", trials, missing, extra);
	CHECK(missing == 0, "supercover never misses a touched voxel");
	CHECK(extra == 0, "supercover reports only touched voxels (1e-4 m tolerance)");
}

// ---------------------------------------------------------------------------------------------
// Test space and contract.

void test_space_contract() {
	section("test space contract: missing tile UNKNOWN, seams enumerated symmetrically");
	TestAirSpace s;
	s.add_tile(0, 0, 0, Cell::FREE);
	s.add_tile(1, 0, 0, Cell::FREE);
	s.add_tile(-1, 0, 0, Cell::FREE);
	s.refine_box(box(32, 0, 0, 40, 8, 8)); // fine bricks just across the +x tile seam
	s.refine_box(box(8, 8, 8, 12, 12, 12)); // a brick inside tile 0 (coarse/fine seam in a tile)
	s.fill_box(box(32, 1, 1, 32.5f, 1.5f, 1.5f), Cell::SOLID); // first fine layer across the seam
	CHECK(s.sample(v3(70, 1, 1)) == Cell::UNKNOWN, "missing tile samples UNKNOWN");
	CHECK(s.sample(v3(-10, 1, 1)) == Cell::FREE, "negative tile samples FREE");
	CellId c;
	CHECK(!s.locate(v3(1, 40, 1), c), "locate fails in a missing tile");
	CHECK(s.locate(v3(32.2f, 1.2f, 1.2f), c) && c.level == 1 && s.state(c) == Cell::SOLID, "fine solid cell located");
	// Symmetry and geometry of every face around a set of cells.
	std::vector<Vec3> probes = {v3(30, 2, 2), v3(30, 6, 6), v3(33.25f, 1.75f, 1.25f), v3(6, 10, 10), v3(10, 10, 10),
		v3(10.25f, 13, 10.25f), v3(-2, 2, 2), v3(2, 2, 2)};
	int asymmetric = 0, bad_geometry = 0, coarse_fine = 0;
	std::vector<Face> faces, back;
	for (const Vec3 &p : probes) {
		CellId a;
		if (!s.locate(p, a) || s.state(a) != Cell::FREE) {
			continue;
		}
		const Aabb ab = s.bounds(a);
		s.neighbours(a, faces);
		for (const Face &f : faces) {
			const Aabb bb = s.bounds(f.to);
			int flat = 0;
			flat += f.overlap.min.x == f.overlap.max.x;
			flat += f.overlap.min.y == f.overlap.max.y;
			flat += f.overlap.min.z == f.overlap.max.z;
			const bool inside = f.overlap.min.x >= std::max(ab.min.x, bb.min.x) &&
					f.overlap.max.x <= std::min(ab.max.x, bb.max.x) && f.overlap.min.y >= std::max(ab.min.y, bb.min.y) &&
					f.overlap.max.y <= std::min(ab.max.y, bb.max.y) && f.overlap.min.z >= std::max(ab.min.z, bb.min.z) &&
					f.overlap.max.z <= std::min(ab.max.z, bb.max.z);
			bad_geometry += (flat == 1 && inside) ? 0 : 1;
			coarse_fine += a.level != f.to.level ? 1 : 0;
			s.neighbours(f.to, back);
			bool found = false;
			for (const Face &g : back) {
				if (g.to.tx == a.tx && g.to.ty == a.ty && g.to.tz == a.tz && g.to.level == a.level && g.to.coarse == a.coarse &&
						(a.level == 0 || g.to.fine == a.fine)) {
					found = g.overlap.min.x == f.overlap.min.x && g.overlap.max.x == f.overlap.max.x &&
							g.overlap.min.y == f.overlap.min.y && g.overlap.max.y == f.overlap.max.y &&
							g.overlap.min.z == f.overlap.min.z && g.overlap.max.z == f.overlap.max.z;
				}
			}
			asymmetric += found ? 0 : 1;
		}
	}
	std::printf("  coarse<->fine faces checked: %d\n", coarse_fine);
	CHECK(asymmetric == 0, "every face is listed from both sides with the same rectangle");
	CHECK(bad_geometry == 0, "every face rectangle is flat on one axis and inside both cells");
	CHECK(coarse_fine > 60, "coarse cells list each fine cell across a seam");
	// A coarse cell beside a brick lists 64 fine faces (minus the solid one) of 0.25 m^2.
	CellId coarse;
	s.locate(v3(30, 2, 2), coarse);
	s.neighbours(coarse, faces);
	int fine_faces = 0;
	for (const Face &f : faces) {
		if (f.to.tx == 1 && f.to.level == 1) {
			++fine_faces;
			const float area = (f.overlap.max.y - f.overlap.min.y) * (f.overlap.max.z - f.overlap.min.z);
			CHECK(std::fabs(area - 0.25f) < 1e-6f, "seam face is one fine face");
		}
	}
	CHECK(fine_faces == 63, "coarse cell at the tile seam sees 63 free fine faces (one solid)");
	CHECK(!s.touches_unknown(coarse) || true, "touches_unknown callable");
	CellId edge;
	s.locate(v3(62, 2, 2), edge);
	CHECK(s.touches_unknown(edge), "cell at the world edge touches UNKNOWN");
	CellId floor_cell;
	s.locate(v3(10, 2, 10), floor_cell);
	CHECK(s.touches_unknown(floor_cell), "cell on the world floor touches the missing tile below");
	CellId inner;
	s.locate(v3(10, 6, 10), inner); // its +y face meets the fine brick (64 probes)
	CHECK(!s.touches_unknown(inner), "interior cell beside a brick does not touch UNKNOWN");
	s.fill_box(box(12, 4, 8, 16, 8, 12), Cell::UNKNOWN);
	CellId beside;
	s.locate(v3(10, 6, 10), beside);
	CHECK(s.touches_unknown(beside), "cell beside an UNKNOWN coarse entry touches UNKNOWN");
}

// ---------------------------------------------------------------------------------------------
// Reference: Dijkstra on the same cell graph and cost model (independent search code).

struct RefResult {
	bool found = false;
	float cost = 0.0f;
};

RefResult dijkstra(const AirSpace &space, const Vec3 &start, const Vec3 &goal) {
	using K = std::tuple<int32_t, int32_t, int32_t, int, int, int>;
	auto key = [](const CellId &c) { return K(c.tx, c.ty, c.tz, c.level, c.coarse, c.level ? c.fine : 0); };
	CellId sc, gc;
	RefResult r;
	if (!space.locate(start, sc) || !space.locate(goal, gc)) {
		return r;
	}
	std::map<K, double> best;
	std::map<K, bool> done;
	using Item = std::tuple<double, K, CellId, Vec3, bool>;
	struct Cmp {
		bool operator()(const Item &a, const Item &b) const { return std::get<0>(a) > std::get<0>(b); }
	};
	std::priority_queue<Item, std::vector<Item>, Cmp> open;
	open.push(Item(0.0, key(sc), sc, start, false));
	best[key(sc)] = 0.0;
	std::vector<Face> faces;
	const K gk = key(gc);
	while (!open.empty()) {
		const Item it = open.top();
		open.pop();
		const double d = std::get<0>(it);
		if (std::get<4>(it)) {
			r.found = true;
			r.cost = float(d);
			return r;
		}
		const K k = std::get<1>(it);
		if (done[k]) {
			continue;
		}
		done[k] = true;
		const CellId c = std::get<2>(it);
		const Vec3 p = std::get<3>(it);
		if (k == gk) {
			open.push(Item(d + air_distance(p, goal), k, c, goal, true));
		}
		space.neighbours(c, faces);
		for (const Face &f : faces) {
			const K nk = key(f.to);
			if (done[nk]) {
				continue;
			}
			const Vec3 q = air_centre(space.bounds(f.to));
			const Vec3 via = air_centre(f.overlap);
			const double nd = d + double(air_distance(p, via)) + double(air_distance(via, q));
			auto b = best.find(nk);
			if (b == best.end() || nd < b->second) {
				best[nk] = nd;
				open.push(Item(nd, nk, f.to, q, false));
			}
		}
	}
	return r;
}

Vec3 random_free(const AirSpace &s, std::mt19937 &rng, const Aabb &region) {
	std::uniform_real_distribution<float> x(region.min.x, region.max.x), y(region.min.y, region.max.y),
			z(region.min.z, region.max.z);
	for (int i = 0; i < 1000; ++i) {
		const Vec3 p = v3(x(rng), y(rng), z(rng));
		if (air_point_clear(s, p)) {
			return p;
		}
	}
	return region.min;
}

void test_against_dijkstra() {
	section("A* cost equals an independent Dijkstra on the same graph (random worlds)");
	std::mt19937 rng(777);
	int compared = 0, reach_mismatch = 0, cost_mismatch = 0, reachable = 0;
	int any_reach_mismatch = 0, any_above = 0, any_below_line = 0, any_uncertified = 0;
	int default_reach_mismatch = 0, default_uncertified = 0;
	float default_worst = 0.0f;
	float worst = 0.0f, any_worst = 0.0f, any_best = 1e9f;
	for (int world = 0; world < 6; ++world) {
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 64, 32, 64));
		std::uniform_real_distribution<float> pos(0.0f, 60.0f), size(0.6f, 9.0f), h(0.0f, 28.0f);
		for (int k = 0; k < 40; ++k) {
			const float x = pos(rng), z = pos(rng), y = h(rng);
			s.fill_box(box(x, y, z, x + size(rng), y + size(rng), z + size(rng)), Cell::SOLID);
		}
		if (world % 2 == 1) {
			s.fill_box(box(30, 0, 0, 31, 32, 64), Cell::SOLID); // a dividing wall: some goals unreachable
		}
		for (int route = 0; route < 10; ++route) {
			const Vec3 a = random_free(s, rng, box(1, 1, 1, 63, 31, 63));
			const Vec3 b = random_free(s, rng, box(1, 1, 1, 63, 31, 63));
			AirSearchLimits graph = unlimited();
			graph.any_angle = false;
			graph.coarse_first = false;
			graph.heuristic_weight = 1.0f;
			const Outcome o = solve(s, a, AirGoal::point(b), graph);
			AirSearchLimits full_any = unlimited();
			full_any.coarse_first = false;
			full_any.heuristic_weight = 1.0f;
			const Outcome any = solve(s, a, AirGoal::point(b), full_any);
			const RefResult ref = dijkstra(s, a, b);
			++compared;
			const Outcome dflt = solve(s, a, AirGoal::point(b));
			default_reach_mismatch += (dflt.status == AirStatus::COMPLETE) != ref.found ? 1 : 0;
			if (dflt.status == AirStatus::COMPLETE && ref.found) {
				default_worst = std::max(default_worst, dflt.route.cost / ref.cost);
				default_uncertified += air_polyline_clear(s, dflt.route.points, {}) ? 0 : 1;
			}
			any_reach_mismatch += (any.status == AirStatus::COMPLETE) != ref.found ? 1 : 0;
			if (any.status == AirStatus::COMPLETE && ref.found) {
				const float ratio = any.route.cost / ref.cost;
				any_worst = std::max(any_worst, ratio);
				any_best = std::min(any_best, ratio);
				any_above += ratio > 1.0f + 1e-4f ? 1 : 0;
				any_below_line += any.route.cost < air_distance(a, b) - 1e-3f ? 1 : 0;
				any_uncertified += air_polyline_clear(s, any.route.points, {}) ? 0 : 1;
			}
			const bool found = o.status == AirStatus::COMPLETE;
			reach_mismatch += found != ref.found ? 1 : 0;
			if (found && ref.found) {
				++reachable;
				const float rel = std::fabs(o.route.cost - ref.cost) / std::max(1.0f, ref.cost);
				worst = std::max(worst, rel);
				cost_mismatch += rel > 1e-4f ? 1 : 0;
			}
			if (!found) {
				CHECK(o.status == AirStatus::UNREACHABLE, "closed arena: no route means UNREACHABLE");
			}
		}
	}
	std::printf("  %d routes, %d reachable: %d reachability and %d cost mismatches, worst relative %.2e\n", compared,
			reachable, reach_mismatch, cost_mismatch, double(worst));
	CHECK(reach_mismatch == 0, "A* and Dijkstra agree on reachability");
	CHECK(cost_mismatch == 0, "A* cost is optimal on the cell graph");
	CHECK(reachable >= 30, "enough reachable routes compared");
	std::printf("  any-angle: cost / face-graph optimum between %.3f and %.3f, %d above, %d reachability mismatches\n",
			double(any_best), double(any_worst), any_above, any_reach_mismatch);
	CHECK(any_reach_mismatch == 0, "any-angle search agrees on reachability");
	CHECK(any_above == 0, "any-angle route never costs more than the face-graph optimum");
	CHECK(any_below_line == 0, "any-angle cost is never below the straight-line distance");
	CHECK(any_uncertified == 0, "any-angle raw route certifies");
	std::printf("  default limits (coarse-first, any-angle): worst cost / face-graph optimum %.3f, %d reachability mismatches\n",
			double(default_worst), default_reach_mismatch);
	CHECK(default_reach_mismatch == 0, "default search agrees on reachability");
	CHECK(default_worst <= AirSearchLimits().heuristic_weight, "default cost within the weight bound of the optimum");
	CHECK(default_uncertified == 0, "default raw route certifies");
}

// ---------------------------------------------------------------------------------------------
// Obstacle courses.

void check_route(const AirSpace &s, const Outcome &o, const Vec3 &goal, const char *label) {
	char text[160];
	std::snprintf(text, sizeof(text), "%s: COMPLETE", label);
	CHECK(o.status == AirStatus::COMPLETE, text);
	if (o.status != AirStatus::COMPLETE) {
		std::printf("    status %s\n", air_status_name(o.status));
		return;
	}
	std::snprintf(text, sizeof(text), "%s: raw route certifies", label);
	CHECK(air_polyline_clear(s, o.route.points, {}), text);
	std::snprintf(text, sizeof(text), "%s: shortened route certifies", label);
	CHECK(air_polyline_clear(s, o.shortened, {}), text);
	std::snprintf(text, sizeof(text), "%s: every route cell FREE", label);
	CHECK(all_cells_free(s, o.route), text);
	std::snprintf(text, sizeof(text), "%s: arrives exactly at the goal", label);
	CHECK(air_distance(o.route.points.back(), goal) < 1e-5f && o.route.arrives, text);
	std::snprintf(text, sizeof(text), "%s: shortening never lengthens", label);
	CHECK(polyline_length(o.shortened) <= polyline_length(o.route.points) + 1e-3f, text);
}

void test_over_under_around() {
	section("over, under and around obstacles; lateral detour around a wall");
	{
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 96, 48, 32));
		s.fill_box(box(44, 0, 0, 52, 36, 32), Cell::SOLID); // wall across the arena, open above
		const Vec3 a = v3(8, 4, 16), b = v3(88, 4, 16);
		const Outcome o = solve(s, a, AirGoal::point(b));
		check_route(s, o, b, "over");
		float top = -1e9f;
		for (const Vec3 &p : densify(o.shortened, 0.25f)) {
			if (p.x > 44 && p.x < 52) {
				top = std::max(top, p.y);
				CHECK(p.y >= 36.0f, "over: inside the wall's X span the route is above it");
			}
		}
		std::printf("  over: shortened %zu points, %.1f m, height over the wall %.2f m\n", o.shortened.size(),
				double(polyline_length(o.shortened)), double(top));
	}
	{
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 96, 48, 32));
		s.fill_box(box(44, 12, 0, 52, 48, 32), Cell::SOLID); // hanging slab, gap below
		const Vec3 a = v3(8, 30, 16), b = v3(88, 30, 16);
		const Outcome o = solve(s, a, AirGoal::point(b));
		check_route(s, o, b, "under");
		bool below = true;
		for (const Vec3 &p : densify(o.shortened, 0.25f)) {
			if (p.x > 44 && p.x < 52) {
				below = below && p.y <= 12.0f;
			}
		}
		CHECK(below, "under: inside the slab's X span the route is below it");
	}
	{
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 96, 48, 32));
		s.fill_box(box(44, 0, 10, 52, 48, 22), Cell::SOLID); // pillar floor to ceiling
		const Vec3 a = v3(8, 20, 16), b = v3(88, 20, 16);
		const Outcome o = solve(s, a, AirGoal::point(b));
		check_route(s, o, b, "around");
		bool beside = true;
		for (const Vec3 &p : densify(o.shortened, 0.25f)) {
			if (p.x > 44 && p.x < 52) {
				beside = beside && (p.z <= 10.0f || p.z >= 22.0f);
			}
		}
		CHECK(beside, "around: the route passes beside the pillar");
	}
	{
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 96, 32, 64));
		s.fill_box(box(46, 0, 0, 50, 32, 56), Cell::SOLID); // wall with its only gap at z 56..64
		const Vec3 a = v3(8, 16, 8), b = v3(88, 16, 8);
		const Outcome o = solve(s, a, AirGoal::point(b));
		check_route(s, o, b, "lateral detour");
		bool through_gap = true;
		for (const Vec3 &p : densify(o.shortened, 0.25f)) {
			if (p.x > 46 && p.x < 50) {
				through_gap = through_gap && p.z >= 56.0f;
			}
		}
		CHECK(through_gap, "lateral detour: crosses the wall line only through the gap");
		CHECK(polyline_length(o.shortened) > 2.0f * std::sqrt(40.0f * 40.0f + 48.0f * 48.0f) - 1.0f,
				"lateral detour: length matches the detour");
		std::printf("  lateral detour: %.1f m (straight %.1f m), %u expansions\n", double(polyline_length(o.shortened)),
				double(air_distance(a, b)), o.stats.expansions);
	}
}

void test_sealed_volume() {
	section("sealed volumes rejected (closed world, open world, start inside)");
	{
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 96, 32, 32));
		s.fill_box(box(60, 8, 8, 76, 24, 24), Cell::SOLID);
		s.fill_box(box(61, 9, 9, 75, 23, 23), Cell::FREE); // hollow, 1 m walls
		const Outcome o = solve(s, v3(8, 16, 16), AirGoal::point(v3(68, 16, 16)));
		CHECK(o.status == AirStatus::UNREACHABLE, "goal inside a sealed hollow of a closed world: UNREACHABLE");
		std::printf("  closed world: %s after %u expansions\n", air_status_name(o.status), o.stats.expansions);
		const Outcome inside = solve(s, v3(68, 16, 16), AirGoal::point(v3(8, 16, 16)));
		CHECK(inside.status == AirStatus::UNREACHABLE, "start inside a sealed hollow: UNREACHABLE");
		// Each pass (coarse-first, then full) can expand at most the start's own component.
		std::set<std::tuple<int, int, int, int, int, int>> component;
		std::vector<CellId> queue;
		CellId first;
		s.locate(v3(68, 16, 16), first);
		queue.push_back(first);
		std::vector<Face> faces;
		for (size_t head = 0; head < queue.size(); ++head) {
			const CellId c = queue[head];
			if (!component.insert(std::make_tuple(c.tx, c.ty, c.tz, int(c.level), int(c.coarse), c.level ? int(c.fine) : 0))
							 .second) {
				continue;
			}
			s.neighbours(c, faces);
			for (const Face &f : faces) {
				queue.push_back(f.to);
			}
		}
		CHECK(inside.stats.expansions <= 2 * component.size(), "start inside: only the hollow is searched");
		std::printf("  start inside: %u expansions for a %zu-cell sealed component\n", inside.stats.expansions,
				component.size());
	}
	{
		TestAirSpace s; // open world: the edges are missing tiles
		s.add_tiles(box(0, 0, 0, 96, 32, 32), Cell::FREE);
		s.fill_box(box(60, 8, 8, 64, 12, 12), Cell::SOLID);
		s.fill_box(box(61, 9, 9, 63, 11, 11), Cell::FREE); // small sealed room, 2 m inside
		const Outcome o = solve(s, v3(8, 16, 16), AirGoal::point(v3(62, 10, 10)));
		CHECK(o.status == AirStatus::UNREACHABLE, "small sealed room in an open world: UNREACHABLE");
		CHECK(o.stats.expansions == 0, "small sealed room proven by the goal-side probe without a forward search");
		std::printf("  open world small room: %s, probe %u cells, %u expansions\n", air_status_name(o.status),
				o.stats.seal_probe_cells, o.stats.expansions);
		s.fill_box(box(60, 8, 8, 76, 24, 24), Cell::SOLID);
		s.fill_box(box(61, 9, 9, 75, 23, 23), Cell::FREE); // larger hollow
		const Outcome big = solve(s, v3(8, 16, 16), AirGoal::point(v3(68, 16, 16)));
		CHECK(big.status == AirStatus::WAITING_FOR_GEOMETRY || big.status == AirStatus::UNREACHABLE,
				"large sealed hollow in an open world is never COMPLETE");
		AirSearchLimits deep = unlimited();
		deep.seal_probe_cells = 1u << 20;
		const Outcome proven = solve(s, v3(8, 16, 16), AirGoal::point(v3(68, 16, 16)), deep);
		CHECK(proven.status == AirStatus::UNREACHABLE, "large sealed hollow proven with a larger probe");
		std::printf("  open world large hollow: default %s, larger probe %s (%u probe cells)\n", air_status_name(big.status),
				air_status_name(proven.status), proven.stats.seal_probe_cells);
	}
	{
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 64, 32, 32));
		s.fill_box(box(30, 10, 10, 34, 14, 14), Cell::SOLID);
		const Outcome o = solve(s, v3(8, 16, 16), AirGoal::point(v3(32, 12, 12)));
		CHECK(o.status == AirStatus::GOAL_BLOCKED, "goal inside solid: GOAL_BLOCKED");
		const Outcome st = solve(s, v3(32, 12, 12), AirGoal::point(v3(8, 16, 16)));
		CHECK(st.status == AirStatus::START_BLOCKED, "start inside solid: START_BLOCKED");
	}
}

void test_same_xz() {
	section("same X/Z, different Y");
	TestAirSpace s;
	make_arena(s, box(0, 0, 0, 96, 64, 96));
	{
		const Vec3 a = v3(40.3f, 4.2f, 40.7f), b = v3(40.3f, 52.6f, 40.7f);
		const Outcome o = solve(s, a, AirGoal::point(b));
		check_route(s, o, b, "vertical");
		CHECK(o.shortened.size() == 2, "vertical: open air shortens to one straight segment");
		CHECK(std::fabs(polyline_length(o.shortened) - 48.4f) < 1e-3f, "vertical: straight up");
	}
	s.fill_box(box(0, 20, 0, 96, 22, 96), Cell::SOLID); // floor between the levels...
	s.fill_box(box(70, 20, 70, 72, 22, 72), Cell::FREE); // ...with one 2 m hole
	for (int dir = 0; dir < 2; ++dir) {
		const Vec3 low = v3(40.3f, 4.2f, 40.7f), high = v3(40.3f, 52.6f, 40.7f);
		const Vec3 a = dir == 0 ? low : high, b = dir == 0 ? high : low;
		const Outcome o = solve(s, a, AirGoal::point(b));
		check_route(s, o, b, dir == 0 ? "up through a hole" : "down through a hole");
		bool via_hole = true;
		for (const Vec3 &p : densify(o.shortened, 0.1f)) {
			if (p.y > 20 && p.y < 22) {
				via_hole = via_hole && p.x >= 70 && p.x <= 72 && p.z >= 70 && p.z <= 72;
			}
		}
		CHECK(via_hole, "same X/Z: crosses the floor level only through the hole");
	}
	// The goal on the other level must not be accepted at the start's height.
	const Outcome o = solve(s, v3(40, 30, 40), AirGoal::point(v3(40, 10, 40)));
	CHECK(o.status == AirStatus::COMPLETE && std::fabs(o.route.points.back().y - 10.0f) < 1e-5f,
			"arrival is the goal's own height, not the X/Z column");
}

void test_low_ceiling_and_thin_walls() {
	section("low ceiling tunnel, thin walls not tunnelled, blocked diagonal not cut");
	{
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 64, 16, 32));
		s.fill_box(box(24, 0, 0, 40, 16, 32), Cell::SOLID);
		s.fill_box(box(24, 2, 14, 40, 3, 18), Cell::FREE); // 1 m tall tunnel
		const Vec3 a = v3(8, 2.5f, 16), b = v3(56, 2.5f, 16);
		const Outcome o = solve(s, a, AirGoal::point(b));
		check_route(s, o, b, "low ceiling");
		bool inside = true;
		for (const Vec3 &p : densify(o.shortened, 0.1f)) {
			if (p.x > 24 && p.x < 40) {
				inside = inside && p.y >= 2.0f && p.y <= 3.0f && p.z >= 14 && p.z <= 18;
			}
		}
		CHECK(inside, "low ceiling: the route stays inside the tunnel");
		s.fill_box(box(31, 2, 14, 33, 3, 18), Cell::SOLID); // plug the tunnel
		const Outcome plugged = solve(s, a, AirGoal::point(b));
		CHECK(plugged.status == AirStatus::UNREACHABLE, "plugged tunnel: UNREACHABLE");
	}
	{
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 64, 32, 32));
		s.fill_box(box(32.2f, 0, 0, 32.3f, 32, 32), Cell::SOLID); // 10 cm wall
		const Outcome o = solve(s, v3(8, 16, 16), AirGoal::point(v3(56, 16, 16)));
		CHECK(o.status == AirStatus::UNREACHABLE, "10 cm wall across the world: UNREACHABLE");
		CHECK(!air_segment_clear(s, v3(8, 16, 16), v3(56, 16, 16)), "segment through the thin wall rejected");
		CHECK(!air_segment_clear(s, v3(31.0f, 15.0f, 15.0f), v3(33.0f, 17.0f, 17.0f)),
				"diagonal through the thin wall's voxel corner rejected");
		TestAirSpace p;
		make_arena(p, box(0, 0, 0, 64, 32, 32));
		p.fill_box(box(32, 0, 0, 32, 32, 32), Cell::SOLID); // zero-thickness wall exactly on a grid plane
		CHECK(solve(p, v3(8, 16, 16), AirGoal::point(v3(56, 16, 16))).status == AirStatus::UNREACHABLE,
				"zero-thickness wall on a grid plane: UNREACHABLE");
		CHECK(!air_segment_clear(p, v3(31.75f, 16, 16), v3(32.25f, 16, 16)), "segment across the plane wall rejected");
	}
	for (int variant = 0; variant < 2; ++variant) {
		// Two solid blocks touching only along a vertical edge; free quadrants touch only there.
		const float e = variant == 0 ? 8.0f : 6.5f; // coarse-aligned and fine (brick) edge
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 16, 8, 16));
		s.fill_box(box(0, 0, 0, e, 8, e), Cell::SOLID);
		s.fill_box(box(e, 0, e, 16, 8, 16), Cell::SOLID);
		const Vec3 a = v3((e + 16) * 0.5f, 4, e * 0.5f), b = v3(e * 0.5f, 4, (e + 16) * 0.5f);
		const Outcome o = solve(s, a, AirGoal::point(b));
		CHECK(o.status == AirStatus::UNREACHABLE, "blocked diagonal: face graph does not cut the edge");
		CHECK(!air_segment_clear(s, a, b), "blocked diagonal: segment through the shared edge rejected");
		CHECK(!air_segment_clear(s, v3(e + 0.25f, 4.1f, e - 0.25f), v3(e - 0.25f, 4.1f, e + 0.25f)),
				"blocked diagonal: short segment exactly through the edge rejected");
	}
}

void test_unknown() {
	section("unknown is never free");
	TestAirSpace s;
	s.add_tiles(box(0, 0, 0, 96, 32, 32), Cell::FREE);
	s.remove_tile(1, 0, 0); // hole in the middle, the only connection
	{
		const Outcome o = solve(s, v3(16, 16, 16), AirGoal::point(v3(80, 16, 16)));
		CHECK(o.status == AirStatus::WAITING_FOR_GEOMETRY, "only connection unknown: WAITING_FOR_GEOMETRY");
		bool lists_hole = false;
		for (const AirTileKey &t : o.frontier) {
			lists_hole = lists_hole || (t.x == 1 && t.y == 0 && t.z == 0);
		}
		CHECK(lists_hole, "frontier names the missing tile");
		CHECK(!air_segment_clear(s, v3(16, 16, 16), v3(80, 16, 16)), "segment through a missing tile rejected");
		AirSegmentCheck info;
		air_segment_clear(s, v3(16, 16, 16), v3(80, 16, 16), 0.0f, &info);
		CHECK(info.blocking == Cell::UNKNOWN, "rejection reason is UNKNOWN");
	}
	s.add_tiles(box(0, 32, 0, 96, 64, 32), Cell::FREE); // a known level above the hole
	{
		const Vec3 b = v3(80, 16, 16);
		const Outcome o = solve(s, v3(16, 16, 16), AirGoal::point(b));
		check_route(s, o, b, "detour above unknown");
		bool above = true;
		for (const Vec3 &p : densify(o.shortened, 0.1f)) {
			if (p.x > 32 && p.x < 64) {
				above = above && p.y >= 32.0f;
			}
		}
		CHECK(above, "detour: never enters the missing tile");
	}
	CHECK(solve(s, v3(48, 16, 16), AirGoal::point(v3(16, 16, 16))).status == AirStatus::WAITING_FOR_GEOMETRY,
			"start in unknown: WAITING_FOR_GEOMETRY");
	CHECK(solve(s, v3(16, 16, 16), AirGoal::point(v3(48, 16, 16))).status == AirStatus::WAITING_FOR_GEOMETRY,
			"goal in unknown: WAITING_FOR_GEOMETRY");
	CHECK(solve(s, v3(16, 16, 16), AirGoal::hover(v3(48, 16, 16), 2.0f)).status == AirStatus::WAITING_FOR_GEOMETRY,
			"hover region in unknown: WAITING_FOR_GEOMETRY");
	// An UNKNOWN coarse entry inside a present tile is not free either.
	TestAirSpace u;
	make_arena(u, box(0, 0, 0, 64, 16, 16));
	u.fill_box(box(28, 0, 0, 32, 16, 16), Cell::UNKNOWN);
	const Outcome o = solve(u, v3(8, 8, 8), AirGoal::point(v3(56, 8, 8)));
	CHECK(o.status == AirStatus::WAITING_FOR_GEOMETRY, "UNKNOWN cells inside a tile block and report WAITING");
}

void test_goals() {
	section("hover regions and landing footprints");
	TestAirSpace s;
	make_arena(s, box(0, 0, 0, 96, 32, 32));
	{
		const Vec3 centre = v3(80, 10, 16);
		const Outcome o = solve(s, v3(8, 10, 16), AirGoal::hover(centre, 1.5f));
		CHECK(o.status == AirStatus::COMPLETE, "hover region reached");
		const Vec3 end = o.route.points.back();
		CHECK(std::fabs(end.x - centre.x) <= 1.5f && std::fabs(end.y - centre.y) <= 1.5f &&
						std::fabs(end.z - centre.z) <= 1.5f,
				"hover arrival is inside the region");
		CHECK(end.x < centre.x - 1.0f, "hover arrival is the near side of the region");
	}
	{
		s.fill_box(box(60, 0, 0, 68, 6, 32), Cell::SOLID); // a building under pad 7
		std::vector<AirGoalRegion> pads = {
			{box(62, 2, 14, 64, 4, 16), 7}, // inside the building: not usable
			{box(84, 2, 14, 86, 4, 16), 9},
		};
		const Outcome o = solve(s, v3(8, 10, 16), AirGoal::landing(pads));
		CHECK(o.status == AirStatus::COMPLETE && o.route.goal_id == 9, "blocked pad skipped, alternate footprint reached");
		std::vector<AirGoalRegion> blocked = {{box(62, 2, 14, 64, 4, 16), 7}};
		CHECK(solve(s, v3(8, 10, 16), AirGoal::landing(blocked)).status == AirStatus::GOAL_BLOCKED,
				"only pad inside solid: GOAL_BLOCKED");
		std::vector<AirGoalRegion> both = {{box(20, 2, 14, 22, 4, 16), 3}, {box(84, 2, 14, 86, 4, 16), 9}};
		const Outcome near = solve(s, v3(8, 10, 16), AirGoal::landing(both));
		CHECK(near.status == AirStatus::COMPLETE && near.route.goal_id == 3, "nearest reachable footprint chosen");
	}
}

void test_budget_cancel_determinism() {
	section("budget pause/resume, total cap, cancellation, determinism");
	TestAirSpace s;
	make_arena(s, box(0, 0, 0, 96, 32, 64));
	s.fill_box(box(46, 0, 0, 50, 32, 56), Cell::SOLID);
	s.fill_box(box(20, 0, 20, 24, 24, 64), Cell::SOLID);
	const Vec3 a = v3(8, 16, 8), b = v3(88, 16, 8);
	const Outcome whole = solve(s, a, AirGoal::point(b));
	CHECK(whole.status == AirStatus::COMPLETE, "reference search completes");
	AirSearchLimits sliced = unlimited();
	sliced.slice_expansions = 7;
	AirSearch search;
	AirStatus st = search.begin(s, a, AirGoal::point(b), sliced);
	int pendings = 0;
	while ((st = search.advance()) == AirStatus::PENDING) {
		++pendings;
	}
	CHECK(st == AirStatus::COMPLETE, "sliced search completes");
	CHECK(pendings > 10, "sliced search paused many times");
	CHECK(same_points(search.route().points, whole.route.points) && search.route().cost == whole.route.cost &&
					search.stats().expansions == whole.stats.expansions,
			"resumed search equals the one-shot search exactly");
	std::printf("  %d pauses, %u expansions, cost %.3f\n", pendings, search.stats().expansions, double(search.route().cost));
	// Same object reused (stamped scratch) and a fresh object give identical answers.
	AirSearch reused;
	for (int i = 0; i < 3; ++i) {
		reused.begin(s, v3(8, 4, 60), AirGoal::point(v3(90, 30, 2)), unlimited());
		reused.run_to_end();
	}
	reused.begin(s, a, AirGoal::point(b), unlimited());
	reused.run_to_end();
	CHECK(same_points(reused.route().points, whole.route.points) && reused.stats().expansions == whole.stats.expansions,
			"reused scratch gives the identical route");
	// Time-sliced: a tiny time budget still ends with the same route.
	AirSearchLimits timed = unlimited();
	timed.slice_seconds = 1e-6;
	timed.slice_expansions = 1u << 30;
	AirSearch t;
	t.begin(s, a, AirGoal::point(b), timed);
	int time_slices = 0;
	while (t.advance() == AirStatus::PENDING) {
		++time_slices;
	}
	CHECK(t.status() == AirStatus::COMPLETE && same_points(t.route().points, whole.route.points),
			"time-sliced search gives the identical route");
	// Total cap: BUDGET_EXHAUSTED with a usable prefix that does not arrive.
	AirSearchLimits capped = unlimited();
	capped.total_expansions = 40;
	AirSearch c;
	c.begin(s, a, AirGoal::point(b), capped);
	CHECK(c.run_to_end() == AirStatus::BUDGET_EXHAUSTED, "total cap: BUDGET_EXHAUSTED");
	AirRoute prefix;
	CHECK(c.partial_route(prefix) && !prefix.arrives && prefix.points.size() >= 2, "partial prefix exists and never arrives");
	CHECK(air_polyline_clear(s, prefix.points, {}), "partial prefix certifies");
	CHECK(air_distance(prefix.points.back(), b) < air_distance(a, b), "partial prefix ends closer to the goal");
	// Cancellation between slices and from another thread.
	AirSearchLimits small = unlimited();
	small.slice_expansions = 5;
	AirSearch k;
	k.begin(s, a, AirGoal::point(b), small);
	CHECK(k.advance() == AirStatus::PENDING, "first slice pending");
	k.cancel();
	CHECK(k.advance() == AirStatus::CANCELLED && k.advance() == AirStatus::CANCELLED, "cancelled stays cancelled");
	TestAirSpace big;
	big.add_tiles(box(0, 0, 0, 512, 64, 512), Cell::FREE);
	big.fill_box(box(250, 0, 0, 252, 64, 510), Cell::SOLID);
	AirSearchLimits slow = unlimited();
	slow.slice_expansions = 64;
	AirSearch threaded;
	threaded.begin(big, v3(10, 30, 10), AirGoal::point(v3(500, 30, 10)), slow);
	std::thread worker([&threaded]() { threaded.run_to_end(); });
	std::this_thread::sleep_for(std::chrono::milliseconds(2));
	threaded.cancel();
	worker.join();
	CHECK(threaded.status() == AirStatus::CANCELLED || threaded.status() == AirStatus::COMPLETE,
			"cancel from another thread ends the job");
	std::printf("  cross-thread cancel: %s after %u expansions\n", air_status_name(threaded.status()),
			threaded.stats().expansions);
}

void test_seam_routes() {
	section("routes across coarse/fine seams and tile boundaries");
	for (int variant = 0; variant < 2; ++variant) {
		// Tile 0 coarse only; tile 1 fully refined into fine bricks with a wall that has one 0.5 m hole.
		const float wx = variant == 0 ? 40.0f : 32.0f; // inside tile 1, or right at the tile boundary
		TestAirSpace s;
		make_arena(s, box(0, 0, 0, 64, 32, 32));
		s.refine_box(box(32, 0, 0, 64, 32, 32));
		s.fill_box(box(wx, 0, 0, wx + 0.5f, 32, 32), Cell::SOLID);
		s.fill_box(box(wx, 10, 10, wx + 0.5f, 10.5f, 10.5f), Cell::FREE);
		const Vec3 a = v3(8, 10.25f, 10.25f), b = v3(56, 10.25f, 10.25f);
		const Outcome o = solve(s, a, AirGoal::point(b));
		check_route(s, o, b, variant == 0 ? "fine hole inside a refined tile" : "fine hole at the tile seam");
		if (o.status != AirStatus::COMPLETE) {
			continue;
		}
		bool coarse = false, fine = false;
		for (const Vec3 &p : densify(o.route.points, 0.1f)) {
			CellId c;
			if (s.locate(p, c)) {
				coarse = coarse || c.level == 0;
				fine = fine || c.level == 1;
			}
		}
		CHECK(coarse && fine, "seam route passes through coarse and fine leaves");
		std::printf("  %s: %zu route points, %u expansions (%u in the coarse-first pass)\n",
				variant == 0 ? "hole inside the refined tile" : "hole at the tile seam", o.route.points.size(),
				o.stats.expansions, o.stats.coarse_expansions);
		CHECK(o.stats.used_full_search, "coarse-first pass found no coarse route and the full search took over");
		bool through_hole = true;
		for (const Vec3 &p : densify(o.shortened, 0.05f)) {
			if (p.x > wx && p.x < wx + 0.5f) {
				through_hole = through_hole && p.y >= 10.0f && p.y <= 10.5f && p.z >= 10.0f && p.z <= 10.5f;
			}
		}
		CHECK(through_hole, "seam route crosses the wall only through the 0.5 m hole");
		s.fill_box(box(wx, 10, 10, wx + 0.5f, 10.5f, 10.5f), Cell::SOLID);
		CHECK(solve(s, a, AirGoal::point(b)).status == AirStatus::UNREACHABLE, "hole closed: UNREACHABLE");
	}
}

void test_dynamic() {
	section("dynamic blockers and corridor invalidation");
	TestAirSpace base;
	make_arena(base, box(0, 0, 0, 128, 32, 32));
	DynamicOverlay overlay;
	OverlaidAirSpace space(base, overlay);
	const Vec3 a = v3(8, 16, 16), b = v3(120, 16, 16);
	Outcome o = solve(space, a, AirGoal::point(b));
	CHECK(o.status == AirStatus::COMPLETE && o.shortened.size() == 2, "open corridor is one straight segment");
	AirCorridor corridor;
	CHECK(air_make_corridor(space, o.shortened, {}, corridor), "corridor certifies");
	CHECK(corridor.tiles.size() == 4, "corridor depends on the four tiles it crosses");
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::VALID, "unchanged: VALID");
	const uint32_t far = overlay.add(box(10, 2, 2, 12, 4, 4)); // tile (0,0,0): on the corridor's tiles, off its line
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::REVALIDATED, "blocker in a corridor tile, off the line: REVALIDATED");
	CHECK(corridor.recertified == 1, "recertified once");
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::VALID, "after revalidation: VALID again");
	const uint32_t elsewhere = overlay.add(box(200, 2, 2, 202, 4, 4)); // a tile the corridor never touches
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::VALID && corridor.recertified == 1,
			"blocker elsewhere costs no recertification");
	const uint32_t wall = overlay.add(box(62, 13, 13, 66, 19, 19), 0.5f);
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::BLOCKED, "durable blocker on the line: BLOCKED");
	Outcome re = solve(space, a, AirGoal::point(b));
	CHECK(re.status == AirStatus::COMPLETE, "replan around the blocker");
	CHECK(air_polyline_clear(space, re.shortened, {}), "replanned route certifies against the overlay");
	bool clear_of_box = true;
	for (const Vec3 &p : densify(re.shortened, 0.05f)) {
		clear_of_box = clear_of_box && !(p.x > 61.5f && p.x < 66.5f && p.y > 12.5f && p.y < 19.5f && p.z > 12.5f && p.z < 19.5f);
	}
	CHECK(clear_of_box, "replanned route avoids the inflated blocker");
	AirCorridor detour;
	CHECK(air_make_corridor(space, re.shortened, {}, detour), "replanned corridor certifies");
	overlay.move(wall, box(62, 2, 2, 66, 4, 4), 0.5f); // moved off both routes
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::REVALIDATED, "moved away: old corridor valid again");
	CHECK(air_check_corridor(space, detour) == AirCorridorState::REVALIDATED, "detour also still valid");
	overlay.remove(far);
	overlay.remove(elsewhere);
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::REVALIDATED, "removal: REVALIDATED");
	base.fill_box(box(90, 15, 15, 91, 17, 17), Cell::SOLID); // static rebuild on the line
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::BLOCKED, "static tile change on the line: BLOCKED");
	base.fill_box(box(90, 15, 15, 91, 17, 17), Cell::FREE);
	base.remove_tile(2, 0, 0);
	CHECK(air_check_corridor(space, corridor) == AirCorridorState::MISSING_DATA, "tile unloaded: MISSING_DATA");
	// Overlay sampling: whole cells in the search, fine voxels in certification.
	TestAirSpace b2;
	make_arena(b2, box(0, 0, 0, 32, 32, 32));
	DynamicOverlay o2;
	OverlaidAirSpace s2(b2, o2);
	o2.add(box(10.1f, 10.1f, 10.1f, 10.2f, 10.2f, 10.2f));
	CellId c;
	s2.locate(v3(9, 9, 9), c);
	CHECK(s2.state(c) == Cell::SOLID, "overlay makes the whole coarse cell SOLID for the search");
	CHECK(s2.sample(v3(10.15f, 10.15f, 10.15f)) == Cell::SOLID && s2.sample(v3(11.2f, 11.2f, 11.2f)) == Cell::FREE,
			"overlay sample is per fine voxel");
}

void test_smoothing_and_trajectory() {
	section("smoothing through swept clear volume and flight-limit validation");
	TestAirSpace s;
	make_arena(s, box(0, 0, 0, 96, 48, 64));
	s.fill_box(box(40, 0, 0, 56, 48, 40), Cell::SOLID); // block: route bends around its corner
	const Vec3 a = v3(8, 20, 8), b = v3(88, 20, 8);
	const Outcome o = solve(s, a, AirGoal::point(b));
	CHECK(o.status == AirStatus::COMPLETE, "bend course completes");
	AirSmoothPath smooth;
	CHECK(air_smooth(s, o.shortened, AirSmoothOptions(), smooth), "smoothing accepts the certified path");
	CHECK(air_polyline_clear(s, smooth.points, smooth.clearance), "every smoothed segment certifies with its swept size");
	int rounded = 0, sharp = 0;
	for (float c : smooth.clearance) {
		rounded += c > 0.0f ? 1 : 0;
	}
	for (uint8_t f : smooth.sharp) {
		sharp += f;
	}
	std::printf("  shortened %zu points -> smoothed %zu points (%d swept segments, %d sharp corners)\n", o.shortened.size(),
			smooth.points.size(), rounded, sharp);
	AirFlightLimits lim;
	AirTrajectoryReport rep;
	CHECK(air_validate_trajectory(smooth.points, smooth.clearance, lim, 0.0f, 0.0f, rep), "trajectory valid from rest");
	float top = 0.0f;
	for (float v : rep.speed) {
		top = std::max(top, v);
	}
	std::printf("  bend course: %.1f s, top speed %.1f m/s, tightest limit %.2f m/s at point %u\n", double(rep.duration),
			double(top), double(rep.limit[rep.limiting_index]), rep.limiting_index);
	// A fillet at a corner with room to round it: certified curve, faster than the sharp corner.
	TestAirSpace open;
	make_arena(open, box(0, 0, 0, 64, 32, 64));
	const std::vector<Vec3> corner = {v3(8, 16, 8), v3(40, 16, 8), v3(40, 16, 40)};
	AirSmoothPath rounded_path;
	air_smooth(open, corner, AirSmoothOptions(), rounded_path);
	AirTrajectoryReport sharp_rep, round_rep;
	air_validate_trajectory(corner, {}, lim, 0.0f, 0.0f, sharp_rep);
	air_validate_trajectory(rounded_path.points, rounded_path.clearance, lim, 0.0f, 0.0f, round_rep);
	CHECK(sharp_rep.speed[1] == 0.0f, "unrounded 90 degree corner with no slack: stop at the corner");
	float slowest_round = 1e9f;
	for (size_t i = 1; i + 1 < round_rep.speed.size(); ++i) {
		slowest_round = std::min(slowest_round, round_rep.speed[i]);
	}
	CHECK(slowest_round > 4.0f, "rounded corner flown without stopping");
	CHECK(round_rep.duration < sharp_rep.duration, "rounded corner is faster");
	std::printf("  90 deg corner: sharp %.2f s (corner 0 m/s), rounded %.2f s (slowest %.2f m/s)\n",
			double(sharp_rep.duration), double(round_rep.duration), double(slowest_round));
	// A corner next to a wall cannot be rounded on the inside: it stays sharp and slow.
	TestAirSpace tight;
	make_arena(tight, box(0, 0, 0, 64, 32, 64));
	tight.fill_box(box(0, 0, 8.5f, 39.5f, 32, 64), Cell::SOLID);
	const std::vector<Vec3> hug = {v3(8, 16, 8.25f), v3(40, 16, 8.25f), v3(40, 16, 40)};
	CHECK(air_polyline_clear(tight, hug, {}), "hugging path certifies");
	AirSmoothPath hug_smooth;
	air_smooth(tight, hug, AirSmoothOptions(), hug_smooth);
	CHECK(air_polyline_clear(tight, hug_smooth.points, hug_smooth.clearance), "smoothing never certifies a cut corner");
	// Climb limit, braking at the start, stall speed.
	const std::vector<Vec3> climb = {v3(0, 0, 0), v3(100, 100, 0)};
	AirTrajectoryReport cr;
	air_validate_trajectory(climb, {}, lim, 0.0f, 0.0f, cr);
	CHECK(std::fabs(cr.limit[0] - 6.0f / std::sqrt(0.5f)) < 1e-3f, "45 degree climb capped at climb_rate / sin(pitch)");
	const std::vector<Vec3> stop_ahead = {v3(0, 10, 0), v3(5, 10, 0), v3(5, 10, 5)};
	AirTrajectoryReport fast;
	CHECK(!air_validate_trajectory(stop_ahead, {}, lim, 20.0f, 0.0f, fast) &&
					fast.verdict == AirTrajectoryVerdict::TOO_FAST_AT_START,
			"20 m/s with a stop 5 m ahead: rejected, not cut");
	AirFlightLimits glider = lim;
	glider.min_speed = 8.0f;
	AirTrajectoryReport stall;
	CHECK(!air_validate_trajectory(corner, {}, glider, 10.0f, 10.0f, stall) &&
					stall.verdict == AirTrajectoryVerdict::BELOW_STALL_SPEED,
			"glider cannot fly a sharp corner: BELOW_STALL_SPEED");
	const std::vector<Vec3> straight = {v3(0, 10, 0), v3(400, 10, 0)};
	AirTrajectoryReport cruise;
	air_validate_trajectory(straight, {}, lim, 0.0f, 0.0f, cruise);
	const float peak = *std::max_element(cruise.speed.begin(), cruise.speed.end());
	CHECK(peak <= lim.max_speed + 1e-4f, "never above max speed");
	const double expect = 20.0 / 6.0 + 20.0 / 8.0 + (400.0 - 400.0 / 12.0 - 400.0 / 16.0) / 20.0;
	CHECK(std::fabs(cruise.duration - expect) < 1e-2, "straight 400 m duration matches accelerate/cruise/brake");
}

void test_horizon() {
	section("streaming horizon");
	const float need = air_required_distance(350.0f, 0.5f, 30.0f, 10.0f);
	CHECK(std::fabs(need - (175.0f + 350.0f * 350.0f / 60.0f + 10.0f)) < 0.01f, "required distance formula");
	CHECK(std::fabs(air_max_safe_speed(need, 0.5f, 30.0f, 10.0f, 400.0f) - 350.0f) < 0.05f, "max safe speed inverts it");
	CHECK(air_max_safe_speed(9.0f, 0.5f, 30.0f, 10.0f, 400.0f) == 0.0f, "inside the margin: must stop");
	CHECK(air_max_safe_speed(1e6f, 0.5f, 30.0f, 10.0f, 40.0f) == 40.0f, "capped at the profile speed");
	std::printf("  Rainbow Dash 350 m/s, 0.5 s latency, 30 m/s^2 braking, 10 m margin: %.0f m known-safe needed\n",
			double(need));
	TestAirSpace s;
	s.add_tiles(box(0, 0, 0, 64, 32, 32), Cell::FREE); // unknown beyond x = 64
	const std::vector<Vec3> line = {v3(4, 16, 16), v3(30, 16, 16), v3(200, 16, 16)};
	const float known = air_certified_distance(s, line, 1000.0f);
	CHECK(known <= 60.0f + 1e-3f && known >= 59.4f, "known-safe distance ends at the unknown tile");
	const float v = air_max_safe_speed(known, 0.5f, 30.0f, 10.0f, 350.0f);
	std::printf("  60 m of known air ahead: safe speed %.1f m/s\n", double(v));
	CHECK(air_required_distance(v, 0.5f, 30.0f, 10.0f) <= known + 1e-3f, "safe speed stops inside known air");
	s.fill_box(box(40, 0, 0, 40.1f, 32, 32), Cell::SOLID);
	CHECK(air_certified_distance(s, line, 1000.0f) <= 36.0f + 1e-3f, "a thin obstacle ends the known-safe distance");
}

// ---------------------------------------------------------------------------------------------
// 200 m course timing.

double percentile(std::vector<double> v, double q) {
	if (v.empty()) {
		return 0.0;
	}
	std::sort(v.begin(), v.end());
	const size_t i = std::min(v.size() - 1, size_t(q * double(v.size() - 1) + 0.5));
	return v[i];
}

void build_course(TestAirSpace &s, uint32_t seed) {
	s.add_tiles(box(0, 0, 0, 256, 64, 256), Cell::FREE);
	s.fill_box(box(0, 0, 0, 256, 2, 256), Cell::SOLID); // ground
	std::mt19937 rng(seed);
	std::uniform_real_distribution<float> pos(4.0f, 250.0f), r(0.4f, 1.6f), tall(6.0f, 30.0f), crown(2.0f, 6.0f);
	for (int i = 0; i < 260; ++i) { // trees: trunk + crown
		const float x = pos(rng), z = pos(rng), w = r(rng), h = tall(rng), c = crown(rng);
		s.fill_box(box(x - w, 2, z - w, x + w, h, z + w), Cell::SOLID);
		s.fill_box(box(x - c, h - 1, z - c, x + c, h + c, z + c), Cell::SOLID);
	}
	std::uniform_real_distribution<float> bw(6.0f, 20.0f), bh(6.0f, 40.0f);
	for (int i = 0; i < 40; ++i) { // buildings
		const float x = pos(rng), z = pos(rng);
		s.fill_box(box(x, 2, z, x + bw(rng), bh(rng), z + bw(rng)), Cell::SOLID);
	}
	s.fill_box(box(120, 2, 30, 122, 48, 226), Cell::SOLID); // long wall, open at both ends and above
}

struct Mode {
	const char *name;
	bool any_angle;
	float weight;
	bool coarse_first;
};

void test_performance() {
	section("search time on a 200 m course (256 x 64 x 256 m, trees, buildings, a wall)");
	TestAirSpace s;
	build_course(s, 4242);
	std::printf("  world: %zu tiles, %zu fine bricks\n", s.tile_count(), s.brick_count());
	std::mt19937 rng(99);
	std::uniform_real_distribution<float> h(3.0f, 50.0f), side(10.0f, 60.0f), along(20.0f, 236.0f);
	const int routes = 60;
	std::vector<std::pair<Vec3, Vec3>> pairs;
	for (int i = 0; i < routes; ++i) {
		Vec3 a = v3(side(rng), h(rng), along(rng));
		Vec3 b = v3(256.0f - side(rng), h(rng), along(rng));
		if (i % 2) {
			std::swap(a, b);
		}
		for (int tries = 0; tries < 50 && !air_point_clear(s, a); ++tries) {
			a.y += 1.0f;
		}
		for (int tries = 0; tries < 50 && !air_point_clear(s, b); ++tries) {
			b.y += 1.0f;
		}
		pairs.push_back(std::make_pair(a, b));
	}
	const Mode modes[] = {{"face A* w1.0", false, 1.0f, false}, {"face A* w2.0", false, 2.0f, false},
		{"any-angle w1.0", true, 1.0f, false}, {"any-angle w1.5", true, 1.5f, false},
		{"coarse1st w1.0", true, 1.0f, true}, {"coarse1st w1.25", true, 1.25f, true}, {"coarse1st w1.5", true, 1.5f, true},
		{"coarse1st w2.0", true, 2.0f, true}, {"c1st face w1.5", false, 1.5f, true}};
	std::vector<float> reference_length(size_t(routes), 0.0f); // shortened length of the exact any-angle route
	std::printf("  %-16s %8s %8s %9s %9s %9s %10s %10s %9s %9s %9s\n", "mode", "complete", "budget", "med ms", "p95 ms",
			"max ms", "med exp", "p95 exp", "len/ref", "p95", "max");
	for (const Mode &mode : modes) {
		std::vector<double> ms, expansions, ratio;
		double worst_ratio = 0.0;
		int complete = 0, budget = 0;
		AirSearch search;
		for (int i = 0; i < routes; ++i) {
			AirSearchLimits lim;
			lim.slice_expansions = 1u << 30;
			lim.slice_seconds = 0.0;
			lim.any_angle = mode.any_angle;
			lim.heuristic_weight = mode.weight;
			lim.coarse_first = mode.coarse_first;
			const auto t0 = std::chrono::steady_clock::now();
			search.begin(s, pairs[size_t(i)].first, AirGoal::point(pairs[size_t(i)].second), lim);
			const AirStatus st = search.run_to_end();
			ms.push_back(seconds_since(t0) * 1000.0);
			expansions.push_back(search.stats().expansions);
			if (st == AirStatus::COMPLETE) {
				++complete;
				std::vector<Vec3> shortened;
				air_shorten(s, search.route().points, shortened);
				const float len = polyline_length(shortened);
				if (mode.any_angle && mode.weight == 1.0f && !mode.coarse_first) {
					reference_length[size_t(i)] = len;
				}
				if (reference_length[size_t(i)] > 0.0f) {
					ratio.push_back(len / reference_length[size_t(i)]);
					worst_ratio = std::max(worst_ratio, ratio.back());
				}
			} else if (st == AirStatus::BUDGET_EXHAUSTED) {
				++budget;
			}
		}
		std::printf("  %-16s %8d %8d %9.2f %9.2f %9.2f %10.0f %10.0f %9.3f %9.3f %9.3f\n", mode.name, complete, budget,
				percentile(ms, 0.5), percentile(ms, 0.95), percentile(ms, 1.0), percentile(expansions, 0.5),
				percentile(expansions, 0.95), ratio.empty() ? 0.0 : percentile(ratio, 0.5),
				ratio.empty() ? 0.0 : percentile(ratio, 0.95), worst_ratio);
	}
	// Default limits: cold vs warm, shorten and smooth cost, certification.
	std::vector<double> cold, warm, shorten_ms, smooth_ms, lengths, los;
	int complete = 0;
	AirSearch reused;
	const AirSearchLimits defaults;
	for (int i = 0; i < routes; ++i) {
		const Vec3 a = pairs[size_t(i)].first, b = pairs[size_t(i)].second;
		AirSearchLimits lim = defaults;
		lim.slice_expansions = 1u << 30;
		lim.slice_seconds = 0.0;
		auto t0 = std::chrono::steady_clock::now();
		AirSearch fresh;
		fresh.begin(s, a, AirGoal::point(b), lim);
		const AirStatus st = fresh.run_to_end();
		cold.push_back(seconds_since(t0) * 1000.0);
		t0 = std::chrono::steady_clock::now();
		reused.begin(s, a, AirGoal::point(b), lim);
		reused.run_to_end();
		warm.push_back(seconds_since(t0) * 1000.0);
		CHECK(same_points(reused.route().points, fresh.route().points), "warm and cold answers identical");
		if (st != AirStatus::COMPLETE) {
			std::printf("    route %d: %s\n", i, air_status_name(st));
			continue;
		}
		++complete;
		los.push_back(fresh.stats().los_checks);
		std::vector<Vec3> shortened;
		t0 = std::chrono::steady_clock::now();
		air_shorten(s, fresh.route().points, shortened);
		shorten_ms.push_back(seconds_since(t0) * 1000.0);
		AirSmoothPath smooth;
		t0 = std::chrono::steady_clock::now();
		air_smooth(s, shortened, AirSmoothOptions(), smooth);
		smooth_ms.push_back(seconds_since(t0) * 1000.0);
		lengths.push_back(polyline_length(shortened));
		CHECK(air_polyline_clear(s, fresh.route().points, {}) && air_polyline_clear(s, shortened, {}) &&
						air_polyline_clear(s, smooth.points, smooth.clearance),
				"course route certifies (raw, shortened, smoothed)");
	}
	std::printf("  defaults (any_angle=%d weight=%.2f): %d/%d complete; route length median %.0f m (p95 %.0f)\n",
			int(defaults.any_angle), double(defaults.heuristic_weight), complete, routes, percentile(lengths, 0.5),
			percentile(lengths, 0.95));
	std::printf("  search cold ms: median %.2f p95 %.2f max %.2f\n", percentile(cold, 0.5), percentile(cold, 0.95),
			percentile(cold, 1.0));
	std::printf("  search warm ms: median %.2f p95 %.2f max %.2f\n", percentile(warm, 0.5), percentile(warm, 0.95),
			percentile(warm, 1.0));
	std::printf("  segment certifications per search: median %.0f p95 %.0f\n", percentile(los, 0.5), percentile(los, 0.95));
	std::printf("  shorten ms: median %.2f p95 %.2f; smooth ms: median %.2f p95 %.2f\n", percentile(shorten_ms, 0.5),
			percentile(shorten_ms, 0.95), percentile(smooth_ms, 0.5), percentile(smooth_ms, 0.95));
	std::printf("AIR_SEARCH_PERF routes=%d complete=%d warm_median_ms=%.2f warm_p95_ms=%.2f cold_median_ms=%.2f "
				"cold_p95_ms=%.2f\n",
			routes, complete, percentile(warm, 0.5), percentile(warm, 0.95), percentile(cold, 0.5), percentile(cold, 0.95));
	CHECK(complete >= routes * 9 / 10, "most 200 m course routes complete with the default limits");
}

#ifdef AIR_WITH_STORAGE
// ---------------------------------------------------------------------------------------------
// Real tiles: triangles and a heightfield voxelized and inflated by the storage half.

void add_box_triangles(TriangleSoup &soup, float x0, float y0, float z0, float x1, float y1, float z1) {
	const float c[8][3] = {{x0, y0, z0}, {x1, y0, z0}, {x1, y1, z0}, {x0, y1, z0}, {x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1},
		{x0, y1, z1}};
	const int f[12][3] = {{0, 1, 2}, {0, 2, 3}, {4, 6, 5}, {4, 7, 6}, {0, 4, 5}, {0, 5, 1}, {3, 2, 6}, {3, 6, 7}, {0, 3, 7},
		{0, 7, 4}, {1, 5, 6}, {1, 6, 2}};
	for (const auto &t : f) {
		for (int k = 0; k < 3; ++k) {
			soup.xyz.push_back(c[t[k]][0]);
			soup.xyz.push_back(c[t[k]][1]);
			soup.xyz.push_back(c[t[k]][2]);
		}
	}
}

void test_real_tiles() {
	section("real tiles voxelized from triangles (storage half)");
	GeometrySet geo;
	HeightField ground;
	ground.x0 = -16;
	ground.z0 = -16;
	ground.dx = ground.dz = 2;
	ground.w = 70; // x -16..122: the tiles plus the voxelizer's inflation margin
	ground.d = 50; // z -16..82
	ground.heights.assign(size_t(ground.w * ground.d), 1.0f);
	geo.fields.push_back(ground);
	TriangleSoup house;
	house.cls = SourceClass::BUILDING;
	add_box_triangles(house, 40, 0, 8, 52, 14, 56); // closed box building (a triangle shell)
	geo.soups.push_back(house);
	TriangleSoup thin;
	thin.cls = SourceClass::STRUCTURE;
	// One-sided thin panel (two triangles) standing at x = 20.
	const float panel[18] = {20, 0, -16, 20, 40, -16, 20, 40, 80, 20, 0, -16, 20, 40, 80, 20, 0, 80};
	thin.xyz.assign(panel, panel + 18);
	geo.soups.push_back(thin);
	geo.prepare();
	BakeParams params;
	params.envelope_radius = 0.75f;
	AirTileSpace space(AirProfile{"pegasus", 0.75f, Vec3{0, 0, 0}});
	int baked = 0;
	for (int tz = 0; tz < 2; ++tz) {
		for (int ty = 0; ty < 2; ++ty) {
			for (int tx = 0; tx < 3; ++tx) {
				std::string why;
				std::shared_ptr<AirTile> t = bake_tile(TileKey{tx, ty, tz}, geo, params, nullptr, &why);
				if (t) {
					space.publish(t);
					++baked;
				} else {
					std::printf("    tile %d %d %d not baked: %s\n", tx, ty, tz, why.c_str());
				}
			}
		}
	}
	const size_t sealed = space.seal_enclosed(space.keys()); // the shell's hollow inside becomes SOLID
	std::printf("  %d tiles baked, %zu resealed, %zu bricks, %.1f KiB\n", baked, sealed, space.brick_count(),
			double(space.memory_bytes()) / 1024.0);
	CHECK(baked == 12, "all tiles baked");
	const Vec3 a = v3(8, 6, 32), b = v3(88, 6, 32);
	CHECK(space.sample(v3(46, 6, 32)) == Cell::SOLID, "inside the building is SOLID (not hollow)");
	CHECK(space.sample(v3(20.2f, 10, 32)) == Cell::SOLID, "thin panel is SOLID");
	CHECK(space.sample(v3(8, 0.5f, 32)) == Cell::SOLID, "below the terrain surface is SOLID");
	const Outcome o = solve(space, a, AirGoal::point(b));
	std::printf("  real tiles: %s, %u expansions, shortened %zu points, %.1f m\n", air_status_name(o.status),
			o.stats.expansions, o.shortened.size(), double(polyline_length(o.shortened)));
	CHECK(o.status == AirStatus::COMPLETE, "route over the panel and the building found");
	if (o.status == AirStatus::COMPLETE) {
		CHECK(air_polyline_clear(space, o.shortened, {}), "real-tile route certifies");
		bool clear = true;
		for (const Vec3 &p : densify(o.shortened, 0.1f)) {
			if (p.x > 40 - 0.75f && p.x < 52 + 0.75f && p.z > 8 - 0.75f && p.z < 56 + 0.75f) {
				clear = clear && p.y >= 14.0f + 0.75f;
			}
			if (std::fabs(p.x - 20.0f) < 0.75f) {
				clear = clear && p.y >= 40.0f + 0.75f;
			}
		}
		CHECK(clear, "real-tile route keeps the 0.75 m envelope clear of the panel and the building");
	}
	CHECK(!air_segment_clear(space, a, b), "straight line through the building rejected");
	CHECK(solve(space, a, AirGoal::point(v3(46, 6, 32))).status == AirStatus::GOAL_BLOCKED, "goal inside the building blocked");
	CHECK(solve(space, a, AirGoal::point(v3(130, 6, 32))).status == AirStatus::WAITING_FOR_GEOMETRY,
			"goal beyond baked tiles waits for geometry");
}
#endif

} // namespace

int main() {
	test_supercover();
	test_space_contract();
	test_against_dijkstra();
	test_over_under_around();
	test_sealed_volume();
	test_same_xz();
	test_low_ceiling_and_thin_walls();
	test_unknown();
	test_goals();
	test_budget_cancel_determinism();
	test_seam_routes();
	test_dynamic();
	test_smoothing_and_trajectory();
	test_horizon();
#ifdef AIR_WITH_STORAGE
	test_real_tiles();
#else
	std::printf("[real tiles] skipped: built without AIR_WITH_STORAGE\n");
#endif
	test_performance();
	if (failures == 0) {
		std::printf("AIR_SEARCH_TESTS PASS (%d checks, 0 failures)\n", checks);
		return 0;
	}
	std::printf("AIR_SEARCH_TESTS FAIL (%d checks, %d failures)\n", checks, failures);
	return 1;
}
