// Painted-vegetation cell fill across the WorkerThreadPool (see foliage_fill.h).
// dev 2026-10-20 multithreading. Every expression mirrors the GDScript it replaces, in the same
// precision: Vector2 math in float (real_t), GDScript `float` values in double, so a slot passes
// here exactly when it passes there. tools/foliage/test_native_fill_equivalence.gd compares both.
#include "foliage_fill.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

// Keep a*b + c*d as two roundings, like the engine's own Vector2 math on x86-64 (no fused
// multiply-add), so results stay bit-identical to GDScript where the compiler could fuse them.
#if defined(__clang__)
#pragma clang fp contract(off)
#endif

using namespace godot;

namespace {

constexpr int MAX_CANDIDATES_PER_CELL = 84; // BiomeFoliage.MAX_CANDIDATES_PER_CELL
constexpr int SIZE = 256; // WorldBiomeField.SIZE
constexpr int COUNT = 13; // WorldBiomeField.COUNT
constexpr double MAX_VEGETATION_DENSITY = 8.0;

inline int64_t tile_key(int64_t p_x, int64_t p_y) {
	return (int64_t)(((uint64_t)p_x << 32) ^ ((uint64_t)p_y & 0xffffffffULL));
}

// Image::get_pixel of an 8-bit channel: float(byte / 255.0).
inline float unit(uint8_t p_byte) {
	return (float)(p_byte / 255.0);
}

// BiomeFoliage._random: integer hash of the position, wrapping 64-bit multiply as GDScript does.
inline double fill_random(float p_x, float p_y, int64_t p_salt) {
	const int64_t a = (int64_t)std::floor((double)p_x * 31.0);
	const int64_t b = (int64_t)std::floor((double)p_y * 31.0);
	int64_t h = (int64_t)(((uint64_t)a * 73856093ULL) ^ ((uint64_t)b * 19349663ULL) ^ ((uint64_t)p_salt * 83492791ULL));
	h = (int64_t)(((uint64_t)(h ^ (h >> 13)) * 1274126177ULL) & 0x7fffffffULL);
	return (double)(h % 100000) / 100000.0;
}

inline double lerp_d(double p_from, double p_to, double p_weight) {
	return p_from + (p_to - p_from) * p_weight;
}

inline bool rect_has_point(const Rect2 &p_rect, float p_x, float p_y) {
	if (p_x < p_rect.position.x || p_y < p_rect.position.y) {
		return false;
	}
	if (p_x >= p_rect.position.x + p_rect.size.x || p_y >= p_rect.position.y + p_rect.size.y) {
		return false;
	}
	return true;
}

int density_candidate_count(int p_base, double p_density) {
	if (p_density <= 1.0) {
		return std::clamp(p_base, 0, MAX_CANDIDATES_PER_CELL);
	}
	return (int)std::clamp<int64_t>((int64_t)std::ceil(p_base * p_density), 0, MAX_CANDIDATES_PER_CELL);
}

double density_tree_spacing(double p_base, double p_density) {
	if (p_density <= 1.0) {
		return p_base;
	}
	return std::max(4.0, p_base / std::sqrt(p_density));
}

// BiomeFoliage._cell_slots for one cell, grown on demand (pure function of the cell).
struct Slots {
	Vector2i cell;
	std::vector<Vector2> points;
	std::vector<double> priorities;

	void ensure(int p_count) {
		const float ox = (float)cell.x;
		const float oy = (float)cell.y;
		for (int n = (int)points.size(); n < p_count; n++) {
			const float rx = (float)fill_random(ox, oy, n * 2 + 1);
			const float ry = (float)fill_random(ox, oy, n * 2 + 2);
			const Vector2 candidate(ox * 32.0f + rx * 32.0f, oy * 32.0f + ry * 32.0f);
			points.push_back(candidate);
			priorities.push_back(fill_random(candidate.x, candidate.y, 107));
		}
	}
};

struct SlotCache {
	std::vector<Slots> cells;

	Slots &get(const Vector2i &p_cell, int p_count) {
		for (Slots &slots : cells) {
			if (slots.cell == p_cell) {
				slots.ensure(p_count);
				return slots;
			}
		}
		cells.push_back(Slots());
		cells.back().cell = p_cell;
		cells.back().ensure(p_count);
		return cells.back();
	}
};

struct Sampler {
	const PonyFoliageFill::TileMap &tiles;

