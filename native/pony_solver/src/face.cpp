// Skeleton-modifier work, line for line. Runs inside Godot's deferred skeleton update, one
// skeleton at a time, so it stays serial:
// - pony_terrain_modifier.gd: write the prepared pose to every bone;
// - openpony_eye_motion.gd _unprofiled_process_modification(): lids and blinks with the eye
//   expressions, brow and ear expression deltas, gaze onto the curved eye surface, and the
//   show-eye surface callback; background_eye_motion.gd's asymmetric gaze included.
// hybrid_boop.gd _sync_snoot(): the face collision spheres and blush decals follow the head.
// pony_clip_head.gd _apply(): the live head over the clip tiers' baked gaits.
#include "engine_math.h"
#include "pony_solver_native.h"

#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cmath>
#include <cstring>

using namespace godot;
using namespace pony;

// pony_terrain_modifier.gd
void PonySolverNative::write_bone_poses(Object *p_skeleton, const Array &p_pose) {
	Skeleton3D *skeleton = Object::cast_to<Skeleton3D>(p_skeleton);
	ERR_FAIL_NULL(skeleton);
	const int64_t count = p_pose.size();
	if (count != skeleton->get_bone_count()) {
		return;
	}
	for (int64_t i = 0; i < count; i++) {
		skeleton->set_bone_pose((int32_t)i, p_pose[i]);
	}
}

namespace {

bool same(const Transform3D &a, const Transform3D &b) {
	return std::memcmp(&a, &b, sizeof(Transform3D)) == 0;
}

template <typename T>
bool same_value(const T &a, const T &b) {
	return std::memcmp(&a, &b, sizeof(T)) == 0;
}

} // namespace

// pony_terrain_modifier.gd with the bone skip: write only the bones whose value differs from
// what the skeleton holds right now. Skeleton3D keeps a bone pose as position, rotation and
// scale; set_bone_pose() stores (origin, basis.get_rotation_quaternion(), basis.get_scale()).
// A bone is skipped only when that triple is bitwise the one it already holds, so the skeleton
// ends up exactly as after a full write.
//
// What it holds at modifier time is the unmodified pose: Skeleton3D saves every bone before its
// modifiers run and restores them after skinning (4.5 NOTIFICATION_UPDATE_SKELETON). That pose
// changes only when something writes the skeleton outside the modifier pass (reset_bone_poses(),
// the animation mixer of the clip tiers, a script). Every such write marks the skeleton dirty,
// and the next update emits pose_updated before its modifiers run; the modifier connects that
// signal to invalidate_bone_skip(), which makes the next pass re-read all held values. The
// caller only uses this when no active modifier runs before it on the same skeleton.
//
// Cost per bone: a bone known to match is skipped after one 48-byte comparison. A bone whose
// value has not changed since the previous tick is decomposed once to test it. A bone that
// moves every tick is written as before.
void PonySolverNative::invalidate_bone_skip() {
	bone_skip_valid = false;
}

int64_t PonySolverNative::write_bone_poses_skip(Object *p_skeleton, const Array &p_pose) {
	Skeleton3D *skeleton = Object::cast_to<Skeleton3D>(p_skeleton);
	ERR_FAIL_NULL_V(skeleton, 0);
	const int64_t count = p_pose.size();
	if (count != skeleton->get_bone_count()) {
		return 0;
	}
	if (!bone_skip_valid || (int64_t)skip_held_position.size() != count) {
		skip_held_position.resize(count);
		skip_held_rotation.resize(count);
		skip_held_scale.resize(count);
		skip_last.resize(count);
		skip_match.resize(count);
		skip_miss.resize(count);
		skip_flags.assign(count, 0);
		for (int64_t i = 0; i < count; i++) {
			skip_held_position[i] = skeleton->get_bone_pose_position((int32_t)i);
			skip_held_rotation[i] = skeleton->get_bone_pose_rotation((int32_t)i);
			skip_held_scale[i] = skeleton->get_bone_pose_scale((int32_t)i);
		}
		bone_skip_valid = true;
	}
	enum : uint8_t {
		HAS_LAST = 1,
		HAS_MATCH = 2,
		HAS_MISS = 4,
	};
	int64_t written = 0;
	for (int64_t i = 0; i < count; i++) {
		const Transform3D pose = p_pose[i];
		uint8_t &flags = skip_flags[i];
		if ((flags & HAS_MATCH) && same(pose, skip_match[i])) {
			continue;
		}
		const bool stable = (flags & HAS_LAST) && same(pose, skip_last[i]);
		skip_last[i] = pose;
		flags |= HAS_LAST;
		if (stable && !((flags & HAS_MISS) && same(pose, skip_miss[i]))) {
			const Quaternion rotation = pose.basis.get_rotation_quaternion();
			const Vector3 scale = pose.basis.get_scale();
			if (same_value(pose.origin, skip_held_position[i]) && same_value(rotation, skip_held_rotation[i]) &&
					same_value(scale, skip_held_scale[i])) {
				skip_match[i] = pose;
				flags |= HAS_MATCH;
				continue;
			}
			skip_miss[i] = pose;
			flags |= HAS_MISS;
		}
		skeleton->set_bone_pose((int32_t)i, pose);
		written++;
	}
	if (written == 0 && count > 0) {
		// A full write always sets the skeleton's pose-changed flag, which makes this update
		// re-skin. Keep that: rewrite bone 0 with the value it already holds.
		skeleton->set_bone_pose(0, p_pose[0]);
		written = 1;
	}
	return written;
}

