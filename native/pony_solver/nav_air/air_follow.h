// Air corridor follower (navigation overhaul phase 5, AIR_FOLLOW slice;
// docs/NAVIGATION_AIR_FOLLOW_2026_10_02.md). Plain C++17, no Godot types, no threads, deterministic.
//
// Pipeline: AirSearch route -> air_prepare_corridor (shorten, glide-shape steep descents, smooth,
// certify, per-point speed limits) -> AirFollower::begin -> AirFollower::step every physics tick.
//
// Frame: Godot metres, Y up, positions are the BODY CENTRE (the flight envelope's reference),
// not the pony root; the binding adds the profile's centre offset. Occupancy in AirSpace is
// already inflated by the envelope, so a centre path whose every touched fine voxel is FREE is
// clear; nothing here inflates it again. Godot yaw: forward is -Z, yaw 0 faces -Z, positive yaw
// turns toward -X (left); a direction (dx, dz) has yaw atan2(-dx, -dz).
//
// Motor model (air_step_velocity, used identically for prediction and for the command): above
// hover_speed the velocity direction turns toward the target at most min(turn_rate,
// lateral_accel / speed) rad/s (3D, so pitch changes are turn-limited too) while the speed
// changes by at most accel (up) or brake (down) per second; at or below hover_speed the velocity
// vector changes by at most max(accel, brake) per second in any direction (hovering). Then the
// vertical rules: climb <= climb_rate; descent only with horizontal speed >= min_descent_speed and
// then at most min(descent_rate, horizontal / glide_ratio), i.e. a forward glide, never a routine
// vertical descent while flapping. The one exception is a small settle_rate correction inside
// settle_radius of a hover goal.
//
// Step: project the actor onto the corridor (XYZ, current segment plus a bounded forward window;
// progress advances only while within corridor_tolerance), roll the lookahead
// clamp(speed * lookahead_time, lookahead_min, lookahead_max) (never past a corner whose certified
// slack cannot absorb the cut), and plan the speed: min(requested, capability, curvature preview
// (brake into every per-point limit ahead along the 3D arc), arrival braking on the remaining 3D
// arc, the known-safe horizon (air_governor.h), climb/descent caps). A bounded candidate set
// around that reference (and an optional preferred avoidance velocity, the previous plan and two
// brakes) is predicted with the motor model: hold the candidate for control_horizon, then brake to
// rest while still steering. Candidates are ranked on progress, corridor error, deviation from
// the preferred velocity and control change; they are then certified lazily in rank order
// (collision constraints first: the whole predicted path, chords merged only while their
// deviation bound stays under chord_tolerance and swept with that bound, must touch FREE voxels
// only; UNKNOWN fails; separation from predicted neighbour spheres must hold). The first
// certified candidate wins; ties keep the stable candidate order. If none certifies she brakes and
// says why. Because each chosen command carries a certified stop, she can always stop inside
// certified volume as long as the world does not change under her.
#pragma once

#include "air_governor.h"
#include "air_shorten.h"

#include <cstdint>
#include <vector>

namespace nav_air {

// ---------------------------------------------------------------- profile and motor model

struct AirFlightProfile {
	float max_speed = 20.0f; // authored top speed: capability (pony_flight.gd CRUISE; Rainbow Dash 350)
	float accel = 7.0f; // pony_flight.gd ACCEL
	float brake = 6.0f; // pony_flight.gd BRAKE
	float lateral_accel = 10.0f; // initial value (AirFlightLimits default), not measured on a pony
	float turn_rate = 2.5f; // rad/s, initial value (AirFlightLimits default)
	float climb_rate = 6.0f; // m/s up
	float descent_rate = 8.0f; // m/s down at most, while gliding
	float min_descent_speed = 3.0f; // horizontal m/s needed before any routine descent
	float glide_ratio = 3.0f; // steepest glide: metres forward per metre down (pony_flight.gd _glide_in)
	float hover_speed = 1.5f; // below this the velocity changes as a free vector (pony_flight.gd hover clip)
	float settle_rate = 0.25f; // downward correction allowed only near a hover goal
	float settle_radius = 0.6f;
	float envelope_radius = 1.0f; // sphere around the body centre: neighbour separation
	float lookahead_time = 0.8f;
	float lookahead_min = 2.0f;
	float lookahead_max = 120.0f;
	float arrival_radius = 0.25f; // 3D
	float arrival_speed = 0.15f; // hover counts as stopped below this
	float corridor_tolerance = 3.0f; // progress advances only within this distance of the corridor
	float tracking_tolerance = 0.0f; // certified slack corners may use beyond segment clearance

