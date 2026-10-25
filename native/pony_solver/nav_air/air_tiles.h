#pragma once
// Sparse air tiles: the storage half of nav_air (docs/NAVIGATION_AIR_STORAGE_2026_10_02.md).
//
// A tile is a 32 m cube of 8 x 8 x 8 coarse 4 m cells. Each coarse entry is UNKNOWN, FREE,
// SOLID or a fine brick of 8 x 8 x 8 cells of 0.5 m (2 bits per cell). A whole tile that is
// one state stores no arrays at all. A missing tile is UNKNOWN, never FREE.
//
// Occupancy stored here is ALREADY INFLATED by the profile's flight envelope (air_voxelize.cpp
// applies it exactly once). A cell is FREE only when every point inside it is farther than
// the envelope radius from every collision triangle/shape, so callers must not inflate again:
// a body centre anywhere inside a FREE cell is clear.
//
// World frame: Godot metres, Y up. Tile (tx, ty, tz) spans [t * 32, t * 32 + 32) on each axis
// from the world origin; positions on a boundary belong to the higher cell (floor).
// Local indices: coarse = cx + 8 * (cy + 8 * cz), fine = fx + 8 * (fy + 8 * fz).
//
// Thread ownership: AirTileSpace mutation (publish/remove/seal) is single-owner. Workers read
// an immutable snapshot() (tiles are shared_ptr<const AirTile>, never edited after publish).
#include "air_space.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace nav_air {

constexpr float TILE_SIZE = 32.0f;
constexpr float COARSE_SIZE = 4.0f;
constexpr float FINE_SIZE = 0.5f;
constexpr int DIM = 8;          // cells per axis in a tile (coarse) and in a brick (fine)
constexpr int CELLS = 512;      // DIM^3
constexpr int TILE_FINE = 64;   // fine cells per tile axis
constexpr int TILE_FINE_CELLS = TILE_FINE * TILE_FINE * TILE_FINE;
constexpr int BRICK_BYTES = 128;  // 512 cells x 2 bits

// Coarse entry encoding.
constexpr uint16_t ENTRY_UNKNOWN = 0;
constexpr uint16_t ENTRY_FREE = 1;
constexpr uint16_t ENTRY_SOLID = 2;
constexpr uint16_t ENTRY_BRICK_BASE = 3;  // entry - 3 = brick index
constexpr uint16_t NO_COMPONENT = 0xFFFF;

struct TileKey {
	int32_t x = 0, y = 0, z = 0;
};
inline bool operator==(const TileKey &a, const TileKey &b) { return a.x == b.x && a.y == b.y && a.z == b.z; }
inline bool operator!=(const TileKey &a, const TileKey &b) { return !(a == b); }
inline bool operator<(const TileKey &a, const TileKey &b) {
	if (a.y != b.y) return a.y < b.y;
	if (a.z != b.z) return a.z < b.z;
	return a.x < b.x;
}
struct TileKeyHash {
	size_t operator()(const TileKey &k) const {
		uint64_t h = 1469598103934665603ull;
		for (int32_t v : {k.x, k.y, k.z}) { h ^= uint32_t(v); h *= 1099511628211ull; }
		return size_t(h ^ (h >> 29));
	}
};

// Mathematical floor division / modulo (negative coordinates).
inline int64_t floor_div(int64_t a, int64_t b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }
inline int64_t positive_mod(int64_t a, int64_t b) { return a - floor_div(a, b) * b; }

struct AirProfile {
	std::string name;
	float envelope_radius = 0.0f;   // metres: sphere enclosing body + open wings + clearance
	Vec3 centre_offset{0.0f, 0.0f, 0.0f};  // body centre relative to the pony root (metadata)
};

// One immutable tile once published.
struct AirTile {
	TileKey key{};
	uint64_t revision = 0;      // process-wide unique, assigned by AirTileSpace::publish
	uint64_t source_hash = 0;   // hash of the geometry it was baked from
	uint8_t uniform = 0;        // Cell value when the whole tile has one state (no arrays), else 0
	std::vector<uint16_t> coarse;  // CELLS entries unless uniform
	std::vector<uint8_t> bricks;   // BRICK_BYTES per brick, 2 bits per fine cell (Cell values)

