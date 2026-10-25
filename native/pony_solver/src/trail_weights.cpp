// See trail_weights.h.
#include "trail_weights.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>
#include <vector>

using namespace godot;

void PonyTrailWeights::_bind_methods() {
	ClassDB::bind_static_method("PonyTrailWeights",
			D_METHOD("chunk_weights", "data", "chunk", "cell", "chunk_cells", "trail_mask"),
			&PonyTrailWeights::chunk_weights);
}

// terrain_paths.gd control_weight(): base/overlay texture IDs and the overlay blend.
static inline float control_weight(int64_t p_control, int64_t p_mask) {
	const int64_t base = (p_control >> 27) & 31;
	const int64_t overlay = (p_control >> 22) & 31;
	const double blend = double((p_control >> 14) & 255) / 255.0;
	const double a = (p_mask >> base) & 1 ? 1.0 : 0.0;
	const double b = (p_mask >> overlay) & 1 ? 1.0 : 0.0;
	// lerpf in double; the GDScript stores it in a PackedFloat32Array.
	return float(a + (b - a) * blend);
}

PackedFloat64Array PonyTrailWeights::chunk_weights(Object *p_data, const Vector2i &p_chunk, double p_cell,
		int p_chunk_cells, int64_t p_trail_mask) {
	PackedFloat64Array result;
	if (p_data == nullptr || p_chunk_cells <= 0) {
		return result;
	}
	static const StringName get_control("get_control");
	const int n = p_chunk_cells;
	// Column centres exactly as _apply_paint builds them: integer cell + .5, times CELL (double),
	// stored in a float32 Vector3.
	std::vector<float> xs(n), zs(n);
	for (int i = 0; i < n; i++) {
		xs[i] = float((double(int64_t(p_chunk.x) * n + i) + 0.5) * p_cell);
		zs[i] = float((double(int64_t(p_chunk.y) * n + i) + 0.5) * p_cell);
	}
	// Vector2.floor() on float32 components.
	const int64_t vx0 = int64_t(std::floor(xs[0]));
	const int64_t vz0 = int64_t(std::floor(zs[0]));
	const int64_t width = int64_t(std::floor(xs[n - 1])) - vx0 + 2;
	const int64_t depth = int64_t(std::floor(zs[n - 1])) - vz0 + 2;
	// One Terrain3D read per vertex the chunk touches.
	std::vector<float> vertex(size_t(width * depth));
	for (int64_t z = 0; z < depth; z++) {
		for (int64_t x = 0; x < width; x++) {
			const Vector3 at(float(vx0 + x), 0.0f, float(vz0 + z));
			const int64_t control = int64_t(p_data->call(get_control, at));
			vertex[size_t(z * width + x)] = control_weight(control, p_trail_mask);
		}
	}
	result.resize(int64_t(n) * n);
	double *out = result.ptrw();
	for (int row = 0; row < n; row++) {
		const float pz = zs[row];
		const float cz = std::floor(pz);
		const double fz = double(pz - cz);
		const int64_t iz = int64_t(cz) - vz0;
		for (int col = 0; col < n; col++) {
			const float px = xs[col];
			const float cx = std::floor(px);
			const double fx = double(px - cx);
			const int64_t ix = int64_t(cx) - vx0;
			const double w0 = vertex[size_t(iz * width + ix)];
			const double w1 = vertex[size_t(iz * width + ix + 1)];
			const double w2 = vertex[size_t((iz + 1) * width + ix)];
			const double w3 = vertex[size_t((iz + 1) * width + ix + 1)];
			const double top = w0 + (w1 - w0) * fx;
			const double bottom = w2 + (w3 - w2) * fx;
			out[row * n + col] = top + (bottom - top) * fz;
		}
	}
	return result;
}
