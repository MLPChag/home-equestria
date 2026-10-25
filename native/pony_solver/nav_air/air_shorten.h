// Path certification, shortening, smoothing and flight-limit validation for air routes.
//
// Everything is certified against the profile's inflated occupancy at the fine (0.5 m) grid:
// a segment is clear only when every fine voxel whose closed box it touches is FREE, including
// voxels touched only along an edge or at a corner (supercover). UNKNOWN never certifies. Curves
// are certified as chords swept by a cube whose half-size bounds the curve-to-chord distance, so
// an interpolated curve is never trusted because its straight endpoints are clear.
#pragma once

#include "air_space.h"

namespace nav_air {

// Calls visit(ctx, x, y, z, t) for every fine voxel (global 0.5 m grid index) whose closed box
// touches segment a-b; t is the segment parameter at which the voxel is reached. Voxels can be
// reported more than once. Returns false when the visitor returned false (stopped early).
using AirVoxelVisitor = bool (*)(void *ctx, int32_t x, int32_t y, int32_t z, float t);
bool air_supercover(const Vec3 &a, const Vec3 &b, AirVoxelVisitor visit, void *ctx);

struct AirSegmentCheck {
	Cell blocking = Cell::FREE; // first non-FREE state met
	Vec3 voxel_centre{0, 0, 0}; // where
	float t = 1.0f; // segment parameter of that voxel (1 when clear)
	uint32_t voxels = 0; // voxels sampled
};

// True when the cube of half-size `radius` swept along a-b only meets FREE voxels (radius 0: the
// segment itself). Stops at the first SOLID or UNKNOWN voxel.
bool air_segment_clear(const AirSpace &space, const Vec3 &a, const Vec3 &b, float radius = 0.0f,
		AirSegmentCheck *info = nullptr);

// Every segment of a polyline clear (per-segment radii optional; empty = 0).
bool air_polyline_clear(const AirSpace &space, const std::vector<Vec3> &points, const std::vector<float> &radii,
		AirSegmentCheck *info = nullptr);

// Greedy string pulling: from each kept point, keeps the farthest later point whose straight
// segment certifies, scanning `lookahead_after_fail` points past a failure. False (and out = in)
// when an input segment itself does not certify.
bool air_shorten(const AirSpace &space, const std::vector<Vec3> &in, std::vector<Vec3> &out,
		uint32_t lookahead_after_fail = 8);

struct AirSmoothOptions {
	float turn_radius = 6.0f; // wanted fillet radius (e.g. cruise_speed^2 / lateral_accel)
	float max_chord_length = 1.0f;
	uint32_t max_chords = 24;
	uint32_t shrink_attempts = 4; // halve the fillet this many times before keeping a sharp corner
	float line_clearance = 0.1f; // swept half-size tried on straight pieces (falls back to less)
};

struct AirSmoothPath {
	std::vector<Vec3> points;
	std::vector<float> clearance; // per segment: certified swept half-size (0 = segment itself)
	std::vector<uint8_t> sharp; // per point: 1 at a corner that could not be rounded
};

// Rounds corners of a certified polyline with quadratic fillets whose chords certify with their
// curve-to-chord bound. A fillet that does not certify shrinks, then the corner stays sharp
// (trajectory validation then slows the flyer there). False if the input does not certify.
bool air_smooth(const AirSpace &space, const std::vector<Vec3> &in, const AirSmoothOptions &options, AirSmoothPath &out);

struct AirFlightLimits {
	float max_speed = 20.0f;
	float min_speed = 0.0f; // stall speed; 0 for a flyer that can hover
	float max_accel = 6.0f;
	float max_brake = 8.0f;
	float max_lateral_accel = 10.0f;
	float max_turn_rate = 2.5f; // rad/s
	float max_climb_rate = 6.0f; // m/s upward
	float max_descent_rate = 8.0f; // m/s downward
	float tracking_tolerance = 0.0f; // certified slack around the line the follower may use
};

enum class AirTrajectoryVerdict : uint8_t {
	OK = 0,
	TOO_FAST_AT_START = 1, // cannot brake in time for the first limit: slow first or replan
	BELOW_STALL_SPEED = 2, // a limit falls under min_speed: needs another route
	INVALID = 3,
};

struct AirTrajectoryReport {
	AirTrajectoryVerdict verdict = AirTrajectoryVerdict::INVALID;
	std::vector<float> speed; // per point: highest speed respecting every limit
	std::vector<float> limit; // per point: local limit before acceleration passes
	float duration = 0.0f;
	uint32_t limiting_index = 0; // tightest point
};

// Speed profile that keeps the flyer on the certified line. At a corner of deviation theta the
// flyer's arc radius r = max(v^2 / a_lat, v / turn_rate) cuts inside by r * (sec(theta/2) - 1); that
// cut must stay inside the certified slack (max of tracking_tolerance and the adjacent segments'
// swept clearance), and the arc must fit in half of each adjacent segment. Climb and descent rates
// cap speed on sloped segments; acceleration and braking limits are applied forwards/backwards.
// Never cuts a corner: it slows down (to 0 at a sharp reversal) or rejects.
bool air_validate_trajectory(const std::vector<Vec3> &points, const std::vector<float> &clearance,
		const AirFlightLimits &limits, float start_speed, float end_speed, AirTrajectoryReport &out);

} // namespace nav_air