namespace {

// Dictionary(bone -> Transform3D) in iteration order.
void read_bone_map(const Dictionary &p_map, std::vector<std::pair<int32_t, Transform3D>> &r_list) {
	r_list.clear();
	const Array bones = p_map.keys();
	for (int64_t i = 0; i < bones.size(); i++) {
		r_list.emplace_back((int32_t)(int64_t)bones[i], (Transform3D)p_map[bones[i]]);
	}
}

// Dictionary(shape -> Dictionary(bone -> Transform3D)) in iteration order.
void read_shapes(const Dictionary &p_shapes, std::vector<PonySolverNative::EyeShape> &r_shapes) {
	r_shapes.clear();
	const Array names = p_shapes.keys();
	for (int64_t i = 0; i < names.size(); i++) {
		PonySolverNative::EyeShape shape;
		shape.name = names[i];
		read_bone_map(p_shapes[names[i]], shape.bones);
		r_shapes.push_back(shape);
	}
}

const PonySolverNative::EyeShape *find_shape(const std::vector<PonySolverNative::EyeShape> &p_shapes, const String &p_name) {
	for (const PonySolverNative::EyeShape &shape : p_shapes) {
		if (shape.name == p_name) {
			return &shape;
		}
	}
	return nullptr;
}

const Transform3D *find_bone(const PonySolverNative::EyeShape *p_shape, int32_t p_bone) {
	if (p_shape == nullptr) {
		return nullptr;
	}
	for (const std::pair<int32_t, Transform3D> &entry : p_shape->bones) {
		if (entry.first == p_bone) {
			return &entry.second;
		}
	}
	return nullptr;
}

} // namespace

// openpony_eye_motion.gd bind() results: _lid_open and _lid_closed (same keys), _eye_shapes,
// _brow_shapes, _ear_shapes, _eye_bones, _head_bone, _eye_center_head, _rest_globals, _parents.
void PonySolverNative::bind_eyes(const Dictionary &p_lid_open, const Dictionary &p_lid_closed, const Dictionary &p_eye_shapes,
		const Dictionary &p_brow_shapes, const Dictionary &p_ear_shapes, const PackedInt32Array &p_eye_bones, int32_t p_head_bone,
		const Vector3 &p_eye_center_head, const Array &p_rest_globals, const PackedInt32Array &p_parents) {
	read_bone_map(p_lid_open, eye_lid_open);
	eye_lid_closed.clear();
	for (const std::pair<int32_t, Transform3D> &entry : eye_lid_open) {
		eye_lid_closed.push_back(p_lid_closed[entry.first]);
	}
	read_shapes(p_eye_shapes, eye_shapes);
	read_shapes(p_brow_shapes, brow_shapes);
	read_shapes(p_ear_shapes, ear_shapes);
	eye_bones.assign(p_eye_bones.ptr(), p_eye_bones.ptr() + p_eye_bones.size());
	eye_head_bone = p_head_bone;
	eye_center_head = p_eye_center_head;
	eye_rest_globals.clear();
	for (int64_t i = 0; i < p_rest_globals.size(); i++) {
		eye_rest_globals.push_back(p_rest_globals[i]);
	}
	eye_parents.assign(p_parents.ptr(), p_parents.ptr() + p_parents.size());
	eye_written.clear();
}

