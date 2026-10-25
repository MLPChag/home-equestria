// Walk-grid trail weights for a whole chunk in one call (docs/SCRIPT_PROFILE_2026_10_24.md).
// Mirrors world/navigation/terrain_paths.gd weight_at() for every column centre of a walk chunk:
// the four surrounding Terrain3D control values, each mapped to 0/1 trail by its base and overlay
// texture IDs and the overlay blend, then bilinear by the column's fraction. The GDScript version
// asked Terrain3D 4 times per column (16,384 calls per 64x64 chunk); here each terrain vertex is
// read once (289 per chunk). Float32 storage and double arithmetic follow the GDScript exactly.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace godot {

class PonyTrailWeights : public RefCounted {
	GDCLASS(PonyTrailWeights, RefCounted)

protected:
	static void _bind_methods();

public:
	// Column-major-by-row weights (index = row * chunk_cells + column) for walk chunk `chunk`.
	// `trail_mask` has bit N set when texture ID N is a navigation trail. Empty when `data` is null.
	static PackedFloat64Array chunk_weights(Object *p_data, const Vector2i &p_chunk, double p_cell,
			int p_chunk_cells, int64_t p_trail_mask);
};

} // namespace godot
