// Known-safe streaming horizon and air stall classification for the flight follower
// (navigation overhaul phase 5, AIR_FOLLOW slice; docs/NAVIGATION_AIR_FOLLOW_2026_10_02.md).
// Plain C++17, no Godot types, no threads, deterministic. air_follow.h drives both.
//
// Horizon. Before each movement step the known-safe distance ahead must cover reaction travel
// plus braking: required = v * latency + v^2 / (2 * braking) + margin (latency = streaming +
// scheduling + reaction delay). The known-safe distance is measured from the actor along the
// join to its corridor projection and then along the corridor, through volume whose every
// touched fine voxel is FREE (supercover; UNKNOWN and SOLID both end it). The speed limit is the
// highest speed whose required distance fits. A corridor that is certified all the way to a
// terminal stop does not limit speed (arrival braking stops on that certified point); a partial
// corridor end, UNKNOWN or SOLID does. The authored top speed (capability, e.g. Rainbow Dash's
// 350 m/s) is reported unchanged: the horizon limits where it may be used, never what it is.
//
// Stalls. Same model as the ground ProgressMonitor (src/navigation_progress.h), ported for air:
// a 10 Hz ring of samples; the class is decided before any timer advances (FOLLOWING expects
// corridor progress in proportion to the permitted speed; YIELDING, WAITING_GEOMETRY and
// WAITING_ROUTE have their own bounded timers; HOLDING at a goal expects nothing). A stall is
// genuine blocked progress, circling (a full heading sweep without approaching the goal) or
// oscillation (projection reversing back and forth). Escalation is deterministic: local repair,
// replan, alternate route, then one terminal failure, with per-level deadlines, a total stalled
// budget and an optional intent deadline. A replacement route keeps the history.
#pragma once

#include "air_dynamic.h"

#include <cstdint>
#include <vector>

namespace nav_air {

// ---------------------------------------------------------------- known-safe horizon

struct AirHorizonConfig {
	float latency = 0.5f; // s: streaming + scheduling + reaction delay
	float margin = 10.0f; // m kept between the stop point and uncertified volume
	float braking = 6.0f; // m/s^2 the stop assumes (the profile's braking)
	float capability = 20.0f; // authored top speed, reported unchanged
	float scan_extra = 16.0f; // scanned beyond the distance the wanted speed requires
	float max_scan = 4096.0f; // hard cap on one scan (m)
};

enum class AirHorizonReason : uint8_t {
	CLEAR = 0, // scan covered the distance the wanted speed needs
	TERMINAL = 1, // certified to the corridor's terminal stop: no horizon limit
	PARTIAL_END = 2, // a partial corridor ends: stop inside it
	UNKNOWN_AHEAD = 3, // UNKNOWN volume ends the known-safe distance
	SOLID_AHEAD = 4, // SOLID volume (new obstruction) ends it
	NO_CORRIDOR = 5, // invalid query
};

const char *air_horizon_reason_name(AirHorizonReason reason);

struct AirHorizonQuery {
	Vec3 actor{0, 0, 0}; // body centre
	const std::vector<Vec3> *points = nullptr; // corridor polyline
	const std::vector<float> *cumulative = nullptr; // arc length at every point
	float progress = 0.0f; // actor's arc length on the corridor
	bool terminal_end = true; // the corridor end is a certified stop (hover/pass), not a partial prefix
	float speed = 0.0f; // current speed
	float wanted_speed = 0.0f; // speed the follower would like to reach
};

struct AirHorizon {
	AirHorizonReason reason = AirHorizonReason::NO_CORRIDOR;
	float known_safe = 0.0f; // metres from the actor through certified volume (scan-capped)
	float required = 0.0f; // required distance at the current speed
	float speed_limit = 0.0f; // highest speed that can still stop inside known_safe (capability if not limiting)
	float capability = 0.0f; // authored top speed
	bool limited = false; // speed_limit < wanted_speed
	Vec3 end_point{0, 0, 0}; // where the known-safe distance ends
	uint32_t voxels = 0; // fine voxels certified by this scan
};

AirHorizon air_evaluate_horizon(const AirSpace &space, const AirHorizonQuery &query, const AirHorizonConfig &config);

// ---------------------------------------------------------------- stall classification

enum class AirFollowClass : uint8_t {
	FOLLOWING = 0, // expects progress in proportion to the permitted speed
	YIELDING = 1, // neighbour avoidance holds her back (bounded)
	WAITING_GEOMETRY = 2, // unknown volume ahead: data latency, not physical stuck time (bounded)
	WAITING_ROUTE = 3, // at the end of a partial corridor while the rest is searched (bounded)
	HOLDING = 4, // hovering at the goal: no progress expected
};

enum class AirEscalation : uint8_t {
	NONE = 0,
	LOCAL_REPAIR = 1, // widen the candidate set, rejoin the corridor
	REPLAN = 2, // ask for a new route from here (keeps flying safely meanwhile)
	ALTERNATE = 3, // ask for a different route / goal region
	FAILED = 4, // terminal: reported once
};

const char *air_follow_class_name(AirFollowClass klass);
const char *air_escalation_name(AirEscalation level);

struct AirStallSample {
	double t = 0.0;
	uint64_t route = 0;
	double progress = 0.0; // monotonic corridor arc length of this route
	double raw_progress = 0.0; // unclamped projection (oscillation evidence)
	double intent_progress = 0.0; // summed over every route of this intent
	Vec3 position{0, 0, 0};
	double yaw = 0.0; // heading of the actual velocity
	double goal_distance = 0.0; // remaining corridor distance
	double command = 0.0;
	double actual = 0.0;
	double permitted = 0.0; // speed she would travel at if unobstructed
	// Accumulated since the previous sample.
	double gained = 0.0;
	double expected = 0.0;
	double following = 0.0;
	AirFollowClass klass = AirFollowClass::FOLLOWING;
	int32_t reason = 0;
};

struct AirStallTuning {
	double sample_hz = 10.0;
	double stall_window = 3.0; // s judged
	double following_share = 0.9; // share of the window that must be FOLLOWING
	double expected_floor = 1.5; // m of permitted motion before progress is judged
	double stall_fraction = 0.25; // stalled when gain < this share of permitted distance
	double resume_gain = 2.0; // m gained in the window that clears an escalation
	double yielding_limit = 3.0; // continuous YIELDING beyond this counts as FOLLOWING
	double geometry_wait_limit = 20.0; // continuous WAITING_GEOMETRY beyond this escalates
	double route_wait_limit = 10.0; // an unanswered REPLAN / ALTERNATE beyond this escalates
	double repair_seconds = 3.0;
	double replan_seconds = 6.0;
	double alternate_seconds = 8.0;
	double total_stall_limit = 30.0; // stalled seconds one intent may spend
	double intent_deadline = 0.0; // s since the intent began; 0 = none (binding derives it from length / speed)
	double circling_window = 8.0;
	double circling_progress = 1.0; // m of approach that disproves circling
	double oscillation_window = 5.0;
	double oscillation_amplitude = 0.5; // m
	int oscillation_reversals = 3;
};

class AirStallMonitor {
public:
	static constexpr int CAPACITY = 50;