// openpony_eye_motion.gd _write(): set the bone and remember it for the in-between ticks.
void PonySolverNative::eye_write(Skeleton3D *p_skeleton, int32_t p_bone, const Transform3D &p_pose) {
	p_skeleton->set_bone_pose(p_bone, p_pose);
	for (std::pair<int32_t, Transform3D> &entry : eye_written) {
		if (entry.first == p_bone) {
			entry.second = p_pose;
			return;
		}
	}
	eye_written.emplace_back(p_bone, p_pose);
}

// openpony_eye_motion.gd surface_angles(), with background_eye_motion.gd's asymmetric gaze.
Vector2 PonySolverNative::eye_surface_angles(int p_side_index, const Vector2 &p_angles) const {
	if (!eye_asymmetric) {
		return p_angles;
	}
	const double side = p_side_index == 0 ? 1.0 : -1.0;
	return p_angles * (real_t)0.2 + Vector2(-side * eye_inward, -side * eye_vertical);
}

// openpony_eye_motion.gd eye_pose() (background_eye_motion.gd applies surface_angles() first).
Transform3D PonySolverNative::eye_pose(int p_side_index, const Vector2 &p_angles) const {
	const Vector2 angles = eye_asymmetric ? eye_surface_angles(p_side_index, p_angles) : p_angles;
	const double side = p_side_index == 0 ? 1.0 : -1.0;
	const int32_t bone = eye_bones[p_side_index];
	const Transform3D &rest = eye_rest_globals[bone];
	const Vector3 center(side * 0.07155437, 0.91847255, 0.31813008);
	const Basis metric(Vector3(477.04993, 0.0, side * 378.63708), Vector3(0.0, 60.65196, 0.0), Vector3(side * 378.63708, 0.0, 493.82285));
	const Vector3 neutral = metric.xform(rest.origin - center).normalized();
	const double yaw = -side * deg_to_rad(eye_convergence) + clamp_double(angles.x, -0.08, 0.08);
	Vector3 normal = basis_axis_angle(Vector3(0, 1, 0), yaw).xform(neutral).normalized();
	normal.y = (real_t)clamp_double((double)normal.y + clamp_double(angles.y, -.25, .25) * .2, -.06, .06);
	normal = normal.normalized();
	const Basis inverse = metric.inverse();
	const Vector3 surface = center + inverse.xform(normal) / (real_t)std::sqrt((double)normal.dot(inverse.xform(normal)));
	const Vector3 rest_surface = center + inverse.xform(neutral) / (real_t)std::sqrt((double)neutral.dot(inverse.xform(neutral)));
	const Transform3D posed(Basis(shortest_arc(neutral, normal)) * rest.basis, rest.origin + surface - rest_surface);
	return eye_rest_globals[eye_parents[bone]].affine_inverse() * posed;
}

