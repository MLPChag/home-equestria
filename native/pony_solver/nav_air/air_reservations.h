// Takeoff/landing reservations shared by every flyer (navigation overhaul phase 5, AIR_TRANSITIONS
// slice; docs/NAVIGATION_AIR_TRANSITIONS_2026_10_02.md). Plain C++17, no Godot types, no threads.
//
// A reservation is a vertical cylinder (a departure column, a landing pad with its flare, a
// doorway) requested by one actor. Two reservations of different actors conflict when their
// cylinders overlap with positive volume; reservations of the same actor never conflict.
//
// Grants happen only in update(now), never inside request(), so the order in which actors are
// stepped within a tick cannot change who wins. update() ranks waiting requests by
//     rank = priority + aging_per_second * waited_seconds
// then by earlier request time, then by actor (slot, generation), then by ticket. Walking that
// order, a request is granted when it conflicts with no granted reservation and with no request
// ranked above it that is still waiting (no barging: a long-waiting request cannot be starved by
// a stream of later ones that fit around it). A granted reservation is never pre-empted by a
// later, higher-priority request (stable priority).
//
// Timeouts: every live ticket holds a lease. The owner renews it each tick it still wants it
// (waiting or holding); a ticket not renewed within `lease` seconds ends as LEASE_EXPIRED, so a
// despawned or stuck actor cannot keep a pad forever. Optional per-request limits end a wait
// (WAIT_LIMIT) or a grant (HOLD_LIMIT). release_actor() ends everything an actor owns (cancel,
// despawn). Ended tickets remain queryable for `ended_retention` seconds, then state() is NONE.
//
// Time is the caller's simulation clock in seconds (deterministic; no wall clock).
#pragma once

#include "air_space.h"

#include <cstdint>
#include <map>
#include <vector>

namespace nav_air {

// Stable actor identity (the same slot/generation pair as ponynav::ActorHandle).
struct AirActorKey {
	uint32_t slot = 0;
	uint32_t generation = 0;
	uint64_t packed() const { return (uint64_t(slot) << 32) | uint64_t(generation); }
};
inline bool operator==(const AirActorKey &a, const AirActorKey &b) {
	return a.slot == b.slot && a.generation == b.generation;
}
inline bool operator!=(const AirActorKey &a, const AirActorKey &b) { return !(a == b); }

// Vertical cylinder: `base` is the centre of its bottom disc, Y up.
struct AirCylinder {
	Vec3 base{0, 0, 0};
	float radius = 0.0f;
	float height = 0.0f;
};

// Positive-volume overlap of two vertical cylinders.
bool air_cylinders_overlap(const AirCylinder &a, const AirCylinder &b);

enum class ReservationKind : uint8_t {
	DEPARTURE = 0, // takeoff column above a footprint
	LANDING = 1, // landing pad with its flare
	PASSAGE = 2, // doorway or other shared passage (ground adapters may use it)
};

enum class ReservationState : uint8_t {
	NONE = 0, // unknown ticket, or ended longer than ended_retention ago
	WAITING = 1,
	GRANTED = 2,
	ENDED = 3, // see end_reason()
};

enum class ReservationEnd : uint8_t {
	NONE = 0,
	RELEASED = 1, // owner released it (normal use)
	CANCELLED = 2, // owner's intent was cancelled
	DESPAWNED = 3, // owner left the world
	LEASE_EXPIRED = 4, // not renewed within the lease
	WAIT_LIMIT = 5, // waited longer than its max_wait
	HOLD_LIMIT = 6, // held longer than its max_hold
	INTERRUPTED = 7, // owner was grabbed, thrown or otherwise taken over
};

const char *reservation_state_name(ReservationState state);
const char *reservation_end_name(ReservationEnd end);

struct ReservationRequest {
	AirActorKey actor;
	ReservationKind kind = ReservationKind::LANDING;
	uint32_t resource_id = 0; // pad / footprint id (informational; conflicts are geometric)
	AirCylinder volume;
	int32_t priority = 0; // higher wins among waiters
	double max_wait = 0.0; // seconds; 0 = no limit (the lease still applies)
	double max_hold = 0.0; // seconds after the grant; 0 = no limit
};

struct ReservationPolicy {
	double lease = 2.0; // seconds a ticket survives without renew()
	double aging_per_second = 0.1; // rank gained per second of waiting
	double ended_retention = 10.0; // seconds an ended ticket stays queryable
};

class ReservationTable {
public:
	explicit ReservationTable(const ReservationPolicy &policy = ReservationPolicy());

	// Returns a ticket > 0, or 0 for invalid input (non-finite volume, radius/height <= 0).
	// Re-requesting the same actor, kind and resource while its ticket is live returns that
	// ticket (volume and priority updated, request time kept, lease renewed).
	uint64_t request(const ReservationRequest &request, double now);
	// Ends expired tickets, then grants in rank order (see top of file). Call once per tick.
	void update(double now);
	// Keeps a live ticket's lease. False when the ticket is not live.
	bool renew(uint64_t ticket, double now);
	bool release(uint64_t ticket, ReservationEnd why = ReservationEnd::RELEASED, double now = 0.0);
	// Ends every live ticket of the actor. Returns how many ended.
	uint32_t release_actor(const AirActorKey &actor, ReservationEnd why, double now = 0.0);

	ReservationState state(uint64_t ticket) const;
	ReservationEnd end_reason(uint64_t ticket) const;
	bool held(uint64_t ticket) const { return state(ticket) == ReservationState::GRANTED; }
	double waited(uint64_t ticket, double now) const; // seconds since the request (0 if unknown)
	double granted_at(uint64_t ticket) const; // -1 when never granted
	// A GRANTED reservation of another actor overlapping `volume` (ground keep-out query).
	bool conflicts(const AirCylinder &volume, const AirActorKey &ignore, uint64_t *ticket = nullptr) const;
	size_t live_count() const;
	const ReservationPolicy &policy() const { return policy_; }

private:
	struct Entry {
		ReservationRequest request;
		ReservationState state = ReservationState::WAITING;
		ReservationEnd end = ReservationEnd::NONE;
		double requested_at = 0.0;
		double renewed_at = 0.0;
		double granted_at = -1.0;
		double ended_at = 0.0;
	};
	void end(Entry &entry, ReservationEnd why, double now);

	ReservationPolicy policy_;
	std::map<uint64_t, Entry> entries_; // ordered by ticket: deterministic iteration
	uint64_t next_ticket_ = 1;
};

} // namespace nav_air