	void set_tuning(const AirStallTuning &value) { tuning_ = value; }
	const AirStallTuning &tuning() const { return tuning_; }
	void reset(); // new intent: forget everything
	void route_replaced(uint64_t route); // same intent: keeps history and escalation, ends a route wait
	// Advances by dt. Returns the escalation level entered on this tick (NONE when it did not rise);
	// FAILED is returned exactly once per intent.
	AirEscalation update(double dt, AirFollowClass klass, const AirStallSample &now);
	// Physical evidence (no safe trajectory, corridor blocked ahead): jump to at least `level`.
	AirEscalation force(AirEscalation level, const char *cause);

	AirEscalation level() const { return level_; }
	bool awaiting_route() const { return awaiting_route_; }
	bool stalled() const { return stalled_; }
	const char *cause() const { return cause_; }
	double clock() const { return clock_; }
	double total_stalled() const { return total_stalled_; }
	double geometry_wait() const { return geometry_wait_; }
	double planning_wait() const { return planning_wait_; }
	double route_wait() const { return route_wait_; }
	int repairs() const { return repairs_; }
	int replans() const { return replans_; }
	int alternates() const { return alternates_; }
	AirFollowClass effective_class() const { return effective_; }
	int sample_count() const { return count_; }
	const AirStallSample &sample(int index) const; // oldest first
	bool circling() const;
	bool oscillating() const;

private:
	void push(const AirStallSample &sample);
	void evaluate();
	AirEscalation enter(AirEscalation level, const char *cause);

	AirStallTuning tuning_;
	AirStallSample ring_[CAPACITY];
	int count_ = 0;
	int next_ = 0;
	double clock_ = 0.0;
	double since_sample_ = 0.0;
	double acc_gained_ = 0.0;
	double acc_expected_ = 0.0;
	double acc_following_ = 0.0;
	double yielding_run_ = 0.0;
	double geometry_wait_ = 0.0;
	double planning_wait_ = 0.0;
	double route_wait_ = 0.0;
	double total_stalled_ = 0.0;
	double window_gain_ = 0.0;
	double level_time_ = 0.0;
	bool stalled_ = false;
	bool awaiting_route_ = false;
	bool forced_ = false; // a forced REPLAN / ALTERNATE: progress does not cancel it, a new route does
	const char *cause_ = "";
	AirEscalation level_ = AirEscalation::NONE;
	AirFollowClass effective_ = AirFollowClass::FOLLOWING;
	int repairs_ = 0;
	int replans_ = 0;
	int alternates_ = 0;
};

} // namespace nav_air
