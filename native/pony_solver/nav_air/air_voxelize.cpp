// Conservative voxelization, envelope inflation and tile (re)baking (see air_voxelize.h).
// Written for this project; the triangle/box test follows the published separating-axis
// method (Akenine-Moller 2001) and the distance transform the published lower-envelope
// method (Felzenszwalb & Huttenlocher 2012). No third-party source is copied here
// (native/pony_solver/nav_air/PROVENANCE.md).
#include "air_voxelize.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <unordered_set>
#include <utility>

namespace nav_air {

namespace {

inline void sub(const double a[3], const double b[3], double o[3]) {
	o[0] = a[0] - b[0];
	o[1] = a[1] - b[1];
	o[2] = a[2] - b[2];
}
inline double dot(const double a[3], const double b[3]) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
inline void cross(const double a[3], const double b[3], double o[3]) {
	o[0] = a[1] * b[2] - a[2] * b[1];
	o[1] = a[2] * b[0] - a[0] * b[2];
	o[2] = a[0] * b[1] - a[1] * b[0];
}

// Dense working grid over a tile plus margin.
struct Region {
	int m = 0, n = 0;  // margin cells, cells per axis (64 + 2m)
	int64_t g0[3] = {0, 0, 0};  // global fine index of cell (0, 0, 0)
	std::vector<uint8_t> cells;  // n^3, index x + n * (y + n * z); 0 free, 1 solid
	size_t at(int x, int y, int z) const { return size_t(x) + size_t(n) * (size_t(y) + size_t(n) * size_t(z)); }
	double lo(int axis, int i) const { return double(g0[axis] + i) * FINE_SIZE; }
	// Index range of cells whose closed box (grown by eps) touches [mn, mx] on `axis`.
	bool range(int axis, double mn, double mx, double eps, int &a, int &b) const {
		const double h = FINE_SIZE;
		const int64_t ia = int64_t(std::floor((mn - eps) / h)) - g0[axis];
		const int64_t ib = int64_t(std::floor((mx + eps) / h)) - g0[axis];
		if (ib < 0 || ia > n - 1) return false;
		a = int(std::max<int64_t>(ia, 0));
		b = int(std::min<int64_t>(ib, n - 1));
		return a <= b;
	}
};

void fill_heightfields(Region &r, const std::vector<HeightField> &fields, double eps, size_t &uncovered) {
	const double h = FINE_SIZE;
	for (int k = 0; k < r.n; ++k)
		for (int i = 0; i < r.n; ++i) {
			const double xa = r.lo(0, i), xb = xa + h, za = r.lo(2, k), zb = za + h;
			double top = -std::numeric_limits<double>::infinity();
			bool covered = false;
			for (const HeightField &f : fields) {
				if (f.w < 2 || f.d < 2 || f.heights.size() != size_t(f.w) * size_t(f.d)) continue;
				const double fx1 = f.x0 + (f.w - 1) * f.dx, fz1 = f.z0 + (f.d - 1) * f.dz;
				if (xb + eps < f.x0 || xa - eps > fx1 || zb + eps < f.z0 || za - eps > fz1) continue;
				if (xa >= f.x0 - 1e-6 && xb <= fx1 + 1e-6 && za >= f.z0 - 1e-6 && zb <= fz1 + 1e-6) covered = true;
				// Every vertex of every quad touching the closed column footprint: the surface
				// over a quad never exceeds its highest vertex, whichever diagonal is used.
				const int i0 = std::max(0, int(std::floor((xa - eps - f.x0) / f.dx)));
				const int i1 = std::min(f.w - 1, int(std::ceil((xb + eps - f.x0) / f.dx)));
				const int j0 = std::max(0, int(std::floor((za - eps - f.z0) / f.dz)));
				const int j1 = std::min(f.d - 1, int(std::ceil((zb + eps - f.z0) / f.dz)));
				for (int j = j0; j <= j1; ++j)
					for (int q = i0; q <= i1; ++q) {
						const float y = f.heights[size_t(q) + size_t(f.w) * size_t(j)];
						if (std::isfinite(y)) top = std::max(top, double(y));
					}
			}
			if (!covered) ++uncovered;
			if (!std::isfinite(top)) continue;
			const int64_t jt = int64_t(std::floor((top + eps) / h)) - r.g0[1];
			const int last = int(std::min<int64_t>(jt, r.n - 1));
			for (int j = 0; j <= last; ++j) r.cells[r.at(i, j, k)] = 1;
		}
}

void mark_triangle(Region &r, const double t[9], double eps) {
	int lo[3], hi[3];
	for (int a = 0; a < 3; ++a) {
		const double mn = std::min(t[a], std::min(t[3 + a], t[6 + a]));
		const double mx = std::max(t[a], std::max(t[3 + a], t[6 + a]));
		if (!r.range(a, mn, mx, eps, lo[a], hi[a])) return;
	}
	double e1[3], e2[3], nrm[3];
	sub(t + 3, t, e1);
	sub(t + 6, t, e2);
	cross(e1, e2, nrm);
	const double len = std::sqrt(dot(nrm, nrm));
	const bool plane = len > 1e-12;
	if (plane)
		for (double &v : nrm) v /= len;
	const double half = 0.5 * FINE_SIZE + eps;
	const double hh[3] = {half, half, half};
	const double reach = half * (std::fabs(nrm[0]) + std::fabs(nrm[1]) + std::fabs(nrm[2]));
	for (int z = lo[2]; z <= hi[2]; ++z)
		for (int y = lo[1]; y <= hi[1]; ++y)
			for (int x = lo[0]; x <= hi[0]; ++x) {
				uint8_t &cell = r.cells[r.at(x, y, z)];
				if (cell) continue;
				const double c[3] = {r.lo(0, x) + 0.5 * FINE_SIZE, r.lo(1, y) + 0.5 * FINE_SIZE, r.lo(2, z) + 0.5 * FINE_SIZE};
				if (plane) {
					double rel[3];
					sub(c, t, rel);
					if (std::fabs(dot(nrm, rel)) > reach) continue;
				}
				if (triangle_box_overlap(c, hh, t)) cell = 1;
			}
}

void mark_convex(Region &r, const ConvexSolid &s, double eps) {
	int lo[3], hi[3];
	for (int a = 0; a < 3; ++a)
		if (!r.range(a, s.box_min[a], s.box_max[a], eps, lo[a], hi[a])) return;
	if (s.box_fallback) {
		for (int z = lo[2]; z <= hi[2]; ++z)
			for (int y = lo[1]; y <= hi[1]; ++y)
				for (int x = lo[0]; x <= hi[0]; ++x) r.cells[r.at(x, y, z)] = 1;
		return;
	}
	const double half = 0.5 * FINE_SIZE + eps;
	const double hh[3] = {half, half, half};
	for (int z = lo[2]; z <= hi[2]; ++z)
		for (int y = lo[1]; y <= hi[1]; ++y)
			for (int x = lo[0]; x <= hi[0]; ++x) {
				uint8_t &cell = r.cells[r.at(x, y, z)];
				if (cell) continue;
				const double c[3] = {r.lo(0, x) + 0.5 * FINE_SIZE, r.lo(1, y) + 0.5 * FINE_SIZE, r.lo(2, z) + 0.5 * FINE_SIZE};
				bool outside = false, inside = true, centre_in = true;
				for (const auto &p : s.planes) {
					const double dist = p[0] * c[0] + p[1] * c[1] + p[2] * c[2] - p[3];
					const double reach = half * (std::fabs(p[0]) + std::fabs(p[1]) + std::fabs(p[2]));
					if (dist > reach) { outside = true; break; }
					if (dist > -reach) inside = false;
					if (dist > 0) centre_in = false;
				}
				if (outside) continue;
				if (inside) { cell = 1; continue; }
				bool hit = false;
				for (const auto &t : s.triangles)
					if (triangle_box_overlap(c, hh, t.data())) { hit = true; break; }
				// No boundary in the box: it is wholly inside or wholly outside; the centre decides.
				if (hit || centre_in) cell = 1;
			}
}

// Squared distance transform of one line (lower envelope of parabolas). f: input, d: output.
void dt_line(const double *f, int n, double *d, int *v, double *z) {
	int k = 0;
	v[0] = 0;
	z[0] = -std::numeric_limits<double>::infinity();
	z[1] = std::numeric_limits<double>::infinity();
	auto meet = [&](int q, int p) { return ((f[q] + double(q) * q) - (f[p] + double(p) * p)) / (2.0 * q - 2.0 * p); };
	for (int q = 1; q < n; ++q) {
		// f is finite (BIG stands for "no solid"), so s is finite and z[0] = -inf stops the walk.
		double s = meet(q, v[k]);
		while (s <= z[k]) {
			--k;
			s = meet(q, v[k]);
		}
		++k;
		v[k] = q;
		z[k] = s;
		z[k + 1] = std::numeric_limits<double>::infinity();
	}
	k = 0;
	for (int q = 0; q < n; ++q) {
		while (z[k + 1] < q) ++k;
		const double dq = double(q - v[k]);
		d[q] = dq * dq + f[v[k]];
	}
}

// Cells within `radius` (box-to-box) of a raw solid cell become solid; output is the inner
// 64^3 of the region as Cell values.
void inflate(const Region &r, double radius, std::vector<uint8_t> &out) {
	const int n = r.n;
	const size_t total = size_t(n) * n * n;
	// Grow by one cell (Chebyshev): box-to-box distance of cells u, v equals the distance
	// between u and the 3x3x3 block around v, in cell units.
	std::vector<uint8_t> grown(r.cells), tmp(total);
	for (int axis = 0; axis < 3; ++axis) {
		tmp = grown;
		const size_t stride = axis == 0 ? 1 : (axis == 1 ? size_t(n) : size_t(n) * n);
		for (int z = 0; z < n; ++z)
			for (int y = 0; y < n; ++y)
				for (int x = 0; x < n; ++x) {
					const int i = axis == 0 ? x : (axis == 1 ? y : z);
					const size_t at = r.at(x, y, z);
					if (tmp[at]) continue;
					if ((i > 0 && tmp[at - stride]) || (i < n - 1 && tmp[at + stride])) grown[at] = 1;
				}
	}
	const double BIG = 1e12;
	std::vector<double> dist(total);
	for (size_t i = 0; i < total; ++i) dist[i] = grown[i] ? 0.0 : BIG;
	const size_t len = size_t(n);
	std::vector<double> f(len), d(len), zz(len + 1);
	std::vector<int> v(len);
	for (int axis = 0; axis < 3; ++axis) {
		const size_t stride = axis == 0 ? 1 : (axis == 1 ? size_t(n) : size_t(n) * n);
		for (int b = 0; b < n; ++b)
			for (int a = 0; a < n; ++a) {
				size_t start;
				if (axis == 0) start = r.at(0, a, b);
				else if (axis == 1) start = r.at(a, 0, b);
				else start = r.at(a, b, 0);
				for (int i = 0; i < n; ++i) f[size_t(i)] = dist[start + size_t(i) * stride];
				dt_line(f.data(), n, d.data(), v.data(), zz.data());
				for (int i = 0; i < n; ++i) dist[start + size_t(i) * stride] = d[size_t(i)];
			}
	}
	const double cells = radius / double(FINE_SIZE);
	const double limit = cells * cells + 1e-9;
	out.resize(TILE_FINE_CELLS);
	for (int z = 0; z < TILE_FINE; ++z)
		for (int y = 0; y < TILE_FINE; ++y)
			for (int x = 0; x < TILE_FINE; ++x) {
				const double q = dist[r.at(x + r.m, y + r.m, z + r.m)];
				out[size_t(x) + TILE_FINE * (size_t(y) + TILE_FINE * size_t(z))] =
						uint8_t(q <= limit ? Cell::SOLID : Cell::FREE);
			}
}

}  // namespace

const char *source_class_name(SourceClass c) {
	switch (c) {
		case SourceClass::TERRAIN: return "terrain";
		case SourceClass::BUILDING: return "building";
		case SourceClass::STRUCTURE: return "structure";
		case SourceClass::CLOUD: return "cloud";
		case SourceClass::FOLIAGE_TRUNK: return "foliage_trunk";
		case SourceClass::FOLIAGE_CROWN: return "foliage_crown";
		default: return "other";
	}
}

bool triangle_box_overlap(const double centre[3], const double half[3], const double tri[9]) {
	double v0[3], v1[3], v2[3];
	sub(tri, centre, v0);
	sub(tri + 3, centre, v1);
	sub(tri + 6, centre, v2);
	double e[3][3];
	sub(v1, v0, e[0]);
	sub(v2, v1, e[1]);
	sub(v0, v2, e[2]);
	// Nine axes: box axis x triangle edge.
	for (int i = 0; i < 3; ++i) {
		for (int k = 0; k < 3; ++k) {
			double axis[3] = {0, 0, 0};
			const double unit[3] = {double(k == 0), double(k == 1), double(k == 2)};
			cross(unit, e[i], axis);
			const double p0 = dot(v0, axis), p1 = dot(v1, axis), p2 = dot(v2, axis);
			const double r = half[0] * std::fabs(axis[0]) + half[1] * std::fabs(axis[1]) + half[2] * std::fabs(axis[2]);
			const double mn = std::min(p0, std::min(p1, p2)), mx = std::max(p0, std::max(p1, p2));
			if (mn > r || mx < -r) return false;
		}
	}
	// Box face normals.
	for (int a = 0; a < 3; ++a) {
		const double mn = std::min(v0[a], std::min(v1[a], v2[a])), mx = std::max(v0[a], std::max(v1[a], v2[a]));
		if (mn > half[a] || mx < -half[a]) return false;
	}
	// Triangle plane.
	double nrm[3];
	cross(e[0], e[1], nrm);
	const double dist = dot(nrm, v0);
	const double r = half[0] * std::fabs(nrm[0]) + half[1] * std::fabs(nrm[1]) + half[2] * std::fabs(nrm[2]);
	return std::fabs(dist) <= r;
}

double point_triangle_distance(const double p[3], const double tri[9]) {
	// Closest point on a triangle (Voronoi region walk).
	const double *a = tri, *b = tri + 3, *c = tri + 6;
	double ab[3], ac[3], ap[3], q[3];
	sub(b, a, ab);
	sub(c, a, ac);
	sub(p, a, ap);
	const double d1 = dot(ab, ap), d2 = dot(ac, ap);
	auto dist_to = [&](const double x[3]) {
		double t[3];
		sub(p, x, t);
		return std::sqrt(dot(t, t));
	};
	if (d1 <= 0 && d2 <= 0) return dist_to(a);
	double bp[3];
	sub(p, b, bp);
	const double d3 = dot(ab, bp), d4 = dot(ac, bp);
	if (d3 >= 0 && d4 <= d3) return dist_to(b);
	const double vc = d1 * d4 - d3 * d2;
	if (vc <= 0 && d1 >= 0 && d3 <= 0) {
		const double t = d1 / (d1 - d3);
		for (int i = 0; i < 3; ++i) q[i] = a[i] + t * ab[i];
		return dist_to(q);
	}
	double cp[3];
	sub(p, c, cp);
	const double d5 = dot(ab, cp), d6 = dot(ac, cp);
	if (d6 >= 0 && d5 <= d6) return dist_to(c);
	const double vb = d5 * d2 - d1 * d6;
	if (vb <= 0 && d2 >= 0 && d6 <= 0) {
		const double t = d2 / (d2 - d6);
		for (int i = 0; i < 3; ++i) q[i] = a[i] + t * ac[i];
		return dist_to(q);
	}
	const double va = d3 * d6 - d5 * d4;
	if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
		const double t = (d4 - d3) / ((d4 - d3) + (d5 - d6));
		for (int i = 0; i < 3; ++i) q[i] = b[i] + t * (c[i] - b[i]);
		return dist_to(q);
	}
	const double denom = 1.0 / (va + vb + vc);
	const double v = vb * denom, w = vc * denom;
	for (int i = 0; i < 3; ++i) q[i] = a[i] + ab[i] * v + ac[i] * w;
	return dist_to(q);
}