	// Speeds and accelerations scale with the body like pony_flight.gd; turn and glide limits do not.
	static AirFlightProfile pegasus(float body_scale = 1.0f);
	static AirFlightProfile rainbow_dash(float body_scale = 1.0f); // DASH_CRUISE 350, DASH_ACCEL 45, DASH_BRAKE 40
	AirFlightLimits limits() const; // the air_shorten view of these limits
};

// Highest downward speed allowed at this horizontal speed.
float air_allowed_descent(float horizontal_speed, const AirFlightProfile &profile, bool settle);
// One motor tick (see the header comment). target_direction need not be unit; zero means "stop".
Vec3 air_step_velocity(const Vec3 &velocity, const Vec3 &target_direction, float target_speed,
		const AirFlightProfile &profile, float dt, bool settle);

// ---------------------------------------------------------------- corridor

enum class AirTerminal : uint8_t {
	HOVER = 0, // stop with ~zero velocity at the corridor's XYZ end (never ground-projected)
	PASS = 1, // reach the end at end_speed and report arrival (hand-off, e.g. to an approach)
	PARTIAL = 2, // the corridor is a certified prefix: stop inside it and wait for the rest
};

struct AirProjection {
	bool found = false;
	float s = 0.0f; // arc length of the projected point
	float distance = 0.0f; // actor to projected point (3D)
	int32_t segment = 0;
	Vec3 point{0, 0, 0};
};

class AirFollowCorridor {
public:
	// Certifies points/clearance through `space` (air_make_corridor stamps), then derives arc
	// lengths and per-point limits (air_validate_trajectory's corner/climb/descent model with this
	// profile). Points closer than 1 mm are merged. False if fewer than two points remain, the
	// polyline does not certify or the limits are invalid.
	bool build(const AirSpace &space, const std::vector<Vec3> &points, const std::vector<float> &clearance,
			const AirFlightProfile &profile, AirTerminal terminal, float end_speed = 0.0f);
	void clear();
	bool empty() const { return points_.size() < 2; }
	size_t size() const { return points_.size(); }
	float length() const { return cumulative_.empty() ? 0.0f : cumulative_.back(); }
	AirTerminal terminal() const { return terminal_; }
	float end_speed() const { return end_speed_; }
	const Vec3 &end() const { return points_.back(); }
	const std::vector<Vec3> &points() const { return points_; }
	const std::vector<float> &clearance() const { return clearance_; }
	const std::vector<float> &cumulative() const { return cumulative_; }
	const std::vector<float> &limits() const { return limit_; } // per point (m/s)
	const std::vector<uint8_t> &steep() const { return steep_; } // per segment: steeper than the glide slope
	const AirTrajectoryReport &report() const { return report_; }
	AirCorridor &stamped() { return certified_; } // tile stamps for air_check_corridor
	const AirCorridor &stamped() const { return certified_; }