	// Derived (compute_components): face-connected FREE components inside this tile.
	uint16_t component_count = 0;
	std::vector<uint16_t> coarse_component;  // per coarse cell: component of a FREE coarse leaf
	std::vector<uint16_t> brick_component;   // per brick: the one component of all its FREE cells,
	                                         // NO_COMPONENT if none, MIXED_BRICK when labelled per cell
	std::vector<uint32_t> brick_labels_at;   // per brick: offset into fine_labels, or UINT32_MAX
	std::vector<uint16_t> fine_labels;       // CELLS labels per mixed brick
	static constexpr uint16_t MIXED_BRICK = 0xFFFE;

	size_t brick_count() const { return bricks.size() / BRICK_BYTES; }
	bool is_brick(int coarse_index) const { return !uniform && coarse[coarse_index] >= ENTRY_BRICK_BASE; }
	Cell coarse_state(int coarse_index) const;  // UNKNOWN for a brick (not a leaf)
	Cell fine_state(int coarse_index, int fine_index) const;  // uniform coarse cells answer their state
	Cell state_at(int fx, int fy, int fz) const;              // tile-local fine coordinates 0..63
	uint16_t component_at(int fx, int fy, int fz) const;      // NO_COMPONENT unless FREE
	void expand(uint8_t *out) const;  // TILE_FINE_CELLS Cell values, index x + 64 * (y + 64 * z)
	size_t memory_bytes() const;
};

// Builds a tile from a dense fine grid (TILE_FINE_CELLS Cell values, index x + 64*(y + 64*z)):
// coarse cells that are all one state collapse, mixed ones become bricks, an all-one-state
// tile becomes uniform. Components are not computed (publish does that).
std::shared_ptr<AirTile> make_tile(const TileKey &key, const uint8_t *fine, uint64_t source_hash);
void compute_components(AirTile &tile);

class AirTileSpace final : public AirSpace {
public:
	explicit AirTileSpace(AirProfile profile = {});

	// AirSpace (see air_space.h). locate() returns false for a missing tile or a non-finite
	// point; for a missing tile `out` still names the tile and coarse cell (level 0).
	// state() of a level-0 id whose coarse cell is a brick is UNKNOWN (not a leaf, never free).
	bool locate(const Vec3 &p, CellId &out) const override;
	Cell state(const CellId &c) const override;
	Aabb bounds(const CellId &c) const override;
	void neighbours(const CellId &c, std::vector<Face> &out) const override;
	Cell sample(const Vec3 &p) const override;
	uint64_t tile_revision(int32_t tx, int32_t ty, int32_t tz) const override;
	// Exact and O(1) here: present tiles hold only FREE/SOLID, so UNKNOWN across a face means
	// the cell's own tile is missing or a face lies on a tile side whose neighbour is missing.
	bool touches_unknown(const CellId &c) const override;

	const AirProfile &profile() const { return profile_; }
	void set_profile(const AirProfile &profile) { profile_ = profile; }

	// Publishes a tile (replacing any tile with its key): computes its components and assigns
	// a new process-wide revision, which it returns.
	uint64_t publish(std::shared_ptr<AirTile> tile);
	bool remove(const TileKey &key);
	const AirTile *find(const TileKey &key) const;
	std::shared_ptr<const AirTile> tile(const TileKey &key) const;
	std::vector<TileKey> keys() const;  // sorted (y, z, x)
	size_t tile_count() const { return tiles_.size(); }
	size_t brick_count() const;
	size_t memory_bytes() const;  // tiles + their arrays + map overhead estimate
	std::shared_ptr<AirTileSpace> snapshot() const;  // shares the immutable tiles

	// Tile-local FREE component of a leaf (NO_COMPONENT if not a FREE leaf or tile missing).
	uint16_t component(const CellId &c) const;
	// Component links across the six faces of a tile into present neighbour tiles.
	struct Link {
		uint16_t from = NO_COMPONENT;
		TileKey to{};
		uint16_t to_component = NO_COMPONENT;
		uint8_t side = 0;  // 0 -x, 1 +x, 2 -y, 3 +y, 4 -z, 5 +z
	};
	void tile_links(const TileKey &key, std::vector<Link> &out) const;

	// Closed-building policy: FREE pockets whose whole connected volume (through tiles in
	// `scope`) never reaches a face toward a missing tile or a tile outside `scope` are
	// provably enclosed (sealed houses, closed boxes, gaps narrower than the envelope) and
	// become SOLID. Changed tiles are republished with new revisions. Returns tiles changed.
	size_t seal_enclosed(const std::vector<TileKey> &scope);

	static uint64_t next_revision();

private:
	AirProfile profile_;
	std::unordered_map<TileKey, std::shared_ptr<const AirTile>, TileKeyHash> tiles_;
};

}  // namespace nav_air