// ---------------------------------------------------------------- convex hull

void ConvexSolid::prepare() {
	triangles.clear();
	planes.clear();
	box_fallback = false;
	prepared = true;
	const size_t n = points.size();
	for (int a = 0; a < 3; ++a) {
		box_min[a] = std::numeric_limits<double>::infinity();
		box_max[a] = -std::numeric_limits<double>::infinity();
	}
	std::vector<std::array<double, 3>> p(n);
	for (size_t i = 0; i < n; ++i) {
		p[i] = {double(points[i].x), double(points[i].y), double(points[i].z)};
		for (int a = 0; a < 3; ++a) {
			box_min[a] = std::min(box_min[a], p[i][size_t(a)]);
			box_max[a] = std::max(box_max[a], p[i][size_t(a)]);
		}
	}
	if (n == 0) {
		box_fallback = true;  // empty: range() rejects an inverted box
		return;
	}
	double extent = 0;
	for (int a = 0; a < 3; ++a) extent = std::max(extent, box_max[a] - box_min[a]);
	const double eps = 1e-9 + 1e-7 * extent;
	if (n < 4 || extent < 1e-6) {
		box_fallback = true;
		return;
	}
	// Initial tetrahedron from extreme points.
	size_t i0 = 0;
	for (size_t i = 1; i < n; ++i)
		if (p[i][0] < p[i0][0]) i0 = i;
	auto d2 = [&](size_t a, size_t b) {
		double s = 0;
		for (int k = 0; k < 3; ++k) s += (p[a][size_t(k)] - p[b][size_t(k)]) * (p[a][size_t(k)] - p[b][size_t(k)]);
		return s;
	};
	size_t i1 = i0;
	for (size_t i = 0; i < n; ++i)
		if (d2(i, i0) > d2(i1, i0)) i1 = i;
	double u[3];
	sub(p[i1].data(), p[i0].data(), u);
	size_t i2 = i0;
	double best = 0;
	for (size_t i = 0; i < n; ++i) {
		double w[3], c[3];
		sub(p[i].data(), p[i0].data(), w);
		cross(u, w, c);
		const double s = dot(c, c);
		if (s > best) best = s, i2 = i;
	}
	double w2[3], nrm0[3];
	sub(p[i2].data(), p[i0].data(), w2);
	cross(u, w2, nrm0);
	const double nlen = std::sqrt(dot(nrm0, nrm0));
	if (nlen < eps * extent) {
		box_fallback = true;
		return;
	}
	size_t i3 = i0;
	best = 0;
	for (size_t i = 0; i < n; ++i) {
		double w[3];
		sub(p[i].data(), p[i0].data(), w);
		const double s = std::fabs(dot(w, nrm0)) / nlen;
		if (s > best) best = s, i3 = i;
	}
	if (best < eps) {
		box_fallback = true;  // flat: its AABB is a thin, conservative slab
		return;
	}
	double interior[3];
	for (int k = 0; k < 3; ++k)
		interior[k] = (p[i0][size_t(k)] + p[i1][size_t(k)] + p[i2][size_t(k)] + p[i3][size_t(k)]) * 0.25;
	struct F {
		size_t a, b, c;
		double n[3], d;
		bool alive;
	};
	std::vector<F> faces;
	auto add_face = [&](size_t a, size_t b, size_t c) {
		F f{a, b, c, {0, 0, 0}, 0, true};
		double e1[3], e2[3];
		sub(p[b].data(), p[a].data(), e1);
		sub(p[c].data(), p[a].data(), e2);
		cross(e1, e2, f.n);
		double len = std::sqrt(dot(f.n, f.n));
		if (len <= 0) len = 1;
		for (double &v : f.n) v /= len;
		double rel[3];
		sub(interior, p[a].data(), rel);
		if (dot(f.n, rel) > 0) {
			std::swap(f.b, f.c);
			for (double &v : f.n) v = -v;
		}
		f.d = dot(f.n, p[a].data());
		faces.push_back(f);
	};
	add_face(i0, i1, i2);
	add_face(i0, i1, i3);
	add_face(i0, i2, i3);
	add_face(i1, i2, i3);
	std::vector<std::pair<size_t, size_t>> edges, horizon;
	for (size_t i = 0; i < n; ++i) {
		if (i == i0 || i == i1 || i == i2 || i == i3) continue;
		edges.clear();
		for (F &f : faces) {
			if (!f.alive || dot(f.n, p[i].data()) - f.d <= eps) continue;
			f.alive = false;
			edges.emplace_back(f.a, f.b);
			edges.emplace_back(f.b, f.c);
			edges.emplace_back(f.c, f.a);
		}
		if (edges.empty()) continue;
		horizon.clear();
		for (const auto &e : edges) {
			bool shared = false;
			for (const auto &o : edges)
				if (o.first == e.second && o.second == e.first) { shared = true; break; }
			if (!shared) horizon.push_back(e);
		}
		for (const auto &e : horizon) add_face(e.first, e.second, i);
		if (faces.size() > 4 * n + 64) {  // drop dead faces now and then
			faces.erase(std::remove_if(faces.begin(), faces.end(), [](const F &f) { return !f.alive; }), faces.end());
		}
	}
	for (const F &f : faces) {
		if (!f.alive) continue;
		std::array<double, 9> t{};
		for (int k = 0; k < 3; ++k) {
			t[size_t(k)] = p[f.a][size_t(k)];
			t[size_t(3 + k)] = p[f.b][size_t(k)];
			t[size_t(6 + k)] = p[f.c][size_t(k)];
		}
		triangles.push_back(t);
		planes.push_back({f.n[0], f.n[1], f.n[2], f.d});
	}
	// Verify containment; any doubt falls back to the (larger) AABB.
	const double tol = 1e-4 + 1e-6 * extent;
	for (const auto &pt : p)
		for (const auto &pl : planes)
			if (pl[0] * pt[0] + pl[1] * pt[1] + pl[2] * pt[2] - pl[3] > tol) {
				box_fallback = true;
				triangles.clear();
				planes.clear();
				return;
			}
	// Planes are offset by the tolerance so points inside by rounding still count as inside.
	for (auto &pl : planes) pl[3] += tol;
}

