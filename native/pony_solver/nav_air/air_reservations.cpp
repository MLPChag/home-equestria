// See air_reservations.h.
#include "air_reservations.h"

#include <algorithm>
#include <cmath>

namespace nav_air {

namespace {

bool finite3(const Vec3 &v) {
	return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

} // namespace

bool air_cylinders_overlap(const AirCylinder &a, const AirCylinder &b) {
	const float a0 = a.base.y, a1 = a.base.y + a.height;
	const float b0 = b.base.y, b1 = b.base.y + b.height;
	if (!(a0 < b1 && b0 < a1)) {
		return false;
	}
	const float dx = a.base.x - b.base.x, dz = a.base.z - b.base.z;
	const float r = a.radius + b.radius;
	return dx * dx + dz * dz < r * r;
}

const char *reservation_state_name(ReservationState state) {
	switch (state) {
		case ReservationState::NONE: return "NONE";
		case ReservationState::WAITING: return "WAITING";
		case ReservationState::GRANTED: return "GRANTED";
		case ReservationState::ENDED: return "ENDED";
	}
	return "?";
}

const char *reservation_end_name(ReservationEnd end) {
	switch (end) {
		case ReservationEnd::NONE: return "NONE";
		case ReservationEnd::RELEASED: return "RELEASED";
		case ReservationEnd::CANCELLED: return "CANCELLED";
		case ReservationEnd::DESPAWNED: return "DESPAWNED";
		case ReservationEnd::LEASE_EXPIRED: return "LEASE_EXPIRED";
		case ReservationEnd::WAIT_LIMIT: return "WAIT_LIMIT";
		case ReservationEnd::HOLD_LIMIT: return "HOLD_LIMIT";
		case ReservationEnd::INTERRUPTED: return "INTERRUPTED";
	}
	return "?";
}

ReservationTable::ReservationTable(const ReservationPolicy &policy) :
		policy_(policy) {}

uint64_t ReservationTable::request(const ReservationRequest &request, double now) {
	const AirCylinder &v = request.volume;
	if (!finite3(v.base) || !std::isfinite(v.radius) || !std::isfinite(v.height) || v.radius <= 0.0f ||
			v.height <= 0.0f || !std::isfinite(now)) {
		return 0;
	}
	for (auto &item : entries_) {
		Entry &e = item.second;
		if (e.state != ReservationState::WAITING && e.state != ReservationState::GRANTED) {
			continue;
		}
		if (e.request.actor == request.actor && e.request.kind == request.kind &&
				e.request.resource_id == request.resource_id) {
			e.request.volume = request.volume;
			e.request.priority = request.priority;
			e.request.max_wait = request.max_wait;
			e.request.max_hold = request.max_hold;
			e.renewed_at = now;
			return item.first;
		}
	}
	const uint64_t ticket = next_ticket_++;
	Entry e;
	e.request = request;
	e.requested_at = now;
	e.renewed_at = now;
	entries_.emplace(ticket, e);
	return ticket;
}

void ReservationTable::end(Entry &entry, ReservationEnd why, double now) {
	entry.state = ReservationState::ENDED;
	entry.end = why;
	entry.ended_at = now;
}

void ReservationTable::update(double now) {
	// Expiries and pruning first.
	for (auto it = entries_.begin(); it != entries_.end();) {
		Entry &e = it->second;
		if (e.state == ReservationState::ENDED) {
			if (now - e.ended_at > policy_.ended_retention) {
				it = entries_.erase(it);
				continue;
			}
		} else if (now - e.renewed_at > policy_.lease) {
			end(e, ReservationEnd::LEASE_EXPIRED, now);
		} else if (e.state == ReservationState::WAITING && e.request.max_wait > 0.0 &&
				now - e.requested_at > e.request.max_wait) {
			end(e, ReservationEnd::WAIT_LIMIT, now);
		} else if (e.state == ReservationState::GRANTED && e.request.max_hold > 0.0 &&
				now - e.granted_at > e.request.max_hold) {
			end(e, ReservationEnd::HOLD_LIMIT, now);
		}
		++it;
	}
	// Rank the waiters.
	struct Waiter {
		double rank;
		double requested_at;
		uint64_t actor;
		uint64_t ticket;
		Entry *entry;
	};
	std::vector<Waiter> waiters;
	std::vector<const Entry *> claimed;
	for (auto &item : entries_) {
		Entry &e = item.second;
		if (e.state == ReservationState::GRANTED) {
			claimed.push_back(&e);
		} else if (e.state == ReservationState::WAITING) {
			const double rank = double(e.request.priority) + policy_.aging_per_second * std::max(0.0, now - e.requested_at);
			waiters.push_back(Waiter{rank, e.requested_at, e.request.actor.packed(), item.first, &e});
		}
	}
	std::sort(waiters.begin(), waiters.end(), [](const Waiter &a, const Waiter &b) {
		if (a.rank != b.rank) return a.rank > b.rank;
		if (a.requested_at != b.requested_at) return a.requested_at < b.requested_at;
		if (a.actor != b.actor) return a.actor < b.actor;
		return a.ticket < b.ticket;
	});
	for (const Waiter &w : waiters) {
		bool free = true;
		for (const Entry *c : claimed) {
			if (c->request.actor != w.entry->request.actor &&
					air_cylinders_overlap(c->request.volume, w.entry->request.volume)) {
				free = false;
				break;
			}
		}
		if (free) {
			w.entry->state = ReservationState::GRANTED;
			w.entry->granted_at = now;
		}
		// Granted or still waiting, it claims its volume against everyone ranked below it.
		claimed.push_back(w.entry);
	}
}

bool ReservationTable::renew(uint64_t ticket, double now) {
	auto it = entries_.find(ticket);
	if (it == entries_.end()) {
		return false;
	}
	Entry &e = it->second;
	if (e.state != ReservationState::WAITING && e.state != ReservationState::GRANTED) {
		return false;
	}
	e.renewed_at = std::max(e.renewed_at, now);
	return true;
}

bool ReservationTable::release(uint64_t ticket, ReservationEnd why, double now) {
	auto it = entries_.find(ticket);
	if (it == entries_.end()) {
		return false;
	}
	Entry &e = it->second;
	if (e.state != ReservationState::WAITING && e.state != ReservationState::GRANTED) {
		return false;
	}
	end(e, why, now);
	return true;
}

uint32_t ReservationTable::release_actor(const AirActorKey &actor, ReservationEnd why, double now) {
	uint32_t count = 0;
	for (auto &item : entries_) {
		Entry &e = item.second;
		if (e.request.actor == actor &&
				(e.state == ReservationState::WAITING || e.state == ReservationState::GRANTED)) {
			end(e, why, now);
			++count;
		}
	}
	return count;
}

ReservationState ReservationTable::state(uint64_t ticket) const {
	auto it = entries_.find(ticket);
	return it == entries_.end() ? ReservationState::NONE : it->second.state;
}

ReservationEnd ReservationTable::end_reason(uint64_t ticket) const {
	auto it = entries_.find(ticket);
	return it == entries_.end() ? ReservationEnd::NONE : it->second.end;
}

double ReservationTable::waited(uint64_t ticket, double now) const {
	auto it = entries_.find(ticket);
	return it == entries_.end() ? 0.0 : std::max(0.0, now - it->second.requested_at);
}

double ReservationTable::granted_at(uint64_t ticket) const {
	auto it = entries_.find(ticket);
	return it == entries_.end() ? -1.0 : it->second.granted_at;
}

bool ReservationTable::conflicts(const AirCylinder &volume, const AirActorKey &ignore, uint64_t *ticket) const {
	for (const auto &item : entries_) {
		const Entry &e = item.second;
		if (e.state == ReservationState::GRANTED && e.request.actor != ignore &&
				air_cylinders_overlap(e.request.volume, volume)) {
			if (ticket != nullptr) {
				*ticket = item.first;
			}
			return true;
		}
	}
	return false;
}

size_t ReservationTable::live_count() const {
	size_t count = 0;
	for (const auto &item : entries_) {
		if (item.second.state == ReservationState::WAITING || item.second.state == ReservationState::GRANTED) {
			++count;
		}
	}
	return count;
}

} // namespace nav_air
