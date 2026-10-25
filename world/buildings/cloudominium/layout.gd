extends RefCounted
## Rainbow Dash's Cloudominium interior: the one shared room frame (dev 2026-09-28).
## References: art/references/cloudominium-2026-09-28/ (sources.json).
##
## Frame: origin on the tower axis at the hall floor, which is the cloud top at the door; +Y up;
## the front door is on +Z. Metres, unscaled: the shell cancels any inherited scale.
## shell.gd measures the real tower and returns this dictionary with its measured door and
## windows filled in; every other part reads that returned dictionary, never these constants.
##
## Source tower, prefab-local (tools/cloudominium/probe_shell.gd, captures/cloudominium/
## source-shell.json, 2026-09-28): axis (x -5.723, z -1.282); lower tier wall R 4.03 from the
## cloud (y 5.5) to its cap at y 12.46; second tier R 3.60 to its top slab at y 17.55; colonnade
## and dome above. The door leaf is the plane x -1.5385 (z -1.965..-0.309, arch apex y 9.06);
## the cloud rises to y 6.26..6.43 at it, so the hall floor is prefab y 6.36. The hall fills the
## lower tier (6 m tall, a gallery-high round hall); the bedroom fills the narrower second tier.
## Every source window lies wholly inside one of the two, so no floor crosses a window.

## Default room: the measured values; shell.gd replaces "windows" and the door with its own
## runtime measurement of the same mesh.
static func defaults() -> Dictionary:
	return {
		"radius": 3.9,            # hall lining radius (source wall 4.03)
		"upper_radius": 3.44,     # bedroom lining radius (second tier wall 3.60)
		"wall": 0.13,             # gap from the lining to the source wall
		"ground_y": 0.0,
		"upper_y": 6.25,          # upper floor top (bedroom), prefab y 12.61
		"ceiling_y": 11.05,       # upper ceiling, prefab y 17.41
		"ground_ceiling_y": 6.0,  # underside of the upper floor: the hall ceiling
		"door_position": Vector3(-0.145, 0, 4.1845),  # threshold centre on the leaf plane
		"door_width": 1.6,        # clear width between the reveals
		"door_height": 2.67,      # clear height at the arch apex; the arch springs at 1.5
		"door_inside": Vector3(-0.145, 0, 2.2),     # past the inward swing of the leaf
		"door_approach": Vector3(-0.145, -0.71, 6.12),  # outside, on the cloud
		# Curved stair inside the hall wall, ground -> upper floor, angles increasing (it passes
		# over the door 5 m up). Angles in degrees about +Y, 0 = +Z (door), 90 = +X; the end
		# may exceed 360. The outer edge stays inside the bedroom wall so it arrives indoors.
		"stair": {"start_angle": 150.0, "end_angle": 400.0, "inner_radius": 2.25, "outer_radius": 3.35},
		# Opening in the upper floor where the stair is above 3.6 m (2.4 m headroom), to its top.
		"stair_hole": {"start_angle": 295.0, "end_angle": 408.0, "inner_radius": 2.1, "outer_radius": 3.44},
		# The source's own arched windows: angle where the opening's centre line meets that
		# level's lining ("upper" windows sit on upper_radius), centre height, full width and
		# height of the pane outline. Their arches are segmental, a little flatter than "round".
		"windows": [
			{"angle": 85.9, "y": 1.22, "width": 0.77, "height": 1.49, "level": "ground"},
			{"angle": -164.1, "y": 2.35, "width": 0.79, "height": 1.49, "level": "ground"},
			{"angle": -34.6, "y": 2.53, "width": 0.78, "height": 1.49, "level": "ground"},
			{"angle": 156.5, "y": 2.56, "width": 1.46, "height": 2.77, "level": "ground"},
			{"angle": -93.6, "y": 2.74, "width": 1.42, "height": 2.77, "level": "ground"},
			{"angle": 63.1, "y": 4.24, "width": 0.96, "height": 1.86, "level": "ground"},
			{"angle": 101.6, "y": 4.54, "width": 0.96, "height": 1.86, "level": "ground"},
			{"angle": -129.0, "y": 4.54, "width": 0.97, "height": 1.86, "level": "ground"},
			{"angle": 0.9, "y": 4.72, "width": 0.98, "height": 1.86, "level": "ground"},
			{"angle": 108.4, "y": 8.15, "width": 0.77, "height": 1.49, "level": "upper"},
			{"angle": 82.0, "y": 8.32, "width": 1.19, "height": 2.31, "level": "upper"},
			{"angle": -94.2, "y": 8.32, "width": 1.19, "height": 2.31, "level": "upper"},
			{"angle": -180.0, "y": 8.32, "width": 1.22, "height": 2.31, "level": "upper"},
			{"angle": -0.1, "y": 8.32, "width": 1.22, "height": 2.31, "level": "upper"},
			{"angle": -69.1, "y": 8.87, "width": 0.77, "height": 1.49, "level": "upper"},
			{"angle": 150.4, "y": 9.35, "width": 0.78, "height": 1.49, "level": "upper"},
			{"angle": -29.8, "y": 9.65, "width": 0.78, "height": 1.49, "level": "upper"},
		],
		# Zones furniture fills (angle ranges, level). Keep the door path, the door's inward swing
		# (x -0.97..0.68, z 2.5..4.2) and the stair's low end (150..240 at 2.25..3.35 m) clear.
		"zones": {
			"entrance_statue": {"level": "ground", "angle": 180.0, "distance": 1.6},
			"lounge": {"level": "ground", "from": 35.0, "to": 125.0},
			"music_corner": {"level": "ground", "from": -110.0, "to": -35.0},
			"bedroom": {"level": "upper", "from": 70.0, "to": 200.0},
			"trophy_wall": {"level": "upper", "from": -150.0, "to": -70.0},
		},
	}
