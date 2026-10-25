#pragma once
// Conservative voxelization and per-profile inflation for nav_air tiles
// (docs/NAVIGATION_AIR_STORAGE_2026_10_02.md).
//
// Pipeline for one tile (bake_tile):
//  1. Raw occupancy at 0.5 m over the tile plus a margin that covers the envelope reach:
//     - terrain heightfields fill every cell from the bottom up to the HIGHEST vertex of any
//       heightfield quad touching the cell's column (independent of the quad diagonal, so the
//       ground below the surface can never become a tunnel);
//     - collision triangles mark every cell whose closed box they touch (exact triangle/box
//       separating-axis test in double precision with a small box growth; the triangle AABB
//       only narrows candidates);
//     - closed convex solids (boxes, cylinder prisms, capsules, convex shapes, tree envelopes)
//       mark every cell their volume touches (hull planes + triangle SAT on the boundary).
//  2. Inflation, applied exactly once: a cell becomes SOLID when its box comes within the
//     envelope radius of a raw SOLID box (box-to-box distance; equal to the Euclidean distance
//     transform of the raw cells grown by one cell). A FREE cell therefore keeps every point
//     inside it farther than the radius from all geometry, discretization included.
//  3. Coarse/fine compaction (air_tiles.cpp make_tile).
// Enclosed pockets are filled afterwards across tiles (AirTileSpace::seal_enclosed).
#include "air_tiles.h"

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace nav_air {

// Where the geometry came from (statistics and debugging; voxelization treats all alike
// except TERRAIN heightfields, which fill downward).
enum class SourceClass : uint8_t {
	TERRAIN = 0,
	BUILDING = 1,
	STRUCTURE = 2,
	CLOUD = 3,
	FOLIAGE_TRUNK = 4,
	FOLIAGE_CROWN = 5,
	OTHER = 6,
	COUNT = 7,
};
const char *source_class_name(SourceClass c);

struct TriangleSoup {
	SourceClass cls = SourceClass::OTHER;
	std::vector<float> xyz;  // 9 floats per triangle, world metres
	size_t triangle_count() const { return xyz.size() / 9; }
};

struct ConvexSolid {
	SourceClass cls = SourceClass::OTHER;
	std::vector<Vec3> points;  // world metres; the solid is their convex hull
	// Derived by prepare(): hull triangles and outward planes (n, d with n.p <= d inside).
	std::vector<std::array<double, 9>> triangles;
	std::vector<std::array<double, 4>> planes;
	double box_min[3] = {0, 0, 0}, box_max[3] = {0, 0, 0};
	bool box_fallback = false;  // degenerate/unverifiable hull: the points' AABB is used
	bool prepared = false;
	void prepare();
};

struct HeightField {
	SourceClass cls = SourceClass::TERRAIN;
	double x0 = 0, z0 = 0;  // world position of vertex (0, 0)
	double dx = 1, dz = 1;  // vertex spacing
	int32_t w = 0, d = 0;   // vertices along X and Z
	std::vector<float> heights;  // w * d, index i + w * j; NaN = hole (no collision there)
};

struct GeometrySet {
	std::vector<TriangleSoup> soups;
	std::vector<ConvexSolid> convexes;
	std::vector<HeightField> fields;
	uint64_t source_hash = 0;
	void prepare();  // hulls for every convex
};

// Instanced geometry (MultiMesh / foliage): one convex prototype per instance transform.
// `transforms` holds 12 floats per instance: basis columns x, y, z then origin.
void add_instanced_convex(GeometrySet &set, SourceClass cls, const std::vector<Vec3> &prototype,
		const std::vector<float> &transforms);

struct BakeParams {
	float envelope_radius = 0.0f;  // metres; the profile envelope, applied once
	bool raw_only = false;         // tests: skip inflation (raw conservative occupancy)
	bool require_terrain = true;   // skip a tile whose columns are not all covered by a heightfield
	double box_epsilon = 1e-4;     // metres added to every cell box in overlap tests
};

struct TileBakeStats {
	size_t triangles_tested = 0;
	size_t convexes_tested = 0;
	size_t raw_solid = 0;
	size_t inflated_solid = 0;
	size_t uncovered_columns = 0;
};

// Fine cells of inflation reach beyond the tile (geometry must be supplied that far out).
int margin_cells(float envelope_radius);
double margin_metres(float envelope_radius);

// Voxelizes one tile from `geometry` (which must contain everything within margin_metres of
// the tile). Returns nullptr when require_terrain is set and some column lacks heightfield
// coverage (`why` says so); missing data stays a missing tile (UNKNOWN), never FREE.
std::shared_ptr<AirTile> bake_tile(const TileKey &key, const GeometrySet &geometry, const BakeParams &params,
		TileBakeStats *stats = nullptr, std::string *why = nullptr);

// Dirty-tile rebuild entry point: re-voxelizes `dirty` from `geometry`, publishes each with a
// new revision (a tile that cannot be baked is removed: UNKNOWN), then reseals the dirty
// tiles plus their face neighbours. Returns the number of tiles republished or removed.
size_t rebuild_tiles(AirTileSpace &space, const std::vector<TileKey> &dirty, const GeometrySet &geometry,
		const BakeParams &params);

// Exposed for tests.
bool triangle_box_overlap(const double centre[3], const double half[3], const double tri[9]);
double point_triangle_distance(const double p[3], const double tri[9]);

}  // namespace nav_air
