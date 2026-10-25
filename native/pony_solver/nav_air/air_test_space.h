// Simple in-memory AirSpace for the air search tests (no Godot, no storage format).
// Layout follows air_space.h: 32 m tiles of 8^3 coarse 4 m entries; an entry is uniform
// (UNKNOWN / FREE / SOLID) or an 8^3 brick of 0.5 m fine cells. Missing tiles are UNKNOWN.
// Boxes given to fill_box() are taken as already inflated occupancy (the profile envelope is the
// caller's business), and are marked conservatively: every cell overlapping the box is set.
#pragma once

#include "air_space.h"

#include <array>
#include <unordered_map>

namespace nav_air {

class TestAirSpace : public AirSpace {
public:
	// Creates (or resets) one tile with every coarse entry uniform `fill`.
	void add_tile(int32_t tx, int32_t ty, int32_t tz, Cell fill);
	// Creates every tile overlapping `box` (positive volume) that does not exist yet.
	void add_tiles(const Aabb &box, Cell fill);
	bool remove_tile(int32_t tx, int32_t ty, int32_t tz);
	// Sets every cell overlapping `box` in existing tiles. Coarse entries fully inside become
	// uniform; partly covered ones are subdivided into a brick first. A zero-thickness box marks
	// the cells on both sides of its plane. Returns the number of tiles changed.
	int fill_box(const Aabb &box, Cell state);
	// Subdivides the coarse entries overlapping `box` without changing any state (seam tests).
	int refine_box(const Aabb &box);
	// Gives a tile a new revision without changing it.
	void touch_tile(int32_t tx, int32_t ty, int32_t tz);
	size_t tile_count() const { return tiles_.size(); }
	size_t brick_count() const;

	bool locate(const Vec3 &p, CellId &out) const override;
	Cell state(const CellId &c) const override;
	Aabb bounds(const CellId &c) const override;
	void neighbours(const CellId &c, std::vector<Face> &out) const override;
	Cell sample(const Vec3 &p) const override;
	uint64_t tile_revision(int32_t tx, int32_t ty, int32_t tz) const override;

private:
	struct Key {
		int32_t x, y, z;
		bool operator==(const Key &o) const { return x == o.x && y == o.y && z == o.z; }
	};
	struct KeyHash {
		size_t operator()(const Key &k) const;
	};
	struct Tile {
		uint64_t revision = 0;
		std::array<uint8_t, 512> coarse{};
		std::array<int32_t, 512> brick{};
		std::vector<std::array<uint8_t, 512>> bricks;
	};

	const Tile *tile(int32_t tx, int32_t ty, int32_t tz) const;
	// Leaf at a global fine coordinate (0.5 m grid). False when the tile is missing.
	bool leaf_at(int64_t gx, int64_t gy, int64_t gz, CellId &out, Cell &cell) const;
	int ensure_brick(Tile &t, int coarse);

	std::unordered_map<Key, Tile, KeyHash> tiles_;
	uint64_t next_revision_ = 1;
};

} // namespace nav_air
