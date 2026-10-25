// Shared math for the native pony solver. Plain arithmetic runs here; anything that reaches the
// C runtime's transcendental functions is delegated to the engine (see engine_math.h).
#include "engine_math.h"

#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

namespace pony {

// @GlobalScope.wrapf as GDScript calls it (double precision), Godot core/math/math_funcs.h.
double wrapf_double(double value, double min, double max) {
	const double range = max - min;
	if (std::abs(range) < 0.00001) {
		return min;
	}
	const double result = value - (range * std::floor((value - min) / range));
	double tolerance = 0.00001 * std::abs(result);
	if (tolerance < 0.00001) {
		tolerance = 0.00001;
	}
	if (std::abs(result - max) < tolerance) {
		return min;
	}
	return result;
}

double clamp_double(double value, double min, double max) {
	return value < min ? min : (value > max ? max : value);
}

// Every operation below that reaches the C runtime's transcendental functions (acos, sin,
// cos, atan2) is delegated to the engine itself: the builtin Quaternion/Transform3D methods
// and constructors and the @GlobalScope utility functions are exactly what GDScript calls.
// Compiling the same formulas here is not enough: the official Windows engine is built by
// MinGW-GCC against msvcrt and mingw-w64's static math, which rounds differently from any
// other toolchain, and the refinement loop amplifies one-ulp differences into visible ones.
// The shortest-arc constructor goes to the engine too: godot-cpp's copy uses another
// parallel threshold (0.99999 against 0.99999975) and skips the final normalize().
// The rest (products, normalisation, sqrt, orthonormalisation) is plain IEEE arithmetic,
// identical in godot-cpp and the engine.
GDExtensionPtrBuiltInMethod builtin(GDExtensionVariantType type, const char *name, GDExtensionInt hash) {
	const StringName method(name);
	GDExtensionPtrBuiltInMethod result = internal::gdextension_interface_variant_get_ptr_builtin_method(type, method._native_ptr(), hash);
	CRASH_COND_MSG(result == nullptr, String("PonySolverNative: engine method missing: ") + name);
	return result;
}

GDExtensionPtrConstructor constructor(GDExtensionVariantType type, int32_t index) {
	GDExtensionPtrConstructor result = internal::gdextension_interface_variant_get_ptr_constructor(type, index);
	CRASH_COND_MSG(result == nullptr, "PonySolverNative: engine constructor missing");
	return result;
}

// Quaternion.angle_to()
double angle_between(const Quaternion &a, const Quaternion &b) {
	static const GDExtensionPtrBuiltInMethod method = builtin(GDEXTENSION_VARIANT_TYPE_QUATERNION, "angle_to", 3244682419);
	const GDExtensionConstTypePtr args[1] = { &b };
	double result = 0.0;
	method(const_cast<Quaternion *>(&a), args, &result, 1);
	return result;
}

// Quaternion.get_angle()
double angle_of(const Quaternion &q) {
	static const GDExtensionPtrBuiltInMethod method = builtin(GDEXTENSION_VARIANT_TYPE_QUATERNION, "get_angle", 466405837);
	double result = 0.0;
	method(const_cast<Quaternion *>(&q), nullptr, &result, 0);
	return result;
}

// Quaternion.slerp()
Quaternion slerp(const Quaternion &from, const Quaternion &to, double weight) {
	static const GDExtensionPtrBuiltInMethod method = builtin(GDEXTENSION_VARIANT_TYPE_QUATERNION, "slerp", 1773590316);
	const GDExtensionConstTypePtr args[2] = { &to, &weight };
	Quaternion result;
	method(const_cast<Quaternion *>(&from), args, &result, 2);
	return result;
}

// Transform3D.interpolate_with()
Transform3D interpolate(const Transform3D &from, const Transform3D &to, double weight) {
	static const GDExtensionPtrBuiltInMethod method = builtin(GDEXTENSION_VARIANT_TYPE_TRANSFORM3D, "interpolate_with", 1786453358);
	const GDExtensionConstTypePtr args[2] = { &to, &weight };
	Transform3D result;
	method(const_cast<Transform3D *>(&from), args, &result, 2);
	return result;
}

// Quaternion(axis, angle)
Quaternion axis_angle(const Vector3 &axis, double angle) {
	static const GDExtensionPtrConstructor make = constructor(GDEXTENSION_VARIANT_TYPE_QUATERNION, 3);
	const GDExtensionConstTypePtr args[2] = { &axis, &angle };
	Quaternion result;
	make(&result, args);
	return result;
}

// Quaternion(arc_from, arc_to)
Quaternion shortest_arc(const Vector3 &from, const Vector3 &to) {
	static const GDExtensionPtrConstructor make = constructor(GDEXTENSION_VARIANT_TYPE_QUATERNION, 4);
	const GDExtensionConstTypePtr args[2] = { &from, &to };
	Quaternion result;
	make(&result, args);
	return result;
}

// limb_solver.gd alignment()
Quaternion alignment(const Vector3 &from, const Vector3 &to) {
	if (from.length_squared() < 1e-12 || to.length_squared() < 1e-12) {
		return Quaternion();
	}
	return shortest_arc(from.normalized(), to.normalized()).normalized();
}

Quaternion rotation_of(const Basis &basis) {
	return basis.orthonormalized().get_rotation_quaternion();
}

// pony_joint_limits.gd _split(): twist about `axis` (as an angle) and the remaining swing.
void split(Quaternion rotation, const Vector3 &axis, double &angle, Quaternion &swing) {
	if (rotation.w < 0.0) {
		rotation = -rotation;
	}
	const Vector3 vector(rotation.x, rotation.y, rotation.z);
	const Vector3 projection = axis * vector.dot(axis);
	Quaternion twist(projection.x, projection.y, projection.z, rotation.w);
	if (twist.length_squared() < 1e-10) {
		twist = Quaternion();
	} else {
		twist = twist.normalized();
	}
	angle = wrapf_double(2.0 * engine_atan2((double)Vector3(twist.x, twist.y, twist.z).dot(axis), (double)twist.w), -Math_PI, Math_PI);
	swing = (rotation * twist.inverse()).normalized();
}


// Basis(axis, angle)
Basis basis_axis_angle(const Vector3 &axis, double angle) {
	static const GDExtensionPtrConstructor make = constructor(GDEXTENSION_VARIANT_TYPE_BASIS, 3);
	const GDExtensionConstTypePtr args[2] = { &axis, &angle };
	Basis result;
	make(&result, args);
	return result;
}

// Vector3.angle_to()
double vector_angle(const Vector3 &a, const Vector3 &b) {
	static const GDExtensionPtrBuiltInMethod method = builtin(GDEXTENSION_VARIANT_TYPE_VECTOR3, "angle_to", 1047977935);
	const GDExtensionConstTypePtr args[1] = { &b };
	double result = 0.0;
	method(const_cast<Vector3 *>(&a), args, &result, 1);
	return result;
}

// @GlobalScope.exp / atan2 / cos, as GDScript calls them.
double engine_exp(double x) {
	return UtilityFunctions::exp(x);
}

double engine_atan2(double y, double x) {
	return UtilityFunctions::atan2(y, x);
}

double engine_cos(double x) {
	return UtilityFunctions::cos(x);
}

// Basis.from_euler(euler) (default order YXZ)
Basis basis_from_euler(const Vector3 &euler) {
	static const GDExtensionPtrBuiltInMethod method = builtin(GDEXTENSION_VARIANT_TYPE_BASIS, "from_euler", 2802321791);
	const int64_t order = 2;
	const GDExtensionConstTypePtr args[2] = { &euler, &order };
	Basis result;
	method(nullptr, args, &result, 2);
	return result;
}

} // namespace pony
