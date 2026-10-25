// See air_governor.h.
#include "air_governor.h"

#include "air_search.h"

#include <algorithm>
#include <cmath>

namespace nav_air {

namespace {

constexpr double PI_VALUE = 3.14159265358979323846;

double wrap(double angle) {
	angle = std::fmod(angle + PI_VALUE, 2.0 * PI_VALUE);
	if (angle < 0.0) {
		angle += 2.0 * PI_VALUE;
	}
	return angle - PI_VALUE;
}

Vec3 lerp(const Vec3 &a, const Vec3 &b, float t) {
	return Vec3{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t};
}

} // namespace

const char *air_horizon_reason_name(AirHorizonReason reason) {
	switch (reason) {
		case AirHorizonReason::CLEAR:
			return "clear";
		case AirHorizonReason::TERMINAL:
			return "terminal";
		case AirHorizonReason::PARTIAL_END:
			return "partial_end";
		case AirHorizonReason::UNKNOWN_AHEAD:
			return "unknown_ahead";
		case AirHorizonReason::SOLID_AHEAD:
			return "solid_ahead";
		case AirHorizonReason::NO_CORRIDOR:
			return "no_corridor";
	}
	return "unknown";
}

AirHorizon air_evaluate_horizon(const AirSpace &space, const AirHorizonQuery &query, const AirHorizonConfig &config) {
	AirHorizon out;
	out.capability = config.capability;
	const float speed = std::isfinite(query.speed) ? std::max(0.0f, query.speed) : 0.0f;
	const float wanted = std::max(speed, std::isfinite(query.wanted_speed) ? query.wanted_speed : 0.0f);
	out.required = air_required_distance(speed, config.latency, config.braking, config.margin);
	out.end_point = query.actor;
	const std::vector<Vec3> *points = query.points;
	const std::vector<float> *cumulative = query.cumulative;
	if (points == nullptr || cumulative == nullptr || points->size() < 2 || cumulative->size() != points->size() ||
			!std::isfinite(query.actor.x) || !std::isfinite(query.actor.y) || !std::isfinite(query.actor.z)) {
		out.reason = AirHorizonReason::NO_CORRIDOR;
		out.speed_limit = 0.0f;
		out.limited = wanted > 0.0f;
		return out;
	}
	const std::vector<Vec3> &p = *points;
	const std::vector<float> &c = *cumulative;
	const float need = std::min(config.max_scan,
			air_required_distance(wanted, config.latency, config.braking, config.margin) + std::max(0.0f, config.scan_extra));
	const float progress = std::max(0.0f, std::min(query.progress, c.back()));
	size_t seg = 0;
	while (seg + 2 < p.size() && c[seg + 1] <= progress) {
		++seg;
	}
	const float seg_len = c[seg + 1] - c[seg];
	const Vec3 at = seg_len > 0.0f ? lerp(p[seg], p[seg + 1], (progress - c[seg]) / seg_len) : p[seg];

	float travelled = 0.0f;
	bool blocked = false;
	bool capped = false;
	// Certifies a-b (clipped to the scan need). False when blocked or the cap was reached.
	auto walk = [&](const Vec3 &a, const Vec3 &b) -> bool {
		float len = air_distance(a, b);
		Vec3 end = b;
		bool last = false;
		if (travelled + len >= need) {
			const float keep = std::max(0.0f, need - travelled);
			end = len > 0.0f ? lerp(a, b, keep / len) : a;
			len = keep;
			last = true;
		}
		AirSegmentCheck info;
		const bool clear = air_segment_clear(space, a, end, 0.0f, &info);
		out.voxels += info.voxels;
		if (!clear) {
			const float t = std::max(0.0f, std::min(1.0f, info.t));
			travelled += t * len;
			out.end_point = lerp(a, end, t);
			out.reason = info.blocking == Cell::SOLID ? AirHorizonReason::SOLID_AHEAD : AirHorizonReason::UNKNOWN_AHEAD;
			blocked = true;
			return false;
		}
		travelled += len;
		out.end_point = end;
		if (last) {
			capped = true;
			return false;
		}
		return true;
	};

	bool going = walk(query.actor, at);
	if (going) {
		going = walk(at, p[seg + 1]);
	}
	for (size_t i = seg + 1; going && i + 1 < p.size(); ++i) {
		going = walk(p[i], p[i + 1]);
	}
	out.known_safe = travelled;
	if (!blocked) {
		out.reason = capped ? AirHorizonReason::CLEAR
							: (query.terminal_end ? AirHorizonReason::TERMINAL : AirHorizonReason::PARTIAL_END);
	}
	const float safe = air_max_safe_speed(out.known_safe, config.latency, config.braking, config.margin, config.capability);
	switch (out.reason) {
		case AirHorizonReason::TERMINAL:
			out.speed_limit = config.capability;
			break;
		case AirHorizonReason::CLEAR:
			// Covers the wanted speed by construction; report the true bound (never above capability).
			out.speed_limit = std::max(safe, std::min(wanted, config.capability));
			break;
		default:
			out.speed_limit = safe;
			break;
	}
	out.limited = out.speed_limit + 1.0e-4f < wanted;
	return out;
}

// ---------------------------------------------------------------- stall classification

const char *air_follow_class_name(AirFollowClass klass) {
	switch (klass) {
		case AirFollowClass::FOLLOWING:
			return "following";
		case AirFollowClass::YIELDING:
			return "yielding";
		case AirFollowClass::WAITING_GEOMETRY:
			return "waiting_geometry";
		case AirFollowClass::WAITING_ROUTE:
			return "waiting_route";
		case AirFollowClass::HOLDING:
			return "holding";
	}
	return "unknown";
}

const char *air_escalation_name(AirEscalation level) {
	switch (level) {
		case AirEscalation::NONE:
			return "none";
		case AirEscalation::LOCAL_REPAIR:
			return "local_repair";
		case AirEscalation::REPLAN:
			return "replan";
		case AirEscalation::ALTERNATE:
			return "alternate";
		case AirEscalation::FAILED:
			return "failed";
	}
	return "unknown";
}

void AirStallMonitor::reset() {
	const AirStallTuning keep = tuning_;
	*this = AirStallMonitor();
	tuning_ = keep;
}

void AirStallMonitor::route_replaced(uint64_t) {
	if (awaiting_route_) {
		awaiting_route_ = false;
		level_time_ = 0.0;
	}
	route_wait_ = 0.0;
	forced_ = false;
}

const AirStallSample &AirStallMonitor::sample(int index) const {
	if (count_ < CAPACITY) {
		return ring_[index];
	}
	return ring_[(next_ + index) % CAPACITY];
}

void AirStallMonitor::push(const AirStallSample &value) {
	ring_[next_] = value;
	next_ = (next_ + 1) % CAPACITY;
	if (count_ < CAPACITY) {
		++count_;
	}
}

AirEscalation AirStallMonitor::enter(AirEscalation level, const char *cause) {
	level_ = level;
	level_time_ = 0.0;
	cause_ = cause;
	awaiting_route_ = level == AirEscalation::REPLAN || level == AirEscalation::ALTERNATE;
	route_wait_ = 0.0;
	if (!awaiting_route_) {
		forced_ = false;
	}
	if (level == AirEscalation::LOCAL_REPAIR) {
		++repairs_;
	} else if (level == AirEscalation::REPLAN) {
		++replans_;
	} else if (level == AirEscalation::ALTERNATE) {
		++alternates_;
	}
	return level;
}

AirEscalation AirStallMonitor::force(AirEscalation level, const char *cause) {
	if (uint8_t(level_) >= uint8_t(level)) {
		return AirEscalation::NONE;
	}
	const AirEscalation entered = enter(level, cause);
	forced_ = awaiting_route_; // physical evidence: only a new route clears this request
	return entered;
}

AirEscalation AirStallMonitor::update(double dt, AirFollowClass klass, const AirStallSample &now) {
	if (!(dt > 0.0) || !std::isfinite(dt) || level_ == AirEscalation::FAILED) {
		return AirEscalation::NONE;
	}
	clock_ += dt;
	AirFollowClass effective = klass;
	if (klass == AirFollowClass::YIELDING) {
		yielding_run_ += dt;
		if (yielding_run_ > tuning_.yielding_limit) {
			effective = AirFollowClass::FOLLOWING; // endless yielding is judged like following
		}
	} else {
		yielding_run_ = 0.0;
	}
	if (klass == AirFollowClass::WAITING_GEOMETRY) {
		geometry_wait_ += dt;
	} else {
		geometry_wait_ = 0.0;
	}
	if (klass == AirFollowClass::WAITING_ROUTE) {
		planning_wait_ += dt;
	}
	if (awaiting_route_) {
		route_wait_ += dt;
	}
	effective_ = effective;
	if (effective == AirFollowClass::FOLLOWING) {
		acc_following_ += dt;
		acc_expected_ += std::max(0.0, std::isfinite(now.permitted) ? now.permitted : 0.0) * dt;
	}
	acc_gained_ += std::max(0.0, std::isfinite(now.gained) ? now.gained : 0.0);
	since_sample_ += dt;
	if (since_sample_ >= 1.0 / tuning_.sample_hz) {
		AirStallSample value = now;
		value.t = clock_;
		value.gained = acc_gained_;
		value.expected = acc_expected_;
		value.following = acc_following_;
		value.klass = effective;
		push(value);
		evaluate();
		if (stalled_) {
			total_stalled_ += since_sample_;
		}
		since_sample_ = 0.0;
		acc_gained_ = 0.0;
		acc_expected_ = 0.0;
		acc_following_ = 0.0;
	}
	if (tuning_.intent_deadline > 0.0 && clock_ > tuning_.intent_deadline) {
		return enter(AirEscalation::FAILED, "intent deadline passed");
	}
	if (total_stalled_ > tuning_.total_stall_limit) {
		return enter(AirEscalation::FAILED, "stalled too long in total");
	}
	// Bounded waits escalate one level (at least to a replan) instead of waiting forever.
	if (geometry_wait_ > tuning_.geometry_wait_limit) {
		geometry_wait_ = 0.0;
		const AirEscalation next = level_ < AirEscalation::REPLAN ? AirEscalation::REPLAN : AirEscalation(uint8_t(level_) + 1);
		return enter(next, "geometry wait too long");
	}
	if (awaiting_route_ && route_wait_ > tuning_.route_wait_limit) {
		return enter(AirEscalation(uint8_t(level_) + 1), "route request unanswered");
	}
	if (!awaiting_route_ && level_ != AirEscalation::NONE) {
		level_time_ += dt;
	}
	if (level_ == AirEscalation::NONE) {
		if (stalled_) {
			return enter(AirEscalation::LOCAL_REPAIR, cause_);
		}
		return AirEscalation::NONE;
	}
	if (!stalled_ && !forced_ && window_gain_ >= tuning_.resume_gain) {
		// Progress resumed: plain following again. Counters and the total budget remain.
		level_ = AirEscalation::NONE;
		level_time_ = 0.0;
		awaiting_route_ = false;
		route_wait_ = 0.0;
		return AirEscalation::NONE;
	}
	if (awaiting_route_) {
		return AirEscalation::NONE;
	}
	const double deadline = level_ == AirEscalation::LOCAL_REPAIR ? tuning_.repair_seconds
			: level_ == AirEscalation::REPLAN						 ? tuning_.replan_seconds
																	 : tuning_.alternate_seconds;
	if (level_time_ >= deadline && stalled_) {
		return enter(AirEscalation(uint8_t(level_) + 1), cause_);
	}
	return AirEscalation::NONE;
}

void AirStallMonitor::evaluate() {
	double gained = 0.0;
	double expected = 0.0;
	double following = 0.0;
	const double newest = sample(count_ - 1).t;
	for (int i = count_ - 1; i >= 0; --i) {
		const AirStallSample &value = sample(i);
		if (newest - value.t >= tuning_.stall_window) {
			break;
		}
		gained += value.gained;
		expected += value.expected;
		following += value.following;
	}
	window_gain_ = gained;
	stalled_ = false;
	if (following >= tuning_.following_share * tuning_.stall_window && expected >= tuning_.expected_floor &&
			gained < tuning_.stall_fraction * expected) {
		stalled_ = true;
		cause_ = "no progress while following";
	} else if (circling()) {
		stalled_ = true;
		cause_ = "circling";
	} else if (oscillating()) {
		stalled_ = true;
		cause_ = "oscillation";
	}
}

bool AirStallMonitor::circling() const {
	if (count_ < 2) {
		return false;
	}
	const double newest = sample(count_ - 1).t;
	double turned = 0.0;
	double first_distance = -1.0;
	double best_distance = 0.0;
	for (int i = 0; i < count_; ++i) {
		const AirStallSample &value = sample(i);
		if (newest - value.t > tuning_.circling_window) {
			continue;
		}
		if (first_distance < 0.0) {
			first_distance = value.goal_distance;
			best_distance = value.goal_distance;
		} else {
			if (value.klass == AirFollowClass::FOLLOWING && sample(i - 1).klass == AirFollowClass::FOLLOWING) {
				turned += std::fabs(wrap(value.yaw - sample(i - 1).yaw));
			}
			best_distance = std::min(best_distance, value.goal_distance);
		}
	}
	return turned >= 2.0 * PI_VALUE && first_distance - best_distance < tuning_.circling_progress;
}

bool AirStallMonitor::oscillating() const {
	if (count_ < 3) {
		return false;
	}
	const double newest = sample(count_ - 1).t;
	int flips = 0;
	int trend = 0;
	double extreme = 0.0;
	uint64_t route = 0;
	bool started = false;
	for (int i = 0; i < count_; ++i) {
		const AirStallSample &value = sample(i);
		if (newest - value.t > tuning_.oscillation_window) {
			continue;
		}
		if (!started || value.route != route) {
			started = true;
			route = value.route;
			extreme = value.raw_progress;
			trend = 0;
			flips = 0;
			continue;
		}
		const double progress = value.raw_progress;
		if (trend >= 0 && progress > extreme) {
			extreme = progress;
			trend = 1;
		} else if (trend <= 0 && progress < extreme) {
			extreme = progress;
			trend = -1;
		} else if (std::fabs(progress - extreme) > tuning_.oscillation_amplitude) {
			trend = trend != 0 ? -trend : (progress > extreme ? 1 : -1);
			extreme = progress;
			++flips;
		}
	}
	return flips >= tuning_.oscillation_reversals;
}

} // namespace nav_air
