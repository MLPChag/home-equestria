// See air_shorten.h.
#include "air_shorten.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace nav_air {

namespace {

constexpr double EPS = 1.0e-6; // voxel units: closer than this to a grid plane counts as on it
constexpr double NUDGE = 1.0e-5; // a segment lying in a plane is walked on both sides of it
constexpr double PI = 3.14159265358979323846;

inline double vget(const double *v, int axis) {
	return v[axis];
}

inline float fget(const Vec3 &v, int axis) {
	return axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
}

Vec3 sub(const Vec3 &a, const Vec3 &b) {
	return Vec3{a.x - b.x, a.y - b.y, a.z - b.z};
}

Vec3 add(const Vec3 &a, const Vec3 &b) {
	return Vec3{a.x + b.x, a.y + b.y, a.z + b.z};
}

Vec3 scale(const Vec3 &a, float s) {
	return Vec3{a.x * s, a.y * s, a.z * s};
}

float dot(const Vec3 &a, const Vec3 &b) {
	return a.x * b.x + a.y * b.y + a.z * b.z;
}

float length(const Vec3 &a) {
	return std::sqrt(dot(a, a));
}

bool same_point(const Vec3 &a, const Vec3 &b) {
	return a.x == b.x && a.y == b.y && a.z == b.z;
}

// All voxels whose closed box contains P (1, 2, 4 or 8 of them).
bool visit_point(const double *P, float t, AirVoxelVisitor visit, void *ctx) {
	int64_t lo[3], hi[3];
	for (int axis = 0; axis < 3; ++axis) {
		const double n = std::round(P[axis]);
		if (std::fabs(P[axis] - n) <= EPS) {
			lo[axis] = int64_t(n) - 1;
			hi[axis] = int64_t(n);
		} else {
			lo[axis] = hi[axis] = int64_t(std::floor(P[axis]));
		}
	}
	for (int64_t z = lo[2]; z <= hi[2]; ++z) {
		for (int64_t y = lo[1]; y <= hi[1]; ++y) {
			for (int64_t x = lo[0]; x <= hi[0]; ++x) {
				if (!visit(ctx, int32_t(x), int32_t(y), int32_t(z), t)) {
					return false;
				}
			}
		}
	}
	return true;
}

// Amanatides-Woo walk that also reports the voxels touched where the segment crosses an edge or a
// corner (several axes reach their next plane at the same parameter).
bool supercover_core(const double *A, const double *B, AirVoxelVisitor visit, void *ctx) {
	if (!visit_point(A, 0.0f, visit, ctx)) {
		return false;
	}
	double D[3] = {B[0] - A[0], B[1] - A[1], B[2] - A[2]};
	const double len = std::sqrt(D[0] * D[0] + D[1] * D[1] + D[2] * D[2]);
	if (len <= EPS) {
		return visit_point(B, 1.0f, visit, ctx);
	}
	int64_t v[3];
	int step[3];
	double tmax[3], tdelta[3];
	double guard = 8.0;
	for (int axis = 0; axis < 3; ++axis) {
		const double a = A[axis], d = D[axis];
		guard += std::fabs(d) * 2.0 + 2.0;
		if (std::fabs(d) <= EPS) {
			step[axis] = 0;
			v[axis] = int64_t(std::floor(a));
			tmax[axis] = std::numeric_limits<double>::infinity();
			tdelta[axis] = std::numeric_limits<double>::infinity();
			continue;
		}
		const double n = std::round(a);
		if (std::fabs(a - n) <= EPS) {
			v[axis] = d > 0.0 ? int64_t(n) : int64_t(n) - 1;
		} else {
			v[axis] = int64_t(std::floor(a));
		}
		step[axis] = d > 0.0 ? 1 : -1;
		tmax[axis] = d > 0.0 ? (double(v[axis]) + 1.0 - a) / d : (a - double(v[axis])) / -d;
		tdelta[axis] = 1.0 / std::fabs(d);
	}
	const double teps = EPS / len;
	double t = 0.0;
	while (true) {
		if (!visit(ctx, int32_t(v[0]), int32_t(v[1]), int32_t(v[2]), float(t))) {
			return false;
		}
		const double tmin = std::min(tmax[0], std::min(tmax[1], tmax[2]));
		if (tmin > 1.0 + teps || (guard -= 1.0) < 0.0) {
			break;
		}
		int tied = 0;
		for (int axis = 0; axis < 3; ++axis) {
			if (tmax[axis] <= tmin + teps) {
				tied |= 1 << axis;
			}
		}
		// Voxels touched only along the crossed edge / at the crossed corner.
		for (int subset = 1; subset < tied; ++subset) {
			if ((subset & ~tied) != 0) {
				continue;
			}
			int64_t w[3] = {v[0], v[1], v[2]};
			for (int axis = 0; axis < 3; ++axis) {
				if (subset & (1 << axis)) {
					w[axis] += step[axis];
				}
			}
			if (!visit(ctx, int32_t(w[0]), int32_t(w[1]), int32_t(w[2]), float(tmin))) {
				return false;
			}
		}
		for (int axis = 0; axis < 3; ++axis) {
			if (tied & (1 << axis)) {
				v[axis] += step[axis];
				tmax[axis] += tdelta[axis];
			}
		}
		t = tmin;
	}
	return visit_point(B, 1.0f, visit, ctx);
}

bool segment_box(const Vec3 &a, const Vec3 &b, const double *lo, const double *hi) {
	double t0 = 0.0, t1 = 1.0;
	for (int axis = 0; axis < 3; ++axis) {
		const double s = fget(a, axis);
		const double d = double(fget(b, axis)) - s;
		if (std::fabs(d) < 1.0e-12) {
			if (s < lo[axis] || s > hi[axis]) {
				return false;
			}
			continue;
		}
		double ta = (lo[axis] - s) / d, tb = (hi[axis] - s) / d;
		if (ta > tb) {
			std::swap(ta, tb);
		}
		t0 = std::max(t0, ta);
		t1 = std::min(t1, tb);
		if (t0 > t1) {
			return false;
		}
	}
	return true;
}

struct ClearContext {
	const AirSpace *space;
	Vec3 a, b;
	float radius;
	int ring;
	AirSegmentCheck *info;
	int64_t last[3];
	bool has_last;
	uint32_t voxels;
	Cell blocking;
	Vec3 where;
	float t;
	// Last located leaf: a leaf has one state, so voxels inside it need no new lookup. Uses
	// state(leaf), which an overlaid space reports SOLID for any leaf a blocker meets.
	bool cached;
	Aabb cache_bounds;
	Cell cache_state;
};

bool check_voxel(ClearContext &c, int64_t x, int64_t y, int64_t z, float t) {
	const Vec3 centre{(float(x) + 0.5f) * AIR_FINE_SIZE, (float(y) + 0.5f) * AIR_FINE_SIZE, (float(z) + 0.5f) * AIR_FINE_SIZE};
	++c.voxels;
	Cell s;
	if (c.cached && centre.x > c.cache_bounds.min.x && centre.x < c.cache_bounds.max.x && centre.y > c.cache_bounds.min.y &&
			centre.y < c.cache_bounds.max.y && centre.z > c.cache_bounds.min.z && centre.z < c.cache_bounds.max.z) {
		s = c.cache_state;
	} else {
		CellId leaf;
		if (c.space->locate(centre, leaf)) {
			s = c.space->state(leaf);
			c.cached = true;
			c.cache_bounds = c.space->bounds(leaf);
			c.cache_state = s;
		} else {
			s = Cell::UNKNOWN;
		}
	}
	if (s != Cell::FREE) {
		c.blocking = s;
		c.where = centre;
		c.t = t;
		return false;
	}
	return true;
}

bool clear_visit(void *ctx, int32_t x, int32_t y, int32_t z, float t) {
	ClearContext &c = *static_cast<ClearContext *>(ctx);
	if (c.has_last && c.last[0] == x && c.last[1] == y && c.last[2] == z) {
		return true;
	}
	c.has_last = true;
	c.last[0] = x;
	c.last[1] = y;
	c.last[2] = z;
	if (c.ring == 0) {
		return check_voxel(c, x, y, z, t);
	}
	const double r = c.radius;
	for (int dz = -c.ring; dz <= c.ring; ++dz) {
		for (int dy = -c.ring; dy <= c.ring; ++dy) {
			for (int dx = -c.ring; dx <= c.ring; ++dx) {
				const int64_t w[3] = {int64_t(x) + dx, int64_t(y) + dy, int64_t(z) + dz};
				double lo[3], hi[3];
				for (int axis = 0; axis < 3; ++axis) {
					lo[axis] = double(w[axis]) * AIR_FINE_SIZE - r;
					hi[axis] = double(w[axis] + 1) * AIR_FINE_SIZE + r;
				}
				if (!segment_box(c.a, c.b, lo, hi)) {
					continue;
				}
				if (!check_voxel(c, w[0], w[1], w[2], t)) {
					return false;
				}
			}
		}
	}
	return true;
}

} // namespace

