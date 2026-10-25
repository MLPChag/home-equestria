// Standalone tests for the AIR_TRANSITIONS slice (nav_air/air_transitions, nav_air/air_reservations).
// No Godot. A FakeSupport stands in for the GDScript physics adapter (support, volumes, occupancy,
// sweeps, pad proposals) and a tiny kinematic body applies each TransitionCommand once per tick.
// The AirSpace is the search slice's in-memory TestAirSpace, filled with geometry already inflated
// by the 1.5 m envelope, exactly as the storage bake delivers it.
// Build: build_air_transitions_tests.sh OUTPUT_DIR. Each test answers a behaviour question.
#include "../nav_air/air_test_space.h"
#include "../nav_air/air_transitions.h"

#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

using namespace nav_air;

namespace {

int failures = 0;
int checks = 0;
bool trace = false; // AIR_TRACE=1: per-tick lines (diagnostics only)

#define CHECK(condition, label)                                                    \
	do {                                                                           \
		++checks;                                                                  \
		if (!(condition)) {                                                        \
			++failures;                                                            \
			std::printf("  FAIL %s (%s:%d)\n", label, __FILE__, __LINE__);        \
		}                                                                          \
	} while (0)

void section(const char *name) {
	std::printf("[%s]\n", name);
}

constexpr float ENVELOPE = 1.5f;

Aabb box(float x0, float y0, float z0, float x1, float y1, float z1) {
	return Aabb{Vec3{x0, y0, z0}, Vec3{x1, y1, z1}};
}
Vec3 v3(float x, float y, float z) {
	return Vec3{x, y, z};
}
Aabb inflate(const Aabb &b, float e) {
	return box(b.min.x - e, b.min.y - e, b.min.z - e, b.max.x + e, b.max.y + e, b.max.z + e);
}
Vec3 vsub(const Vec3 &a, const Vec3 &b) {
	return v3(a.x - b.x, a.y - b.y, a.z - b.z);
}
float vlen(const Vec3 &a) {
	return std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
}
float hlen(const Vec3 &a) {
	return std::sqrt(a.x * a.x + a.z * a.z);
}

// ---- Fake physics adapter ---------------------------------------------------------------------

struct FakeBox {
	Aabb box;
	uint32_t surface_id = 1;
	uint32_t flags = 0;
	bool live = true; // false: only a heightmap estimate exists here
	bool solid = true; // collides for volume / sweep checks
	bool support = true; // its top face is a support surface
	Vec3 normal{0, 1, 0};
};

struct FakeBody {
	AirCylinder c;
	uint64_t actor = 0;
};

bool cylinder_box(const AirCylinder &c, const Aabb &b) {
	if (!(c.base.y < b.max.y && c.base.y + c.height > b.min.y)) {
		return false;
	}
	const float dx = std::max(std::max(b.min.x - c.base.x, 0.0f), c.base.x - b.max.x);
	const float dz = std::max(std::max(b.min.z - c.base.z, 0.0f), c.base.z - b.max.z);
	return dx * dx + dz * dz < c.radius * c.radius;
}

// Segment against a box (closed slabs: touching counts, conservative).
bool segment_box(const Vec3 &a, const Vec3 &b, const Aabb &bx) {
	float t0 = 0.0f, t1 = 1.0f;
	const float A[3] = {a.x, a.y, a.z}, B[3] = {b.x, b.y, b.z};
	const float lo[3] = {bx.min.x, bx.min.y, bx.min.z}, hi[3] = {bx.max.x, bx.max.y, bx.max.z};
	for (int i = 0; i < 3; ++i) {
		const float d = B[i] - A[i];
		if (std::fabs(d) < 1.0e-9f) {
			if (A[i] < lo[i] || A[i] > hi[i]) {
				return false;
			}
			continue;
		}
		float u0 = (lo[i] - A[i]) / d, u1 = (hi[i] - A[i]) / d;
		if (u0 > u1) {
			std::swap(u0, u1);
		}
		t0 = std::max(t0, u0);
		t1 = std::min(t1, u1);
		if (t0 > t1) {
			return false;
		}
	}
	return true;
}

class FakeSupport : public SupportQuery {
public:
	std::vector<FakeBox> boxes;
	std::vector<FakeBody> bodies;
	std::vector<PadProposal> pads;

	bool support(const Vec3 &at, float up, float down, SupportSample &out) const override {
		out = SupportSample();
		bool any = false;
		for (const FakeBox &b : boxes) {
			if (!b.support || at.x < b.box.min.x || at.x > b.box.max.x || at.z < b.box.min.z || at.z > b.box.max.z) {
				continue;
			}
			const float top = b.box.max.y;
			if (top > at.y + up || top < at.y - down || (any && top <= out.point.y)) {
				continue;
			}
			any = true;
			out.hit = true;
			out.live = b.live;
			out.point = v3(at.x, top, at.z);
			out.normal = b.normal;
			out.surface_id = b.surface_id;
			out.flags = b.flags;
		}
		return any;
	}
	bool volume_clear(const AirCylinder &c) const override {
		for (const FakeBox &b : boxes) {
			if (b.solid && b.live && cylinder_box(c, b.box)) {
				return false;
			}
		}
		return true;
	}
	uint32_t occupancy(const AirCylinder &c, uint64_t self) const override {
		uint32_t n = 0;
		for (const FakeBody &b : bodies) {
			if (b.actor != self && air_cylinders_overlap(b.c, c)) {
				++n;
			}
		}
		return n;
	}
	bool sweep_clear(const Vec3 &from, const Vec3 &to, float radius, float centre_height) const override {
		const Vec3 a = v3(from.x, from.y + centre_height, from.z), b = v3(to.x, to.y + centre_height, to.z);
		for (const FakeBox &bx : boxes) {
			if (bx.solid && bx.live && segment_box(a, b, inflate(bx.box, radius))) {
				return false;
			}
		}
		return true;
	}
	void propose_pads(const Vec3 &goal, float radius, uint32_t, std::vector<PadProposal> &out) const override {
		out.clear();
		for (const PadProposal &p : pads) {
			if (hlen(vsub(p.point, goal)) <= radius) {
				out.push_back(p);
			}
		}
	}
};

// ---- World and body simulator ------------------------------------------------------------------

struct Sim {
	TestAirSpace space;
	DynamicOverlay overlay;
	OverlaidAirSpace air{space, overlay};
	FakeSupport support;
	ReservationTable table;
	SyncAirRoutePlanner planner{air};
	std::vector<PredictedCapsule> traffic;
	TransitionWorld world;
	double now = 0.0;
	float dt = 0.05f;

	Sim() {
		world.air = &air;
		world.support = &support;
		world.reservations = &table;
		world.planner = &planner;
		world.ground_traffic = &traffic;
		space.add_tiles(box(-64, -32, -64, 96, 96, 64), Cell::FREE);
		FakeBox ground;
		ground.box = box(-64, -1, -64, 96, 0, 64);
		support.boxes.push_back(ground);
		space.fill_box(box(-64, -32, -64, 96, ENVELOPE, 64), Cell::SOLID);
	}
	// Live collision for the adapter, inflated occupancy for the AirSpace.
	void add_solid(const Aabb &b, uint32_t surface_id = 5, uint32_t flags = 0, bool live = true) {
		FakeBox f;
		f.box = b;
		f.surface_id = surface_id;
		f.flags = flags;
		f.live = live;
		support.boxes.push_back(f);
		space.fill_box(inflate(b, ENVELOPE), Cell::SOLID);
	}
};

struct Body {
	AirActorKey key{1, 1};
	TransitionActorState s;
	float walk_speed = 1.5f;
	float hover_floor = -1.0e9f; // test hook: keeps the body at least this high while flying

