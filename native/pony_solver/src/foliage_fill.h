// Painted-vegetation cell fill (world/foliage/biome_foliage.gd _build_cell) in C++ across the
// WorkerThreadPool, plus the MultiMesh packing/bounds loops of biome_foliage.gd and
// painted_tree_batches.gd. dev 2026-10-20 multithreading.
//
// What runs where:
// - Workers (add_native_group_task, one element per cell, low priority, task count chosen by the
//   pool, so it scales with threading/worker_pool/max_threads = the processor count by default):
//   every pure per-slot test of _build_cell — slot positions, coverage/density/vegetation-biome
//   pixels, the bilinear biome weights (WorldBiomeField.sample_weights), the preset roll, the
//   density and setting thinning, _could_be_tree and the cross-cell tree spacing (_tree_spacing).
//   Output: the surviving slots in slot order.
// - Main thread (GDScript): terrain height/normal/control, the physics ray, the catalogue pick and
//   transforms for those survivors only, and all node/MultiMesh creation.
//
// Ownership and synchronisation (no locks on the hot path):
// - Config and the tile table are immutable once published: the main thread builds a new
//   shared_ptr<const ...> on every change, and each batch copies the pointers when submitted.
//   Workers only read them; a reference keeps them alive until the batch is collected.
// - Tile pixels are PackedByteArray copies of the field Images' data (copy-on-write: no pixel copy;
//   a later write to the Image copies away from the snapshot, so workers never see a change).
// - A batch's jobs vector is written by the main thread before add_native_group_task, each element
//   only by the one worker that processes that index, and read by the main thread only after
//   wait_for_group_task_completion (its semaphore orders the workers' writes before the reads).
//   The main thread never touches the jobs while the group runs (busy flag).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/worker_thread_pool.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <map>
#include <memory>
#include <vector>

namespace godot {

class PonyFoliageFill : public RefCounted {
	GDCLASS(PonyFoliageFill, RefCounted)

public:
	// One field tile (WorldBiomeField.tile): 4 RGBA8 weight maps and 4 L8 maps, 256x256.
	struct Tile {
		PackedByteArray maps[4];
		PackedByteArray coverage;
		PackedByteArray density;
		PackedByteArray boost; // empty: no density_boost image (density stays the base value)
		PackedByteArray vegetation; // empty: no vegetation image (no override)
		bool has_boost = false;
		bool has_vegetation = false;
	};
	struct PresetRow {
		int tree_slots = 3;
		int plant_slots = 24;
		double spacing = 20.0;
		bool tree_family = false; // everfree, woodland, desert
		bool skip_family = false; // none, rock
	};
	struct Config {
		std::vector<PresetRow> rows;
		std::vector<Vector2i> tree_rules;
		Rect2 everfree;
	};
	using TileMap = std::map<int64_t, std::shared_ptr<const Tile>>;

	enum Status {
		OK = 0,
		FALLBACK = 1, // needs a tile this snapshot lacks (or an unexpected index): use the GDScript path
	};

	struct Job {
		Vector2i cell;
		bool trees_only = false;
		bool keep_trees = false;
		double density_scale = 1.0;
		int tree_slot_limit = 0;
		// Results.
		int status = OK;
		std::vector<int32_t> rows; // per survivor: slot, preset index, tree
		std::vector<Vector2> points;
		std::vector<double> spacing;
	};

private:
	std::shared_ptr<const Config> config;
	std::shared_ptr<const TileMap> tiles;
	// The in-flight batch: written before submit, read after the group completes.
	struct Batch {
		std::shared_ptr<const Config> config;
		std::shared_ptr<const TileMap> tiles;
		std::vector<Job> jobs;
	};
	Batch batch;
	int64_t group = -1;

	static void run_job(void *p_batch, uint32_t p_index);
	static void compute(const Config &p_config, const TileMap &p_tiles, Job &r_job);
	static Dictionary job_result(const Job &p_job);
	void wait();

protected:
	static void _bind_methods();

public:
	~PonyFoliageFill();

	// rows: [family String, tree slots, plant slots, tree spacing] per preset (BiomeFoliage
	// _preset_rows); tree_rules: [tree slots, plant slots] pairs; everfree: the forest footprint.
	void configure(const Array &p_rows, const Array &p_tree_rules, const Rect2 &p_everfree);
	// Snapshots one WorldBiomeField.tile() dictionary; false (and nothing stored) when any image
	// is missing or not the expected 256x256 RGBA8/L8 layout.
	bool set_tile(const Vector2i &p_location, const Dictionary &p_data);
	bool has_tile(const Vector2i &p_location) const;
	void erase_tile(const Vector2i &p_location);
	void clear_tiles();

	// Synchronous, on the calling thread: the result dictionary for one cell.
	Dictionary compute_cell(const Vector2i &p_cell, bool p_trees_only, bool p_keep_trees, double p_density_scale, int p_tree_slot_limit) const;
	// Starts one worker batch: `cells` holds x, y, flags (1 trees only, 2 keep trees) per cell.
	// False while a batch is still in flight.
	bool submit(const PackedInt32Array &p_cells, double p_density_scale, int p_tree_slot_limit);
	bool is_busy() const;
	bool is_ready() const;
	// Waits for the batch (instant once is_ready()) and returns one result dictionary per cell,
	// in submit order: {cell, status, trees_only, keep_trees, density_scale, slot_limit, rows, points, spacing}.
	Array collect();

	// MultiMesh.buffer floats (3x4 rows) of transforms[i] * part, or of transforms[i] as given when
	// `multiply` is false: the same floats as biome_foliage.gd instance_buffer and
	// painted_tree_batches.gd _pack_placed.
	PackedFloat32Array pack_transforms(const Array &p_transforms, const Transform3D &p_part, bool p_multiply) const;
	// Merges (transforms[i] * part) * local (transforms[i] * local when `multiply` is false) into
	// `start` in order (the first box replaces `start` when `first`), exactly as the GDScript
	// loops do. Returns [AABB, first].
	Array merge_bounds(const AABB &p_start, bool p_first, const Array &p_transforms, const Transform3D &p_part, const AABB &p_local, bool p_multiply) const;
};

} // namespace godot