bool air_supercover(const Vec3 &a, const Vec3 &b, AirVoxelVisitor visit, void *ctx) {
	const double A[3] = {double(a.x) / AIR_FINE_SIZE, double(a.y) / AIR_FINE_SIZE, double(a.z) / AIR_FINE_SIZE};
	const double B[3] = {double(b.x) / AIR_FINE_SIZE, double(b.y) / AIR_FINE_SIZE, double(b.z) / AIR_FINE_SIZE};
	int planar[3];
	int count = 0;
	for (int axis = 0; axis < 3; ++axis) {
		const double n = std::round(vget(A, axis));
		if (std::fabs(B[axis] - A[axis]) <= EPS && std::fabs(A[axis] - n) <= EPS) {
			planar[count++] = axis;
		}
	}
	for (int combo = 0; combo < (1 << count); ++combo) {
		double a2[3] = {A[0], A[1], A[2]};
		double b2[3] = {B[0], B[1], B[2]};
		for (int k = 0; k < count; ++k) {
			const int axis = planar[k];
			const double plane = std::round(A[axis]);
			a2[axis] = b2[axis] = plane + (((combo >> k) & 1) ? NUDGE : -NUDGE);
		}
		if (!supercover_core(a2, b2, visit, ctx)) {
			return false;
		}
	}
	return true;
}

