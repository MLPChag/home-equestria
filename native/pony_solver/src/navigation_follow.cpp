// Native pony navigation, corridor following: see navigation_follow.h.
#include "navigation_follow.h"

#include <algorithm>

namespace ponynav {

bool Corridor::assign(const std::vector<Vec3f> &points) {
	clear();
	for (const Vec3f &point : points) {
		if (!point.finite()) {
			clear();
			return false;
		}
		if (!points_.empty()) {
			const double dx = double(point.x) - double(points_.back().x);
			const double dz = double(point.z) - double(points_.back().z);
			if (dx * dx + dz * dz < 1e-6) {
				points_.back().y = point.y;
				continue;
			}
		}
		points_.push_back(point);
	}
	if (points_.size() < 2) {
		clear();
		return false;
	}
	const size_t n = points_.size();
	cumulative_.assign(n, 0.0);
	dir_x_.assign(n - 1, 0.0);
	dir_z_.assign(n - 1, 0.0);
	for (size_t i = 0; i + 1 < n; ++i) {
		const double dx = double(points_[i + 1].x) - double(points_[i].x);
		const double dz = double(points_[i + 1].z) - double(points_[i].z);
		const double length = std::sqrt(dx * dx + dz * dz);
		dir_x_[i] = dx / length;
		dir_z_[i] = dz / length;
		cumulative_[i + 1] = cumulative_[i] + length;
	}
	total_ = cumulative_.back();
	turn_.assign(n, 0.0);
	turn_abs_prefix_.assign(n, 0.0);
	turn_prefix_.assign(n, 0.0);
	for (size_t j = 1; j + 1 < n; ++j) {
		turn_[j] = wrap_angle(yaw_of(dir_x_[j], dir_z_[j]) - yaw_of(dir_x_[j - 1], dir_z_[j - 1]));
	}
	for (size_t j = 1; j < n; ++j) {
		turn_abs_prefix_[j] = turn_abs_prefix_[j - 1] + std::fabs(turn_[j]);
		turn_prefix_[j] = turn_prefix_[j - 1] + turn_[j];
	}
	return true;
}

void Corridor::clear() {
	points_.clear();
	cumulative_.clear();
	dir_x_.clear();
	dir_z_.clear();
	turn_.clear();
	turn_abs_prefix_.clear();
	turn_prefix_.clear();
	total_ = 0.0;
}

CorridorProjection Corridor::project_segment(size_t i, double x, double y, double z) const {
	CorridorProjection result;
	const Vec3f &a = points_[i];
	const Vec3f &b = points_[i + 1];
	const double length = cumulative_[i + 1] - cumulative_[i];
	const double px = x - double(a.x);
	const double pz = z - double(a.z);
	double t = (px * dir_x_[i] + pz * dir_z_[i]) / length;
	t = std::min(1.0, std::max(0.0, t));
	const double qx = double(a.x) + dir_x_[i] * length * t;
	const double qz = double(a.z) + dir_z_[i] * length * t;
	const double qy = double(a.y) + (double(b.y) - double(a.y)) * t;
	result.found = true;
	result.s = cumulative_[i] + length * t;
	result.lateral = std::sqrt((x - qx) * (x - qx) + (z - qz) * (z - qz));
	result.vertical = y - qy;
	result.segment = int32_t(i);
	return result;
}

CorridorProjection Corridor::project_window(double x, double y, double z, double from_s, double back, double ahead,
		double vertical_tolerance) const {
	CorridorProjection best;
	if (empty()) {
		return best;
	}
	const double low = from_s - back;
	const double high = from_s + ahead;
	size_t i = size_t(segment_at(low));
	for (; i + 1 < points_.size() && cumulative_[i] <= high; ++i) {
		if (cumulative_[i + 1] < low) {
			continue;
		}
		const CorridorProjection candidate = project_segment(i, x, y, z);
		if (std::fabs(candidate.vertical) > vertical_tolerance) {
			continue;
		}
		// Nearest wins; an exact tie (a corner point shared by two segments) takes the later.
		if (!best.found || candidate.lateral < best.lateral - 1e-9 ||
				(candidate.lateral <= best.lateral + 1e-9 && candidate.s > best.s)) {
			best = candidate;
		}
	}
	return best;
}

CorridorProjection Corridor::project_all(double x, double y, double z, double vertical_tolerance) const {
	CorridorProjection best;
	for (size_t i = 0; i + 1 < points_.size(); ++i) {
		const CorridorProjection candidate = project_segment(i, x, y, z);
		if (std::fabs(candidate.vertical) > vertical_tolerance) {
			continue;
		}
		if (!best.found || candidate.lateral < best.lateral - 1e-9) {
			best = candidate;
		}
	}
	return best;
}

int32_t Corridor::segment_at(double s) const {
	if (points_.size() < 2) {
		return 0;
	}
	const auto upper = std::upper_bound(cumulative_.begin(), cumulative_.end(), s);
	int64_t index = int64_t(upper - cumulative_.begin()) - 1;
	index = std::max<int64_t>(0, std::min<int64_t>(index, int64_t(points_.size()) - 2));
	return int32_t(index);
}

Vec3f Corridor::point_at(double s) const {
	if (points_.empty()) {
		return Vec3f();
	}
	if (s <= 0.0) {
		return points_.front();
	}
	if (s >= total_) {
		return points_.back();
	}
	const size_t i = size_t(segment_at(s));
	const double length = cumulative_[i + 1] - cumulative_[i];
	const double t = length > 0.0 ? (s - cumulative_[i]) / length : 0.0;
	const Vec3f &a = points_[i];
	const Vec3f &b = points_[i + 1];
	return Vec3f(float(double(a.x) + (double(b.x) - double(a.x)) * t), float(double(a.y) + (double(b.y) - double(a.y)) * t),
			float(double(a.z) + (double(b.z) - double(a.z)) * t));
}

void Corridor::tangent_at(double s, double &tx, double &tz) const {
	if (points_.size() < 2) {
		tx = 0.0;
		tz = -1.0;
		return;
	}
	const size_t i = size_t(segment_at(s));
	tx = dir_x_[i];
	tz = dir_z_[i];
}

size_t Corridor::corner_index_after(double s) const {
	// Last point index whose arc length is <= s.
	const auto upper = std::upper_bound(cumulative_.begin(), cumulative_.end(), s);
	const int64_t index = int64_t(upper - cumulative_.begin()) - 1;
	return size_t(std::max<int64_t>(0, index));
}

double Corridor::absolute_turn(double s0, double s1) const {
	if (points_.size() < 3 || s1 <= s0) {
		return 0.0;
	}
	const size_t a = corner_index_after(s0);
	const size_t b = corner_index_after(s1);
	return turn_abs_prefix_[std::min(b, points_.size() - 1)] - turn_abs_prefix_[std::min(a, points_.size() - 1)];
}

double Corridor::signed_turn(double s0, double s1) const {
	if (points_.size() < 3 || s1 <= s0) {
		return 0.0;
	}
	const size_t a = corner_index_after(s0);
	const size_t b = corner_index_after(s1);
	return turn_prefix_[std::min(b, points_.size() - 1)] - turn_prefix_[std::min(a, points_.size() - 1)];
}

} // namespace ponynav