	const PonyFoliageFill::Tile *find(int64_t p_x, int64_t p_y) const {
		auto it = tiles.find(tile_key(p_x, p_y));
		return it == tiles.end() ? nullptr : it->second.get();
	}

	// WorldBiomeField.get_weights at a global field pixel (4 m cell); false when its tile is absent.
	bool weights(int64_t p_x, int64_t p_y, float *r_weights) const {
		const int64_t lx = (int64_t)std::floor((double)p_x / (double)SIZE);
		const int64_t ly = (int64_t)std::floor((double)p_y / (double)SIZE);
		const PonyFoliageFill::Tile *tile = find(lx, ly);
		if (tile == nullptr) {
			return false;
		}
		const int64_t ofs = ((p_y - ly * SIZE) * SIZE + (p_x - lx * SIZE)) * 4;
		for (int i = 0; i < 4; i++) {
			const uint8_t *pixel = tile->maps[i].ptr() + ofs;
			for (int j = 0; j < 4 && i * 4 + j < COUNT; j++) {
				r_weights[i * 4 + j] = unit(pixel[j]);
			}
		}
		return true;
	}

	// WorldBiomeField.sample_weights(pos).
	bool sample(const Vector2 &p_pos, float *r_weights) const {
		const float gx = p_pos.x / 4.0f;
		const float gy = p_pos.y / 4.0f;
		const int64_t cx = (int64_t)std::floor((double)gx);
		const int64_t cy = (int64_t)std::floor((double)gy);
		const float fx = gx - (float)cx;
		const float fy = gy - (float)cy;
		float a[COUNT], b[COUNT], c[COUNT], d[COUNT];
		if (!weights(cx, cy, a) || !weights(cx + 1, cy, b) || !weights(cx, cy + 1, c) || !weights(cx + 1, cy + 1, d)) {
			return false;
		}
		for (int i = 0; i < COUNT; i++) {
			r_weights[i] = (float)lerp_d(lerp_d(a[i], b[i], fx), lerp_d(c[i], d[i], fx), fy);
		}
		return true;
	}
};

// BiomeFoliage._tree_spacing.
bool tree_spacing(SlotCache &p_slots, const Vector2i &p_cell, const Vector2 &p_pos, double p_spacing, int p_candidates, int p_extra_start, int p_extra_count) {
	const double priority = fill_random(p_pos.x, p_pos.y, 107);
	const double limit = p_spacing * p_spacing;
	const int extra_end = p_extra_start >= 0 ? p_extra_start + p_extra_count : 0;
	const int count = std::max(p_candidates, extra_end);
	const double reach = p_spacing + 0.5;
	const float inside_x = p_pos.x - (float)p_cell.x * 32.0f;
	const float inside_y = p_pos.y - (float)p_cell.y * 32.0f;
	for (int z = p_cell.y - 1; z < p_cell.y + 2; z++) {
		if ((z < p_cell.y && inside_y > reach) || (z > p_cell.y && 32.0 - inside_y > reach)) {
			continue;
		}
		for (int x = p_cell.x - 1; x < p_cell.x + 2; x++) {
			if ((x < p_cell.x && inside_x > reach) || (x > p_cell.x && 32.0 - inside_x > reach)) {
				continue;
			}
			const Slots &slots = p_slots.get(Vector2i(x, z), count);
			for (int n = 0; n < p_candidates; n++) {
				if (slots.priorities[n] < priority && slots.points[n].distance_squared_to(p_pos) < limit) {
					return false;
				}
			}
			if (p_extra_start >= 0) {
				for (int n = p_extra_start; n < extra_end; n++) {
					if (slots.priorities[n] < priority && slots.points[n].distance_squared_to(p_pos) < limit) {
						return false;
					}
				}
			}
		}
	}
	return true;
}

bool could_be_tree(const std::vector<Vector2i> &p_rules, int p_n, double p_density) {
	for (const Vector2i &rule : p_rules) {
		if (p_n < rule.x) {
			return true;
		}
		if (p_n >= rule.y && p_n < std::min(MAX_CANDIDATES_PER_CELL, rule.y + density_candidate_count(rule.x, p_density) - rule.x)) {
			return true;
		}
	}
	return false;
}

} // namespace

