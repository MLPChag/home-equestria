#pragma once
// nav_air binary formats (docs/NAVIGATION_AIR_STORAGE_2026_10_02.md). All little-endian.
//
// Runtime air data (world/navigation/air_data/*.airnav), version 1:
//   "HEAIRNAV" u32 version | f32 tile, coarse, fine sizes | u32 cells per axis (8)
//   f64 origin x, y, z (world position of tile (0,0,0)'s corner, 0 today) | u64 source hash
//   f32 envelope radius | f32 centre offset x, y, z | u16 profile name length + bytes
//   i32 min tile x, y, z | i32 max tile x, y, z (inclusive) | u32 tile count
//   per tile (sorted y, z, x): i32 x, y, z | u64 tile source hash | u8 uniform state
//     (1 FREE, 2 SOLID, 0 = arrays follow: u16 coarse[512] | u16 brick count | 128 B per brick)
//   u64 FNV-1a of every preceding byte.
// No paths, user names or timestamps are stored. Revisions are not stored: every load
// publishes fresh process-wide revisions. Components are derived again on load.
//
// Extracted geometry per tile column (captures only, tools/navigation/air_extract_geometry.gd):
//   "HEAIRGEO" u32 version (1) | i32 tx, tz | f32 tile size, margin | u32 record count
//   record: u8 kind, u8 class (SourceClass), u16 reserved, u32 count, then
//     kind 1 triangles: f32[9 * count]; kind 2 convex points: f32[3 * count];
//     kind 3 heightfield: f32 x0, z0, dx, dz, i32 w, d (count = w * d), f32 heights[count]
//   (world metres; NaN height = hole).
#include "air_tiles.h"
#include "air_voxelize.h"

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace nav_air {

constexpr uint32_t AIR_DATA_VERSION = 1;
constexpr uint32_t AIR_GEOMETRY_VERSION = 1;

uint64_t fnv1a(const void *data, size_t size, uint64_t seed = 1469598103934665603ull);

struct AirDataInfo {
	uint32_t version = 0;
	float tile_size = 0, coarse_size = 0, fine_size = 0;
	double origin[3] = {0, 0, 0};
	uint64_t source_hash = 0;
	AirProfile profile;
	TileKey min{}, max{};
	uint32_t tile_count = 0;
};

// Serializes every tile of `space` (sorted). Returns false if the profile name is too long.
bool write_air_data(const AirTileSpace &space, uint64_t source_hash, std::vector<uint8_t> &out);
// Validates and loads into `space` (tiles published with new revisions, profile set).
// On any failure nothing is published and `error` says why.
bool read_air_data(const uint8_t *data, size_t size, AirTileSpace &space, AirDataInfo *info, std::string *error);

bool save_file(const std::string &path, const std::vector<uint8_t> &bytes, std::string *error);
bool load_file(const std::string &path, std::vector<uint8_t> &bytes, std::string *error);

struct GeometryColumn {
	int32_t tx = 0, tz = 0;
	float tile_size = 0, margin = 0;
	GeometrySet geometry;  // source_hash = FNV-1a of the file bytes
	size_t triangles = 0, convexes = 0, fields = 0;
};
bool read_geometry_column(const uint8_t *data, size_t size, GeometryColumn &out, std::string *error);

// key=value lines (the extractor's region.txt). Blank lines and '#' comments are ignored.
bool read_manifest(const std::string &path, std::map<std::string, std::string> &out, std::string *error);

}  // namespace nav_air
