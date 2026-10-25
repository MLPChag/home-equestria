// Journey modes for flyers: GROUND -> TAKEOFF -> AIR -> APPROACH -> LANDING -> GROUND
// (navigation overhaul phase 5, AIR_TRANSITIONS slice; docs/NAVIGATION_AIR_TRANSITIONS_2026_10_02.md).
// Plain C++17, no Godot types, no threads of its own, deterministic for identical inputs.
//
// One AirJourney per actor. The binding (PonyNavigationNative) steps it on the main thread in the
// physics phase with the actor's live state, and applies the returned TransitionCommand through the
// locomotion adapter exactly once. Everything the journey needs from the world comes through
// TransitionWorld: the profile's (overlaid) AirSpace, a SupportQuery implemented by GDScript physics,
// the shared ReservationTable, an AirRoutePlanner and the predicted ground traffic.
//
// Modes, the work each owns and how it ends (PART 2, "Fly the route and land on a real surface"):
//
//   GROUND    owner GROUND. Leg TO_TAKEOFF: walk to a certified takeoff footprint. It ends when the
//             actor stands on that footprint (supported, same surface), holds the departure
//             reservation, the air route is ready and the live departure check passes -> TAKEOFF.
//             Leg CONTINUATION: after landing, walk on to the destination -> ARRIVED.
//   TAKEOFF   owner AIR (the one ownership change: floor snap off). Climb the certified departure
//             column footprint -> air entry E -> departure top T. Ends at T, clear of the ground and
//             on a corridor that still certifies -> AIR (departure reservation released).
//   AIR       owner AIR. Follow the XYZ corridor; hold in a certified holding volume on blockers,
//             replans, reservation waits and pad changes. Ends at the approach entry A with the pad
//             reservation held and the pad still valid -> APPROACH; or, for a hover intent, inside
//             the hover region (3D distance) -> ARRIVED, still airborne.
//   APPROACH  owner AIR. Forward glide down the certified cone A -> C (glide ratio, never a vertical
//             descent). Ends at C when the live landing certification passes -> LANDING; any
//             failure is a go-around back up the cone to A (mode AIR), never a descent.
//   LANDING   owner AIR. Flare C -> F -> touchdown P with occupancy/traffic/reservation checks.
//             Ends only on a real supported body: physics support, the pad's surface id, the pad's
//             height, acceptable speed -> GROUND (the second ownership change: floor snap on,
//             landing reservation released). Hovering above the pad is not landed.
//
// Every transition changes the motion owner at most once and bumps `ownership_epoch` when it does;
// the adapter applies floor snap / collision mode only for the current epoch, so a delayed callback
// from an old flight cannot undo a new one. Every refusal and wait carries a TransitionReason.
//
// Coordinates: Godot metres, Y up. Command paths, pads and footprints are ROOT positions (the
// point the locomotion adapter moves; on the ground it is the support point). The AirSpace stores
// occupancy for the BODY CENTRE (root + body.centre_height, inflated by the profile envelope), so
// the journey converts before every AirSpace query and every route request; AirRoutePlanner works
// in body-centre coordinates.
#pragma once

#include "air_dynamic.h"
#include "air_reservations.h"
#include "air_search.h"

#include <string>
#include <vector>

