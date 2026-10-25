// Native pony navigation, ground storage (docs/NAVIGATION_PHASE_1_2026_10_02.md).
// Pure C++17 with no Godot types: the same file builds into the GDExtension and into the
// standalone algorithm tests (native/pony_solver/tests/navigation_tests.cpp).
//
// A walk chunk (world/navigation/walk_chunk.gd) is a 64 x 64 grid of 0.25 m columns. The
// GDScript arrays hold two floor slots per column; here each published chunk revision is
// converted once into compressed sparse rows: `column_offsets[c] .. column_offsets[c + 1]`
// indexes the solid floor spans of column c, highest first, so a column can hold any number of
// stacked floors (the two-slot limit is the producer's, not this format's). Published chunks
// are immutable and shared with worker searches through std::shared_ptr<const ...>.
#pragma once

#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace ponynav {

constexpr double CELL = 0.25;
constexpr int32_t CHUNK_CELLS = 64;
constexpr int32_t CHUNK_COLUMNS = CHUNK_CELLS * CHUNK_CELLS;
// walk_grid.gd SPANS: the slots per column in the GDScript producer arrays.
constexpr int32_t LEGACY_SPANS = 2;
constexpr int32_t LEGACY_SLOTS = CHUNK_COLUMNS * LEGACY_SPANS;
constexpr double PAINT_SCALE = 50.0;
// A span's surface id is (column << SLOT_BITS) | slot; a column holds at most 15 floors.
constexpr uint32_t SLOT_BITS = 4;
constexpr uint32_t MAX_COLUMN_SPANS = (1u << SLOT_BITS) - 1;
constexpr double INF = std::numeric_limits<double>::infinity();

// walk_grid.gd flag bits, per span.
enum SpanFlag : uint8_t {
	FLAG_SOLID = 1,
	FLAG_WATER = 2,
	FLAG_NO_CLEARANCE = 4,
	FLAG_EDGE = 8,
	FLAG_ROOF = 16,
	FLAG_PAINT_TRAIL = 32,
	FLAG_PAINT_FORD = 64,
	FLAG_PAINT_BLOCK = 128,
};

// Mathematical floor division and a modulo that is never negative: cell -1 is in chunk -1 at
// local column 63, not in chunk 0. C++ `/` and `%` truncate toward zero.
inline int32_t floor_div(int32_t value, int32_t divisor) {
	const int32_t quotient = value / divisor;
	const int32_t remainder = value % divisor;
	return (remainder != 0 && ((remainder < 0) != (divisor < 0))) ? quotient - 1 : quotient;
}

inline int32_t positive_mod(int32_t value, int32_t divisor) {
	const int32_t remainder = value % divisor;
	return (remainder != 0 && ((remainder < 0) != (divisor < 0))) ? remainder + divisor : remainder;
}

// WalkGrid.column(): floori(world / CELL). World X = -0.1 m is cell -1.
inline int32_t cell_coord(double world) {
	return int32_t(std::floor(world / CELL));
}

struct ChunkKey {
	int32_t x = 0;
	int32_t z = 0;

	bool operator==(const ChunkKey &other) const { return x == other.x && z == other.z; }
	bool operator!=(const ChunkKey &other) const { return !(*this == other); }
	// Row-major (z, then x): the snapshot order and every deterministic tie on chunks.
	bool operator<(const ChunkKey &other) const { return z != other.z ? z < other.z : x < other.x; }
	uint64_t packed() const { return (uint64_t(uint32_t(x)) << 32) | uint64_t(uint32_t(z)); }
	static ChunkKey from_packed(uint64_t packed) {
		ChunkKey key;
		key.x = int32_t(uint32_t(packed >> 32));
		key.z = int32_t(uint32_t(packed & 0xffffffffu));
		return key;
	}
	static ChunkKey of_cell(int32_t cell_x, int32_t cell_z) {
		ChunkKey key;
		key.x = floor_div(cell_x, CHUNK_CELLS);
		key.z = floor_div(cell_z, CHUNK_CELLS);
		return key;
	}
};

// Local column index inside a chunk, `lz * 64 + lx`, for any global cell.
inline int32_t local_column(int32_t cell_x, int32_t cell_z) {
	return positive_mod(cell_z, CHUNK_CELLS) * CHUNK_CELLS + positive_mod(cell_x, CHUNK_CELLS);
}

