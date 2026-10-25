// Shared math for the native pony solver (docs/NATIVE_SOLVER_2026_09_25.md).
//
// Every operation that reaches the C runtime's transcendental functions (acos, sin, cos, atan2,
// exp) is delegated to the engine: the builtin Quaternion/Basis/Vector3/Transform3D methods and
// constructors and the @GlobalScope utility functions are exactly what GDScript calls. Compiling
// the same formulas here is not enough: the official Windows engine is built by MinGW-GCC against
// msvcrt and mingw-w64's static math, which rounds differently from any other toolchain. The
// shortest-arc constructor goes to the engine too (godot-cpp's copy uses another threshold and
// skips the final normalize()). The rest (products, normalisation, sqrt, orthonormalisation,
// lerp, limit_length, move_toward) is plain IEEE arithmetic, identical in godot-cpp and the engine.
#pragma once

#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <gdextension_interface.h>

namespace pony {

using godot::Basis;
using godot::Quaternion;
using godot::Transform3D;
using godot::Vector3;

double wrapf_double(double value, double min, double max); // @GlobalScope.wrapf (double)
double clamp_double(double value, double min, double max); // @GlobalScope.clampf
GDExtensionPtrBuiltInMethod builtin(GDExtensionVariantType type, const char *name, GDExtensionInt hash);
GDExtensionPtrConstructor constructor(GDExtensionVariantType type, int32_t index);

double angle_between(const Quaternion &a, const Quaternion &b); // Quaternion.angle_to()
double angle_of(const Quaternion &q); // Quaternion.get_angle()
Quaternion slerp(const Quaternion &from, const Quaternion &to, double weight); // Quaternion.slerp()
Transform3D interpolate(const Transform3D &from, const Transform3D &to, double weight); // Transform3D.interpolate_with()
Quaternion axis_angle(const Vector3 &axis, double angle); // Quaternion(axis, angle)
Quaternion shortest_arc(const Vector3 &from, const Vector3 &to); // Quaternion(arc_from, arc_to)
Basis basis_axis_angle(const Vector3 &axis, double angle); // Basis(axis, angle)
double vector_angle(const Vector3 &a, const Vector3 &b); // Vector3.angle_to()
Basis basis_from_euler(const Vector3 &euler); // Basis.from_euler(euler)
double engine_exp(double x); // @GlobalScope.exp
double engine_atan2(double y, double x); // @GlobalScope.atan2
double engine_cos(double x); // @GlobalScope.cos

Quaternion alignment(const Vector3 &from, const Vector3 &to); // limb_solver.gd alignment()
Quaternion rotation_of(const Basis &basis); // basis.orthonormalized().get_rotation_quaternion()
void split(Quaternion rotation, const Vector3 &axis, double &angle, Quaternion &swing); // pony_joint_limits.gd _split()

// GDScript maxf/minf (Godot's MAX/MIN macros).
inline double maxf(double a, double b) { return a < b ? b : a; }
inline double minf(double a, double b) { return a < b ? a : b; }
// GDScript lerpf.
inline double lerpf(double from, double to, double weight) { return from + (to - from) * weight; }
// GDScript deg_to_rad (double).
inline double deg_to_rad(double degrees) { return degrees * (3.1415926535897932384626433833 / 180.0); }

} // namespace pony
