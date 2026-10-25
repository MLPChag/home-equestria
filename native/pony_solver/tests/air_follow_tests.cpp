// Standalone tests for the air follower slice (nav_air: air_follow, air_governor) on the in-memory
// TestAirSpace. No Godot. Build: build_air_follow_tests.sh OUTPUT_DIR.
// The simulated motor applies each command's velocity for one tick exactly; every executed tick
// segment is certified independently against the space (supercover, UNKNOWN fails), and the
// descent rule is checked on every executed velocity. Each test answers a behaviour question.
#include "air_follow.h"
#include "air_search.h"
#include "air_test_space.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <set>
#include <vector>

using namespace nav_air;

namespace {

int failures = 0;
int checks = 0;

#define CHECK(condition, label)                                             \
	do {                                                                    \
		++checks;                                                           \
		if (!(condition)) {                                                 \
			++failures;                                                     \
			std::printf("  FAIL %s (%s:%d)\n", label, __FILE__, __LINE__); \
		}                                                                   \
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

float dist(const Vec3 &a, const Vec3 &b) {
	return air_distance(a, b);
}

float len(const Vec3 &a) {
	return std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
}

float hlen(const Vec3 &a) {
	return std::sqrt(a.x * a.x + a.z * a.z);
}

constexpr float DT = 1.0f / 60.0f;

// Minimum distance between two points moving linearly over [0, dt].
float min_separation(const Vec3 &a, const Vec3 &va, const Vec3 &b, const Vec3 &vb, float dt) {
	const Vec3 r{a.x - b.x, a.y - b.y, a.z - b.z};
	const Vec3 w{va.x - vb.x, va.y - vb.y, va.z - vb.z};
	const float w2 = w.x * w.x + w.y * w.y + w.z * w.z;
	float t = w2 > 0.0f ? -(r.x * w.x + r.y * w.y + r.z * w.z) / w2 : 0.0f;
	t = std::max(0.0f, std::min(dt, t));
	return len(Vec3{r.x + w.x * t, r.y + w.y * t, r.z + w.z * t});
}

struct Flight {
	Vec3 p{0, 0, 0};
	Vec3 v{0, 0, 0};
	float yaw = 0.0f;
	float t = 0.0f;
	float requested = -1.0f;
	std::vector<AirNeighbour> neighbours;
	bool has_preferred = false;
	Vec3 preferred{0, 0, 0};
};

struct Stats {
	int ticks = 0;
	int arrived_events = 0;
	int failed_events = 0;
	float arrive_time = -1.0f;
	float max_speed = 0.0f;
	float max_error = 0.0f;
	bool unsafe = false;
	Vec3 unsafe_at{0, 0, 0};
	bool descent_violation = false;
	Vec3 descent_at{0, 0, 0};
	std::set<int32_t> reasons;
	std::set<int> limits;
	std::set<int> candidates;
	std::set<int> classes;
	AirEscalation max_level = AirEscalation::NONE;
	uint64_t hash = 1469598103934665603ull;
	std::vector<double> step_us;
};

void hash_float(uint64_t &h, float f) {
	uint32_t bits;
	static_assert(sizeof(bits) == sizeof(f), "float size");
	std::memcpy(&bits, &f, sizeof(f));
	h ^= bits;
	h *= 1099511628211ull;
}

// Runs the follower for at most `seconds`, stopping `after_arrival` seconds after arrival.
// `tick(cmd)` may change the world or the flight between ticks; returning false stops.
template <class Tick>
Stats fly(const AirSpace &space, AirFollower &f, Flight &fl, float seconds, float after_arrival, Tick tick) {
	Stats s;
	const AirFlightProfile &prof = f.profile();
	float stop_at = seconds;
	while (fl.t < stop_at) {
		AirFollowInput in;
		in.position = fl.p;
		in.velocity = fl.v;
		in.yaw = fl.yaw;
		in.dt = DT;
		in.requested_speed = fl.requested;
		in.neighbours = fl.neighbours.empty() ? nullptr : fl.neighbours.data();
		in.neighbour_count = fl.neighbours.size();
		in.has_preferred = fl.has_preferred;
		in.preferred_velocity = fl.preferred;
		const auto t0 = std::chrono::steady_clock::now();
		const AirFollowCommand cmd = f.step(space, in);
		s.step_us.push_back(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count());
		// Motor: apply the command for one tick.
		const Vec3 next{fl.p.x + cmd.velocity.x * DT, fl.p.y + cmd.velocity.y * DT, fl.p.z + cmd.velocity.z * DT};
		if (!s.unsafe && !air_segment_clear(space, fl.p, next)) {
			s.unsafe = true;
			s.unsafe_at = fl.p;
		}
		const Vec3 cv = cmd.velocity;
		if (cv.y < -1.0e-4f) {
			const float h = hlen(cv);
			const bool glide = h >= prof.min_descent_speed - 1.0e-3f && -cv.y <= h / prof.glide_ratio + 1.0e-3f &&
					-cv.y <= prof.descent_rate + 1.0e-3f;
			const bool settle = f.corridor().terminal() == AirTerminal::HOVER &&
					dist(fl.p, f.corridor().end()) <= prof.settle_radius + 1.0e-3f && -cv.y <= prof.settle_rate + 1.0e-4f;
			if (!glide && !settle && !s.descent_violation) {
				s.descent_violation = true;
				s.descent_at = fl.p;
			}
		}
		if (cv.y > prof.climb_rate + 1.0e-3f) {
			s.descent_violation = true; // climb limit broken (reported with the same flag)
		}
		fl.p = next;
		fl.v = cmd.velocity;
		fl.yaw = cmd.yaw;
		fl.t += DT;
		for (AirNeighbour &n : fl.neighbours) {
			n.position = Vec3{n.position.x + n.velocity.x * DT, n.position.y + n.velocity.y * DT, n.position.z + n.velocity.z * DT};
		}
		++s.ticks;
		s.max_speed = std::max(s.max_speed, len(cmd.velocity));
		s.max_error = std::max(s.max_error, cmd.corridor_error);
		s.reasons.insert(cmd.reason);
		s.limits.insert(int(cmd.limit));
		s.candidates.insert(int(cmd.candidate));
		s.classes.insert(int(cmd.klass));
		s.max_level = std::max(s.max_level, cmd.escalation);
		hash_float(s.hash, cmd.velocity.x);
		hash_float(s.hash, cmd.velocity.y);
		hash_float(s.hash, cmd.velocity.z);
		if (cmd.arrived_event) {
			++s.arrived_events;
			if (s.arrive_time < 0.0f) {
				s.arrive_time = fl.t;
				stop_at = std::min(seconds, fl.t + after_arrival);
			}
		}
		if (cmd.failed_event) {
			++s.failed_events;
		}
		if (!tick(cmd)) {
			break;
		}
	}
	return s;
}

Stats fly(const AirSpace &space, AirFollower &f, Flight &fl, float seconds, float after_arrival = 1.0f) {
	return fly(space, f, fl, seconds, after_arrival, [](const AirFollowCommand &) { return true; });
}

double percentile(std::vector<double> v, double q) {
	if (v.empty()) {
		return 0.0;
	}
	std::sort(v.begin(), v.end());
	const size_t i = std::min(v.size() - 1, size_t(q * double(v.size() - 1) + 0.5));
	return v[i];
}

void open_space(TestAirSpace &s, const Aabb &b) {
	s.add_tiles(b, Cell::FREE);
}

AirFollowCorridor raw_corridor(const AirSpace &space, const std::vector<Vec3> &points, const AirFlightProfile &prof,
		AirTerminal terminal = AirTerminal::HOVER) {
	AirFollowCorridor c;
	const bool ok = c.build(space, points, std::vector<float>(), prof, terminal);
	CHECK(ok, "raw corridor builds");
	return c;
}

bool search(const AirSpace &space, const Vec3 &a, const Vec3 &b, std::vector<Vec3> &route) {
	AirSearch s;
	AirSearchLimits l;
	l.slice_seconds = 0.0;
	l.slice_expansions = 1u << 30;
	const AirStatus st = s.begin(space, a, AirGoal::point(b), l);
	const AirStatus end = st == AirStatus::PENDING ? s.run_to_end() : st;
	if (end != AirStatus::COMPLETE) {
		std::printf("  search status %s\n", air_status_name(end));
		return false;
	}
	route = s.route().points;
	return true;
}

// ------------------------------------------------------------------ tests

void test_motor_model() {
	section("motor model and pose sign");
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	// Hovering, asked straight down: no descent at all.
	Vec3 v{0, 0, 0};
	for (int i = 0; i < 120; ++i) {
		v = air_step_velocity(v, v3(0, -1, 0), 8.0f, prof, DT, false);
	}
	CHECK(std::fabs(v.y) < 1.0e-6f && hlen(v) < 1.0e-6f, "hover asked straight down stays put");
	// Settle near a hover goal allows only the small correction.
	v = Vec3{0, 0, 0};
	for (int i = 0; i < 60; ++i) {
		v = air_step_velocity(v, v3(0, -1, 0), 8.0f, prof, DT, true);
	}
	CHECK(std::fabs(v.y + prof.settle_rate) < 1.0e-5f, "settle correction capped at settle_rate");
	// Forward and down at speed: a glide at most 1 / glide_ratio steep.
	v = Vec3{0, 0, -10};
	for (int i = 0; i < 240; ++i) {
		v = air_step_velocity(v, v3(0, -1, -1), 10.0f, prof, DT, false);
	}
	CHECK(v.y < -1.0f && -v.y <= hlen(v) / prof.glide_ratio + 1.0e-4f, "diving request becomes a glide");
	// Climb rate cap.
	v = Vec3{0, 0, 0};
	for (int i = 0; i < 240; ++i) {
		v = air_step_velocity(v, v3(0, 1, 0), 20.0f, prof, DT, false);
	}
	CHECK(std::fabs(v.y - prof.climb_rate) < 1.0e-4f, "vertical climb at climb_rate");
	// Turn rate: at 20 m/s the heading turns at most lateral_accel / v = 0.5 rad/s.
	v = Vec3{0, 0, -20};
	const Vec3 v1 = air_step_velocity(v, v3(-1, 0, 0), 20.0f, prof, DT, false);
	const float turned = std::acos(std::max(-1.0f, std::min(1.0f, (v.x * v1.x + v.z * v1.z) / (len(v) * len(v1)))));
	CHECK(std::fabs(turned - 0.5f * DT) < 1.0e-4f, "turn limited by lateral acceleration");
	// Godot sign: facing -Z (yaw 0), a target toward world -X turns left: positive yaw and bank.
	TestAirSpace s;
	open_space(s, box(-64, 0, -64, 64, 64, 64));
	AirFollower f;
	f.set_profile(prof);
	const AirFollowCorridor c = raw_corridor(s, {v3(0, 20, 0), v3(-40, 20, 0)}, prof);
	f.begin(c, 1);
	AirFollowInput in;
	in.position = v3(0, 20, 0);
	in.velocity = v3(0, 0, -10);
	in.yaw = 0.0f;
	const AirFollowCommand cmd = f.step(s, in);
	CHECK(cmd.yaw > 0.0f, "target to -X at yaw 0 gives positive yaw");
	CHECK(cmd.bank > 0.0f, "left turn banks left wing down (positive)");
	std::printf("  yaw %.4f rad, bank %.4f rad, candidate %s\n", cmd.yaw, cmd.bank, air_candidate_name(cmd.candidate));
}

void test_straight() {
	section("straight corridor");
	TestAirSpace s;
	open_space(s, box(-32, 0, -32, 160, 64, 32));
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	AirFollower f;
	f.set_profile(prof);
	f.begin(raw_corridor(s, {v3(0, 20, 0), v3(120, 20, 0)}, prof), 1);
	Flight fl;
	fl.p = v3(0, 20, 0);
	fl.yaw = -0.5f * 3.14159265f; // facing +X
	float slow_run = 0.0f, worst_slow = 0.0f;
	const Stats st = fly(s, f, fl, 30.0f, 1.0f, [&](const AirFollowCommand &cmd) {
		const bool middle = fl.t > 0.5f && cmd.remaining > 2.0f;
		if (middle && len(fl.v) < 0.05f) {
			slow_run += DT;
			worst_slow = std::max(worst_slow, slow_run);
		} else {
			slow_run = 0.0f;
		}
		return true;
	});
	CHECK(st.arrived_events == 1, "arrives once");
	CHECK(!st.unsafe, "every tick certified");
	CHECK(st.max_speed > 19.9f && st.max_speed <= 20.0f + 1.0e-3f, "reaches cruise, never above it");
	CHECK(st.max_error < 0.05f, "stays on the line");
	CHECK(dist(fl.p, v3(120, 20, 0)) <= prof.arrival_radius && len(fl.v) <= prof.arrival_speed, "stopped at the end");
	CHECK(worst_slow <= 0.25f, "no stop mid-route");
	// Ideal accelerate / cruise / brake time is 9.05 s; allow the final hover approach.
	CHECK(st.arrive_time > 0.0f && st.arrive_time < 11.0f, "arrival time near ideal");
	std::printf("  arrived at %.2f s, max speed %.2f, max error %.4f m, final %.3f m %.3f m/s, step p50 %.1f us p95 %.1f us\n",
			st.arrive_time, st.max_speed, st.max_error, dist(fl.p, v3(120, 20, 0)), len(fl.v), percentile(st.step_us, 0.5),
			percentile(st.step_us, 0.95));
}

void test_corner() {
	section("90 degree air corner");
	TestAirSpace s;
	open_space(s, box(-32, 0, -64, 160, 64, 160));
	// A building fills the inside of the corner (all heights), so the route must turn 90 degrees.
	s.fill_box(box(-32, 0, 4, 72, 64, 160), Cell::SOLID);
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	std::vector<Vec3> route;
	CHECK(search(s, v3(0, 20, 0), v3(100, 20, 120), route), "corner: search");
	for (int smooth = 1; smooth >= 0; --smooth) {
		AirPrepareOptions opt;
		opt.smooth = smooth != 0;
		AirFollowCorridor c;
		const AirPrepareStatus ps = air_prepare_corridor(s, route, prof, AirTerminal::HOVER, 0.0f, opt, c);
		CHECK(ps == AirPrepareStatus::OK, "corner corridor prepared");
		AirFollower f;
		f.set_profile(prof);
		f.begin(c, 1);
		Flight fl;
		fl.p = route[0];
		float min_mid = 1.0e9f;
		bool reached5 = false;
		const Stats st = fly(s, f, fl, 40.0f, 1.0f, [&](const AirFollowCommand &cmd) {
			if (len(fl.v) > 5.0f) {
				reached5 = true;
			}
			if (reached5 && cmd.remaining > 10.0f) {
				min_mid = std::min(min_mid, len(fl.v));
			}
			return true;
		});
		CHECK(st.arrived_events == 1, "corner: arrives once");
		CHECK(!st.unsafe, "corner: every tick certified");
		CHECK(dist(fl.p, v3(100, 20, 120)) <= prof.arrival_radius, "corner: at the goal");
		if (smooth) {
			CHECK(min_mid > 3.0f, "smoothed 90 degree corner flown without stopping");
		} else {
			// Unsmoothed, the corner may only be cut inside the certified clearance of the segments
			// that meet there (AirFollowCorridor slack); it must stay inside it and fly the bend slower
			// than the smoothed corridor allows.
			float slack = 0.0f;
			for (size_t i = 1; i + 1 < c.size(); ++i) {
				slack = std::max(slack, std::min(c.clearance()[i - 1], c.clearance()[i]));
			}
			std::printf("  sharp: corner slack %.2f m\n", slack);
			CHECK(st.max_error <= slack + 0.05f, "sharp corner: cuts only inside its certified slack");
			CHECK(min_mid < 4.0f, "sharp corner: slows for the bend");
		}
		float turn = 0.0f;
		for (size_t i = 1; i + 1 < c.size(); ++i) {
			const Vec3 a = c.points()[i - 1], b = c.points()[i], d = c.points()[i + 1];
			const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z}, w{d.x - b.x, d.y - b.y, d.z - b.z};
			turn += std::acos(std::max(-1.0f, std::min(1.0f, (u.x * w.x + u.y * w.y + u.z * w.z) / (len(u) * len(w)))));
		}
		std::printf("  %s: %zu points, total turn %.1f deg, min speed through the corner %.2f m/s, arrived %.2f s, max error %.2f m\n",
				smooth ? "smoothed" : "sharp", c.size(), turn * 57.2958f, min_mid, st.arrive_time, st.max_error);
		if (smooth) {
			CHECK(turn > 1.3f, "corner: the corridor really turns about 90 degrees");
		}
	}
}

void test_stop_corners() {
	section("zero-clearance corners do not reward cutting across the bend");
	TestAirSpace s;
	open_space(s, box(-64, 0, -96, 128, 64, 96));
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	for (float degrees : {30.0f, 90.0f, 135.0f, -30.0f, -90.0f, -135.0f}) {
		const float angle = degrees * 0.01745329252f;
		const Vec3 goal = v3(40.0f + 40.0f * std::cos(angle), 20, 40.0f * std::sin(angle));
		AirFollower f;
		f.set_profile(prof);
		f.begin(raw_corridor(s, {v3(0,20,0), v3(40,20,0), goal}, prof), 1);
		Flight fl;
		fl.p = v3(0,20,0);
		const Stats st = fly(s, f, fl, 30.0f);
		CHECK(st.arrived_events == 1, "stop corner reaches its goal once");
		CHECK(!st.unsafe, "stop corner keeps every executed tick certified");
		CHECK(st.max_error <= 0.05f, "stop corner stays within zero-clearance numerical margin");
		std::printf("  %.0f degrees: arrived %.2f s, max error %.4f m\n", degrees, st.arrive_time, st.max_error);
	}
}

void test_climb_over() {
	section("climb over an obstacle");
	TestAirSpace s;
	open_space(s, box(-32, 0, -32, 160, 64, 32));
	s.fill_box(box(-32, 0, -32, 160, 2, 32), Cell::SOLID); // ground
	s.fill_box(box(60, 0, -32, 61, 20, 32), Cell::SOLID); // wall across the whole width
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	std::vector<Vec3> route;
	const bool found = search(s, v3(10, 5, 0), v3(120, 5, 0), route);
	CHECK(found, "search finds the way over");
	AirFollowCorridor c;
	const AirPrepareStatus ps = air_prepare_corridor(s, route, prof, AirTerminal::HOVER, 0.0f, AirPrepareOptions(), c);
	CHECK(ps == AirPrepareStatus::OK, "prepared (descents shaped)");
	AirFollower f;
	f.set_profile(prof);
	f.begin(c, 1);
	Flight fl;
	fl.p = v3(10, 5, 0);
	float top = 0.0f;
	float min_mid = 1.0e9f;
	bool moving = false;
	const Stats st = fly(s, f, fl, 60.0f, 1.0f, [&](const AirFollowCommand &cmd) {
		if (fl.p.x >= 59.5f && fl.p.x <= 61.5f) {
			top = std::max(top, fl.p.y);
		}
		moving = moving || len(fl.v) > 3.0f;
		if (moving && cmd.remaining > 6.0f) {
			min_mid = std::min(min_mid, len(fl.v));
		}
		return true;
	});
	CHECK(st.arrived_events == 1, "arrives over the wall");
	CHECK(!st.unsafe, "never crosses the wall or the ground");
	CHECK(top > 20.0f, "passes above the wall top");
	CHECK(!st.descent_violation, "descent only as a forward glide");
	CHECK(dist(fl.p, v3(120, 5, 0)) <= prof.arrival_radius, "at the goal height");
	std::printf("  route %zu -> corridor %zu points, length %.1f m, height over the wall %.2f m, min speed %.2f m/s, arrived %.2f s\n",
			route.size(), c.size(), c.length(), top, min_mid, st.arrive_time);
}

void test_descent_needs_speed() {
	section("descent requires forward speed");
	TestAirSpace s;
	open_space(s, box(-64, 0, -64, 64, 64, 64));
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	// Raw vertical corridor straight down: she must not drop while hovering.
	{
		AirFollower f;
		f.set_profile(prof);
		f.begin(raw_corridor(s, {v3(0, 40, 0), v3(0, 10, 0)}, prof), 1);
		Flight fl;
		fl.p = v3(0, 40, 0);
		float y_at_2s = 0.0f;
		const Stats st = fly(s, f, fl, 6.0f, 0.0f, [&](const AirFollowCommand &) {
			if (std::fabs(fl.t - 2.5f) < 0.5f * DT) {
				y_at_2s = fl.p.y;
			}
			return true;
		});
		CHECK(!st.descent_violation, "no vertical descent while flapping");
		CHECK(y_at_2s > 40.0f - prof.settle_radius, "hovering, not sinking, before any repair");
		CHECK(st.reasons.count(AIR_REASON_DESCENT_TOO_STEEP) == 1, "reports the steep descent");
		CHECK(st.arrived_events == 0, "no false arrival");
		std::printf("  raw vertical: y after 2.5 s %.3f, after 6 s %.3f, escalation %s\n", y_at_2s, fl.p.y,
				air_escalation_name(st.max_level));
	}
	// The same drop prepared: a glide helix, then the level run-out.
	{
		AirFollowCorridor c;
		uint32_t shaped = 0, failed = 0;
		std::vector<Vec3> shaped_points;
		air_shape_descents(s, {v3(0, 40, 0), v3(0, 10, 0)}, prof, true, shaped_points, &shaped, &failed);
		CHECK(shaped == 1 && failed == 0, "steep drop shaped once");
		const AirPrepareStatus ps =
				air_prepare_corridor(s, {v3(0, 40, 0), v3(0, 10, 0)}, prof, AirTerminal::HOVER, 0.0f, AirPrepareOptions(), c);
		CHECK(ps == AirPrepareStatus::OK, "prepared");
		size_t steep = 0;
		for (uint8_t b : c.steep()) {
			steep += b;
		}
		CHECK(steep == 0, "no segment steeper than the glide slope after shaping");
		AirFollower f;
		f.set_profile(prof);
		f.begin(c, 1);
		Flight fl;
		fl.p = v3(0, 40, 0);
		const Stats st = fly(s, f, fl, 120.0f);
		CHECK(st.arrived_events == 1, "helix descent arrives");
		CHECK(!st.unsafe, "helix: every tick certified");
		CHECK(!st.descent_violation, "helix: descent only as a glide");
		CHECK(std::fabs(fl.p.x) <= 0.25f && std::fabs(fl.p.z) <= 0.25f && std::fabs(fl.p.y - 10.0f) <= 0.25f,
				"arrives at the same X/Z, 30 m lower");
		std::printf("  shaped: %zu points, %.1f m of arc, arrived %.2f s at (%.3f, %.3f, %.3f)\n", c.size(), c.length(),
				st.arrive_time, fl.p.x, fl.p.y, fl.p.z);
	}
}

void test_thin_wall() {
	section("thin wall not cut");
	TestAirSpace s;
	open_space(s, box(-32, 0, -64, 128, 64, 64));
	s.fill_box(box(40.0f, 0, -64, 40.1f, 64, 8), Cell::SOLID); // 10 cm wall, open past z = 8
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	std::vector<Vec3> route;
	const bool found = search(s, v3(20, 20, -10), v3(60, 20, -10), route);
	CHECK(found, "search goes round the wall end");
	AirFollowCorridor c;
	const AirPrepareStatus ps = air_prepare_corridor(s, route, prof, AirTerminal::HOVER, 0.0f, AirPrepareOptions(), c);
	CHECK(ps == AirPrepareStatus::OK, "prepared");
	CHECK(air_polyline_clear(s, c.points(), c.clearance()), "smoothed corridor certifies with its clearance");
	AirFollower f;
	f.set_profile(prof);
	f.begin(c, 1);
	Flight fl;
	fl.p = v3(20, 20, -10);
	bool crossed_wall = false;
	Vec3 last = fl.p;
	const Stats st = fly(s, f, fl, 60.0f, 1.0f, [&](const AirFollowCommand &) {
		// Crossing the wall plane x = 40.05 anywhere with z < 8 (the wall's extent) would be a cut.
		if ((last.x - 40.05f) * (fl.p.x - 40.05f) <= 0.0f && last.x != fl.p.x) {
			const float t = (40.05f - last.x) / (fl.p.x - last.x);
			const float z = last.z + (fl.p.z - last.z) * t;
			if (z < 8.0f) {
				crossed_wall = true;
			}
		}
		last = fl.p;
		return true;
	});
	CHECK(st.arrived_events == 1, "arrives behind the wall");
	CHECK(!st.unsafe, "every tick certified");
	CHECK(!crossed_wall, "never crosses the wall plane");
	std::printf("  corridor %zu points %.1f m, arrived %.2f s, max error %.2f m\n", c.size(), c.length(), st.arrive_time,
			st.max_error);
}

void test_unknown_ahead() {
	section("unknown ahead: slows, stops before it, resumes");
	TestAirSpace s;
	open_space(s, box(-32, -32, -32, 320, 64, 64));
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	AirFollower f;
	f.set_profile(prof);
	f.begin(raw_corridor(s, {v3(0, 16, 16), v3(300, 16, 16)}, prof), 1);
	// Tiles from x = 160 on are evicted after planning.
	for (int tx = 5; tx < 10; ++tx) {
		for (int ty = -1; ty <= 1; ++ty) {
			for (int tz = -1; tz <= 1; ++tz) {
				s.remove_tile(tx, ty, tz);
			}
		}
	}
	Flight fl;
	fl.p = v3(0, 16, 16);
	float max_x = 0.0f;
	bool waited = false;
	const Stats st = fly(s, f, fl, 30.0f, 0.0f, [&](const AirFollowCommand &cmd) {
		max_x = std::max(max_x, fl.p.x);
		if (cmd.klass == AirFollowClass::WAITING_GEOMETRY) {
			waited = true;
		}
		return true;
	});
	CHECK(!st.unsafe, "never enters unknown volume");
	CHECK(max_x < 160.0f - 0.5f * 10.0f, "stops at least half the margin before unknown");
	CHECK(len(fl.v) < 0.05f, "stopped");
	CHECK(st.reasons.count(AIR_REASON_UNKNOWN_AHEAD) == 1, "reason unknown_ahead");
	CHECK(waited, "classified as a geometry wait");
	CHECK(st.max_level == AirEscalation::NONE, "no stall escalation while waiting for data (30 s)");
	CHECK(st.limits.count(int(AirSpeedLimit::HORIZON)) == 1, "horizon limited the speed");
	std::printf("  stopped at x = %.2f (unknown from 160), speed %.3f, max speed %.2f\n", max_x, len(fl.v), st.max_speed);
	// Data arrives: she continues and arrives.
	open_space(s, box(160, -32, -32, 320, 64, 64));
	const Stats st2 = fly(s, f, fl, 90.0f);
	CHECK(st2.arrived_events == 1, "resumes and arrives once the data is back");
	CHECK(!st2.unsafe, "resumed flight certified");
}

void test_dash_horizon() {
	section("350 m/s capped by the known-safe horizon");
	const AirFlightProfile prof = AirFlightProfile::rainbow_dash();
	for (int limited = 0; limited <= 1; ++limited) {
		TestAirSpace s;
		open_space(s, box(-32, -32, -32, 4128, 64, 64));
		AirFollower f;
		f.set_profile(prof);
		f.begin(raw_corridor(s, {v3(0, 16, 16), v3(4000, 16, 16)}, prof), 1);
		if (limited) {
			for (int tx = 19; tx < 130; ++tx) {
				for (int ty = -1; ty <= 1; ++ty) {
					for (int tz = -1; tz <= 1; ++tz) {
						s.remove_tile(tx, ty, tz);
					}
				}
			}
		}
		Flight fl;
		fl.p = v3(0, 16, 16);
		bool over_limit = false;
		float capability = 0.0f;
		float max_x = 0.0f;
		const Stats st = fly(s, f, fl, 60.0f, 0.5f, [&](const AirFollowCommand &cmd) {
			capability = std::max(capability, cmd.horizon.capability);
			// The executed speed never exceeds what the horizon allowed by more than one tick of accel.
			if (len(cmd.velocity) > cmd.horizon.speed_limit + prof.accel * DT + 1.0e-2f) {
				over_limit = true;
			}
			max_x = std::max(max_x, fl.p.x);
			return true;
		});
		CHECK(!st.unsafe, "dash: every tick certified");
		CHECK(!over_limit, "dash: never faster than the horizon allows");
		CHECK(std::fabs(capability - 350.0f) < 1.0e-3f, "dash: authored 350 m/s capability kept");
		if (!limited) {
			CHECK(st.max_speed > 345.0f && st.max_speed <= 350.0f + 1.0e-2f, "dash: reaches 350 m/s where 4 km are known");
			CHECK(st.arrived_events == 1, "dash: arrives 4 km away");
		} else {
			const float bound = air_max_safe_speed(608.0f, 0.5f, prof.brake, 10.0f, 350.0f);
			CHECK(st.max_speed < bound, "dash: peak below the safe speed for 608 m of known air");
			CHECK(max_x < 608.0f - 5.0f, "dash: stops before the unknown");
			CHECK(st.reasons.count(AIR_REASON_UNKNOWN_AHEAD) == 1, "dash: reason unknown_ahead");
			std::printf("  safe-speed bound for the whole 608 m: %.1f m/s\n", bound);
		}
		std::printf("  %s: max speed %.1f m/s, furthest x %.1f, arrived %.2f s, step p50 %.1f us p95 %.1f us max %.1f us\n",
				limited ? "608 m known" : "4 km known", st.max_speed, max_x, st.arrive_time, percentile(st.step_us, 0.5),
				percentile(st.step_us, 0.95), percentile(st.step_us, 1.0));
	}
}

void test_hover_same_xz() {
	section("hover arrival: same X/Z, different Y");
	TestAirSpace s;
	open_space(s, box(-64, 0, -64, 64, 64, 64));
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	// Up: a vertical climb straight to the point.
	{
		AirFollower f;
		f.set_profile(prof);
		f.begin(raw_corridor(s, {v3(5, 10, 5), v3(5, 40, 5)}, prof), 1);
		Flight fl;
		fl.p = v3(5, 10, 5);
		const Stats st = fly(s, f, fl, 30.0f, 2.0f);
		CHECK(st.arrived_events == 1, "up: arrives once");
		CHECK(std::fabs(fl.p.x - 5) <= 0.25f && std::fabs(fl.p.z - 5) <= 0.25f && std::fabs(fl.p.y - 40) <= 0.25f,
				"up: hovering at the XYZ point (not ground-projected)");
		CHECK(len(fl.v) <= prof.arrival_speed, "up: ~zero velocity");
		CHECK(st.max_speed <= prof.climb_rate + 1.0e-3f, "up: climb rate respected");
		std::printf("  up: arrived %.2f s, held at (%.3f, %.3f, %.3f) speed %.3f\n", st.arrive_time, fl.p.x, fl.p.y, fl.p.z,
				len(fl.v));
	}
	// Down: prepared glide helix (checked in detail above); here only arrival and the hold.
	{
		AirFollowCorridor c;
		air_prepare_corridor(s, {v3(5, 40, 5), v3(5, 12, 5)}, prof, AirTerminal::HOVER, 0.0f, AirPrepareOptions(), c);
		AirFollower f;
		f.set_profile(prof);
		f.begin(c, 1);
		Flight fl;
		fl.p = v3(5, 40, 5);
		const Stats st = fly(s, f, fl, 120.0f, 2.0f);
		CHECK(st.arrived_events == 1, "down: arrives once");
		CHECK(std::fabs(fl.p.x - 5) <= 0.25f && std::fabs(fl.p.z - 5) <= 0.25f && std::fabs(fl.p.y - 12) <= 0.25f,
				"down: hovering at the XYZ point");
		CHECK(!st.descent_violation, "down: glide only");
		std::printf("  down: arrived %.2f s, held at (%.3f, %.3f, %.3f)\n", st.arrive_time, fl.p.x, fl.p.y, fl.p.z);
	}
}

void test_replacement() {
	section("route replacement mid-flight");
	TestAirSpace s;
	open_space(s, box(-32, 0, -64, 256, 64, 160));
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	AirFollower f;
	f.set_profile(prof);
	f.begin(raw_corridor(s, {v3(0, 20, 0), v3(200, 20, 0)}, prof), 1);
	Flight fl;
	fl.p = v3(0, 20, 0);
	fly(s, f, fl, 4.0f);
	const float speed_before = len(fl.v);
	const double clock_before = f.monitor().clock();
	const int repairs_before = f.monitor().repairs();
	// Replan answer computed from an older position (starts behind her).
	AirFollowCorridor b;
	AirPrepareOptions keep_corner;
	keep_corner.shorten = false; // the planner's own corner (open air would let shortening cut it)
	const AirPrepareStatus ps = air_prepare_corridor(s, {v3(30, 20, 0), v3(100, 20, 0), v3(100, 20, 100)}, prof,
			AirTerminal::HOVER, 0.0f, keep_corner, b);
	CHECK(ps == AirPrepareStatus::OK, "replacement prepared");
	// A route entirely behind her and pointing back is refused; the old one is kept.
	AirFollowCorridor back = raw_corridor(s, {v3(fl.p.x - 5, 20, 0), v3(-20, 20, 0)}, prof);
	CHECK(f.replace(s, back, 7, fl.p, fl.v) == AirJoinStatus::NO_COMPATIBLE_PART, "backward route refused");
	CHECK(f.route() == 1, "old corridor kept after a refused join");
	const AirJoinStatus js = f.replace(s, b, 2, fl.p, fl.v);
	CHECK(js == AirJoinStatus::JOINED, "joined");
	CHECK(std::fabs(f.progress() - (fl.p.x - 30.0f)) < 0.5f, "progress joins at her projection, not the route start");
	CHECK(f.monitor().clock() == clock_before && f.monitor().repairs() == repairs_before, "stall history kept");
	float first_speed = -1.0f;
	float min_progress_jump = 0.0f;
	float last_progress = f.progress();
	const Stats st = fly(s, f, fl, 60.0f, 1.0f, [&](const AirFollowCommand &cmd) {
		if (first_speed < 0.0f) {
			first_speed = len(cmd.velocity);
		}
		min_progress_jump = std::min(min_progress_jump, cmd.progress - last_progress);
		last_progress = cmd.progress;
		return true;
	});
	CHECK(first_speed >= speed_before - prof.brake * DT - 1.0e-3f, "keeps her velocity across the swap");
	CHECK(min_progress_jump >= 0.0f, "no backward corridor jump");
	CHECK(st.arrived_events == 1, "arrives at the new goal");
	CHECK(dist(fl.p, v3(100, 20, 100)) <= prof.arrival_radius, "at the new goal");
	std::printf("  speed before %.2f, first after %.2f, joined at s = %.2f, arrived %.2f s later\n", speed_before, first_speed,
			f.corridor().length() > 0 ? 0.0f : 0.0f, st.arrive_time - 4.0f);
}

void test_neighbour() {
	section("candidate avoidance with a moving neighbour sphere");
	TestAirSpace s;
	open_space(s, box(-32, 0, -64, 192, 64, 64));
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	AirFollower f;
	f.set_profile(prof);
	f.begin(raw_corridor(s, {v3(0, 20, 0), v3(150, 20, 0)}, prof), 1);
	Flight fl;
	fl.p = v3(0, 20, 0);
	AirNeighbour n;
	n.position = v3(150, 20, 0);
	n.velocity = v3(-8, 0, 0);
	n.radius = 1.0f;
	n.id = 42;
	fl.neighbours.push_back(n);
	const float required = prof.envelope_radius + n.radius + f.tuning().neighbour_margin;
	float closest = 1.0e9f;
	int side_switches = 0;
	int side = 0;
	Vec3 first_side{0, 0, 0};
	const Stats st = fly(s, f, fl, 40.0f, 1.0f, [&](const AirFollowCommand &cmd) {
		const AirNeighbour &m = fl.neighbours[0];
		const Vec3 prev_m{m.position.x - m.velocity.x * DT, m.position.y - m.velocity.y * DT, m.position.z - m.velocity.z * DT};
		const Vec3 prev_p{fl.p.x - cmd.velocity.x * DT, fl.p.y - cmd.velocity.y * DT, fl.p.z - cmd.velocity.z * DT};
		closest = std::min(closest, min_separation(prev_p, cmd.velocity, prev_m, m.velocity, DT));
		// Side = her offset from the neighbour perpendicular to the corridor (Y/Z plane).
		const Vec3 off{0.0f, fl.p.y - m.position.y, fl.p.z - m.position.z};
		if (std::fabs(fl.p.x - m.position.x) < 12.0f && len(off) > 0.3f) {
			if (side == 0) {
				first_side = off;
				side = 1;
			} else if (off.y * first_side.y + off.z * first_side.z < 0.0f) {
				++side_switches;
				first_side = off;
			}
		}
		return true;
	});
	CHECK(closest >= required - 1.0e-3f, "separation from the neighbour sphere kept");
	CHECK(!st.unsafe, "every tick certified");
	CHECK(st.arrived_events == 1, "arrives after the pass");
	CHECK(st.reasons.count(AIR_REASON_NEIGHBOUR) == 1, "reason neighbour reported");
	CHECK(side_switches == 0, "keeps one side while passing");
	std::printf("  closest %.3f m (required %.2f), side switches %d, arrived %.2f s\n", closest, required, side_switches,
			st.arrive_time);

	section("preferred (avoidance) velocity is validated, never trusted");
	{
		TestAirSpace w;
		open_space(w, box(-32, 0, -64, 192, 64, 64));
		w.fill_box(box(-32, 0, 3, 192, 64, 4), Cell::SOLID); // wall beside the corridor
		AirFollower g;
		g.set_profile(prof);
		g.begin(raw_corridor(w, {v3(0, 20, 0), v3(150, 20, 0)}, prof), 1);
		Flight a;
		a.p = v3(0, 20, 0);
		a.v = v3(10, 0, 0);
		a.has_preferred = true;
		a.preferred = v3(6, 0, 8); // into the wall
		AirFollowInput in;
		in.position = a.p;
		in.velocity = a.v;
		in.has_preferred = true;
		in.preferred_velocity = a.preferred;
		const AirFollowCommand bad = g.step(w, in);
		CHECK(bad.candidate != AirCandidateKind::PREFERRED, "preferred velocity into a wall rejected");
		const Stats sb = fly(w, g, a, 3.0f, 0.0f);
		CHECK(!sb.unsafe, "never follows it into the wall");
		AirFollower h;
		h.set_profile(prof);
		h.begin(raw_corridor(w, {v3(0, 20, 0), v3(150, 20, 0)}, prof), 1);
		in.preferred_velocity = v3(10, 0, -2); // safe sidestep
		const AirFollowCommand good = h.step(w, in);
		CHECK(good.candidate == AirCandidateKind::PREFERRED && good.reason == AIR_REASON_PREFERRED,
				"safe preferred velocity executed");
		std::printf("  into wall -> %s; safe sidestep -> %s\n", air_candidate_name(bad.candidate),
				air_candidate_name(good.candidate));
	}
}

void test_escalation() {
	section("blocked corridor: replan request, bounded waits, one terminal failure");
	TestAirSpace s;
	open_space(s, box(-32, 0, -32, 160, 64, 32));
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	AirFollower f;
	f.set_profile(prof);
	f.begin(raw_corridor(s, {v3(0, 20, 0), v3(120, 20, 0)}, prof), 1);
	Flight fl;
	fl.p = v3(0, 20, 0);
	fly(s, f, fl, 1.0f);
	// A durable obstruction appears across the whole corridor ahead (a sealed wall: no detour).
	s.fill_box(box(60, 0, -32, 62, 64, 32), Cell::SOLID);
	float replan_at = -1.0f, alternate_at = -1.0f, failed_at = -1.0f;
	const Stats st = fly(s, f, fl, 60.0f, 0.0f, [&](const AirFollowCommand &cmd) {
		if (cmd.entered == AirEscalation::REPLAN && replan_at < 0.0f) {
			replan_at = fl.t;
		}
		if (cmd.entered == AirEscalation::ALTERNATE && alternate_at < 0.0f) {
			alternate_at = fl.t;
		}
		if (cmd.failed_event) {
			failed_at = fl.t;
		}
		return true;
	});
	CHECK(!st.unsafe, "never enters the new obstruction");
	CHECK(fl.p.x < 60.0f, "stopped before it");
	CHECK(replan_at > 0.0f && replan_at < 1.1f, "replan requested at once");
	CHECK(st.reasons.count(AIR_REASON_CORRIDOR_BLOCKED) == 1, "reason corridor_blocked");
	CHECK(alternate_at > replan_at, "unanswered replan escalates to an alternate");
	CHECK(failed_at > alternate_at, "then fails");
	CHECK(st.failed_events == 1, "terminal failure reported exactly once");
	CHECK(st.arrived_events == 0, "no false arrival");
	std::printf("  replan %.2f s, alternate %.2f s, failed %.2f s, stopped at x = %.2f\n", replan_at, alternate_at, failed_at,
			fl.p.x);

	section("stall monitor: no progress while following escalates, resumes on progress");
	{
		AirStallMonitor m;
		AirStallSample sm;
		sm.permitted = 10.0;
		AirEscalation first = AirEscalation::NONE;
		double t_repair = -1, t_replan = -1;
		for (int i = 0; i < 60 * 12; ++i) {
			sm.gained = 0.0;
			const AirEscalation e = m.update(DT, AirFollowClass::FOLLOWING, sm);
			if (e == AirEscalation::LOCAL_REPAIR && t_repair < 0) {
				t_repair = m.clock();
				first = e;
			}
			if (e == AirEscalation::REPLAN && t_replan < 0) {
				t_replan = m.clock();
			}
		}
		// Judged once 90 % of the 3 s window is following: about 2.7 s.
		CHECK(first == AirEscalation::LOCAL_REPAIR && t_repair > 2.6 && t_repair < 3.5, "stall -> local repair after ~3 s");
		std::printf("  local repair at %.2f s, replan at %.2f s\n", t_repair, t_replan);
		CHECK(t_replan > t_repair + 2.9 && t_replan < t_repair + 3.6, "repair deadline -> replan");
		CHECK(m.awaiting_route(), "awaiting the route");
		m.route_replaced(9);
		CHECK(!m.awaiting_route() && m.level() == AirEscalation::REPLAN, "new route keeps the level and history");
		for (int i = 0; i < 60 * 4; ++i) {
			sm.gained = 10.0 * DT;
			m.update(DT, AirFollowClass::FOLLOWING, sm);
		}
		CHECK(m.level() == AirEscalation::NONE, "progress clears the escalation");
		CHECK(m.replans() == 1 && m.repairs() == 1, "counters kept");
		// Geometry waits are bounded too.
		AirStallMonitor g;
		AirEscalation got = AirEscalation::NONE;
		for (int i = 0; i < 60 * 25 && got == AirEscalation::NONE; ++i) {
			got = g.update(DT, AirFollowClass::WAITING_GEOMETRY, AirStallSample());
		}
		CHECK(got == AirEscalation::REPLAN && g.clock() > 20.0, "geometry wait beyond its limit asks for a replan");
	}
}

void test_determinism() {
	section("determinism");
	TestAirSpace s;
	open_space(s, box(-32, 0, -32, 160, 64, 32));
	s.fill_box(box(-32, 0, -32, 160, 2, 32), Cell::SOLID);
	s.fill_box(box(60, 0, -32, 61, 20, 32), Cell::SOLID);
	const AirFlightProfile prof = AirFlightProfile::pegasus();
	std::vector<Vec3> route;
	search(s, v3(10, 5, 0), v3(120, 5, 0), route);
	uint64_t hashes[2] = {0, 0};
	for (int run = 0; run < 2; ++run) {
		AirFollowCorridor c;
		air_prepare_corridor(s, route, prof, AirTerminal::HOVER, 0.0f, AirPrepareOptions(), c);
		AirFollower f;
		f.set_profile(prof);
		f.begin(c, 1);
		Flight fl;
		fl.p = v3(10, 5, 0);
		fl.neighbours.push_back(AirNeighbour{v3(110, 8, 0), v3(-6, 0, 0), 1.0f, 3});
		hashes[run] = fly(s, f, fl, 40.0f).hash;
	}
	CHECK(hashes[0] == hashes[1], "identical command streams on identical input");
}

} // namespace

int main() {
	test_motor_model();
	test_straight();
	test_corner();
	test_stop_corners();
	test_climb_over();
	test_descent_needs_speed();
	test_thin_wall();
	test_unknown_ahead();
	test_dash_horizon();
	test_hover_same_xz();
	test_replacement();
	test_neighbour();
	test_escalation();
	test_determinism();
	std::printf("AIR_FOLLOW_TESTS %s (%d checks, %d failures)\n", failures == 0 ? "PASS" : "FAIL", checks, failures);
	return failures == 0 ? 0 : 1;
}