namespace nav_air {

// ---- Capabilities ----------------------------------------------------------------------------

constexpr uint32_t AIR_CAP_WINGS = 1u << 0; // may take wing links (takeoff, flight, landing)
constexpr uint32_t AIR_CAP_CLOUD_SUPPORT = 1u << 1; // may stand on / land on cloud surfaces

// pony_identity.gd `Race` order: EARTH, PEGASUS, UNICORN, ALICORN.
enum class AirRace : uint8_t { EARTH = 0, PEGASUS = 1, UNICORN = 2, ALICORN = 3 };
uint32_t air_capabilities_for_race(AirRace race);

enum class AirLinkKind : uint8_t {
	WALK = 0, // ordinary ground link
	WING = 1, // takeoff / flight / landing link
	CLOUD = 2, // ground link on cloud support
};
// Earth ponies and unicorns never take WING or CLOUD links; pegasi and alicorns may.
bool air_link_allowed(uint32_t capabilities, AirLinkKind link);

// Support surface flags (SupportSample::flags, PadProposal::flags).
constexpr uint32_t AIR_SURFACE_CLOUD = 1u << 0;
constexpr uint32_t AIR_SURFACE_WATER = 1u << 1;
constexpr uint32_t AIR_SURFACE_ROOF = 1u << 2; // takeoff from a roof is allowed, landing on one is not
constexpr uint32_t AIR_PAD_PROVISIONAL = 1u << 8; // proposal from a heightmap guess, not live collision

// ---- Reasons and modes -----------------------------------------------------------------------

enum class TransitionReason : uint16_t {
	NONE = 0,
	INVALID_INPUT,
	NO_WINGS, // capability: earth pony / unicorn asked for a wing link
	CLOUD_NOT_ALLOWED, // capability: cloud support without AIR_CAP_CLOUD_SUPPORT
	SURFACE_MISMATCH, // support surface id is not the pad's / the intent's required id
	WRONG_HEIGHT, // matching X/Z but not at the pad's / destination's height
	OFF_PAD, // supported, but horizontally off the pad
	NOT_SUPPORTED, // no physics support under the body (hovering is not landed)
	WATER_SURFACE,
	ROOF_SURFACE,
	SLOPE_TOO_STEEP,
	NO_SUPPORT, // nothing to stand on at the pad / footprint
	PROVISIONAL_SUPPORT, // only a heightmap guess: a proposed pad, not certified
	BODY_BLOCKED, // static geometry inside the body / wing volume
	OCCUPIED, // another body stands there
	SWEEP_BLOCKED, // live final approach / departure sweep hit geometry
	GROUND_TRAFFIC, // a predicted ground pony enters the transition volume
	NO_TAKEOFF_FOOTPRINT,
	TAKEOFF_VOLUME_BLOCKED, // departure column not certified (roof, crown, overhang)
	DEPARTURE_RESERVATION_WAIT,
	NO_PAD, // no pad proposal survived filtering and approach certification
	APPROACH_VOLUME_BLOCKED, // glide cone not certified in AirSpace
	PAD_RESERVATION_WAIT,
	PAD_RESERVATION_LOST,
	HOVER_POINT_BLOCKED,
	ROUTE_PENDING,
	ROUTE_WAITING_FOR_GEOMETRY,
	ROUTE_UNREACHABLE,
	ROUTE_BUDGET_EXHAUSTED,
	ROUTE_START_BLOCKED,
	ROUTE_FAILED,
	CORRIDOR_BLOCKED,
	CORRIDOR_MISSING_DATA,
	NO_HOLDING_VOLUME,
	ALL_PADS_BLOCKED,
	WAIT_TIMEOUT,
	LANDING_TIMEOUT,
	TOUCHDOWN_TOO_FAST,
	MANOEUVRE_NOT_ALLOWED, // loops never enter commanded travel
	MANOEUVRE_VOLUME_BLOCKED,
	MANOEUVRE_BUSY,
	INTERRUPTED,
	CANCELLED,
	DESPAWNED,
};
const char *transition_reason_name(TransitionReason reason);

enum class JourneyMode : uint8_t { GROUND = 0, TAKEOFF = 1, AIR = 2, APPROACH = 3, LANDING = 4 };
const char *journey_mode_name(JourneyMode mode);

enum class MotionOwner : uint8_t {
	NONE = 0, // no journey command (idle or despawned)
	GROUND = 1, // ground locomotion: floor snap, gait, ground navigation
	AIR = 2, // flight motion: floor snap off
	EXTERNAL = 3, // grabbed / thrown / player: the journey writes nothing
};
const char *motion_owner_name(MotionOwner owner);

enum class JourneyStatus : uint8_t { IDLE = 0, ACTIVE = 1, ARRIVED = 2, FAILED = 3, CANCELLED = 4 };
const char *journey_status_name(JourneyStatus status);

enum class GroundLeg : uint8_t { NONE = 0, TO_TAKEOFF = 1, CONTINUATION = 2 };
enum class AirPhase : uint8_t { FOLLOW = 0, HOLD = 1, GO_AROUND = 2, MANOEUVRE = 3, HOVER = 4 };

enum class CommandKind : uint8_t {
	NONE = 0, // no write this tick (another owner, or despawned)
	IDLE = 1, // ground owner, stand
	WALK = 2, // ground owner, walk to `target` (ground navigation supplies the corridor)
	CLIMB = 3, // takeoff column
	FLY = 4, // follow `path`
	HOLD = 5, // stay at `target` (certified holding volume)
	GLIDE = 6, // approach cone
	FLARE = 7, // landing flare and touchdown
	HOVER = 8, // arrived at a hover goal
	BRAKE = 9, // no certified option: stop now (exposed failure / emergency)
};
const char *command_kind_name(CommandKind kind);

// ---- Inputs ----------------------------------------------------------------------------------

struct BodyShape {
	float radius = 0.45f; // body capsule radius
	float height = 1.3f; // capsule height above the root
	float centre_height = 0.8f; // body centre above the root (AirSpace envelope centre)
	float wing_radius = 1.0f; // horizontal reach of open wings around the root
	float step = 0.3f; // static checks start this far above the support (ground contact)
};

struct TransitionProfile {
	uint32_t capabilities = AIR_CAP_WINGS | AIR_CAP_CLOUD_SUPPORT;
	BodyShape body;
	float envelope_radius = 1.5f; // the AirSpace inflation (AirProfile::envelope_radius)
	AirFlightLimits limits; // cruise / accel / brake / climb / descent
	// Takeoff.
	float footprint_search_radius = 8.0f;
	float footprint_ring_step = 2.0f;
	uint32_t footprint_directions = 8;
	float footprint_tolerance = 0.35f; // horizontal distance that counts as "on the footprint"
	float entry_margin = 0.25f; // body centre above the inflated ground at the air entry E
	// How far above its lowest possible height E may be searched. Kept small on purpose: below E
	// the climb is certified by live collision only, so a footprint whose AirSpace column is
	// blocked by a nearby roof or crown must be rejected, not climbed through on a live check.
	float entry_scan = 1.0f;
	float departure_climb = 3.0f; // T = E + up * departure_climb
	float takeoff_speed_low = 1.8f; // below E
	float takeoff_speed_high = 3.5f;
	// Approach / landing (forward glide, never a vertical descent).
	float glide_ratio = 3.0f; // metres forward per metre down
	float min_glide_ratio = 1.5f; // GLIDE commands never descend steeper than this (forward per down)
	float min_flare_ratio = 1.0f; // FLARE commands likewise
	float approach_height = 8.0f; // A above the pad (root)
	float flare_distance = 1.4f; // F is this far before the pad
	float flare_height = 0.7f; // and this high above it
	float cut_margin = 0.75f; // C: body centre this far above envelope_radius over the pad
	float approach_speed = 6.0f;
	float flare_speed = 1.8f;
	float cone_base_radius = 0.25f; // certified slack around the glide line at C
	float cone_top_radius = 1.0f; // and at A
	float touchdown_speed = 1.0f; // max |velocity| that counts as a landed body
	float pad_height_tolerance = 0.18f;
	float max_slope_degrees = 25.0f;
	float pad_margin = 0.25f; // added to reservation / occupancy radii
	// Holding.
	float hold_drift = 1.0f; // certified radius around a holding point beyond braking
	float hover_speed = 0.5f; // hover arrival: speed at most this
	float waypoint_tolerance = 0.6f;
	// Waits and timeouts (seconds; deterministic simulation clock).
	double takeoff_wait_limit = 15.0;
	double pad_wait_limit = 8.0; // waiting for one pad's reservation before trying another
	double hold_limit = 20.0; // holding with no valid pad before ALL_PADS_BLOCKED
	double route_wait_limit = 30.0; // WAITING_FOR_GEOMETRY before failing
	double route_retry = 1.0;
	double landing_time_limit = 10.0; // C -> touchdown before a go-around
	double pad_recheck = 0.5; // live pad pre-check period near the pad
	double pad_retry = 3.0; // a blocked pad is not retried before this
	float reserve_ahead_distance = 60.0f; // request the pad reservation this far along the route
	float traffic_horizon = 3.0f; // seconds of ground-traffic prediction at transitions
	int32_t priority = 0;
	float scale = 1.0f; // informational: values above are already scaled