struct FloorSpan {
	float floor_y = 0.0f;
	float headroom = 0.0f;
	float water_depth = 0.0f;
	// Stable surface identity inside the chunk: (column << SLOT_BITS) | slot. It names the
	// floor across searches; a packed array index is only valid inside one snapshot.
	uint32_t surface_id = 0;
	uint8_t flags = 0;
	uint8_t slope_deg = 0;
	// Painted route cost per column, cost * PAINT_SCALE (255 = painted block).
	uint8_t paint_byte = 50;
	// Visible terrain trail strength, 0..255.
	uint8_t trail_byte = 0;

	uint32_t column() const { return surface_id >> SLOT_BITS; }
	uint32_t slot() const { return surface_id & MAX_COLUMN_SPANS; }
};

// WalkGrid.sample() "trail": a painted trail counts as a full trail.
inline double span_trail(const FloorSpan &span) {
	return (span.flags & FLAG_PAINT_TRAIL) ? 1.0 : double(span.trail_byte) / 255.0;
}

// WalkGrid.sample() "paint": the painted cost, discounted up to 40 % on a visible terrain trail
// unless a painted trail already owns the column. Same double arithmetic as GDScript lerpf().
inline double span_paint(const FloorSpan &span) {
	double paint = double(span.paint_byte) / PAINT_SCALE;
	if (!(span.flags & FLAG_PAINT_TRAIL)) {
		const double trail = double(span.trail_byte) / 255.0;
		paint *= 1.0 + (0.6 - 1.0) * trail;
	}
	return paint;
}

// Generic span input for the variable-floor producer and tests.
struct SpanInput {
	float floor_y = 0.0f;
	float headroom = 0.0f;
	float water_depth = 0.0f;
	uint8_t flags = FLAG_SOLID;
	uint8_t slope_deg = 0;
	uint8_t paint_byte = 50;
	uint8_t trail_byte = 0;
};

struct GroundChunk {
	ChunkKey key;
	uint64_t revision = 0;
	std::vector<uint32_t> column_offsets; // CHUNK_COLUMNS + 1 entries
	std::vector<FloorSpan> spans;
	// Lowest paint multiplier of any span: every edge into this chunk costs at least
	// length * CELL * cost_floor (slope and water factors are >= 1). Admissible A* bound.
	double cost_floor = INF;
	uint32_t max_column_spans = 0;

	uint32_t span_count() const { return uint32_t(spans.size()); }
	uint32_t column_begin(int32_t column) const { return column_offsets[size_t(column)]; }
	uint32_t column_end(int32_t column) const { return column_offsets[size_t(column) + 1]; }
	size_t memory_bytes() const;
};

// Converts one published walk_chunk.gd revision (flat slot arrays, `column * 2 + span`) into
// CSR storage. Only SOLID slots become spans; their slot order is kept, so the GDScript key
// Vector3i(x, slot, z) maps one to one onto (column, slot). `trail` may be shorter than the slot
// arrays (older cache files): missing entries read as 0, exactly like WalkGrid.sample().
std::shared_ptr<GroundChunk> build_chunk_from_legacy(const ChunkKey &key, const float *floor_y, size_t floor_count,
		const uint8_t *slope_deg, size_t slope_count, const float *water_depth, size_t water_count, const float *headroom,
		size_t headroom_count, const uint8_t *flags, size_t flags_count, const uint8_t *paint_cost, size_t paint_count,
		const uint8_t *trail_weight, size_t trail_count, std::string &error);

// Builds a chunk with any number of floors per column. `column_offsets` has CHUNK_COLUMNS + 1
// non-decreasing entries indexing `spans`; spans of a column are listed highest first.
std::shared_ptr<GroundChunk> build_chunk_from_columns(const ChunkKey &key, const std::vector<uint32_t> &column_offsets,
		const std::vector<SpanInput> &spans, std::string &error);

// An immutable set of published chunks that one search reads from start to finish.
struct Snapshot {
	uint64_t epoch = 0;
	std::vector<std::shared_ptr<const GroundChunk>> chunks; // sorted by ChunkKey::operator<
	std::unordered_map<uint64_t, uint32_t> index;
	double cost_floor = INF;
	size_t span_total = 0;

	int32_t find(const ChunkKey &key) const {
		const auto found = index.find(key.packed());
		return found == index.end() ? -1 : int32_t(found->second);
	}
	uint64_t revision_of(const ChunkKey &key) const {
		const int32_t at = find(key);
		return at < 0 ? 0 : chunks[size_t(at)]->revision;
	}
};

