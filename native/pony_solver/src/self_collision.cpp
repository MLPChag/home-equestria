// pony_self_collision.gd measure(), _separate(), _closest_on_segment() and
// _closest_between_segments(), line for line. Scalars are doubles like GDScript floats; vectors
// are single precision. `integrate()` (smoothing, exp) stays in GDScript.
#include "engine_math.h"
#include "pony_solver_native.h"

using namespace godot;
using namespace pony;

namespace {

// Contact labels, in pony_self_collision.gd LABELS order.
enum Label {
	HOOF_HOOF,
	HOOF_UPPER,
	HOOF_CANNON,
	UPPER_UPPER,
	UPPER_CANNON,
	CANNON_UPPER,
	CANNON_CANNON,
	HOOF_BELLY,
	CANNON_BELLY,
};

struct Collision {
	Vector3 *wanted;
	float *penetration; // PackedFloat32Array in GDScript
	double *max_penetration;
	std::vector<double> *records; // [depth, label, i, j] per overlap, detection order
	Vector3 forward;
};

// _share()
double share(double mobility_a, double mobility_b) {
	const double total = mobility_a + mobility_b;
	if (total < 0.05) {
		return 0.5;
	}
	return mobility_a / total;
}

// _separate()
void separate(Collision &c, int i, int j, const Vector3 &point_i, const Vector3 &point_j, double clearance,
		double share_i, double share_j, int label) {
	const Vector3 d = point_i - point_j;
	const double distance = d.length();
	if (distance >= clearance) {
		return;
	}
	const double depth = clearance - distance;
	c.records->push_back(depth);
	c.records->push_back(label);
	c.records->push_back(i);
	c.records->push_back(j);
	const Vector3 normal = distance > 0.001 ? d / (real_t)distance : c.forward;
	c.penetration[i] = (float)maxf(c.penetration[i], depth);
	*c.max_penetration = maxf(*c.max_penetration, depth);
	c.wanted[i] += normal * (real_t)depth * (real_t)share_i;
	if (j >= 0) {
		c.penetration[j] = (float)maxf(c.penetration[j], depth);
		c.wanted[j] -= normal * (real_t)depth * (real_t)share_j;
	}
}

// _closest_on_segment()
Vector3 closest_on_segment(const Vector3 &p, const Vector3 &a, const Vector3 &b) {
	const Vector3 ab = b - a;
	const double t = clamp_double((double)(p - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0);
	return a + ab * (real_t)t;
}

// _closest_between_segments() (Ericson, Real-Time Collision Detection, 5.1.9)
void closest_between_segments(const Vector3 &p1, const Vector3 &q1, const Vector3 &p2, const Vector3 &q2,
		Vector3 &r_first, Vector3 &r_second) {
	const Vector3 d1 = q1 - p1;
	const Vector3 d2 = q2 - p2;
	const Vector3 r = p1 - p2;
	const double a = d1.length_squared();
	const double e = d2.length_squared();
	const double f = d2.dot(r);
	double s = 0.0;
	double t = 0.0;
	if (a <= 1e-9 && e <= 1e-9) {
		r_first = p1;
		r_second = p2;
		return;
	}
	if (a <= 1e-9) {
		t = clamp_double(f / e, 0.0, 1.0);
	} else {
		const double c = d1.dot(r);
		if (e <= 1e-9) {
			s = clamp_double(-c / a, 0.0, 1.0);
		} else {
			const double b = d1.dot(d2);
			const double denominator = a * e - b * b;
			s = denominator > 1e-9 ? clamp_double((b * f - c * e) / denominator, 0.0, 1.0) : 0.0;
			t = (b * s + f) / e;
			if (t < 0.0) {
				t = 0.0;
				s = clamp_double(-c / a, 0.0, 1.0);
			} else if (t > 1.0) {
				t = 1.0;
				s = clamp_double((b - c) / a, 0.0, 1.0);
			}
		}
	}
	r_first = p1 + d1 * (real_t)s;
	r_second = p2 + d2 * (real_t)t;
}

} // namespace

// measure() on plain values: the middle and leaf transforms of each leg's forward kinematics, the
// dynamic soles, the raw feet[i].weight values and the shape (hoof, segment and belly radius,
// hoof lift).
void PonySolverNative::measure_core(const Transform3D p_middles[4], const Transform3D p_leaves[4], const Vector3 p_soles[4],
		const double p_weights[4], const Transform3D &p_frame, const Vector3 &p_forward, const double p_shape[4],
		const Vector3 &p_belly_from, const Vector3 &p_belly_to, MeasureResult &r_result) {
	const double hoof_radius = p_shape[0];
	const double segment_radius = p_shape[1];
	const double belly_radius = p_shape[2];
	const double hoof_lift = p_shape[3];
	r_result = MeasureResult();
	Collision c;
	c.wanted = r_result.wanted;
	c.penetration = r_result.penetration;
	c.max_penetration = &r_result.max_penetration;
	c.records = &r_result.records;
	c.forward = p_forward;
	Vector3 hooves[4];
	Vector3 segments[4][2][2];
	double mobility[4];
	for (int i = 0; i < 4; i++) {
		const Transform3D &middle = p_middles[i];
		const Transform3D &leaf = p_leaves[i];
		const Vector3 sole = leaf.xform(p_soles[i]);
		hooves[i] = sole + Vector3(0, 1, 0) * (real_t)hoof_lift;
		segments[i][0][0] = middle.origin;
		segments[i][0][1] = leaf.origin;
		segments[i][1][0] = leaf.origin;
		segments[i][1][1] = sole;
		mobility[i] = 1.0 - clamp_double(p_weights[i], 0.0, 1.0);
	}
	const Vector3 belly_a = p_frame.xform(p_belly_from);
	const Vector3 belly_b = p_frame.xform(p_belly_to);
	for (int i = 0; i < 4; i++) {
		for (int j = i + 1; j < 4; j++) {
			const double share_i = share(mobility[i], mobility[j]);
			const double share_j = 1.0 - share_i;
			// Hoof against hoof.
			separate(c, i, j, hooves[i], hooves[j], hoof_radius * 2.0, share_i, share_j, HOOF_HOOF);
			// Hoof against the other leg's segments, both ways.
			for (int k = 0; k < 2; k++) {
				const int label = k == 0 ? HOOF_UPPER : HOOF_CANNON;
				Vector3 q = closest_on_segment(hooves[i], segments[j][k][0], segments[j][k][1]);
				separate(c, i, j, hooves[i], q, hoof_radius + segment_radius, share_i, share_j, label);
				q = closest_on_segment(hooves[j], segments[i][k][0], segments[i][k][1]);
				separate(c, j, i, hooves[j], q, hoof_radius + segment_radius, share_j, share_i, label);
			}
			// Lower segments against each other (legs crossing mid-stride).
			for (int a = 0; a < 2; a++) {
				for (int b = 0; b < 2; b++) {
					Vector3 first;
					Vector3 second;
					closest_between_segments(segments[i][a][0], segments[i][a][1], segments[j][b][0], segments[j][b][1], first, second);
					separate(c, i, j, first, second, segment_radius * 2.0, share_i, share_j, UPPER_UPPER + a * 2 + b);
				}
			}
		}
	}
	// Legs against the belly. The body never moves out of the way.
	for (int i = 0; i < 4; i++) {
		const Vector3 q = closest_on_segment(hooves[i], belly_a, belly_b);
		separate(c, i, -1, hooves[i], q, hoof_radius + belly_radius, 1.0, 0.0, HOOF_BELLY);
		Vector3 first;
		Vector3 second;
		closest_between_segments(segments[i][1][0], segments[i][1][1], belly_a, belly_b, first, second);
		separate(c, i, -1, first, second, segment_radius + belly_radius, 1.0, 0.0, CANNON_BELLY);
	}
}

// measure(). `bones` holds [middle, leaf] per leg; `weights` the raw feet[i].weight values.
// Returns [wanted (PackedVector3Array), penetration (PackedFloat32Array), max_penetration,
// records (PackedFloat64Array of depth, label, i, j)].
Array PonySolverNative::measure_self_collision(const Array &p_fk, const PackedInt32Array &p_bones,
		const PackedVector3Array &p_soles, const PackedFloat64Array &p_weights, const Transform3D &p_frame,
		const Vector3 &p_forward, const PackedFloat64Array &p_shape, const Vector3 &p_belly_from,
		const Vector3 &p_belly_to) {
	Array result;
	ERR_FAIL_COND_V(p_bones.size() != 8 || p_soles.size() != 4 || p_weights.size() != 4 || p_shape.size() != 4, result);
	Transform3D middles[4];
	Transform3D leaves[4];
	Vector3 soles[4];
	double weights[4];
	double shape[4];
	for (int i = 0; i < 4; i++) {
		middles[i] = p_fk[p_bones[i * 2]];
		leaves[i] = p_fk[p_bones[i * 2 + 1]];
		soles[i] = p_soles[i];
		weights[i] = p_weights[i];
		shape[i] = p_shape[i];
	}
	MeasureResult measured;
	measure_core(middles, leaves, soles, weights, p_frame, p_forward, shape, p_belly_from, p_belly_to, measured);
	PackedVector3Array wanted;
	PackedFloat32Array penetration;
	for (int i = 0; i < 4; i++) {
		wanted.push_back(measured.wanted[i]);
		penetration.push_back(measured.penetration[i]);
	}
	PackedFloat64Array records;
	records.resize(measured.records.size());
	for (size_t i = 0; i < measured.records.size(); i++) {
		records.set(i, measured.records[i]);
	}
	result.push_back(wanted);
	result.push_back(penetration);
	result.push_back(measured.max_penetration);
	result.push_back(records);
	return result;
}