	bool valid(std::string &error) const;
};

// Live actor state for this tick, gathered after the last physical move.
struct TransitionActorState {
	Vec3 root{0, 0, 0};
	Vec3 velocity{0, 0, 0};
	float yaw = 0.0f; // Godot yaw (forward = (-sin yaw, 0, -cos yaw))
	bool supported = false; // physics floor contact this tick, never inferred from height
	uint32_t support_surface_id = 0;
	uint32_t support_flags = 0;
};

struct SupportSample {
	bool hit = false;
	bool live = false; // false: a heightmap / unloaded estimate
	Vec3 point{0, 0, 0};
	Vec3 normal{0, 1, 0};
	uint32_t surface_id = 0;
	uint32_t flags = 0; // AIR_SURFACE_*
};

struct PadProposal {
	uint32_t pad_id = 0; // stable id (authored pad, or one derived by the proposer)
	Vec3 point{0, 0, 0}; // proposed touchdown root position
	uint32_t surface_id = 0; // the surface the pad stands on
	uint32_t flags = 0; // AIR_SURFACE_* | AIR_PAD_PROVISIONAL
};

// Implemented later by the GDScript physics adapter (main thread, physics phase). All queries use
// live collision for the actor's own collision mask (pegasi include the cloud layer).
class SupportQuery {
public:
	virtual ~SupportQuery() = default;
	// Vertical probe from at.y + up down to at.y - down; the highest support hit.
	virtual bool support(const Vec3 &at, float up, float down, SupportSample &out) const = 0;
	// True when static geometry does not overlap the cylinder.
	virtual bool volume_clear(const AirCylinder &volume) const = 0;
	// Bodies (ponies, the player, loose props) inside the cylinder, excluding `self`.
	virtual uint32_t occupancy(const AirCylinder &volume, uint64_t self) const = 0;
	// Sphere of `radius` centred `centre_height` above the root swept from one root position to
	// another, against static geometry.
	virtual bool sweep_clear(const Vec3 &from_root, const Vec3 &to_root, float radius, float centre_height) const = 0;
	// Proposed pads near `goal`, best first (authored pads, door pads, heightmap guesses).
	virtual void propose_pads(const Vec3 &goal, float radius, uint32_t required_surface_id,
			std::vector<PadProposal> &out) const = 0;
};

// Air routes in BODY-CENTRE coordinates. request() starts a job and returns a ticket > 0 (0 on
// invalid input); poll() answers PENDING until it ends, and on COMPLETE fills a certified route
// (shortened, every segment clear). The phase 5 binding runs these on its search workers.
class AirRoutePlanner {
public:
	virtual ~AirRoutePlanner() = default;
	virtual uint64_t request(const Vec3 &start, const AirGoal &goal) = 0;
	virtual AirStatus poll(uint64_t ticket, AirRoute &out) = 0;
	virtual void cancel(uint64_t ticket) = 0;
};

// Runs AirSearch + air_shorten synchronously inside request(). For tests, labs and short local hops.
class SyncAirRoutePlanner : public AirRoutePlanner {
public:
	SyncAirRoutePlanner(const AirSpace &space, const AirSearchLimits &limits = AirSearchLimits());
	uint64_t request(const Vec3 &start, const AirGoal &goal) override;
	AirStatus poll(uint64_t ticket, AirRoute &out) override;
	void cancel(uint64_t ticket) override;
	uint32_t requests() const { return requests_; }

private:
	struct Done {
		uint64_t ticket;
		AirStatus status;
		AirRoute route;
	};
	const AirSpace &space_;
	AirSearchLimits limits_;
	AirSearch search_;
	std::vector<Done> done_;
	uint64_t next_ = 1;
	uint32_t requests_ = 0;
};

// A ground pony as the ground system predicts it: a vertical capsule moving linearly.
struct PredictedCapsule {
	uint64_t actor = 0; // AirActorKey::packed(); the journey skips its own
	Vec3 base{0, 0, 0}; // feet now
	Vec3 velocity{0, 0, 0};
	float radius = 0.45f;
	float height = 1.3f;
};
// True when a capsule's linear prediction over [0, horizon] overlaps the cylinder.
bool air_traffic_conflict(const std::vector<PredictedCapsule> &traffic, const AirCylinder &volume, float horizon,
		uint64_t self, uint64_t *who = nullptr);

struct TransitionWorld {
	const AirSpace *air = nullptr; // this profile's space (OverlaidAirSpace when blockers exist)
	const SupportQuery *support = nullptr;
	ReservationTable *reservations = nullptr; // update(now) once per tick before stepping journeys
	AirRoutePlanner *planner = nullptr;
	const std::vector<PredictedCapsule> *ground_traffic = nullptr; // may be null
};

enum class JourneyTerminal : uint8_t {
	LAND = 0, // land on a certified pad near the destination (then optionally walk on)
	HOVER = 1, // hover at the exact XYZ destination (3D arrival; not landed)
};
enum class JourneyPurpose : uint8_t {
	COMMANDED = 0, // travel, follow, story: manoeuvres are refused
	LEISURE = 1, // joyride: explicit manoeuvres may be requested
};

struct JourneyIntent {
	uint64_t generation = 0;
	JourneyTerminal terminal = JourneyTerminal::LAND;
	JourneyPurpose purpose = JourneyPurpose::COMMANDED;
	Vec3 destination{0, 0, 0}; // root position (hover point, or where to walk after landing)
	float pad_search_radius = 12.0f;
	uint32_t required_surface_id = 0; // 0: any allowed surface; else the pad must stand on it
	bool walk_after_landing = true; // walk on from the pad to the destination
	float arrival_radius = 0.25f; // horizontal for LAND (+ height tolerance), 3D for HOVER
	float arrival_height_tolerance = 0.3f;
	int32_t priority = 0;
};

enum class ManoeuvreKind : uint8_t {
	LOOP = 0, // vertical circle along the heading (loop-de-loop)
	ORBIT = 1, // horizontal circle (joyride lap)
};
struct ManoeuvreRequest {
	ManoeuvreKind kind = ManoeuvreKind::LOOP;
	float radius = 3.0f;
	uint32_t chords = 16;
	float margin = 0.25f; // certified slack beyond the chord-to-circle bound
	float speed = 6.0f;
};

// ---- Outputs ---------------------------------------------------------------------------------

struct TransitionCommand {
	bool valid = false; // false: write nothing (EXTERNAL / NONE owner)
	JourneyMode mode = JourneyMode::GROUND;
	MotionOwner owner = MotionOwner::NONE;
	uint32_t ownership_epoch = 0;
	bool floor_snap = true; // ground owner only
	CommandKind kind = CommandKind::NONE;
	std::vector<Vec3> path; // root positions, remaining path of this phase (first = actor's projection)
	Vec3 target{0, 0, 0}; // walk target, hold / hover point, or the path end
	float speed_limit = 0.0f;
	float end_speed = 0.0f; // speed wanted at the path end
	Vec3 velocity{0, 0, 0}; // reference air velocity (simple pursuit; the flight follower may replace it)
	TransitionReason reason = TransitionReason::NONE; // why waiting / holding / braking
	uint32_t pad_id = 0;
};

enum class TransitionEventKind : uint8_t {
	MODE_CHANGED = 0,
	REFUSED = 1,
	PAD_SELECTED = 2,
	PAD_REJECTED = 3,
	HOLDING = 4,
	GO_AROUND = 5,
	ARRIVED = 6,
	FAILED = 7,
	CANCELLED = 8,
	MANOEUVRE_STARTED = 9,
	MANOEUVRE_DONE = 10,
};
const char *transition_event_name(TransitionEventKind kind);

struct TransitionEvent {
	TransitionEventKind kind = TransitionEventKind::MODE_CHANGED;
	JourneyMode from = JourneyMode::GROUND;
	JourneyMode to = JourneyMode::GROUND;
	MotionOwner owner_from = MotionOwner::NONE;
	MotionOwner owner_to = MotionOwner::NONE;
	uint32_t ownership_epoch = 0;
	TransitionReason reason = TransitionReason::NONE;
	uint32_t pad_id = 0;
	uint64_t intent_generation = 0;
	double time = 0.0;
};

// Arrival on a pad: a real supported body on the pad's surface, at its height, slow enough.
// Returns NONE when landed, else the first failing reason in this order: NOT_SUPPORTED (hovering),
// OFF_PAD, WRONG_HEIGHT (e.g. on the terrain under a cloud pad), SURFACE_MISMATCH,
// TOUCHDOWN_TOO_FAST.
TransitionReason air_landed_check(const TransitionActorState &actor, const Vec3 &pad, uint32_t pad_surface_id,
		float horizontal_tolerance, float height_tolerance, float max_speed);

// Simple pursuit used for the transition paths (and by tests). `path` starts at the actor's
// projection (as TransitionCommand::path does); carrot along it, speed
// min(limit, sqrt(end^2 + 2 brake remaining)), climb/descent clamped, acceleration limited.
// min_glide_ratio > 0: the result never descends steeper than that many metres forward per metre
// down (forward glide; a vertical descent is never commanded).
Vec3 air_transition_pursuit(const Vec3 &root, const Vec3 &velocity, const std::vector<Vec3> &path, float speed_limit,
		float end_speed, const AirFlightLimits &limits, float dt, float min_glide_ratio = 0.0f);

// Approach geometry for one pad and heading (root positions).
struct ApproachPlan {
	PadProposal pad;
	Vec3 heading{0, 0, -1}; // horizontal unit vector, A -> P
	Vec3 entry{0, 0, 0}; // A: glide entry (end of the air route)
	Vec3 cut{0, 0, 0}; // C: lowest point certified in AirSpace
	Vec3 flare{0, 0, 0}; // F
	AirCorridor cone; // A -> C, body-centre coordinates, widening clearance
	AirCylinder volume; // landing reservation / traffic volume around the touchdown
	// A itself is certified as a holding volume (sphere of profile.hold_drift).
};

// ---- The journey -----------------------------------------------------------------------------

class AirJourney {
public:
	AirJourney(const AirActorKey &actor, const TransitionProfile &profile);

