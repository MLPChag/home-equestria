// PonyWanderJob: one native wander search (navigation_wander.h) run on Godot's WorkerThreadPool
// (dev 2026-10-20 multithreading). Created by PonyNavigationNative.wander_job(world, profile,
// params) on the main thread, which also takes the world's immutable snapshot for it.
//
// Ownership and synchronisation (no other shared state):
// - State is shared by this object and the pool task through std::shared_ptr; the task holds
//   its own reference, so freeing the job early never leaves the task with a dangling pointer.
// - Between start() and completion only the task writes `output`. The main thread reads it only
//   after is_done() saw WorkerThreadPool::is_task_completed() and waited the task; the pool's
//   task mutex orders those writes before the read.
// - `cancel` is the one value both sides touch while the task runs (std::atomic).
// - The snapshot is immutable; the clearance cache is thread safe (navigation_world.h).
// Tasks are low priority: the engine caps those at threading/worker_pool/low_priority_thread_ratio
// of the pool, so searches never hold the threads that frame work (culling, physics) waits on.
#pragma once

#include "navigation_wander.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <atomic>
#include <memory>

namespace godot {

class PonyWanderJob : public RefCounted {
	GDCLASS(PonyWanderJob, RefCounted)

public:
	struct State {
		std::shared_ptr<const ponynav::Snapshot> snapshot;
		std::shared_ptr<ponynav::ClearanceCache> cache;
		ponynav::GroundProfile profile;
		ponynav::WanderParams params;
		ponynav::WanderOutput output;
		std::atomic<bool> cancel{ false };
		bool ran = false;
	};

private:
	std::shared_ptr<State> state;
	int64_t task = -1;
	static void run_task(void *p_userdata);
	static void execute(State &p_state);

protected:
	static void _bind_methods();

public:
	PonyWanderJob();
	~PonyWanderJob();

	// Main thread, before start(): the snapshot, cache and inputs (PonyNavigationNative).
	void configure(std::shared_ptr<const ponynav::Snapshot> p_snapshot, std::shared_ptr<ponynav::ClearanceCache> p_cache,
			const ponynav::GroundProfile &p_profile, const Dictionary &p_params);

	// Queues the search as one low-priority WorkerThreadPool task. False when already started.
	bool start();
	// Runs the search on the calling thread (fixtures). False when already started.
	bool run_now();
	// Asks a running search to stop at its next 128-cell check.
	void cancel();
	// Main thread: true once the result is readable (collects a finished pool task).
	bool is_done();
	// Main thread: blocks until a started search ends (zone unload after cancel()).
	void wait();
	// WalkPlanner.wander()'s answer: Vector3.INF when no destination was chosen.
	Vector3 destination();
	Dictionary diagnostics();
};

} // namespace godot
