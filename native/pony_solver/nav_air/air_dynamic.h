// Dynamic blockers, corridor invalidation and the streaming safety horizon for air routes.
//
// DynamicOverlay is a sparse, revisioned set of durable obstruction boxes (already inflated by
// the caller's envelope, or inflated here at add()). It is indexed per 32 m tile; each change
// bumps the overlay revision and the revision of every tile the old/new box touches.
// OverlaidAirSpace presents base + overlay as one AirSpace: a FREE cell meeting a blocker with
// positive volume is SOLID (whole cell: conservative), sample() is SOLID in any fine voxel a
// blocker meets, and tile_revision() mixes both revisions so a corridor notices either change.
// Short-lived moving agents belong to local avoidance, not to this overlay.
#pragma once

#include "air_shorten.h"

#include <unordered_map>

namespace nav_air {

class DynamicOverlay {
public:
	uint32_t add(const Aabb &box, float inflate = 0.0f); // returns id > 0
	bool move(uint32_t id, const Aabb &box, float inflate = 0.0f);
	bool remove(uint32_t id);
	void clear();
	uint64_t revision() const { return revision_; }
	uint64_t tile_revision(int32_t tx, int32_t ty, int32_t tz) const; // 0 = never touched
	bool overlaps(const Aabb &box) const; // any live blocker meets box with positive volume
	size_t count() const { return live_; }

private:
	struct Key {
		int32_t x, y, z;
		bool operator==(const Key &o) const { return x == o.x && y == o.y && z == o.z; }
	};
	struct KeyHash {
		size_t operator()(const Key &k) const;
	};
	struct TileEntry {
		std::vector<uint32_t> ids;
		uint64_t revision = 0;
	};
	struct Blocker {
		Aabb box;
		bool live = false;
	};
	void link(uint32_t id, bool insert);

	std::vector<Blocker> blockers_; // index = id - 1
	std::unordered_map<Key, TileEntry, KeyHash> tiles_;
	uint64_t revision_ = 0;
	size_t live_ = 0;
};

class OverlaidAirSpace : public AirSpace {
public:
	OverlaidAirSpace(const AirSpace &base, const DynamicOverlay &overlay) :
			base_(base), overlay_(overlay) {}
	bool locate(const Vec3 &p, CellId &out) const override { return base_.locate(p, out); }
	Cell state(const CellId &c) const override;
	Aabb bounds(const CellId &c) const override { return base_.bounds(c); }
	void neighbours(const CellId &c, std::vector<Face> &out) const override;
	Cell sample(const Vec3 &p) const override;
	uint64_t tile_revision(int32_t tx, int32_t ty, int32_t tz) const override;
	bool touches_unknown(const CellId &c) const override { return base_.touches_unknown(c); }

private:
	const AirSpace &base_;
	const DynamicOverlay &overlay_;
};

// A certified route as the follower keeps it, with the tile revisions it was certified against.
struct AirCorridor {
	std::vector<Vec3> points;
	std::vector<float> clearance; // per segment swept half-size (empty = 0)
	struct TileStamp {
		int32_t x, y, z;
		uint64_t revision;
	};
	std::vector<TileStamp> tiles; // every tile the certification touched, sorted
	uint32_t recertified = 0;
};

enum class AirCorridorState : uint8_t {
	VALID = 0, // no tile it depends on changed
	REVALIDATED = 1, // something changed in its tiles but every segment still certifies
	BLOCKED = 2, // a segment now meets SOLID (static change or a durable blocker)
	MISSING_DATA = 3, // a tile it depends on is gone or UNKNOWN now
};

const char *air_corridor_state_name(AirCorridorState state);

// Certifies the polyline and records the tiles it touched. False when it does not certify.
bool air_make_corridor(const AirSpace &space, const std::vector<Vec3> &points, const std::vector<float> &clearance,
		AirCorridor &out);
// Cheap when nothing changed (one revision lookup per tile); otherwise re-certifies the whole
// corridor against the current space and refreshes its stamps when it still holds.
AirCorridorState air_check_corridor(const AirSpace &space, AirCorridor &corridor);

// Streaming horizon. The known-safe distance ahead must cover reaction travel plus braking:
// required = v * latency + v^2 / (2 * braking) + margin.
float air_required_distance(float speed, float latency, float braking, float margin);
// Highest speed whose required distance fits in known_safe_distance (0 if even stopping does
// not fit), capped at max_speed.
float air_max_safe_speed(float known_safe_distance, float latency, float braking, float margin, float max_speed);
// Distance along the polyline from its first point that certifies (every touched voxel FREE),
// stopping at max_distance. The first SOLID or UNKNOWN voxel ends the known-safe distance.
float air_certified_distance(const AirSpace &space, const std::vector<Vec3> &points, float max_distance);

} // namespace nav_air