	// Starts (or replaces) an intent. Refusals return their reason, record a REFUSED event and
	// leave the actor's mode and owner unchanged. A grounded actor starts in GROUND (TO_TAKEOFF);
	// an airborne one in AIR, holding while its new route is planned.
	TransitionReason begin(const JourneyIntent &intent, const TransitionActorState &actor, TransitionWorld &world,
			double now);
	// One physics tick. Fills `out` (always; out.valid false means "write nothing").
	void step(const TransitionActorState &actor, TransitionWorld &world, double now, float dt, TransitionCommand &out);
	// Explicit optional manoeuvre (LEISURE intents only, AIR following or hovering).
	TransitionReason request_manoeuvre(const ManoeuvreRequest &request, const TransitionActorState &actor,
			TransitionWorld &world, double now);
	// Intent cancelled: reservations released. Airborne actors keep an AIR hold (never dropped);
	// grounded ones go idle.
	void cancel(const TransitionActorState &actor, TransitionWorld &world, double now);
	// Grabbed / thrown / player control: release everything, owner EXTERNAL.
	void interrupt(TransitionWorld &world, double now);
	// Ownership returns: the same intent restarts from the actor's real state.
	TransitionReason resume(const TransitionActorState &actor, TransitionWorld &world, double now);
	// Actor leaves the world: release everything, owner NONE, no further commands.
	void despawn(TransitionWorld &world, double now);

