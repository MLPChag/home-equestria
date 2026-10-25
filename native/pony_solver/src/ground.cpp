// Ground rays and body support, line for line: pony_locomotion.gd _probe() (one reused query
// object instead of a new PhysicsRayQueryParameters3D per ray; the same ray, mask and exclusion,
// the same seam retry and slope test) and the free-standing branch of _update_body() (its ten
// rays go through probe() in the same order). Main thread only: physics-space queries.
#include "engine_math.h"
#include "pony_solver_native.h"

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cmath>

using namespace godot;
using namespace pony;

namespace {

struct Keys {
	const Variant position = StringName("position");
	const Variant normal = StringName("normal");
	const Variant rid = StringName("rid");
};

const Keys &keys() {
	static const Keys k;
	return k;
}

const Vector3 UP(0, 1, 0);

} // namespace

// `pony`: the CollisionObject3D whose own body every probe excludes (GDScript [get_rid()]).
void PonySolverNative::bind_probe(Object *p_pony, const RID &p_exclude) {
	probe_owner = p_pony != nullptr ? p_pony->get_instance_id() : ObjectID();
	probe_query.instantiate();
	TypedArray<RID> exclude;
	exclude.push_back(p_exclude);
	probe_query->set_exclude(exclude);
}

// pony_locomotion.gd _probe()
Dictionary PonySolverNative::probe(const Vector3 &p_point, double p_rise, double p_hip_height, int64_t p_mask,
		double p_max_slope_degrees) {
	Node3D *pony = Object::cast_to<Node3D>(ObjectDB::get_instance(probe_owner));
	ERR_FAIL_NULL_V(pony, Dictionary());
	ERR_FAIL_COND_V(probe_query.is_null(), Dictionary());
	PhysicsDirectSpaceState3D *space = pony->get_world_3d()->get_direct_space_state();
	ERR_FAIL_NULL_V(space, Dictionary());
	const Keys &k = keys();
	const double h = p_hip_height;
	PhysicsRayQueryParameters3D *query = probe_query.ptr();
	query->set_from(p_point + UP * (real_t)(h * 0.9 + p_rise));
	query->set_to(p_point - UP * (real_t)h * (real_t)1.5);
	query->set_collision_mask((uint32_t)p_mask);
	Dictionary hit = space->intersect_ray(probe_query);
	if (hit.is_empty()) {
		// Jolt can miss a ray exactly on a shared triangle edge. Retry only that miss,
		// straddling it by 2 mm; require the same continuous floor on both sides.
		const Vector3 seam(0.002, 0.0, 0.001);
		query->set_from(query->get_from() + seam);
		query->set_to(query->get_to() + seam);
		Dictionary first = space->intersect_ray(probe_query);
		if (first.is_empty()) {
			return Dictionary();
		}
		query->set_from(query->get_from() - seam * (real_t)2.0);
		query->set_to(query->get_to() - seam * (real_t)2.0);
		const Dictionary second = space->intersect_ray(probe_query);
		if (second.is_empty() || first[k.rid] != second[k.rid] ||
				std::abs((double)Vector3(first[k.position]).y - (double)Vector3(second[k.position]).y) > 0.01) {
			return Dictionary();
		}
		if ((double)Vector3(first[k.normal]).dot(Vector3(second[k.normal])) < 0.99) {
			return Dictionary();
		}
		hit = first;
		hit[k.position] = (Vector3(first[k.position]) + Vector3(second[k.position])) * (real_t)0.5;
		hit[k.normal] = (Vector3(first[k.normal]) + Vector3(second[k.normal])).normalized();
	}
	if (hit.is_empty() || (double)Vector3(hit[k.normal]).dot(UP) < engine_cos(deg_to_rad(p_max_slope_degrees))) {
		return Dictionary();
	}
	return hit;
}

// The legs' neutral sole points (profile.legs[i].neutral_sole), once per gait profile.
void PonySolverNative::bind_body(const PackedVector3Array &p_neutral_soles) {
	body_neutral_soles.assign(p_neutral_soles.ptr(), p_neutral_soles.ptr() + p_neutral_soles.size());
}