void PonyFoliageFill::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "rows", "tree_rules", "everfree"), &PonyFoliageFill::configure);
	ClassDB::bind_method(D_METHOD("set_tile", "location", "data"), &PonyFoliageFill::set_tile);
	ClassDB::bind_method(D_METHOD("has_tile", "location"), &PonyFoliageFill::has_tile);
	ClassDB::bind_method(D_METHOD("erase_tile", "location"), &PonyFoliageFill::erase_tile);
	ClassDB::bind_method(D_METHOD("clear_tiles"), &PonyFoliageFill::clear_tiles);
	ClassDB::bind_method(D_METHOD("compute_cell", "cell", "trees_only", "keep_trees", "density_scale", "tree_slot_limit"), &PonyFoliageFill::compute_cell);
	ClassDB::bind_method(D_METHOD("submit", "cells", "density_scale", "tree_slot_limit"), &PonyFoliageFill::submit);
	ClassDB::bind_method(D_METHOD("is_busy"), &PonyFoliageFill::is_busy);
	ClassDB::bind_method(D_METHOD("is_ready"), &PonyFoliageFill::is_ready);
	ClassDB::bind_method(D_METHOD("collect"), &PonyFoliageFill::collect);
	ClassDB::bind_method(D_METHOD("pack_transforms", "transforms", "part", "multiply"), &PonyFoliageFill::pack_transforms);
	ClassDB::bind_method(D_METHOD("merge_bounds", "start", "first", "transforms", "part", "local", "multiply"), &PonyFoliageFill::merge_bounds);
}

PonyFoliageFill::~PonyFoliageFill() {
	// The jobs live in this object: never free them under a running group.
	wait();
}

void PonyFoliageFill::wait() {
	if (group < 0) {
		return;
	}
	WorkerThreadPool::get_singleton()->wait_for_group_task_completion(group);
	group = -1;
}

void PonyFoliageFill::configure(const Array &p_rows, const Array &p_tree_rules, const Rect2 &p_everfree) {
	std::shared_ptr<Config> next = std::make_shared<Config>();
	for (int64_t i = 0; i < p_rows.size(); i++) {
		const Array row = p_rows[i];
		PresetRow preset;
		const String family = row[0];
		preset.tree_slots = (int)(int64_t)row[1];
		preset.plant_slots = (int)(int64_t)row[2];
		preset.spacing = (double)row[3];
		preset.tree_family = family == "everfree" || family == "woodland" || family == "desert";
		preset.skip_family = family == "none" || family == "rock";
		next->rows.push_back(preset);
	}
	for (int64_t i = 0; i < p_tree_rules.size(); i++) {
		next->tree_rules.push_back((Vector2i)p_tree_rules[i]);
	}
	next->everfree = p_everfree;
	config = next;
}

bool PonyFoliageFill::set_tile(const Vector2i &p_location, const Dictionary &p_data) {
	// A rejected tile must not leave an older snapshot behind.
	erase_tile(p_location);
	auto plane = [](const Variant &p_image, Image::Format p_format, PackedByteArray &r_bytes) -> bool {
		const Ref<Image> image = p_image;
		if (image.is_null() || image->get_format() != p_format || image->get_width() != SIZE || image->get_height() != SIZE || image->has_mipmaps()) {
			return false;
		}
		r_bytes = image->get_data();
		return r_bytes.size() == (int64_t)SIZE * SIZE * (p_format == Image::FORMAT_RGBA8 ? 4 : 1);
	};
	std::shared_ptr<Tile> tile = std::make_shared<Tile>();
	const Array maps = p_data.get("maps", Array());
	if (maps.size() < 4) {
		return false;
	}
	for (int i = 0; i < 4; i++) {
		if (!plane(maps[i], Image::FORMAT_RGBA8, tile->maps[i])) {
			return false;
		}
	}
	if (!plane(p_data.get("coverage", Variant()), Image::FORMAT_L8, tile->coverage) || !plane(p_data.get("density", Variant()), Image::FORMAT_L8, tile->density)) {
		return false;
	}
	// Absent optional images keep the GDScript meaning (no boost, no override); present ones must fit.
	const Variant boost = p_data.get("density_boost", Variant());
	if (boost.get_type() != Variant::NIL) {
		if (!plane(boost, Image::FORMAT_L8, tile->boost)) {
			return false;
		}
		tile->has_boost = true;
	}
	const Variant vegetation = p_data.get("vegetation", Variant());
	if (vegetation.get_type() != Variant::NIL) {
		if (!plane(vegetation, Image::FORMAT_L8, tile->vegetation)) {
			return false;
		}
		tile->has_vegetation = true;
	}
	std::shared_ptr<TileMap> next = tiles ? std::make_shared<TileMap>(*tiles) : std::make_shared<TileMap>();
	(*next)[tile_key(p_location.x, p_location.y)] = tile;
	tiles = next;
	return true;
}