	JourneyMode mode() const { return mode_; }
	MotionOwner owner() const { return owner_; }
	uint32_t ownership_epoch() const { return epoch_; }
	JourneyStatus status() const { return status_; }
	TransitionReason failure() const { return failure_; }
	GroundLeg ground_leg() const { return leg_; }
	AirPhase air_phase() const { return phase_; }
	const AirActorKey &actor() const { return actor_; }
	const JourneyIntent &intent() const { return intent_; }
	const std::vector<ApproachPlan> &pads() const { return pads_; }
	uint32_t active_pad() const; // 0 when none
	uint64_t departure_ticket() const { return departure_ticket_; }
	uint64_t landing_ticket() const { return landing_ticket_; }
	const Vec3 &footprint() const { return footprint_; }
	const Vec3 &departure_top() const { return top_; }
	const Vec3 &hold_point() const { return hold_; }
	std::vector<TransitionEvent> take_events();
	const std::vector<TransitionEvent> &events() const { return events_; }

private:
	struct Footprint {
		Vec3 root{0, 0, 0}, entry{0, 0, 0}, top{0, 0, 0};
		uint32_t surface_id = 0;
	};
	enum class PadCheck : uint8_t {
		LIGHT = 0, // live support, slope, surface id, body clearance, occupancy
		ENTRY = 1, // + predicted ground traffic (before committing to an approach)
		FULL = 2, // + final approach sweep (live certification right before the flare)
	};
	struct PadState {
		double blocked_until = -1.0; // usable again from this time
		TransitionReason blocked_reason = TransitionReason::NONE;
	};

