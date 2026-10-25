// The hybrid tail springs, line for line: pony_tail.gd update() (whose contact forces are zero
// in hybrid_tail_physics.gd), _frames(), _angle_basis(), _rotation_vector(), and
// hybrid_tail_physics.gd's floor-only contact projection (_deepest() with cheap_floor, _project(),
// and background_tail_physics.gd's extra projection). Floor probes, sleeping and skeleton reads
// stay in GDScript; angles and angular velocities travel in and out as PackedVector3Array.
#include "engine_math.h"
#include "pony_solver_native.h"

#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cmath>

using namespace godot;
using namespace pony;

namespace {

const Vector3 GRAVITY(0.0, -9.8, 0.0);
const double MAX_STEP = 1.0 / 120.0;
const double MAX_DELTA = 0.25;
const double MAX_ANGULAR_SPEED = 2.8;
const double MAX_ANGULAR_ACCELERATION = 70.0;
const double MAX_ROOT_ACCELERATION = 18.0;
const double TAIL_RADIUS = .09;
const double MAX_CONTACT_ROTATION = .14;

// pony_tail.gd _angle_basis()
Basis angle_basis(const Vector3 &value) {
	const double angle = value.length();
	return angle > 0.000001 ? basis_axis_angle(value / (real_t)angle, angle) : Basis();
}

// pony_tail.gd _rotation_vector()
Vector3 rotation_vector(const Quaternion &value) {
	const Vector3 axis(value.x, value.y, value.z);
	const double sine = axis.length();
	return sine > 0.000001 ? axis * (real_t)(2.0 * engine_atan2(sine, value.w) / sine) : Vector3();
}

struct FloorPlane {
	bool present = false;
	Vector3 position;
	Vector3 normal;
};

struct Contact {
	bool found = false;
	double depth = 0.0;
	int bone = 0;
	Vector3 offset;
	Vector3 normal;
};

} // namespace

void PonySolverNative::bind_tail(const PackedVector3Array &p_tips, const Array &p_rest_bases, const PackedFloat64Array &p_angle_limits) {
	tail_tips.assign(p_tips.ptr(), p_tips.ptr() + p_tips.size());
	tail_rest_bases.clear();
	for (int64_t i = 0; i < p_rest_bases.size(); i++) {
		tail_rest_bases.push_back(p_rest_bases[i]);
	}
	tail_angle_limits.assign(p_angle_limits.ptr(), p_angle_limits.ptr() + p_angle_limits.size());
}

// pony_tail.gd _frames()
void PonySolverNative::tail_frames(const Transform3D &mount_frame) {
	const size_t count = tail_tips.size();
	tail_frame.resize(count);
	Transform3D parent = mount_frame;
	for (size_t i = 0; i < count; i++) {
		Transform3D local = tail_base[i];
		const Basis &rest = tail_rest_bases[i];
		local.basis = rest * angle_basis(tail_angles[i]) * rest.inverse() * local.basis;
		parent = parent * local;
		tail_frame[i] = parent;
	}
}

void PonySolverNative::tail_load(const PackedVector3Array &p_angles, const PackedVector3Array &p_velocity, const Array &p_base_pose) {
	tail_angles.assign(p_angles.ptr(), p_angles.ptr() + p_angles.size());
	tail_velocity.assign(p_velocity.ptr(), p_velocity.ptr() + p_velocity.size());
	tail_base.resize(p_base_pose.size());
	for (int64_t i = 0; i < p_base_pose.size(); i++) {
		tail_base[i] = p_base_pose[i];
	}
}

