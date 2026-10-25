// See air_dynamic.h.
#include "air_dynamic.h"
#include "air_search.h"

#include <algorithm>
#include <cmath>

namespace nav_air {

namespace {

float fget(const Vec3 &v, int axis) {
	return axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
}

// Positive-volume overlap; a zero-thickness axis of `a` counts when it lies within `b` (closed).
bool overlap(const Aabb &a, const Aabb &b) {
	for (int axis = 0; axis < 3; ++axis) {
		const float alo = fget(a.min, axis), ahi = fget(a.max, axis);
		const float blo = fget(b.min, axis), bhi = fget(b.max, axis);
		const bool positive = alo < bhi && ahi > blo;
		const bool plane = alo == ahi && alo >= blo && alo <= bhi;
		if (!positive && !plane) {
			return false;
		}
	}
	return true;
}

int64_t floor_div64(int64_t a, int64_t b) {
	int64_t q = a / b;
	if ((a % b != 0) && ((a < 0) != (b < 0))) {
		--q;
	}
	return q;
}

void tile_range(const Aabb &box, int32_t lo[3], int32_t hi[3]) {
	for (int axis = 0; axis < 3; ++axis) {
		const double a = double(fget(box.min, axis)) / AIR_TILE_SIZE;
		const double b = double(fget(box.max, axis)) / AIR_TILE_SIZE;
		if (b > a) {
			lo[axis] = int32_t(std::floor(a));
			hi[axis] = int32_t(std::ceil(b)) - 1;
		} else {
			lo[axis] = int32_t(std::ceil(a)) - 1;
			hi[axis] = int32_t(std::floor(a));
		}
	}
}

struct TileCollector {
	std::vector<AirCorridor::TileStamp> *tiles;
	int ring;
	int64_t last[3];
	bool has_last;
};

bool collect_visit(void *ctx, int32_t x, int32_t y, int32_t z, float) {
	TileCollector &c = *static_cast<TileCollector *>(ctx);
	const int64_t v[3] = {x, y, z};
	int64_t lo[3], hi[3];
	for (int axis = 0; axis < 3; ++axis) {
		lo[axis] = floor_div64(v[axis] - c.ring, 64);
		hi[axis] = floor_div64(v[axis] + c.ring, 64);
	}
	if (c.has_last && lo[0] == hi[0] && lo[1] == hi[1] && lo[2] == hi[2] && lo[0] == c.last[0] && lo[1] == c.last[1] &&
			lo[2] == c.last[2]) {
		return true;
	}
	for (int64_t tz = lo[2]; tz <= hi[2]; ++tz) {
		for (int64_t ty = lo[1]; ty <= hi[1]; ++ty) {
			for (int64_t tx = lo[0]; tx <= hi[0]; ++tx) {
				c.tiles->push_back(AirCorridor::TileStamp{int32_t(tx), int32_t(ty), int32_t(tz), 0});
			}
		}
	}
	c.has_last = true;
	c.last[0] = lo[0];
	c.last[1] = lo[1];
	c.last[2] = lo[2];
	return true;
}

} // namespace

size_t DynamicOverlay::KeyHash::operator()(const Key &k) const {
	uint64_t h = uint64_t(uint32_t(k.x)) * 0x9E3779B97F4A7C15ull;
	h ^= uint64_t(uint32_t(k.y)) * 0xC2B2AE3D27D4EB4Full + (h << 6) + (h >> 2);
	h ^= uint64_t(uint32_t(k.z)) * 0x165667B19E3779F9ull + (h << 6) + (h >> 2);
	return size_t(h ^ (h >> 29));
}

void DynamicOverlay::link(uint32_t id, bool insert) {
	const Aabb &box = blockers_[size_t(id - 1)].box;
	int32_t lo[3], hi[3];
	tile_range(box, lo, hi);
	++revision_;
	for (int32_t z = lo[2]; z <= hi[2]; ++z) {
		for (int32_t y = lo[1]; y <= hi[1]; ++y) {
			for (int32_t x = lo[0]; x <= hi[0]; ++x) {
				TileEntry &e = tiles_[Key{x, y, z}];
				if (insert) {
					e.ids.push_back(id);
				} else {
					e.ids.erase(std::remove(e.ids.begin(), e.ids.end(), id), e.ids.end());
				}
				e.revision = revision_;
			}
		}
	}
}

uint32_t DynamicOverlay::add(const Aabb &box, float inflate) {
	const float e = std::max(0.0f, inflate);
	Blocker b;
	b.box = Aabb{Vec3{box.min.x - e, box.min.y - e, box.min.z - e}, Vec3{box.max.x + e, box.max.y + e, box.max.z + e}};
	b.live = true;
	blockers_.push_back(b);
	const uint32_t id = uint32_t(blockers_.size());
	link(id, true);
	++live_;
	return id;
}

bool DynamicOverlay::move(uint32_t id, const Aabb &box, float inflate) {
	if (id == 0 || id > blockers_.size() || !blockers_[size_t(id - 1)].live) {
		return false;
	}
	link(id, false);
	const float e = std::max(0.0f, inflate);
	blockers_[size_t(id - 1)].box =
			Aabb{Vec3{box.min.x - e, box.min.y - e, box.min.z - e}, Vec3{box.max.x + e, box.max.y + e, box.max.z + e}};
	link(id, true);
	return true;
}

bool DynamicOverlay::remove(uint32_t id) {
	if (id == 0 || id > blockers_.size() || !blockers_[size_t(id - 1)].live) {
		return false;
	}
	link(id, false);
	blockers_[size_t(id - 1)].live = false;
	--live_;
	return true;
}

void DynamicOverlay::clear() {
	for (uint32_t id = 1; id <= blockers_.size(); ++id) {
		if (blockers_[size_t(id - 1)].live) {
			remove(id);
		}
	}
}

uint64_t DynamicOverlay::tile_revision(int32_t tx, int32_t ty, int32_t tz) const {
	auto it = tiles_.find(Key{tx, ty, tz});
	return it == tiles_.end() ? 0 : it->second.revision;
}

bool DynamicOverlay::overlaps(const Aabb &box) const {
	if (live_ == 0) {
		return false;
	}
	int32_t lo[3], hi[3];
	tile_range(box, lo, hi);
	for (int32_t z = lo[2]; z <= hi[2]; ++z) {
		for (int32_t y = lo[1]; y <= hi[1]; ++y) {
			for (int32_t x = lo[0]; x <= hi[0]; ++x) {
				auto it = tiles_.find(Key{x, y, z});
				if (it == tiles_.end()) {
					continue;
				}
				for (uint32_t id : it->second.ids) {
					const Blocker &b = blockers_[size_t(id - 1)];
					if (b.live && (overlap(b.box, box) || overlap(box, b.box))) {
						return true;
					}
				}
			}
		}
	}
	return false;
}

Cell OverlaidAirSpace::state(const CellId &c) const {
	const Cell s = base_.state(c);
	if (s == Cell::FREE && overlay_.overlaps(base_.bounds(c))) {
		return Cell::SOLID;
	}
	return s;
}

void OverlaidAirSpace::neighbours(const CellId &c, std::vector<Face> &out) const {
	base_.neighbours(c, out);
	if (overlay_.count() == 0) {
		return;
	}
	out.erase(std::remove_if(out.begin(), out.end(),
					  [this](const Face &f) { return overlay_.overlaps(base_.bounds(f.to)); }),
			out.end());
}

Cell OverlaidAirSpace::sample(const Vec3 &p) const {
	const Cell s = base_.sample(p);
	if (s != Cell::FREE || overlay_.count() == 0) {
		return s;
	}
	const Vec3 lo{std::floor(p.x / AIR_FINE_SIZE) * AIR_FINE_SIZE, std::floor(p.y / AIR_FINE_SIZE) * AIR_FINE_SIZE,
		std::floor(p.z / AIR_FINE_SIZE) * AIR_FINE_SIZE};
	const Aabb voxel{lo, Vec3{lo.x + AIR_FINE_SIZE, lo.y + AIR_FINE_SIZE, lo.z + AIR_FINE_SIZE}};
	return overlay_.overlaps(voxel) ? Cell::SOLID : Cell::FREE;
}

uint64_t OverlaidAirSpace::tile_revision(int32_t tx, int32_t ty, int32_t tz) const {
	const uint64_t base = base_.tile_revision(tx, ty, tz);
	const uint64_t extra = overlay_.tile_revision(tx, ty, tz);
	if (base == 0 || extra == 0) {
		return base;
	}
	uint64_t h = base ^ (extra * 0x9E3779B97F4A7C15ull + 0x632BE59BD9B4E019ull);
	h ^= h >> 31;
	return h == 0 ? 1 : h;
}

const char *air_corridor_state_name(AirCorridorState state) {
	switch (state) {
		case AirCorridorState::VALID:
			return "VALID";
		case AirCorridorState::REVALIDATED:
			return "REVALIDATED";
		case AirCorridorState::BLOCKED:
			return "BLOCKED";
		case AirCorridorState::MISSING_DATA:
			return "MISSING_DATA";
	}
	return "?";
}

bool air_make_corridor(const AirSpace &space, const std::vector<Vec3> &points, const std::vector<float> &clearance,
		AirCorridor &out) {
	out.points = points;
	out.clearance = clearance;
	out.tiles.clear();
	if (!air_polyline_clear(space, points, clearance)) {
		return false;
	}
	for (size_t i = 0; i + 1 < points.size(); ++i) {
		const float r = i < clearance.size() ? clearance[i] : 0.0f;
		TileCollector c;
		c.tiles = &out.tiles;
		c.ring = r > 0.0f ? int(std::ceil(r / AIR_FINE_SIZE)) : 0;
		c.has_last = false;
		air_supercover(points[i], points[i + 1], collect_visit, &c);
	}
	if (points.size() == 1) {
		TileCollector c;
		c.tiles = &out.tiles;
		c.ring = 0;
		c.has_last = false;
		air_supercover(points[0], points[0], collect_visit, &c);
	}
	auto less = [](const AirCorridor::TileStamp &a, const AirCorridor::TileStamp &b) {
		if (a.y != b.y) {
			return a.y < b.y;
		}
		if (a.z != b.z) {
			return a.z < b.z;
		}
		return a.x < b.x;
	};
	auto same = [](const AirCorridor::TileStamp &a, const AirCorridor::TileStamp &b) {
		return a.x == b.x && a.y == b.y && a.z == b.z;
	};
	std::sort(out.tiles.begin(), out.tiles.end(), less);
	out.tiles.erase(std::unique(out.tiles.begin(), out.tiles.end(), same), out.tiles.end());
	for (AirCorridor::TileStamp &t : out.tiles) {
		t.revision = space.tile_revision(t.x, t.y, t.z);
	}
	return true;
}

AirCorridorState air_check_corridor(const AirSpace &space, AirCorridor &corridor) {
	bool changed = false;
	for (const AirCorridor::TileStamp &t : corridor.tiles) {
		if (space.tile_revision(t.x, t.y, t.z) != t.revision) {
			changed = true;
			break;
		}
	}
	if (!changed) {
		return AirCorridorState::VALID;
	}
	AirSegmentCheck info;
	if (!air_polyline_clear(space, corridor.points, corridor.clearance, &info)) {
		return info.blocking == Cell::UNKNOWN ? AirCorridorState::MISSING_DATA : AirCorridorState::BLOCKED;
	}
	const uint32_t count = corridor.recertified + 1;
	const std::vector<Vec3> points = corridor.points;
	const std::vector<float> clearance = corridor.clearance;
	air_make_corridor(space, points, clearance, corridor);
	corridor.recertified = count;
	return AirCorridorState::REVALIDATED;
}

float air_required_distance(float speed, float latency, float braking, float margin) {
	const float v = std::max(0.0f, speed);
	if (!(braking > 0.0f)) {
		return v > 0.0f ? INFINITY : std::max(0.0f, margin);
	}
	return v * std::max(0.0f, latency) + v * v / (2.0f * braking) + std::max(0.0f, margin);
}

float air_max_safe_speed(float known_safe_distance, float latency, float braking, float margin, float max_speed) {
	const float room = known_safe_distance - std::max(0.0f, margin);
	if (!(room > 0.0f) || !(braking > 0.0f)) {
		return 0.0f;
	}
	const double l = std::max(0.0f, latency);
	const double b = braking;
	// v^2 / (2b) + v l - room = 0
	const double v = b * (-l + std::sqrt(l * l + 2.0 * double(room) / b));
	return std::max(0.0f, std::min(float(v), max_speed));
}

float air_certified_distance(const AirSpace &space, const std::vector<Vec3> &points, float max_distance) {
	float travelled = 0.0f;
	for (size_t i = 0; i + 1 < points.size(); ++i) {
		const Vec3 &a = points[i];
		Vec3 b = points[i + 1];
		float len = air_distance(a, b);
		bool last = false;
		if (travelled + len > max_distance) {
			const float keep = std::max(0.0f, max_distance - travelled);
			const float s = len > 0.0f ? keep / len : 0.0f;
			b = Vec3{a.x + (b.x - a.x) * s, a.y + (b.y - a.y) * s, a.z + (b.z - a.z) * s};
			len = keep;
			last = true;
		}
		AirSegmentCheck info;
		if (!air_segment_clear(space, a, b, 0.0f, &info)) {
			return travelled + std::max(0.0f, info.t) * len;
		}
		travelled += len;
		if (last) {
			break;
		}
	}
	return std::min(travelled, max_distance);
}

} // namespace nav_air