	Vec3 centre(const Vec3 &root) const;
	Vec3 root_of(const Vec3 &centre) const;
	void emit(TransitionEventKind kind, TransitionReason reason, double now, uint32_t pad = 0);
	void change_mode(JourneyMode to, MotionOwner owner, TransitionReason reason, double now);
	void release_own(TransitionWorld &world, ReservationEnd why, double now);
	void fail(TransitionReason reason, TransitionWorld &world, double now);

	TransitionReason check_footprint(const Vec3 &root, TransitionWorld &world, Footprint &out) const;
	TransitionReason select_footprint(const JourneyIntent &intent, const TransitionActorState &actor,
			TransitionWorld &world, Footprint &out) const;
	AirCylinder departure_volume() const;
	void request_departure(TransitionWorld &world, double now);
	TransitionReason departure_live_check(TransitionWorld &world) const;

	TransitionReason pad_surface_ok(const PadProposal &pad, uint32_t required_surface_id) const;
	TransitionReason plan_approach(const PadProposal &pad, const Vec3 &from_root, TransitionWorld &world,
			ApproachPlan &out) const;
	TransitionReason plan_pads(const JourneyIntent &intent, const Vec3 &from_root, TransitionWorld &world, double now,
			std::vector<ApproachPlan> &out);
	TransitionReason pad_live_check(const ApproachPlan &plan, TransitionWorld &world, PadCheck level) const;
	bool pad_usable(size_t index, double now) const;
	void block_pad(TransitionWorld &world, size_t index, TransitionReason why, double now);
	AirGoal landing_goal(double now) const;
	void request_landing_reservation(TransitionWorld &world, double now);
	bool ticket_live(TransitionWorld &world, uint64_t ticket) const;