bool PonyFoliageFill::has_tile(const Vector2i &p_location) const {
	return tiles && tiles->count(tile_key(p_location.x, p_location.y)) > 0;
}

void PonyFoliageFill::erase_tile(const Vector2i &p_location) {
	if (!has_tile(p_location)) {
		return;
	}
	std::shared_ptr<TileMap> next = std::make_shared<TileMap>(*tiles);
	next->erase(tile_key(p_location.x, p_location.y));
	tiles = next;
}

void PonyFoliageFill::clear_tiles() {
	tiles.reset();
}

// BiomeFoliage._build_cell's slot loop, every test that reads neither the terrain nor physics.
void PonyFoliageFill::compute(const Config &p_config, const TileMap &p_tiles, Job &r_job) {
	r_job.status = OK;
	r_job.rows.clear();
	r_job.points.clear();
	r_job.spacing.clear();
	const Sampler sampler{ p_tiles };
	const Vector2i cell = r_job.cell;
	const float cell_x = (float)cell.x * 32.0f;
	const float cell_y = (float)cell.y * 32.0f;
	const int64_t cell_loc_x = (int64_t)std::floor((double)cell_x / 1024.0);
	const int64_t cell_loc_y = (int64_t)std::floor((double)cell_y / 1024.0);
	const Tile *cell_tile = sampler.find(cell_loc_x, cell_loc_y);
	if (cell_tile == nullptr) {
		r_job.status = FALLBACK;
		return;
	}
	// _density_at_most_one: no boost painted in the cell's 8x8 field pixels.
	bool at_most_one = true;
	if (cell_tile->has_boost) {
		const int64_t local_x = cell.x - cell_loc_x * 32;
		const int64_t local_y = cell.y - cell_loc_y * 32;
		const uint8_t *boost = cell_tile->boost.ptr();
		for (int64_t z = local_y * 8; z < local_y * 8 + 8 && at_most_one; z++) {
			for (int64_t x = local_x * 8; x < local_x * 8 + 8; x++) {
				if (boost[z * SIZE + x] != 0) {
					at_most_one = false;
					break;
				}
			}
		}
	}
	const int slot_count = r_job.trees_only && at_most_one ? r_job.tree_slot_limit : MAX_CANDIDATES_PER_CELL;
	SlotCache cache;
	cache.get(cell, slot_count);
	const int rows = (int)p_config.rows.size();
	float w[COUNT];
	for (int n = 0; n < slot_count; n++) {
		// Neighbour spacing checks may append to the cache: re-read the point each slot.
		const Vector2 p = cache.get(cell, slot_count).points[n];
		const int64_t loc_x = (int64_t)std::floor((double)p.x / 1024.0);
		const int64_t loc_y = (int64_t)std::floor((double)p.y / 1024.0);
		const Tile *data = loc_x == cell_loc_x && loc_y == cell_loc_y ? cell_tile : sampler.find(loc_x, loc_y);
		if (data == nullptr) {
			r_job.status = FALLBACK;
			return;
		}
		const int pixel_x = std::clamp((int)((p.x - (float)(loc_x * 1024)) / 4.0f), 0, 255);
		const int pixel_y = std::clamp((int)((p.y - (float)(loc_y * 1024)) / 4.0f), 0, 255);
		const int ofs = pixel_y * SIZE + pixel_x;
		const bool authored = data->coverage.ptr()[ofs] != 0;
		double density = 1.0;
		if (authored) {
			density = (double)unit(data->density.ptr()[ofs]);
			if (data->has_boost) {
				density = density + (double)unit(data->boost.ptr()[ofs]) * (MAX_VEGETATION_DENSITY - 1.0);
			}
		}
		if (n >= 42 && density <= 1.0) {
			continue;
		}
		if (r_job.trees_only && !could_be_tree(p_config.tree_rules, n, density)) {
			continue;
		}
		if (!authored && !rect_has_point(p_config.everfree, p.x, p.y)) {
			continue;
		}
		int64_t override_biome = -1;
		if (authored && data->has_vegetation) {
			override_biome = (int64_t)std::round((double)unit(data->vegetation.ptr()[ofs]) * 255.0) - 1;
		}
		int64_t selected = 0;
		bool sampled = false;
		if (override_biome >= 0) {
			selected = override_biome;
		} else {
			if (!sampler.sample(p, w)) {
				r_job.status = FALLBACK;
				return;
			}
			sampled = true;
			double roll = fill_random(p.x, p.y, 54);
			for (int i = 0; i < COUNT; i++) {
				roll -= (double)w[i];
				if (roll <= 0) {
					selected = i;
					break;
				}
			}
		}
		if (selected >= rows) {
			r_job.status = FALLBACK;
			return;
		}
		const PresetRow &row = p_config.rows[selected];
		const int base_tree_slots = row.tree_slots;
		const int base_plant_slots = row.plant_slots;
		const int tree_slots = density_candidate_count(base_tree_slots, density);
		const int extra_tree_slots = tree_slots - base_tree_slots;
		const int candidate_limit = std::min(MAX_CANDIDATES_PER_CELL, base_plant_slots + extra_tree_slots);
		const double spacing = density_tree_spacing(row.spacing, density);
		bool tree = (n < base_tree_slots || (n >= base_plant_slots && n < candidate_limit)) && row.tree_family;
		if (r_job.trees_only && !tree) {
			continue;
		}
		if (r_job.keep_trees && tree) {
			continue;
		}
		if (n >= candidate_limit) {
			continue;
		}
		if (!authored) {
			if (!rect_has_point(p_config.everfree, p.x, p.y) || !sampled || (double)w[3] < 0.5) {
				continue;
			}
			if (tree && (n >= 2 || fill_random(p.x, p.y, 93) > 0.45)) {
				continue;
			}
			if (!tree && n >= 18) {
				continue;
			}
		} else if (density <= 1.0 && fill_random(p.x, p.y, 51) > density) {
			continue;
		}
		if (row.skip_family) {
			continue;
		}
		if (r_job.density_scale < 1.0 && fill_random(p.x, p.y, 71) > r_job.density_scale) {
			continue;
		}
		// Terrain height/normal come next in GDScript; they are tested on the main thread.
		if (tree && !tree_spacing(cache, cell, p, spacing, base_tree_slots, base_plant_slots, extra_tree_slots)) {
			continue;
		}
		r_job.rows.push_back(n);
		r_job.rows.push_back((int32_t)selected);
		r_job.rows.push_back(tree ? 1 : 0);
		r_job.points.push_back(p);
		r_job.spacing.push_back(spacing);
	}
}