void GeometrySet::prepare() {
	for (ConvexSolid &c : convexes)
		if (!c.prepared) c.prepare();
}

void add_instanced_convex(GeometrySet &set, SourceClass cls, const std::vector<Vec3> &prototype,
		const std::vector<float> &transforms) {
	for (size_t t = 0; t + 12 <= transforms.size(); t += 12) {
		const float *m = &transforms[t];
		ConvexSolid s;
		s.cls = cls;
		s.points.reserve(prototype.size());
		for (const Vec3 &q : prototype) {
			s.points.push_back({m[9] + m[0] * q.x + m[3] * q.y + m[6] * q.z, m[10] + m[1] * q.x + m[4] * q.y + m[7] * q.z,
					m[11] + m[2] * q.x + m[5] * q.y + m[8] * q.z});
		}
		set.convexes.push_back(std::move(s));
	}
}

// ---------------------------------------------------------------- baking

int margin_cells(float envelope_radius) {
	return int(std::floor(double(std::max(0.0f, envelope_radius)) / FINE_SIZE)) + 2;
}

double margin_metres(float envelope_radius) { return margin_cells(envelope_radius) * double(FINE_SIZE); }

std::shared_ptr<AirTile> bake_tile(const TileKey &key, const GeometrySet &geometry, const BakeParams &params,
		TileBakeStats *stats, std::string *why) {
	TileBakeStats local;
	TileBakeStats &st = stats ? *stats : local;
	Region r;
	r.m = params.raw_only ? 1 : margin_cells(params.envelope_radius);
	r.n = TILE_FINE + 2 * r.m;
	r.g0[0] = int64_t(key.x) * TILE_FINE - r.m;
	r.g0[1] = int64_t(key.y) * TILE_FINE - r.m;
	r.g0[2] = int64_t(key.z) * TILE_FINE - r.m;
	r.cells.assign(size_t(r.n) * r.n * r.n, 0);
	const double eps = params.box_epsilon;
	size_t uncovered = 0;
	fill_heightfields(r, geometry.fields, eps, uncovered);
	st.uncovered_columns += uncovered;
	if (params.require_terrain && uncovered) {
		if (why) *why = "terrain heightfield does not cover " + std::to_string(uncovered) + " columns";
		return nullptr;
	}
	for (const TriangleSoup &soup : geometry.soups) {
		const size_t count = soup.triangle_count();
		for (size_t i = 0; i < count; ++i) {
			double t[9];
			for (int k = 0; k < 9; ++k) t[k] = double(soup.xyz[i * 9 + size_t(k)]);
			bool finite = true;
			for (double v : t) finite = finite && std::isfinite(v);
			if (!finite) continue;
			++st.triangles_tested;
			mark_triangle(r, t, eps);
		}
	}
	for (const ConvexSolid &s : geometry.convexes) {
		if (!s.prepared) {
			if (why) *why = "convex solids not prepared";
			return nullptr;
		}
		++st.convexes_tested;
		mark_convex(r, s, eps);
	}
	size_t solid = 0;
	for (uint8_t c : r.cells) solid += c;
	st.raw_solid += solid;
	std::vector<uint8_t> out(TILE_FINE_CELLS);
	if (params.raw_only) {
		for (int z = 0; z < TILE_FINE; ++z)
			for (int y = 0; y < TILE_FINE; ++y)
				for (int x = 0; x < TILE_FINE; ++x)
					out[size_t(x) + TILE_FINE * (size_t(y) + TILE_FINE * size_t(z))] =
							uint8_t(r.cells[r.at(x + r.m, y + r.m, z + r.m)] ? Cell::SOLID : Cell::FREE);
	} else if (solid == 0) {
		std::memset(out.data(), uint8_t(Cell::FREE), out.size());
	} else if (solid == r.cells.size()) {
		std::memset(out.data(), uint8_t(Cell::SOLID), out.size());
	} else {
		inflate(r, params.envelope_radius, out);
	}
	for (uint8_t c : out) st.inflated_solid += c == uint8_t(Cell::SOLID);
	return make_tile(key, out.data(), geometry.source_hash);
}

size_t rebuild_tiles(AirTileSpace &space, const std::vector<TileKey> &dirty, const GeometrySet &geometry,
		const BakeParams &params) {
	size_t changed = 0;
	std::vector<TileKey> scope;
	std::unordered_set<TileKey, TileKeyHash> seen;
	for (const TileKey &key : dirty) {
		std::shared_ptr<AirTile> tile = bake_tile(key, geometry, params);
		if (tile) {
			space.publish(tile);
			++changed;
		} else if (space.remove(key)) {
			++changed;
		}
		const TileKey around[7] = {key, {key.x - 1, key.y, key.z}, {key.x + 1, key.y, key.z}, {key.x, key.y - 1, key.z},
			{key.x, key.y + 1, key.z}, {key.x, key.y, key.z - 1}, {key.x, key.y, key.z + 1}};
		for (const TileKey &k : around)
			if (space.find(k) && seen.insert(k).second) scope.push_back(k);
	}
	space.seal_enclosed(scope);
	return changed;
}

}  // namespace nav_air