// pony_tail.gd update() after its early return, with hybrid_tail_physics.gd's zero contact
// forces. `mount_state`: previous mount basis, previous mount velocity, mount history.
// `amounts`: gravity_amount, inertia_amount. Returns [angles, angular velocity, previous mount
// basis, previous mount velocity].
Array PonySolverNative::tail_update(const PackedVector3Array &p_angles, const PackedVector3Array &p_velocity,
		const Array &p_base_pose, const Transform3D &p_mount_frame, double p_delta, const Vector3 &p_world_acceleration,
		const Array &p_mount_state, const PackedFloat64Array &p_amounts) {
	Array result;
	ERR_FAIL_COND_V(p_mount_state.size() != 3 || p_amounts.size() != 2, result);
	ERR_FAIL_COND_V(p_angles.size() != (int64_t)tail_tips.size() || p_velocity.size() != p_angles.size(), result);
	tail_load(p_angles, p_velocity, p_base_pose);
	const size_t count = tail_tips.size();
	const double gravity_amount = p_amounts[0];
	const double inertia_amount = p_amounts[1];
	const double elapsed = minf(p_delta, MAX_DELTA);
	const Basis mount_basis = p_mount_frame.basis.orthonormalized();
	Vector3 mount_acceleration;
	const Basis previous_mount_basis = p_mount_state[0];
	Vector3 previous_mount_velocity = p_mount_state[1];
	const bool mount_history = p_mount_state[2];
	if (mount_history && p_delta <= MAX_DELTA) {
		Quaternion change = (mount_basis * previous_mount_basis.inverse()).get_rotation_quaternion().normalized();
		if (change.w < 0.0) {
			change = -change;
		}
		Vector3 mount_velocity = rotation_vector(change) / (real_t)p_delta;
		mount_velocity = mount_velocity.limit_length(6.0);
		mount_acceleration = ((mount_velocity - previous_mount_velocity) / (real_t)p_delta).limit_length(25.0);
		previous_mount_velocity = mount_velocity;
	} else {
		previous_mount_velocity = Vector3();
	}
	const Vector3 acceleration = p_world_acceleration.is_finite() ? p_world_acceleration.limit_length(MAX_ROOT_ACCELERATION) : Vector3();
	const int64_t steps = std::max<int64_t>(1, (int64_t)std::ceil(elapsed / MAX_STEP));
	const double dt = elapsed / steps;
	const Vector3 zero_force;
	for (int64_t step = 0; step < steps; step++) {
		tail_frames(p_mount_frame);
		for (size_t i = 0; i < count; i++) {
			const double progress = (double)i / (double)(count - 1);
			const Basis frame = tail_frame[i].basis.orthonormalized();
			const Basis inverse_frame = frame.inverse();
			const Vector3 direction = tail_tips[i].normalized();
			const Vector3 local_force = inverse_frame.xform(GRAVITY * (real_t)gravity_amount - acceleration * (real_t)inertia_amount);
			Vector3 force = direction.cross(local_force) * (real_t)lerpf(0.35, 0.8, progress);
			force -= inverse_frame.xform(mount_acceleration) * (real_t)lerpf(0.18, 0.35, progress);
			force += zero_force;
			force -= direction * force.dot(direction);
			const double stiffness = lerpf(42.0, 23.0, progress);
			const double damping = lerpf(10.0, 7.0, progress);
			const Vector3 angular_acceleration = (force - tail_angles[i] * (real_t)stiffness - tail_velocity[i] * (real_t)damping).limit_length(MAX_ANGULAR_ACCELERATION);
			tail_velocity[i] = (tail_velocity[i] + angular_acceleration * (real_t)dt).limit_length(MAX_ANGULAR_SPEED);
			tail_angles[i] += tail_velocity[i] * (real_t)dt;
			const double limit = tail_angle_limits[std::min(i, tail_angle_limits.size() - 1)];
			if (tail_angles[i].length() > limit) {
				tail_angles[i] = tail_angles[i].limit_length(limit);
				const Vector3 outward = tail_angles[i].normalized();
				tail_velocity[i] -= outward * (real_t)maxf(0.0, tail_velocity[i].dot(outward));
			}
		}
	}
	PackedVector3Array angles;
	PackedVector3Array velocity;
	for (size_t i = 0; i < count; i++) {
		angles.push_back(tail_angles[i]);
		velocity.push_back(tail_velocity[i]);
	}
	result.push_back(angles);
	result.push_back(velocity);
	result.push_back(mount_basis);
	result.push_back(previous_mount_velocity);
	return result;
}

// frames[i] * tips[i] for the floor probes in hybrid_tail_physics.gd apply_pose().
PackedVector3Array PonySolverNative::tail_tip_points(const PackedVector3Array &p_angles, const Array &p_base_pose,
		const Transform3D &p_mount) {
	PackedVector3Array points;
	ERR_FAIL_COND_V(p_angles.size() != (int64_t)tail_tips.size(), points);
	tail_load(p_angles, p_angles, p_base_pose);
	tail_frames(p_mount);
	for (size_t i = 0; i < tail_tips.size(); i++) {
		points.push_back(tail_frame[i].xform(tail_tips[i]));
	}
	return points;
}

