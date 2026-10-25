// Exact coarse batches for posed_shoulder_surface.gd. No change to sampling,
// pose capture, cache invalidation, engine TriangleMesh queries or joint solving.
#include "pony_solver_native.h"
#include "engine_math.h"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/templates/sort_array.hpp>
#include <limits>

using namespace godot;

PackedVector3Array PonySolverNative::surface_skin(const PackedInt32Array &p_starts,
		const PackedInt32Array &p_slots, const PackedVector3Array &p_points,
		const PackedFloat32Array &p_weights, const Array &p_poses) {
	PackedVector3Array result;
	ERR_FAIL_COND_V(p_starts.size() < 2 || p_slots.size() != p_points.size() || p_slots.size() != p_weights.size(), result);
	ERR_FAIL_COND_V(p_starts[0] != 0 || p_starts[p_starts.size() - 1] != p_slots.size(), result);
	std::vector<Transform3D> poses;
	poses.reserve(p_poses.size());
	for (int64_t i = 0; i < p_poses.size(); ++i) {
		ERR_FAIL_COND_V(p_poses[i].get_type() != Variant::TRANSFORM3D, result);
		poses.push_back(p_poses[i]);
	}
	const int32_t *starts = p_starts.ptr();
	const int32_t *slots = p_slots.ptr();
	const Vector3 *points = p_points.ptr();
	const float *weights = p_weights.ptr();
	result.resize(p_starts.size() - 1);
	Vector3 *out = result.ptrw();
	for (int64_t vertex = 0; vertex < result.size(); ++vertex) {
		ERR_FAIL_COND_V(starts[vertex] < 0 || starts[vertex] > starts[vertex + 1] || starts[vertex + 1] > p_slots.size(), PackedVector3Array());
		Vector3 point;
		for (int32_t i = starts[vertex]; i < starts[vertex + 1]; ++i) {
			ERR_FAIL_COND_V(slots[i] < 0 || slots[i] >= int64_t(poses.size()), PackedVector3Array());
			const Transform3D &pose = poses[slots[i]];
			// Each Vector3 product/add rounds separately, as in GDScript.
			point += pose.basis.xform(points[i]) + pose.origin * weights[i];
		}
		out[vertex] = point;
	}
	return result;
}

Dictionary PonySolverNative::surface_envelope(const PackedVector3Array &p_vertices,
		const PackedVector3Array &p_normals, const Array &p_witnesses, bool p_rebuild) {
	Dictionary result;
	ERR_FAIL_COND_V(p_vertices.is_empty() || (!p_rebuild && p_witnesses.size() != p_normals.size()), result);
	PackedFloat32Array limits;
	limits.resize(p_normals.size());
	Array witnesses;
	if (p_rebuild) witnesses.resize(p_normals.size());
	const Vector3 *vertices = p_vertices.ptr();
	for (int64_t plane = 0; plane < p_normals.size(); ++plane) {
		double limit = -std::numeric_limits<double>::infinity();
		const Vector3 normal = p_normals[plane];
		if (p_rebuild) {
			for (int64_t vertex = 0; vertex < p_vertices.size(); ++vertex) limit = pony::maxf(limit, normal.dot(vertices[vertex]));
			PackedInt32Array support;
			for (int64_t vertex = 0; vertex < p_vertices.size(); ++vertex) {
				if (double(normal.dot(vertices[vertex])) >= limit - .01) support.append(vertex);
			}
			witnesses[plane] = support;
		} else {
			const PackedInt32Array support = p_witnesses[plane];
			for (int64_t i = 0; i < support.size(); ++i) {
				const int32_t vertex = support[i];
				ERR_FAIL_COND_V(vertex < 0 || vertex >= p_vertices.size(), Dictionary());
				limit = pony::maxf(limit, normal.dot(vertices[vertex]));
			}
		}
		limits.set(plane, limit);
	}
	result["limits"] = limits;
	result["witnesses"] = p_rebuild ? witnesses : p_witnesses;
	return result;
}

namespace {
struct SurfaceSample {
	bool valid = false;
	Vector3 shoulder;
	Vector3 head;
	double depth = -std::numeric_limits<double>::infinity();
	Dictionary dictionary() const {
		Dictionary result;
		if (valid) {
			result["shoulder"] = shoulder;
			result["head"] = head;
			result["depth"] = depth;
			result["kind"] = "drawn_head_cloth";
		}
		return result;
	}
};
struct DepthDescending {
	bool operator()(const Vector2 &a, const Vector2 &b) const { return a.y > b.y; }
};
} // namespace