	void request_route(const Vec3 &from_centre, TransitionWorld &world, double now, bool retry);
	bool route_pending() const;
	bool poll_route(TransitionWorld &world, double now, TransitionReason &wait);

	void hold_at(const Vec3 &root, bool at_entry, TransitionReason reason, double now);
	void enter_hold(const TransitionActorState &actor, TransitionWorld &world, TransitionReason reason, double now);
	bool has_alternate(double now) const;
	bool switch_pad(TransitionWorld &world, const TransitionActorState &actor, double now);
	void go_around(const TransitionActorState &actor, TransitionWorld &world, TransitionReason why, double now);

	void step_ground(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
			TransitionCommand &out);
	void step_takeoff(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
			TransitionCommand &out);
	void step_air(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
			TransitionCommand &out);
	void step_hold(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
			TransitionCommand &out, TransitionReason route_wait);
	void step_detour(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
			TransitionCommand &out);
	void step_approach(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
			TransitionCommand &out);
	void step_landing(const TransitionActorState &actor, TransitionWorld &world, double now, float dt,
			TransitionCommand &out);
	void fill_path(CommandKind kind, const std::vector<Vec3> &path, float speed, float end_speed,
			const TransitionActorState &actor, float dt, TransitionCommand &out, float min_glide_ratio = 0.0f) const;
	void fill_hold(const TransitionActorState &actor, float dt, TransitionCommand &out) const;

