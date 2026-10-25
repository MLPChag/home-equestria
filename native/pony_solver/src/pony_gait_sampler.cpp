#include "pony_gait_sampler.h"
#include "engine_math.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>

// GDScript rounds each arithmetic operation separately, including on ARM.
#if defined(__clang__)
#pragma clang fp contract(off)
#endif

using namespace godot;

void PonyGaitSampler::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "standing", "samples", "gallop", "legs", "body_animated", "body_blend"), &PonyGaitSampler::configure);
	ClassDB::bind_method(D_METHOD("sample", "phase", "phases", "walk", "gallop_phase", "gallop_blend", "leg_blends", "blend"), &PonyGaitSampler::sample);
}

bool PonyGaitSampler::read_pose(const Array &input, int count, std::vector<Transform3D> &out) {
	if (input.size() != count) return false;
	out.resize(count);
	for (int i = 0; i < count; ++i) {
		if (input[i].get_type() != Variant::TRANSFORM3D) return false;
		out[i] = input[i];
	}
	return true;
}

bool PonyGaitSampler::read_bones(const PackedInt32Array &input, int count, std::vector<int> &out) {
	out.clear();
	for (int i = 0; i < input.size(); ++i) {
		if (input[i] < 0 || input[i] >= count) return false;
		out.push_back(input[i]);
	}
	return true;
}

bool PonyGaitSampler::read_clip(const Array &frames, int count, Clip &out) {
	if (frames.is_empty()) return false;
	out.frames.resize(frames.size());
	for (int i = 0; i < frames.size(); ++i) {
		if (frames[i].get_type() != Variant::ARRAY || !read_pose(frames[i], count, out.frames[i])) return false;
	}
	out.first = Array(frames[0]).duplicate();
	return true;
}

bool PonyGaitSampler::configure(const Array &p_standing, const Array &p_samples, const Dictionary &p_gallop,
		const Array &p_legs, const PackedInt32Array &p_body_animated, const PackedInt32Array &p_body_blend) {
	ready = false;
	const int count = p_standing.size();
	std::vector<Transform3D> checked;
	if (count == 0 || !read_pose(p_standing, count, checked) || p_legs.size() != 4) return false;
	standing = p_standing.duplicate();
	if (!read_clip(p_samples, count, trot) || !p_gallop.has("samples") || !p_gallop.has("animated_bones")) return false;
	if (!read_clip(p_gallop["samples"], count, gallop) ||
			!read_bones(p_gallop["animated_bones"], count, gallop.animated) ||
			!read_bones(p_body_animated, count, body_animated) || !read_bones(p_body_blend, count, body_blend)) return false;
	legs.clear();
	for (int i = 0; i < p_legs.size(); ++i) {
		const Dictionary source = p_legs[i];
		for (const char *key : {"contact_start", "contact_span", "chain", "walk_lift", "walk_land", "walk_curl"}) {
			if (!source.has(key)) return false;
		}
		Leg leg;
		leg.contact_start = source["contact_start"];
		leg.contact_span = source["contact_span"];
		if (!std::isfinite(leg.contact_start) || !std::isfinite(leg.contact_span) || leg.contact_span < 0.0 || leg.contact_span >= 1.0) return false;
		const Array chain = source["chain"];
		PackedInt32Array ids;
		for (int j = 0; j < chain.size(); ++j) ids.append(chain[j]);
		if (!read_bones(ids, count, leg.chain)) return false;
		std::vector<Transform3D> lift, land;
		if (!read_pose(source["walk_lift"], count, lift) || !read_pose(source["walk_land"], count, land)) return false;
		const Dictionary curls = source["walk_curl"];
		for (int bone : leg.chain) {
			leg.lift.push_back(lift[bone]);
			leg.land.push_back(land[bone]);
			leg.has_curl.push_back(curls.has(bone));
			leg.curl.push_back(curls.get(bone, Vector3()));
		}
		legs.push_back(std::move(leg));
	}
	ready = true;
	return true;
}

TypedArray<Transform3D> PonyGaitSampler::sample_gallop(double phase) const {
	const double cursor = UtilityFunctions::fposmod(phase, 1.0) * gallop.frames.size();
	const int index = int(cursor);
	TypedArray<Transform3D> result = gallop.first.duplicate();
	for (int bone : gallop.animated) {
		result[bone] = pony::interpolate(gallop.frames[index][bone], gallop.frames[(index + 1) % gallop.frames.size()][bone], cursor - index);
	}
	return result;
}

