// Native pony navigation, actors, intents and search jobs: see navigation_jobs.h.
#include "navigation_jobs.h"

#include <algorithm>
#include <cstring>

namespace ponynav {

namespace {

using Clock = std::chrono::steady_clock;

double micros(Clock::duration duration) {
	return double(std::chrono::duration_cast<std::chrono::nanoseconds>(duration).count()) / 1000.0;
}

bool same_float(float a, float b) {
	uint32_t x = 0;
	uint32_t y = 0;
	std::memcpy(&x, &a, sizeof(x));
	std::memcpy(&y, &b, sizeof(y));
	return x == y;
}

bool same_vec(const Vec3f &a, const Vec3f &b) {
	return same_float(a.x, b.x) && same_float(a.y, b.y) && same_float(a.z, b.z);
}

float distance3(const Vec3f &a, const Vec3f &b) {
	const float x = a.x - b.x;
	const float y = a.y - b.y;
	const float z = a.z - b.z;
	return std::sqrt(x * x + y * y + z * z);
}

} // namespace

bool IntentParams::same_request(const IntentParams &other) const {
	return owner == other.owner && same_vec(goal, other.goal) && terminal_mode == other.terminal_mode &&
			same_float(pace, other.pace) && priority == other.priority && follow == other.follow &&
			same_float(follow_replan_distance, other.follow_replan_distance) &&
			search.any_floor == other.search.any_floor && search.relaxed == other.search.relaxed &&
			search.use_corridor == other.search.use_corridor && search.allow_partial == other.search.allow_partial &&
			search.smooth == other.search.smooth && search.expansion_limit == other.search.expansion_limit &&
			search.goal_radius == other.search.goal_radius && search.dijkstra == other.search.dijkstra &&
			search.escape_reach == other.search.escape_reach && search.blocked == other.search.blocked;
}

// ---------------------------------------------------------------------------------------------
// JobScheduler

// dev 2026-10-20 multithreading: the worker count follows the engine's thread pool (the GDScript
// backend passes its autodetected search concurrency); this only bounds a bad argument. The
// scheduler keeps its own std::threads because idle workers sleep on a condition variable, which
// must never happen on a WorkerThreadPool thread, and the file also builds into the standalone
// tests without Godot.
constexpr int MAX_SEARCH_WORKERS = 64;

JobScheduler::JobScheduler(int workers) :
		wanted(std::min(MAX_SEARCH_WORKERS, std::max(1, workers))) {
}

JobScheduler::~JobScheduler() {
	shutdown();
}

void JobScheduler::start_locked() {
	if (!threads.empty() || stopping || closed) {
		return;
	}
	for (int i = 0; i < wanted; ++i) {
		threads.emplace_back([this]() { run(); });
	}
}

void JobScheduler::submit(const std::shared_ptr<SearchJob> &job) {
	std::lock_guard<std::mutex> lock(mutex);
	if (closed) {
		job->cancelled.store(true);
		job->search->cancel();
		job->status = RouteStatus::CANCELLED;
		done.push_back(job);
		return;
	}
	job->ready_since = Clock::now();
	ready.push_back(job);
	start_locked();
	wake.notify_one();
}

void JobScheduler::run() {
	std::unique_lock<std::mutex> lock(mutex);
	while (true) {
		wake.wait(lock, [this]() { return stopping || (!paused && !ready.empty()); });
		if (stopping) {
			return;
		}
		// Highest priority first; waiting time ages a job up one level per second (up to ten)
		// so background work cannot starve. Equal scores take turns, then the older job.
		const Clock::time_point now = Clock::now();
		size_t best = 0;
		double best_score = -1e300;
		for (size_t i = 0; i < ready.size(); ++i) {
			const SearchJob &candidate = *ready[i];
			const double waited = std::min(10.0, micros(now - candidate.ready_since) / 1e6);
			const double score = double(candidate.priority) + waited;
			const SearchJob &current = *ready[best];
			if (i == 0 || score > best_score ||
					(score == best_score && (candidate.last_slice < current.last_slice ||
													(candidate.last_slice == current.last_slice && candidate.id < current.id)))) {
				best = i;
				best_score = score;
			}
		}
		std::shared_ptr<SearchJob> job = ready[best];
		ready.erase(ready.begin() + long(best));
		++running;
		const int64_t expansions = slice_expansions;
		const int64_t budget_us = slice_us;
		lock.unlock();

		if (!job->started) {
			job->started = true;
			job->first_slice = Clock::now();
		}
		RouteStatus status = RouteStatus::PENDING;
		if (job->cancelled.load(std::memory_order_relaxed)) {
			job->search->cancel();
			status = RouteStatus::CANCELLED;
		} else {
			status = job->search->advance(expansions, budget_us, &job->cancelled);
		}

		lock.lock();
		--running;
		++slice_clock;
		job->status = status;
		if (status == RouteStatus::PENDING) {
			job->last_slice = slice_clock;
			job->ready_since = Clock::now();
			ready.push_back(job);
			wake.notify_one();
		} else {
			done.push_back(job);
		}
	}
}

std::vector<std::shared_ptr<SearchJob>> JobScheduler::drain() {
	std::vector<std::shared_ptr<SearchJob>> result;
	std::lock_guard<std::mutex> lock(mutex);
	result.swap(done);
	return result;
}

void JobScheduler::stop_threads() {
	std::vector<std::thread> joining;
	{
		std::lock_guard<std::mutex> lock(mutex);
		stopping = true;
		joining.swap(threads);
	}
	wake.notify_all();
	for (std::thread &thread : joining) {
		if (thread.joinable()) {
			thread.join();
		}
	}
	std::lock_guard<std::mutex> lock(mutex);
	stopping = false;
}

void JobScheduler::set_workers(int workers) {
	stop_threads();
	std::lock_guard<std::mutex> lock(mutex);
	wanted = std::min(MAX_SEARCH_WORKERS, std::max(1, workers));
	if (!ready.empty()) {
		start_locked();
		wake.notify_all();
	}
}

int JobScheduler::workers() const {
	std::lock_guard<std::mutex> lock(mutex);
	return wanted;
}

void JobScheduler::set_paused(bool value) {
	{
		std::lock_guard<std::mutex> lock(mutex);
		paused = value;
	}
	wake.notify_all();
}

void JobScheduler::set_slice_budget(int64_t expansions, int64_t microseconds) {
	std::lock_guard<std::mutex> lock(mutex);
	slice_expansions = std::max<int64_t>(64, expansions);
	slice_us = std::max<int64_t>(0, microseconds);
}

size_t JobScheduler::queued() const {
	std::lock_guard<std::mutex> lock(mutex);
	return ready.size();
}

int JobScheduler::busy() const {
	std::lock_guard<std::mutex> lock(mutex);
	return running;
}

uint64_t JobScheduler::slices() const {
	std::lock_guard<std::mutex> lock(mutex);
	return slice_clock;
}

void JobScheduler::shutdown() {
	{
		std::lock_guard<std::mutex> lock(mutex);
		closed = true;
		for (const std::shared_ptr<SearchJob> &job : ready) {
			job->cancelled.store(true);
		}
	}
	stop_threads();
	std::lock_guard<std::mutex> lock(mutex);
	ready.clear();
	done.clear();
}

// ---------------------------------------------------------------------------------------------
// NavigationService

NavigationService::NavigationService(int workers) :
		scheduler(workers) {
}

NavigationService::~NavigationService() {
	shutdown();
}

uint32_t NavigationService::create_world() {
	const uint32_t id = next_world++;
	worlds[id] = std::unique_ptr<NavigationWorld>(new NavigationWorld(id));
	return id;
}

bool NavigationService::destroy_world(uint32_t id) {
	const auto found = worlds.find(id);
	if (found == worlds.end()) {
		return false;
	}
	for (auto &entry : in_flight) {
		if (entry.second->world == id) {
			entry.second->cancelled.store(true);
		}
	}
	for (Actor &actor : actors) {
		if (actor.live && actor.world == id) {
			actor.intent.cancelled = true;
			actor.intent.has_pending_goal = false;
			actor.follow = FollowState();
		}
	}
	follow_grounds.erase(std::remove_if(follow_grounds.begin(), follow_grounds.end(),
								 [id](const std::unique_ptr<FollowGround> &entry) { return entry->world == id; }),
			follow_grounds.end());
	// Running searches keep their snapshot and clearance cache through shared ownership.
	worlds.erase(found);
	return true;
}

NavigationWorld *NavigationService::world(uint32_t id) {
	const auto found = worlds.find(id);
	return found == worlds.end() ? nullptr : found->second.get();
}

NavigationService::Actor *NavigationService::live_actor(const ActorHandle &handle) {
	if (handle.slot >= actors.size()) {
		return nullptr;
	}
	Actor &actor = actors[handle.slot];
	return (actor.live && actor.generation == handle.generation && handle.generation != 0) ? &actor : nullptr;
}

const NavigationService::Actor *NavigationService::live_actor(const ActorHandle &handle) const {
	if (handle.slot >= actors.size()) {
		return nullptr;
	}
	const Actor &actor = actors[handle.slot];
	return (actor.live && actor.generation == handle.generation && handle.generation != 0) ? &actor : nullptr;
}

ActorHandle NavigationService::register_actor(uint32_t world_id, const GroundProfile &profile, std::string &error) {
	ActorHandle handle;
	if (worlds.find(world_id) == worlds.end()) {
		error = "unknown navigation world";
		return handle;
	}
	if (!profile.valid(error)) {
		return handle;
	}
	uint32_t slot = 0;
	if (!free_slots.empty()) {
		slot = free_slots.back();
		free_slots.pop_back();
	} else {
		slot = uint32_t(actors.size());
		actors.emplace_back();
	}
	Actor &actor = actors[slot];
	// A reused slot gets a new generation: results for the old occupant are never delivered.
	actor.generation = actor.generation + 1 == 0 ? 1 : actor.generation + 1;
	actor.live = true;
	actor.world = world_id;
	actor.profile = profile;
	actor.last_intent_generation = 0;
	actor.intent = IntentState();
	actor.follow = FollowState();
	handle.slot = slot;
	handle.generation = actor.generation;
	return handle;
}

bool NavigationService::update_actor_profile(const ActorHandle &handle, const GroundProfile &profile) {
	Actor *actor = live_actor(handle);
	std::string error;
	if (actor == nullptr || !profile.valid(error)) {
		return false;
	}
	actor->profile = profile;
	return true;
}

bool NavigationService::unregister_actor(const ActorHandle &handle) {
	Actor *actor = live_actor(handle);
	if (actor == nullptr) {
		return false;
	}
	if (actor->intent.job != 0) {
		cancel_job(actor->intent.job);
	}
	actor->live = false;
	actor->intent = IntentState();
	actor->follow = FollowState();
	free_slots.push_back(handle.slot);
	return true;
}

bool NavigationService::actor_live(const ActorHandle &handle) const {
	return live_actor(handle) != nullptr;
}

std::shared_ptr<SearchJob> NavigationService::start_job(uint32_t slot, Actor &actor, const Vec3f &from, const Vec3f &goal) {
	NavigationWorld *target = world(actor.world);
	if (target == nullptr) {
		return nullptr;
	}
	auto job = std::make_shared<SearchJob>();
	job->id = next_job++;
	job->world = actor.world;
	job->actor.slot = slot;
	job->actor.generation = actor.generation;
	job->intent_generation = actor.intent.params.generation;
	job->owner = actor.intent.params.owner;
	job->goal = goal;
	job->priority = actor.intent.params.priority;
	job->submitted = Clock::now();
	job->search.reset(new GroundSearch(target->snapshot(), target->cache(), actor.profile, from, goal,
			actor.intent.params.search));
	actor.intent.job = job->id;
	actor.intent.searched_goal = goal;
	in_flight[job->id] = job;
	++stats.jobs_submitted;
	scheduler.submit(job);
	return job;
}

void NavigationService::cancel_job(uint64_t id) {
	const auto found = in_flight.find(id);
	if (found != in_flight.end()) {
		found->second->cancelled.store(true);
	}
}

int64_t NavigationService::submit_intent(const ActorHandle &handle, const IntentParams &params) {
	Actor *actor = live_actor(handle);
	if (actor == nullptr || world(actor->world) == nullptr || !params.from.finite() || !params.goal.finite() ||
			!std::isfinite(params.search.goal_radius) || params.search.expansion_limit <= 0) {
		++stats.rejected_generation;
		return -1;
	}
	IntentState &intent = actor->intent;
	const bool searching = intent.live && !intent.cancelled && (intent.job != 0 || intent.has_pending_goal);
	if (searching && intent.params.same_request(params)) {
		++stats.idempotent;
		return int64_t(intent.params.generation);
	}
	if (params.generation <= actor->last_intent_generation) {
		++stats.rejected_generation;
		return -1;
	}
	if (intent.job != 0) {
		cancel_job(intent.job);
	}
	intent = IntentState();
	intent.live = true;
	intent.params = params;
	actor->last_intent_generation = params.generation;
	start_job(handle.slot, *actor, params.from, params.goal);
	return int64_t(params.generation);
}

bool NavigationService::update_intent_goal(const ActorHandle &handle, uint64_t generation, const Vec3f &goal,
		const Vec3f &from) {
	Actor *actor = live_actor(handle);
	if (actor == nullptr || !goal.finite() || !from.finite()) {
		return false;
	}
	IntentState &intent = actor->intent;
	if (!intent.live || intent.cancelled || intent.params.generation != generation) {
		return false;
	}
	intent.params.goal = goal;
	if (intent.job != 0) {
		// One search in flight: keep only the newest goal for when it finishes.
		intent.has_pending_goal = true;
		intent.pending_goal = goal;
		intent.pending_from = from;
		++stats.coalesced;
		return true;
	}
	if (double(distance3(goal, intent.searched_goal)) > double(intent.params.follow_replan_distance)) {
		start_job(handle.slot, *actor, from, goal);
	} else {
		++stats.coalesced;
	}
	return true;
}

bool NavigationService::cancel_intent(const ActorHandle &handle, uint64_t generation) {
	Actor *actor = live_actor(handle);
	if (actor == nullptr) {
		return false;
	}
	IntentState &intent = actor->intent;
	if (!intent.live || intent.cancelled || intent.params.generation != generation) {
		return false;
	}
	intent.cancelled = true;
	intent.has_pending_goal = false;
	if (intent.job != 0) {
		cancel_job(intent.job);
	}
	return true;
}

void NavigationService::record(const SearchJob &job, double queue_us, double latency_us) {
	JobRecord entry;
	entry.job_id = job.id;
	entry.world = job.world;
	entry.status = job.status;
	entry.expanded = job.search->output().expanded;
	entry.cpu_us = job.search->output().cpu_us;
	entry.queue_us = queue_us;
	entry.latency_us = latency_us;
	entry.slices = job.search->output().slices;
	history.push_back(entry);
	while (history.size() > HISTORY) {
		history.pop_front();
	}
}

std::vector<NavResult> NavigationService::poll() {
	std::vector<NavResult> results;
	const Clock::time_point now = Clock::now();
	for (const std::shared_ptr<SearchJob> &job : scheduler.drain()) {
		in_flight.erase(job->id);
		++stats.jobs_finished;
		const double latency = micros(now - job->submitted);
		const double queue = job->started ? micros(job->first_slice - job->submitted) : latency;
		record(*job, queue, latency);
		if (job->status == RouteStatus::CANCELLED) {
			++stats.cancelled;
			continue;
		}
		NavigationWorld *target = world(job->world);
		if (target == nullptr) {
			++stats.stale_world;
			continue;
		}
		Actor *actor = live_actor(job->actor);
		if (actor == nullptr) {
			++stats.stale_actor;
			continue;
		}
		IntentState &intent = actor->intent;
		if (!intent.live || intent.cancelled || intent.params.generation != job->intent_generation ||
				intent.job != job->id) {
			++stats.stale_intent;
			continue;
		}
		intent.job = 0;
		NavResult result;
		result.job_id = job->id;
		result.world = job->world;
		result.actor = job->actor;
		result.intent_generation = job->intent_generation;
		result.owner = job->owner;
		result.goal = job->goal;
		result.output = job->search->output();
		result.queue_us = queue;
		result.latency_us = latency;
		for (const auto &dependency : result.output.dependencies) {
			if (target->revision_of(dependency.first) != dependency.second) {
				++stats.stale_chunk;
				result.output.status = RouteStatus::STALE;
				result.output.reason = "Route geometry changed while searching";
				result.output.path.clear();
				result.output.partial_path.clear();
				break;
			}
		}
		if (intent.has_pending_goal) {
			intent.has_pending_goal = false;
			if (double(distance3(intent.pending_goal, intent.searched_goal)) > double(intent.params.follow_replan_distance)) {
				const uint32_t slot = job->actor.slot;
				start_job(slot, *actor, intent.pending_from, intent.pending_goal);
				result.goal_superseded = true;
			}
		}
		++stats.results_delivered;
		results.push_back(std::move(result));
	}
	return results;
}

size_t NavigationService::pending_jobs() const {
	return in_flight.size();
}

std::vector<uint32_t> NavigationService::world_ids() const {
	std::vector<uint32_t> ids;
	for (const auto &entry : worlds) {
		ids.push_back(entry.first);
	}
	std::sort(ids.begin(), ids.end());
	return ids;
}

size_t NavigationService::actor_count() const {
	size_t count = 0;
	for (const Actor &actor : actors) {
		count += actor.live ? 1 : 0;
	}
	return count;
}

std::vector<JobRecord> NavigationService::recent_jobs() const {
	return std::vector<JobRecord>(history.begin(), history.end());
}

void NavigationService::shutdown() {
	scheduler.shutdown();
	in_flight.clear();
	worlds.clear();
	for (Actor &actor : actors) {
		actor.intent = IntentState();
		actor.follow = FollowState();
	}
	follow_grounds.clear();
	follow_events.clear();
}

} // namespace ponynav