	AirActorKey actor_;
	TransitionProfile profile_;
	JourneyIntent intent_;
	bool has_intent_ = false;
	JourneyMode mode_ = JourneyMode::GROUND;
	MotionOwner owner_ = MotionOwner::NONE; // first begin() sets GROUND or AIR
	uint32_t epoch_ = 0;
	JourneyStatus status_ = JourneyStatus::IDLE;
	TransitionReason failure_ = TransitionReason::NONE;
	GroundLeg leg_ = GroundLeg::NONE;
	AirPhase phase_ = AirPhase::FOLLOW;
	std::vector<TransitionEvent> events_; // bounded (256), drained by take_events()

	// Takeoff (root positions).
	Vec3 footprint_{0, 0, 0}, entry_{0, 0, 0}, top_{0, 0, 0};
	uint32_t footprint_surface_ = 0;
	uint64_t departure_ticket_ = 0;
	double wait_since_ = -1.0;
	// Route (body-centre corridor).
	uint64_t route_ticket_ = 0;
	bool route_ready_ = false;
	double route_since_ = 0.0;
	double route_retry_at_ = -1.0;
	Vec3 route_from_{0, 0, 0};
	AirCorridor corridor_;
	uint32_t corridor_index_ = 0;
	// Pads.
	std::vector<ApproachPlan> pads_;
	std::vector<PadState> pad_states_;
	int active_pad_ = -1;
	uint64_t landing_ticket_ = 0;
	double pad_wait_since_ = -1.0;
	double next_pad_check_ = 0.0;
	double pad_stall_ = 0.0; // seconds held because of pads (reset when an approach starts)
	double landing_since_ = 0.0;
	// Holding / go-around / manoeuvre (root positions).
	Vec3 hold_{0, 0, 0};
	bool hold_braking_ = false; // no certified hold: brake in place (never descend)
	bool hold_at_entry_ = false;
	bool rejoin_pending_ = false; // a fresh route waits until she is at its start
	TransitionReason hold_reason_ = TransitionReason::NONE;
	std::vector<Vec3> detour_;
	uint32_t detour_index_ = 0;
	float manoeuvre_speed_ = 0.0f;
};

} // namespace nav_air
