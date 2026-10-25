// PonyWanderJob: see pony_wander_job.h (dev 2026-10-20 multithreading).
#include "pony_wander_job.h"

#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

using namespace godot;

namespace {

ponynav::Vec3f vec(const Vector3 &value) {
	return ponynav::Vec3f(value.x, value.y, value.z);
}

Vector3 vector(const ponynav::Vec3f &value) {
	return Vector3(value.x, value.y, value.z);
}

ponynav::Vec3f vec_or(const Dictionary &values, const char *key, const ponynav::Vec3f &fallback) {
	const Variant value = values.get(key, Variant());
	return value.get_type() == Variant::VECTOR3 ? vec(Vector3(value)) : fallback;
}

} // namespace

void PonyWanderJob::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start"), &PonyWanderJob::start);
	ClassDB::bind_method(D_METHOD("run_now"), &PonyWanderJob::run_now);
	ClassDB::bind_method(D_METHOD("cancel"), &PonyWanderJob::cancel);
	ClassDB::bind_method(D_METHOD("is_done"), &PonyWanderJob::is_done);
	ClassDB::bind_method(D_METHOD("wait"), &PonyWanderJob::wait);
	ClassDB::bind_method(D_METHOD("destination"), &PonyWanderJob::destination);
	ClassDB::bind_method(D_METHOD("diagnostics"), &PonyWanderJob::diagnostics);
}

PonyWanderJob::PonyWanderJob() :
		state(std::make_shared<State>()) {
}

PonyWanderJob::~PonyWanderJob() {
	// The pool keeps a task's bookkeeping until it is waited; a dropped job still waits it
	// (after asking it to stop, so this is at most one 128-cell stretch).
	if (task >= 0) {
		state->cancel.store(true, std::memory_order_relaxed);
		WorkerThreadPool::get_singleton()->wait_for_task_completion(task);
		task = -1;
	}
}

void PonyWanderJob::configure(std::shared_ptr<const ponynav::Snapshot> p_snapshot,
		std::shared_ptr<ponynav::ClearanceCache> p_cache, const ponynav::GroundProfile &p_profile,
		const Dictionary &p_params) {
	ERR_FAIL_COND_MSG(task >= 0 || state->ran, "PonyWanderJob is already running");
	state->snapshot = std::move(p_snapshot);
	state->cache = std::move(p_cache);
	state->profile = p_profile;
	ponynav::WanderParams &params = state->params;
	params.from = vec_or(p_params, "from", params.from);
	params.radius = double(p_params.get("radius", 0.0));
	params.interest = vec_or(p_params, "interest", params.interest);
	params.home = vec_or(p_params, "home", params.home);
	params.leash = double(p_params.get("leash", ponynav::INF));
	params.heading = vec_or(p_params, "heading", ponynav::Vec3f());
	params.seed = uint64_t(int64_t(p_params.get("seed", 0)));
	params.recent.clear();
	const Variant recent = p_params.get("recent", Variant());
	if (recent.get_type() == Variant::PACKED_VECTOR3_ARRAY) {
		const PackedVector3Array points = recent;
		for (int64_t i = 0; i < points.size(); ++i) {
			params.recent.push_back(vec(points[i]));
		}
	} else if (recent.get_type() == Variant::ARRAY) {
		const Array points = recent;
		for (int64_t i = 0; i < points.size(); ++i) {
			if (points[i].get_type() == Variant::VECTOR3) {
				params.recent.push_back(vec(Vector3(points[i])));
			}
		}
	}
}

void PonyWanderJob::execute(State &p_state) {
	if (p_state.snapshot) {
		ponynav::GroundAccess ground(p_state.snapshot, p_state.cache, p_state.profile);
		p_state.output = ponynav::wander(ground, p_state.params, &p_state.cancel);
	} else {
		p_state.output = ponynav::WanderOutput();
		p_state.output.no_floor = true;
	}
}

void PonyWanderJob::run_task(void *p_userdata) {
	std::shared_ptr<State> *held = static_cast<std::shared_ptr<State> *>(p_userdata);
	execute(**held);
	delete held;
}

bool PonyWanderJob::start() {
	if (task >= 0 || state->ran) {
		return false;
	}
	state->ran = true;
	std::shared_ptr<State> *held = new std::shared_ptr<State>(state);
	task = WorkerThreadPool::get_singleton()->add_native_task(&PonyWanderJob::run_task, held, false, String("Pony wander search"));
	return true;
}

bool PonyWanderJob::run_now() {
	if (task >= 0 || state->ran) {
		return false;
	}
	state->ran = true;
	execute(*state);
	return true;
}

void PonyWanderJob::cancel() {
	state->cancel.store(true, std::memory_order_relaxed);
}

bool PonyWanderJob::is_done() {
	if (task < 0) {
		return state->ran;
	}
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	if (!pool->is_task_completed(task)) {
		return false;
	}
	pool->wait_for_task_completion(task);
	task = -1;
	return true;
}

void PonyWanderJob::wait() {
	if (task >= 0) {
		WorkerThreadPool::get_singleton()->wait_for_task_completion(task);
		task = -1;
	}
}

Vector3 PonyWanderJob::destination() {
	if (task >= 0 || !state->ran) {
		return Vector3(INFINITY, INFINITY, INFINITY);
	}
	return vector(state->output.destination);
}

Dictionary PonyWanderJob::diagnostics() {
	Dictionary result;
	const bool readable = task < 0 && state->ran;
	result["done"] = readable;
	if (!readable) {
		return result;
	}
	const ponynav::WanderOutput &output = state->output;
	result["found"] = output.found;
	result["cancelled"] = output.cancelled;
	result["no_floor"] = output.no_floor;
	result["visited"] = output.visited;
	result["candidates"] = output.candidates;
	result["cpu_ms"] = output.cpu_us / 1000.0;
	result["rooms_computed"] = int64_t(output.rooms_computed);
	return result;
}
