// Native 3D flight routes for pegasi and alicorns (phase 5 of
// docs/NAVIGATION_OVERHAUL_COMPLETE_2026_10_02.txt; docs/NAVIGATION_PHASE_5_2026_10_02.md).
// Binds the Godot-independent nav_air core (sparse air volume, 3D search, air follower) for
// world/characters/locomotion/native_air.gd. One instance holds the baked air volume; every
// flying pony gets a follower by id. Positions passed in and out are pony ROOT positions: the
// binding adds and removes the baked profile's body-centre offset.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <map>
#include <memory>

#include "air_follow.h"
#include "air_search.h"
#include "air_tiles.h"

namespace godot {

class PonyAirNavigation : public RefCounted {
	GDCLASS(PonyAirNavigation, RefCounted);

	struct Flyer {
		nav_air::AirFollower follower;
		nav_air::AirFlightProfile profile;
		uint64_t route = 0;
	};

	std::unique_ptr<nav_air::AirTileSpace> space;
	nav_air::AirSearch search;
	std::map<int64_t, Flyer> flyers;
	bool loaded = false;

	nav_air::Vec3 centre(const Vector3 &root) const;
	Vector3 root(const nav_air::Vec3 &centre) const;

protected:
	static void _bind_methods();

public:
	PonyAirNavigation();
	~PonyAirNavigation() override;

	// The baked .airnav bytes (world/navigation/air_data/). {ok, error, tiles, profile, envelope}
	Dictionary load_bytes(const PackedByteArray &p_bytes);
	bool is_loaded() const { return loaded; }
	// FREE, SOLID or UNKNOWN (0, 1, 2 as in nav_air::Cell) at a pony ROOT position.
	int64_t sample(const Vector3 &p_root) const;
	// Search a route for flyer `id` from `from` to a hover box around `to` (both pony roots) and,
	// when one certifies, start following it. options: body_scale, dash (bool), half_extent,
	// max_expansions, cruise_speed. Returns {status, status_name, points (roots), length, prepared}.
	Dictionary plan(int64_t p_id, const Vector3 &p_from, const Vector3 &p_to, const Dictionary &p_options);
	// One follower tick. Returns {mode, mode_name, velocity, yaw, pitch, bank, remaining, reason,
	// limit, progress}; mode ARRIVED (3) once at the goal, FAILED (4) once on terminal failure.
	Dictionary step(int64_t p_id, const Vector3 &p_root, const Vector3 &p_velocity, double p_yaw, double p_delta,
			double p_requested_speed);
	void clear(int64_t p_id);
	bool following(int64_t p_id) const;
};

} // namespace godot