// _update_body() when not held and on the floor. `scalars`: delta, body_height, hip_height,
// max_slope_degrees, secondary.roll, floor_mask. Returns [pivot transform (before
// _apply_body_scale()), body tilt, body height, slope angle].
Array PonySolverNative::update_body(const Transform3D &p_global, const Quaternion &p_body_tilt, const Transform3D &p_model_frame,
		const Vector3 &p_body_offset, const Vector3 &p_secondary_offset, const PackedFloat64Array &p_scalars) {
	Array result;
	ERR_FAIL_COND_V(p_scalars.size() != 6, result);
	const double delta = p_scalars[0];
	double body_height = p_scalars[1];
	const double hip_height = p_scalars[2];
	const double max_slope_degrees = p_scalars[3];
	const double roll = p_scalars[4];
	const int64_t mask = (int64_t)p_scalars[5];
	const Keys &k = keys();
	// Sample under the tilted footprint: pitching about the hips moves the feet on a slope.
	const Vector3 center(0.0, hip_height, 0.2927);
	Quaternion body_tilt = p_body_tilt;
	const Transform3D footprint(Basis(body_tilt), center - body_tilt.xform(center));
	const Transform3D inverse_global = p_global.affine_inverse();
	Vector3 points[6];
	int n = 0;
	for (const double z : { -0.30, 0.05, 0.40 }) {
		for (const double x : { -0.15, 0.15 }) {
			const Vector3 local_point = footprint.xform(Vector3(x, 0.0, z));
			const Vector3 point = p_global.xform(local_point);
			const Dictionary hit = probe(point, 0.0, hip_height, mask, max_slope_degrees);
			points[n++] = !hit.is_empty() ? inverse_global.xform(Vector3(hit[k.position])) : local_point;
		}
	}
	const Vector3 longitudinal = (points[4] + points[5]) - (points[0] + points[1]);
	const Vector3 lateral = (points[1] + points[3] + points[5]) - (points[0] + points[2] + points[4]);
	const double dz = longitudinal.y / maxf(std::abs((double)longitudinal.z), 0.1);
	const double dx = lateral.y / maxf(std::abs((double)lateral.x), 0.1);
	const Vector3 local_normal = Vector3(-dx, 1.0, -dz).normalized();
	const double slope_angle = vector_angle(UP, local_normal);
	const Vector3 axis = UP.cross(local_normal);
	const double tilt_limit = deg_to_rad(minf(max_slope_degrees, 40.0));
	const Quaternion want_tilt = axis.length_squared() < 1e-10 ? Quaternion() : axis_angle(axis.normalized(), minf(slope_angle, tilt_limit));
	const double weight = 1.0 - engine_exp(-delta / 0.07);
	body_tilt = slerp(body_tilt, want_tilt, weight);
	const Transform3D tilted(Basis(body_tilt), center - body_tilt.xform(center));
	double height_sum = 0.0;
	int64_t count = 0;
	for (const Vector3 &neutral_sole : body_neutral_soles) {
		const Vector3 sole = (p_global * tilted * p_model_frame).xform(neutral_sole);
		const Dictionary hit = probe(sole, 0.0, hip_height, mask, max_slope_degrees);
		if (!hit.is_empty()) {
			height_sum += (double)Vector3(hit[k.position]).y - (double)sole.y;
			count += 1;
		}
	}
	const double want_height = clamp_double(height_sum / (double)std::max<int64_t>(count, 1), -hip_height * 0.45, hip_height * 0.45);
	body_height = lerpf(body_height, want_height, weight);
	Transform3D pivot = tilted;
	pivot.origin.y = (real_t)((double)pivot.origin.y + body_height);
	const Basis give_rotation = basis_from_euler(Vector3(p_body_offset.z * 0.7, 0.0, -p_body_offset.x * 0.8 + roll));
	const Transform3D give(give_rotation, center - give_rotation.xform(center) + p_body_offset + p_secondary_offset);
	pivot = pivot * give;
	result.push_back(pivot);
	result.push_back(body_tilt);
	result.push_back(body_height);
	result.push_back(slope_angle);
	return result;
}
