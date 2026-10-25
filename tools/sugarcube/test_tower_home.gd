extends SceneTree
## Isolated home ownership and transformed physical-bed contract; no save APIs.
const HOME := preload("res://world/buildings/sugarcube/tower_home.gd")
var failures := 0
var checks := 0

func _initialize() -> void: run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL ", message)

func run() -> void:
	var house := Node3D.new()
	house.position = Vector3(30, -4, 17)
	house.rotation.y = .7
	house.scale = Vector3.ONE * 14.0
	root.add_child(house)
	var room := Node3D.new()
	room.name = "TowerRoom"
	room.scale = Vector3.ONE / 14.0
	house.add_child(room)
	var bed := Node3D.new()
	bed.name = "PinkieBed"
	bed.position = Vector3(-.2, 11.6, -.2)
	bed.rotation.y = .2
	bed.scale.x = .7
	bed.set_meta("side_local", Vector3(0, 0, 1.7))
	bed.set_meta("mattress_top", .65)
	bed.set_meta("bed_size", Vector3(2.0, 1.1, 2.1))
	room.add_child(bed)
	var home := HOME.new()
	home.scale = Vector3.ONE / 14.0
	home.floor_y = .9
	home.stair_path.assign([Vector3(2, .9, 1), Vector3(2, 3.3, -2), Vector3(0, 7, -2), Vector3(-.2, 11.6, 1.5)])
	house.add_child(home)
	check(home.is_in_group("house_interiors"), "home participates in normal indoor APIs")
	check(home.ensure_bed("pinkie_pie") == bed and bed.get_meta("house") == home, "actual authored bed linked to home")
	check(not home.bed_shared("pinkie_pie"), "single bed has no second sleeper lane")
	var saved := {"pinkie_pie": "house:existing", "other": "house:unrelated"}
	var before := saved.duplicate(true)
	check(not home.configure_owner(saved), "saved home not displaced")
	check(saved == before and str(home.get_meta("reserved_for")) == "", "existing save unchanged and tower unavailable to random assignments")
	check(home.configure_owner({}) and str(home.get_meta("reserved_for")) == "pinkie_pie", "new world reserves tower for Pinkie")
	check(home.configure_owner({"pinkie_pie": home.place_id()}), "saved tower assignment retained")
	var side := home.bed_side("pinkie_pie")
	check(side.is_equal_approx(bed.to_global(Vector3(0, 0, 1.7))), "bed approach follows rotated building and scaled bed")
	var rest := home.bed_rest("pinkie_pie")
	check(rest.origin.is_equal_approx(bed.to_global(Vector3(0, .65, .15))), "rest lies on actual transformed mattress")
	check(rest.basis.z.normalized().dot(bed.global_basis.z.normalized()) > .999, "head direction follows bed")
	check(home.on_mattress(rest.origin), "actual rest recognized as on mattress")
	bed.set_meta("rest_local", Vector3(.285 / bed.scale.x, .65, -.20 / bed.scale.z))
	var centered := home.bed_rest("pinkie_pie")
	check(centered.origin.is_equal_approx(bed.to_global(bed.get_meta("rest_local"))), "common sleep anchor follows transformed bed")
	check(home.on_mattress(centered.origin), "common anchor remains on mattress")
	check(not home.on_mattress(side), "approach floor is not mattress")
	check(not home.on_mattress(bed.to_global(Vector3(2, .65, 0))), "outside narrowed bed rejected")
	check(not home.on_mattress(bed.to_global(Vector3(0, 1.5, 0))), "above mattress rejected")
	check(home.contains(home.to_global(Vector3(-.2, 11.6, 1))), "bedroom floor belongs to tower")
	check(not home.contains(home.to_global(Vector3(4, 11.6, 1))), "outside tower rejected")
	check(not home.contains(home.to_global(Vector3(0, .9, 0))), "shop floor does not become bedroom")
	for i in home.stair_path.size() - 1:
		var up := home.local_waypoint(home.to_global(home.stair_path[i]), home.to_global(home.stair_path[-1]))
		check(up.is_equal_approx(home.to_global(home.stair_path[i + 1])), "ascent retains connecting leg " + str(i))
		var down := home.local_waypoint(home.to_global(home.stair_path[i + 1]), home.to_global(home.stair_path[0]))
		check(down.is_equal_approx(home.to_global(home.stair_path[i])), "descent retains connecting leg " + str(i))
	var middle: Vector3 = home.stair_path[1].lerp(home.stair_path[2], .5)
	var above: Vector3 = home.stair_path[2].lerp(home.stair_path[3], .5)
	check(home.local_waypoint(home.to_global(above), home.to_global(middle)).is_equal_approx(home.to_global(home.stair_path[2])), "follow target midway down stairs descends to connecting point")
	check(home.local_waypoint(home.to_global(home.stair_path[2]), home.to_global(middle)).is_equal_approx(home.to_global(middle)), "mid-stair target reached without oscillating between endpoints")
	# Actual authored counter detour must survive the stair-to-commercial handoff.
	home.stair_path.assign([Vector3(.12,.9,1.6), Vector3(.12,.9,3.4), Vector3(4.45,.9,3.4), Vector3(4.45,.9,-2.35), Vector3(-4.7,.9,-2.35), Vector3(-1.3,3.27,-2.35)])
	home.ground_path_count = 5
	for i in range(4, 1, -1):
		var result: Vector3 = home.ground_waypoint(home.to_global(home.stair_path[i]), home.to_global(home.stair_path[0]))
		check(result.is_equal_approx(home.to_global(home.stair_path[i-1])), "ground descent retains counter detour " + str(i))
	for i in range(1, 4):
		var result: Vector3 = home.ground_waypoint(home.to_global(home.stair_path[i]), home.to_global(home.stair_path[4]))
		check(result.is_equal_approx(home.to_global(home.stair_path[i+1])), "ground ascent retains counter detour " + str(i))
	check(not home.ground_waypoint(home.to_global(Vector3(.2,.9,1)),home.to_global(Vector3(-1,.9,.8))).is_finite(), "ordinary entrance-side shop travel stays with bakery")
	house.queue_free()
	await process_frame
	print("TOWER_HOME_RESULT checks=", checks, " failures=", failures)
	if failures == 0: print("TOWER_HOME_PASS")
	quit(0 if failures == 0 else 1)