// openpony_eye_motion.gd _unprofiled_process_modification() after its early returns.
// `scalars`: closure, expression_closure, target_weight, convergence_degrees, asymmetric (0/1),
// inward_radians, vertical_radians.
void PonySolverNative::eye_process(Object *p_skeleton, const PackedFloat64Array &p_scalars, const Vector2 &p_gaze,
		const Vector2 &p_offset, const Vector3 &p_target_world, const Dictionary &p_expression_eyes,
		const Dictionary &p_expression_brows, const Dictionary &p_expression_ears, const Callable &p_surface_update) {
	Skeleton3D *sk = Object::cast_to<Skeleton3D>(p_skeleton);
	ERR_FAIL_NULL(sk);
	ERR_FAIL_COND(p_scalars.size() != 7);
	const double closure = p_scalars[0];
	const double expression_closure = p_scalars[1];
	const double target_weight = p_scalars[2];
	eye_convergence = p_scalars[3];
	eye_asymmetric = p_scalars[4] != 0.0;
	eye_inward = p_scalars[5];
	eye_vertical = p_scalars[6];
	eye_written.clear();
	const double lid_closure = 1.0 - (1.0 - clamp_double(closure, 0.0, 1.0)) * (1.0 - clamp_double(expression_closure, 0.0, 1.0));
	const Array eye_keys = p_expression_eyes.keys();
	std::vector<const EyeShape *> eye_shape_of(eye_keys.size());
	for (int64_t s = 0; s < eye_keys.size(); s++) {
		eye_shape_of[s] = find_shape(eye_shapes, eye_keys[s]);
	}
	for (size_t n = 0; n < eye_lid_open.size(); n++) {
		const int32_t i = eye_lid_open[n].first;
		Transform3D opened = eye_lid_open[n].second;
		// Blend the original eye poses as a convex mix, then close the actual lids.
		double total = 0.0;
		for (int64_t s = 0; s < eye_keys.size(); s++) {
			if (find_bone(eye_shape_of[s], i) != nullptr) {
				total += clamp_double(p_expression_eyes[eye_keys[s]], 0.0, 1.0);
			}
		}
		double mass = maxf(0.0, 1.0 - total);
		for (int64_t s = 0; s < eye_keys.size(); s++) {
			const Transform3D *shape_pose = find_bone(eye_shape_of[s], i);
			if (shape_pose == nullptr) {
				continue;
			}
			const double weight = clamp_double(p_expression_eyes[eye_keys[s]], 0.0, 1.0);
			if (weight < .0001) {
				continue;
			}
			mass += weight;
			opened = interpolate(opened, *shape_pose, weight / mass);
		}
		const Transform3D pose = interpolate(opened, eye_lid_closed[n], lid_closure);
		eye_write(sk, i, pose);
	}
	// Apply only original brow/forehead deltas, above the freshly reset blink pose.
	for (const EyeShape &shape : brow_shapes) {
		const double weight = clamp_double(p_expression_brows.get(shape.name, 0.0), 0.0, 1.0) * (1.0 - lid_closure);
		if (weight < .0001) {
			continue;
		}
		for (const std::pair<int32_t, Transform3D> &entry : shape.bones) {
			const Transform3D &delta = entry.second;
			Transform3D pose = sk->get_bone_pose(entry.first);
			pose.origin += delta.origin * (real_t)weight;
			pose.basis = pose.basis * Basis(slerp(Quaternion(), delta.basis.get_rotation_quaternion(), weight));
			eye_write(sk, entry.first, pose);
		}
	}
	// Native ear rotations add to this frame's source pose; no persistent bone reset.
	const Array ear_keys = p_expression_ears.keys();
	for (int64_t s = 0; s < ear_keys.size(); s++) {
		const double weight = clamp_double(p_expression_ears[ear_keys[s]], 0.0, 1.0);
		if (weight < .0001) {
			continue;
		}
		const EyeShape *shape = find_shape(ear_shapes, ear_keys[s]);
		if (shape == nullptr) {
			continue;
		}
		for (const std::pair<int32_t, Transform3D> &entry : shape->bones) {
			const Transform3D &delta = entry.second;
			Transform3D pose = sk->get_bone_pose(entry.first);
			pose.origin += delta.origin * (real_t)weight;
			pose.basis = pose.basis * Basis(slerp(Quaternion(), delta.basis.get_rotation_quaternion(), weight));
			eye_write(sk, entry.first, pose);
		}
	}
	Vector2 aim = p_gaze;
	if (target_weight > 0.0 && eye_head_bone >= 0) {
		// Read the actual linked head inside its modifier, after body/neck motion.
		const Transform3D frame = sk->get_global_transform() * sk->get_bone_global_pose(eye_head_bone);
		const Vector3 direction = frame.affine_inverse().xform(p_target_world) - eye_center_head;
		if (direction.length_squared() > .0001) {
			const Vector2 directed(engine_atan2(direction.x, direction.z),
					engine_atan2(direction.y, Vector2(direction.x, direction.z).length()));
			aim = aim.lerp(directed, (real_t)clamp_double(target_weight, 0.0, 1.0));
		}
	}
	if (p_surface_update.is_valid()) {
		p_surface_update.call(eye_surface_angles(0, aim + p_offset), eye_surface_angles(1, aim + p_offset), lid_closure);
	}
	for (size_t side_index = 0; side_index < eye_bones.size(); side_index++) {
		const int32_t bone = eye_bones[side_index];
		if (bone < 0) {
			continue;
		}
		eye_write(sk, bone, eye_pose((int)side_index, aim + p_offset));
	}
}

// openpony_eye_motion.gd: a clip-tier tick re-applies the last full run.
void PonySolverNative::eye_rewrite(Object *p_skeleton) {
	Skeleton3D *sk = Object::cast_to<Skeleton3D>(p_skeleton);
	ERR_FAIL_NULL(sk);
	for (const std::pair<int32_t, Transform3D> &entry : eye_written) {
		sk->set_bone_pose(entry.first, entry.second);
	}
}

