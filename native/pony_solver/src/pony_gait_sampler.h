// HERO source-pose sampling, matching pony_gait_profile.gd and
// pony_locomotion.gd::_sample_source_pose. Bound tables are private snapshots;
// each sample returns an independent pose. No nodes, physics or worker state.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <vector>

namespace godot {

class PonyGaitSampler : public RefCounted {
	GDCLASS(PonyGaitSampler, RefCounted)
	struct Leg {
		double contact_start = 0.0, contact_span = 0.0;
		std::vector<int> chain;
		std::vector<Transform3D> lift, land;
		std::vector<Vector3> curl;
		std::vector<bool> has_curl;
	};
	struct Clip {
		TypedArray<Transform3D> first;
		std::vector<std::vector<Transform3D>> frames;
		std::vector<int> animated;
	};
	bool ready = false;
	TypedArray<Transform3D> standing;
	Clip trot, gallop;
	std::vector<Leg> legs;
	std::vector<int> body_animated, body_blend;
	static bool read_pose(const Array &input, int count, std::vector<Transform3D> &out);
	static bool read_bones(const PackedInt32Array &input, int count, std::vector<int> &out);
	static bool read_clip(const Array &frames, int count, Clip &out);
	TypedArray<Transform3D> sample_gallop(double phase) const;
	TypedArray<Transform3D> sample_steps(double phase, const PackedFloat64Array &phases, double walk) const;

protected:
	static void _bind_methods();

public:
	bool configure(const Array &p_standing, const Array &p_samples, const Dictionary &p_gallop,
			const Array &p_legs, const PackedInt32Array &p_body_animated, const PackedInt32Array &p_body_blend);
	TypedArray<Transform3D> sample(double phase, const PackedFloat64Array &phases, double walk,
			double gallop_phase, double gallop_blend, const PackedFloat64Array &leg_blends, double blend) const;
};

} // namespace godot