	Vec3 point_at(float s) const;
	int32_t segment_at(float s) const;
	Vec3 direction_at(float s) const; // unit tangent of the segment containing s
	// Nearest point on the segments overlapping [from_s - back, from_s + ahead], s clamped to that
	// window (ties: smaller s). project_all: every segment (joins and explicit recovery only).
	AirProjection project_window(const Vec3 &p, float from_s, float back, float ahead) const;
	AirProjection project_all(const Vec3 &p) const;
	// Lookahead end <= to_s that does not pass the first corner in (from_s, to_s] by more than its
	// certified slack can absorb (corner-to-chord distance <= slack).
	float clamp_lookahead(float from_s, float to_s) const;
	// Highest speed at s that can still brake into every per-point limit in (s, s + preview] and
	// into the end speed, along the 3D arc. `limiting` gets the point index (-1: none, size(): end).
	float preview_speed(float s, float preview, float braking, int32_t *limiting = nullptr) const;

private:
	std::vector<Vec3> points_;
	std::vector<float> clearance_;
	std::vector<float> cumulative_;
	std::vector<float> limit_;
	std::vector<float> slack_; // per point: certified slack at that corner
	std::vector<float> turn_; // per point: deviation angle (0 at both ends)
	std::vector<uint8_t> steep_;
	AirTerminal terminal_ = AirTerminal::HOVER;
	float end_speed_ = 0.0f;
	AirCorridor certified_;
	AirTrajectoryReport report_;
};

// Replaces every descending segment steeper than the glide slope (and, for a hover end, a final
// descent without a level run-out long enough to brake from min_descent_speed) with a certified
// glide: a descending helix of whole turns above the segment's start (so it returns to the same
// X/Z) followed by a straight glide and the level run-out. Chords certify with their
// curve-to-chord bound. `shaped` counts replaced segments, `failed` those with no certifiable
// glide volume (kept unchanged; the follower then cannot descend there and reports it).
// Returns false only for invalid input.
bool air_shape_descents(const AirSpace &space, const std::vector<Vec3> &in, const AirFlightProfile &profile,
		bool hover_end, std::vector<Vec3> &out, uint32_t *shaped = nullptr, uint32_t *failed = nullptr);

struct AirPrepareOptions {
	bool shorten = true;
	bool shape_descents = true;
	bool smooth = true;
	float cruise_speed = 0.0f; // 0: the profile's max speed
	float max_turn_radius = 40.0f; // fillet radius = min(cruise^2 / lateral_accel, this)
	AirSmoothOptions smooth_options; // turn_radius is overwritten from the two values above
};

enum class AirPrepareStatus : uint8_t {
	OK = 0,
	NOT_CERTIFIED = 1, // the route does not certify (stale or wrong space)
	NO_GLIDE_VOLUME = 2, // built, but a steep descent could not be shaped (follower will refuse to dive)
	INVALID = 3,
};

const char *air_prepare_status_name(AirPrepareStatus status);

AirPrepareStatus air_prepare_corridor(const AirSpace &space, const std::vector<Vec3> &route,
		const AirFlightProfile &profile, AirTerminal terminal, float end_speed, const AirPrepareOptions &options,
		AirFollowCorridor &out);

// ---------------------------------------------------------------- follower

struct AirNeighbour {
	Vec3 position{0, 0, 0}; // centre of its sphere
	Vec3 velocity{0, 0, 0}; // predicted constant over the neighbour horizon
	float radius = 1.0f;
	uint64_t id = 0;
};

struct AirFollowInput {
	Vec3 position{0, 0, 0}; // body centre
	Vec3 velocity{0, 0, 0}; // actual velocity
	float yaw = 0.0f; // current body yaw (pose hint while hovering)
	float dt = 1.0f / 60.0f;
	float requested_speed = -1.0f; // < 0: the profile's max speed
	bool has_preferred = false; // avoidance suggestion (e.g. Godot 3D avoidance)
	Vec3 preferred_velocity{0, 0, 0};
	const AirNeighbour *neighbours = nullptr;
	size_t neighbour_count = 0;
};

enum class AirCommandMode : uint8_t {
	TRAVEL = 0, // follow with `velocity`
	BRAKE = 1, // braking (a brake candidate or the emergency brake)
	HOLD = 2, // hovering in place (goal reached, waiting for route/geometry, failed)
	ARRIVED = 3, // the one tick the terminal condition is met
	FAILED = 4, // the one tick the terminal failure is reported (then HOLD)
};

const char *air_command_mode_name(AirCommandMode mode);

// What set the permitted speed (before collision constraints).
enum class AirSpeedLimit : uint8_t {
	REQUESTED = 0,
	CAPABILITY = 1,
	CURVE = 2, // curvature preview / pursuit curvature
	ARRIVAL = 3, // braking for the remaining 3D arc
	HORIZON = 4, // known-safe streaming horizon
	VERTICAL = 5, // climb / descent rate on the current segment
	ESCAPE = 6, // leaving non-FREE volume slowly
};

const char *air_speed_limit_name(AirSpeedLimit limit);

enum AirFollowReason : int32_t {
	AIR_REASON_NONE = 0,
	AIR_REASON_ARRIVED = 1,
	AIR_REASON_HOVER_HOLD = 2,
	AIR_REASON_HORIZON_LIMITED = 3, // informational: the horizon governs speed
	AIR_REASON_UNKNOWN_AHEAD = 4, // stopping / stopped before unknown volume
	AIR_REASON_SOLID_AHEAD = 5, // new obstruction on the corridor ahead
	AIR_REASON_NO_SAFE_TRAJECTORY = 6, // no candidate certified: emergency brake
	AIR_REASON_NEIGHBOUR = 7, // a neighbour sphere constrained the choice
	AIR_REASON_DESCENT_TOO_STEEP = 8, // corridor descends steeper than the glide slope here
	AIR_REASON_DESCENT_NEEDS_SPEED = 9, // too slow to descend: holding height
	AIR_REASON_CORRIDOR_LOST = 10,
	AIR_REASON_WAITING_ROUTE = 11, // end of a partial corridor, or a replan is outstanding
	AIR_REASON_REPAIR = 12, // local repair candidates active
	AIR_REASON_FAILED = 13,
	AIR_REASON_INVALID_INPUT = 14,
	AIR_REASON_ESCAPING = 15, // start not FREE: bounded escape prefix allowed
	AIR_REASON_UNKNOWN_HERE = 16, // actor is in UNKNOWN volume: hold, never move blind
	AIR_REASON_CORRIDOR_BLOCKED = 17, // durable change blocked the corridor ahead: replan
	AIR_REASON_PREFERRED = 18, // informational: the preferred (avoidance) velocity was executed
};

const char *air_reason_name(int32_t reason);

enum class AirCandidateKind : uint8_t {
	REFERENCE = 0,
	CONTINUE = 1, // remaining previous plan
	TRACK = 2, // short lookahead
	YAW_LEFT_SMALL = 3,
	YAW_RIGHT_SMALL = 4,
	PITCH_UP_SMALL = 5,
	PITCH_DOWN_SMALL = 6,
	YAW_LEFT_WIDE = 7,
	YAW_RIGHT_WIDE = 8,
	YAW_LEFT_REPAIR = 9,
	YAW_RIGHT_REPAIR = 10,
	PITCH_UP_REPAIR = 11,
	PITCH_DOWN_REPAIR = 12,
	PREFERRED = 13,
	BRAKE_STEER = 14,
	BRAKE = 15,
	EMERGENCY = 16, // nothing certified
	HOVER_HOLD = 17,
};

const char *air_candidate_name(AirCandidateKind kind);

struct AirFollowTuning {
	float control_horizon = 0.5f; // s a candidate is held before its braking tail
	float neighbour_horizon = 2.0f; // s neighbours are predicted (constant velocity)
	float neighbour_margin = 0.25f; // m beyond the two radii
	float chord_tolerance = 0.1f; // m: merged chords' deviation bound
	float max_chord = 32.0f; // m
	float escape_distance = 1.0f; // m of non-FREE start allowed while leaving it
	float window_back = 2.0f; // projection window behind progress (m)
	float window_ahead_min = 8.0f; // and ahead: max(this, speed * window_time)
	float window_time = 1.0f;
	float lost_factor = 2.0f; // corridor lost beyond corridor_tolerance * this
	float lost_seconds = 0.5f; // lost this long: local repair
	float no_safe_seconds = 1.0f; // no certified candidate this long: local repair
	float small_angle = 0.2618f; // 15 degrees
	float wide_angle = 0.6109f; // 35 degrees
	float repair_angle = 1.0472f; // 60 degrees
	float slow_share = 0.5f; // second speed of every direction
	float hover_gain = 2.0f; // 1/s: final approach speed <= gain * distance
	float weight_progress = 1.0f;
	float weight_error = 0.5f;
	float weight_preferred = 1.5f;
	float weight_change = 0.15f;
	uint32_t max_tail_steps = 4096; // braking tail cap (steps of dt)
	float brake_share = 0.9f; // share of the motor's braking that speed plans and the horizon assume
};

struct AirFollowCommand {
	AirCommandMode mode = AirCommandMode::HOLD;
	Vec3 velocity{0, 0, 0}; // apply for the next dt: already within every motor limit
	Vec3 desired{0, 0, 0}; // chosen candidate's target velocity (before the limited step)
	float yaw = 0.0f; // pose hints only: they never move the root
	float pitch = 0.0f; // + nose up
	float bank = 0.0f; // + left wing down (into a left turn)
	float speed_limit = 0.0f; // permitted speed before collision constraints
	AirSpeedLimit limit = AirSpeedLimit::REQUESTED;
	int32_t reason = AIR_REASON_NONE;
	AirCandidateKind candidate = AirCandidateKind::HOVER_HOLD;
	AirHorizon horizon;
	float progress = 0.0f;
	float raw_progress = 0.0f;
	float remaining = 0.0f; // 3D arc left (straight distance in the final lookahead)
	float corridor_error = 0.0f;
	Vec3 lookahead{0, 0, 0};
	uint32_t candidates = 0; // generated
	uint32_t certified_tries = 0; // certification attempts this tick
	uint32_t voxels = 0; // fine voxels touched (horizon + certification)
	AirFollowClass klass = AirFollowClass::FOLLOWING;
	AirEscalation escalation = AirEscalation::NONE; // current level
	AirEscalation entered = AirEscalation::NONE; // level entered on this tick
	bool arrived_event = false; // true on exactly one tick per corridor
	bool failed_event = false; // true on exactly one tick per intent
	AirCorridorState corridor_state = AirCorridorState::VALID;
};

enum class AirJoinStatus : uint8_t {
	JOINED = 0,
	NO_COMPATIBLE_PART = 1, // nothing on the new route lies ahead of her motion within reach
	JOIN_NOT_CERTIFIED = 2, // every compatible join crosses non-FREE volume
	INVALID = 3,
};

const char *air_join_status_name(AirJoinStatus status);

class AirFollower {
public:
	void set_profile(const AirFlightProfile &profile) { profile_ = profile; }
	const AirFlightProfile &profile() const { return profile_; }
	void set_tuning(const AirFollowTuning &tuning) { tuning_ = tuning; }
	const AirFollowTuning &tuning() const { return tuning_; }
	void set_horizon(float latency, float margin) {
		latency_ = latency;
		margin_ = margin;
	}
	AirStallMonitor &monitor() { return monitor_; }
	const AirStallMonitor &monitor() const { return monitor_; }