// hybrid_boop.gd _sync_snoot(). `bones`: head, nose, muzzle (-1 when missing), left and right
// cheek (-1 when missing). `decals`: the blush decals, left first.
void PonySolverNative::boop_sync(Object *p_skeleton, const PackedInt32Array &p_bones, Object *p_snoot, Object *p_skull_shape,
		Object *p_muzzle_shape, const Array &p_decals) {
	Skeleton3D *sk = Object::cast_to<Skeleton3D>(p_skeleton);
	Node3D *snoot = Object::cast_to<Node3D>(p_snoot);
	Node3D *skull = Object::cast_to<Node3D>(p_skull_shape);
	Node3D *muzzle = Object::cast_to<Node3D>(p_muzzle_shape);
	ERR_FAIL_COND(sk == nullptr || snoot == nullptr || skull == nullptr || muzzle == nullptr || p_bones.size() != 5);
	const Transform3D skeleton_global = sk->get_global_transform();
	const Transform3D head = skeleton_global * sk->get_bone_global_pose(p_bones[0]);
	const Vector3 nose = (skeleton_global * sk->get_bone_global_pose(p_bones[1])).origin;
	snoot->set_global_transform(Transform3D(Basis(), nose));
	skull->set_global_transform(head);
	muzzle->set_global_position(p_bones[2] < 0 ? nose : (skeleton_global * sk->get_bone_global_pose(p_bones[2])).origin);
	for (int64_t i = 0; i < p_decals.size(); i++) {
		const int32_t bone = p_bones[3 + (i == 0 ? 0 : 1)];
		if (bone < 0) {
			continue;
		}
		Node3D *decal = Object::cast_to<Node3D>(p_decals[i]);
		ERR_CONTINUE(decal == nullptr);
		const Transform3D cheek = skeleton_global * sk->get_bone_global_pose(bone);
		// Outward, a touch forward and down: the cheek surface under the eye.
		const double sign = i == 0 ? 1.0 : -1.0;
		const Vector3 normal = head.basis.xform(Vector3(sign * 0.8, -0.1, 0.5)).normalized();
		Basis basis;
		basis.set_column(1, normal);
		basis.set_column(0, normal.cross(head.basis.get_column(1)).normalized());
		basis.set_column(2, basis.get_column(0).cross(normal).normalized());
		const Vector3 centre = cheek.origin + head.basis.xform(Vector3(0.0, 0.035, 0.0)) + normal * (real_t)0.005;
		decal->set_global_transform(Transform3D(basis, centre));
	}
}

// pony_clip_head.gd: the neck and head bones (pony_secondary_motion.gd _neck) and the rest basis
// of each one's parent (_parent_frames).
void PonySolverNative::bind_clip_head(const PackedInt32Array &p_bones, const Array &p_parent_frames) {
	ERR_FAIL_COND(p_bones.size() != p_parent_frames.size());
	clip_head_bones.clear();
	clip_head_parents.clear();
	for (int64_t i = 0; i < p_bones.size(); i++) {
		clip_head_bones.push_back(p_bones[i]);
		clip_head_parents.push_back(p_parent_frames[i]);
	}
}

// pony_clip_head.gd _apply() after the interpolation: pony_secondary_motion.gd apply_pose()'s
// additive over the bones the clip posed, within the bound joint limits; with `rest`, its
// apply_rest_gaze() instead (a posture: the gaze only, 50 degrees at most, no limits).
void PonySolverNative::clip_head(Object *p_skeleton, const Vector3 &p_head, const Vector3 &p_gaze, const Vector3 &p_neck_gaze, bool p_rest) {
	Skeleton3D *skeleton = Object::cast_to<Skeleton3D>(p_skeleton);
	ERR_FAIL_NULL(skeleton);
	for (size_t i = 0; i < clip_head_bones.size(); i++) {
		const int32_t bone = clip_head_bones[i];
		const Basis &parent = clip_head_parents[i];
		if (p_rest) {
			const Vector3 look = (i == 2 ? p_gaze - p_neck_gaze * 0.55 : p_neck_gaze * 0.275).limit_length(deg_to_rad(50.0));
			Transform3D posed = skeleton->get_bone_pose(bone);
			posed.basis = parent.inverse() * basis_from_euler(look) * parent * posed.basis;
			skeleton->set_bone_pose(bone, posed);
			continue;
		}
		const double share = i == 2 ? 0.3 : 0.35;
		const Vector3 angles = p_head * share + (i == 2 ? p_gaze - p_neck_gaze * 0.55 : p_neck_gaze * 0.275);
		Transform3D pose = skeleton->get_bone_pose(bone);
		pose.basis = constrain(bone, parent.inverse() * basis_from_euler(angles) * parent * pose.basis);
		skeleton->set_bone_pose(bone, pose);
	}
}
