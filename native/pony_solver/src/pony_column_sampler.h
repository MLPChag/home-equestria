// PonyColumnSampler: walk_grid_service.gd _sample_column() as one native call per tick
// (dev 2026-10-20 multithreading).
//
// Why this stays on the main thread: Godot 4.5 only lets the main thread use a physics space's
// direct state. PhysicsServer3DWrapMT::space_get_direct_state() refuses other threads, and
// JoltPhysicsServer3D refuses a space that is stepping. Jolt's queries use the no-lock narrow
// phase and body interfaces (jolt_space_3d.cpp), so a ray on a worker would race any body the
// main thread adds, moves or frees. The columns cannot be rebuilt from terrain data either,
// because they must match the colliders exactly (houses, props, roofs). What changes is that a
// whole budget slice of columns runs in C++ instead of the GDScript interpreter. The rays, their
// order, every parameter and every float conversion are the same as the GDScript sampler.
#pragma once

#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/physics_shape_query_parameters3d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>

namespace godot {

class PonyColumnSampler : public RefCounted {
	GDCLASS(PonyColumnSampler, RefCounted)

protected:
	static void _bind_methods();

public:
	// Samples columns first_column, first_column + 1, ... of `chunk` (a WalkChunk) like
	// _sample_column(), stopping after `max_columns` or once Time.get_ticks_usec() reaches
	// `deadline_usec` (checked before every column after the first, as the GDScript loop does).
	// `ray` and `volume` are the service's own query objects (left as the GDScript sampler leaves
	// them). `blockers` holds AABBs; `terrain` is WorldTerrain.instance or null.
	// Returns how many columns were sampled. Main thread only.
	int64_t sample(Object *p_space, const Ref<PhysicsRayQueryParameters3D> &p_ray,
			const Ref<PhysicsShapeQueryParameters3D> &p_volume, Object *p_chunk, int64_t p_first_column,
			int64_t p_max_columns, int64_t p_deadline_usec, const AABB &p_bounds, const Array &p_blockers,
			Object *p_terrain);
};

} // namespace godot