Dictionary PonyFoliageFill::job_result(const Job &p_job) {
	Dictionary out;
	out["cell"] = p_job.cell;
	out["status"] = p_job.status;
	out["trees_only"] = p_job.trees_only;
	out["keep_trees"] = p_job.keep_trees;
	out["density_scale"] = p_job.density_scale;
	out["slot_limit"] = p_job.tree_slot_limit;
	PackedInt32Array rows;
	rows.resize((int64_t)p_job.rows.size());
	std::copy(p_job.rows.begin(), p_job.rows.end(), rows.ptrw());
	PackedVector2Array points;
	points.resize((int64_t)p_job.points.size());
	std::copy(p_job.points.begin(), p_job.points.end(), points.ptrw());
	PackedFloat64Array spacing;
	spacing.resize((int64_t)p_job.spacing.size());
	std::copy(p_job.spacing.begin(), p_job.spacing.end(), spacing.ptrw());
	out["rows"] = rows;
	out["points"] = points;
	out["spacing"] = spacing;
	return out;
}

Dictionary PonyFoliageFill::compute_cell(const Vector2i &p_cell, bool p_trees_only, bool p_keep_trees, double p_density_scale, int p_tree_slot_limit) const {
	Job job;
	job.cell = p_cell;
	job.trees_only = p_trees_only;
	job.keep_trees = p_keep_trees;
	job.density_scale = p_density_scale;
	job.tree_slot_limit = p_tree_slot_limit;
	if (!config || !tiles) {
		job.status = FALLBACK;
	} else {
		compute(*config, *tiles, job);
	}
	return job_result(job);
}

