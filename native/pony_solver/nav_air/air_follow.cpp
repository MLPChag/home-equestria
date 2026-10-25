// See air_follow.h.
#include "air_follow.h"

#include "air_search.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace nav_air {

namespace {

constexpr float PI_F = 3.14159265358979f;
constexpr float GRAVITY = 9.81f;
constexpr float INF_F = std::numeric_limits<float>::infinity();
constexpr float TRACK_SCALE = 0.3f; // short-lookahead pursuit: share of the rolling lookahead

inline Vec3 v_add(const Vec3 &a, const Vec3 &b) {
	return Vec3{a.x + b.x, a.y + b.y, a.z + b.z};
}

inline Vec3 v_sub(const Vec3 &a, const Vec3 &b) {
	return Vec3{a.x - b.x, a.y - b.y, a.z - b.z};
}

inline Vec3 v_scale(const Vec3 &a, float s) {
	return Vec3{a.x * s, a.y * s, a.z * s};
}

inline float v_dot(const Vec3 &a, const Vec3 &b) {
	return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline float v_len(const Vec3 &a) {
	return std::sqrt(v_dot(a, a));
}

inline float h_len(const Vec3 &a) {
	return std::sqrt(a.x * a.x + a.z * a.z);
}

inline Vec3 v_norm(const Vec3 &a) {
	const float l = v_len(a);
	return l > 1.0e-9f ? v_scale(a, 1.0f / l) : Vec3{0, 0, 0};
}

inline Vec3 v_lerp(const Vec3 &a, const Vec3 &b, float t) {
	return Vec3{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t};
}

inline bool finite3(const Vec3 &a) {
	return std::isfinite(a.x) && std::isfinite(a.y) && std::isfinite(a.z);
}

inline float clampf(float v, float lo, float hi) {
	return std::max(lo, std::min(hi, v));
}

float wrapf(float angle) {
	angle = std::fmod(angle + PI_F, 2.0f * PI_F);
	if (angle < 0.0f) {
		angle += 2.0f * PI_F;
	}
	return angle - PI_F;
}

// Godot: left of a forward direction (horizontal).
inline Vec3 left_of(const Vec3 &f) {
	return Vec3{f.z, 0.0f, -f.x};
}

// Rotation about +Y; positive angles turn toward the left (Godot yaw sign).
inline Vec3 rot_y(const Vec3 &w, float a) {
	const float c = std::cos(a), s = std::sin(a);
	return Vec3{w.x * c + w.z * s, w.y, -w.x * s + w.z * c};
}

inline float yaw_of(const Vec3 &d) {
	return std::atan2(-d.x, -d.z);
}

inline Vec3 forward_of_yaw(float yaw) {
	return Vec3{-std::sin(yaw), 0.0f, -std::cos(yaw)};
}

// Turns unit u toward unit d by at most `step` radians (in their common plane).
Vec3 rotate_toward(const Vec3 &u, const Vec3 &d, float step) {
	const float c = clampf(v_dot(u, d), -1.0f, 1.0f);
	const float angle = std::acos(c);
	if (angle <= step) {
		return d;
	}
	Vec3 w = v_sub(d, v_scale(u, c));
	if (v_len(w) < 1.0e-6f) {
		w = left_of(u); // reversal: turn horizontally
		if (v_len(w) < 1.0e-6f) {
			w = Vec3{1.0f, 0.0f, 0.0f};
		}
	}
	w = v_norm(w);
	return v_add(v_scale(u, std::cos(step)), v_scale(w, std::sin(step)));
}

// Elevation change of a direction; heading from the direction, or `yaw` when it is vertical.
Vec3 pitch_dir(const Vec3 &d, float delta, float yaw) {
	const float h = h_len(d);
	Vec3 heading = h > 1.0e-4f ? Vec3{d.x / h, 0.0f, d.z / h} : forward_of_yaw(yaw);
	const float e = clampf(std::atan2(d.y, h) + delta, -0.5f * PI_F, 0.5f * PI_F);
	return Vec3{heading.x * std::cos(e), std::sin(e), heading.z * std::cos(e)};
}

} // namespace

// ---------------------------------------------------------------- profile and motor model

AirFlightProfile AirFlightProfile::pegasus(float body_scale) {
	AirFlightProfile p;
	const float s = body_scale > 0.0f ? body_scale : 1.0f;
	p.max_speed = 20.0f * s;
	p.accel = 7.0f * s;
	p.brake = 6.0f * s;
	return p;
}

AirFlightProfile AirFlightProfile::rainbow_dash(float body_scale) {
	AirFlightProfile p;
	const float s = body_scale > 0.0f ? body_scale : 1.0f;
	p.max_speed = 350.0f * s;
	p.accel = 45.0f * s;
	p.brake = 40.0f * s;
	return p;
}

AirFlightLimits AirFlightProfile::limits() const {
	AirFlightLimits l;
	l.max_speed = max_speed;
	l.min_speed = 0.0f;
	l.max_accel = accel;
	l.max_brake = brake;
	l.max_lateral_accel = lateral_accel;
	l.max_turn_rate = turn_rate;
	l.max_climb_rate = climb_rate;
	l.max_descent_rate = descent_rate;
	l.tracking_tolerance = tracking_tolerance;
	return l;
}

float air_allowed_descent(float horizontal_speed, const AirFlightProfile &profile, bool settle) {
	float down = 0.0f;
	if (horizontal_speed >= profile.min_descent_speed && profile.glide_ratio > 0.0f) {
		down = std::min(profile.descent_rate, horizontal_speed / profile.glide_ratio);
	}
	if (settle) {
		down = std::max(down, profile.settle_rate);
	}
	return down;
}

Vec3 air_step_velocity(const Vec3 &velocity, const Vec3 &target_direction, float target_speed,
		const AirFlightProfile &profile, float dt, bool settle) {
	if (!(dt > 0.0f) || !finite3(velocity)) {
		return Vec3{0, 0, 0};
	}
	const float speed = v_len(velocity);
	const float tl = finite3(target_direction) ? v_len(target_direction) : 0.0f;
	const bool has_dir = tl > 1.0e-6f;
	const Vec3 d = has_dir ? v_scale(target_direction, 1.0f / tl) : Vec3{0, 0, 0};
	float want = has_dir && std::isfinite(target_speed) ? clampf(target_speed, 0.0f, profile.max_speed) : 0.0f;
	Vec3 out;
	if (speed <= profile.hover_speed) {
		// Hovering: the velocity is a free vector with bounded change.
		Vec3 delta = v_sub(v_scale(d, want), velocity);
		const float dl = v_len(delta);
		const float cap = std::max(profile.accel, profile.brake) * dt;
		if (dl > cap) {
			delta = v_scale(delta, cap / dl);
		}
		out = v_add(velocity, delta);
	} else {
		Vec3 u = v_scale(velocity, 1.0f / speed);
		if (has_dir) {
			if (v_dot(u, d) < 0.0f) {
				want = std::min(want, profile.hover_speed); // turning round: slow down first
			}
			const float omega = std::min(profile.turn_rate, profile.lateral_accel / speed);
			u = rotate_toward(u, d, omega * dt);
		}
		const float change = clampf(want - speed, -profile.brake * dt, profile.accel * dt);
		out = v_scale(u, std::max(0.0f, speed + change));
	}
	out.y = std::min(out.y, profile.climb_rate);
	out.y = std::max(out.y, -air_allowed_descent(h_len(out), profile, settle));
	return out;
}

// ---------------------------------------------------------------- corridor

void AirFollowCorridor::clear() {
	*this = AirFollowCorridor();
}

bool AirFollowCorridor::build(const AirSpace &space, const std::vector<Vec3> &points, const std::vector<float> &clearance,
		const AirFlightProfile &profile, AirTerminal terminal, float end_speed) {
	clear();
	std::vector<Vec3> p;
	std::vector<float> c;
	float pending = INF_F; // smallest clearance of the original segments merged into the next one
	for (size_t i = 0; i < points.size(); ++i) {
		if (!finite3(points[i])) {
			return false;
		}
		if (i > 0) {
			const float ci = i - 1 < clearance.size() ? std::max(0.0f, clearance[i - 1]) : 0.0f;
			pending = std::min(pending, ci);
		}
		if (p.empty() || air_distance(p.back(), points[i]) > 1.0e-3f) {
			if (!p.empty()) {
				c.push_back(std::isfinite(pending) ? pending : 0.0f);
			}
			p.push_back(points[i]);
			pending = INF_F;
		}
	}
	if (p.size() < 2) {
		return false;
	}
	// Segments under 0.25 m (fillet junctions) make the per-vertex corner model see a needlessly
	// sharp turn. Drop such a vertex wherever the joined segment certifies with the smaller
	// clearance of the two it replaces.
	{
		std::vector<Vec3> q{p[0]};
		std::vector<float> qc;
		for (size_t i = 1; i < p.size(); ++i) {
			const bool last = i + 1 == p.size();
			if (!last && air_distance(q.back(), p[i]) < 0.25f) {
				const float joined = std::min(c[i - 1], c[i]); // c[i - 1]: segment from q.back() to p[i]
				if (air_segment_clear(space, q.back(), p[i + 1], joined)) {
					c[i] = joined; // the next pushed segment starts at q.back()
					continue;
				}
			}
			if (last && q.size() >= 2 && air_distance(q.back(), p[i]) < 0.25f) {
				const float joined = std::min(qc.back(), c[i - 1]);
				if (air_segment_clear(space, q[q.size() - 2], p[i], joined)) {
					q.back() = p[i];
					qc.back() = joined;
					continue;
				}
			}
			q.push_back(p[i]);
			qc.push_back(c[i - 1]);
		}
		p.swap(q);
		c.swap(qc);
	}
	if (!air_make_corridor(space, p, c, certified_)) {
		clear();
		return false;
	}
	const size_t n = p.size();
	terminal_ = terminal;
	end_speed_ = terminal == AirTerminal::PASS ? clampf(end_speed, 0.0f, profile.max_speed) : 0.0f;
	report_ = AirTrajectoryReport();
	air_validate_trajectory(p, c, profile.limits(), 0.0f, end_speed_, report_);
	if (report_.verdict == AirTrajectoryVerdict::INVALID || report_.limit.size() != n) {
		clear();
		return false;
	}
	points_ = p;
	clearance_ = c;
	limit_ = report_.limit;
	cumulative_.assign(n, 0.0f);
	for (size_t i = 1; i < n; ++i) {
		cumulative_[i] = cumulative_[i - 1] + air_distance(p[i - 1], p[i]);
	}
	turn_.assign(n, 0.0f);
	slack_.assign(n, 0.0f);
	for (size_t i = 1; i + 1 < n; ++i) {
		const Vec3 u = v_norm(v_sub(p[i], p[i - 1]));
		const Vec3 w = v_norm(v_sub(p[i + 1], p[i]));
		turn_[i] = std::acos(clampf(v_dot(u, w), -1.0f, 1.0f));
		slack_[i] = std::max(profile.tracking_tolerance, std::min(c[i - 1], c[i]));
	}
	steep_.assign(n - 1, 0);
	for (size_t i = 0; i + 1 < n; ++i) {
		const Vec3 d = v_sub(p[i + 1], p[i]);
		const float drop = -d.y;
		steep_[i] = (drop > 1.0e-4f && drop * profile.glide_ratio > h_len(d) + 1.0e-4f) ? 1 : 0;
	}
	return true;
}

int32_t AirFollowCorridor::segment_at(float s) const {
	if (points_.size() < 2) {
		return 0;
	}
	const auto it = std::upper_bound(cumulative_.begin(), cumulative_.end(), s);
	int32_t i = int32_t(it - cumulative_.begin()) - 1;
	return std::max(0, std::min(i, int32_t(points_.size()) - 2));
}

Vec3 AirFollowCorridor::point_at(float s) const {
	if (points_.empty()) {
		return Vec3{0, 0, 0};
	}
	if (points_.size() < 2 || s <= 0.0f) {
		return points_.front();
	}
	if (s >= length()) {
		return points_.back();
	}
	const int32_t i = segment_at(s);
	const float len = cumulative_[i + 1] - cumulative_[i];
	return len > 0.0f ? v_lerp(points_[i], points_[i + 1], (s - cumulative_[i]) / len) : points_[i];
}

Vec3 AirFollowCorridor::direction_at(float s) const {
	if (points_.size() < 2) {
		return Vec3{0, 0, 0};
	}
	const int32_t i = segment_at(std::min(s, length()));
	return v_norm(v_sub(points_[i + 1], points_[i]));
}

AirProjection AirFollowCorridor::project_window(const Vec3 &p, float from_s, float back, float ahead) const {
	AirProjection best;
	if (points_.size() < 2 || !finite3(p)) {
		return best;
	}
	const float lo = clampf(from_s - std::max(0.0f, back), 0.0f, length());
	const float hi = clampf(from_s + std::max(0.0f, ahead), lo, length());
	for (int32_t i = segment_at(lo); i + 1 < int32_t(points_.size()); ++i) {
		if (cumulative_[i] > hi) {
			break;
		}
		const Vec3 a = points_[i], b = points_[i + 1];
		const Vec3 ab = v_sub(b, a);
		const float len = cumulative_[i + 1] - cumulative_[i];
		const float l2 = v_dot(ab, ab);
		float t = l2 > 0.0f ? clampf(v_dot(v_sub(p, a), ab) / l2, 0.0f, 1.0f) : 0.0f;
		float s = clampf(cumulative_[i] + t * len, lo, hi);
		t = len > 0.0f ? clampf((s - cumulative_[i]) / len, 0.0f, 1.0f) : 0.0f;
		const Vec3 q = v_lerp(a, b, t);
		const float dist = air_distance(p, q);
		if (!best.found || dist < best.distance - 1.0e-5f) {
			best.found = true;
			best.s = s;
			best.distance = dist;
			best.segment = i;
			best.point = q;
		}
	}
	return best;
}

AirProjection AirFollowCorridor::project_all(const Vec3 &p) const {
	return project_window(p, 0.0f, 0.0f, length());
}

float AirFollowCorridor::clamp_lookahead(float from_s, float to_s) const {
	float to = std::min(to_s, length());
	for (size_t j = 1; j + 1 < points_.size(); ++j) {
		if (cumulative_[j] <= from_s) {
			continue;
		}
		if (cumulative_[j] > to) {
			break;
		}
		const float theta = turn_[j];
		if (theta < 1.0e-4f) {
			continue;
		}
		// Corner-to-chord distance <= (distance past the corner) * sin(theta) for theta <= 90 deg.
		const float past = theta < 0.5f * PI_F ? slack_[j] / std::sin(theta) : 0.0f;
		to = std::min(to, cumulative_[j] + past);
	}
	return std::max(to, std::min(from_s, length()));
}

float AirFollowCorridor::preview_speed(float s, float preview, float braking, int32_t *limiting) const {
	float best = INF_F;
	int32_t which = -1;
	if (points_.size() < 2) {
		if (limiting != nullptr) {
			*limiting = which;
		}
		return 0.0f;
	}
	const float b = std::max(1.0e-3f, braking);
	const size_t n = points_.size();
	for (size_t j = size_t(segment_at(s)) + 1; j < n; ++j) {
		const float d = cumulative_[j] - s;
		if (d > preview) {
			break;
		}
		float lim = limit_[j];
		if (j == n - 1) {
			lim = std::min(lim, end_speed_);
		}
		const float v = std::sqrt(lim * lim + 2.0f * b * std::max(0.0f, d));
		if (v < best) {
			best = v;
			which = j == n - 1 ? int32_t(n) : int32_t(j);
		}
	}
	if (limiting != nullptr) {
		*limiting = which;
	}
	return best;
}

// ---------------------------------------------------------------- shaping and preparation

namespace {

// Moves sharp interior corners outward along their bisector while both adjacent segments still
// certify, so smoothing has certified room to round them. The offset tried first is the smallest
// step covering what a fillet of `turn_radius` cuts inside (R (sec(theta/2) - 1)), then smaller.
void relax_corners(const AirSpace &space, std::vector<Vec3> &pts, float turn_radius) {
	static const float STEPS[] = {0.5f, 1.0f, 2.0f, 4.0f};
	for (size_t i = 1; i + 1 < pts.size(); ++i) {
		const Vec3 u = v_norm(v_sub(pts[i], pts[i - 1]));
		const Vec3 w = v_norm(v_sub(pts[i + 1], pts[i]));
		const float c = clampf(v_dot(u, w), -1.0f, 1.0f);
		if (c > 0.9962f || c < -0.99f) {
			continue; // under 5 degrees, or a reversal (no outward bisector)
		}
		const Vec3 outward = v_norm(v_sub(u, w));
		const float half = 0.5f * std::acos(c);
		const float need = turn_radius * (1.0f / std::cos(half) - 1.0f);
		int first = 3;
		for (int k = 0; k < 4; ++k) {
			if (STEPS[k] >= need) {
				first = k;
				break;
			}
		}
		for (int k = first; k >= 0; --k) {
			const float off = STEPS[k];
			const Vec3 q = v_add(pts[i], v_scale(outward, off));
			if (air_segment_clear(space, pts[i - 1], q) && air_segment_clear(space, q, pts[i + 1])) {
				pts[i] = q;
				break;
			}
		}
	}
}

struct HelixPlan {
	std::vector<Vec3> points; // after the start point
};

// Helix of whole turns starting at P with initial tangent t0 (horizontal unit), centre on `side`
// (+1 left, -1 right), descending `drop` linearly over all but the last `tail` metres of arc.
bool build_helix(const AirSpace &space, const Vec3 &P, const Vec3 &t0, int side, float radius, float drop, float tail,
		float glide_ratio, HelixPlan &out) {
	out.points.clear();
	const float circumference = 2.0f * PI_F * radius;
	const float need = drop * glide_ratio + tail;
	const int turns = std::max(1, int(std::ceil(need / circumference - 1.0e-4f)));
	if (turns > 64) {
		return false;
	}
	const int per_turn = std::max(16, int(std::ceil(circumference / 4.0f)));
	const float total = float(turns) * circumference;
	const float descend_arc = std::max(1.0e-3f, total - tail);
	const Vec3 side_vec = v_scale(left_of(t0), float(side) * radius);
	const Vec3 centre = v_add(P, side_vec);
	const Vec3 w = v_sub(P, centre);
	const int count = turns * per_turn;
	Vec3 previous = P;
	for (int k = 1; k <= count; ++k) {
		const float phi = 2.0f * PI_F * float(k) / float(per_turn);
		const Vec3 r = rot_y(Vec3{w.x, 0.0f, w.z}, float(side) * phi);
		const float arc = radius * phi;
		const float y = P.y - drop * std::min(1.0f, arc / descend_arc);
		Vec3 q{centre.x + r.x, y, centre.z + r.z};
		if (k == count) {
			q.x = P.x; // whole turns: back over the start's X/Z exactly
			q.z = P.z;
		}
		if (!air_segment_clear(space, previous, q)) {
			return false;
		}
		out.points.push_back(q);
		previous = q;
	}
	return true;
}

} // namespace

bool air_shape_descents(const AirSpace &space, const std::vector<Vec3> &in, const AirFlightProfile &profile,
		bool hover_end, std::vector<Vec3> &out, uint32_t *shaped, uint32_t *failed) {
	out.clear();
	uint32_t shaped_count = 0, failed_count = 0;
	for (const Vec3 &v : in) {
		if (!finite3(v)) {
			return false;
		}
	}
	if (in.size() < 2 || !(profile.glide_ratio > 0.0f) || !(profile.brake > 0.0f) || !(profile.lateral_accel > 0.0f) ||
			!(profile.turn_rate > 0.0f)) {
		out = in;
		if (shaped != nullptr) {
			*shaped = 0;
		}
		if (failed != nullptr) {
			*failed = 0;
		}
		return in.size() >= 2 || in.size() == 1;
	}
	// Shaped glides use 80 % of the steepest allowed slope, so a flyer that lags can catch up.
	const float g = profile.glide_ratio * 1.25f;
	// Glide speed: comfortably above the minimum descent speed; the helix is flown at it.
	const float v_glide = std::min(profile.max_speed, std::max(1.3f * profile.min_descent_speed, profile.min_descent_speed + 1.0f));
	const float r_min = std::max(v_glide * v_glide / profile.lateral_accel, v_glide / profile.turn_rate);
	const float runout = profile.min_descent_speed * profile.min_descent_speed / (2.0f * profile.brake) + 1.0f;
	Vec3 incoming{0, 0, 0};
	out.push_back(in[0]);
	for (size_t i = 0; i + 1 < in.size(); ++i) {
		const Vec3 P = out.back();
		const Vec3 Q = in[i + 1];
		const bool last = i + 2 == in.size();
		const float tail = last && hover_end ? runout : 0.0f;
		const Vec3 d = v_sub(Q, P);
		const float drop = -d.y;
		const float h = h_len(d);
		const Vec3 u_h = h > 1.0e-3f ? Vec3{d.x / h, 0.0f, d.z / h} : Vec3{0, 0, 0};
		auto finish = [&](void) {
			const Vec3 e = v_sub(out.back(), out[out.size() >= 2 ? out.size() - 2 : 0]);
			if (h_len(e) > 1.0e-3f) {
				incoming = Vec3{e.x / h_len(e), 0.0f, e.z / h_len(e)};
			}
		};
		if (drop <= 1.0e-3f || (drop * g + tail <= h && tail <= 0.0f)) {
			out.push_back(Q); // level, climbing or a compliant glide
			finish();
			continue;
		}
		bool done = false;
		// A: enough run for a straight glide plus the level run-out.
		if (drop * g + tail <= h) {
			const Vec3 M{Q.x - u_h.x * tail, Q.y, Q.z - u_h.z * tail};
			if (air_segment_clear(space, P, M) && air_segment_clear(space, M, Q)) {
				out.push_back(M);
				out.push_back(Q);
				done = true;
			}
		}
		// B: a descending helix above P, then the straight part.
		if (!done) {
			// Spiral only what the straight part cannot glide; a hover end keeps its level run-out
			// after the glide (or at the end of the helix when there is no room for one).
			const float glide_h = std::max(0.0f, h - tail);
			const bool glide_after = glide_h > 1.0e-3f;
			const float helix_drop = glide_after ? std::max(0.0f, drop - glide_h / g) : drop;
			const float helix_tail = glide_after ? 0.0f : tail;
			const Vec3 P2{P.x, P.y - helix_drop, P.z};
			const Vec3 M{Q.x - u_h.x * tail, Q.y, Q.z - u_h.z * tail};
			const bool runout = glide_after && tail > 0.0f;
			Vec3 t0 = h > 1.0e-3f ? u_h : incoming;
			if (h_len(t0) < 1.0e-3f) {
				t0 = Vec3{1.0f, 0.0f, 0.0f};
			}
			const float radii[2] = {std::max(r_min, std::max(2.0f * r_min, 4.0f)), r_min};
			const int headings = h > 1.0e-3f ? 1 : 4; // a vertical drop may start the helix any way round
			HelixPlan plan;
			for (int r = 0; r < 2 && !done; ++r) {
				for (int k = 0; k < headings && !done; ++k) {
					const Vec3 t = rot_y(t0, float(k) * 0.5f * PI_F);
					for (int side = 1; side >= -1 && !done; side -= 2) {
						if (!build_helix(space, P, t, side, radii[r], helix_drop, helix_tail, g, plan)) {
							continue;
						}
						if (runout ? !(air_segment_clear(space, P2, M) && air_segment_clear(space, M, Q))
									: (air_distance(P2, Q) > 1.0e-3f && !air_segment_clear(space, P2, Q))) {
							continue;
						}
						out.insert(out.end(), plan.points.begin(), plan.points.end());
						if (runout) {
							out.push_back(M);
						}
						if (air_distance(out.back(), Q) > 1.0e-3f) {
							out.push_back(Q);
						}
						done = true;
					}
				}
			}
		}
		if (done) {
			++shaped_count;
		} else {
			++failed_count;
			out.push_back(Q);
		}
		finish();
	}
	if (shaped != nullptr) {
		*shaped = shaped_count;
	}
	if (failed != nullptr) {
		*failed = failed_count;
	}
	return true;
}

const char *air_prepare_status_name(AirPrepareStatus status) {
	switch (status) {
		case AirPrepareStatus::OK:
			return "ok";
		case AirPrepareStatus::NOT_CERTIFIED:
			return "not_certified";
		case AirPrepareStatus::NO_GLIDE_VOLUME:
			return "no_glide_volume";
		case AirPrepareStatus::INVALID:
			return "invalid";
	}
	return "unknown";
}

AirPrepareStatus air_prepare_corridor(const AirSpace &space, const std::vector<Vec3> &route,
		const AirFlightProfile &profile, AirTerminal terminal, float end_speed, const AirPrepareOptions &options,
		AirFollowCorridor &out) {
	out.clear();
	if (route.size() < 2) {
		return AirPrepareStatus::INVALID;
	}
	std::vector<Vec3> pts;
	if (options.shorten) {
		if (!air_shorten(space, route, pts)) {
			return AirPrepareStatus::NOT_CERTIFIED;
		}
	} else {
		if (!air_polyline_clear(space, route, std::vector<float>())) {
			return AirPrepareStatus::NOT_CERTIFIED;
		}
		pts = route;
	}
	const float cruise = options.cruise_speed > 0.0f ? options.cruise_speed : profile.max_speed;
	const float turn_radius = std::max(1.0f, std::min(cruise * cruise / std::max(1.0e-3f, profile.lateral_accel),
													 options.max_turn_radius));
	relax_corners(space, pts, turn_radius);
	uint32_t failed = 0;
	if (options.shape_descents) {
		std::vector<Vec3> shaped;
		if (!air_shape_descents(space, pts, profile, terminal == AirTerminal::HOVER, shaped, nullptr, &failed)) {
			return AirPrepareStatus::INVALID;
		}
		pts.swap(shaped);
	}
	std::vector<float> clearance;
	if (options.smooth) {
		AirSmoothOptions so = options.smooth_options;
		so.turn_radius = turn_radius;
		AirSmoothPath smooth;
		if (!air_smooth(space, pts, so, smooth)) {
			return AirPrepareStatus::NOT_CERTIFIED;
		}
		pts = smooth.points;
		clearance = smooth.clearance;
	}
	if (!out.build(space, pts, clearance, profile, terminal, end_speed)) {
		return AirPrepareStatus::NOT_CERTIFIED;
	}
	return failed > 0 ? AirPrepareStatus::NO_GLIDE_VOLUME : AirPrepareStatus::OK;
}

// ---------------------------------------------------------------- names

const char *air_command_mode_name(AirCommandMode mode) {
	switch (mode) {
		case AirCommandMode::TRAVEL:
			return "travel";
		case AirCommandMode::BRAKE:
			return "brake";
		case AirCommandMode::HOLD:
			return "hold";
		case AirCommandMode::ARRIVED:
			return "arrived";
		case AirCommandMode::FAILED:
			return "failed";
	}
	return "unknown";
}

const char *air_speed_limit_name(AirSpeedLimit limit) {
	switch (limit) {
		case AirSpeedLimit::REQUESTED:
			return "requested";
		case AirSpeedLimit::CAPABILITY:
			return "capability";
		case AirSpeedLimit::CURVE:
			return "curve";
		case AirSpeedLimit::ARRIVAL:
			return "arrival";
		case AirSpeedLimit::HORIZON:
			return "horizon";
		case AirSpeedLimit::VERTICAL:
			return "vertical";
		case AirSpeedLimit::ESCAPE:
			return "escape";
	}
	return "unknown";
}

const char *air_reason_name(int32_t reason) {
	switch (reason) {
		case AIR_REASON_NONE:
			return "none";
		case AIR_REASON_ARRIVED:
			return "arrived";
		case AIR_REASON_HOVER_HOLD:
			return "hover_hold";
		case AIR_REASON_HORIZON_LIMITED:
			return "horizon_limited";
		case AIR_REASON_UNKNOWN_AHEAD:
			return "unknown_ahead";
		case AIR_REASON_SOLID_AHEAD:
			return "solid_ahead";
		case AIR_REASON_NO_SAFE_TRAJECTORY:
			return "no_safe_trajectory";
		case AIR_REASON_NEIGHBOUR:
			return "neighbour";
		case AIR_REASON_DESCENT_TOO_STEEP:
			return "descent_too_steep";
		case AIR_REASON_DESCENT_NEEDS_SPEED:
			return "descent_needs_speed";
		case AIR_REASON_CORRIDOR_LOST:
			return "corridor_lost";
		case AIR_REASON_WAITING_ROUTE:
			return "waiting_route";
		case AIR_REASON_REPAIR:
			return "repair";
		case AIR_REASON_FAILED:
			return "failed";
		case AIR_REASON_INVALID_INPUT:
			return "invalid_input";
		case AIR_REASON_ESCAPING:
			return "escaping";
		case AIR_REASON_UNKNOWN_HERE:
			return "unknown_here";
		case AIR_REASON_CORRIDOR_BLOCKED:
			return "corridor_blocked";
		case AIR_REASON_PREFERRED:
			return "preferred";
	}
	return "unknown";
}

const char *air_candidate_name(AirCandidateKind kind) {
	switch (kind) {
		case AirCandidateKind::REFERENCE:
			return "reference";
		case AirCandidateKind::CONTINUE:
			return "continue";
		case AirCandidateKind::TRACK:
			return "track";
		case AirCandidateKind::YAW_LEFT_SMALL:
			return "yaw_left_small";
		case AirCandidateKind::YAW_RIGHT_SMALL:
			return "yaw_right_small";
		case AirCandidateKind::PITCH_UP_SMALL:
			return "pitch_up_small";
		case AirCandidateKind::PITCH_DOWN_SMALL:
			return "pitch_down_small";
		case AirCandidateKind::YAW_LEFT_WIDE:
			return "yaw_left_wide";
		case AirCandidateKind::YAW_RIGHT_WIDE:
			return "yaw_right_wide";
		case AirCandidateKind::YAW_LEFT_REPAIR:
			return "yaw_left_repair";
		case AirCandidateKind::YAW_RIGHT_REPAIR:
			return "yaw_right_repair";
		case AirCandidateKind::PITCH_UP_REPAIR:
			return "pitch_up_repair";
		case AirCandidateKind::PITCH_DOWN_REPAIR:
			return "pitch_down_repair";
		case AirCandidateKind::PREFERRED:
			return "preferred";
		case AirCandidateKind::BRAKE_STEER:
			return "brake_steer";
		case AirCandidateKind::BRAKE:
			return "brake";
		case AirCandidateKind::EMERGENCY:
			return "emergency";
		case AirCandidateKind::HOVER_HOLD:
			return "hover_hold";
	}
	return "unknown";
}

const char *air_join_status_name(AirJoinStatus status) {
	switch (status) {
		case AirJoinStatus::JOINED:
			return "joined";
		case AirJoinStatus::NO_COMPATIBLE_PART:
			return "no_compatible_part";
		case AirJoinStatus::JOIN_NOT_CERTIFIED:
			return "join_not_certified";
		case AirJoinStatus::INVALID:
			return "invalid";
	}
	return "unknown";
}

// ---------------------------------------------------------------- follower

struct AirFollower::Context {
	Vec3 p0{0, 0, 0};
	Vec3 v0{0, 0, 0};
	float dt = 1.0f / 60.0f;
	float yaw = 0.0f;
	bool settle = false;
	bool escape = false;
	const AirNeighbour *neighbours = nullptr;
	size_t neighbour_count = 0;
	float progress = 0.0f;
	float window_ahead = 8.0f;
	float s_target = 0.0f;
	bool has_pref = false;
	Vec3 pref{0, 0, 0};
	Vec3 previous_desired{0, 0, 0};
	// Speed caps a travelling candidate's hold obeys, as later ticks would command them.
	float b_plan = 6.0f;
	float rem0 = INF_F; // remaining distance at the start
	float end_speed = 0.0f;
	float horizon_known = -1.0f; // < 0: the horizon does not limit
	float latency = 0.5f;
	float margin = 10.0f;
	bool pass = false; // PASS terminal: brake to end_speed; otherwise stop (with the hover gain)
	float hover_gain = 2.0f;
	float arrival_cap(float rem) const {
		rem = std::max(0.0f, rem);
		if (pass) {
			return std::sqrt(end_speed * end_speed + 2.0f * b_plan * rem);
		}
		return std::min(std::sqrt(2.0f * b_plan * rem), hover_gain * rem + 0.02f);
	}
};

bool AirFollower::begin(const AirFollowCorridor &corridor, uint64_t route_id) {
	clear();
	if (corridor.empty()) {
		return false;
	}
	corridor_ = corridor;
	route_ = route_id;
	return true;
}

void AirFollower::clear() {
	corridor_.clear();
	monitor_.reset();
	route_ = 0;
	progress_ = 0.0f;
	raw_progress_ = 0.0f;
	intent_progress_ = 0.0;
	arrived_ = false;
	failed_reported_ = false;
	lost_time_ = 0.0f;
	no_safe_time_ = 0.0f;
	recover_projection_ = false;
	has_plan_ = false;
	plan_direction_ = Vec3{0, 0, 0};
	plan_speed_ = 0.0f;
	plan_hold_left_ = 0.0f;
	previous_desired_ = Vec3{0, 0, 0};
	corridor_fingerprint_ = 0;
	corridor_state_ = AirCorridorState::VALID;
	blocked_ahead_ = false;
	ideal_speed_ = 0.0f;
}

AirJoinStatus AirFollower::replace(const AirSpace &space, const AirFollowCorridor &corridor, uint64_t route_id,
		const Vec3 &position, const Vec3 &velocity) {
	if (corridor.empty() || !finite3(position) || !finite3(velocity)) {
		return AirJoinStatus::INVALID;
	}
	const float speed = v_len(velocity);
	const Vec3 u = speed > profile_.hover_speed ? v_scale(velocity, 1.0f / speed) : Vec3{0, 0, 0};
	const float reach = std::max(profile_.corridor_tolerance * 4.0f, speed * 2.0f + profile_.lookahead_min);
	struct Option {
		AirProjection projection;
		size_t order;
	};
	std::vector<Option> options;
	const std::vector<Vec3> &pts = corridor.points();
	const std::vector<float> &cum = corridor.cumulative();
	for (size_t i = 0; i + 1 < pts.size(); ++i) {
		const Vec3 dir = v_norm(v_sub(pts[i + 1], pts[i]));
		if (speed > profile_.hover_speed && v_dot(dir, u) < -0.17f) {
			continue; // would make her reverse: not forward-compatible
		}
		const AirProjection pr = corridor.project_window(position, cum[i], 0.0f, cum[i + 1] - cum[i]);
		if (pr.found && pr.distance <= reach) {
			options.push_back(Option{pr, i});
		}
	}
	if (options.empty()) {
		return AirJoinStatus::NO_COMPATIBLE_PART;
	}
	std::stable_sort(options.begin(), options.end(), [](const Option &a, const Option &b) {
		if (a.projection.distance != b.projection.distance) {
			return a.projection.distance < b.projection.distance;
		}
		return a.projection.s < b.projection.s;
	});
	const size_t tries = std::min<size_t>(options.size(), 8);
	for (size_t k = 0; k < tries; ++k) {
		const AirProjection &pr = options[k].projection;
		if (pr.distance > 1.0e-4f && !air_segment_clear(space, position, pr.point)) {
			continue;
		}
		corridor_ = corridor;
		route_ = route_id;
		progress_ = pr.s;
		raw_progress_ = pr.s;
		arrived_ = false;
		lost_time_ = 0.0f;
		no_safe_time_ = 0.0f;
		recover_projection_ = false;
		corridor_fingerprint_ = 0;
		corridor_state_ = AirCorridorState::VALID;
		blocked_ahead_ = false;
		monitor_.route_replaced(route_id); // history, escalation and intent progress are kept
		return AirJoinStatus::JOINED;
	}
	return AirJoinStatus::JOIN_NOT_CERTIFIED;
}

void AirFollower::predict(const Context &c, const Candidate &k, std::vector<Vec3> &points, std::vector<Vec3> &velocities,
		bool with_tail) const {
	points.clear();
	velocities.clear();
	points.push_back(c.p0);
	Vec3 v = c.v0;
	Vec3 p = c.p0;
	// Pursuit candidates re-aim along the corridor every tick, exactly as step() would.
	float s_prog = c.progress;
	const float len = corridor_.length();
	auto aim = [&](float &rem) -> Vec3 {
		const float spd = v_len(v);
		const float ahead = std::max(tuning_.window_ahead_min, spd * tuning_.window_time);
		const AirProjection pr = corridor_.project_window(p, s_prog, tuning_.window_back, ahead);
		if (pr.found && pr.distance <= profile_.corridor_tolerance) {
			s_prog = std::max(s_prog, pr.s);
		}
		const float full = clampf(spd * profile_.lookahead_time, profile_.lookahead_min, profile_.lookahead_max);
		const float look_len = std::max(0.5f, k.look_scale * full);
		const float sl = corridor_.clamp_lookahead(s_prog, std::min(len, s_prog + look_len));
		const Vec3 look = sl >= len - 1.0e-4f ? corridor_.end() : corridor_.point_at(sl);
		const float arc_left = std::max(0.0f, len - s_prog);
		rem = arc_left <= full ? air_distance(p, corridor_.end()) : arc_left;
		return v_sub(look, p);
	};
	const int hold_steps = std::max(1, int(std::ceil(k.hold / c.dt - 1.0e-3f)));
	float travelled = 0.0f;
	for (int i = 0; i < hold_steps; ++i) {
		float rem = c.rem0 - travelled;
		const Vec3 dir = k.pursuit ? aim(rem) : k.direction;
		float target = k.speed;
		if (target > 0.0f && i > 0) {
			target = std::min(target, c.arrival_cap(rem));
			if (c.horizon_known >= 0.0f) {
				target = std::min(target, air_max_safe_speed(c.horizon_known - travelled, c.latency, c.b_plan, c.margin,
												  profile_.max_speed));
			}
		}
		v = air_step_velocity(v, dir, target, profile_, c.dt, c.settle);
		travelled += v_len(v) * c.dt;
		p = v_add(p, v_scale(v, c.dt));
		velocities.push_back(v);
		points.push_back(p);
	}
	if (!with_tail) {
		return;
	}
	// Braking tail: stop while still steering (along the corridor for pursuit candidates).
	for (uint32_t i = 0; i < tuning_.max_tail_steps && v_len(v) > 1.0e-5f; ++i) {
		float rem = 0.0f;
		const Vec3 dir = k.pursuit ? aim(rem) : k.direction;
		v = air_step_velocity(v, dir, 0.0f, profile_, c.dt, c.settle);
		if (v_len(v) <= 1.0e-6f) {
			break;
		}
		p = v_add(p, v_scale(v, c.dt));
		velocities.push_back(v);
		points.push_back(p);
	}
}

bool AirFollower::certify(const AirSpace &space, const Context &c, const std::vector<Vec3> &points,
		const std::vector<Vec3> &velocities, uint32_t &voxels, bool &neighbour_failed) const {
	neighbour_failed = false;
	const size_t n = points.size();
	if (n < 2 && !c.escape) {
		return air_point_clear(space, points[0]);
	}
	size_t start = 0;
	if (c.escape) {
		// Leaving non-FREE (never UNKNOWN) volume: the prefix up to the first clear point is
		// allowed, bounded by escape_distance.
		float travelled = 0.0f;
		bool found = false;
		for (size_t k = 0; k < n; ++k) {
			bool unknown = false;
			if (air_point_clear(space, points[k], &unknown)) {
				start = k;
				found = true;
				break;
			}
			if (unknown || space.sample(points[k]) == Cell::UNKNOWN) {
				return false;
			}
			if (k + 1 < n) {
				travelled += air_distance(points[k], points[k + 1]);
			}
			if (travelled > tuning_.escape_distance) {
				return false;
			}
		}
		if (!found) {
			return false;
		}
	}
	// Static volume: chords merged while their deviation bound stays small; each swept with it.
	size_t a = start;
	while (a + 1 < n) {
		size_t b = a + 1;
		float len = air_distance(points[a], points[b]);
		float turned = 0.0f;
		Vec3 dir = v_norm(v_sub(points[b], points[a]));
		while (b + 1 < n) {
			const float l2 = air_distance(points[b], points[b + 1]);
			const Vec3 d2 = v_norm(v_sub(points[b + 1], points[b]));
			float add = 0.0f;
			if (l2 > 0.0f && v_len(dir) > 0.0f) {
				add = std::acos(clampf(v_dot(dir, d2), -1.0f, 1.0f));
			}
			const float new_len = len + l2;
			const float new_turn = turned + add;
			const float bound = 0.5f * new_len * std::sin(std::min(2.0f * new_turn, 0.5f * PI_F));
			if (bound > tuning_.chord_tolerance || new_len > tuning_.max_chord) {
				break;
			}
			len = new_len;
			turned = new_turn;
			if (l2 > 0.0f) {
				dir = d2;
			}
			++b;
		}
		const float radius = turned > 0.0f ? 0.5f * len * std::sin(std::min(2.0f * turned, 0.5f * PI_F)) : 0.0f;
		AirSegmentCheck info;
		const bool clear = air_segment_clear(space, points[a], points[b], radius, &info);
		voxels += info.voxels;
		if (!clear) {
			return false;
		}
		a = b;
	}
	// Neighbour spheres, predicted at constant velocity over the neighbour horizon.
	for (size_t j = 0; j < c.neighbour_count; ++j) {
		const AirNeighbour &nb = c.neighbours[j];
		if (!finite3(nb.position) || !finite3(nb.velocity)) {
			continue;
		}
		float required = profile_.envelope_radius + std::max(0.0f, nb.radius) + tuning_.neighbour_margin;
		const float d0 = air_distance(c.p0, nb.position);
		if (d0 < required) {
			required = d0 - 1.0e-3f; // already too close: must not close in further
		}
		const float horizon = tuning_.neighbour_horizon;
		float t = 0.0f;
		bool fail = false;
		for (size_t k = 0; k + 1 < n && t < horizon && !fail; ++k) {
			const Vec3 at = v_add(nb.position, v_scale(nb.velocity, t));
			const Vec3 a0 = v_sub(points[k], at);
			const Vec3 rel = v_sub(velocities[k], nb.velocity);
			const float r2 = v_dot(rel, rel);
			const float span = std::min(c.dt, horizon - t);
			const float tau = r2 > 0.0f ? clampf(-v_dot(a0, rel) / r2, 0.0f, span) : 0.0f;
			fail = v_len(v_add(a0, v_scale(rel, tau))) < required;
			t += c.dt;
		}
		if (!fail && t < horizon) {
			// At rest at the last point for the rest of the horizon.
			const Vec3 at = v_add(nb.position, v_scale(nb.velocity, t));
			const Vec3 a0 = v_sub(points[n - 1], at);
			const Vec3 rel = v_scale(nb.velocity, -1.0f);
			const float r2 = v_dot(rel, rel);
			const float tau = r2 > 0.0f ? clampf(-v_dot(a0, rel) / r2, 0.0f, horizon - t) : 0.0f;
			fail = v_len(v_add(a0, v_scale(rel, tau))) < required;
		}
		if (fail) {
			neighbour_failed = true;
			return false;
		}
	}
	return true;
}

void AirFollower::score(const Context &c, Candidate &k) const {
	// Raw terms only; step() normalizes progress by the best progress of this tick's set.
	std::vector<Vec3> &points = score_points_;
	std::vector<Vec3> &velocities = score_velocities_;
	predict(c, k, points, velocities, false);
	k.first = velocities.empty() ? c.v0 : velocities[0];
	const Vec3 end = points.back();
	// A zero-speed corner must be reached before progress beyond it earns a
	// reward. Otherwise a candidate can cut across the bend to its outgoing
	// segment, outweighing tracking cost despite the corner's braking limit.
	// Positive-speed fillets and straight sidesteps keep ordinary scoring.
	float look_end = std::min(corridor_.length(), c.progress + c.window_ahead + k.speed * k.hold + 1.0f);
	for (size_t j = size_t(corridor_.segment_at(c.progress)) + 1; j + 1 < corridor_.size(); ++j) {
		if (corridor_.cumulative()[j] >= look_end) break;
		if (corridor_.report().limit[j] <= 0.0f) {
			look_end = corridor_.cumulative()[j];
			break;
		}
	}
	const AirProjection pr = corridor_.project_window(end, c.progress, tuning_.window_back, look_end - c.progress);
	k.gain = pr.found ? pr.s - c.progress : 0.0f;
	const float error = pr.found ? pr.distance : air_distance(end, corridor_.point_at(c.progress));
	const Vec3 desired = v_scale(v_norm(k.direction), k.speed);
	float cost = tuning_.weight_error * error / std::max(1.0f, profile_.corridor_tolerance);
	if (c.has_pref) {
		cost += tuning_.weight_preferred * v_len(v_sub(desired, c.pref)) / std::max(1.0f, std::max(v_len(c.pref), c.s_target));
	}
	// Control change: direction only (side flips), never a penalty for starting or stopping.
	if (k.speed > 0.0f && v_len(c.previous_desired) > 1.0e-3f) {
		const float cosine = clampf(v_dot(v_norm(k.direction), v_norm(c.previous_desired)), -1.0f, 1.0f);
		cost += tuning_.weight_change * 0.5f * (1.0f - cosine);
	}
	k.cost = cost;
}

AirFollowCommand AirFollower::step(const AirSpace &space, const AirFollowInput &in) {
	AirFollowCommand cmd;
	cmd.yaw = in.yaw;
	cmd.escalation = monitor_.level();
	if (corridor_.empty() || !finite3(in.position) || !finite3(in.velocity) || !(in.dt > 0.0f) || !std::isfinite(in.dt)) {
		cmd.mode = AirCommandMode::HOLD;
		cmd.reason = AIR_REASON_INVALID_INPUT;
		cmd.velocity = finite3(in.velocity) && in.dt > 0.0f
				? air_step_velocity(in.velocity, Vec3{0, 0, 0}, 0.0f, profile_, in.dt, false)
				: Vec3{0, 0, 0};
		return cmd;
	}
	const float dt = in.dt;
	const Vec3 p = in.position;
	const Vec3 v = in.velocity;
	const float speed = v_len(v);
	AirEscalation entered = AirEscalation::NONE;
	auto note = [&](AirEscalation level) {
		if (level != AirEscalation::NONE) {
			entered = level;
		}
	};

	// 1. Durable changes to the corridor (cheap while its tiles keep their revisions).
	{
		const AirCorridor &stamped = corridor_.stamped();
		uint64_t fingerprint = 1469598103934665603ull;
		const bool cached = corridor_state_ == AirCorridorState::BLOCKED || corridor_state_ == AirCorridorState::MISSING_DATA;
		if (cached) {
			for (const AirCorridor::TileStamp &t : stamped.tiles) {
				fingerprint ^= space.tile_revision(t.x, t.y, t.z);
				fingerprint *= 1099511628211ull;
			}
		}
		if (!cached || fingerprint != corridor_fingerprint_) {
			corridor_state_ = air_check_corridor(space, corridor_.stamped());
			blocked_ahead_ = false;
			if (corridor_state_ == AirCorridorState::BLOCKED || corridor_state_ == AirCorridorState::MISSING_DATA) {
				fingerprint = 1469598103934665603ull;
				for (const AirCorridor::TileStamp &t : stamped.tiles) {
					fingerprint ^= space.tile_revision(t.x, t.y, t.z);
					fingerprint *= 1099511628211ull;
				}
				corridor_fingerprint_ = fingerprint;
			}
			if (corridor_state_ == AirCorridorState::BLOCKED) {
				// Only an obstruction ahead of her matters.
				std::vector<Vec3> rest;
				std::vector<float> rest_clear;
				const int32_t seg = corridor_.segment_at(progress_);
				rest.push_back(corridor_.point_at(progress_));
				for (size_t i = size_t(seg) + 1; i < corridor_.size(); ++i) {
					rest.push_back(corridor_.points()[i]);
					rest_clear.push_back(size_t(i - 1) < corridor_.clearance().size() ? corridor_.clearance()[i - 1] : 0.0f);
				}
				AirSegmentCheck info;
				blocked_ahead_ = !air_polyline_clear(space, rest, rest_clear, &info) && info.blocking == Cell::SOLID;
			}
		}
		cmd.corridor_state = corridor_state_;
		if (blocked_ahead_) {
			note(monitor_.force(AirEscalation::REPLAN, "corridor blocked ahead"));
		}
	}

	// 2. Projection (bounded forward window; full search only in explicit recovery).
	const float lookahead = clampf(speed * profile_.lookahead_time, profile_.lookahead_min, profile_.lookahead_max);
	const float window_ahead = std::max(tuning_.window_ahead_min, speed * tuning_.window_time);
	const float before = progress_;
	AirProjection pr;
	if (recover_projection_) {
		pr = corridor_.project_all(p);
		if (pr.found && (pr.distance <= 1.0e-4f || air_segment_clear(space, p, pr.point))) {
			progress_ = pr.s; // recovery may move progress back; recorded via the stall samples
			recover_projection_ = false;
		} else {
			pr = corridor_.project_window(p, progress_, tuning_.window_back, window_ahead);
		}
	} else {
		pr = corridor_.project_window(p, progress_, tuning_.window_back, window_ahead);
	}
	raw_progress_ = pr.found ? pr.s : progress_;
	const float error = pr.found ? pr.distance : air_distance(p, corridor_.point_at(progress_));
	if (pr.found && pr.distance <= profile_.corridor_tolerance) {
		progress_ = std::max(progress_, pr.s);
	}
	const float gained = std::max(0.0f, progress_ - before);
	intent_progress_ += gained;
	if (error > profile_.corridor_tolerance * tuning_.lost_factor) {
		lost_time_ += dt;
	} else {
		lost_time_ = 0.0f;
	}
	const bool lost = lost_time_ > tuning_.lost_seconds;
	if (lost) {
		recover_projection_ = true;
		note(monitor_.force(AirEscalation::LOCAL_REPAIR, "corridor lost"));
	}
	cmd.progress = progress_;
	cmd.raw_progress = raw_progress_;
	cmd.corridor_error = error;

	// 3. Terminal state.
	const AirTerminal terminal = corridor_.terminal();
	const Vec3 goal = corridor_.end();
	const float goal_distance = air_distance(p, goal);
	const float arc_left = std::max(0.0f, corridor_.length() - progress_);
	const bool final_leg = arc_left <= lookahead;
	const float remaining = final_leg ? goal_distance : arc_left;
	cmd.remaining = remaining;
	const bool settle = terminal == AirTerminal::HOVER && goal_distance <= profile_.settle_radius;
	bool arrival_tick = false;
	if (!arrived_) {
		if (terminal == AirTerminal::HOVER && goal_distance <= profile_.arrival_radius && speed <= profile_.arrival_speed) {
			arrived_ = arrival_tick = true;
		} else if (terminal == AirTerminal::PASS &&
				(goal_distance <= std::max(profile_.arrival_radius, speed * dt * 1.5f) ||
						(progress_ >= corridor_.length() - 1.0e-3f && pr.distance <= profile_.corridor_tolerance))) {
			arrived_ = arrival_tick = true;
		}
	}
	const bool partial_end =
			terminal == AirTerminal::PARTIAL && goal_distance <= std::max(profile_.arrival_radius, margin_ + 1.0f) &&
			speed <= std::max(profile_.arrival_speed, 0.5f);

	// 4. Unknown or non-FREE start.
	bool start_unknown = false;
	const bool start_clear = air_point_clear(space, p, &start_unknown);
	if (!start_clear && !start_unknown && space.sample(p) == Cell::UNKNOWN) {
		start_unknown = true;
	}
	const bool escape = !start_clear && !start_unknown;

	// 5. Reference direction and speed.
	const float look_s = corridor_.clamp_lookahead(progress_, std::min(corridor_.length(), progress_ + lookahead));
	Vec3 look = look_s >= corridor_.length() - 1.0e-4f ? goal : corridor_.point_at(look_s);
	cmd.lookahead = look;
	Vec3 to_look = v_sub(look, p);
	Vec3 dir_ref = v_norm(to_look);
	if (v_len(to_look) < 1.0e-4f) {
		dir_ref = Vec3{0, 0, 0};
	}
	const float requested = in.requested_speed < 0.0f || !std::isfinite(in.requested_speed)
			? profile_.max_speed
			: std::min(in.requested_speed, profile_.max_speed);
	// Plans brake at a share of the motor's braking so a tick of lag can always be caught up.
	const float b_plan = profile_.brake * clampf(tuning_.brake_share, 0.1f, 1.0f);
	float s_target = requested;
	AirSpeedLimit limit = in.requested_speed < 0.0f ? AirSpeedLimit::CAPABILITY : AirSpeedLimit::REQUESTED;
	auto bound = [&](float value, AirSpeedLimit why) {
		if (value < s_target) {
			s_target = std::max(0.0f, value);
			limit = why;
		}
	};
	{
		// Curvature preview along the 3D arc, and the terminal speed at the end.
		const float preview = std::max(speed, requested) * std::max(speed, requested) / (2.0f * b_plan) + lookahead;
		int32_t which = -1;
		const float v_preview = corridor_.preview_speed(progress_, preview, b_plan, &which);
		bound(v_preview, which == int32_t(corridor_.size()) ? AirSpeedLimit::ARRIVAL : AirSpeedLimit::CURVE);
		// Arrival braking on the remaining distance (straight in the final leg).
		if (terminal == AirTerminal::PASS) {
			const float e = corridor_.end_speed();
			bound(std::sqrt(e * e + 2.0f * b_plan * remaining), AirSpeedLimit::ARRIVAL);
		} else {
			bound(std::min(std::sqrt(2.0f * b_plan * remaining), tuning_.hover_gain * remaining + 0.02f),
					AirSpeedLimit::ARRIVAL);
		}
		// Climb / descent rate on the current segment.
		const Vec3 seg = corridor_.direction_at(progress_);
		if (seg.y > 1.0e-3f) {
			bound(profile_.climb_rate / seg.y, AirSpeedLimit::VERTICAL);
		} else if (seg.y < -1.0e-3f) {
			bound(profile_.descent_rate / -seg.y, AirSpeedLimit::VERTICAL);
		}
	}
	// Known-safe streaming horizon.
	AirHorizonConfig hc;
	hc.latency = latency_;
	hc.margin = margin_;
	hc.braking = b_plan;
	hc.capability = profile_.max_speed;
	AirHorizonQuery hq;
	hq.actor = p;
	hq.points = &corridor_.points();
	hq.cumulative = &corridor_.cumulative();
	hq.progress = progress_;
	hq.terminal_end = terminal != AirTerminal::PARTIAL;
	hq.speed = speed;
	hq.wanted_speed = s_target;
	const AirHorizon horizon = air_evaluate_horizon(space, hq, hc);
	cmd.horizon = horizon;
	cmd.voxels += horizon.voxels;
	if (escape) {
		bound(profile_.hover_speed, AirSpeedLimit::ESCAPE); // the horizon starts in non-FREE volume
	} else {
		bound(horizon.speed_limit, AirSpeedLimit::HORIZON);
	}
	cmd.speed_limit = s_target;
	cmd.limit = limit;

	// 6. Candidates.
	Context c;
	c.p0 = p;
	c.v0 = v;
	c.dt = dt;
	c.yaw = in.yaw;
	c.settle = settle;
	c.escape = escape;
	c.neighbours = in.neighbours;
	c.neighbour_count = in.neighbours != nullptr ? in.neighbour_count : 0;
	c.progress = progress_;
	c.window_ahead = window_ahead;
	c.s_target = s_target;
	c.has_pref = in.has_preferred && finite3(in.preferred_velocity);
	c.pref = c.has_pref ? in.preferred_velocity : Vec3{0, 0, 0};
	c.previous_desired = previous_desired_;
	c.b_plan = b_plan;
	c.rem0 = remaining;
	c.end_speed = terminal == AirTerminal::PASS ? corridor_.end_speed() : 0.0f;
	c.horizon_known = (horizon.reason == AirHorizonReason::CLEAR || horizon.reason == AirHorizonReason::TERMINAL || escape)
			? -1.0f
			: horizon.known_safe;
	c.latency = latency_;
	c.margin = margin_;
	c.pass = terminal == AirTerminal::PASS;
	c.hover_gain = tuning_.hover_gain;

	const bool failed = monitor_.level() == AirEscalation::FAILED;
	const bool holding = (arrived_ && terminal == AirTerminal::HOVER) || failed || start_unknown ||
			(arrived_ && terminal == AirTerminal::PASS);
	const bool repair = monitor_.level() >= AirEscalation::LOCAL_REPAIR && !failed;
	const float hold_time = std::max(dt, tuning_.control_horizon);
	candidates_.clear();
	uint32_t order = 0;
	auto add = [&](AirCandidateKind kind, const Vec3 &direction, float spd, float hold, bool pursuit = false,
						 float look_scale = 1.0f) {
		Candidate k;
		k.kind = kind;
		k.direction = direction;
		k.speed = std::max(0.0f, spd);
		k.hold = hold;
		k.pursuit = pursuit;
		k.look_scale = look_scale;
		k.order = order++;
		candidates_.push_back(k);
	};
	const Vec3 heading = speed > 1.0e-3f ? v_scale(v, 1.0f / speed) : dir_ref;
	if (holding) {
		if (arrived_ && terminal == AirTerminal::HOVER && !failed && !start_unknown) {
			add(AirCandidateKind::HOVER_HOLD, v_sub(goal, p),
					std::min(profile_.hover_speed, tuning_.hover_gain * goal_distance), hold_time);
		}
		add(AirCandidateKind::BRAKE, heading, 0.0f, hold_time);
	} else {
		const float slow = s_target * tuning_.slow_share;
		add(AirCandidateKind::REFERENCE, dir_ref, s_target, hold_time, true, 1.0f);
		if (has_plan_ && plan_hold_left_ - dt >= dt) {
			add(AirCandidateKind::CONTINUE, plan_direction_, std::min(plan_speed_, s_target), plan_hold_left_ - dt,
					plan_pursuit_, plan_look_scale_);
		}
		{
			const float track_s = corridor_.clamp_lookahead(
					progress_, std::min(corridor_.length(), progress_ + std::max(0.5f, TRACK_SCALE * lookahead)));
			const Vec3 tp = track_s >= corridor_.length() - 1.0e-4f ? goal : corridor_.point_at(track_s);
			add(AirCandidateKind::TRACK, v_sub(tp, p), s_target, hold_time, true, TRACK_SCALE);
		}
		struct Turn {
			AirCandidateKind kind;
			float yaw;
			float pitch;
		};
		const float sa = tuning_.small_angle, wa = tuning_.wide_angle, ra = tuning_.repair_angle;
		const Turn turns[] = {
			{AirCandidateKind::YAW_LEFT_SMALL, sa, 0.0f},
			{AirCandidateKind::YAW_RIGHT_SMALL, -sa, 0.0f},
			{AirCandidateKind::PITCH_UP_SMALL, 0.0f, sa},
			{AirCandidateKind::PITCH_DOWN_SMALL, 0.0f, -sa},
			{AirCandidateKind::YAW_LEFT_WIDE, wa, 0.0f},
			{AirCandidateKind::YAW_RIGHT_WIDE, -wa, 0.0f},
			{AirCandidateKind::YAW_LEFT_REPAIR, ra, 0.0f},
			{AirCandidateKind::YAW_RIGHT_REPAIR, -ra, 0.0f},
			{AirCandidateKind::PITCH_UP_REPAIR, 0.0f, ra},
			{AirCandidateKind::PITCH_DOWN_REPAIR, 0.0f, -ra},
		};
		const Vec3 base = v_len(dir_ref) > 0.0f ? dir_ref : forward_of_yaw(in.yaw);
		for (const Turn &t : turns) {
			const bool repair_only = t.kind >= AirCandidateKind::YAW_LEFT_REPAIR;
			if (repair_only && !repair) {
				continue;
			}
			const Vec3 d = t.pitch != 0.0f ? pitch_dir(base, t.pitch, in.yaw) : rot_y(base, t.yaw);
			add(t.kind, d, s_target, hold_time);
			add(t.kind, d, slow, hold_time);
		}
		add(AirCandidateKind::REFERENCE, dir_ref, slow, hold_time, true, 1.0f);
		if (c.has_pref) {
			const float ps = std::min(v_len(c.pref), s_target);
			add(AirCandidateKind::PREFERRED, c.pref, ps, hold_time);
			add(AirCandidateKind::PREFERRED, c.pref, ps * tuning_.slow_share, hold_time);
		}
		add(AirCandidateKind::BRAKE_STEER, v_len(dir_ref) > 0.0f ? dir_ref : heading, 0.0f, hold_time, true, 1.0f);
		add(AirCandidateKind::BRAKE, heading, 0.0f, hold_time);
	}
	float best_gain = 0.0f;
	for (Candidate &k : candidates_) {
		score(c, k);
		best_gain = std::max(best_gain, k.gain);
	}
	const float gain_norm = std::max(0.05f, best_gain);
	for (Candidate &k : candidates_) {
		k.score = -tuning_.weight_progress * k.gain / gain_norm + k.cost;
	}
	std::stable_sort(candidates_.begin(), candidates_.end(), [](const Candidate &a, const Candidate &b) {
		if (a.score != b.score) {
			return a.score < b.score;
		}
		return a.order < b.order;
	});
	cmd.candidates = uint32_t(candidates_.size());
	const Candidate *chosen = nullptr;
	bool reference_neighbour = false;
	bool any_neighbour = false;
	for (const Candidate &k : candidates_) {
		predict(c, k, scratch_points_, scratch_velocities_, true);
		bool neighbour_failed = false;
		uint32_t voxels = 0;
		++cmd.certified_tries;
		const bool ok = certify(space, c, scratch_points_, scratch_velocities_, voxels, neighbour_failed);
		cmd.voxels += voxels;
		if (neighbour_failed) {
			any_neighbour = true;
			if (k.kind == AirCandidateKind::REFERENCE && k.order == 0) {
				reference_neighbour = true;
			}
		}
		if (ok) {
			chosen = &k;
			break;
		}
	}
	Candidate emergency;
	if (chosen == nullptr) {
		emergency.kind = AirCandidateKind::EMERGENCY;
		emergency.direction = heading;
		emergency.speed = 0.0f;
		emergency.hold = dt;
		emergency.first = air_step_velocity(v, heading, 0.0f, profile_, dt, settle);
		chosen = &emergency;
		no_safe_time_ += dt;
	} else {
		no_safe_time_ = 0.0f;
	}
	if (no_safe_time_ > tuning_.no_safe_seconds) {
		note(monitor_.force(AirEscalation::LOCAL_REPAIR, "no safe trajectory"));
	}

	// 7. Command and pose hints.
	cmd.candidate = chosen->kind;
	cmd.velocity = chosen->first;
	cmd.desired = v_scale(v_norm(chosen->direction), chosen->speed);
	has_plan_ = chosen->kind != AirCandidateKind::EMERGENCY;
	plan_direction_ = chosen->direction;
	plan_speed_ = chosen->speed;
	plan_hold_left_ = chosen->hold;
	plan_pursuit_ = chosen->pursuit;
	plan_look_scale_ = chosen->look_scale;
	previous_desired_ = cmd.desired;
	{
		const Vec3 cv = cmd.velocity;
		const float hc_speed = h_len(cv);
		const float ha_speed = h_len(v);
		cmd.yaw = hc_speed > 0.5f ? yaw_of(cv) : in.yaw;
		cmd.pitch = v_len(cv) > 0.5f ? std::atan2(cv.y, hc_speed) : 0.0f;
		float bank = 0.0f;
		if (hc_speed > 0.5f && ha_speed > 0.5f) {
			const float yaw_rate = wrapf(yaw_of(cv) - yaw_of(v)) / dt;
			bank = std::atan2(hc_speed * yaw_rate, GRAVITY);
		}
		cmd.bank = clampf(bank, -1.0f, 1.0f);
	}

	// 8. Classification, escalation, mode and reason.
	AirFollowClass klass = AirFollowClass::FOLLOWING;
	if (holding && !start_unknown) {
		klass = AirFollowClass::HOLDING;
	} else if (start_unknown ||
			(horizon.reason == AirHorizonReason::UNKNOWN_AHEAD && horizon.limited && s_target < profile_.hover_speed)) {
		klass = AirFollowClass::WAITING_GEOMETRY;
	} else if (partial_end) {
		klass = AirFollowClass::WAITING_ROUTE;
	} else if (reference_neighbour && chosen->kind != AirCandidateKind::REFERENCE) {
		klass = AirFollowClass::YIELDING;
	}
	cmd.klass = klass;
	AirStallSample sample;
	sample.route = route_;
	sample.progress = progress_;
	sample.raw_progress = raw_progress_;
	sample.intent_progress = intent_progress_;
	sample.position = p;
	sample.yaw = h_len(v) > 0.3f ? yaw_of(v) : in.yaw;
	sample.goal_distance = remaining;
	sample.command = v_len(cmd.velocity);
	sample.actual = speed;
	ideal_speed_ = std::min(s_target, ideal_speed_ + profile_.accel * dt);
	sample.permitted = ideal_speed_; // the monitor counts it only while (effectively) following
	sample.gained = gained;
	note(monitor_.update(dt, klass, sample));
	cmd.escalation = monitor_.level();
	cmd.entered = entered;

	const bool brake_kind = chosen->kind == AirCandidateKind::BRAKE || chosen->kind == AirCandidateKind::BRAKE_STEER ||
			chosen->kind == AirCandidateKind::EMERGENCY;
	if (monitor_.level() == AirEscalation::FAILED && !failed_reported_) {
		failed_reported_ = true;
		cmd.failed_event = true;
		cmd.mode = AirCommandMode::FAILED;
	} else if (arrival_tick) {
		cmd.arrived_event = true;
		cmd.mode = AirCommandMode::ARRIVED;
	} else if (holding || partial_end || chosen->kind == AirCandidateKind::HOVER_HOLD) {
		cmd.mode = AirCommandMode::HOLD;
	} else if (brake_kind) {
		cmd.mode = v_len(cmd.velocity) <= profile_.arrival_speed ? AirCommandMode::HOLD : AirCommandMode::BRAKE;
	} else {
		cmd.mode = AirCommandMode::TRAVEL;
	}

	const int32_t seg = corridor_.segment_at(progress_);
	const bool steep_here = size_t(seg) < corridor_.steep().size() && corridor_.steep()[size_t(seg)] != 0;
	const bool wants_down = cmd.desired.y < -1.0e-3f;
	const bool cannot_descend = wants_down && cmd.velocity.y > cmd.desired.y + 0.05f &&
			h_len(cmd.velocity) < profile_.min_descent_speed;
	int32_t reason = AIR_REASON_NONE;
	if (monitor_.level() == AirEscalation::FAILED) {
		reason = AIR_REASON_FAILED;
	} else if (start_unknown) {
		reason = AIR_REASON_UNKNOWN_HERE;
	} else if (arrival_tick) {
		reason = AIR_REASON_ARRIVED;
	} else if (arrived_ && terminal == AirTerminal::HOVER) {
		reason = AIR_REASON_HOVER_HOLD;
	} else if (chosen->kind == AirCandidateKind::EMERGENCY) {
		reason = AIR_REASON_NO_SAFE_TRAJECTORY;
	} else if (blocked_ahead_) {
		reason = AIR_REASON_CORRIDOR_BLOCKED;
	} else if (escape) {
		reason = AIR_REASON_ESCAPING;
	} else if (partial_end || (monitor_.awaiting_route() && cmd.mode != AirCommandMode::TRAVEL)) {
		reason = AIR_REASON_WAITING_ROUTE;
	} else if (horizon.limited && limit == AirSpeedLimit::HORIZON && horizon.reason == AirHorizonReason::UNKNOWN_AHEAD) {
		reason = AIR_REASON_UNKNOWN_AHEAD;
	} else if (horizon.limited && limit == AirSpeedLimit::HORIZON && horizon.reason == AirHorizonReason::SOLID_AHEAD) {
		reason = AIR_REASON_SOLID_AHEAD;
	} else if (any_neighbour && chosen->kind != AirCandidateKind::REFERENCE) {
		reason = AIR_REASON_NEIGHBOUR;
	} else if (lost) {
		reason = AIR_REASON_CORRIDOR_LOST;
	} else if (steep_here) {
		reason = AIR_REASON_DESCENT_TOO_STEEP;
	} else if (cannot_descend) {
		reason = AIR_REASON_DESCENT_NEEDS_SPEED;
	} else if (repair) {
		reason = AIR_REASON_REPAIR;
	} else if (chosen->kind == AirCandidateKind::PREFERRED) {
		reason = AIR_REASON_PREFERRED;
	} else if (limit == AirSpeedLimit::HORIZON && horizon.limited) {
		reason = AIR_REASON_HORIZON_LIMITED;
	}
	cmd.reason = reason;
	return cmd;
}

} // namespace nav_air
