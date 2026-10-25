// PonyNavigationNative: native pony navigation (docs/NAVIGATION_PHASE_1_2026_10_02.md and
// docs/NAVIGATION_OVERHAUL_COMPLETE_2026_10_02.txt). Registered beside PonySolverNative; it
// shares no state with the pose solver. This class only converts Godot values; the work is in
// navigation_world (storage), navigation_ground (search) and navigation_jobs (actors, intents,
// worker scheduling), which are plain C++ and also build into the standalone tests.
#pragma once

#include "navigation_jobs.h"
#include "pony_wander_job.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <memory>

namespace godot {

class PonyNavigationNative : public RefCounted {
	GDCLASS(PonyNavigationNative, RefCounted)

	std::unique_ptr<ponynav::NavigationService> service;
	// Last step_batch outputs, reused between calls.
	std::vector<float> batch_commands;
	std::vector<float> batch_state_rows;
	std::vector<ponynav::Vec3f> batch_preferred_rows;
	std::vector<ponynav::Vec3f> batch_positions;
	std::vector<ponynav::Vec3f> batch_velocities;

protected:
	static void _bind_methods();

public:
	enum Status {
		STATUS_PENDING = 0,
		STATUS_COMPLETE = 1,
		STATUS_PARTIAL = 2,
		STATUS_WAITING_FOR_GEOMETRY = 3,
		STATUS_BUDGET_EXHAUSTED = 4,
		STATUS_UNREACHABLE = 5,
		STATUS_CANCELLED = 6,
		STATUS_STALE = 7,
		STATUS_NO_FLOOR = 8,
		STATUS_INVALID = 9,
	};

	// Phase 2 follower: wire format, command modes, reasons and events (navigation_jobs.h).
	enum Follower {
		COMMAND_STRIDE = 4,
		INPUT_STRIDE = 13,
		STATE_STRIDE = 8,
		MODE_STOP = 0,
		MODE_TRAVEL = 1,
		MODE_STEP_TURN = 2,
		MODE_BRAKE = 3,
		MODE_HOLD = 4,
		INPUT_REQUESTED_SPEED = 0,
		INPUT_TERMINAL_SPEED = 1,
		INPUT_FLAGS = 2,
		INPUT_AVOID_VX = 3,
		INPUT_AVOID_VZ = 4,
		INPUT_AVOID_AGE = 5,
		INPUT_WALL_NX = 6,
		INPUT_WALL_NZ = 7,
		INPUT_EXECUTED_SPEED = 8,
		INPUT_EXECUTED_YAW = 9,
		INPUT_REFUSAL = 10,
		INPUT_STEP_SECONDS = 11,
		INPUT_SPEED_SCALE = 12,
		INPUT_FLAG_AVOIDANCE = 1,
		INPUT_FLAG_WALL = 2,
		INPUT_FLAG_ROUTE_PENDING = 4,
		REFUSAL_NONE = 0,
		REFUSAL_SUPPORT = 1,
		REFUSAL_TOUCH = 2,
		REFUSAL_TURN_SUPPORT = 3,
		EVENT_ARRIVED = 1,
		EVENT_REPAIR = 2,
		EVENT_REPLAN = 3,
		EVENT_ALTERNATE = 4,
		EVENT_FAILED = 5,
		EVENT_CORRIDOR_LOST = 6,
	};

	PonyNavigationNative();
	~PonyNavigationNative();

	// Worlds and immutable chunk revisions.
	int64_t create_world();
	bool destroy_world(int64_t p_world);
	int64_t publish_walk_chunk(int64_t p_world, const Vector2i &p_coord, const PackedFloat32Array &p_floor_y,
			const PackedByteArray &p_slope_deg, const PackedFloat32Array &p_water_depth,
			const PackedFloat32Array &p_headroom, const PackedByteArray &p_flags, const PackedByteArray &p_paint_cost,
			const PackedByteArray &p_trail_weight);
	int64_t publish_span_chunk(int64_t p_world, const Vector2i &p_coord, const PackedInt32Array &p_column_offsets,
			const PackedFloat32Array &p_span_floats, const PackedByteArray &p_span_bytes);
	bool remove_chunk(int64_t p_world, const Vector2i &p_coord);
	int64_t chunk_revision(int64_t p_world, const Vector2i &p_coord);
	int64_t chunk_count(int64_t p_world);
	int64_t chunk_span_count(int64_t p_world, const Vector2i &p_coord);

	// Actors and intents.
	PackedInt64Array register_actor(int64_t p_world, const Dictionary &p_profile);
	bool update_actor_profile(int64_t p_slot, int64_t p_generation, const Dictionary &p_profile);
	bool unregister_actor(int64_t p_slot, int64_t p_generation);
	bool is_actor_live(int64_t p_slot, int64_t p_generation);
	int64_t submit_intent(int64_t p_slot, int64_t p_generation, const Dictionary &p_intent);
	bool update_intent_goal(int64_t p_slot, int64_t p_generation, int64_t p_intent_generation, const Vector3 &p_goal,
			const Vector3 &p_from);
	bool cancel_intent(int64_t p_slot, int64_t p_generation, int64_t p_intent_generation);
	Array poll_results();

	// Synchronous search on the calling thread (labs and tests), and read-only queries.
	// One native wander search over the world's current snapshot, not started yet (dev 2026-10-20
	// multithreading): start() runs it on the WorkerThreadPool, run_now() on this thread.
	Ref<PonyWanderJob> wander_job(int64_t p_world, const Dictionary &p_profile, const Dictionary &p_params);
	Dictionary search_now(int64_t p_world, const Dictionary &p_profile, const Vector3 &p_from, const Vector3 &p_to,
			const Dictionary &p_options);
	Dictionary query_cell(int64_t p_world, const Dictionary &p_profile, const Vector3i &p_cell);
	Dictionary chunk_components(int64_t p_world, const Vector2i &p_coord, const Dictionary &p_profile);

	// Scheduling and diagnostics.
	void set_worker_count(int64_t p_count);
	int64_t get_worker_count();
	void set_slice_budget(int64_t p_expansions, int64_t p_microseconds);
	void set_paused(bool p_paused);
	int64_t pending_jobs();
	int64_t queued_jobs();
	int64_t busy_workers();
	Dictionary get_diagnostics();
	void shutdown();
	static String status_name(int64_t p_status);

	// Phase 2 follower (docs/NAVIGATION_PHASE_2_2026_10_02.md).
	bool follow_configure(int64_t p_slot, int64_t p_generation, const Dictionary &p_limits);
	Dictionary follow_set_corridor(int64_t p_slot, int64_t p_generation, const PackedVector3Array &p_points,
			const Dictionary &p_options, const Vector3 &p_position, double p_heading, const Vector3 &p_velocity);
	bool follow_clear(int64_t p_slot, int64_t p_generation);
	PackedFloat32Array step_batch(const PackedInt64Array &p_actor_keys, const PackedVector3Array &p_positions,
			const PackedVector3Array &p_velocities, const PackedFloat32Array &p_headings, double p_delta,
			const PackedFloat32Array &p_inputs);
	PackedFloat32Array batch_state();
	PackedVector3Array batch_preferred_velocities();
	Array take_follow_events();
	Dictionary follow_state(int64_t p_slot, int64_t p_generation);
	Dictionary follow_diagnostics();
	static String reason_name(int64_t p_reason);
	// Pure pursuit in Godot's convention (labs/tests): Vector3(curvature, forward, left).
	static Vector3 pursuit(const Vector3 &p_position, double p_yaw, const Vector3 &p_target);
};

} // namespace godot