void PonyFoliageFill::run_job(void *p_batch, uint32_t p_index) {
	Batch *batch = static_cast<Batch *>(p_batch);
	compute(*batch->config, *batch->tiles, batch->jobs[p_index]);
}

bool PonyFoliageFill::submit(const PackedInt32Array &p_cells, double p_density_scale, int p_tree_slot_limit) {
	if (group >= 0 || !config || !tiles) {
		return false;
	}
	batch.config = config;
	batch.tiles = tiles;
	batch.jobs.clear();
	for (int64_t i = 0; i + 2 < p_cells.size(); i += 3) {
		Job job;
		job.cell = Vector2i(p_cells[i], p_cells[i + 1]);
		job.trees_only = (p_cells[i + 2] & 1) != 0;
		job.keep_trees = (p_cells[i + 2] & 2) != 0;
		job.density_scale = p_density_scale;
		job.tree_slot_limit = p_tree_slot_limit;
		batch.jobs.push_back(job);
	}
	if (batch.jobs.empty()) {
		return false;
	}
	// Low priority: background streaming work that nobody waits on this frame; the pool's
	// low-priority share leaves threads free for the engine's own high-priority jobs. Task count
	// -1 = one task per pool thread, so it scales with the machine's cores.
	group = WorkerThreadPool::get_singleton()->add_native_group_task(&PonyFoliageFill::run_job, &batch,
			(int)batch.jobs.size(), -1, false, String("Foliage cell fill"));
	return true;
}

bool PonyFoliageFill::is_busy() const {
	return group >= 0;
}

bool PonyFoliageFill::is_ready() const {
	return group >= 0 && WorkerThreadPool::get_singleton()->is_group_task_completed(group);
}

Array PonyFoliageFill::collect() {
	Array out;
	if (group < 0) {
		return out;
	}
	wait();
	for (const Job &job : batch.jobs) {
		out.push_back(job_result(job));
	}
	batch.jobs.clear();
	batch.config.reset();
	batch.tiles.reset();
	return out;
}

PackedFloat32Array PonyFoliageFill::pack_transforms(const Array &p_transforms, const Transform3D &p_part, bool p_multiply) const {
	PackedFloat32Array data;
	const int64_t count = p_transforms.size();
	data.resize(count * 12);
	float *out = data.ptrw();
	for (int64_t i = 0; i < count; i++) {
		const Transform3D source = p_transforms[i];
		const Transform3D t = p_multiply ? source * p_part : source;
		float *row = out + i * 12;
		for (int r = 0; r < 3; r++) {
			row[r * 4 + 0] = t.basis.rows[r][0];
			row[r * 4 + 1] = t.basis.rows[r][1];
			row[r * 4 + 2] = t.basis.rows[r][2];
			row[r * 4 + 3] = t.origin[r];
		}
	}
	return data;
}

Array PonyFoliageFill::merge_bounds(const AABB &p_start, bool p_first, const Array &p_transforms, const Transform3D &p_part, const AABB &p_local, bool p_multiply) const {
	AABB bounds = p_start;
	bool first = p_first;
	const int64_t count = p_transforms.size();
	for (int64_t i = 0; i < count; i++) {
		const Transform3D source = p_transforms[i];
		const AABB box = (p_multiply ? source * p_part : source).xform(p_local);
		bounds = first ? box : bounds.merge(box);
		first = false;
	}
	Array out;
	out.push_back(bounds);
	out.push_back(first);
	return out;
}