	Body(const Vec3 &at, uint32_t surface = 1) {
		s.root = at;
		s.supported = true;
		s.support_surface_id = surface;
	}
	AirCylinder cylinder() const {
		return AirCylinder{s.root, 0.45f, 1.3f};
	}
};

void apply(Sim &sim, Body &body, const TransitionCommand &cmd) {
	TransitionActorState &s = body.s;
	if (!cmd.valid) {
		return;
	}
	if (cmd.owner == MotionOwner::GROUND) {
		if (cmd.kind != CommandKind::WALK) {
			s.velocity = v3(0, 0, 0);
			return;
		}
		Vec3 to = vsub(cmd.target, s.root);
		to.y = 0.0f;
		const float d = hlen(to), step = body.walk_speed * sim.dt;
		Vec3 next = d <= step ? v3(cmd.target.x, s.root.y, cmd.target.z)
							  : v3(s.root.x + to.x * step / d, s.root.y, s.root.z + to.z * step / d);
		SupportSample h;
		if (sim.support.support(next, 1.0f, 2.0f, h)) {
			next.y = h.point.y;
			s.supported = true;
			s.support_surface_id = h.surface_id;
			s.support_flags = h.flags;
		}
		s.velocity = v3((next.x - s.root.x) / sim.dt, 0.0f, (next.z - s.root.z) / sim.dt);
		s.root = next;
		return;
	}
	// Flight owner: integrate the reference velocity; touching a live support while not climbing lands.
	s.velocity = cmd.velocity;
	Vec3 next = v3(s.root.x + s.velocity.x * sim.dt, s.root.y + s.velocity.y * sim.dt, s.root.z + s.velocity.z * sim.dt);
	if (next.y < body.hover_floor) {
		next.y = body.hover_floor;
		s.velocity.y = 0.0f;
	}
	s.root = next;
	s.supported = false;
	SupportSample h;
	if (s.velocity.y <= 0.0f && sim.support.support(s.root, 0.02f, 0.05f, h) && h.live && s.root.y - h.point.y <= 0.02f) {
		s.root.y = h.point.y;
		s.velocity.y = 0.0f;
		s.supported = true;
		s.support_surface_id = h.surface_id;
		s.support_flags = h.flags;
	}
}

struct Run {
	std::vector<TransitionEvent> events;
	std::vector<JourneyMode> modes;
	std::vector<CommandKind> kinds;
	TransitionCommand last;
	float max_step = 0.0f; // largest per-tick displacement
	float max_descent = 0.0f; // fastest downward speed
	bool glide_ok = true; // descending in APPROACH only with forward motion
	bool supported_while_air = false;
	int ticks = 0;
	double seconds = 0.0;

