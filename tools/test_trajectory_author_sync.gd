extends SceneTree

const SCENE_PATH := "res://demos/ots_carry_clay_proxy.tscn"
const JSON_PATH := "res://trajectories/female_walk_bezier.json"
const PLUGIN_PATH := "res://addons/trajectory_author/plugin.gd"


func _initialize() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	var scene_root := packed.instantiate() as Node3D
	var trajectory := scene_root.get_node("CarrierTrajectory") as Node3D
	var file := FileAccess.open(JSON_PATH, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	var values := (parsed as Dictionary).get("waypoints", []) as Array
	var plugin_script := load(PLUGIN_PATH) as Script
	var plugin := plugin_script.new() as EditorPlugin
	plugin.call("_sync_waypoints_from_values", trajectory, values, scene_root)
	var markers: Array[Marker3D] = []
	for child in trajectory.get_children():
		if child is Marker3D and child.has_meta("trajectory_waypoint"):
			markers.append(child as Marker3D)
	markers.sort_custom(func(a: Marker3D, b: Marker3D) -> bool: return a.name.naturalnocasecmp_to(b.name) < 0)
	if markers.size() != values.size():
		push_error("Trajectory sync count mismatch: scene=%d json=%d" % [markers.size(), values.size()])
		quit(1)
		return
	for index in markers.size():
		var expected := Vector3(
			float((values[index] as Dictionary).position[0]),
			float((values[index] as Dictionary).position[1]),
			float((values[index] as Dictionary).position[2])
		)
		if not markers[index].position.is_equal_approx(expected):
			push_error("Trajectory sync position mismatch at %d" % index)
			quit(1)
			return
	print("TRAJECTORY_SYNC_TEST_OK json=%d scene_after_load=%d" % [values.size(), markers.size()])
	plugin.free()
	scene_root.free()
	quit(0)