	// New intent: forgets history. The corridor is copied.
	bool begin(const AirFollowCorridor &corridor, uint64_t route_id);
	// Same intent, new route (replan answer): joins the nearest forward-compatible part whose join
	// certifies, keeps her velocity, previous plan and stall history. On failure the current
	// corridor is kept.
	AirJoinStatus replace(const AirSpace &space, const AirFollowCorridor &corridor, uint64_t route_id,
			const Vec3 &position, const Vec3 &velocity);
	void clear();
	bool active() const { return !corridor_.empty(); }
	const AirFollowCorridor &corridor() const { return corridor_; }
	uint64_t route() const { return route_; }
	float progress() const { return progress_; }

	AirFollowCommand step(const AirSpace &space, const AirFollowInput &input);

private:
	struct Candidate {
		AirCandidateKind kind = AirCandidateKind::REFERENCE;
		Vec3 direction{0, 0, 0};
		float speed = 0.0f;
		float hold = 0.0f;
		bool pursuit = false; // re-aims along the corridor every predicted tick
		float look_scale = 1.0f; // share of the rolling lookahead (pursuit only)
		float score = 0.0f;
		float gain = 0.0f; // corridor progress at the end of the hold
		float cost = 0.0f; // corridor error, preferred deviation and control change
		Vec3 first{0, 0, 0}; // velocity after the first tick
		uint32_t order = 0;
	};
	struct Context;
	void predict(const Context &c, const Candidate &k, std::vector<Vec3> &points, std::vector<Vec3> &velocities,
			bool with_tail) const;
	bool certify(const AirSpace &space, const Context &c, const std::vector<Vec3> &points,
			const std::vector<Vec3> &velocities, uint32_t &voxels, bool &neighbour_failed) const;
	void score(const Context &c, Candidate &k) const;