	int count(TransitionEventKind kind, TransitionReason reason = TransitionReason::NONE, bool any_reason = true) const {
		int n = 0;
		for (const TransitionEvent &e : events) {
			if (e.kind == kind && (any_reason || e.reason == reason)) {
				++n;
			}
		}
		return n;
	}
	int count_reason(TransitionEventKind kind, TransitionReason reason) const {
		return count(kind, reason, false);
	}
	bool saw_kind(CommandKind k) const {
		for (CommandKind c : kinds) {
			if (c == k) {
				return true;
			}
		}
		return false;
	}
};

void tick(Sim &sim, AirJourney &j, Body &body, Run &run) {
	sim.table.update(sim.now);
	TransitionCommand cmd;
	const Vec3 before = body.s.root;
	j.step(body.s, sim.world, sim.now, sim.dt, cmd);
	apply(sim, body, cmd);
	for (const TransitionEvent &e : j.take_events()) {
		run.events.push_back(e);
	}
	if (run.modes.empty() || run.modes.back() != j.mode()) {
		run.modes.push_back(j.mode());
	}
	if (cmd.valid && (run.kinds.empty() || run.kinds.back() != cmd.kind)) {
		run.kinds.push_back(cmd.kind);
	}
	const Vec3 d = vsub(body.s.root, before);
	run.max_step = std::max(run.max_step, vlen(d));
	const float vy = d.y / sim.dt;
	run.max_descent = std::max(run.max_descent, -vy);
	if (j.mode() == JourneyMode::APPROACH && cmd.mode == JourneyMode::APPROACH && vy < -0.3f &&
			hlen(d) / sim.dt < (TransitionProfile().min_glide_ratio - 0.01f) * -vy) {
		run.glide_ok = false;
	}
	if (cmd.owner == MotionOwner::AIR && (j.mode() == JourneyMode::AIR || j.mode() == JourneyMode::APPROACH) &&
			body.s.supported) {
		run.supported_while_air = true;
	}
	if (trace) {
		std::printf("    t %6.2f %-8s %-6s %-9s p(%7.2f %6.2f %6.2f) v(%6.2f %6.2f %6.2f) %s\n", sim.now,
				journey_mode_name(j.mode()), command_kind_name(cmd.kind), journey_status_name(j.status()), body.s.root.x,
				body.s.root.y, body.s.root.z, body.s.velocity.x, body.s.velocity.y, body.s.velocity.z,
				transition_reason_name(cmd.reason));
	}
	run.last = cmd;
	++run.ticks;
	sim.now += sim.dt;
	run.seconds += sim.dt;
}

void run_until(Sim &sim, AirJourney &j, Body &body, Run &run, double seconds,
		const std::function<bool()> &stop = std::function<bool()>(),
		const std::function<void()> &each = std::function<void()>()) {
	const double end = sim.now + seconds;
	while (sim.now < end) {
		if (each) {
			each();
		}
		tick(sim, j, body, run);
		if (stop && stop()) {
			return;
		}
	}
}

bool mode_sequence(const Run &run, const std::vector<JourneyMode> &want) {
	return run.modes == want;
}

int owner_changes(const Run &run) {
	int n = 0;
	for (const TransitionEvent &e : run.events) {
		if (e.kind == TransitionEventKind::MODE_CHANGED && e.owner_from != e.owner_to) {
			++n;
		}
	}
	return n;
}

bool epochs_consistent(const Run &run) {
	uint32_t epoch = 0;
	bool first = true;
	for (const TransitionEvent &e : run.events) {
		if (e.kind != TransitionEventKind::MODE_CHANGED) {
			continue;
		}
		const uint32_t want = (first ? 0 : epoch) + (e.owner_from != e.owner_to ? 1 : 0);
		if (!first && e.ownership_epoch != want) {
			return false;
		}
		epoch = e.ownership_epoch;
		first = false;
	}
	return true;
}

void print_events(const Run &run) {
	for (const TransitionEvent &e : run.events) {
		std::printf("    %7.2f %-17s %-8s -> %-8s %-8s -> %-8s e%u %s pad %u\n", e.time, transition_event_name(e.kind),
				journey_mode_name(e.from), journey_mode_name(e.to), motion_owner_name(e.owner_from),
				motion_owner_name(e.owner_to), e.ownership_epoch, transition_reason_name(e.reason), e.pad_id);
	}
}

PadProposal pad(uint32_t id, const Vec3 &p, uint32_t surface = 1, uint32_t flags = 0) {
	PadProposal out;
	out.pad_id = id;
	out.point = p;
	out.surface_id = surface;
	out.flags = flags;
	return out;
}

JourneyIntent land_at(const Vec3 &destination, uint64_t generation = 1) {
	JourneyIntent in;
	in.generation = generation;
	in.terminal = JourneyTerminal::LAND;
	in.destination = destination;
	in.pad_search_radius = 12.0f;
	return in;
}

TransitionProfile pegasus() {
	TransitionProfile p;
	p.capabilities = air_capabilities_for_race(AirRace::PEGASUS);
	p.envelope_radius = ENVELOPE;
	return p;
}

// ---- Tests -------------------------------------------------------------------------------------

void test_capabilities() {
	section("capabilities: earth ponies and unicorns never take wing or cloud links");
	const uint32_t earth = air_capabilities_for_race(AirRace::EARTH);
	const uint32_t unicorn = air_capabilities_for_race(AirRace::UNICORN);
	const uint32_t peg = air_capabilities_for_race(AirRace::PEGASUS);
	const uint32_t ali = air_capabilities_for_race(AirRace::ALICORN);
	CHECK(!air_link_allowed(earth, AirLinkKind::WING) && !air_link_allowed(earth, AirLinkKind::CLOUD), "earth pony: no wing/cloud links");
	CHECK(!air_link_allowed(unicorn, AirLinkKind::WING) && !air_link_allowed(unicorn, AirLinkKind::CLOUD), "unicorn: no wing/cloud links");
	CHECK(air_link_allowed(earth, AirLinkKind::WALK) && air_link_allowed(unicorn, AirLinkKind::WALK), "everyone walks");
	CHECK(air_link_allowed(peg, AirLinkKind::WING) && air_link_allowed(peg, AirLinkKind::CLOUD), "pegasus: wings and clouds");
	CHECK(air_link_allowed(ali, AirLinkKind::WING) && air_link_allowed(ali, AirLinkKind::CLOUD), "alicorn: wings and clouds");

	Sim sim;
	sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
	TransitionProfile profile = pegasus();
	profile.capabilities = earth;
	AirJourney j(AirActorKey{7, 1}, profile);
	Body body(v3(0, 0, 0));
	const TransitionReason r = j.begin(land_at(v3(53, 0, 0)), body.s, sim.world, sim.now);
	CHECK(r == TransitionReason::NO_WINGS, "earth pony asking for a flight is refused NO_WINGS");
	CHECK(j.status() == JourneyStatus::IDLE && j.owner() == MotionOwner::NONE && j.ownership_epoch() == 0,
			"refusal changes neither status nor ownership");
	CHECK(sim.table.live_count() == 0 && sim.planner.requests() == 0, "refusal reserves nothing and plans nothing");
	const std::vector<TransitionEvent> ev = j.take_events();
	CHECK(ev.size() == 1 && ev[0].kind == TransitionEventKind::REFUSED && ev[0].reason == TransitionReason::NO_WINGS,
			"one REFUSED event with the reason");
	TransitionCommand cmd;
	j.step(body.s, sim.world, sim.now, sim.dt, cmd);
	CHECK(!cmd.valid, "a refused earth pony gets no command at all");
}

// Walks out from under a porch roof to a certified footprint, takes off, flies, glides in, lands
// on the pad and walks on to the door. Also the determinism check (run twice).
struct SequenceResult {
	Vec3 final_root;
	std::vector<TransitionEvent> events;
};

SequenceResult sequence_run(bool verbose) {
	section(verbose ? "sequence: walk -> takeoff -> air -> approach -> landing -> walk" : "sequence: determinism rerun");
	Sim sim;
	sim.add_solid(box(-2, 2.6f, -2, 2, 3.0f, 2), 5, AIR_SURFACE_ROOF); // porch roof over the start
	sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
	sim.support.pads.push_back(pad(12, v3(50, 0, 8)));
	AirJourney j(AirActorKey{1, 1}, pegasus());
	Body body(v3(0, 0, 0));
	Run run;
	const TransitionReason r = j.begin(land_at(v3(53, 0, 0)), body.s, sim.world, sim.now);
	CHECK(r == TransitionReason::NONE, "begin accepted");
	CHECK(j.mode() == JourneyMode::GROUND && j.ground_leg() == GroundLeg::TO_TAKEOFF, "starts walking to a takeoff footprint");
	const Vec3 fp = j.footprint();
	const float rx = std::max(std::fabs(fp.x) - 2.0f, 0.0f), rz = std::max(std::fabs(fp.z) - 2.0f, 0.0f);
	CHECK(std::sqrt(rx * rx + rz * rz) >= pegasus().body.wing_radius && std::fabs(fp.y) < 1.0e-4f,
			"footprint keeps open wings clear of the porch roof");
	CHECK(hlen(fp) > 0.5f && hlen(fp) <= pegasus().footprint_search_radius + 1.0e-3f, "footprint is near her, not under the roof");
	CHECK(j.pads().size() == 2, "both pads accepted with certified glide cones");
	bool walked_to_footprint = false;
	bool took_off_on_footprint = true;
	float min_air_y = 1.0e9f;
	run_until(sim, j, body, run, 90.0, [&]() { return j.status() != JourneyStatus::ACTIVE; }, [&]() {
		if (j.mode() == JourneyMode::GROUND && j.ground_leg() == GroundLeg::TO_TAKEOFF && !run.kinds.empty() &&
				run.kinds.back() == CommandKind::WALK) {
			walked_to_footprint = true;
		}
		if (j.mode() == JourneyMode::TAKEOFF && run.modes.back() == JourneyMode::GROUND) {
			took_off_on_footprint = took_off_on_footprint && hlen(vsub(body.s.root, fp)) <= 0.35f;
		}
		if (j.mode() == JourneyMode::AIR) {
			min_air_y = std::min(min_air_y, body.s.root.y);
		}
	});
	if (verbose) {
		print_events(run);
	}
	CHECK(j.status() == JourneyStatus::ARRIVED, "arrived");
	CHECK(mode_sequence(run, {JourneyMode::GROUND, JourneyMode::TAKEOFF, JourneyMode::AIR, JourneyMode::APPROACH,
								  JourneyMode::LANDING, JourneyMode::GROUND}),
			"modes GROUND TAKEOFF AIR APPROACH LANDING GROUND, each once");
	CHECK(walked_to_footprint && took_off_on_footprint, "walked to the footprint, took off from it");
	CHECK(run.count(TransitionEventKind::ARRIVED) == 1, "ARRIVED emitted exactly once");
	CHECK(owner_changes(run) == 3 && j.ownership_epoch() == 3,
			"ownership changed exactly at begin, GROUND->TAKEOFF and LANDING->GROUND");
	CHECK(epochs_consistent(run), "epoch increments by one exactly on an owner change");
	CHECK(hlen(vsub(body.s.root, v3(53, 0, 0))) <= 0.3f && body.s.supported && body.s.support_surface_id == 1,
			"stands at the door on the ground surface");
	CHECK(run.count_reason(TransitionEventKind::PAD_SELECTED, TransitionReason::NONE) >= 1, "pad selected");
	CHECK(run.count(TransitionEventKind::GO_AROUND) == 0 && run.count(TransitionEventKind::FAILED) == 0, "no go-around, no failure");
	CHECK(run.count(TransitionEventKind::MANOEUVRE_STARTED) == 0, "no loop inserted into commanded travel");
	CHECK(sim.table.live_count() == 0, "every reservation released");
	CHECK(run.max_step <= (20.0f + 1.0f) * sim.dt, "no tick moved her farther than cruise speed allows (no teleport)");
	CHECK(run.max_descent <= pegasus().limits.max_descent_rate + 1.0e-3f, "descent never faster than the profile limit");
	CHECK(run.glide_ok, "approach descends only while moving forward (glide, not vertical)");
	CHECK(!run.supported_while_air, "never supported while in AIR/APPROACH");
	CHECK(min_air_y >= 2.0f, "cruise stays clear of the ground");
	if (verbose) {
		std::printf("  footprint (%.2f, %.2f, %.2f), %.2f s, %d ticks, max step %.3f m, max descent %.2f m/s, planner calls %u\n",
				fp.x, fp.y, fp.z, run.seconds, run.ticks, run.max_step, run.max_descent, sim.planner.requests());
	}
	return SequenceResult{body.s.root, run.events};
}

void test_sequence() {
	const SequenceResult a = sequence_run(true);
	const SequenceResult b = sequence_run(false);
	bool same = a.events.size() == b.events.size() && a.final_root.x == b.final_root.x && a.final_root.y == b.final_root.y &&
			a.final_root.z == b.final_root.z;
	for (size_t i = 0; same && i < a.events.size(); ++i) {
		same = a.events[i].kind == b.events[i].kind && a.events[i].reason == b.events[i].reason &&
				a.events[i].time == b.events[i].time && a.events[i].pad_id == b.events[i].pad_id;
	}
	CHECK(same, "identical inputs give identical events and final position");
}

void test_pad_blocked_mid_approach() {
	section("landing pad blocked mid-approach: go-around, alternate pad");
	Sim sim;
	sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
	sim.support.pads.push_back(pad(12, v3(50, 0, 8)));
	AirJourney j(AirActorKey{1, 1}, pegasus());
	Body body(v3(0, 0, 0));
	Run run;
	CHECK(j.begin(land_at(v3(53, 0, 4)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
	bool blocked = false;
	bool landed_on_11 = false;
	float min_y_after_block = 1.0e9f;
	run_until(sim, j, body, run, 120.0, [&]() { return j.status() != JourneyStatus::ACTIVE; }, [&]() {
		if (!blocked && j.mode() == JourneyMode::APPROACH && hlen(vsub(body.s.root, v3(50, 0, 0))) < 18.0f) {
			FakeBody other;
			other.c = AirCylinder{v3(50, 0, 0.3f), 0.45f, 1.3f};
			other.actor = 99;
			sim.support.bodies.push_back(other); // a pony walks onto pad 11
			blocked = true;
		}
		if (blocked && j.mode() == JourneyMode::AIR) {
			min_y_after_block = std::min(min_y_after_block, body.s.root.y);
		}
		if (body.s.supported && hlen(vsub(body.s.root, v3(50, 0, 0))) < 0.5f && j.mode() != JourneyMode::TAKEOFF) {
			landed_on_11 = true;
		}
	});
	print_events(run);
	CHECK(blocked, "pad 11 was blocked during the approach");
	CHECK(run.count_reason(TransitionEventKind::GO_AROUND, TransitionReason::OCCUPIED) == 1, "one go-around, reason OCCUPIED");
	CHECK(run.count_reason(TransitionEventKind::PAD_REJECTED, TransitionReason::OCCUPIED) >= 1, "pad 11 rejected as OCCUPIED");
	bool selected_12 = false;
	for (const TransitionEvent &e : run.events) {
		selected_12 = selected_12 || (e.kind == TransitionEventKind::PAD_SELECTED && e.pad_id == 12);
	}
	CHECK(selected_12, "alternate pad 12 selected");
	CHECK(!landed_on_11, "never touched down on the occupied pad");
	CHECK(j.status() == JourneyStatus::ARRIVED, "arrived via the alternate");
	CHECK(hlen(vsub(body.s.root, v3(53, 0, 4))) <= 0.3f && body.s.supported, "walked on from pad 12 to the destination");
	CHECK(min_y_after_block >= 1.4f, "after the block, until the next approach, she never sank below the cone cut height");
	CHECK(run.max_step <= 21.0f * sim.dt && run.glide_ok, "no teleport, glide only");
	CHECK(sim.table.live_count() == 0, "reservations released");
}

void test_all_pads_blocked() {
	section("all pads blocked: certified hold, then exposed failure (no descent, no teleport)");
	Sim sim;
	sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
	sim.support.pads.push_back(pad(12, v3(50, 0, 8)));
	for (const Vec3 &p : {v3(50, 0, 0), v3(50, 0, 8)}) {
		FakeBody other;
		other.c = AirCylinder{p, 0.45f, 1.3f};
		other.actor = 90;
		sim.support.bodies.push_back(other);
	}
	AirJourney j(AirActorKey{1, 1}, pegasus());
	Body body(v3(0, 0, 0));
	Run run;
	CHECK(j.begin(land_at(v3(53, 0, 4)), body.s, sim.world, sim.now) == TransitionReason::NONE,
			"begin accepts proposed pads (occupancy is a live check, not a planning one)");
	float min_y_airborne = 1.0e9f;
	double first_all_blocked = -1.0;
	run_until(sim, j, body, run, 90.0, [&]() { return j.status() != JourneyStatus::ACTIVE; }, [&]() {
		if (j.mode() == JourneyMode::AIR) {
			min_y_airborne = std::min(min_y_airborne, body.s.root.y);
		}
		if (first_all_blocked < 0.0 && j.mode() == JourneyMode::AIR && j.air_phase() == AirPhase::HOLD &&
				run.last.reason == TransitionReason::ALL_PADS_BLOCKED) {
			first_all_blocked = sim.now;
		}
	});
	print_events(run);
	CHECK(j.status() == JourneyStatus::FAILED && j.failure() == TransitionReason::ALL_PADS_BLOCKED,
			"fails with ALL_PADS_BLOCKED");
	CHECK(first_all_blocked >= 0.0 && sim.now - first_all_blocked >= pegasus().hold_limit - 1.0,
			"held for the bounded hold time before failing");
	CHECK(run.count(TransitionEventKind::FAILED) == 1, "one FAILED event");
	CHECK(run.count(TransitionEventKind::GO_AROUND) == 0 && !run.saw_kind(CommandKind::GLIDE) &&
					!run.saw_kind(CommandKind::FLARE),
			"never started an approach to an occupied pad");
	CHECK(j.mode() == JourneyMode::AIR && j.owner() == MotionOwner::AIR, "still owned by flight: not landed");
	// After failure she keeps holding in certified air; a few more seconds change nothing.
	Run after;
	const Vec3 at_fail = body.s.root;
	run_until(sim, j, body, after, 5.0);
	CHECK(after.last.valid && (after.last.kind == CommandKind::HOLD || after.last.kind == CommandKind::BRAKE),
			"after failure: HOLD/BRAKE command");
	CHECK(body.s.root.y >= at_fail.y - 0.25f && !body.s.supported, "after failure: no descent");
	CHECK(min_y_airborne >= 2.0f, "never descended toward the pads while airborne");
	CHECK(run.max_step <= 21.0f * sim.dt && after.max_step <= 21.0f * sim.dt, "no teleport");
	CHECK(sim.table.live_count() == 0, "failure released every reservation");
}

void test_cloud() {
	section("cloud pads: capability, surface id, wrong height");
	auto cloud_sim = [](Sim &sim, uint32_t live_surface) {
		sim.add_solid(box(40, 29, -6, 56, 30, 6), live_surface, AIR_SURFACE_CLOUD);
		sim.support.pads.push_back(pad(21, v3(48, 30, 0), 77, AIR_SURFACE_CLOUD));
		sim.support.pads.push_back(pad(22, v3(48, 0, 9), 1, 0)); // terrain beside the cloud
	};
	JourneyIntent in = land_at(v3(50, 30, 2));
	in.required_surface_id = 77;
	in.pad_search_radius = 14.0f;
	{
		Sim sim;
		cloud_sim(sim, 77);
		TransitionProfile wings_only = pegasus();
		wings_only.capabilities = AIR_CAP_WINGS;
		AirJourney j(AirActorKey{2, 1}, wings_only);
		Body body(v3(0, 0, 0));
		const TransitionReason r = j.begin(in, body.s, sim.world, sim.now);
		CHECK(r == TransitionReason::CLOUD_NOT_ALLOWED, "winged but without cloud support: cloud pad refused");
	}
	{
		Sim sim;
		cloud_sim(sim, 77);
		AirJourney j(AirActorKey{2, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(in, body.s, sim.world, sim.now) == TransitionReason::NONE, "pegasus may land on the cloud");
		const std::vector<TransitionEvent> early = j.take_events();
		bool rejected_terrain = false;
		for (const TransitionEvent &e : early) {
			rejected_terrain = rejected_terrain || (e.kind == TransitionEventKind::PAD_REJECTED && e.pad_id == 22 &&
															  e.reason == TransitionReason::SURFACE_MISMATCH);
		}
		CHECK(rejected_terrain, "terrain pad with matching X/Z region rejected: SURFACE_MISMATCH");
		CHECK(j.pads().size() == 1 && j.pads()[0].pad.pad_id == 21, "only the cloud pad remains");
		run_until(sim, j, body, run, 90.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
		print_events(run);
		CHECK(j.status() == JourneyStatus::ARRIVED, "arrived on the cloud");
		CHECK(std::fabs(body.s.root.y - 30.0f) < 0.05f && body.s.support_surface_id == 77 && body.s.supported,
				"standing on surface 77 at cloud height");
		CHECK(hlen(vsub(body.s.root, v3(50, 30, 2))) <= 0.3f, "walked to the cloud door");
	}
	{
		// Live collision says the pad stands on another surface (78): never certified, never landed.
		Sim sim;
		cloud_sim(sim, 78);
		AirJourney j(AirActorKey{2, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(in, body.s, sim.world, sim.now) == TransitionReason::NONE, "proposal accepted for planning");
		run_until(sim, j, body, run, 90.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
		CHECK(run.count_reason(TransitionEventKind::PAD_REJECTED, TransitionReason::SURFACE_MISMATCH) >= 1,
				"live support with the wrong surface id rejects the pad");
		CHECK(j.status() == JourneyStatus::FAILED && !body.s.supported && j.mode() == JourneyMode::AIR,
				"never landed on the wrong surface; failure exposed while airborne");
	}
	// Same X/Z, wrong height is not arrival; right height but another surface is not either.
	TransitionActorState under;
	under.root = v3(48, 0, 0);
	under.supported = true;
	under.support_surface_id = 1;
	CHECK(air_landed_check(under, v3(48, 30, 0), 77, 0.35f, 0.18f, 1.0f) == TransitionReason::WRONG_HEIGHT,
			"on the terrain under the cloud pad: WRONG_HEIGHT");
	TransitionActorState other = under;
	other.root = v3(48, 30, 0);
	other.support_surface_id = 78;
	CHECK(air_landed_check(other, v3(48, 30, 0), 77, 0.35f, 0.18f, 1.0f) == TransitionReason::SURFACE_MISMATCH,
			"cloud height on another surface: SURFACE_MISMATCH");
	other.support_surface_id = 77;
	CHECK(air_landed_check(other, v3(48, 30, 0), 77, 0.35f, 0.18f, 1.0f) == TransitionReason::NONE,
			"cloud height on surface 77: landed");
	other.velocity = v3(0, 0, -2.0f);
	CHECK(air_landed_check(other, v3(48, 30, 0), 77, 0.35f, 0.18f, 1.0f) == TransitionReason::TOUCHDOWN_TOO_FAST,
			"too fast is not landed");
}

void test_hover_not_landed() {
	section("hovering over the pad is not landed; hover goals use 3D distance");
	{
		Sim sim;
		sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
		AirJourney j(AirActorKey{1, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(land_at(v3(50, 0, 0)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
		bool hovering_seen = false;
		bool ground_while_hovering = false;
		run_until(sim, j, body, run, 60.0, [&]() { return run.count(TransitionEventKind::GO_AROUND) > 0; }, [&]() {
			if (j.mode() == JourneyMode::LANDING) {
				body.hover_floor = 0.5f; // something keeps her half a metre above the pad
			}
			if (j.mode() == JourneyMode::LANDING && hlen(vsub(body.s.root, v3(50, 0, 0))) < 0.3f) {
				hovering_seen = hovering_seen || run.last.reason == TransitionReason::NOT_SUPPORTED;
			}
			ground_while_hovering = ground_while_hovering || (body.hover_floor > 0.0f && j.mode() == JourneyMode::GROUND);
		});
		CHECK(hovering_seen, "directly above the pad the command says NOT_SUPPORTED");
		CHECK(!ground_while_hovering && j.status() == JourneyStatus::ACTIVE && run.count(TransitionEventKind::ARRIVED) == 0,
				"hovering above the pad never became GROUND or ARRIVED");
		CHECK(run.count_reason(TransitionEventKind::GO_AROUND, TransitionReason::LANDING_TIMEOUT) == 1,
				"no touchdown within the limit: go-around (LANDING_TIMEOUT)");
	}
	{
		Sim sim;
		JourneyIntent in;
		in.terminal = JourneyTerminal::HOVER;
		in.destination = v3(20, 12, 0);
		in.arrival_radius = 0.5f;
		AirJourney j(AirActorKey{3, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(in, body.s, sim.world, sim.now) == TransitionReason::NONE, "hover begin");
		run_until(sim, j, body, run, 60.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
		CHECK(j.status() == JourneyStatus::ARRIVED && j.mode() == JourneyMode::AIR && j.owner() == MotionOwner::AIR,
				"hover arrival stays in AIR, owned by flight");
		CHECK(vlen(vsub(body.s.root, v3(20, 12, 0))) <= 0.5f && !body.s.supported, "at the XYZ point, not supported");
		// Same X/Z, 12 m higher: a different goal.
		JourneyIntent up = in;
		up.generation = 2;
		up.destination = v3(20, 24, 0);
		Run run2;
		CHECK(j.begin(up, body.s, sim.world, sim.now) == TransitionReason::NONE, "airborne begin for a higher hover");
		CHECK(j.status() == JourneyStatus::ACTIVE, "matching X/Z at the wrong height is not arrival");
		run_until(sim, j, body, run2, 60.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
		CHECK(j.status() == JourneyStatus::ARRIVED && std::fabs(body.s.root.y - 24.0f) <= 0.5f,
				"arrives only at the requested height");
		CHECK(owner_changes(run2) == 0, "re-targeting in the air changes no ownership");
	}
}

void test_reservations() {
	section("reservations: stable priority, waiting-age fairness, no barging, timeouts, release");
	const AirCylinder pad_a{v3(0, 0, 0), 2.0f, 3.0f};
	auto req = [](uint32_t slot, const AirCylinder &c, int32_t prio) {
		ReservationRequest r;
		r.actor = AirActorKey{slot, 1};
		r.kind = ReservationKind::LANDING;
		r.resource_id = 1;
		r.volume = c;
		r.priority = prio;
		return r;
	};
	{
		ReservationTable t;
		const uint64_t a = t.request(req(1, pad_a, 0), 0.0);
		t.update(0.0);
		CHECK(t.held(a), "first request granted");
		const uint64_t b = t.request(req(2, pad_a, 0), 0.1);
		const uint64_t c = t.request(req(3, pad_a, 5), 0.2);
		const uint64_t big = t.request(req(4, pad_a, 100), 0.3);
		t.update(0.4);
		CHECK(t.held(a) && !t.held(c) && !t.held(big), "stable: a holder is never pre-empted by higher priority");
		t.release(big, ReservationEnd::CANCELLED, 0.5);
		t.release(a, ReservationEnd::RELEASED, 1.0);
		t.renew(b, 1.0);
		t.renew(c, 1.0);
		t.update(1.0);
		CHECK(t.held(c) && !t.held(b), "on release the higher priority waiter wins");
		t.release(c, ReservationEnd::RELEASED, 1.1);
		// B (priority 0) has waited since 0.1; E (priority 1) arrives at 20.
		const uint64_t e = t.request(req(5, pad_a, 1), 20.0);
		for (double now = 1.2; now < 20.0; now += 1.0) {
			t.renew(b, now);
		}
		t.renew(b, 21.0);
		t.renew(e, 21.0);
		t.update(21.0);
		CHECK(t.held(b) && !t.held(e), "waiting-age fairness: a long wait outranks a small priority edge");
		CHECK(t.state(e) == ReservationState::WAITING, "the newcomer waits");
	}
	{
		// No barging: X needs a volume covering pads 1 and 2; Y wants only pad 2.
		ReservationTable t;
		const AirCylinder p1{v3(0, 0, 0), 1.0f, 3.0f}, p2{v3(3, 0, 0), 1.0f, 3.0f}, both{v3(1.5f, 0, 0), 2.6f, 3.0f};
		const uint64_t a = t.request(req(1, p1, 0), 0.0);
		t.update(0.0);
		const uint64_t x = t.request(req(2, both, 0), 1.0);
		const uint64_t y = t.request(req(3, p2, 0), 2.0);
		t.update(2.0);
		CHECK(t.held(a) && !t.held(x) && !t.held(y), "a younger request does not slip past an older conflicting waiter");
		t.release(a, ReservationEnd::RELEASED, 3.0);
		t.renew(x, 3.0);
		t.renew(y, 3.0);
		t.update(3.0);
		CHECK(t.held(x) && !t.held(y), "the older waiter gets the space first");
		uint64_t who = 0;
		CHECK(t.conflicts(p2, AirActorKey{9, 1}, &who) && who == x, "ground keep-out query sees the granted volume");
		CHECK(!t.conflicts(p2, AirActorKey{2, 1}), "an actor never conflicts with itself");
	}
	{
		// Same-tick order independence: lower actor key breaks the tie whatever the call order.
		ReservationTable t1, t2;
		const uint64_t a1 = t1.request(req(5, pad_a, 0), 0.0);
		const uint64_t b1 = t1.request(req(3, pad_a, 0), 0.0);
		const uint64_t b2 = t2.request(req(3, pad_a, 0), 0.0);
		const uint64_t a2 = t2.request(req(5, pad_a, 0), 0.0);
		t1.update(0.0);
		t2.update(0.0);
		CHECK(t1.held(b1) && !t1.held(a1) && t2.held(b2) && !t2.held(a2), "tie broken by actor key, not call order");
	}
	{
		ReservationTable t;
		const uint64_t a = t.request(req(1, pad_a, 0), 0.0);
		const uint64_t b = t.request(req(2, pad_a, 0), 0.0);
		t.update(0.0);
		for (double now = 0.5; now <= 3.0; now += 0.5) {
			t.renew(b, now); // A stops renewing (stuck or forgotten)
			t.update(now);
		}
		CHECK(t.state(a) == ReservationState::ENDED && t.end_reason(a) == ReservationEnd::LEASE_EXPIRED,
				"lease timeout ends an unrenewed holder");
		CHECK(t.held(b), "the waiter gets the pad after the lease timeout");
		ReservationRequest limited = req(3, pad_a, 0);
		limited.max_wait = 1.0;
		const uint64_t c = t.request(limited, 3.0);
		t.renew(c, 4.5);
		t.renew(b, 4.5);
		t.update(4.5);
		CHECK(t.end_reason(c) == ReservationEnd::WAIT_LIMIT, "max_wait ends a waiter");
		t.release(b, ReservationEnd::RELEASED, 4.6);
		ReservationRequest hold = req(4, pad_a, 0);
		hold.max_hold = 1.0;
		const uint64_t d = t.request(hold, 5.0);
		t.update(5.0);
		t.renew(d, 6.5);
		t.update(6.5);
		CHECK(t.end_reason(d) == ReservationEnd::HOLD_LIMIT, "max_hold ends a holder");
		t.update(6.5 + t.policy().ended_retention + 1.0);
		CHECK(t.state(d) == ReservationState::NONE, "ended tickets are pruned after the retention time");
	}
	{
		ReservationTable t;
		ReservationRequest dep = req(1, AirCylinder{v3(0, 0, 0), 1.25f, 6.0f}, 0);
		dep.kind = ReservationKind::DEPARTURE;
		const uint64_t a = t.request(dep, 0.0);
		const uint64_t b = t.request(req(1, pad_a, 0), 0.0);
		const uint64_t other = t.request(req(2, pad_a, 0), 0.0);
		t.update(0.0);
		CHECK(t.held(a) && t.held(b) && !t.held(other), "one actor's own volumes never conflict with each other");
		CHECK(t.release_actor(AirActorKey{1, 1}, ReservationEnd::DESPAWNED, 0.1) == 2, "despawn releases both tickets");
		CHECK(t.end_reason(a) == ReservationEnd::DESPAWNED && t.end_reason(b) == ReservationEnd::DESPAWNED, "reason DESPAWNED");
		t.renew(other, 0.2);
		t.update(0.2);
		CHECK(t.held(other), "the next waiter is granted on the next update");
		CHECK(t.request(req(7, AirCylinder{v3(0, 0, 0), 0.0f, 1.0f}, 0), 0.0) == 0, "degenerate volume refused");
	}
}

void test_journey_despawn_and_queue() {
	section("two flyers, one pad: the second waits its turn; despawn releases the pad");
	Sim sim;
	sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
	AirJourney j1(AirActorKey{1, 1}, pegasus());
	AirJourney j2(AirActorKey{2, 1}, pegasus());
	Body b1(v3(0, 0, 0));
	b1.key = AirActorKey{1, 1};
	Body b2(v3(0, 0, 12));
	b2.key = AirActorKey{2, 1};
	CHECK(j1.begin(land_at(v3(54, 0, 0)), b1.s, sim.world, sim.now) == TransitionReason::NONE, "flyer 1 begins");
	CHECK(j2.begin(land_at(v3(50, 0, -4)), b2.s, sim.world, sim.now) == TransitionReason::NONE, "flyer 2 begins");
	Run r1, r2;
	bool second_waited = false;
	bool both_on_pad = false;
	for (int i = 0; i < 4000; ++i) {
		sim.support.bodies.clear();
		sim.support.bodies.push_back(FakeBody{b1.cylinder(), b1.key.packed()});
		sim.support.bodies.push_back(FakeBody{b2.cylinder(), b2.key.packed()});
		sim.table.update(sim.now);
		TransitionCommand c1, c2;
		j1.step(b1.s, sim.world, sim.now, sim.dt, c1);
		j2.step(b2.s, sim.world, sim.now, sim.dt, c2);
		apply(sim, b1, c1);
		apply(sim, b2, c2);
		for (const TransitionEvent &e : j1.take_events()) r1.events.push_back(e);
		for (const TransitionEvent &e : j2.take_events()) r2.events.push_back(e);
		if (c2.valid && c2.kind == CommandKind::HOLD &&
				(c2.reason == TransitionReason::PAD_RESERVATION_WAIT || c2.reason == TransitionReason::ALL_PADS_BLOCKED)) {
			second_waited = true;
		}
		const bool on1 = b1.s.supported && hlen(vsub(b1.s.root, v3(50, 0, 0))) < 0.9f;
		const bool on2 = b2.s.supported && hlen(vsub(b2.s.root, v3(50, 0, 0))) < 0.9f;
		both_on_pad = both_on_pad || (on1 && on2);
		sim.now += sim.dt;
		if (j1.status() != JourneyStatus::ACTIVE && j2.status() != JourneyStatus::ACTIVE) {
			break;
		}
	}
	std::printf("  flyer 2 events:\n");
	print_events(r2);
	CHECK(j1.status() == JourneyStatus::ARRIVED && j2.status() == JourneyStatus::ARRIVED, "both arrive");
	CHECK(second_waited, "the later flyer held in the air while the pad was reserved or occupied");
	CHECK(!both_on_pad, "never two bodies on the pad");
	CHECK(sim.table.live_count() == 0, "all reservations released");

	// Despawn mid-flight releases the landing reservation and the waiter gets it.
	Sim s2;
	s2.support.pads.push_back(pad(11, v3(50, 0, 0)));
	AirJourney a(AirActorKey{1, 1}, pegasus());
	Body ba(v3(0, 0, 0));
	Run ra;
	CHECK(a.begin(land_at(v3(50, 0, 0)), ba.s, s2.world, s2.now) == TransitionReason::NONE, "flyer begins");
	run_until(s2, a, ba, ra, 60.0, [&]() { return a.landing_ticket() != 0 && s2.table.held(a.landing_ticket()); });
	const uint64_t ticket = a.landing_ticket();
	CHECK(ticket != 0 && s2.table.held(ticket), "landing reservation held in flight");
	ReservationRequest waiter;
	waiter.actor = AirActorKey{8, 1};
	waiter.volume = AirCylinder{v3(50, 0, 0), 1.0f, 3.0f};
	const uint64_t w = s2.table.request(waiter, s2.now);
	s2.table.update(s2.now);
	CHECK(!s2.table.held(w), "another flyer waits for the pad");
	a.despawn(s2.world, s2.now);
	CHECK(s2.table.end_reason(ticket) == ReservationEnd::DESPAWNED, "despawn released the landing ticket");
	s2.table.renew(w, s2.now + 0.05);
	s2.table.update(s2.now + 0.05);
	CHECK(s2.table.held(w), "the waiter is granted on the next update");
	TransitionCommand cmd;
	a.step(ba.s, s2.world, s2.now, s2.dt, cmd);
	CHECK(!cmd.valid && a.owner() == MotionOwner::NONE, "a despawned journey writes nothing");
}

void test_roof() {
	section("takeoff volume blocked by a roof");
	{
		Sim sim;
		sim.add_solid(box(-12, 2.6f, -12, 12, 3.0f, 12), 5, AIR_SURFACE_ROOF); // roof over the whole search area
		sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
		AirJourney j(AirActorKey{1, 1}, pegasus());
		Body body(v3(0, 0, 0));
		const TransitionReason r = j.begin(land_at(v3(53, 0, 0)), body.s, sim.world, sim.now);
		CHECK(r == TransitionReason::TAKEOFF_VOLUME_BLOCKED, "no certified departure column: TAKEOFF_VOLUME_BLOCKED");
		CHECK(sim.table.live_count() == 0 && sim.planner.requests() == 0 && j.owner() == MotionOwner::NONE,
				"refused before reserving or planning");
	}
	{
		// A durable blocker appears in the column during the climb: she stops climbing, then resumes.
		Sim sim;
		sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
		AirJourney j(AirActorKey{1, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(land_at(v3(53, 0, 0)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
		run_until(sim, j, body, run, 20.0, [&]() { return j.mode() == JourneyMode::TAKEOFF; });
		const Vec3 top = j.departure_top();
		const uint32_t id = sim.overlay.add(box(top.x - 0.5f, top.y + 0.3f, top.z - 0.5f, top.x + 0.5f, top.y + 1.0f, top.z + 0.5f));
		Run blocked;
		run_until(sim, j, body, blocked, 2.0);
		CHECK(blocked.last.kind == CommandKind::BRAKE && blocked.last.reason == TransitionReason::TAKEOFF_VOLUME_BLOCKED,
				"column blocked mid-climb: brake with TAKEOFF_VOLUME_BLOCKED");
		CHECK(j.mode() == JourneyMode::TAKEOFF && body.s.root.y < top.y, "stays in TAKEOFF below the top, never pushed through");
		sim.overlay.remove(id);
		run_until(sim, j, body, blocked, 90.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
		CHECK(j.status() == JourneyStatus::ARRIVED, "resumes after the blocker leaves and arrives");
	}
}

void test_traffic() {
	section("mixed traffic: predicted ground ponies at takeoff and landing");
	{
		Sim sim;
		sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
		AirJourney j(AirActorKey{1, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		PredictedCapsule walker;
		walker.actor = 77;
		walker.base = v3(4, 0, 0);
		walker.velocity = v3(-1, 0, 0);
		sim.traffic.push_back(walker);
		CHECK(j.begin(land_at(v3(53, 0, 0)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
		bool waited = false;
		bool took_off_in_conflict = false;
		run_until(sim, j, body, run, 60.0, [&]() { return j.mode() == JourneyMode::AIR; }, [&]() {
			sim.traffic[0].base.x += sim.traffic[0].velocity.x * sim.dt; // she walks past
			if (run.last.valid && run.last.reason == TransitionReason::GROUND_TRAFFIC && j.mode() == JourneyMode::GROUND) {
				waited = true;
			}
			if (j.mode() == JourneyMode::TAKEOFF && run.modes.back() == JourneyMode::GROUND) {
				const float x = sim.traffic[0].base.x;
				took_off_in_conflict = x > -1.7f; // still inside volume radius + capsule radius
			}
		});
		CHECK(waited, "waits on the ground (GROUND owner) while a pony is predicted through the departure volume");
		CHECK(!took_off_in_conflict, "takes off only after the walker cleared the volume");
		CHECK(owner_changes(run) == 2, "the wait changed no ownership (begin + takeoff only)");
	}
	{
		// A pony is predicted onto pad 11 only once the glide has started: the live certification at
		// C sees it, she goes around, and lands on pad 12 instead.
		Sim sim;
		sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
		sim.support.pads.push_back(pad(12, v3(50, 0, 9)));
		AirJourney j(AirActorKey{1, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(land_at(v3(50, 0, 4)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
		bool touched_11 = false;
		run_until(sim, j, body, run, 120.0, [&]() { return j.status() != JourneyStatus::ACTIVE; }, [&]() {
			if (sim.traffic.empty() && j.mode() == JourneyMode::APPROACH) {
				PredictedCapsule loiter;
				loiter.actor = 78;
				loiter.base = v3(53, 0, 0);
				loiter.velocity = v3(-0.5f, 0, 0); // walking onto pad 11
				sim.traffic.push_back(loiter);
			}
			touched_11 = touched_11 || (body.s.supported && hlen(vsub(body.s.root, v3(50, 0, 0))) < 0.5f);
		});
		print_events(run);
		CHECK(run.count_reason(TransitionEventKind::GO_AROUND, TransitionReason::GROUND_TRAFFIC) == 1,
				"live landing certification saw the predicted pony: one go-around");
		CHECK(!touched_11, "never touched down on pad 11");
		CHECK(j.status() == JourneyStatus::ARRIVED && hlen(vsub(body.s.root, v3(50, 0, 4))) <= 0.3f,
				"landed on pad 12 and walked on");
	}
	{
		// Already predicted onto pad 11 when she reaches its approach entry: no approach is started.
		Sim sim;
		sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
		sim.support.pads.push_back(pad(12, v3(50, 0, 9)));
		PredictedCapsule loiter;
		loiter.actor = 78;
		loiter.base = v3(53, 0, 0);
		loiter.velocity = v3(-0.5f, 0, 0);
		sim.traffic.push_back(loiter);
		AirJourney j(AirActorKey{1, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(land_at(v3(50, 0, 4)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
		run_until(sim, j, body, run, 120.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
		CHECK(run.count_reason(TransitionEventKind::PAD_REJECTED, TransitionReason::GROUND_TRAFFIC) >= 1,
				"pad 11 rejected at its approach entry for predicted traffic");
		CHECK(run.count(TransitionEventKind::GO_AROUND) == 0, "no approach was started toward the conflict");
		CHECK(j.status() == JourneyStatus::ARRIVED && hlen(vsub(body.s.root, v3(50, 0, 4))) <= 0.3f,
				"landed on pad 12 and walked on");
	}
}

void test_manoeuvres() {
	section("loops: explicit, certified, never in commanded travel");
	{
		Sim sim;
		JourneyIntent in;
		in.terminal = JourneyTerminal::HOVER;
		in.destination = v3(20, 12, 0);
		in.arrival_radius = 0.5f;
		AirJourney j(AirActorKey{1, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(in, body.s, sim.world, sim.now) == TransitionReason::NONE, "commanded hover begins");
		run_until(sim, j, body, run, 60.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
		ManoeuvreRequest loop;
		CHECK(j.request_manoeuvre(loop, body.s, sim.world, sim.now) == TransitionReason::MANOEUVRE_NOT_ALLOWED,
				"a loop is refused during commanded travel");
	}
	{
		Sim sim;
		JourneyIntent in;
		in.terminal = JourneyTerminal::HOVER;
		in.purpose = JourneyPurpose::LEISURE;
		in.destination = v3(20, 12, 0);
		in.arrival_radius = 0.5f;
		AirJourney j(AirActorKey{1, 1}, pegasus());
		Body body(v3(0, 0, 0));
		Run run;
		CHECK(j.begin(in, body.s, sim.world, sim.now) == TransitionReason::NONE, "joyride begins");
		CHECK(j.request_manoeuvre(ManoeuvreRequest(), body.s, sim.world, sim.now) == TransitionReason::MANOEUVRE_BUSY,
				"no loop while still on the ground");
		run_until(sim, j, body, run, 60.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
		CHECK(run.count(TransitionEventKind::MANOEUVRE_STARTED) == 0, "nothing inserted on its own");
		body.s.yaw = -1.5707963f; // facing +X
		const uint32_t id = sim.overlay.add(box(22, 13, -0.5f, 23, 14, 0.5f));
		CHECK(j.request_manoeuvre(ManoeuvreRequest(), body.s, sim.world, sim.now) == TransitionReason::MANOEUVRE_VOLUME_BLOCKED,
				"a blocker inside the loop circle refuses it");
		sim.overlay.remove(id);
		ManoeuvreRequest loop;
		CHECK(j.request_manoeuvre(loop, body.s, sim.world, sim.now) == TransitionReason::NONE, "certified loop accepted");
		float top = -1.0e9f, ahead = -1.0e9f;
		Run looped;
		run_until(sim, j, body, looped, 20.0, [&]() { return looped.count(TransitionEventKind::MANOEUVRE_DONE) > 0; }, [&]() {
			top = std::max(top, body.s.root.y);
			ahead = std::max(ahead, body.s.root.x);
		});
		CHECK(looped.count(TransitionEventKind::MANOEUVRE_DONE) == 1, "loop completed");
		CHECK(top >= 12.0f + 5.0f && ahead >= 20.0f + 2.0f, "she actually flew the vertical circle ahead of her");
		run_until(sim, j, body, looped, 5.0);
		CHECK(j.status() == JourneyStatus::ARRIVED && j.air_phase() == AirPhase::HOVER &&
						vlen(vsub(body.s.root, v3(20, 12, 0))) <= 0.6f,
				"back to hovering at the goal");
	}
}

void test_provisional_pad() {
	section("a heightmap guess is only a proposed pad");
	Sim sim;
	FakeBox guess;
	guess.box = box(44, -1, -4, 56, 0.01f, 4); // terrain known only from the heightmap here
	guess.live = false;
	guess.solid = false;
	sim.support.boxes.push_back(guess);
	sim.support.pads.push_back(pad(31, v3(50, 0.01f, 0), 1, AIR_PAD_PROVISIONAL));
	sim.support.pads.push_back(pad(32, v3(50, 0, 9)));
	AirJourney j(AirActorKey{1, 1}, pegasus());
	Body body(v3(0, 0, 0));
	Run run;
	CHECK(j.begin(land_at(v3(50, 0, 6)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
	run_until(sim, j, body, run, 90.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
	CHECK(run.count_reason(TransitionEventKind::PAD_REJECTED, TransitionReason::PROVISIONAL_SUPPORT) >= 1,
			"no live support at the guessed pad: PROVISIONAL_SUPPORT");
	CHECK(j.status() == JourneyStatus::ARRIVED && hlen(vsub(body.s.root, v3(50, 0, 6))) <= 0.3f,
			"landed on the live pad instead");
}

void test_interrupt() {
	section("interruption: one owner at a time, resume from the real state");
	Sim sim;
	sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
	AirJourney j(AirActorKey{1, 1}, pegasus());
	Body body(v3(0, 0, 0));
	Run run;
	CHECK(j.begin(land_at(v3(50, 0, 0)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
	run_until(sim, j, body, run, 60.0, [&]() { return j.mode() == JourneyMode::AIR && body.s.root.x > 10.0f; });
	const uint32_t epoch = j.ownership_epoch();
	j.interrupt(sim.world, sim.now);
	CHECK(j.owner() == MotionOwner::EXTERNAL && j.ownership_epoch() == epoch + 1, "grab: owner EXTERNAL, one change");
	CHECK(sim.table.live_count() == 0, "grab released the reservations");
	TransitionCommand cmd;
	j.step(body.s, sim.world, sim.now, sim.dt, cmd);
	CHECK(!cmd.valid, "no journey writes while held");
	body.s.root = v3(14, 9, 3); // the player carried her and let go in the air
	body.s.velocity = v3(0, 0, 0);
	CHECK(j.resume(body.s, sim.world, sim.now) == TransitionReason::NONE, "resume");
	CHECK(j.owner() == MotionOwner::AIR && j.ownership_epoch() == epoch + 2 && j.mode() == JourneyMode::AIR,
			"released in the air: flight owns her again, one change");
	run_until(sim, j, body, run, 90.0, [&]() { return j.status() != JourneyStatus::ACTIVE; });
	CHECK(j.status() == JourneyStatus::ARRIVED && hlen(vsub(body.s.root, v3(50, 0, 0))) <= 0.35f, "still lands at the pad");
}

void test_corridor_blocked() {
	section("durable blocker on the route mid-flight: certified hold, replan, arrive");
	Sim sim;
	sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
	AirJourney j(AirActorKey{1, 1}, pegasus());
	Body body(v3(0, 0, 0));
	Run run;
	CHECK(j.begin(land_at(v3(50, 0, 0)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
	run_until(sim, j, body, run, 30.0, [&]() { return j.mode() == JourneyMode::AIR; });
	// A durable blocker (already inflated) across the straight route, beyond braking distance.
	const Aabb wall = box(13, 0, -6, 15, 16, 6);
	sim.overlay.add(wall);
	bool inside = false;
	run_until(sim, j, body, run, 90.0, [&]() { return j.status() != JourneyStatus::ACTIVE; }, [&]() {
		const Vec3 c = v3(body.s.root.x, body.s.root.y + pegasus().body.centre_height, body.s.root.z);
		inside = inside || (c.x > wall.min.x && c.x < wall.max.x && c.y > wall.min.y && c.y < wall.max.y &&
								   c.z > wall.min.z && c.z < wall.max.z);
	});
	print_events(run);
	CHECK(run.count_reason(TransitionEventKind::HOLDING, TransitionReason::CORRIDOR_BLOCKED) >= 1,
			"the blocked corridor was noticed and she held");
	CHECK(sim.planner.requests() >= 2, "a new route was planned");
	CHECK(!inside, "her body centre never entered the blocker");
	CHECK(j.status() == JourneyStatus::ARRIVED, "arrived around it");
	CHECK(run.max_step <= 21.0f * sim.dt, "no teleport");
}

void test_retarget_in_flare() {
	section("new intent during the flare: climb out along the cone, then fly on (no drop)");
	Sim sim;
	sim.support.pads.push_back(pad(11, v3(50, 0, 0)));
	AirJourney j(AirActorKey{1, 1}, pegasus());
	Body body(v3(0, 0, 0));
	Run run;
	CHECK(j.begin(land_at(v3(50, 0, 0)), body.s, sim.world, sim.now) == TransitionReason::NONE, "begin");
	run_until(sim, j, body, run, 60.0, [&]() { return j.mode() == JourneyMode::LANDING && body.s.root.y < 1.2f; });
	CHECK(j.mode() == JourneyMode::LANDING, "reached the flare");
	const float low = body.s.root.y;
	JourneyIntent in;
	in.generation = 2;
	in.terminal = JourneyTerminal::HOVER;
	in.destination = v3(30, 14, 10);
	in.arrival_radius = 0.5f;
	CHECK(j.begin(in, body.s, sim.world, sim.now) == TransitionReason::NONE, "re-targeted in the flare");
	CHECK(j.mode() == JourneyMode::AIR && j.air_phase() == AirPhase::GO_AROUND && j.ownership_epoch() == 2,
			"climbing out (AIR), no ownership change");
	CHECK(sim.table.live_count() == 0, "the pad reservation was released");
	float min_y = 1.0e9f;
	Run after;
	run_until(sim, j, body, after, 60.0, [&]() { return j.status() != JourneyStatus::ACTIVE; },
			[&]() { min_y = std::min(min_y, body.s.root.y); });
	CHECK(min_y >= low - 0.15f, "never sank below where the flare was interrupted");
	CHECK(j.status() == JourneyStatus::ARRIVED && vlen(vsub(body.s.root, v3(30, 14, 10))) <= 0.5f, "hovering at the new goal");
	CHECK(owner_changes(after) == 0, "no ownership change on the way");
}

void test_helpers() {
	section("helpers: traffic prediction, pursuit limits");
	std::vector<PredictedCapsule> t(1);
	t[0].actor = 5;
	t[0].base = v3(10, 0, 0);
	t[0].velocity = v3(-2, 0, 0);
	const AirCylinder vol{v3(0, 0, 0), 1.0f, 3.0f};
	CHECK(!air_traffic_conflict(t, vol, 3.0f, 0), "10 m away at 2 m/s: no conflict within 3 s");
	CHECK(air_traffic_conflict(t, vol, 5.0f, 0), "within 5 s: conflict");
	CHECK(!air_traffic_conflict(t, vol, 5.0f, 5), "own capsule ignored");
	t[0].base = v3(10, 5, 0);
	CHECK(!air_traffic_conflict(t, vol, 5.0f, 0), "passing above the volume: no conflict");
	AirFlightLimits lim;
	const std::vector<Vec3> path{v3(0, 0, 0), v3(0, -100, 1)};
	const Vec3 v = air_transition_pursuit(v3(0, 0, 0), v3(0, -lim.max_descent_rate, 0), path, 50.0f, 0.0f, lim, 0.05f);
	CHECK(-v.y <= lim.max_descent_rate + 1.0e-4f, "pursuit never exceeds the descent limit");
	const Vec3 w = air_transition_pursuit(v3(0, 0, 0), v3(0, 0, 0), std::vector<Vec3>{v3(100, 0, 0)}, 50.0f, 0.0f, lim, 0.05f);
	CHECK(vlen(w) <= lim.max_accel * 0.05f + 1.0e-4f, "pursuit respects acceleration from rest");
}

} // namespace

int main(int argc, char **argv) {
	trace = argc > 1 && std::string(argv[1]) == "trace";
	test_capabilities();
	test_sequence();
	test_pad_blocked_mid_approach();
	test_all_pads_blocked();
	test_cloud();
	test_hover_not_landed();
	test_reservations();
	test_journey_despawn_and_queue();
	test_roof();
	test_traffic();
	test_manoeuvres();
	test_provisional_pad();
	test_interrupt();
	test_corridor_blocked();
	test_retarget_in_flare();
	test_helpers();
	std::printf("AIR_TRANSITIONS_TESTS %s (%d checks, %d failures)\n", failures == 0 ? "PASS" : "FAIL", checks, failures);
	return failures == 0 ? 0 : 1;
}