// Movement profile. Values are the pony's locomotion profile (walk_grid.gd profile()):
// radius, clearance (height), step, slope (degrees), wade depth and swim. `scale` multiplies
// radius, clearance and step the way PonyGaitProfile.rescale() does; the GDScript adapter
// passes already-scaled values with scale 1. `mask` holds capability bits; it is part of the
// cache signature so future surface filters (clouds) cannot share another body's answers.
struct GroundProfile {
	double radius = 0.45;
	double clearance = 1.2;
	double step = 0.117;
	double slope = 35.0;
	double wade = 0.35;
	bool swim = false;
	double scale = 1.0;
	uint32_t mask = 1;

	GroundProfile effective() const;
	uint64_t signature() const;
	bool same(const GroundProfile &other) const;
	bool valid(std::string &error) const;
};

constexpr uint32_t NO_COMPONENT = 0xffffffffu;

struct Portal {
	uint8_t neighbour = 0; // (dz + 1) * 3 + (dx + 1), never 4 (the chunk itself)
	uint32_t target_span = 0;
};

// Per (chunk, profile) derived data: body room per span, connected components and portals.
// Valid while the 5 x 5 chunk neighbourhood keeps the revisions in `stamp` (room looks across a
// chunk border; a portal's far cell looks one chunk further). Room values are written lazily by
// any worker with relaxed atomics: every writer computes the same value from the same data.
struct ProfileLayer {
	std::array<uint64_t, 25> stamp{};
	uint32_t span_count = 0;
	std::unique_ptr<std::atomic<uint8_t>[]> room; // 0 unknown, 1 blocked, 2 room
	std::mutex build_mutex;
	std::atomic<bool> components_ready{ false };
	std::vector<uint32_t> component; // per span; NO_COMPONENT without body room
	uint32_t component_count = 0;
	std::vector<uint8_t> touch; // per component: bit n = neighbour chunk n may hold a frontier
	std::vector<uint32_t> portal_offsets; // per component, CSR into portals
	std::vector<Portal> portals;
	std::atomic<uint64_t> last_used{ 0 };

	explicit ProfileLayer(uint32_t spans);
	size_t memory_bytes() const;
};

// Clearance cache keyed by chunk, full movement-profile signature and neighbourhood revisions.
// A filly's answer is never Celestia's: entries compare the whole profile, not only a hash.
class ClearanceCache {
public:
	explicit ClearanceCache(size_t limit = 1536);
	std::shared_ptr<ProfileLayer> acquire(const ChunkKey &key, const GroundProfile &profile,
			const std::array<uint64_t, 25> &stamp, uint32_t span_count);
	size_t layer_count() const;
	size_t memory_bytes() const;
	uint64_t hits() const { return hit_count.load(std::memory_order_relaxed); }
	uint64_t misses() const { return miss_count.load(std::memory_order_relaxed); }
	void clear();
	void set_limit(size_t limit);

private:
	struct Entry {
		GroundProfile profile;
		std::shared_ptr<ProfileLayer> layer;
	};
	void evict_locked();
	mutable std::mutex mutex;
	std::unordered_map<uint64_t, std::vector<Entry>> entries;
	size_t count = 0;
	size_t limit = 1536;
	std::atomic<uint64_t> use_clock{ 0 };
	std::atomic<uint64_t> hit_count{ 0 };
	std::atomic<uint64_t> miss_count{ 0 };
};

// Process-wide revision numbers: every publication gets a fresh one, so a (chunk, revision)
// stamp names exactly one immutable geometry version in any world.
uint64_t next_revision();

// One navigation world (one walk-grid service / zone). Main thread publishes and removes
// chunks; searches take an immutable snapshot and never see later edits.
class NavigationWorld {
public:
	explicit NavigationWorld(uint32_t id);
	uint32_t id() const { return world_id; }
	uint64_t publish(std::shared_ptr<GroundChunk> chunk);
	bool remove(const ChunkKey &key);
	void clear();
	uint64_t revision_of(const ChunkKey &key) const;
	std::shared_ptr<const GroundChunk> chunk(const ChunkKey &key) const;
	std::shared_ptr<const Snapshot> snapshot();
	size_t chunk_count() const;
	size_t memory_bytes() const;
	std::shared_ptr<ClearanceCache> cache() const { return clearance; }

private:
	uint32_t world_id = 0;
	mutable std::mutex mutex;
	std::unordered_map<uint64_t, std::shared_ptr<const GroundChunk>> chunks;
	std::shared_ptr<const Snapshot> current;
	bool dirty = true;
	uint64_t epoch = 0;
	std::shared_ptr<ClearanceCache> clearance;
};

} // namespace ponynav
