// Offline nav_air baker: extracted geometry columns -> runtime air data for one flight profile
// (docs/NAVIGATION_AIR_STORAGE_2026_10_02.md). Plain C++17, built with g++ directly:
//   g++ -std=c++17 -O2 -pthread -fno-exceptions nav_air/air_bake_main.cpp nav_air/air_tiles.cpp
//       nav_air/air_voxelize.cpp nav_air/air_serialize.cpp -o air_bake
// Usage:
//   air_bake --geometry DIR --out FILE --profile NAME --radius METRES
//            [--centre-offset X,Y,Z] [--above METRES] [--below METRES] [--threads N]
// DIR holds region.txt and col_<tx>_<tz>.bin from tools/navigation/air_extract_geometry.gd.
#include "air_serialize.h"
#include "air_tiles.h"
#include "air_voxelize.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace nav_air;

namespace {

double seconds_since(std::chrono::steady_clock::time_point t0) {
	return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

int usage() {
	std::fprintf(stderr,
			"usage: air_bake --geometry DIR --out FILE --profile NAME --radius METRES [--centre-offset X,Y,Z]\n"
			"                [--above METRES] [--below METRES] [--threads N]\n");
	return 2;
}

bool number(const std::map<std::string, std::string> &m, const char *key, double &out) {
	auto it = m.find(key);
	if (it == m.end()) return false;
	char *end = nullptr;
	out = std::strtod(it->second.c_str(), &end);
	return end && *end == 0 && std::isfinite(out);
}

}  // namespace

int main(int argc, char **argv) {
	std::string geometry_dir, out_path, profile_name;
	double radius = -1, above = 128.0, below = 16.0;
	float centre[3] = {0.0f, 0.8f, 0.0f};
	int threads = int(std::max(1u, std::min(8u, std::thread::hardware_concurrency() / 2)));
	for (int i = 1; i < argc; ++i) {
		const std::string a = argv[i];
		const bool has = i + 1 < argc;
		if (a == "--geometry" && has) geometry_dir = argv[++i];
		else if (a == "--out" && has) out_path = argv[++i];
		else if (a == "--profile" && has) profile_name = argv[++i];
		else if (a == "--radius" && has) radius = std::atof(argv[++i]);
		else if (a == "--above" && has) above = std::atof(argv[++i]);
		else if (a == "--below" && has) below = std::atof(argv[++i]);
		else if (a == "--threads" && has) threads = std::max(1, std::atoi(argv[++i]));
		else if (a == "--centre-offset" && has) {
			if (std::sscanf(argv[++i], "%f,%f,%f", &centre[0], &centre[1], &centre[2]) != 3) return usage();
		} else return usage();
	}
	if (geometry_dir.empty() || out_path.empty() || profile_name.empty() || !(radius >= 0)) return usage();

	const auto t_start = std::chrono::steady_clock::now();
	std::map<std::string, std::string> manifest;
	std::string error;
	if (!read_manifest(geometry_dir + "/region.txt", manifest, &error)) {
		std::fprintf(stderr, "AIR_BAKE_FAIL manifest: %s\n", error.c_str());
		return 1;
	}
	double tx0, tx1, tz0, tz1, terrain_min, terrain_max, geometry_max, margin, tile_size;
	if (!number(manifest, "tx_min", tx0) || !number(manifest, "tx_max", tx1) || !number(manifest, "tz_min", tz0) ||
			!number(manifest, "tz_max", tz1) || !number(manifest, "terrain_min", terrain_min) ||
			!number(manifest, "terrain_max", terrain_max) || !number(manifest, "geometry_max_y", geometry_max) ||
			!number(manifest, "margin", margin) || !number(manifest, "tile_size", tile_size)) {
		std::fprintf(stderr, "AIR_BAKE_FAIL manifest keys missing\n");
		return 1;
	}
	if (tile_size != TILE_SIZE) {
		std::fprintf(stderr, "AIR_BAKE_FAIL tile size %.1f != %.1f\n", tile_size, double(TILE_SIZE));
		return 1;
	}
	if (margin + 1e-6 < margin_metres(float(radius))) {
		std::fprintf(stderr, "AIR_BAKE_FAIL geometry margin %.2f m < required %.2f m\n", margin, margin_metres(float(radius)));
		return 1;
	}
	const int ty0 = int(std::floor((terrain_min - below) / TILE_SIZE));
	const int ty1 = int(std::floor((std::max(geometry_max, terrain_max) + above) / TILE_SIZE));
	struct Column { int tx, tz; };
	std::vector<Column> columns;
	for (int tz = int(tz0); tz <= int(tz1); ++tz)
		for (int tx = int(tx0); tx <= int(tx1); ++tx) columns.push_back({tx, tz});
	std::printf("AIR_BAKE region tiles x %d..%d z %d..%d y %d..%d (%zu columns, %d levels), profile %s radius %.2f m, %d threads\n",
			int(tx0), int(tx1), int(tz0), int(tz1), ty0, ty1, columns.size(), ty1 - ty0 + 1, profile_name.c_str(), radius, threads);

	BakeParams params;
	params.envelope_radius = float(radius);
	params.require_terrain = true;
	std::mutex lock;
	std::vector<std::shared_ptr<AirTile>> baked;
	std::vector<std::pair<int, uint64_t>> column_hashes;
	TileBakeStats total;
	size_t skipped_tiles = 0, missing_columns = 0, triangles = 0, convexes = 0, fields = 0, hull_fallbacks = 0;
	std::map<int, size_t> class_triangles;
	std::vector<std::string> notes;
	std::atomic<size_t> next{0};
	auto worker = [&]() {
		std::vector<uint8_t> bytes;
		for (;;) {
			const size_t index = next.fetch_add(1);
			if (index >= columns.size()) return;
			const Column col = columns[index];
			const std::string path = geometry_dir + "/col_" + std::to_string(col.tx) + "_" + std::to_string(col.tz) + ".bin";
			std::string why;
			GeometryColumn geo;
			if (!load_file(path, bytes, &why) || !read_geometry_column(bytes.data(), bytes.size(), geo, &why) ||
					geo.tx != col.tx || geo.tz != col.tz) {
				std::lock_guard<std::mutex> g(lock);
				++missing_columns;
				notes.push_back("column " + std::to_string(col.tx) + "," + std::to_string(col.tz) + ": " + (why.empty() ? "key mismatch" : why));
				continue;
			}
			geo.geometry.prepare();
			size_t fallbacks = 0;
			for (const ConvexSolid &s : geo.geometry.convexes) fallbacks += s.box_fallback;
			std::vector<std::shared_ptr<AirTile>> mine;
			TileBakeStats stats;
			size_t skipped = 0;
			std::string first_skip;
			for (int ty = ty0; ty <= ty1; ++ty) {
				std::string skip;
				auto tile = bake_tile({col.tx, ty, col.tz}, geo.geometry, params, &stats, &skip);
				if (tile) mine.push_back(tile);
				else {
					++skipped;
					if (first_skip.empty()) first_skip = skip;
				}
			}
			std::lock_guard<std::mutex> g(lock);
			for (auto &t : mine) baked.push_back(t);
			column_hashes.emplace_back(int(index), geo.geometry.source_hash);
			total.triangles_tested += stats.triangles_tested;
			total.convexes_tested += stats.convexes_tested;
			total.raw_solid += stats.raw_solid;
			total.inflated_solid += stats.inflated_solid;
			total.uncovered_columns += stats.uncovered_columns;
			skipped_tiles += skipped;
			triangles += geo.triangles;
			convexes += geo.convexes;
			fields += geo.fields;
			hull_fallbacks += fallbacks;
			for (const TriangleSoup &s : geo.geometry.soups) class_triangles[int(s.cls)] += s.triangle_count();
			if (skipped) notes.push_back("column " + std::to_string(col.tx) + "," + std::to_string(col.tz) + ": " +
					std::to_string(skipped) + " tiles skipped (" + first_skip + ")");
		}
	};
	const auto t_voxel = std::chrono::steady_clock::now();
	std::vector<std::thread> pool;
	for (int i = 0; i < threads; ++i) pool.emplace_back(worker);
	for (std::thread &t : pool) t.join();
	const double voxel_seconds = seconds_since(t_voxel);

	AirProfile profile;
	profile.name = profile_name;
	profile.envelope_radius = float(radius);
	profile.centre_offset = {centre[0], centre[1], centre[2]};
	AirTileSpace space(profile);
	const auto t_publish = std::chrono::steady_clock::now();
	for (auto &t : baked) space.publish(t);
	baked.clear();
	const double publish_seconds = seconds_since(t_publish);
	const auto t_seal = std::chrono::steady_clock::now();
	const size_t sealed = space.seal_enclosed(space.keys());
	const double seal_seconds = seconds_since(t_seal);

	std::sort(column_hashes.begin(), column_hashes.end());
	uint64_t source_hash = 1469598103934665603ull;
	for (const auto &h : column_hashes) source_hash = fnv1a(&h.second, sizeof(h.second), source_hash);
	std::vector<uint8_t> data;
	const auto t_write = std::chrono::steady_clock::now();
	if (!write_air_data(space, source_hash, data) || !save_file(out_path, data, &error)) {
		std::fprintf(stderr, "AIR_BAKE_FAIL write: %s\n", error.c_str());
		return 1;
	}
	const double write_seconds = seconds_since(t_write);

	// Read back and compare every tile.
	const auto t_load = std::chrono::steady_clock::now();
	std::vector<uint8_t> again;
	AirTileSpace loaded;
	AirDataInfo info;
	if (!load_file(out_path, again, &error) || !read_air_data(again.data(), again.size(), loaded, &info, &error)) {
		std::fprintf(stderr, "AIR_BAKE_FAIL reload: %s\n", error.c_str());
		return 1;
	}
	const double load_seconds = seconds_since(t_load);
	size_t mismatched = 0;
	for (const TileKey &k : space.keys()) {
		const AirTile *a = space.find(k), *b = loaded.find(k);
		if (!b || a->uniform != b->uniform || a->coarse != b->coarse || a->bricks != b->bricks ||
				a->component_count != b->component_count)
			++mismatched;
	}
	if (loaded.tile_count() != space.tile_count()) ++mismatched;

	size_t uniform_free = 0, uniform_solid = 0, mixed = 0, components = 0;
	for (const TileKey &k : space.keys()) {
		const AirTile *t = space.find(k);
		components += t->component_count;
		if (t->uniform == uint8_t(Cell::FREE)) ++uniform_free;
		else if (t->uniform == uint8_t(Cell::SOLID)) ++uniform_solid;
		else ++mixed;
	}
	const double mib = 1.0 / (1024.0 * 1024.0);
	std::printf("AIR_BAKE geometry: %zu triangles, %zu convex solids (%zu AABB fallbacks), %zu heightfields; triangle tests %zu, convex tests %zu\n",
			triangles, convexes, hull_fallbacks, fields, total.triangles_tested, total.convexes_tested);
	for (const auto &c : class_triangles)
		std::printf("AIR_BAKE   %s triangles %zu\n", source_class_name(SourceClass(c.first)), c.second);
	std::printf("AIR_BAKE tiles: %zu (uniform free %zu, uniform solid %zu, mixed %zu), bricks %zu, components %zu, skipped tiles %zu, missing columns %zu, sealed tiles %zu\n",
			space.tile_count(), uniform_free, uniform_solid, mixed, space.brick_count(), components, skipped_tiles, missing_columns, sealed);
	std::printf("AIR_BAKE memory: resident %.2f MiB, file %.2f MiB\n", space.memory_bytes() * mib, data.size() * mib);
	std::printf("AIR_BAKE time: voxelize+inflate %.2f s, publish/components %.2f s, seal %.2f s, write %.2f s, reload %.2f s, total %.2f s\n",
			voxel_seconds, publish_seconds, seal_seconds, write_seconds, load_seconds, seconds_since(t_start));
	std::printf("AIR_BAKE source hash %016llx, reload mismatches %zu\n", (unsigned long long)source_hash, mismatched);
	for (size_t i = 0; i < notes.size() && i < 40; ++i) std::printf("AIR_BAKE note %s\n", notes[i].c_str());
	if (notes.size() > 40) std::printf("AIR_BAKE note ... %zu more\n", notes.size() - 40);
	const bool ok = mismatched == 0 && space.tile_count() > 0;
	std::printf("%s\n", ok ? "AIR_BAKE_DONE" : "AIR_BAKE_FAIL");
	return ok ? 0 : 1;
}