bool air_segment_clear(const AirSpace &space, const Vec3 &a, const Vec3 &b, float radius, AirSegmentCheck *info) {
	ClearContext c;
	c.space = &space;
	c.a = a;
	c.b = b;
	c.radius = std::max(0.0f, radius);
	c.ring = c.radius > 0.0f ? int(std::ceil(c.radius / AIR_FINE_SIZE)) : 0;
	c.info = info;
	c.has_last = false;
	c.voxels = 0;
	c.blocking = Cell::FREE;
	c.where = Vec3{0, 0, 0};
	c.t = 1.0f;
	c.cached = false;
	const bool clear = std::isfinite(a.x) && std::isfinite(a.y) && std::isfinite(a.z) && std::isfinite(b.x) &&
			std::isfinite(b.y) && std::isfinite(b.z) && air_supercover(a, b, clear_visit, &c);
	if (info != nullptr) {
		info->blocking = clear ? Cell::FREE : (c.blocking == Cell::FREE ? Cell::UNKNOWN : c.blocking);
		info->voxel_centre = c.where;
		info->t = clear ? 1.0f : c.t;
		info->voxels = c.voxels;
	}
	return clear;
}

bool air_polyline_clear(const AirSpace &space, const std::vector<Vec3> &points, const std::vector<float> &radii,
		AirSegmentCheck *info) {
	for (size_t i = 0; i + 1 < points.size(); ++i) {
		const float r = i < radii.size() ? radii[i] : 0.0f;
		if (!air_segment_clear(space, points[i], points[i + 1], r, info)) {
			return false;
		}
	}
	return true;
}