	AirFlightProfile profile_;
	AirFollowTuning tuning_;
	AirStallMonitor monitor_;
	AirFollowCorridor corridor_;
	uint64_t route_ = 0;
	float latency_ = 0.5f;
	float margin_ = 10.0f;
	float progress_ = 0.0f;
	float raw_progress_ = 0.0f;
	double intent_progress_ = 0.0;
	bool arrived_ = false;
	bool failed_reported_ = false;
	float lost_time_ = 0.0f;
	float no_safe_time_ = 0.0f;
	bool recover_projection_ = false;
	// Previous plan (continuation candidate).
	bool has_plan_ = false;
	Vec3 plan_direction_{0, 0, 0};
	float plan_speed_ = 0.0f;
	float plan_hold_left_ = 0.0f;
	bool plan_pursuit_ = false;
	float plan_look_scale_ = 1.0f;
	Vec3 previous_desired_{0, 0, 0};
	// Corridor revision fingerprint after a BLOCKED / MISSING_DATA answer.
	uint64_t corridor_fingerprint_ = 0;
	AirCorridorState corridor_state_ = AirCorridorState::VALID;
	bool blocked_ahead_ = false;
	// Unobstructed speed for the stall monitor: rises at the profile's acceleration toward the
	// permitted speed regardless of what she actually does (a blocked flyer falls behind it).
	float ideal_speed_ = 0.0f;
	// Scratch.
	std::vector<Candidate> candidates_;
	std::vector<Vec3> scratch_points_;
	std::vector<Vec3> scratch_velocities_;
	mutable std::vector<Vec3> score_points_;
	mutable std::vector<Vec3> score_velocities_;
};

} // namespace nav_air