Dictionary PonySolverNative::surface_query(const Ref<TriangleMesh> &p_mesh, const PackedVector3Array &p_posed,
		const PackedInt32Array &p_overlaps, const Vector3 &p_cloth, const PackedInt32Array &p_triangles,
		const Dictionary &p_adjacent, const Transform3D &p_frame, const AABB &p_bounds,
		const PackedVector3Array &p_normals, const PackedFloat32Array &p_limits, double p_motion, bool p_pruning) {
	Dictionary output;
	ERR_FAIL_COND_V(p_mesh.is_null() || p_normals.size() != p_limits.size(), output);
	const Transform3D inverse = p_frame.affine_inverse();
	const Vector3 head_center = p_bounds.get_center();
	const Vector3 center = p_frame.xform(head_center);
	const double reach = double(p_bounds.size.length()) * 2.0;
	int64_t queries = 0;
	auto upper_bound = [&](const Vector3 &point) -> double {
		if (!p_pruning) return std::numeric_limits<double>::infinity();
		const Vector3 local = inverse.xform(point);
		const double distance = local.distance_to(head_center);
		if (distance < 1e-8) return std::numeric_limits<double>::infinity();
		const Vector3 direction = (local - head_center) / distance;
		double radius = std::numeric_limits<double>::infinity();
		for (int64_t i = 0; i < p_normals.size(); ++i) {
			const Vector3 normal = p_normals[i];
			const double denominator = normal.dot(direction);
			if (denominator > 1e-8) radius = pony::minf(radius,
					(double(p_limits[i]) + p_motion + .000001 - double(normal.dot(head_center))) / denominator);
		}
		return (radius - distance) * double(p_frame.basis.xform(direction).length());
	};
	auto sample = [&](const Vector3 &point) -> SurfaceSample {
		SurfaceSample result;
		const Vector3 local = inverse.xform(point);
		const Vector3 direction = (local - head_center).normalized();
		if (direction.length_squared() < .5) return result;
		++queries;
		const Dictionary hit = p_mesh->intersect_segment(head_center + direction * reach, head_center);
		if (hit.is_empty()) return result;
		result.valid = true;
		result.shoulder = point;
		result.head = p_frame.xform(Vector3(hit["position"]));
		result.depth = (result.head - point).dot((point - center).normalized());
		return result;
	};
	std::vector<Vector2> candidates;
	candidates.reserve(p_overlaps.size());
	for (int64_t i = 0; i < p_overlaps.size(); ++i) {
		const int32_t vertex = p_overlaps[i];
		ERR_FAIL_COND_V(vertex < 0 || vertex >= p_posed.size(), Dictionary());
		// Preserve the GDScript Vector2's float32 rounding and Godot's tie order.
		candidates.emplace_back(float(vertex), upper_bound(p_posed[vertex]));
	}
	SortArray<Vector2, DepthDescending, true> sorter;
	if (!candidates.empty()) sorter.sort(candidates.data(), candidates.size());
	SurfaceSample best;
	int32_t best_vertex = -1;
	for (const Vector2 &entry : candidates) {
		if (double(entry.y) <= best.depth) break;
		const int32_t vertex = int32_t(entry.x);
		const SurfaceSample candidate = sample(p_posed[vertex]);
		if (candidate.valid && candidate.depth > best.depth) {
			best = candidate;
			best_vertex = vertex;
		}
	}
	const bool refined = best.valid;
	if (!best.valid) {
		best = sample(p_cloth);
	} else {
		const Array faces = p_adjacent.get(best_vertex, Array());
		for (int64_t i = 0; i < faces.size(); ++i) {
			const int64_t face = faces[i];
			ERR_FAIL_COND_V(face < 0 || face + 2 >= p_triangles.size(), Dictionary());
			Vector3 corners[3];
			for (int64_t corner = 0; corner < 3; ++corner) {
				const int32_t vertex = p_triangles[face + corner];
				ERR_FAIL_COND_V(vertex < 0 || vertex >= p_posed.size(), Dictionary());
				corners[corner] = p_posed[vertex];
			}
			Vector3 point = p_posed[best_vertex];
			double step = .5;
			for (int iteration = 0; iteration < 6; ++iteration) {
				Vector3 local_best = point;
				for (const Vector3 &corner : corners) {
					const Vector3 at = point.lerp(corner, step);
					if (upper_bound(at) <= best.depth) continue;
					const SurfaceSample candidate = sample(at);
					if (candidate.valid && candidate.depth > best.depth) {
						best = candidate;
						local_best = candidate.shoulder;
					}
				}
				point = local_best;
				step *= .5;
			}
		}
	}
	output["contact"] = best.dictionary();
	output["queries"] = queries;
	output["refined"] = refined;
	return output;
}
