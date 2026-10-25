// Native pony navigation, corridor following (docs/NAVIGATION_PHASE_2_2026_10_02.md).
// Pure C++17, no Godot types: the same file builds into the GDExtension and the standalone
// tests (native/pony_solver/tests/navigation_tests.cpp).
//
// A Corridor is one accepted route: its points, the horizontal arc length at every point and
// the heading of every segment. Progress along it is measured by projecting the actor onto
// the current segment and a bounded window ahead (never the whole route, so a loop or a stacked
// crossing cannot make a later or earlier segment win); a full nearest-segment search is only
// done in explicit recovery. Arc lengths are horizontal (XZ); heights ride along for floors.
#pragma once

#include "navigation_ground.h"

namespace ponynav {

constexpr double PI_D = 3.14159265358979323846;
constexpr double TAU_D = 2.0 * PI_D;

// Wraps an angle to (-PI, PI].
inline double wrap_angle(double angle) {
	angle = std::fmod(angle + PI_D, TAU_D);
	if (angle < 0.0) {
		angle += TAU_D;
	}
	return angle - PI_D;
}

// Godot yaw of a horizontal direction: forward is local -Z, and yaw 0 faces world -Z, so
// direction (dx, dz) = (-sin(yaw), -cos(yaw)) and yaw = atan2(-dx, -dz).
inline double yaw_of(double dx, double dz) {
	return std::atan2(-dx, -dz);
}

struct CorridorProjection {
	bool found = false;
	// Horizontal arc length of the projected point.
	double s = 0.0;
	// Horizontal distance from the actor to the projected point.
	double lateral = INF;
	// Actor height minus the corridor height at the projection.
	double vertical = 0.0;
	// Index of the segment's first point.
	int32_t segment = 0;
};

class Corridor {
public:
	// Builds the corridor; points closer than 1 mm horizontally to the previous point are merged
	// (the later height is kept). False when fewer than two distinct points remain.
	bool assign(const std::vector<Vec3f> &points);
	void clear();
	bool empty() const { return points_.size() < 2; }
	size_t size() const { return points_.size(); }
	double length() const { return total_; }
	const std::vector<Vec3f> &points() const { return points_; }
	const Vec3f &end() const { return points_.back(); }
	const Vec3f &start() const { return points_.front(); }
	double cumulative(size_t index) const { return cumulative_[index]; }

	// Nearest point on the segments whose arc range overlaps [from_s - back, from_s + ahead],
	// on a floor within `vertical_tolerance` of the actor (stacked floors keep their own).
	CorridorProjection project_window(double x, double y, double z, double from_s, double back, double ahead,
			double vertical_tolerance) const;
	// Every segment: explicit recovery only.
	CorridorProjection project_all(double x, double y, double z, double vertical_tolerance) const;

	// Point at arc length s (clamped to the corridor).
	Vec3f point_at(double s) const;
	// Unit tangent (horizontal) of the segment containing s.
	void tangent_at(double s, double &tx, double &tz) const;
	int32_t segment_at(double s) const;
	// Sum of the absolute heading changes at the corridor's corners inside (s0, s1]: a
	// conservative turn amount (an S-bend inside the window does not cancel itself).
	double absolute_turn(double s0, double s1) const;
	// Signed heading change (+ turns left, Godot yaw increasing) inside (s0, s1].
	double signed_turn(double s0, double s1) const;

private:
	size_t corner_index_after(double s) const;
	CorridorProjection project_segment(size_t i, double x, double y, double z) const;

	std::vector<Vec3f> points_;
	std::vector<double> cumulative_;
	// Per segment: unit direction.
	std::vector<double> dir_x_;
	std::vector<double> dir_z_;
	// Per point: heading change at that point (0 at both ends), and prefix sums.
	std::vector<double> turn_;
	std::vector<double> turn_abs_prefix_;
	std::vector<double> turn_prefix_;
	double total_ = 0.0;
};

} // namespace ponynav