TypedArray<Transform3D> PonyGaitSampler::sample_steps(double phase, const PackedFloat64Array &phases, double walk) const {
	constexpr double PI = 3.1415926535897932384626433833;
	constexpr double TAU = 2.0 * PI;
	const double body_cursor = UtilityFunctions::fposmod(phase, 1.0) * trot.frames.size();
	const int body_index = int(body_cursor);
	TypedArray<Transform3D> result = trot.first.duplicate();
	for (int bone : body_animated) {
		result[bone] = pony::interpolate(trot.frames[body_index][bone], trot.frames[(body_index + 1) % trot.frames.size()][bone], body_cursor - body_index);
	}
	for (int i = 0; i < int(legs.size()); ++i) {
		const Leg &leg = legs[i];
		const double progress = UtilityFunctions::fposmod(phases[i] - leg.contact_start, 1.0);
		const double swing = pony::clamp_double((progress - leg.contact_span) / (1.0 - leg.contact_span), 0.0, 1.0);
		double pose_phase = phases[i];
		if (swing > 0.0) {
			const double eased = swing - 0.35 * walk * UtilityFunctions::sin(TAU * swing) / TAU;
			pose_phase = leg.contact_start + leg.contact_span + eased * (1.0 - leg.contact_span);
		}
		const double cursor = UtilityFunctions::fposmod(pose_phase, 1.0) * trot.frames.size();
		const int index = int(cursor);
		const bool folding = swing > 0.0 && walk > 0.0;
		const double curl = UtilityFunctions::pow(UtilityFunctions::sin(PI * swing), 2.0);
		for (int j = 0; j < int(leg.chain.size()); ++j) {
			const int bone = leg.chain[j];
			Transform3D local = pony::interpolate(trot.frames[index][bone], trot.frames[(index + 1) % trot.frames.size()][bone], cursor - index);
			if (folding) {
				Transform3D folded = pony::interpolate(leg.lift[j], leg.land[j], UtilityFunctions::smoothstep(0.0, 1.0, swing));
				if (leg.has_curl[j]) {
					const Vector3 &bend = leg.curl[j];
					folded.basis = pony::basis_axis_angle(bend.normalized(), double(bend.length()) * curl) * folded.basis;
				}
				local.basis = Basis(pony::slerp(pony::rotation_of(local.basis), pony::rotation_of(folded.basis), walk)).scaled_local(local.basis.get_scale());
			}
			result[bone] = local;
		}
	}
	return result;
}

TypedArray<Transform3D> PonyGaitSampler::sample(double phase, const PackedFloat64Array &phases, double walk,
		double gallop_phase, double gallop_blend, const PackedFloat64Array &leg_blends, double blend) const {
	ERR_FAIL_COND_V(!ready, TypedArray<Transform3D>());
	ERR_FAIL_COND_V(phases.size() != 4 || leg_blends.size() != 4, standing.duplicate());
	ERR_FAIL_COND_V(!std::isfinite(phase) || !std::isfinite(gallop_phase), standing.duplicate());
	for (int i = 0; i < 4; ++i) {
		ERR_FAIL_COND_V(!std::isfinite(phases[i]), standing.duplicate());
	}
	if (blend <= 0.0) return standing.duplicate();
	bool all_gallop = true, all_trot = true;
	for (int i = 0; i < 4; ++i) {
		all_gallop = all_gallop && leg_blends[i] >= 1.0;
		all_trot = all_trot && leg_blends[i] <= 0.0;
	}
	TypedArray<Transform3D> pose;
	if (gallop_blend >= 1.0 && all_gallop) {
		pose = sample_gallop(gallop_phase);
	} else {
		pose = sample_steps(phase, phases, walk);
		if (gallop_blend > 0.0 || !all_trot) {
			const TypedArray<Transform3D> to = sample_gallop(gallop_phase);
			for (int bone : body_blend) pose[bone] = pony::interpolate(pose[bone], to[bone], gallop_blend);
			for (int i = 0; i < 4; ++i) {
				for (int bone : legs[i].chain) pose[bone] = pony::interpolate(pose[bone], to[bone], leg_blends[i]);
			}
		}
	}
	if (blend >= 1.0) return pose;
	TypedArray<Transform3D> result = standing.duplicate();
	for (int bone : body_blend) result[bone] = pony::interpolate(standing[bone], pose[bone], blend);
	for (const Leg &leg : legs) {
		for (int bone : leg.chain) result[bone] = pony::interpolate(standing[bone], pose[bone], blend);
	}
	return result;
}
