#include "pony_air_navigation.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <string>

#include "air_serialize.h"

using namespace godot;

namespace {

double number(const Dictionary &d, const char *key, double fallback) {
	const Variant value = d.get(key, Variant());
	if (value.get_type() == Variant::FLOAT || value.get_type() == Variant::INT) {
		const double v = double(value);
		return std::isfinite(v) ? v : fallback;
	}
	return fallback;
}

bool finite(const Vector3 &v) {
	return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

Vector3 gd(const nav_air::Vec3 &v) {
	return Vector3(v.x, v.y, v.z);
}

} // namespace

PonyAirNavigation::PonyAirNavigation() :
		space(new nav_air::AirTileSpace()) {}

PonyAirNavigation::~PonyAirNavigation() {
	search.cancel();
}

nav_air::Vec3 PonyAirNavigation::centre(const Vector3 &p_root) const {
	const nav_air::Vec3 &o = space->profile().centre_offset;
	return nav_air::Vec3{ float(p_root.x) + o.x, float(p_root.y) + o.y, float(p_root.z) + o.z };
}

Vector3 PonyAirNavigation::root(const nav_air::Vec3 &p_centre) const {
	const nav_air::Vec3 &o = space->profile().centre_offset;
	return Vector3(p_centre.x - o.x, p_centre.y - o.y, p_centre.z - o.z);
}

void PonyAirNavigation::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_bytes", "bytes"), &PonyAirNavigation::load_bytes);
	ClassDB::bind_method(D_METHOD("is_loaded"), &PonyAirNavigation::is_loaded);
	ClassDB::bind_method(D_METHOD("sample", "root"), &PonyAirNavigation::sample);
	ClassDB::bind_method(D_METHOD("plan", "id", "from", "to", "options"), &PonyAirNavigation::plan);
	ClassDB::bind_method(D_METHOD("step", "id", "root", "velocity", "yaw", "delta", "requested_speed"),
			&PonyAirNavigation::step);
	ClassDB::bind_method(D_METHOD("clear", "id"), &PonyAirNavigation::clear);
	ClassDB::bind_method(D_METHOD("following", "id"), &PonyAirNavigation::following);
}

Dictionary PonyAirNavigation::load_bytes(const PackedByteArray &p_bytes) {
	Dictionary result;
	flyers.clear();
	std::unique_ptr<nav_air::AirTileSpace> fresh(new nav_air::AirTileSpace());
	nav_air::AirDataInfo info;
	std::string error;
	const bool ok = nav_air::read_air_data(p_bytes.ptr(), size_t(p_bytes.size()), *fresh, &info, &error);
	result["ok"] = ok;
	result["error"] = String(error.c_str());
	if (!ok) {
		return result;
	}
	space = std::move(fresh);
	loaded = true;
	result["tiles"] = int64_t(info.tile_count);
	result["profile"] = String(info.profile.name.c_str());
	result["envelope"] = info.profile.envelope_radius;
	result["centre_offset"] = gd(info.profile.centre_offset);
	return result;
}

int64_t PonyAirNavigation::sample(const Vector3 &p_root) const {
	if (!loaded || !finite(p_root)) {
		return int64_t(nav_air::Cell::UNKNOWN);
	}
	return int64_t(space->sample(centre(p_root)));
}

