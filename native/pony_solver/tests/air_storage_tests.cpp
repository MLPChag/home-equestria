// Standalone tests for nav_air storage, voxelization, inflation, sealing and serialization
// (docs/NAVIGATION_AIR_STORAGE_2026_10_02.md). Build: tests/build_air_storage_tests.sh OUT_DIR.
#include "air_serialize.h"
#include "air_tiles.h"
#include "air_voxelize.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

using namespace nav_air;

namespace {

int g_checks = 0, g_failures = 0;

void check(bool ok, const std::string &label) {
	++g_checks;
	if (!ok) {
		++g_failures;
		std::printf("FAIL %s\n", label.c_str());
	}
}

Vec3 v3(double x, double y, double z) { return {float(x), float(y), float(z)}; }

void add_tri(TriangleSoup &s, Vec3 a, Vec3 b, Vec3 c) {
	for (const Vec3 &p : {a, b, c}) {
		s.xyz.push_back(p.x);
		s.xyz.push_back(p.y);
		s.xyz.push_back(p.z);
	}
}
void add_quad(TriangleSoup &s, Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
	add_tri(s, a, b, c);
	add_tri(s, a, c, d);
}
// Axis-aligned rectangle on plane `axis` = k spanning [u0,u1] x [v0,v1] on the other two axes.
void add_rect(TriangleSoup &s, int axis, double k, double u0, double u1, double v0, double v1) {
	auto at = [&](double u, double v) {
		double p[3];
		p[axis] = k;
		p[(axis + 1) % 3] = u;
		p[(axis + 2) % 3] = v;
		return v3(p[0], p[1], p[2]);
	};
	add_quad(s, at(u0, v0), at(u1, v0), at(u1, v1), at(u0, v1));
}
// Hollow closed box as a triangle soup (walls only).
void add_box_shell(TriangleSoup &s, const double mn[3], const double mx[3], bool skip_x_min = false) {
	for (int axis = 0; axis < 3; ++axis) {
		const int b = (axis + 1) % 3, c = (axis + 2) % 3;
		if (!(skip_x_min && axis == 0)) add_rect(s, axis, mn[axis], mn[b], mx[b], mn[c], mx[c]);
		add_rect(s, axis, mx[axis], mn[b], mx[b], mn[c], mx[c]);
	}
}

HeightField field(double x0, double z0, int w, int d, double (*h)(double, double)) {
	HeightField f;
	f.x0 = x0;
	f.z0 = z0;
	f.dx = f.dz = 1.0;
	f.w = w;
	f.d = d;
	f.heights.resize(size_t(w) * d);
	for (int j = 0; j < d; ++j)
		for (int i = 0; i < w; ++i) f.heights[size_t(i) + size_t(w) * j] = float(h(x0 + i, z0 + j));
	return f;
}

double flat0(double, double) { return 0.0; }
double hills(double x, double z) {
	if (std::fabs(x - 30.0) < 1e-9 && std::fabs(z - 30.0) < 1e-9) return 28.0;  // one sharp spike vertex
	return 10.0 + 6.0 * std::sin(x * 0.3) * std::cos(z * 0.2);
}

std::shared_ptr<AirTile> bake(const TileKey &k, GeometrySet &g, float radius, bool raw, bool terrain) {
	g.prepare();
	BakeParams p;
	p.envelope_radius = radius;
	p.raw_only = raw;
	p.require_terrain = terrain;
	std::string why;
	auto t = bake_tile(k, g, p, nullptr, &why);
	if (!t) std::printf("note: bake (%d,%d,%d) failed: %s\n", k.x, k.y, k.z, why.c_str());
	return t;
}

Cell at(const AirTileSpace &s, double x, double y, double z) { return s.sample(v3(x, y, z)); }

uint16_t comp_at(const AirTileSpace &s, double x, double y, double z) {
	CellId c;
	if (!s.locate(v3(x, y, z), c)) return NO_COMPONENT;
	return s.component(c);
}

// Enumerates every leaf of every tile.
template <class F>
void for_each_leaf(const AirTileSpace &s, F f) {
	for (const TileKey &k : s.keys()) {
		const AirTile *t = s.find(k);
		for (int c = 0; c < CELLS; ++c) {
			if (t->is_brick(c)) {
				for (int fi = 0; fi < CELLS; ++fi) f(CellId{k.x, k.y, k.z, uint16_t(c), uint16_t(fi), 1});
			} else {
				f(CellId{k.x, k.y, k.z, uint16_t(c), 0, 0});
			}
		}
	}
}

// Every face neighbour is FREE, touches along exactly one axis with a positive-area overlap
// equal to the intersection of both faces, and the relation is symmetric (no diagonals).
void check_neighbour_geometry(const AirTileSpace &s, const std::string &label) {
	std::vector<Face> faces, back;
	size_t bad = 0, asym = 0, total = 0;
	for_each_leaf(s, [&](const CellId &c) {
		if (s.state(c) != Cell::FREE) return;
		s.neighbours(c, faces);
		const Aabb a = s.bounds(c);
		for (const Face &f : faces) {
			++total;
			if (s.state(f.to) != Cell::FREE) { ++bad; continue; }
			const Aabb b = s.bounds(f.to);
			int touching = 0, overlapping = 0;
			bool rect_ok = true;
			const float amn[3] = {a.min.x, a.min.y, a.min.z}, amx[3] = {a.max.x, a.max.y, a.max.z};
			const float bmn[3] = {b.min.x, b.min.y, b.min.z}, bmx[3] = {b.max.x, b.max.y, b.max.z};
			const float omn[3] = {f.overlap.min.x, f.overlap.min.y, f.overlap.min.z};
			const float omx[3] = {f.overlap.max.x, f.overlap.max.y, f.overlap.max.z};
			for (int k = 0; k < 3; ++k) {
				const float lo = std::max(amn[k], bmn[k]), hi = std::min(amx[k], bmx[k]);
				if (hi == lo) ++touching;
				else if (hi > lo) ++overlapping;
				if (omn[k] != lo || omx[k] != hi) rect_ok = false;
			}
			if (touching != 1 || overlapping != 2 || !rect_ok) ++bad;
			s.neighbours(f.to, back);
			bool found = false;
			for (const Face &r : back)
				if (r.to.tx == c.tx && r.to.ty == c.ty && r.to.tz == c.tz && r.to.coarse == c.coarse &&
						r.to.level == c.level && (c.level == 0 || r.to.fine == c.fine))
					found = true;
			if (!found) ++asym;
		}
	});
	check(total > 0 && bad == 0, label + ": neighbour faces geometric (" + std::to_string(bad) + " bad of " + std::to_string(total) + ")");
	check(asym == 0, label + ": neighbour relation symmetric (" + std::to_string(asym) + " one-way)");
}

// Every FREE fine cell (and coarse FREE cell) keeps its corners and centre farther than
// `radius` from every triangle of `soup` (sampled check of the conservative guarantee).
void check_clearance(const AirTileSpace &s, const TriangleSoup &soup, double radius, const std::string &label) {
	size_t bad = 0, tested = 0;
	const size_t n = soup.triangle_count();
	std::vector<double> tri(n * 9);
	for (size_t i = 0; i < tri.size(); ++i) tri[i] = soup.xyz[i];
	for_each_leaf(s, [&](const CellId &c) {
		if (s.state(c) != Cell::FREE) return;
		const Aabb b = s.bounds(c);
		for (int k = 0; k < 9; ++k) {
			double p[3];
			if (k == 8) {
				p[0] = 0.5 * (b.min.x + b.max.x);
				p[1] = 0.5 * (b.min.y + b.max.y);
				p[2] = 0.5 * (b.min.z + b.max.z);
			} else {
				p[0] = (k & 1) ? b.max.x : b.min.x;
				p[1] = (k & 2) ? b.max.y : b.min.y;
				p[2] = (k & 4) ? b.max.z : b.min.z;
			}
			++tested;
			for (size_t t = 0; t < n; ++t)
				if (point_triangle_distance(p, &tri[t * 9]) <= radius) { ++bad; break; }
		}
	});
	check(tested > 0 && bad == 0, label + ": free cells clear of geometry by > " + std::to_string(radius) + " m (" +
			std::to_string(bad) + " of " + std::to_string(tested) + " samples too close)");
}

void test_sat() {
	std::mt19937 rng(7);
	std::uniform_real_distribution<double> u(-2.0, 2.0);
	size_t missed = 0, overlaps = 0;
	for (int trial = 0; trial < 4000; ++trial) {
		double tri[9];
		for (double &v : tri) v = u(rng);
		const double c[3] = {u(rng) * 0.5, u(rng) * 0.5, u(rng) * 0.5};
		const double h[3] = {0.25, 0.25, 0.25};
		const bool sat = triangle_box_overlap(c, h, tri);
		overlaps += sat;
		// Any sampled triangle point strictly inside the box must be reported.
		bool inside = false;
		for (int i = 0; i <= 40 && !inside; ++i)
			for (int j = 0; i + j <= 40 && !inside; ++j) {
				const double a = i / 40.0, b = j / 40.0, w = 1.0 - a - b;
				bool in = true;
				for (int k = 0; k < 3; ++k) {
					const double p = tri[k] * w + tri[3 + k] * a + tri[6 + k] * b;
					in = in && std::fabs(p - c[k]) < h[k];
				}
				inside = in;
			}
		if (inside && !sat) ++missed;
	}
	check(missed == 0 && overlaps > 100, "SAT never misses a sampled triangle point inside a box (" + std::to_string(missed) + " misses)");
	const double c0[3] = {0, 0, 0}, h0[3] = {0.25, 0.25, 0.25};
	const double far[9] = {1, 1, 1, 2, 1, 1, 1, 2, 1};
	const double plane_cut[9] = {-5, 0.1, -5, 5, 0.1, -5, 0, 0.1, 5};  // big triangle through the box
	const double edge_touch[9] = {0.25, -1, -1, 0.25, 1, -1, 0.25, 0, 1};  // lies on the box face
	check(!triangle_box_overlap(c0, h0, far), "SAT separates a distant triangle");
	check(triangle_box_overlap(c0, h0, plane_cut), "SAT catches a large triangle with all vertices outside");
	check(triangle_box_overlap(c0, h0, edge_touch), "SAT counts a triangle lying on the box face (closed boxes)");
}

void test_thin_wall() {
	GeometrySet g;
	TriangleSoup wall;
	wall.cls = SourceClass::STRUCTURE;
	add_rect(wall, 0, 10.25, -10, 50, -10, 50);  // plane x = 10.25 across the whole tile
	g.soups.push_back(wall);
	AirTileSpace raw;
	raw.publish(bake({0, 0, 0}, g, 0.0f, true, false));
	check(at(raw, 10.3, 5, 5) == Cell::SOLID, "thin wall: raw cell holding the 0 mm wall is SOLID");
	check(at(raw, 9.9, 5, 5) == Cell::FREE && at(raw, 10.6, 5, 5) == Cell::FREE, "thin wall: raw neighbours FREE");
	check(comp_at(raw, 5, 5, 5) != comp_at(raw, 20, 5, 5) && comp_at(raw, 5, 5, 5) != NO_COMPONENT,
			"thin wall: sides are different components (no leak through 0.5 m cells)");

	AirTileSpace s(AirProfile{"wall", 1.0f, {0, 0, 0}});
	s.publish(bake({0, 0, 0}, g, 1.0f, false, false));
	// Raw cell [10.0, 10.5]; box-to-box distance <= 1.0 m covers cells [8.5, 12.0).
	check(at(s, 8.45, 5, 5) == Cell::FREE, "thin wall R=1: x=8.45 FREE (box gap 1.5 m)");
	check(at(s, 8.55, 5, 5) == Cell::SOLID, "thin wall R=1: x=8.55 SOLID (box gap 1.0 m)");
	check(at(s, 11.95, 5, 5) == Cell::SOLID, "thin wall R=1: x=11.95 SOLID");
	check(at(s, 12.05, 5, 5) == Cell::FREE, "thin wall R=1: x=12.05 FREE (inflation applied exactly once)");
	check(comp_at(s, 2, 5, 5) != comp_at(s, 20, 5, 5), "thin wall R=1: sides stay separate components");
	check_clearance(s, wall, 1.0, "thin wall R=1");
	check_neighbour_geometry(s, "thin wall R=1");
}

void test_low_ceiling() {
	GeometrySet g;
	g.fields.push_back(field(-8, -8, 49, 49, flat0));  // x, z in [-8, 40]
	TriangleSoup ceiling;
	ceiling.cls = SourceClass::BUILDING;
	add_rect(ceiling, 1, 2.5, -8, 40, 8, 24);  // y = 2.5, z in [-8, 40], x in [8, 24]
	g.soups.push_back(ceiling);
	for (float radius : {1.0f, 0.25f}) {
		AirTileSpace s(AirProfile{"ceiling", radius, {0, 0, 0}});
		for (int ty : {-1, 0}) s.publish(bake({0, ty, 0}, g, radius, false, true));
		const std::string r = radius > 0.5f ? "R=1" : "R=0.25";
		check(s.find({0, -1, 0}) && s.find({0, -1, 0})->uniform == uint8_t(Cell::SOLID),
				"low ceiling " + r + ": tile below the ground is uniform SOLID");
		check(at(s, 16, 5, 16) == Cell::FREE, "low ceiling " + r + ": above the ceiling FREE");
		if (radius > 0.5f) {
			check(at(s, 16, 1.25, 16) == Cell::SOLID, "low ceiling R=1: 2.5 m gap under the ceiling is closed");
			check(at(s, 4, 1.25, 16) == Cell::SOLID && at(s, 4, 2.6, 16) == Cell::FREE,
					"low ceiling R=1: open ground clearance band starts above 2.5 m");
		} else {
			check(at(s, 16, 1.25, 16) == Cell::FREE, "low ceiling R=0.25: passage under the ceiling FREE");
			check(at(s, 16, 0.9, 16) == Cell::SOLID && at(s, 16, 1.6, 16) == Cell::SOLID,
					"low ceiling R=0.25: passage exactly one 0.5 m layer high");
			check(comp_at(s, 16, 1.25, 16) == comp_at(s, 4, 1.25, 16), "low ceiling R=0.25: passage connects to the open side");
		}
		check_clearance(s, ceiling, radius, "low ceiling " + r);
	}
}

void test_closed_box() {
	const double mn[3] = {8, 8, 8}, mx[3] = {20, 20, 20};
	{
		GeometrySet g;
		TriangleSoup box;
		box.cls = SourceClass::BUILDING;
		add_box_shell(box, mn, mx);
		g.soups.push_back(box);
		AirTileSpace s(AirProfile{"box", 0.5f, {0, 0, 0}});
		s.publish(bake({0, 0, 0}, g, 0.5f, false, false));
		check(at(s, 14, 14, 14) == Cell::FREE, "closed box: hollow interior FREE before sealing");
		check(comp_at(s, 14, 14, 14) != comp_at(s, 2, 2, 2), "closed box: interior is its own component");
		const uint64_t before = s.tile_revision(0, 0, 0);
		const size_t changed = s.seal_enclosed(s.keys());
		check(changed == 1 && s.tile_revision(0, 0, 0) > before, "closed box: sealing republishes the tile with a new revision");
		check(at(s, 14, 14, 14) == Cell::SOLID, "closed box: sealed interior becomes SOLID");
		check(at(s, 2, 2, 2) == Cell::FREE && at(s, 30, 30, 30) == Cell::FREE, "closed box: outside stays FREE");
		check_clearance(s, box, 0.5, "closed box");
	}
	{
		// 4 m doorway in the x = 8 wall: open, interior reachable from outside.
		GeometrySet g;
		TriangleSoup box;
		add_box_shell(box, mn, mx, true);
		add_rect(box, 0, 8, 12, 20, 8, 20);  // y 12..20
		add_rect(box, 0, 8, 8, 12, 8, 12);   // y 8..12, z 8..12
		add_rect(box, 0, 8, 8, 12, 16, 20);  // y 8..12, z 16..20 (hole y 8..12, z 12..16)
		g.soups.push_back(box);
		AirTileSpace s(AirProfile{"door", 0.5f, {0, 0, 0}});
		s.publish(bake({0, 0, 0}, g, 0.5f, false, false));
		s.seal_enclosed(s.keys());
		check(at(s, 14, 14, 14) == Cell::FREE && comp_at(s, 14, 14, 14) == comp_at(s, 2, 2, 2),
				"box with a 4 m doorway: interior stays FREE and reachable");
	}
	{
		// 1 m doorway with a 1 m envelope: too narrow, sealed.
		GeometrySet g;
		TriangleSoup box;
		add_box_shell(box, mn, mx, true);
		add_rect(box, 0, 8, 9, 20, 8, 20);       // y 9..20
		add_rect(box, 0, 8, 8, 9, 8, 13.5);      // y 8..9, z 8..13.5
		add_rect(box, 0, 8, 8, 9, 14.5, 20);     // hole y 8..9, z 13.5..14.5
		g.soups.push_back(box);
		AirTileSpace s(AirProfile{"slot", 1.0f, {0, 0, 0}});
		s.publish(bake({0, 0, 0}, g, 1.0f, false, false));
		s.seal_enclosed(s.keys());
		check(at(s, 14, 14, 14) == Cell::SOLID, "box with a 1 m doorway, 1 m envelope: sealed SOLID");
	}
}

void test_terrain_fill() {
	GeometrySet g;
	g.fields.push_back(field(-8, -8, 81, 81, hills));  // x, z in [-8, 72]
	AirTileSpace s(AirProfile{"terrain", 0.5f, {0, 0, 0}});
	for (int ty : {-1, 0, 1})
		for (int tx : {0, 1}) s.publish(bake({tx, ty, 0}, g, 0.5f, false, true));
	check(s.tile_count() == 6, "terrain: six covered tiles baked");
	check(s.find({0, -1, 0})->uniform == uint8_t(Cell::SOLID), "terrain: tile below the surface uniform SOLID");
	check(s.find({0, 1, 0})->uniform == uint8_t(Cell::FREE), "terrain: tile above the spike uniform FREE");
	std::mt19937 rng(11);
	std::uniform_real_distribution<double> ux(0.0, 63.99), uz(0.0, 31.99), depth(0.05, 30.0);
	size_t below_bad = 0, above_bad = 0;
	for (int i = 0; i < 3000; ++i) {
		const double x = ux(rng), z = uz(rng);
		const int x0 = int(std::floor(x)), z0 = int(std::floor(z));
		double lo = 1e9, hi = -1e9;
		for (int dz = 0; dz <= 1; ++dz)
			for (int dx = 0; dx <= 1; ++dx) lo = std::min(lo, hills(x0 + dx, z0 + dz));
		for (int dz = -2; dz <= 3; ++dz)
			for (int dx = -2; dx <= 3; ++dx) hi = std::max(hi, hills(x0 + dx, z0 + dz));
		const double yb = lo - depth(rng);
		if (yb > -32 && at(s, x, yb, z) != Cell::SOLID) ++below_bad;
		// Highest raw cell top <= max + 0.5, grown cell + 0.5, envelope 0.5 rounded up to a cell.
		const double ya = hi + 0.5 + 0.5 + 1.0 + 0.01;
		if (ya < 64 && at(s, x, ya, z) != Cell::FREE) ++above_bad;
	}
	check(below_bad == 0, "terrain: every sampled point under the surface SOLID (" + std::to_string(below_bad) + " not)");
	check(above_bad == 0, "terrain: points clear of the surface by envelope + cells FREE (" + std::to_string(above_bad) + " not)");
	check(at(s, 30.25, 27.0, 30.25) == Cell::SOLID && at(s, 29.75, 27.0, 29.75) == Cell::SOLID,
			"terrain: columns touching the spike vertex filled to its top (no tunnel)");
	check(at(s, 30.25, 31.0, 30.25) == Cell::FREE, "terrain: above the inflated spike FREE");
	std::string why;
	GeometrySet copy = g;
	BakeParams p;
	p.envelope_radius = 0.5f;
	check(!bake_tile({3, 0, 0}, copy, p, nullptr, &why) && !why.empty(), "terrain: tile without heightfield coverage is not baked (stays UNKNOWN)");
	check_neighbour_geometry(s, "terrain");
}

std::vector<Vec3> prism(double radius, double y0, double y1, int sides) {
	std::vector<Vec3> pts;
	const double r = radius / std::cos(M_PI / sides);  // circumscribed: contains the cylinder
	for (int i = 0; i < sides; ++i) {
		const double a = 2 * M_PI * i / sides;
		pts.push_back(v3(r * std::cos(a), y0, r * std::sin(a)));
		pts.push_back(v3(r * std::cos(a), y1, r * std::sin(a)));
	}
	return pts;
}

void test_instanced_tree() {
	GeometrySet g;
	g.fields.push_back(field(-8, -8, 81, 81, flat0));
	const std::vector<Vec3> trunk = prism(0.4, 0.0, 6.0, 12);
	std::vector<Vec3> crown;
	for (int i = 0; i < 8; ++i) crown.push_back(v3((i & 1) ? 3 : -3, (i & 2) ? 10 : 4, (i & 4) ? 2 : -2));
	std::mt19937 rng(5);
	std::uniform_real_distribution<double> pos(6.0, 58.0), yaw(0.0, 2 * M_PI), sc(0.8, 1.3);
	std::vector<float> xforms;
	std::vector<std::array<double, 5>> trees;  // x, z, yaw, scale
	while (trees.size() < 12) {
		const double x = pos(rng), z = pos(rng);
		bool close = false;
		for (const auto &t : trees) close = close || std::hypot(t[0] - x, t[1] - z) < 9.0;
		if (close) continue;
		const double a = yaw(rng), s = sc(rng);
		trees.push_back({x, z, a, s, 0});
		const double c = std::cos(a) * s, n = std::sin(a) * s;
		// Basis columns: X = (c, 0, -n), Y = (0, s, 0), Z = (n, 0, c) (yaw about +Y, uniform scale).
		const float m[12] = {float(c), 0, float(-n), 0, float(s), 0, float(n), 0, float(c), float(x), 0, float(z)};
		xforms.insert(xforms.end(), m, m + 12);
	}
	add_instanced_convex(g, SourceClass::FOLIAGE_TRUNK, trunk, xforms);
	add_instanced_convex(g, SourceClass::FOLIAGE_CROWN, crown, xforms);
	g.prepare();
	size_t fallbacks = 0;
	for (const ConvexSolid &c : g.convexes) fallbacks += c.box_fallback;
	check(g.convexes.size() == 24 && fallbacks == 0, "instanced tree: 12 instances x (trunk prism + crown box), exact hulls");
	AirTileSpace s(AirProfile{"tree", 0.5f, {0, 0, 0}});
	for (int ty : {-1, 0})
		for (int tz : {0, 1})
			for (int tx : {0, 1}) s.publish(bake({tx, ty, tz}, g, 0.5f, false, true));
	size_t trunk_bad = 0, crown_bad = 0, clear_bad = 0;
	for (const auto &t : trees) {
		const double c = std::cos(t[2]) * t[3], n = std::sin(t[2]) * t[3];
		auto world = [&](double lx, double ly, double lz) {
			return v3(t[0] + c * lx + n * lz, ly * t[3], t[1] - n * lx + c * lz);
		};
		for (double ly : {0.5, 2.0, 3.9}) {
			const Vec3 p = world(0.39 * std::cos(ly), ly, 0.39 * std::sin(ly));
			if (s.sample(p) != Cell::SOLID) ++trunk_bad;
		}
		for (int i = 0; i < 8; ++i) {
			const Vec3 p = world((i & 1) ? 2.9 : -2.9, (i & 2) ? 9.9 : 4.1, (i & 4) ? 1.9 : -1.9);
			if (s.sample(p) != Cell::SOLID) ++crown_bad;
		}
	}
	std::uniform_real_distribution<double> any(0.0, 63.9);
	for (int i = 0; i < 2000; ++i) {
		const double x = any(rng), z = any(rng), y = 3.0 + std::fmod(any(rng), 12.0);
		bool near = false;
		for (const auto &t : trees) near = near || std::hypot(t[0] - x, t[1] - z) < 3.7 * t[3] + 2.1;  // crown corner + raw cell, grown cell, envelope
		if (near || y < 2.1) continue;
		if (at(s, x, y, z) != Cell::FREE) ++clear_bad;
	}
	check(trunk_bad == 0, "instanced tree: points inside every trunk cylinder SOLID (" + std::to_string(trunk_bad) + " not)");
	check(crown_bad == 0, "instanced tree: points inside every rotated, scaled crown SOLID (" + std::to_string(crown_bad) + " not)");
	check(clear_bad == 0, "instanced tree: air away from every instance FREE (" + std::to_string(clear_bad) + " not)");
}

void test_mixed_resolution_seam() {
	GeometrySet g;
	TriangleSoup pillar;
	const double mn[3] = {0.1, 5.1, 5.1}, mx[3] = {1.4, 6.9, 6.9};
	add_box_shell(pillar, mn, mx);
	g.soups.push_back(pillar);
	AirTileSpace s;
	s.publish(bake({-1, 0, 0}, g, 0.0f, true, false));  // no geometry inside: coarse only
	s.publish(bake({0, 0, 0}, g, 0.0f, true, false));
	const AirTile *a = s.find({-1, 0, 0}), *b = s.find({0, 0, 0});
	check(a->uniform == uint8_t(Cell::FREE), "seam: tile (-1,0,0) is one coarse FREE level");
	check(!b->uniform && b->is_brick(0 + 8 * (1 + 8 * 1)), "seam: tile (0,0,0) has a fine brick at the shared face");
	// Coarse cell (7,1,1) of the left tile: x [-4,0], y [4,8], z [4,8].
	CellId left{-1, 0, 0, uint16_t(7 + 8 * (1 + 8 * 1)), 0, 0};
	std::vector<Face> faces;
	s.neighbours(left, faces);
	size_t across = 0;
	double area = 0;
	bool plane_ok = true;
	for (const Face &f : faces) {
		if (f.to.tx != 0) continue;
		++across;
		area += double(f.overlap.max.y - f.overlap.min.y) * double(f.overlap.max.z - f.overlap.min.z);
		plane_ok = plane_ok && f.overlap.min.x == 0.0f && f.overlap.max.x == 0.0f && f.to.level == 1;
	}
	// Layer x in [0, 0.5]: 64 fine cells, 16 of them (y, z in [5, 7]) hold the pillar.
	check(across == 48 && std::fabs(area - 12.0) < 1e-6 && plane_ok,
			"seam: coarse face enumerates the 48 free fine faces (12 m^2) at x = 0 (got " + std::to_string(across) + ")");
	CellId right;
	s.locate(v3(0.25, 4.25, 4.25), right);
	s.neighbours(right, faces);
	bool back = false;
	for (const Face &f : faces)
		if (f.to.tx == -1 && f.to.level == 0 && f.to.coarse == left.coarse &&
				f.overlap.max.y - f.overlap.min.y == 0.5f && f.overlap.max.z - f.overlap.min.z == 0.5f)
			back = true;
	check(back, "seam: fine cell links back to the coarse cell with its own 0.5 m face");
	std::vector<AirTileSpace::Link> links;
	s.tile_links({-1, 0, 0}, links);
	check(links.size() == 1 && links[0].to == TileKey{0, 0, 0} && links[0].side == 1, "seam: one component link across the tile face");
	check_neighbour_geometry(s, "seam");
	// Blocked diagonal: two solid cells meeting at an edge leave no corner-cutting link.
	AirTileSpace d;
	std::vector<uint8_t> grid(TILE_FINE_CELLS, uint8_t(Cell::FREE));
	grid[size_t(11 + 64 * (10 + 64 * 10))] = uint8_t(Cell::SOLID);
	grid[size_t(10 + 64 * (11 + 64 * 10))] = uint8_t(Cell::SOLID);
	d.publish(make_tile({0, 0, 0}, grid.data(), 0));
	CellId corner;
	d.locate(v3(5.25, 5.25, 5.25), corner);
	d.neighbours(corner, faces);
	bool diagonal = false;
	for (const Face &f : faces) {
		const Aabb box = d.bounds(f.to);
		diagonal = diagonal || (box.min.x == 5.5f && box.min.y == 5.5f);
	}
	check(faces.size() == 4 && !diagonal, "blocked diagonal: only the 4 open faces, no corner-cutting neighbour");
}

void test_unknown() {
	GeometrySet g;
	AirTileSpace s;
	s.publish(bake({0, 0, 0}, g, 0.5f, false, false));
	check(at(s, 5, 5, 5) == Cell::FREE, "unknown: present empty tile FREE");
	check(at(s, 40, 5, 5) == Cell::UNKNOWN && at(s, -0.01, 5, 5) == Cell::UNKNOWN, "unknown: points in missing tiles UNKNOWN");
	CellId c;
	check(!s.locate(v3(40, 5, 5), c) && c.tx == 1, "unknown: locate fails for a missing tile but names it");
	check(s.tile_revision(1, 0, 0) == 0 && s.tile_revision(0, 0, 0) > 0, "unknown: missing tile revision 0");
	check(at(s, NAN, 5, 5) == Cell::UNKNOWN, "unknown: NaN UNKNOWN");
	CellId edge{0, 0, 0, uint16_t(7 + 8 * (3 + 8 * 3)), 0, 0};
	std::vector<Face> faces;
	s.neighbours(edge, faces);
	bool outward = false;
	for (const Face &f : faces) outward = outward || f.to.tx != 0;
	check(faces.size() == 5 && !outward, "unknown: no neighbour across the face toward a missing tile");
	check(s.state(CellId{3, 3, 3, 0, 0, 0}) == Cell::UNKNOWN, "unknown: state of a missing tile UNKNOWN");
	CellId inner{0, 0, 0, uint16_t(3 + 8 * (3 + 8 * 3)), 0, 0};
	check(s.touches_unknown(edge) && !s.touches_unknown(inner) && s.touches_unknown(CellId{3, 3, 3, 0, 0, 0}),
			"unknown: touches_unknown on a cell facing a missing tile, not on an interior cell");
	AirTileSpace pair;
	pair.publish(bake({0, 0, 0}, g, 0.5f, false, false));
	pair.publish(bake({1, 0, 0}, g, 0.5f, false, false));
	CellId fine_edge{0, 0, 0, uint16_t(7 + 8 * (3 + 8 * 3)), uint16_t(7 + 8 * (3 + 8 * 3)), 1};
	check(!pair.touches_unknown(edge) && pair.touches_unknown(CellId{0, 0, 0, 0, 0, 0}) &&
					pair.touches_unknown(fine_edge) == pair.AirSpace::touches_unknown(edge),
			"unknown: touches_unknown sees the present neighbour tile and agrees with the generic probe");
	AirTileSpace open;
	open.publish(bake({0, 0, 0}, g, 0.5f, false, false));
	check(open.seal_enclosed(open.keys()) == 0 && at(open, 5, 5, 5) == Cell::FREE, "unknown: free space touching unknown is never sealed");
}

std::vector<uint8_t> geometry_file(const GeometrySet &g, int tx, int tz) {
	std::vector<uint8_t> out;
	auto put = [&](const void *p, size_t n) { out.insert(out.end(), (const uint8_t *)p, (const uint8_t *)p + n); };
	auto u32 = [&](uint32_t v) { put(&v, 4); };
	auto f32 = [&](float v) { put(&v, 4); };
	put("HEAIRGEO", 8);
	u32(1);
	u32(uint32_t(tx));
	u32(uint32_t(tz));
	f32(32.0f);
	f32(8.0f);
	u32(uint32_t(g.soups.size() + g.convexes.size() + g.fields.size()));
	for (const TriangleSoup &s : g.soups) {
		const uint8_t head[4] = {1, uint8_t(s.cls), 0, 0};
		put(head, 4);
		u32(uint32_t(s.triangle_count()));
		put(s.xyz.data(), s.xyz.size() * 4);
	}
	for (const ConvexSolid &c : g.convexes) {
		const uint8_t head[4] = {2, uint8_t(c.cls), 0, 0};
		put(head, 4);
		u32(uint32_t(c.points.size()));
		for (const Vec3 &p : c.points) { f32(p.x); f32(p.y); f32(p.z); }
	}
	for (const HeightField &f : g.fields) {
		const uint8_t head[4] = {3, uint8_t(f.cls), 0, 0};
		put(head, 4);
		u32(uint32_t(f.heights.size()));
		f32(float(f.x0)); f32(float(f.z0)); f32(float(f.dx)); f32(float(f.dz));
		u32(uint32_t(f.w)); u32(uint32_t(f.d));
		put(f.heights.data(), f.heights.size() * 4);
	}
	return out;
}

void test_serialization(const std::string &dir) {
	GeometrySet g;
	g.fields.push_back(field(-40, -8, 121, 81, hills));
	TriangleSoup box;
	const double mn[3] = {8, 20, 8}, mx[3] = {20, 30, 20};
	add_box_shell(box, mn, mx);
	g.soups.push_back(box);
	g.convexes.push_back(ConvexSolid{});
	g.convexes.back().points = prism(0.5, 10, 20, 8);
	for (Vec3 &p : g.convexes.back().points) p.x += 40, p.z += 40;
	g.source_hash = 0x1234;
	AirTileSpace s(AirProfile{"pegasus_test", 0.75f, {0.0f, 0.8f, 0.0f}});
	for (int ty : {-1, 0, 1})
		for (int tx : {-1, 0, 1}) s.publish(bake({tx, ty, 0}, g, 0.75f, false, true));
	s.seal_enclosed(s.keys());
	std::vector<uint8_t> bytes;
	check(write_air_data(s, 0xabcdef, bytes), "serialize: write");
	AirTileSpace r;
	AirDataInfo info;
	std::string err;
	check(read_air_data(bytes.data(), bytes.size(), r, &info, &err), "serialize: read back (" + err + ")");
	bool same = r.tile_count() == s.tile_count() && info.source_hash == 0xabcdef && r.profile().name == "pegasus_test" &&
			r.profile().envelope_radius == 0.75f && r.profile().centre_offset.y == 0.8f && info.version == AIR_DATA_VERSION;
	bool revisions_new = true;
	for (const TileKey &k : s.keys()) {
		const AirTile *a = s.find(k), *b = r.find(k);
		same = same && b && a->uniform == b->uniform && a->coarse == b->coarse && a->bricks == b->bricks &&
				a->source_hash == b->source_hash && a->component_count == b->component_count;
		revisions_new = revisions_new && b && b->revision > a->revision;
	}
	check(same, "serialize: round trip keeps keys, arrays, hashes, profile, components");
	check(revisions_new, "serialize: loaded tiles get fresh revisions");
	std::mt19937 rng(3);
	std::uniform_real_distribution<double> u(-40.0, 70.0);
	size_t diff = 0;
	for (int i = 0; i < 20000; ++i) {
		const Vec3 p = v3(u(rng), u(rng) - 15, u(rng) * 0.4);
		if (s.sample(p) != r.sample(p)) ++diff;
	}
	check(diff == 0, "serialize: 20000 samples identical after round trip");
	std::vector<uint8_t> bad = bytes;
	bad[bad.size() / 2] ^= 0x10;
	AirTileSpace t1;
	check(!read_air_data(bad.data(), bad.size(), t1, nullptr, &err) && t1.tile_count() == 0, "serialize: flipped byte rejected (" + err + ")");
	AirTileSpace t2;
	check(!read_air_data(bytes.data(), bytes.size() - 9, t2, nullptr, &err) && t2.tile_count() == 0, "serialize: truncated file rejected");
	bad = bytes;
	bad[8] = 9;  // version
	const uint64_t sum = fnv1a(bad.data(), bad.size() - 8);
	std::memcpy(&bad[bad.size() - 8], &sum, 8);
	AirTileSpace t3;
	check(!read_air_data(bad.data(), bad.size(), t3, nullptr, &err) && err.find("version") != std::string::npos,
			"serialize: unknown version rejected");
	const std::string path = dir + "/round_trip.airnav";
	std::vector<uint8_t> loaded;
	check(save_file(path, bytes, &err) && load_file(path, loaded, &err) && loaded == bytes, "serialize: file save/load identical");
	bool clean = true;
	const std::string needle = "/home";
	clean = std::search(bytes.begin(), bytes.end(), needle.begin(), needle.end()) == bytes.end();
	check(clean, "serialize: data carries no machine path");
	// Extracted geometry column format.
	std::vector<uint8_t> col = geometry_file(g, -1, 0);
	GeometryColumn gc;
	check(read_geometry_column(col.data(), col.size(), gc, &err) && gc.tx == -1 && gc.tz == 0 && gc.triangles == 12 &&
					gc.convexes == 1 && gc.fields == 1 && gc.geometry.fields[0].heights == g.fields[0].heights &&
					gc.geometry.soups[0].xyz == box.xyz,
			"geometry column: read back equal (" + err + ")");
	check(!read_geometry_column(col.data(), col.size() - 3, gc, &err), "geometry column: truncated rejected");
}

void test_dirty_rebuild() {
	GeometrySet g;
	g.fields.push_back(field(-8, -8, 81, 49, flat0));
	BakeParams p;
	p.envelope_radius = 0.5f;
	AirTileSpace s(AirProfile{"rebuild", 0.5f, {0, 0, 0}});
	s.publish(bake({0, 0, 0}, g, 0.5f, false, true));
	s.publish(bake({1, 0, 0}, g, 0.5f, false, true));
	const uint64_t r0 = s.tile_revision(0, 0, 0), r1 = s.tile_revision(1, 0, 0);
	check(at(s, 16.25, 10.25, 16.25) == Cell::FREE, "rebuild: air FREE before the obstacle");
	GeometrySet g2 = g;
	TriangleSoup post;
	const double mn[3] = {15, 0, 15}, mx[3] = {17.5, 20, 17.5};
	add_box_shell(post, mn, mx);
	g2.soups.push_back(post);
	g2.source_hash = 99;
	const size_t changed = rebuild_tiles(s, {{0, 0, 0}}, g2, p);
	check(changed == 1 && s.tile_revision(0, 0, 0) > r0, "rebuild: dirty tile republished with a higher revision");
	check(s.tile_revision(1, 0, 0) == r1, "rebuild: untouched neighbour keeps its revision");
	check(at(s, 16.25, 10.25, 16.25) == Cell::SOLID, "rebuild: new obstacle (sealed hollow post) SOLID");
	check(s.find({0, 0, 0})->source_hash == 99, "rebuild: tile records the new source hash");
	GeometrySet none;
	rebuild_tiles(s, {{1, 0, 0}}, none, p);
	check(s.tile_revision(1, 0, 0) == 0 && at(s, 40, 10, 16) == Cell::UNKNOWN, "rebuild: tile without terrain data removed (UNKNOWN)");
}

void test_memory() {
	GeometrySet g;
	AirTileSpace s;
	s.publish(bake({0, 0, 0}, g, 0.5f, false, false));
	const AirTile *t = s.find({0, 0, 0});
	check(t->uniform == uint8_t(Cell::FREE) && t->coarse.empty() && t->bricks.empty() && t->memory_bytes() < 512,
			"memory: empty sky tile stores no arrays (" + std::to_string(t->memory_bytes()) + " B)");
}

}  // namespace

int main(int argc, char **argv) {
	const std::string dir = argc > 1 ? argv[1] : ".";
	test_sat();
	test_thin_wall();
	test_low_ceiling();
	test_closed_box();
	test_terrain_fill();
	test_instanced_tree();
	test_mixed_resolution_seam();
	test_unknown();
	test_serialization(dir);
	test_dirty_rebuild();
	test_memory();
	std::printf("AIR_STORAGE_TESTS %s (%d checks, %d failures)\n", g_failures ? "FAIL" : "PASS", g_checks, g_failures);
	return g_failures ? 1 : 0;
}