bool air_shorten(const AirSpace &space, const std::vector<Vec3> &in, std::vector<Vec3> &out, uint32_t lookahead_after_fail) {
	out.clear();
	if (in.empty()) {
		return true;
	}
	if (!air_polyline_clear(space, in, std::vector<float>())) {
		out = in;
		return false;
	}
	out.push_back(in[0]);
	size_t i = 0;
	while (i + 1 < in.size()) {
		size_t best = i + 1;
		uint32_t fails = 0;
		for (size_t j = i + 2; j < in.size(); ++j) {
			if (air_segment_clear(space, in[i], in[j])) {
				best = j;
				fails = 0;
			} else if (++fails > lookahead_after_fail) {
				break;
			}
		}
		out.push_back(in[best]);
		i = best;
	}
	return true;
}

bool air_smooth(const AirSpace &space, const std::vector<Vec3> &in, const AirSmoothOptions &options, AirSmoothPath &out) {
	out = AirSmoothPath();
	// Drop repeated points first.
	std::vector<Vec3> p;
	for (const Vec3 &v : in) {
		if (p.empty() || !same_point(p.back(), v)) {
			p.push_back(v);
		}
	}
	if (p.size() < 2) {
		out.points = p;
		out.sharp.assign(p.size(), 0);
		return true;
	}
	if (!air_polyline_clear(space, p, std::vector<float>())) {
		return false;
	}
	struct Fillet {
		bool ok = false;
		std::vector<Vec3> points; // A, chord points, B
		float radius = 0.0f; // certified swept half-size of its chords
	};
	std::vector<Fillet> fillets(p.size());
	for (size_t i = 1; i + 1 < p.size(); ++i) {
		const Vec3 in_dir = sub(p[i], p[i - 1]);
		const Vec3 out_dir = sub(p[i + 1], p[i]);
		const float l_in = length(in_dir), l_out = length(out_dir);
		const Vec3 u_in = scale(in_dir, 1.0f / l_in), u_out = scale(out_dir, 1.0f / l_out);
		const float c = std::max(-1.0f, std::min(1.0f, dot(u_in, u_out)));
		const float theta = std::acos(c);
		if (theta < 1.0e-4f) {
			continue; // straight through
		}
		const float half_tan = theta < float(PI) - 1.0e-3f ? std::tan(0.5f * theta) : 1.0e6f;
		float d = std::min(options.turn_radius * half_tan, 0.5f * std::min(l_in, l_out));
		for (uint32_t attempt = 0; attempt <= options.shrink_attempts && d > 1.0e-3f; ++attempt, d *= 0.5f) {
			const Vec3 A = sub(p[i], scale(u_in, d));
			const Vec3 B = add(p[i], scale(u_out, d));
			const uint32_t chords = std::max(2u, std::min(options.max_chords,
					uint32_t(std::ceil(2.0f * d / std::max(0.05f, options.max_chord_length)))));
			const Vec3 second = add(sub(A, scale(p[i], 2.0f)), B);
			const float sag = length(second) / (4.0f * float(chords) * float(chords)) + 1.0e-4f;
			std::vector<Vec3> pts;
			pts.push_back(A);
			for (uint32_t k = 1; k < chords; ++k) {
				const float t = float(k) / float(chords);
				const float s = 1.0f - t;
				pts.push_back(add(add(scale(A, s * s), scale(p[i], 2.0f * s * t)), scale(B, t * t)));
			}
			pts.push_back(B);
			bool ok = true;
			for (size_t k = 0; k + 1 < pts.size() && ok; ++k) {
				ok = air_segment_clear(space, pts[k], pts[k + 1], sag);
			}
			if (ok) {
				fillets[i].ok = true;
				fillets[i].points = pts;
				fillets[i].radius = sag;
				break;
			}
		}
	}
	out.points.push_back(p[0]);
	out.sharp.push_back(0);
	for (size_t i = 0; i + 1 < p.size(); ++i) {
		const Vec3 from = (i > 0 && fillets[i].ok) ? fillets[i].points.back() : p[i];
		const bool end_fillet = (i + 1 < p.size() - 1) && fillets[i + 1].ok;
		const Vec3 to = end_fillet ? fillets[i + 1].points.front() : p[i + 1];
		if (!same_point(from, to)) {
			// Straight piece: part of a certified segment; give it the most clearance that certifies.
			const float adjacent = std::max(i > 0 && fillets[i].ok ? fillets[i].radius : 0.0f,
					end_fillet ? fillets[i + 1].radius : 0.0f);
			const float wants[3] = {std::max(options.line_clearance, adjacent), adjacent, 0.0f};
			float clearance = 0.0f;
			for (float w : wants) {
				if (w <= 0.0f || air_segment_clear(space, from, to, w)) {
					clearance = w;
					break;
				}
			}
			out.points.push_back(to);
			out.clearance.push_back(clearance);
			out.sharp.push_back(0);
		}
		if (end_fillet) {
			const Fillet &f = fillets[i + 1];
			for (size_t k = 1; k < f.points.size(); ++k) {
				out.points.push_back(f.points[k]);
				out.clearance.push_back(f.radius);
				out.sharp.push_back(0);
			}
		} else if (i + 1 < p.size() - 1) {
			// Sharp corner at p[i + 1] (already pushed as `to`).
			bool corner = true;
			{
				const Vec3 u = sub(p[i + 1], p[i]);
				const Vec3 w = sub(p[i + 2], p[i + 1]);
				corner = dot(u, w) < length(u) * length(w) * (1.0f - 1.0e-8f);
			}
			out.sharp.back() = corner ? 1 : 0;
		}
	}
	return true;
}