// hybrid_tail_physics.gd apply_pose() from the contact projection on: the floor-only projection
// passes (when `project`), the remaining overlap, and the posed local transforms of the tail
// bones. `planes` holds the floor probe dictionaries per bone ({} for none). `flags`: project
// (0/1), background extra projection (0/1). Returns [angles, angular velocity, projected
// contacts, remaining depth (-1 when none), locals].
Array PonySolverNative::tail_project(const PackedVector3Array &p_angles, const PackedVector3Array &p_velocity,
		const Array &p_base_pose, const Transform3D &p_mount, const Array &p_planes, int32_t p_iterations,
		const PackedInt32Array &p_flags) {
	Array result;
	ERR_FAIL_COND_V(p_angles.size() != (int64_t)tail_tips.size() || p_velocity.size() != p_angles.size(), result);
	ERR_FAIL_COND_V(p_planes.size() != p_angles.size() || p_flags.size() != 2, result);
	tail_load(p_angles, p_velocity, p_base_pose);
	const size_t count = tail_tips.size();
	static const Variant position_key = StringName("position");
	static const Variant normal_key = StringName("normal");
	std::vector<FloorPlane> planes(count);
	for (size_t i = 0; i < count; i++) {
		const Dictionary plane = p_planes[i];
		if (!plane.is_empty()) {
			planes[i].present = true;
			planes[i].position = plane[position_key];
			planes[i].normal = plane[normal_key];
		}
	}
	// hybrid_tail_physics.gd _deepest() with cheap_floor.
	auto deepest = [&]() {
		Contact best;
		for (size_t i = 0; i < count; i++) {
			if (!planes[i].present) {
				continue;
			}
			for (const double t : { .5, 1. }) {
				const Vector3 offset = tail_tips[i] * (real_t)t;
				const double depth = (double)planes[i].normal.dot(planes[i].position - tail_frame[i].xform(offset)) + TAIL_RADIUS;
				if (depth > (best.found ? best.depth : 0.0)) {
					best.found = true;
					best.depth = depth;
					best.bone = (int)i;
					best.offset = offset;
					best.normal = planes[i].normal;
				}
			}
		}
		return best;
	};
	// hybrid_tail_physics.gd _project()
	std::vector<Vector3> gradients(count);
	auto project = [&](const Contact &contact) {
		double denominator = 0.0;
		for (size_t joint = 0; joint < count; joint++) {
			Vector3 lever;
			if (contact.bone >= (int)joint) {
				lever += (tail_frame[contact.bone].xform(contact.offset) - tail_frame[joint].origin) * (real_t)1.0;
			}
			Vector3 gradient = lever.cross(contact.normal);
			const Vector3 axis = tail_frame[joint].basis.xform(tail_tips[joint]).normalized();
			gradient -= axis * gradient.dot(axis);
			gradients[joint] = gradient;
			denominator += gradient.length_squared();
		}
		if (denominator < .0000001) {
			return;
		}
		for (size_t joint = 0; joint < count; joint++) {
			const Vector3 rotation = (gradients[joint] * (real_t)(contact.depth * .85 / denominator)).limit_length(MAX_CONTACT_ROTATION);
			if (rotation.length_squared() < .00000001) {
				continue;
			}
			const Basis &parent = joint == 0 ? p_mount.basis : tail_frame[joint - 1].basis;
			const Basis desired = parent.inverse() * angle_basis(rotation) * tail_frame[joint].basis;
			Quaternion relative = (tail_rest_bases[joint].inverse() * desired).orthonormalized().get_rotation_quaternion();
			if (relative.w < 0.0) {
				relative = -relative;
			}
			Vector3 vector = rotation_vector(relative);
			const Vector3 direction = tail_tips[joint].normalized();
			vector -= direction * vector.dot(direction);
			const Vector3 before = tail_angles[joint];
			tail_angles[joint] = vector.limit_length(tail_angle_limits[joint]);
			const Vector3 correction = tail_angles[joint] - before;
			if (correction.length_squared() > .0000001) {
				const Vector3 normal = correction.normalized();
				tail_velocity[joint] -= normal * (real_t)minf(0.0, tail_velocity[joint].dot(normal));
			}
		}
	};
	int64_t projected = 0;
	double remaining = -1.0;
	tail_frames(p_mount);
	if (p_flags[0]) {
		for (int32_t iteration = 0; iteration < p_iterations; iteration++) {
			const Contact contact = deepest();
			if (!contact.found || contact.depth < .0005) {
				break;
			}
			project(contact);
			if (p_flags[1]) {
				// background_tail_physics.gd _project(): one more pass while overlap remains.
				tail_frames(p_mount);
				const Contact again = deepest();
				if (again.found && again.depth > .002) {
					project(again);
				}
			}
			tail_frames(p_mount);
			projected++;
		}
		const Contact left = deepest();
		if (left.found) {
			remaining = left.depth;
		}
	}
	PackedVector3Array angles;
	PackedVector3Array velocity;
	Array locals;
	for (size_t i = 0; i < count; i++) {
		angles.push_back(tail_angles[i]);
		velocity.push_back(tail_velocity[i]);
		Transform3D local = tail_base[i];
		local.basis = tail_rest_bases[i] * angle_basis(tail_angles[i]) * tail_rest_bases[i].inverse() * local.basis;
		locals.push_back(local);
	}
	result.push_back(angles);
	result.push_back(velocity);
	result.push_back(projected);
	result.push_back(remaining);
	result.push_back(locals);
	return result;
}