Dictionary PonyAirNavigation::plan(int64_t p_id, const Vector3 &p_from, const Vector3 &p_to, const Dictionary &p_options) {
	Dictionary result;
	result["prepared"] = false;
	if (!loaded || !finite(p_from) || !finite(p_to)) {
		result["status"] = int64_t(nav_air::AirStatus::INVALID);
		result["status_name"] = loaded ? "non-finite endpoint" : "no air data";
		return result;
	}
	const float body_scale = float(number(p_options, "body_scale", 1.0));
	const bool dash = bool(p_options.get("dash", false));
	const float half = float(number(p_options, "half_extent", 1.0));
	nav_air::AirSearchLimits limits;
	limits.total_expansions = uint32_t(std::max(1000.0, number(p_options, "max_expansions", 250000.0)));
	limits.slice_seconds = 0.0; // one synchronous search: the binding is called for rare flight requests
	const nav_air::AirStatus status = [&]() {
		const nav_air::AirStatus first = search.begin(*space, centre(p_from), nav_air::AirGoal::hover(centre(p_to), half), limits);
		return first == nav_air::AirStatus::PENDING ? search.run_to_end() : first;
	}();
	result["status"] = int64_t(status);
	result["status_name"] = String(nav_air::air_status_name(status));
	result["expansions"] = int64_t(search.stats().expansions);
	if (status != nav_air::AirStatus::COMPLETE) {
		return result;
	}
	const nav_air::AirRoute &route = search.route();
	Flyer &flyer = flyers[p_id];
	flyer.profile = dash ? nav_air::AirFlightProfile::rainbow_dash(body_scale) : nav_air::AirFlightProfile::pegasus(body_scale);
	nav_air::AirPrepareOptions prepare;
	prepare.cruise_speed = float(number(p_options, "cruise_speed", 0.0));
	nav_air::AirFollowCorridor corridor;
	const nav_air::AirPrepareStatus prepared = nav_air::air_prepare_corridor(
			*space, route.points, flyer.profile, nav_air::AirTerminal::HOVER, 0.0f, prepare, corridor);
	result["prepare_status"] = String(nav_air::air_prepare_status_name(prepared));
	if (prepared != nav_air::AirPrepareStatus::OK && prepared != nav_air::AirPrepareStatus::NO_GLIDE_VOLUME) {
		flyers.erase(p_id);
		return result;
	}
	flyer.follower.set_profile(flyer.profile);
	flyer.follower.clear();
	if (!flyer.follower.begin(corridor, ++flyer.route)) {
		flyers.erase(p_id);
		result["prepare_status"] = "follower refused the corridor";
		return result;
	}
	PackedVector3Array points;
	for (const nav_air::Vec3 &p : corridor.points()) {
		points.push_back(root(p));
	}
	result["points"] = points;
	result["length"] = corridor.length();
	result["prepared"] = true;
	return result;
}

Dictionary PonyAirNavigation::step(int64_t p_id, const Vector3 &p_root, const Vector3 &p_velocity, double p_yaw,
		double p_delta, double p_requested_speed) {
	Dictionary result;
	auto found = flyers.find(p_id);
	if (found == flyers.end() || !loaded || !finite(p_root) || !finite(p_velocity) || !std::isfinite(p_yaw)) {
		result["mode"] = int64_t(nav_air::AirCommandMode::FAILED);
		result["mode_name"] = "no follower";
		result["velocity"] = Vector3();
		return result;
	}
	Flyer &flyer = found->second;
	nav_air::AirFollowInput input;
	input.position = centre(p_root);
	input.velocity = nav_air::Vec3{ float(p_velocity.x), float(p_velocity.y), float(p_velocity.z) };
	input.yaw = float(p_yaw);
	input.dt = float(std::max(1.0e-4, std::min(0.1, p_delta)));
	input.requested_speed = float(p_requested_speed);
	const nav_air::AirFollowCommand command = flyer.follower.step(*space, input);
	result["mode"] = int64_t(command.mode);
	result["mode_name"] = String(nav_air::air_command_mode_name(command.mode));
	result["velocity"] = gd(command.velocity);
	result["yaw"] = command.yaw;
	result["pitch"] = command.pitch;
	result["bank"] = command.bank;
	result["remaining"] = command.remaining;
	result["progress"] = command.progress;
	result["reason"] = String(nav_air::air_reason_name(command.reason));
	result["limit"] = String(nav_air::air_speed_limit_name(command.limit));
	return result;
}

void PonyAirNavigation::clear(int64_t p_id) {
	flyers.erase(p_id);
}

bool PonyAirNavigation::following(int64_t p_id) const {
	auto found = flyers.find(p_id);
	return found != flyers.end() && found->second.follower.active();
}