bool air_validate_trajectory(const std::vector<Vec3> &points, const std::vector<float> &clearance,
		const AirFlightLimits &limits, float start_speed, float end_speed, AirTrajectoryReport &out) {
	out = AirTrajectoryReport();
	const size_t n = points.size();
	if (n < 2 || !(limits.max_speed > 0.0f) || !(limits.max_accel > 0.0f) || !(limits.max_brake > 0.0f) ||
			start_speed < 0.0f || end_speed < 0.0f) {
		out.verdict = AirTrajectoryVerdict::INVALID;
		return false;
	}
	std::vector<float> seg_len(n - 1), seg_cap(n - 1);
	for (size_t i = 0; i + 1 < n; ++i) {
		const Vec3 d = sub(points[i + 1], points[i]);
		const float l = length(d);
		seg_len[i] = l;
		float cap = limits.max_speed;
		if (l > 0.0f) {
			const float sin_pitch = d.y / l;
			if (sin_pitch > 1.0e-6f) {
				cap = std::min(cap, limits.max_climb_rate / sin_pitch);
			} else if (sin_pitch < -1.0e-6f) {
				cap = std::min(cap, limits.max_descent_rate / -sin_pitch);
			}
		}
		seg_cap[i] = std::max(0.0f, cap);
	}
	out.limit.assign(n, limits.max_speed);
	for (size_t i = 0; i < n; ++i) {
		float v = limits.max_speed;
		if (i > 0) {
			v = std::min(v, seg_cap[i - 1]);
		}
		if (i + 1 < n) {
			v = std::min(v, seg_cap[i]);
		}
		if (i > 0 && i + 1 < n && seg_len[i - 1] > 0.0f && seg_len[i] > 0.0f) {
			const Vec3 u = scale(sub(points[i], points[i - 1]), 1.0f / seg_len[i - 1]);
			const Vec3 w = scale(sub(points[i + 1], points[i]), 1.0f / seg_len[i]);
			const float theta = std::acos(std::max(-1.0f, std::min(1.0f, dot(u, w))));
			if (theta > 1.0e-4f) {
				float r_max = 0.0f;
				if (theta < float(PI) - 1.0e-3f) {
					const float clear_in = i - 1 < clearance.size() ? clearance[i - 1] : 0.0f;
					const float clear_out = i < clearance.size() ? clearance[i] : 0.0f;
					const float slack = std::max(limits.tracking_tolerance, std::min(clear_in, clear_out));
					const float half = 0.5f * theta;
					const float cut = 1.0f / std::cos(half) - 1.0f;
					const float fit = 0.5f * std::min(seg_len[i - 1], seg_len[i]) / std::tan(half);
					r_max = std::min(cut > 0.0f ? slack / cut : fit, fit);
				}
				// r = max(v^2 / a_lat, v / turn_rate) <= r_max
				const float by_accel = std::sqrt(std::max(0.0f, limits.max_lateral_accel * r_max));
				const float by_rate = limits.max_turn_rate * r_max;
				v = std::min(v, std::min(by_accel, by_rate));
			}
		}
		out.limit[i] = v;
	}
	out.speed = out.limit;
	out.speed[n - 1] = std::min(out.speed[n - 1], end_speed);
	// Backward pass (braking), then forward pass (acceleration) from the start speed.
	for (size_t k = n - 1; k > 0; --k) {
		const float reach = std::sqrt(out.speed[k] * out.speed[k] + 2.0f * limits.max_brake * seg_len[k - 1]);
		out.speed[k - 1] = std::min(out.speed[k - 1], reach);
	}
	if (start_speed > out.speed[0] + 1.0e-3f) {
		out.verdict = AirTrajectoryVerdict::TOO_FAST_AT_START;
		out.limiting_index = 0;
		return false;
	}
	out.speed[0] = std::min(out.speed[0], start_speed);
	for (size_t k = 0; k + 1 < n; ++k) {
		const float reach = std::sqrt(out.speed[k] * out.speed[k] + 2.0f * limits.max_accel * seg_len[k]);
		out.speed[k + 1] = std::min(out.speed[k + 1], reach);
	}
	float tightest = std::numeric_limits<float>::infinity();
	for (size_t i = 0; i < n; ++i) {
		if (out.limit[i] < tightest) {
			tightest = out.limit[i];
			out.limiting_index = uint32_t(i);
		}
	}
	if (limits.min_speed > 0.0f) {
		for (size_t i = 0; i < n; ++i) {
			const bool endpoint = (i == 0 && start_speed < limits.min_speed) || (i == n - 1 && end_speed < limits.min_speed);
			if (!endpoint && out.limit[i] < limits.min_speed) {
				out.verdict = AirTrajectoryVerdict::BELOW_STALL_SPEED;
				out.limiting_index = uint32_t(i);
				return false;
			}
		}
	}
	// Duration: per segment, accelerate / cruise (capped by the segment limit) / brake.
	double total = 0.0;
	for (size_t k = 0; k + 1 < n; ++k) {
		const double l = seg_len[k];
		if (l <= 0.0) {
			continue;
		}
		const double a = limits.max_accel, b = limits.max_brake;
		const double v0 = out.speed[k], v1 = out.speed[k + 1];
		double peak = std::sqrt((2.0 * a * b * l + b * v0 * v0 + a * v1 * v1) / (a + b));
		peak = std::min(peak, double(std::max(seg_cap[k], std::max(out.speed[k], out.speed[k + 1]))));
		if (peak <= 1.0e-6) {
			continue;
		}
		const double up = std::max(0.0, (peak - v0) / a), down = std::max(0.0, (peak - v1) / b);
		const double d_up = (peak * peak - v0 * v0) / (2.0 * a), d_down = (peak * peak - v1 * v1) / (2.0 * b);
		const double cruise = std::max(0.0, l - d_up - d_down);
		total += up + down + cruise / peak;
	}
	out.duration = float(total);
	out.verdict = AirTrajectoryVerdict::OK;
	return true;
}

} // namespace nav_air
