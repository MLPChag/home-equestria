// See air_transitions.h.
#include "air_transitions.h"

#include <algorithm>
#include <cmath>

namespace nav_air {

namespace {

constexpr float PI_F = 3.14159265358979323846f;
const Vec3 UP{0.0f, 1.0f, 0.0f};

Vec3 add(const Vec3 &a, const Vec3 &b) { return Vec3{a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 sub(const Vec3 &a, const Vec3 &b) { return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 mul(const Vec3 &a, float s) { return Vec3{a.x * s, a.y * s, a.z * s}; }
float dot(const Vec3 &a, const Vec3 &b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
float len(const Vec3 &a) { return std::sqrt(dot(a, a)); }
float dist(const Vec3 &a, const Vec3 &b) { return len(sub(a, b)); }
float len_xz(const Vec3 &a) { return std::sqrt(a.x * a.x + a.z * a.z); }
bool finite3(const Vec3 &v) { return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z); }
Vec3 rotate_y(const Vec3 &v, float a) {
	const float c = std::cos(a), s = std::sin(a);
	return Vec3{v.x * c + v.z * s, v.y, -v.x * s + v.z * c};
}
Vec3 move_toward(const Vec3 &from, const Vec3 &to, float delta) {
	const Vec3 d = sub(to, from);
	const float l = len(d);
	if (l <= delta || l < 1.0e-6f) {
		return to;
	}
	return add(from, mul(d, delta / l));
}
bool finite_state(const TransitionActorState &s) {
	return finite3(s.root) && finite3(s.velocity) && std::isfinite(s.yaw);
}

struct Projection {
	uint32_t index = 0; // segment index (pts[index] -> pts[index + 1])
	Vec3 point{0, 0, 0};
	float remaining = 0.0f; // along the polyline from point to its end
	float offset = 0.0f; // distance from the query point to `point`
};

// Projects p on segments [index, index + window) of the polyline. Ties prefer the later segment,
// so an actor standing on a vertex advances.
Projection project_polyline(const std::vector<Vec3> &pts, uint32_t index, const Vec3 &p, uint32_t window) {
	Projection pr;
	if (pts.empty()) {
		pr.point = p;
		return pr;
	}
	if (pts.size() == 1) {
		pr.point = pts[0];
		pr.offset = dist(p, pts[0]);
		return pr;
	}
	const uint32_t last = uint32_t(pts.size()) - 2;
	index = std::min(index, last);
	const uint32_t end = std::min(last, index + std::max(1u, window) - 1);
	float best = INFINITY;
	for (uint32_t i = index; i <= end; ++i) {
		const Vec3 ab = sub(pts[i + 1], pts[i]);
		const float l2 = dot(ab, ab);
		const float t = l2 > 1.0e-12f ? std::max(0.0f, std::min(1.0f, dot(sub(p, pts[i]), ab) / l2)) : 0.0f;
		const Vec3 q = add(pts[i], mul(ab, t));
		const float d = dist(p, q);
		if (d <= best) {
			best = d;
			pr.index = i;
			pr.point = q;
		}
	}
	pr.offset = best;
	pr.remaining = dist(pr.point, pts[pr.index + 1]);
	for (size_t j = pr.index + 2; j < pts.size(); ++j) {
		pr.remaining += dist(pts[j - 1], pts[j]);
	}
	return pr;
}

Vec3 point_along(const std::vector<Vec3> &pts, const Projection &pr, float distance, bool *at_end) {
	if (at_end != nullptr) {
		*at_end = false;
	}
	if (pts.empty()) {
		return pr.point;
	}
	Vec3 p = pr.point;
	float left = std::max(0.0f, distance);
	for (size_t i = size_t(pr.index) + 1; i < pts.size(); ++i) {
		const float l = dist(pts[i], p);
		if (l >= left && l > 1.0e-6f) {
			return add(p, mul(sub(pts[i], p), left / l));
		}
		left -= l;
		p = pts[i];
	}
	if (at_end != nullptr) {
		*at_end = true;
	}
	return pts.back();
}

std::vector<Vec3> path_from(const std::vector<Vec3> &pts, const Projection &pr) {
	std::vector<Vec3> out;
	out.push_back(pr.point);
	for (size_t i = size_t(pr.index) + 1; i < pts.size(); ++i) {
		out.push_back(pts[i]);
	}
	return out;
}

bool is_pad_problem(TransitionReason r) {
	switch (r) {
		case TransitionReason::PAD_RESERVATION_LOST:
		case TransitionReason::PAD_RESERVATION_WAIT:
		case TransitionReason::NONE:
			return false;
		default:
			return true;
	}
}

} // namespace

// ---- Names -------------------------------------------------------------------------------------

const char *transition_reason_name(TransitionReason reason) {
	switch (reason) {
		case TransitionReason::NONE: return "NONE";
		case TransitionReason::INVALID_INPUT: return "INVALID_INPUT";
		case TransitionReason::NO_WINGS: return "NO_WINGS";
		case TransitionReason::CLOUD_NOT_ALLOWED: return "CLOUD_NOT_ALLOWED";
		case TransitionReason::SURFACE_MISMATCH: return "SURFACE_MISMATCH";
		case TransitionReason::WRONG_HEIGHT: return "WRONG_HEIGHT";
		case TransitionReason::OFF_PAD: return "OFF_PAD";
		case TransitionReason::NOT_SUPPORTED: return "NOT_SUPPORTED";
		case TransitionReason::WATER_SURFACE: return "WATER_SURFACE";
		case TransitionReason::ROOF_SURFACE: return "ROOF_SURFACE";
		case TransitionReason::SLOPE_TOO_STEEP: return "SLOPE_TOO_STEEP";
		case TransitionReason::NO_SUPPORT: return "NO_SUPPORT";
		case TransitionReason::PROVISIONAL_SUPPORT: return "PROVISIONAL_SUPPORT";
		case TransitionReason::BODY_BLOCKED: return "BODY_BLOCKED";
		case TransitionReason::OCCUPIED: return "OCCUPIED";
		case TransitionReason::SWEEP_BLOCKED: return "SWEEP_BLOCKED";
		case TransitionReason::GROUND_TRAFFIC: return "GROUND_TRAFFIC";
		case TransitionReason::NO_TAKEOFF_FOOTPRINT: return "NO_TAKEOFF_FOOTPRINT";
		case TransitionReason::TAKEOFF_VOLUME_BLOCKED: return "TAKEOFF_VOLUME_BLOCKED";
		case TransitionReason::DEPARTURE_RESERVATION_WAIT: return "DEPARTURE_RESERVATION_WAIT";
		case TransitionReason::NO_PAD: return "NO_PAD";
		case TransitionReason::APPROACH_VOLUME_BLOCKED: return "APPROACH_VOLUME_BLOCKED";
		case TransitionReason::PAD_RESERVATION_WAIT: return "PAD_RESERVATION_WAIT";
		case TransitionReason::PAD_RESERVATION_LOST: return "PAD_RESERVATION_LOST";
		case TransitionReason::HOVER_POINT_BLOCKED: return "HOVER_POINT_BLOCKED";
		case TransitionReason::ROUTE_PENDING: return "ROUTE_PENDING";
		case TransitionReason::ROUTE_WAITING_FOR_GEOMETRY: return "ROUTE_WAITING_FOR_GEOMETRY";
		case TransitionReason::ROUTE_UNREACHABLE: return "ROUTE_UNREACHABLE";
		case TransitionReason::ROUTE_BUDGET_EXHAUSTED: return "ROUTE_BUDGET_EXHAUSTED";
		case TransitionReason::ROUTE_START_BLOCKED: return "ROUTE_START_BLOCKED";
		case TransitionReason::ROUTE_FAILED: return "ROUTE_FAILED";
		case TransitionReason::CORRIDOR_BLOCKED: return "CORRIDOR_BLOCKED";
		case TransitionReason::CORRIDOR_MISSING_DATA: return "CORRIDOR_MISSING_DATA";
		case TransitionReason::NO_HOLDING_VOLUME: return "NO_HOLDING_VOLUME";
		case TransitionReason::ALL_PADS_BLOCKED: return "ALL_PADS_BLOCKED";
		case TransitionReason::WAIT_TIMEOUT: return "WAIT_TIMEOUT";
		case TransitionReason::LANDING_TIMEOUT: return "LANDING_TIMEOUT";
		case TransitionReason::TOUCHDOWN_TOO_FAST: return "TOUCHDOWN_TOO_FAST";
		case TransitionReason::MANOEUVRE_NOT_ALLOWED: return "MANOEUVRE_NOT_ALLOWED";
		case TransitionReason::MANOEUVRE_VOLUME_BLOCKED: return "MANOEUVRE_VOLUME_BLOCKED";
		case TransitionReason::MANOEUVRE_BUSY: return "MANOEUVRE_BUSY";
		case TransitionReason::INTERRUPTED: return "INTERRUPTED";
		case TransitionReason::CANCELLED: return "CANCELLED";
		case TransitionReason::DESPAWNED: return "DESPAWNED";
	}
	return "?";
}

const char *journey_mode_name(JourneyMode mode) {
	switch (mode) {
		case JourneyMode::GROUND: return "GROUND";
		case JourneyMode::TAKEOFF: return "TAKEOFF";
		case JourneyMode::AIR: return "AIR";
		case JourneyMode::APPROACH: return "APPROACH";
		case JourneyMode::LANDING: return "LANDING";
	}
	return "?";
}

const char *motion_owner_name(MotionOwner owner) {
	switch (owner) {
		case MotionOwner::NONE: return "NONE";
		case MotionOwner::GROUND: return "GROUND";
		case MotionOwner::AIR: return "AIR";
		case MotionOwner::EXTERNAL: return "EXTERNAL";
	}
	return "?";
}

const char *journey_status_name(JourneyStatus status) {
	switch (status) {
		case JourneyStatus::IDLE: return "IDLE";
		case JourneyStatus::ACTIVE: return "ACTIVE";
		case JourneyStatus::ARRIVED: return "ARRIVED";
		case JourneyStatus::FAILED: return "FAILED";
		case JourneyStatus::CANCELLED: return "CANCELLED";
	}
	return "?";
}

const char *command_kind_name(CommandKind kind) {
	switch (kind) {
		case CommandKind::NONE: return "NONE";
		case CommandKind::IDLE: return "IDLE";
		case CommandKind::WALK: return "WALK";
		case CommandKind::CLIMB: return "CLIMB";
		case CommandKind::FLY: return "FLY";
		case CommandKind::HOLD: return "HOLD";
		case CommandKind::GLIDE: return "GLIDE";
		case CommandKind::FLARE: return "FLARE";
		case CommandKind::HOVER: return "HOVER";
		case CommandKind::BRAKE: return "BRAKE";
	}
	return "?";
}

const char *transition_event_name(TransitionEventKind kind) {
	switch (kind) {
		case TransitionEventKind::MODE_CHANGED: return "MODE_CHANGED";
		case TransitionEventKind::REFUSED: return "REFUSED";
		case TransitionEventKind::PAD_SELECTED: return "PAD_SELECTED";
		case TransitionEventKind::PAD_REJECTED: return "PAD_REJECTED";
		case TransitionEventKind::HOLDING: return "HOLDING";
		case TransitionEventKind::GO_AROUND: return "GO_AROUND";
		case TransitionEventKind::ARRIVED: return "ARRIVED";
		case TransitionEventKind::FAILED: return "FAILED";
		case TransitionEventKind::CANCELLED: return "CANCELLED";
		case TransitionEventKind::MANOEUVRE_STARTED: return "MANOEUVRE_STARTED";
		case TransitionEventKind::MANOEUVRE_DONE: return "MANOEUVRE_DONE";
	}
	return "?";
}

// ---- Capabilities ------------------------------------------------------------------------------

uint32_t air_capabilities_for_race(AirRace race) {
	switch (race) {
		case AirRace::PEGASUS:
		case AirRace::ALICORN:
			return AIR_CAP_WINGS | AIR_CAP_CLOUD_SUPPORT;
		case AirRace::EARTH:
		case AirRace::UNICORN:
			return 0;
	}
	return 0;
}

bool air_link_allowed(uint32_t capabilities, AirLinkKind link) {
	switch (link) {
		case AirLinkKind::WALK: return true;
		case AirLinkKind::WING: return (capabilities & AIR_CAP_WINGS) != 0;
		case AirLinkKind::CLOUD: return (capabilities & AIR_CAP_CLOUD_SUPPORT) != 0;
	}
	return false;
}

bool TransitionProfile::valid(std::string &error) const {
	const float positive[] = {body.radius, body.height, body.centre_height, body.wing_radius, envelope_radius,
		limits.max_speed, limits.max_accel, limits.max_brake, limits.max_climb_rate, limits.max_descent_rate,
		footprint_ring_step, footprint_tolerance, departure_climb, takeoff_speed_low, takeoff_speed_high, glide_ratio,
		approach_height, flare_distance, approach_speed, flare_speed, touchdown_speed, pad_height_tolerance,
		max_slope_degrees, hold_drift, hover_speed, waypoint_tolerance, traffic_horizon};
	for (float v : positive) {
		if (!std::isfinite(v) || v <= 0.0f) {
			error = "profile values must be finite and positive";
			return false;
		}
	}
	const float non_negative[] = {body.step, footprint_search_radius, entry_margin, entry_scan, flare_height, cut_margin,
		cone_base_radius, cone_top_radius, pad_margin, reserve_ahead_distance};
	for (float v : non_negative) {
		if (!std::isfinite(v) || v < 0.0f) {
			error = "profile values must be finite and non-negative";
			return false;
		}
	}
	const double times[] = {takeoff_wait_limit, pad_wait_limit, hold_limit, route_wait_limit, route_retry,
		landing_time_limit, pad_recheck, pad_retry};
	for (double v : times) {
		if (!std::isfinite(v) || v <= 0.0) {
			error = "profile times must be finite and positive";
			return false;
		}
	}
	if (footprint_directions == 0 || approach_height <= flare_height || body.step >= body.height) {
		error = "profile geometry is inconsistent";
		return false;
	}
	return true;
}

// ---- Free helpers ------------------------------------------------------------------------------

bool air_traffic_conflict(const std::vector<PredictedCapsule> &traffic, const AirCylinder &volume, float horizon,
		uint64_t self, uint64_t *who) {
	const float h = std::max(0.0f, horizon);
	for (const PredictedCapsule &c : traffic) {
		if (c.actor == self || !finite3(c.base) || !finite3(c.velocity)) {
			continue;
		}
		const float y0 = std::min(c.base.y, c.base.y + c.velocity.y * h);
		const float y1 = std::max(c.base.y, c.base.y + c.velocity.y * h) + c.height;
		if (!(y0 < volume.base.y + volume.height && volume.base.y < y1)) {
			continue;
		}
		// Closest horizontal approach of the linear prediction over [0, h].
		const float px = c.base.x - volume.base.x, pz = c.base.z - volume.base.z;
		const float vx = c.velocity.x, vz = c.velocity.z;
		const float vv = vx * vx + vz * vz;
		float t = vv > 1.0e-9f ? -(px * vx + pz * vz) / vv : 0.0f;
		t = std::max(0.0f, std::min(h, t));
		const float dx = px + vx * t, dz = pz + vz * t;
		const float r = volume.radius + c.radius;
		if (dx * dx + dz * dz < r * r) {
			if (who != nullptr) {
				*who = c.actor;
			}
			return true;
		}
	}
	return false;
}

TransitionReason air_landed_check(const TransitionActorState &actor, const Vec3 &pad, uint32_t pad_surface_id,
		float horizontal_tolerance, float height_tolerance, float max_speed) {
	if (!finite_state(actor) || !finite3(pad)) {
		return TransitionReason::INVALID_INPUT;
	}
	if (!actor.supported) {
		return TransitionReason::NOT_SUPPORTED;
	}
	if (len_xz(sub(actor.root, pad)) > horizontal_tolerance) {
		return TransitionReason::OFF_PAD;
	}
	if (std::fabs(actor.root.y - pad.y) > height_tolerance) {
		return TransitionReason::WRONG_HEIGHT;
	}
	if (pad_surface_id != 0 && actor.support_surface_id != pad_surface_id) {
		return TransitionReason::SURFACE_MISMATCH;
	}
	if (len(actor.velocity) > max_speed) {
		return TransitionReason::TOUCHDOWN_TOO_FAST;
	}
	return TransitionReason::NONE;
}

Vec3 air_transition_pursuit(const Vec3 &root, const Vec3 &velocity, const std::vector<Vec3> &path, float speed_limit,
		float end_speed, const AirFlightLimits &limits, float dt, float min_glide_ratio) {
	if (!(dt > 0.0f) || !finite3(root) || !finite3(velocity)) {
		return Vec3{0, 0, 0};
	}
	if (path.empty()) {
		return move_toward(velocity, Vec3{0, 0, 0}, limits.max_brake * dt);
	}
	// The path starts at the actor's projection: a short window keeps a closed loop (whose end is
	// its start) from reading as finished.
	const Projection pr = project_polyline(path, 0, root, 2);
	const float remaining = pr.remaining + pr.offset;
	float speed = std::min(std::max(0.0f, speed_limit),
			std::sqrt(end_speed * end_speed + 2.0f * limits.max_brake * remaining));
	const float look = std::max(0.3f, std::min(4.0f, len(velocity) * 0.25f));
	bool at_end = false;
	const Vec3 carrot = point_along(path, pr, look, &at_end);
	const Vec3 to = sub(carrot, root);
	const float d = len(to);
	Vec3 wanted{0, 0, 0};
	if (d > 1.0e-4f) {
		if (at_end && end_speed <= 0.0f) {
			speed = std::min(speed, d / dt);
		}
		wanted = mul(to, speed / d);
	}
	if (min_glide_ratio > 0.0f && wanted.y < 0.0f && -wanted.y * min_glide_ratio > len_xz(wanted)) {
		// Above the glide line the carrot lies steeply below. Instead of dropping onto it, keep
		// flying forward along the path's heading and descend at the steepest allowed ratio; the
		// path is shallower than that ratio, so she rejoins it from above.
		Vec3 heading = path.size() > size_t(pr.index) + 1 ? sub(path[pr.index + 1], path[pr.index]) : sub(path.back(), root);
		heading.y = 0.0f;
		if (len(heading) < 1.0e-4f) {
			heading = Vec3{wanted.x, 0.0f, wanted.z};
		}
		const float h = len(heading);
		if (h > 1.0e-6f) {
			const Vec3 dir{heading.x / h, -1.0f / min_glide_ratio, heading.z / h};
			wanted = mul(dir, len(wanted) / len(dir));
		} else {
			wanted.y = 0.0f; // no horizontal reference at all: hold height rather than drop
		}
	}
	wanted.y = std::max(-limits.max_descent_rate, std::min(limits.max_climb_rate, wanted.y));
	const float rate = len(wanted) >= len(velocity) ? limits.max_accel : limits.max_brake;
	Vec3 v = move_toward(velocity, wanted, rate * dt);
	if (min_glide_ratio > 0.0f) {
		v.y = std::max(v.y, -len_xz(v) / min_glide_ratio);
	}
	return v;
}

// ---- SyncAirRoutePlanner -----------------------------------------------------------------------

SyncAirRoutePlanner::SyncAirRoutePlanner(const AirSpace &space, const AirSearchLimits &limits) :
		space_(space), limits_(limits) {}

uint64_t SyncAirRoutePlanner::request(const Vec3 &start, const AirGoal &goal) {
	++requests_;
	Done d;
	d.ticket = next_++;
	d.status = search_.begin(space_, start, goal, limits_);
	if (d.status == AirStatus::PENDING) {
		d.status = search_.run_to_end();
	}
	if (d.status == AirStatus::COMPLETE) {
		d.route = search_.route();
		std::vector<Vec3> shortened;
		if (air_shorten(space_, d.route.points, shortened)) {
			d.route.points = shortened;
		}
	}
	done_.push_back(d);
	return d.ticket;
}

AirStatus SyncAirRoutePlanner::poll(uint64_t ticket, AirRoute &out) {
	for (size_t i = 0; i < done_.size(); ++i) {
		if (done_[i].ticket == ticket) {
			const AirStatus status = done_[i].status;
			out = done_[i].route;
			done_.erase(done_.begin() + long(i));
			return status;
		}
	}
	return AirStatus::INVALID;
}

void SyncAirRoutePlanner::cancel(uint64_t ticket) {
	for (size_t i = 0; i < done_.size(); ++i) {
		if (done_[i].ticket == ticket) {
			done_.erase(done_.begin() + long(i));
			return;
		}
	}
}

// ---- AirJourney: bookkeeping -------------------------------------------------------------------

AirJourney::AirJourney(const AirActorKey &actor, const TransitionProfile &profile) :
		actor_(actor), profile_(profile) {}

Vec3 AirJourney::centre(const Vec3 &root) const {
	return add(root, mul(UP, profile_.body.centre_height));
}

Vec3 AirJourney::root_of(const Vec3 &c) const {
	return sub(c, mul(UP, profile_.body.centre_height));
}

uint32_t AirJourney::active_pad() const {
	return active_pad_ >= 0 && size_t(active_pad_) < pads_.size() ? pads_[size_t(active_pad_)].pad.pad_id : 0;
}

std::vector<TransitionEvent> AirJourney::take_events() {
	std::vector<TransitionEvent> out;
	out.swap(events_);
	return out;
}

void AirJourney::emit(TransitionEventKind kind, TransitionReason reason, double now, uint32_t pad) {
	TransitionEvent e;
	e.kind = kind;
	e.from = e.to = mode_;
	e.owner_from = e.owner_to = owner_;
	e.ownership_epoch = epoch_;
	e.reason = reason;
	e.pad_id = pad;
	e.intent_generation = intent_.generation;
	e.time = now;
	if (events_.size() >= 256) {
		events_.erase(events_.begin()); // undrained diagnostics stay bounded
	}
	events_.push_back(e);
}

void AirJourney::change_mode(JourneyMode to, MotionOwner owner, TransitionReason reason, double now) {
	TransitionEvent e;
	e.kind = TransitionEventKind::MODE_CHANGED;
	e.from = mode_;
	e.to = to;
	e.owner_from = owner_;
	e.owner_to = owner;
	if (owner != owner_) {
		++epoch_; // exactly one ownership change for this transition
	}
	e.ownership_epoch = epoch_;
	e.reason = reason;
	e.pad_id = active_pad();
	e.intent_generation = intent_.generation;
	e.time = now;
	mode_ = to;
	owner_ = owner;
	if (events_.size() >= 256) {
		events_.erase(events_.begin());
	}
	events_.push_back(e);
}

void AirJourney::release_own(TransitionWorld &world, ReservationEnd why, double now) {
	if (world.reservations != nullptr) {
		if (departure_ticket_ != 0) {
			world.reservations->release(departure_ticket_, why, now);
		}
		if (landing_ticket_ != 0) {
			world.reservations->release(landing_ticket_, why, now);
		}
	}
	departure_ticket_ = 0;
	landing_ticket_ = 0;
	pad_wait_since_ = -1.0;
	if (route_ticket_ != 0 && world.planner != nullptr) {
		world.planner->cancel(route_ticket_);
	}
	route_ticket_ = 0;
	route_retry_at_ = -1.0;
}

void AirJourney::fail(TransitionReason reason, TransitionWorld &world, double now) {
	release_own(world, ReservationEnd::RELEASED, now);
	status_ = JourneyStatus::FAILED;
	failure_ = reason;
	if (owner_ == MotionOwner::AIR && phase_ != AirPhase::HOLD) {
		phase_ = AirPhase::HOLD;
		hold_braking_ = true; // no certified hold chosen: stop where she is, never descend
	}
	hold_reason_ = reason;
	emit(TransitionEventKind::FAILED, reason, now, active_pad());
}

// ---- Takeoff -----------------------------------------------------------------------------------

TransitionReason AirJourney::check_footprint(const Vec3 &root, TransitionWorld &world, Footprint &out) const {
	SupportSample s;
	if (!world.support->support(root, 0.5f, 1.0f, s) || !s.hit || !finite3(s.point)) {
		return TransitionReason::NO_SUPPORT;
	}
	if (!s.live) {
		return TransitionReason::PROVISIONAL_SUPPORT;
	}
	if ((s.flags & AIR_SURFACE_WATER) != 0) {
		return TransitionReason::WATER_SURFACE;
	}
	if ((s.flags & AIR_SURFACE_CLOUD) != 0 && !air_link_allowed(profile_.capabilities, AirLinkKind::CLOUD)) {
		return TransitionReason::CLOUD_NOT_ALLOWED;
	}
	if (s.normal.y < std::cos(profile_.max_slope_degrees * PI_F / 180.0f)) {
		return TransitionReason::SLOPE_TOO_STEEP;
	}
	const BodyShape &b = profile_.body;
	const Vec3 base = s.point;
	if (!world.support->volume_clear(AirCylinder{add(base, mul(UP, b.step)), b.radius, b.height - b.step})) {
		return TransitionReason::BODY_BLOCKED;
	}
	// Air entry E: the lowest body-centre point above the footprint that the inflated AirSpace calls
	// FREE. Below it the climb is certified by live collision only (the inflated ground covers it).
	const float h0 = std::max(b.step, profile_.envelope_radius + profile_.entry_margin - b.centre_height);
	const int steps = int(std::floor(profile_.entry_scan / 0.25f + 1.0e-4f));
	float h = -1.0f;
	bool unknown = false;
	for (int i = 0; i <= steps; ++i) {
		const float t = h0 + 0.25f * float(i);
		bool u = false;
		if (air_point_clear(*world.air, centre(add(base, mul(UP, t))), &u)) {
			h = t;
			break;
		}
		unknown = unknown || u;
	}
	if (h < 0.0f) {
		return unknown ? TransitionReason::ROUTE_WAITING_FOR_GEOMETRY : TransitionReason::TAKEOFF_VOLUME_BLOCKED;
	}
	const Vec3 entry = add(base, mul(UP, h));
	const Vec3 top = add(entry, mul(UP, profile_.departure_climb));
	// Body and open wings up the whole live part of the climb (roofs, porches, crowns).
	if (!world.support->volume_clear(AirCylinder{add(base, mul(UP, b.step)), b.wing_radius, h + b.height - b.step})) {
		return TransitionReason::TAKEOFF_VOLUME_BLOCKED;
	}
	// Certified column E -> T and a holding sphere at T.
	if (!air_segment_clear(*world.air, centre(entry), centre(top), 0.0f) ||
			!air_segment_clear(*world.air, centre(top), centre(top), profile_.hold_drift)) {
		return TransitionReason::TAKEOFF_VOLUME_BLOCKED;
	}
	out.root = base;
	out.entry = entry;
	out.top = top;
	out.surface_id = s.surface_id;
	return TransitionReason::NONE;
}

TransitionReason AirJourney::select_footprint(const JourneyIntent &intent, const TransitionActorState &actor,
		TransitionWorld &world, Footprint &out) const {
	const TransitionReason first = check_footprint(actor.root, world, out);
	if (first == TransitionReason::NONE) {
		return first;
	}
	Vec3 toward = sub(intent.destination, actor.root);
	toward.y = 0.0f;
	if (len(toward) < 1.0e-3f) {
		toward = Vec3{-std::sin(actor.yaw), 0.0f, -std::cos(actor.yaw)};
	}
	toward = mul(toward, 1.0f / len(toward));
	const uint32_t n = profile_.footprint_directions;
	for (int ring = 1;; ++ring) {
		const float radius = profile_.footprint_ring_step * float(ring);
		if (radius > profile_.footprint_search_radius + 1.0e-4f) {
			break;
		}
		for (uint32_t k = 0; k < n; ++k) {
			// 0, +1, -1, +2, -2 ... steps of 360/n degrees, toward the destination first.
			const int m = int((k + 1) / 2);
			const float sign = (k % 2 == 1) ? 1.0f : -1.0f;
			const float angle = k == 0 ? 0.0f : sign * float(m) * 2.0f * PI_F / float(n);
			const Vec3 probe = add(actor.root, mul(rotate_y(toward, angle), radius));
			SupportSample s;
			if (!world.support->support(probe, 2.0f, 3.0f, s) || !s.hit || !finite3(s.point)) {
				continue;
			}
			if (check_footprint(s.point, world, out) == TransitionReason::NONE) {
				return TransitionReason::NONE;
			}
		}
	}
	return first;
}

AirCylinder AirJourney::departure_volume() const {
	return AirCylinder{footprint_, profile_.body.wing_radius + profile_.pad_margin,
		(top_.y - footprint_.y) + profile_.body.height};
}

void AirJourney::request_departure(TransitionWorld &world, double now) {
	ReservationRequest r;
	r.actor = actor_;
	r.kind = ReservationKind::DEPARTURE;
	r.resource_id = 0;
	r.volume = departure_volume();
	r.priority = intent_.priority + profile_.priority;
	departure_ticket_ = world.reservations->request(r, now);
}

TransitionReason AirJourney::departure_live_check(TransitionWorld &world) const {
	Footprint fp;
	const TransitionReason r = check_footprint(footprint_, world, fp);
	if (r != TransitionReason::NONE) {
		return r;
	}
	const BodyShape &b = profile_.body;
	const AirCylinder column{add(footprint_, mul(UP, b.step)), b.wing_radius, (top_.y - footprint_.y) + b.height - b.step};
	if (world.support->occupancy(column, actor_.packed()) != 0) {
		return TransitionReason::OCCUPIED;
	}
	if (world.ground_traffic != nullptr &&
			air_traffic_conflict(*world.ground_traffic, departure_volume(), profile_.traffic_horizon, actor_.packed())) {
		return TransitionReason::GROUND_TRAFFIC;
	}
	return TransitionReason::NONE;
}

// ---- Pads --------------------------------------------------------------------------------------

TransitionReason AirJourney::pad_surface_ok(const PadProposal &pad, uint32_t required_surface_id) const {
	if (!finite3(pad.point)) {
		return TransitionReason::INVALID_INPUT;
	}
	if ((pad.flags & AIR_SURFACE_CLOUD) != 0 && !air_link_allowed(profile_.capabilities, AirLinkKind::CLOUD)) {
		return TransitionReason::CLOUD_NOT_ALLOWED;
	}
	if ((pad.flags & AIR_SURFACE_WATER) != 0) {
		return TransitionReason::WATER_SURFACE;
	}
	if ((pad.flags & AIR_SURFACE_ROOF) != 0) {
		return TransitionReason::ROOF_SURFACE;
	}
	if (required_surface_id != 0 && pad.surface_id != required_surface_id) {
		return TransitionReason::SURFACE_MISMATCH;
	}
	return TransitionReason::NONE;
}

TransitionReason AirJourney::plan_approach(const PadProposal &pad, const Vec3 &from_root, TransitionWorld &world,
		ApproachPlan &out) const {
	const TransitionProfile &p = profile_;
	const Vec3 P = pad.point;
	Vec3 primary = sub(P, from_root);
	primary.y = 0.0f;
	if (len(primary) < 1.0e-3f) {
		primary = Vec3{0.0f, 0.0f, -1.0f};
	}
	primary = mul(primary, 1.0f / len(primary));
	// C: the body centre clears the inflated pad surface by cut_margin.
	const float cut_h = std::max(p.flare_height, p.envelope_radius + p.cut_margin - p.body.centre_height);
	const float heights[2] = {p.approach_height, std::max(cut_h + 1.0f, p.approach_height * 0.6f)};
	for (int hi = 0; hi < 2; ++hi) {
		const float h = heights[hi];
		if (h <= cut_h || (hi == 1 && h >= heights[0])) {
			continue;
		}
		for (int k = 0; k < 8; ++k) {
			const int m = (k + 1) / 2;
			const float sign = (k % 2 == 1) ? 1.0f : -1.0f;
			const float angle = k == 0 ? 0.0f : sign * float(m) * PI_F / 4.0f;
			const Vec3 d = rotate_y(primary, angle);
			const Vec3 F = add(sub(P, mul(d, p.flare_distance)), mul(UP, p.flare_height));
			const Vec3 C = add(sub(P, mul(d, p.flare_distance + (cut_h - p.flare_height) * p.glide_ratio)), mul(UP, cut_h));
			const Vec3 A = add(sub(P, mul(d, p.flare_distance + (h - p.flare_height) * p.glide_ratio)), mul(UP, h));
			// The forward glide cone A -> C, certified as pieces whose clearance widens toward A.
			const Vec3 ac = centre(A), cc = centre(C);
			const float length = dist(ac, cc);
			const int pieces = std::max(1, int(std::ceil(length / 2.0f)));
			std::vector<Vec3> pts;
			std::vector<float> radii;
			for (int i = 0; i <= pieces; ++i) {
				const float t = float(i) / float(pieces);
				pts.push_back(add(ac, mul(sub(cc, ac), t)));
				if (i < pieces) {
					// piece i runs from A toward C; use the wider (A-side) radius of the piece
					radii.push_back(p.cone_top_radius + (p.cone_base_radius - p.cone_top_radius) * t);
				}
			}
			AirCorridor cone;
			if (!air_make_corridor(*world.air, pts, radii, cone)) {
				continue;
			}
			if (!air_segment_clear(*world.air, ac, ac, p.hold_drift)) {
				continue; // A must be a certified holding volume
			}
			out.pad = pad;
			out.heading = d;
			out.entry = A;
			out.cut = C;
			out.flare = F;
			out.cone = cone;
			out.volume = AirCylinder{P, p.flare_distance + p.body.radius + p.pad_margin, cut_h + p.body.height};
			return TransitionReason::NONE;
		}
	}
	return TransitionReason::APPROACH_VOLUME_BLOCKED;
}

TransitionReason AirJourney::plan_pads(const JourneyIntent &intent, const Vec3 &from_root, TransitionWorld &world,
		double now, std::vector<ApproachPlan> &out) {
	out.clear();
	std::vector<PadProposal> proposals;
	world.support->propose_pads(intent.destination, intent.pad_search_radius, intent.required_surface_id, proposals);
	TransitionReason first = TransitionReason::NONE;
	for (const PadProposal &pad : proposals) {
		TransitionReason r = pad_surface_ok(pad, intent.required_surface_id);
		ApproachPlan plan;
		if (r == TransitionReason::NONE) {
			r = plan_approach(pad, from_root, world, plan);
		}
		if (r != TransitionReason::NONE) {
			emit(TransitionEventKind::PAD_REJECTED, r, now, pad.pad_id);
			if (first == TransitionReason::NONE) {
				first = r;
			}
			continue;
		}
		out.push_back(plan);
	}
	if (!out.empty()) {
		return TransitionReason::NONE;
	}
	return first == TransitionReason::NONE ? TransitionReason::NO_PAD : first;
}

TransitionReason AirJourney::pad_live_check(const ApproachPlan &plan, TransitionWorld &world, PadCheck level) const {
	const TransitionProfile &p = profile_;
	const BodyShape &b = p.body;
	const Vec3 P = plan.pad.point;
	SupportSample s;
	if (!world.support->support(P, 0.5f, 1.0f, s) || !s.hit || !finite3(s.point)) {
		return TransitionReason::NO_SUPPORT;
	}
	if (!s.live) {
		return TransitionReason::PROVISIONAL_SUPPORT; // a heightmap guess only proposes a pad
	}
	if (std::fabs(s.point.y - P.y) > p.pad_height_tolerance) {
		return TransitionReason::WRONG_HEIGHT;
	}
	if ((plan.pad.surface_id != 0 && s.surface_id != plan.pad.surface_id) ||
			(intent_.required_surface_id != 0 && s.surface_id != intent_.required_surface_id)) {
		return TransitionReason::SURFACE_MISMATCH;
	}
	if ((s.flags & AIR_SURFACE_CLOUD) != 0 && !air_link_allowed(p.capabilities, AirLinkKind::CLOUD)) {
		return TransitionReason::CLOUD_NOT_ALLOWED;
	}
	if ((s.flags & AIR_SURFACE_WATER) != 0) {
		return TransitionReason::WATER_SURFACE;
	}
	if ((s.flags & AIR_SURFACE_ROOF) != 0) {
		return TransitionReason::ROOF_SURFACE;
	}
	if (s.normal.y < std::cos(p.max_slope_degrees * PI_F / 180.0f)) {
		return TransitionReason::SLOPE_TOO_STEEP;
	}
	if (!world.support->volume_clear(AirCylinder{add(P, mul(UP, b.step)), std::max(b.radius, b.wing_radius),
				b.height - b.step})) {
		return TransitionReason::BODY_BLOCKED;
	}
	const AirCylinder body_zone{P, 2.0f * b.radius + p.pad_margin, plan.volume.height};
	if (world.support->occupancy(body_zone, actor_.packed()) != 0) {
		return TransitionReason::OCCUPIED;
	}
	if (level == PadCheck::LIGHT) {
		return TransitionReason::NONE;
	}
	if (world.ground_traffic != nullptr &&
			air_traffic_conflict(*world.ground_traffic, plan.volume, p.traffic_horizon, actor_.packed())) {
		return TransitionReason::GROUND_TRAFFIC;
	}
	if (level == PadCheck::ENTRY) {
		return TransitionReason::NONE;
	}
	// Final approach sweep below the AirSpace cone: wings down to the flare, body to touchdown.
	if (!world.support->sweep_clear(plan.cut, plan.flare, b.wing_radius, b.centre_height) ||
			!world.support->sweep_clear(plan.flare, P, b.radius, b.centre_height)) {
		return TransitionReason::SWEEP_BLOCKED;
	}
	return TransitionReason::NONE;
}

bool AirJourney::pad_usable(size_t index, double now) const {
	return index < pad_states_.size() && pad_states_[index].blocked_until <= now;
}

void AirJourney::block_pad(TransitionWorld &world, size_t index, TransitionReason why, double now) {
	if (index >= pads_.size()) {
		return;
	}
	pad_states_[index].blocked_until = now + profile_.pad_retry;
	pad_states_[index].blocked_reason = why;
	emit(TransitionEventKind::PAD_REJECTED, why, now, pads_[index].pad.pad_id);
	if (int(index) == active_pad_) {
		if (landing_ticket_ != 0 && world.reservations != nullptr) {
			world.reservations->release(landing_ticket_, ReservationEnd::RELEASED, now);
		}
		landing_ticket_ = 0;
		pad_wait_since_ = -1.0;
	}
}

AirGoal AirJourney::landing_goal(double now) const {
	std::vector<AirGoalRegion> regions;
	for (size_t i = 0; i < pads_.size(); ++i) {
		if (!pad_usable(i, now)) {
			continue;
		}
		const Vec3 a = centre(pads_[i].entry);
		const float e = 0.05f;
		regions.push_back(AirGoalRegion{Aabb{Vec3{a.x - e, a.y - e, a.z - e}, Vec3{a.x + e, a.y + e, a.z + e}},
				uint32_t(i + 1)});
	}
	return AirGoal::landing(regions);
}

void AirJourney::request_landing_reservation(TransitionWorld &world, double now) {
	if (active_pad_ < 0) {
		return;
	}
	const ApproachPlan &plan = pads_[size_t(active_pad_)];
	ReservationRequest r;
	r.actor = actor_;
	r.kind = ReservationKind::LANDING;
	r.resource_id = plan.pad.pad_id;
	r.volume = plan.volume;
	r.priority = intent_.priority + profile_.priority;
	const ReservationState before = landing_ticket_ != 0 ? world.reservations->state(landing_ticket_) : ReservationState::NONE;
	landing_ticket_ = world.reservations->request(r, now);
	if (before != ReservationState::WAITING && before != ReservationState::GRANTED) {
		pad_wait_since_ = now;
	}
}

bool AirJourney::ticket_live(TransitionWorld &world, uint64_t ticket) const {
	if (ticket == 0) {
		return false;
	}
	const ReservationState s = world.reservations->state(ticket);
	return s == ReservationState::WAITING || s == ReservationState::GRANTED;
}

// ---- Routes ------------------------------------------------------------------------------------

void AirJourney::request_route(const Vec3 &from_centre, TransitionWorld &world, double now, bool retry) {
	if (route_ticket_ != 0) {
		world.planner->cancel(route_ticket_);
	}
	route_ticket_ = 0;
	route_retry_at_ = -1.0;
	route_ready_ = false;
	route_from_ = from_centre;
	if (!retry) {
		route_since_ = now;
	}
	AirGoal goal;
	if (intent_.terminal == JourneyTerminal::HOVER) {
		goal = AirGoal::point(centre(intent_.destination));
	} else {
		goal = landing_goal(now);
		if (goal.regions.empty()) {
			return; // no usable pad: the hold logic re-plans when one becomes usable
		}
	}
	route_ticket_ = world.planner->request(from_centre, goal);
}

bool AirJourney::route_pending() const {
	return route_ticket_ != 0 || route_retry_at_ >= 0.0;
}

bool AirJourney::poll_route(TransitionWorld &world, double now, TransitionReason &wait) {
	wait = TransitionReason::NONE;
	if (route_retry_at_ >= 0.0) {
		if (now < route_retry_at_) {
			wait = TransitionReason::ROUTE_WAITING_FOR_GEOMETRY;
			return false;
		}
		request_route(route_from_, world, now, true);
	}
	if (route_ticket_ == 0) {
		if (!route_ready_) {
			wait = TransitionReason::ROUTE_PENDING;
		}
		return false;
	}
	AirRoute route;
	const AirStatus status = world.planner->poll(route_ticket_, route);
	switch (status) {
		case AirStatus::PENDING:
			wait = TransitionReason::ROUTE_PENDING;
			return false;
		case AirStatus::COMPLETE: {
			route_ticket_ = 0;
			std::vector<Vec3> pts = route.points;
			Vec3 end_point;
			int pad = -1;
			if (intent_.terminal == JourneyTerminal::LAND) {
				pad = int(route.goal_id) - 1;
				if (pad < 0 || size_t(pad) >= pads_.size()) {
					fail(TransitionReason::ROUTE_FAILED, world, now);
					wait = TransitionReason::ROUTE_FAILED;
					return false;
				}
				end_point = centre(pads_[size_t(pad)].entry);
			} else {
				end_point = centre(intent_.destination);
			}
			if (pts.empty()) {
				pts.push_back(route_from_);
			}
			if (dist(pts.back(), end_point) > 1.0e-3f) {
				if (!air_segment_clear(*world.air, pts.back(), end_point, 0.0f)) {
					fail(TransitionReason::ROUTE_FAILED, world, now);
					wait = TransitionReason::ROUTE_FAILED;
					return false;
				}
				pts.push_back(end_point);
			}
			if (pts.size() == 1) {
				pts.push_back(pts[0]);
			}
			AirCorridor corridor;
			if (!air_make_corridor(*world.air, pts, std::vector<float>(), corridor)) {
				// The space changed since the search: plan again shortly.
				route_retry_at_ = now + profile_.route_retry;
				wait = TransitionReason::ROUTE_PENDING;
				return false;
			}
			corridor_ = corridor;
			corridor_index_ = 0;
			route_ready_ = true;
			if (pad >= 0) {
				if (pad != active_pad_ && landing_ticket_ != 0) {
					world.reservations->release(landing_ticket_, ReservationEnd::RELEASED, now);
					landing_ticket_ = 0;
					pad_wait_since_ = -1.0;
				}
				active_pad_ = pad;
				emit(TransitionEventKind::PAD_SELECTED, TransitionReason::NONE, now, pads_[size_t(pad)].pad.pad_id);
			}
			return true;
		}
		case AirStatus::WAITING_FOR_GEOMETRY:
			route_ticket_ = 0;
			wait = TransitionReason::ROUTE_WAITING_FOR_GEOMETRY;
			if (now - route_since_ > profile_.route_wait_limit) {
				fail(TransitionReason::ROUTE_WAITING_FOR_GEOMETRY, world, now);
			} else {
				route_retry_at_ = now + profile_.route_retry;
			}
			return false;
		case AirStatus::UNREACHABLE:
		case AirStatus::GOAL_BLOCKED:
			route_ticket_ = 0;
			wait = TransitionReason::ROUTE_UNREACHABLE;
			fail(wait, world, now);
			return false;
		case AirStatus::BUDGET_EXHAUSTED:
			route_ticket_ = 0;
			wait = TransitionReason::ROUTE_BUDGET_EXHAUSTED;
			fail(wait, world, now);
			return false;
		case AirStatus::START_BLOCKED:
			route_ticket_ = 0;
			wait = TransitionReason::ROUTE_START_BLOCKED;
			fail(wait, world, now);
			return false;
		default:
			route_ticket_ = 0;
			wait = TransitionReason::ROUTE_FAILED;
			fail(wait, world, now);
			return false;
	}
}

// ---- Holding, alternates, go-around ------------------------------------------------------------

void AirJourney::hold_at(const Vec3 &root, bool at_entry, TransitionReason reason, double now) {
	const bool changed = phase_ != AirPhase::HOLD || hold_braking_ || dist(hold_, root) > 1.0e-3f;
	phase_ = AirPhase::HOLD;
	hold_ = root;
	hold_braking_ = false;
	hold_at_entry_ = at_entry;
	hold_reason_ = reason;
	if (changed) {
		emit(TransitionEventKind::HOLDING, reason, now, active_pad());
	}
}

void AirJourney::enter_hold(const TransitionActorState &actor, TransitionWorld &world, TransitionReason reason,
		double now) {
	const float v = len(actor.velocity);
	const float stop = v * v / (2.0f * profile_.limits.max_brake) + 0.05f;
	const Vec3 c = centre(actor.root);
	std::vector<Vec3> candidates;
	if (route_ready_ && corridor_.points.size() >= 2) {
		const Projection pr = project_polyline(corridor_.points, corridor_index_, c, 4);
		candidates.push_back(point_along(corridor_.points, pr, stop, nullptr));
	}
	candidates.push_back(v > 1.0e-3f ? add(c, mul(actor.velocity, stop / v)) : c);
	for (const Vec3 &cand : candidates) {
		if (air_segment_clear(*world.air, c, cand, 0.0f) &&
				air_segment_clear(*world.air, cand, cand, profile_.hold_drift)) {
			hold_at(root_of(cand), false, reason, now);
			return;
		}
	}
	if (active_pad_ >= 0) {
		const ApproachPlan &plan = pads_[size_t(active_pad_)];
		if (dist(actor.root, plan.entry) <= std::max(profile_.waypoint_tolerance, stop + profile_.hold_drift)) {
			hold_at(plan.entry, true, reason, now);
			return;
		}
	}
	phase_ = AirPhase::HOLD;
	hold_ = actor.root;
	hold_braking_ = true;
	hold_at_entry_ = false;
	hold_reason_ = TransitionReason::NO_HOLDING_VOLUME;
	emit(TransitionEventKind::HOLDING, TransitionReason::NO_HOLDING_VOLUME, now, active_pad());
}

bool AirJourney::has_alternate(double now) const {
	for (size_t i = 0; i < pads_.size(); ++i) {
		if (int(i) != active_pad_ && pad_usable(i, now)) {
			return true;
		}
	}
	return false;
}

bool AirJourney::switch_pad(TransitionWorld &world, const TransitionActorState &actor, double now) {
	bool any = false;
	for (size_t i = 0; i < pads_.size(); ++i) {
		if (!pad_usable(i, now)) {
			continue;
		}
		const TransitionReason r = pad_live_check(pads_[i], world, PadCheck::LIGHT);
		if (r != TransitionReason::NONE) {
			block_pad(world, i, r, now);
			continue;
		}
		any = true;
	}
	if (!any) {
		if (landing_ticket_ != 0) {
			world.reservations->release(landing_ticket_, ReservationEnd::RELEASED, now);
			landing_ticket_ = 0;
		}
		active_pad_ = -1;
		route_ready_ = false;
		return false;
	}
	if (phase_ != AirPhase::HOLD) {
		enter_hold(actor, world, TransitionReason::ROUTE_PENDING, now);
	}
	route_ready_ = false;
	if (!hold_braking_ || len(actor.velocity) <= profile_.hover_speed) {
		request_route(centre(hold_braking_ ? actor.root : hold_), world, now, false);
	} // else step_hold re-plans once she has slowed
	return true;
}

void AirJourney::go_around(const TransitionActorState &actor, TransitionWorld &world, TransitionReason why,
		double now) {
	const ApproachPlan &plan = pads_[size_t(active_pad_)];
	detour_.clear();
	detour_.push_back(actor.root);
	if (actor.root.y < plan.cut.y - 0.05f) {
		detour_.push_back(plan.cut); // back up the swept flare path first
	}
	detour_.push_back(plan.entry); // then up the certified cone to A
	detour_index_ = 0;
	change_mode(JourneyMode::AIR, MotionOwner::AIR, why, now);
	emit(TransitionEventKind::GO_AROUND, why, now, plan.pad.pad_id);
	phase_ = AirPhase::GO_AROUND;
	hold_reason_ = why;
	if (is_pad_problem(why)) {
		block_pad(world, size_t(active_pad_), why, now);
	} else {
		if (landing_ticket_ != 0) {
			world.reservations->release(landing_ticket_, ReservationEnd::RELEASED, now);
		}
		landing_ticket_ = 0;
		pad_wait_since_ = -1.0;
	}
}

// ---- Commands ----------------------------------------------------------------------------------

void AirJourney::fill_path(CommandKind kind, const std::vector<Vec3> &path, float speed, float end_speed,
		const TransitionActorState &actor, float dt, TransitionCommand &out, float min_glide_ratio) const {
	out.valid = true;
	out.kind = kind;
	out.path = path;
	out.target = path.empty() ? actor.root : path.back();
	out.speed_limit = speed;
	out.end_speed = end_speed;
	out.velocity = air_transition_pursuit(actor.root, actor.velocity, path, speed, end_speed, profile_.limits, dt,
			min_glide_ratio);
}

void AirJourney::fill_hold(const TransitionActorState &actor, float dt, TransitionCommand &out) const {
	out.valid = true;
	out.reason = hold_reason_;
	if (hold_braking_) {
		out.kind = CommandKind::BRAKE;
		out.target = actor.root;
		out.path.clear();
		out.speed_limit = 0.0f;
		out.end_speed = 0.0f;
		out.velocity = move_toward(actor.velocity, Vec3{0, 0, 0}, profile_.limits.max_brake * std::max(0.0f, dt));
		return;
	}
	const std::vector<Vec3> path{hold_};
	fill_path(CommandKind::HOLD, path, std::min(profile_.approach_speed, profile_.limits.max_speed), 0.0f, actor, dt, out);
	out.reason = hold_reason_;
}

// ---- Public lifecycle --------------------------------------------------------------------------

TransitionReason AirJourney::begin(const JourneyIntent &intent, const TransitionActorState &actor,
		TransitionWorld &world, double now) {
	std::string error;
	TransitionReason r = TransitionReason::NONE;
	if (world.air == nullptr || world.support == nullptr || world.reservations == nullptr || world.planner == nullptr ||
			!finite_state(actor) || !finite3(intent.destination) || !std::isfinite(now) || !profile_.valid(error) ||
			!(intent.arrival_radius > 0.0f) || !(intent.arrival_height_tolerance >= 0.0f)) {
		r = TransitionReason::INVALID_INPUT;
	} else if (!air_link_allowed(profile_.capabilities, AirLinkKind::WING)) {
		r = TransitionReason::NO_WINGS; // earth ponies and unicorns never take wing links
	}
	const bool airborne = !actor.supported;
	std::vector<ApproachPlan> pads;
	if (r == TransitionReason::NONE) {
		if (intent.terminal == JourneyTerminal::HOVER) {
			bool unknown = false;
			if (!air_point_clear(*world.air, centre(intent.destination), &unknown)) {
				r = unknown ? TransitionReason::ROUTE_WAITING_FOR_GEOMETRY : TransitionReason::HOVER_POINT_BLOCKED;
			}
		} else {
			r = plan_pads(intent, actor.root, world, now, pads);
		}
	}
	Footprint fp;
	if (r == TransitionReason::NONE && !airborne) {
		r = select_footprint(intent, actor, world, fp);
	}
	if (r != TransitionReason::NONE) {
		emit(TransitionEventKind::REFUSED, r, now);
		return r;
	}
	const bool climbing = mode_ == JourneyMode::TAKEOFF && owner_ == MotionOwner::AIR && status_ == JourneyStatus::ACTIVE;
	// Re-targeted on the glide or in the flare: climb back out along the certified cone first
	// (near the pad she is inside the inflated ground, where no hold or route can start).
	std::vector<Vec3> climb_out;
	if (airborne && owner_ == MotionOwner::AIR && (mode_ == JourneyMode::APPROACH || mode_ == JourneyMode::LANDING) &&
			active_pad_ >= 0 && size_t(active_pad_) < pads_.size()) {
		const ApproachPlan &old = pads_[size_t(active_pad_)];
		climb_out.push_back(actor.root);
		if (actor.root.y < old.cut.y - 0.05f) {
			climb_out.push_back(old.cut);
		}
		climb_out.push_back(old.entry);
	}
	// Commit.
	release_own(world, ReservationEnd::RELEASED, now);
	intent_ = intent;
	has_intent_ = true;
	status_ = JourneyStatus::ACTIVE;
	failure_ = TransitionReason::NONE;
	pads_ = pads;
	pad_states_.assign(pads_.size(), PadState());
	active_pad_ = -1;
	route_ready_ = false;
	corridor_ = AirCorridor();
	corridor_index_ = 0;
	detour_.clear();
	detour_index_ = 0;
	hold_braking_ = false;
	hold_at_entry_ = false;
	hold_reason_ = TransitionReason::NONE;
	wait_since_ = -1.0;
	pad_wait_since_ = -1.0;
	pad_stall_ = 0.0;
	rejoin_pending_ = false;
	next_pad_check_ = now;
	landing_since_ = now;
	if (climbing) {
		// Finish the certified climb; the new route starts from the departure top.
		leg_ = GroundLeg::NONE;
		request_departure(world, now);
		request_route(centre(top_), world, now, false);
		return TransitionReason::NONE;
	}
	if (!airborne) {
		footprint_ = fp.root;
		entry_ = fp.entry;
		top_ = fp.top;
		footprint_surface_ = fp.surface_id;
		if (mode_ != JourneyMode::GROUND || owner_ != MotionOwner::GROUND) {
			change_mode(JourneyMode::GROUND, MotionOwner::GROUND, TransitionReason::NONE, now);
		}
		leg_ = GroundLeg::TO_TAKEOFF;
		phase_ = AirPhase::FOLLOW;
		request_departure(world, now);
		request_route(centre(top_), world, now, false);
		return TransitionReason::NONE;
	}
	if (mode_ != JourneyMode::AIR || owner_ != MotionOwner::AIR) {
		change_mode(JourneyMode::AIR, MotionOwner::AIR, TransitionReason::NONE, now);
	}
	leg_ = GroundLeg::NONE;
	phase_ = AirPhase::FOLLOW;
	if (!climb_out.empty()) {
		detour_ = climb_out;
		detour_index_ = 0;
		phase_ = AirPhase::GO_AROUND; // ends in a hold at the old approach entry, then plans
		hold_reason_ = TransitionReason::ROUTE_PENDING;
		emit(TransitionEventKind::GO_AROUND, TransitionReason::ROUTE_PENDING, now);
		return TransitionReason::NONE;
	}
	enter_hold(actor, world, TransitionReason::ROUTE_PENDING, now);
	if (!hold_braking_) {
		request_route(centre(hold_), world, now, false);
	} // braking: step_hold plans once she has slowed
	return TransitionReason::NONE;
}

void AirJourney::cancel(const TransitionActorState &actor, TransitionWorld &world, double now) {
	release_own(world, ReservationEnd::CANCELLED, now);
	if (status_ == JourneyStatus::ACTIVE) {
		status_ = JourneyStatus::CANCELLED;
		failure_ = TransitionReason::CANCELLED;
		emit(TransitionEventKind::CANCELLED, TransitionReason::CANCELLED, now, active_pad());
	}
	detour_.clear();
	if (owner_ == MotionOwner::AIR) {
		if (mode_ != JourneyMode::AIR) {
			change_mode(JourneyMode::AIR, MotionOwner::AIR, TransitionReason::CANCELLED, now);
		}
		route_ready_ = false;
		active_pad_ = -1;
		if (world.air != nullptr && finite_state(actor)) {
			enter_hold(actor, world, TransitionReason::CANCELLED, now); // airborne: hold, never drop
		} else {
			phase_ = AirPhase::HOLD;
			hold_braking_ = true;
		}
	} else {
		leg_ = GroundLeg::NONE;
	}
}

void AirJourney::interrupt(TransitionWorld &world, double now) {
	release_own(world, ReservationEnd::INTERRUPTED, now);
	detour_.clear();
	if (owner_ != MotionOwner::EXTERNAL && owner_ != MotionOwner::NONE) {
		change_mode(mode_, MotionOwner::EXTERNAL, TransitionReason::INTERRUPTED, now);
	}
}

TransitionReason AirJourney::resume(const TransitionActorState &actor, TransitionWorld &world, double now) {
	if (owner_ != MotionOwner::EXTERNAL) {
		return TransitionReason::NONE;
	}
	if (has_intent_ && status_ == JourneyStatus::ACTIVE) {
		const TransitionReason r = begin(intent_, actor, world, now);
		if (r == TransitionReason::NONE) {
			return r;
		}
		// Refused now: ownership still has to come back to a safe owner.
		if (actor.supported) {
			change_mode(JourneyMode::GROUND, MotionOwner::GROUND, r, now);
			leg_ = GroundLeg::NONE;
		} else {
			change_mode(JourneyMode::AIR, MotionOwner::AIR, r, now);
			route_ready_ = false;
			active_pad_ = -1;
			enter_hold(actor, world, r, now);
		}
		fail(r, world, now);
		return r;
	}
	if (actor.supported) {
		change_mode(JourneyMode::GROUND, MotionOwner::GROUND, TransitionReason::NONE, now);
		leg_ = GroundLeg::NONE;
	} else {
		change_mode(JourneyMode::AIR, MotionOwner::AIR, TransitionReason::NONE, now);
		route_ready_ = false;
		active_pad_ = -1;
		enter_hold(actor, world, TransitionReason::INTERRUPTED, now);
	}
	return TransitionReason::NONE;
}

void AirJourney::despawn(TransitionWorld &world, double now) {
	release_own(world, ReservationEnd::DESPAWNED, now);
	if (status_ == JourneyStatus::ACTIVE) {
		status_ = JourneyStatus::CANCELLED;
		failure_ = TransitionReason::DESPAWNED;
	}
	emit(TransitionEventKind::CANCELLED, TransitionReason::DESPAWNED, now, active_pad());
	detour_.clear();
	if (owner_ != MotionOwner::NONE) {
		change_mode(mode_, MotionOwner::NONE, TransitionReason::DESPAWNED, now);
	}
}

TransitionReason AirJourney::request_manoeuvre(const ManoeuvreRequest &request, const TransitionActorState &actor,
		TransitionWorld &world, double now) {
	TransitionReason r = TransitionReason::NONE;
	const bool hovering = status_ == JourneyStatus::ARRIVED && phase_ == AirPhase::HOVER;
	const bool following = status_ == JourneyStatus::ACTIVE && phase_ == AirPhase::FOLLOW && route_ready_;
	if (world.air == nullptr || !finite_state(actor) || !(request.radius > 0.0f) || !(request.speed > 0.0f) ||
			request.chords < 4 || !(request.margin >= 0.0f)) {
		r = TransitionReason::INVALID_INPUT;
	} else if (!air_link_allowed(profile_.capabilities, AirLinkKind::WING)) {
		r = TransitionReason::NO_WINGS;
	} else if (!has_intent_ || intent_.purpose != JourneyPurpose::LEISURE) {
		r = TransitionReason::MANOEUVRE_NOT_ALLOWED; // never inserted into commanded travel
	} else if (owner_ != MotionOwner::AIR || mode_ != JourneyMode::AIR || !(hovering || following)) {
		r = TransitionReason::MANOEUVRE_BUSY;
	}
	if (r == TransitionReason::NONE) {
		Vec3 forward{actor.velocity.x, 0.0f, actor.velocity.z};
		if (len(forward) < 0.3f) {
			forward = Vec3{-std::sin(actor.yaw), 0.0f, -std::cos(actor.yaw)};
		}
		forward = mul(forward, 1.0f / len(forward));
		const Vec3 side{-forward.z, 0.0f, forward.x};
		const Vec3 bend = request.kind == ManoeuvreKind::LOOP ? UP : side;
		const float R = request.radius;
		const uint32_t n = request.chords;
		// Chord-to-arc distance of an n-gon inscribed in the circle, plus the requested slack.
		const float sag = R * (1.0f - std::cos(PI_F / float(n))) + request.margin;
		std::vector<Vec3> pts;
		pts.push_back(actor.root);
		for (uint32_t k = 1; k <= n; ++k) {
			const float a = 2.0f * PI_F * float(k) / float(n);
			pts.push_back(add(actor.root, add(mul(forward, R * std::sin(a)), mul(bend, R * (1.0f - std::cos(a))))));
		}
		pts.back() = actor.root;
		for (size_t i = 0; i + 1 < pts.size(); ++i) {
			if (!air_segment_clear(*world.air, centre(pts[i]), centre(pts[i + 1]), sag)) {
				r = TransitionReason::MANOEUVRE_VOLUME_BLOCKED;
				break;
			}
		}
		if (r == TransitionReason::NONE) {
			detour_ = pts;
			detour_index_ = 0;
			manoeuvre_speed_ = std::min(request.speed, profile_.limits.max_speed);
			phase_ = AirPhase::MANOEUVRE;
			emit(TransitionEventKind::MANOEUVRE_STARTED, TransitionReason::NONE, now);
			return r;
		}
	}
	emit(TransitionEventKind::REFUSED, r, now);
	return r;
}

// ---- Stepping ----------------------------------------------------------------------------------

void AirJourney::step(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
		TransitionCommand &out) {
	out = TransitionCommand();
	if (owner_ == MotionOwner::EXTERNAL || owner_ == MotionOwner::NONE) {
		out.mode = mode_;
		out.owner = owner_;
		out.ownership_epoch = epoch_;
		return; // another owner (or nobody) writes the body
	}
	if (!finite_state(actor) || !(dt > 0.0f) || !std::isfinite(now) || world.air == nullptr ||
			world.support == nullptr || world.reservations == nullptr || world.planner == nullptr) {
		out.valid = true;
		out.kind = owner_ == MotionOwner::AIR ? CommandKind::BRAKE : CommandKind::IDLE;
		out.reason = TransitionReason::INVALID_INPUT;
		out.target = finite3(actor.root) ? actor.root : Vec3{0, 0, 0};
	} else {
		if (departure_ticket_ != 0) {
			world.reservations->renew(departure_ticket_, now);
		}
		if (landing_ticket_ != 0) {
			world.reservations->renew(landing_ticket_, now);
		}
		if (status_ != JourneyStatus::ACTIVE) {
			if (owner_ == MotionOwner::GROUND) {
				out.valid = true;
				out.kind = CommandKind::IDLE;
				out.target = actor.root;
				out.reason = failure_;
			} else if (phase_ == AirPhase::MANOEUVRE) {
				step_detour(actor, world, now, dt, out);
			} else if (status_ == JourneyStatus::ARRIVED) {
				const std::vector<Vec3> path{intent_.destination};
				fill_path(CommandKind::HOVER, path, profile_.approach_speed, 0.0f, actor, dt, out);
			} else {
				fill_hold(actor, dt, out);
			}
		} else {
			switch (mode_) {
				case JourneyMode::GROUND: step_ground(actor, world, now, dt, out); break;
				case JourneyMode::TAKEOFF: step_takeoff(actor, world, now, dt, out); break;
				case JourneyMode::AIR: step_air(actor, world, now, dt, out); break;
				case JourneyMode::APPROACH: step_approach(actor, world, now, dt, out); break;
				case JourneyMode::LANDING: step_landing(actor, world, now, dt, out); break;
			}
		}
	}
	out.mode = mode_;
	out.owner = owner_;
	out.ownership_epoch = epoch_;
	out.floor_snap = owner_ == MotionOwner::GROUND;
	out.pad_id = active_pad();
	if (owner_ != MotionOwner::AIR) {
		out.velocity = Vec3{0, 0, 0}; // ground owner: the ground navigator drives the walk
	}
}

void AirJourney::step_ground(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
		TransitionCommand &out) {
	out.valid = true;
	if (leg_ == GroundLeg::CONTINUATION) {
		const Vec3 &d = intent_.destination;
		const bool surface_ok = intent_.required_surface_id == 0 || actor.support_surface_id == intent_.required_surface_id;
		if (actor.supported && surface_ok && len_xz(sub(actor.root, d)) <= intent_.arrival_radius &&
				std::fabs(actor.root.y - d.y) <= intent_.arrival_height_tolerance) {
			leg_ = GroundLeg::NONE;
			status_ = JourneyStatus::ARRIVED;
			emit(TransitionEventKind::ARRIVED, TransitionReason::NONE, now);
			out.kind = CommandKind::IDLE;
			out.target = actor.root;
			return;
		}
		out.kind = CommandKind::WALK;
		out.target = d;
		out.path = std::vector<Vec3>{d};
		return;
	}
	if (leg_ != GroundLeg::TO_TAKEOFF) {
		out.kind = CommandKind::IDLE;
		out.target = actor.root;
		return;
	}
	TransitionReason route_wait = TransitionReason::NONE;
	poll_route(world, now, route_wait);
	if (status_ != JourneyStatus::ACTIVE) {
		out.kind = CommandKind::IDLE;
		out.target = actor.root;
		out.reason = failure_;
		return;
	}
	if (!ticket_live(world, departure_ticket_)) {
		request_departure(world, now); // a lease or limit ended it: queue again
	}
	const bool on_footprint = actor.supported && len_xz(sub(actor.root, footprint_)) <= profile_.footprint_tolerance &&
			std::fabs(actor.root.y - footprint_.y) <= profile_.pad_height_tolerance + 0.12f &&
			(footprint_surface_ == 0 || actor.support_surface_id == footprint_surface_);
	if (!on_footprint) {
		wait_since_ = -1.0;
		out.kind = CommandKind::WALK;
		out.target = footprint_;
		out.path = std::vector<Vec3>{footprint_};
		return;
	}
	if (wait_since_ < 0.0) {
		wait_since_ = now;
	}
	TransitionReason wait = TransitionReason::NONE;
	if (!route_ready_) {
		wait = route_wait != TransitionReason::NONE ? route_wait : TransitionReason::ROUTE_PENDING;
	} else {
		const AirCorridorState cs = air_check_corridor(*world.air, corridor_);
		if (cs == AirCorridorState::BLOCKED || cs == AirCorridorState::MISSING_DATA) {
			wait = cs == AirCorridorState::BLOCKED ? TransitionReason::CORRIDOR_BLOCKED
												   : TransitionReason::CORRIDOR_MISSING_DATA;
			request_route(centre(top_), world, now, false);
		} else if (!world.reservations->held(departure_ticket_)) {
			wait = TransitionReason::DEPARTURE_RESERVATION_WAIT;
		} else {
			wait = departure_live_check(world);
		}
	}
	if (wait != TransitionReason::NONE) {
		if (now - wait_since_ > profile_.takeoff_wait_limit) {
			fail(wait, world, now);
		}
		out.kind = CommandKind::IDLE;
		out.target = footprint_;
		out.reason = wait;
		return;
	}
	// GROUND -> TAKEOFF: the one ownership change of departure (floor snap off).
	wait_since_ = -1.0;
	leg_ = GroundLeg::NONE;
	change_mode(JourneyMode::TAKEOFF, MotionOwner::AIR, TransitionReason::NONE, now);
	step_takeoff(actor, world, now, dt, out);
}

void AirJourney::step_takeoff(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
		TransitionCommand &out) {
	TransitionReason route_wait = TransitionReason::NONE;
	poll_route(world, now, route_wait);
	if (status_ != JourneyStatus::ACTIVE) {
		fill_hold(actor, dt, out);
		return;
	}
	if (!air_segment_clear(*world.air, centre(entry_), centre(top_), 0.0f)) {
		// Something entered the certified column: stop climbing (never descend), bounded wait.
		if (wait_since_ < 0.0) {
			wait_since_ = now;
		}
		hold_braking_ = true;
		hold_reason_ = TransitionReason::TAKEOFF_VOLUME_BLOCKED;
		if (now - wait_since_ > profile_.takeoff_wait_limit) {
			phase_ = AirPhase::HOLD;
			fail(TransitionReason::TAKEOFF_VOLUME_BLOCKED, world, now);
		}
		fill_hold(actor, dt, out);
		return;
	}
	wait_since_ = -1.0;
	hold_braking_ = false;
	if (dist(actor.root, top_) <= profile_.waypoint_tolerance) {
		if (departure_ticket_ != 0) {
			world.reservations->release(departure_ticket_, ReservationEnd::RELEASED, now);
			departure_ticket_ = 0;
		}
		// TAKEOFF -> AIR: no ownership change.
		if (!route_ready_) {
			change_mode(JourneyMode::AIR, MotionOwner::AIR, route_wait, now);
			hold_at(top_, false, route_wait != TransitionReason::NONE ? route_wait : TransitionReason::ROUTE_PENDING, now);
			fill_hold(actor, dt, out);
			return;
		}
		const AirCorridorState cs = air_check_corridor(*world.air, corridor_);
		change_mode(JourneyMode::AIR, MotionOwner::AIR, TransitionReason::NONE, now);
		if (cs == AirCorridorState::BLOCKED || cs == AirCorridorState::MISSING_DATA) {
			const TransitionReason why = cs == AirCorridorState::BLOCKED ? TransitionReason::CORRIDOR_BLOCKED
																	 : TransitionReason::CORRIDOR_MISSING_DATA;
			hold_at(top_, false, why, now);
			request_route(centre(top_), world, now, false);
			fill_hold(actor, dt, out);
			return;
		}
		phase_ = AirPhase::FOLLOW;
		corridor_index_ = 0;
		step_air(actor, world, now, dt, out);
		return;
	}
	const bool low = actor.root.y < entry_.y - 0.05f;
	std::vector<Vec3> path;
	if (low) {
		path.push_back(entry_);
	}
	path.push_back(top_);
	fill_path(CommandKind::CLIMB, path, low ? profile_.takeoff_speed_low : profile_.takeoff_speed_high, 0.0f, actor, dt,
			out);
}

void AirJourney::step_air(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
		TransitionCommand &out) {
	TransitionReason route_wait = TransitionReason::NONE;
	const bool fresh = poll_route(world, now, route_wait);
	if (status_ != JourneyStatus::ACTIVE) {
		fill_hold(actor, dt, out);
		return;
	}
	if (fresh && phase_ == AirPhase::HOLD) {
		rejoin_pending_ = true; // joined in step_hold once she is inside the hold sphere at its start
	}
	if (phase_ == AirPhase::GO_AROUND || phase_ == AirPhase::MANOEUVRE) {
		step_detour(actor, world, now, dt, out);
		return;
	}
	if (phase_ == AirPhase::HOLD) {
		step_hold(actor, world, now, dt, out, route_wait);
		return;
	}
	if (!route_ready_) {
		enter_hold(actor, world, route_wait != TransitionReason::NONE ? route_wait : TransitionReason::ROUTE_PENDING, now);
		fill_hold(actor, dt, out);
		return;
	}
	const AirCorridorState cs = air_check_corridor(*world.air, corridor_);
	if (cs == AirCorridorState::BLOCKED || cs == AirCorridorState::MISSING_DATA) {
		const TransitionReason why = cs == AirCorridorState::BLOCKED ? TransitionReason::CORRIDOR_BLOCKED
																 : TransitionReason::CORRIDOR_MISSING_DATA;
		enter_hold(actor, world, why, now); // stops along the still-certified part of the corridor
		route_ready_ = false;
		if (!hold_braking_) {
			request_route(centre(hold_), world, now, false);
		} // braking without a certified hold: step_hold plans from where she stops
		fill_hold(actor, dt, out);
		return;
	}
	const Vec3 c = centre(actor.root);
	const Projection pr = project_polyline(corridor_.points, corridor_index_, c, 4);
	corridor_index_ = pr.index;
	std::vector<Vec3> path = path_from(corridor_.points, pr);
	for (Vec3 &p : path) {
		p = root_of(p);
	}
	if (intent_.terminal == JourneyTerminal::HOVER) {
		if (dist(actor.root, intent_.destination) <= intent_.arrival_radius && len(actor.velocity) <= profile_.hover_speed) {
			status_ = JourneyStatus::ARRIVED;
			phase_ = AirPhase::HOVER;
			emit(TransitionEventKind::ARRIVED, TransitionReason::NONE, now);
			const std::vector<Vec3> at{intent_.destination};
			fill_path(CommandKind::HOVER, at, profile_.approach_speed, 0.0f, actor, dt, out);
			return;
		}
		fill_path(CommandKind::FLY, path, profile_.limits.max_speed, 0.0f, actor, dt, out);
		return;
	}
	if (active_pad_ < 0) {
		enter_hold(actor, world, TransitionReason::ALL_PADS_BLOCKED, now);
		fill_hold(actor, dt, out);
		return;
	}
	const ApproachPlan &plan = pads_[size_t(active_pad_)];
	if (pr.remaining + pr.offset <= profile_.reserve_ahead_distance) {
		if (!ticket_live(world, landing_ticket_)) {
			request_landing_reservation(world, now);
		}
		if (now >= next_pad_check_) {
			next_pad_check_ = now + profile_.pad_recheck;
			const TransitionReason r = pad_live_check(plan, world, PadCheck::LIGHT);
			if (r != TransitionReason::NONE) {
				block_pad(world, size_t(active_pad_), r, now);
				enter_hold(actor, world, r, now);
				if (!switch_pad(world, actor, now)) {
					hold_reason_ = TransitionReason::ALL_PADS_BLOCKED;
				}
				fill_hold(actor, dt, out);
				return;
			}
		}
	}
	const bool held = world.reservations->held(landing_ticket_);
	if (dist(c, centre(plan.entry)) <= profile_.waypoint_tolerance) {
		if (held) {
			const TransitionReason r = pad_live_check(plan, world, PadCheck::ENTRY);
			if (r == TransitionReason::NONE) {
				// AIR -> APPROACH: no ownership change.
				change_mode(JourneyMode::APPROACH, MotionOwner::AIR, TransitionReason::NONE, now);
				pad_stall_ = 0.0;
				next_pad_check_ = now + profile_.pad_recheck;
				step_approach(actor, world, now, dt, out);
				return;
			}
			block_pad(world, size_t(active_pad_), r, now);
			hold_at(plan.entry, true, r, now);
			if (!switch_pad(world, actor, now)) {
				hold_reason_ = TransitionReason::ALL_PADS_BLOCKED;
			}
			fill_hold(actor, dt, out);
			return;
		}
		hold_at(plan.entry, true, TransitionReason::PAD_RESERVATION_WAIT, now);
		fill_hold(actor, dt, out);
		return;
	}
	fill_path(CommandKind::FLY, path, profile_.limits.max_speed, held ? profile_.approach_speed : 0.0f, actor, dt, out);
}

void AirJourney::step_hold(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
		TransitionCommand &out, TransitionReason route_wait) {
	if (route_pending()) {
		if (route_wait != TransitionReason::NONE && hold_reason_ != route_wait && !hold_at_entry_) {
			hold_reason_ = route_wait;
		}
		fill_hold(actor, dt, out);
		return;
	}
	const Vec3 c = centre(actor.root);
	// A braking hold has no certified point: plan only once she has slowed, from where she is.
	const bool can_plan = !hold_braking_ || len(actor.velocity) <= profile_.hover_speed;
	if (rejoin_pending_ && route_ready_) {
		// Join a fresh route only from inside the certified hold sphere at its start.
		if (dist(c, corridor_.points.front()) <= std::max(profile_.waypoint_tolerance, profile_.hold_drift)) {
			rejoin_pending_ = false;
			phase_ = AirPhase::FOLLOW;
			hold_braking_ = false;
			hold_at_entry_ = false;
			step_air(actor, world, now, dt, out);
			return;
		}
		if (hold_braking_ && can_plan) {
			rejoin_pending_ = false;
			request_route(c, world, now, false); // she stopped somewhere else: plan from here
		}
		fill_hold(actor, dt, out);
		return;
	}
	rejoin_pending_ = false;
	if (intent_.terminal == JourneyTerminal::HOVER) {
		if (!route_ready_ && can_plan) {
			request_route(hold_braking_ ? c : centre(hold_), world, now, false);
		}
		fill_hold(actor, dt, out);
		return;
	}
	// Holding because of the pad (reservation, occupancy, all pads blocked): bounded.
	pad_stall_ += double(dt);
	bool replan = false;
	if (route_ready_ && active_pad_ >= 0 && pad_usable(size_t(active_pad_), now)) {
		const ApproachPlan &plan = pads_[size_t(active_pad_)];
		if (!hold_at_entry_) {
			hold_at(plan.entry, true, hold_reason_, now); // the route's end is A
		}
		if (!ticket_live(world, landing_ticket_)) {
			request_landing_reservation(world, now);
		}
		TransitionReason r = TransitionReason::NONE;
		if (now >= next_pad_check_) {
			next_pad_check_ = now + profile_.pad_recheck;
			r = pad_live_check(plan, world, PadCheck::ENTRY);
		}
		if (r != TransitionReason::NONE) {
			block_pad(world, size_t(active_pad_), r, now);
			replan = true;
		} else if (world.reservations->held(landing_ticket_)) {
			if (dist(actor.root, plan.entry) <= profile_.waypoint_tolerance) {
				phase_ = AirPhase::FOLLOW;
				change_mode(JourneyMode::APPROACH, MotionOwner::AIR, TransitionReason::NONE, now);
				pad_stall_ = 0.0;
				next_pad_check_ = now + profile_.pad_recheck;
				step_approach(actor, world, now, dt, out);
				return;
			}
			hold_reason_ = TransitionReason::NONE;
		} else {
			hold_reason_ = TransitionReason::PAD_RESERVATION_WAIT;
			if (pad_wait_since_ >= 0.0 && now - pad_wait_since_ > profile_.pad_wait_limit && has_alternate(now)) {
				block_pad(world, size_t(active_pad_), TransitionReason::PAD_RESERVATION_WAIT, now);
				replan = true;
			} else if (pad_stall_ > profile_.hold_limit) {
				fail(TransitionReason::WAIT_TIMEOUT, world, now);
			}
		}
	} else {
		replan = now >= next_pad_check_;
		if (replan) {
			next_pad_check_ = now + profile_.pad_recheck;
		}
	}
	if (replan && status_ == JourneyStatus::ACTIVE && can_plan) {
		if (switch_pad(world, actor, now)) {
			fill_hold(actor, dt, out);
			return;
		}
		hold_reason_ = TransitionReason::ALL_PADS_BLOCKED;
	}
	if (status_ == JourneyStatus::ACTIVE && active_pad_ < 0 && pad_stall_ > profile_.hold_limit) {
		fail(TransitionReason::ALL_PADS_BLOCKED, world, now); // exposed: she keeps holding, no descent
	}
	fill_hold(actor, dt, out);
}

void AirJourney::step_detour(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
		TransitionCommand &out) {
	if (detour_.size() < 2) {
		phase_ = status_ == JourneyStatus::ARRIVED ? AirPhase::HOVER : AirPhase::FOLLOW;
		fill_hold(actor, dt, out);
		return;
	}
	const Projection pr = project_polyline(detour_, detour_index_, actor.root, 2);
	detour_index_ = pr.index;
	const bool last = size_t(detour_index_) + 2 >= detour_.size();
	if (last && dist(actor.root, detour_.back()) <= profile_.waypoint_tolerance) {
		if (phase_ == AirPhase::GO_AROUND) {
			detour_.clear();
			if (active_pad_ >= 0 && is_pad_problem(hold_reason_)) {
				// The pad's retry delay counts from the end of the go-around, so the alternate is
				// tried first instead of flying straight back into the same problem.
				pad_states_[size_t(active_pad_)].blocked_until = now + profile_.pad_retry;
			}
			if (active_pad_ >= 0) {
				hold_at(pads_[size_t(active_pad_)].entry, true, hold_reason_, now);
			} else {
				enter_hold(actor, world, hold_reason_, now);
			}
			fill_hold(actor, dt, out);
			return;
		}
		detour_.clear();
		emit(TransitionEventKind::MANOEUVRE_DONE, TransitionReason::NONE, now);
		if (status_ == JourneyStatus::ARRIVED) {
			phase_ = AirPhase::HOVER;
			const std::vector<Vec3> at{intent_.destination};
			fill_path(CommandKind::HOVER, at, profile_.approach_speed, 0.0f, actor, dt, out);
			return;
		}
		phase_ = AirPhase::FOLLOW;
		step_air(actor, world, now, dt, out);
		return;
	}
	const bool around = phase_ == AirPhase::GO_AROUND;
	fill_path(CommandKind::FLY, path_from(detour_, pr), around ? profile_.approach_speed : manoeuvre_speed_,
			around ? 0.0f : manoeuvre_speed_, actor, dt, out);
	out.reason = around ? hold_reason_ : TransitionReason::NONE;
}

void AirJourney::step_approach(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
		TransitionCommand &out) {
	ApproachPlan &plan = pads_[size_t(active_pad_)];
	TransitionReason why = TransitionReason::NONE;
	if (!world.reservations->held(landing_ticket_)) {
		why = TransitionReason::PAD_RESERVATION_LOST;
	} else {
		const AirCorridorState cs = air_check_corridor(*world.air, plan.cone);
		if (cs == AirCorridorState::BLOCKED || cs == AirCorridorState::MISSING_DATA) {
			why = TransitionReason::APPROACH_VOLUME_BLOCKED;
		} else if (now >= next_pad_check_) {
			next_pad_check_ = now + profile_.pad_recheck;
			why = pad_live_check(plan, world, PadCheck::LIGHT);
		}
	}
	if (why == TransitionReason::NONE && dist(actor.root, plan.cut) <= profile_.waypoint_tolerance) {
		// Live landing certification right before the flare: support, slope, surface id, body
		// clearance, occupancy, ground traffic, final approach sweep, reservation (held above).
		why = pad_live_check(plan, world, PadCheck::FULL);
		if (why == TransitionReason::NONE) {
			// APPROACH -> LANDING: no ownership change.
			change_mode(JourneyMode::LANDING, MotionOwner::AIR, TransitionReason::NONE, now);
			landing_since_ = now;
			step_landing(actor, world, now, dt, out);
			return;
		}
	}
	if (why != TransitionReason::NONE) {
		go_around(actor, world, why, now);
		step_detour(actor, world, now, dt, out);
		return;
	}
	const std::vector<Vec3> line{plan.entry, plan.cut};
	const Projection pr = project_polyline(line, 0, actor.root, 1);
	fill_path(CommandKind::GLIDE, path_from(line, pr), profile_.approach_speed, profile_.flare_speed, actor, dt, out,
			profile_.min_glide_ratio);
}

void AirJourney::step_landing(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
		TransitionCommand &out) {
	const ApproachPlan &plan = pads_[size_t(active_pad_)];
	const Vec3 P = plan.pad.point;
	const TransitionReason landed = air_landed_check(actor, P, plan.pad.surface_id, profile_.footprint_tolerance,
			profile_.pad_height_tolerance, profile_.touchdown_speed);
	if (landed == TransitionReason::NONE) {
		if (landing_ticket_ != 0) {
			world.reservations->release(landing_ticket_, ReservationEnd::RELEASED, now);
			landing_ticket_ = 0;
		}
		// LANDING -> GROUND: the one ownership change of arrival (floor snap back on, now).
		change_mode(JourneyMode::GROUND, MotionOwner::GROUND, TransitionReason::NONE, now);
		pad_stall_ = 0.0;
		phase_ = AirPhase::FOLLOW;
		if (intent_.walk_after_landing && len_xz(sub(intent_.destination, P)) > intent_.arrival_radius) {
			leg_ = GroundLeg::CONTINUATION;
			step_ground(actor, world, now, dt, out);
			return;
		}
		leg_ = GroundLeg::NONE;
		status_ = JourneyStatus::ARRIVED;
		emit(TransitionEventKind::ARRIVED, TransitionReason::NONE, now, plan.pad.pad_id);
		out.valid = true;
		out.kind = CommandKind::IDLE;
		out.target = actor.root;
		return;
	}
	if (actor.supported && (landed == TransitionReason::SURFACE_MISMATCH || landed == TransitionReason::WRONG_HEIGHT ||
								   landed == TransitionReason::OFF_PAD)) {
		// Physically supported somewhere that is not the certified pad: ground owns the body,
		// and this is not an arrival.
		change_mode(JourneyMode::GROUND, MotionOwner::GROUND, landed, now);
		leg_ = GroundLeg::NONE;
		fail(landed, world, now);
		out.valid = true;
		out.kind = CommandKind::IDLE;
		out.target = actor.root;
		out.reason = landed;
		return;
	}
	TransitionReason why = TransitionReason::NONE;
	if (!world.reservations->held(landing_ticket_)) {
		why = TransitionReason::PAD_RESERVATION_LOST;
	} else if (world.ground_traffic != nullptr &&
			air_traffic_conflict(*world.ground_traffic, plan.volume, profile_.traffic_horizon, actor_.packed())) {
		why = TransitionReason::GROUND_TRAFFIC;
	} else if (now - landing_since_ > profile_.landing_time_limit) {
		why = TransitionReason::LANDING_TIMEOUT;
	} else if (now >= next_pad_check_) {
		next_pad_check_ = now + profile_.pad_recheck;
		why = pad_live_check(plan, world, PadCheck::LIGHT);
	}
	if (why != TransitionReason::NONE) {
		go_around(actor, world, why, now);
		step_detour(actor, world, now, dt, out);
		return;
	}
	const std::vector<Vec3> line{plan.cut, plan.flare, P};
	const Projection pr = project_polyline(line, 0, actor.root, 2);
	fill_path(CommandKind::FLARE, path_from(line, pr), profile_.flare_speed, 0.0f, actor, dt, out,
			profile_.min_flare_ratio);
	out.reason = landed; // NOT_SUPPORTED while still above the pad: hovering is not landed
}

} // namespace nav_air
