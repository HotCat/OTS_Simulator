extends SceneTree

const LIBRARY_PATH := "res://animations/ots_carry_walk_cycle.tres"
const ANIMATION_NAME := &"ots_carry_walk_cycle"
const SCENE_PATH := "res://demos/ots_carry_clay_proxy.tscn"


func _initialize() -> void:
	var library := load(LIBRARY_PATH) as AnimationLibrary
	_assert(library != null and library.has_animation(ANIMATION_NAME), "cycle library loads")
	var animation := library.get_animation(ANIMATION_NAME)
	_assert(animation != null, "cycle animation exists")
	_assert(animation.loop_mode == Animation.LOOP_LINEAR, "cycle loops linearly")
	_assert(is_equal_approx(float(animation.get_meta("ots_source_start_seconds", -1.0)), 1.24), "cycle starts at source 1.24 s")
	_assert(is_equal_approx(float(animation.get_meta("ots_requested_end_seconds", -1.0)), 5.875), "cycle searches through requested source end 5.875 s")
	_assert(float(animation.get_meta("ots_source_end_seconds", 0.0)) > 5.5, "cycle keeps the last usable same-phase stride")
	_assert(float(animation.get_meta("ots_phase_seam_score", INF)) < 0.25, "phase-aligned seam score is acceptable")
	_assert(str(animation.get_meta("ots_heading_mode", "")).contains("detrended"), "captured heading drift is removed")
	for track in animation.get_track_count():
		var path := str(animation.track_get_path(track))
		_assert(path.contains("MaleCarrier/Skeleton3D"), "track targets male only: %s" % path)
		_assert(not path.contains("IK_character"), "track never targets female: %s" % path)
		_assert(animation.track_get_type(track) == Animation.TYPE_ROTATION_3D, "cycle contains rotation tracks only")
		var first := animation.track_get_key_value(track, 0) as Quaternion
		var last := animation.track_get_key_value(track, animation.track_get_key_count(track) - 1) as Quaternion
		_assert(first.is_equal_approx(last), "stored track seam closes exactly: %s" % path)

	var packed := load(SCENE_PATH) as PackedScene
	_assert(packed != null, "OTS scene loads")
	var root := packed.instantiate() as Node3D
	get_root().add_child(root)
	await process_frame
	var player := root.get_node_or_null("OTSCarryAnimationPlayer") as AnimationPlayer
	_assert(player != null and player.has_animation(ANIMATION_NAME), "OTS scene uses cycle library")
	var walk_plane := root.get_node_or_null("CarrierWalkPlane") as Node3D
	_assert(walk_plane != null, "walk-plane selector exists")
	var trajectory := root.get_node_or_null("CarrierTrajectory") as Node3D
	_assert(trajectory != null, "carrier trajectory exists")
	var waypoint_count := 0
	for child in trajectory.get_children():
		if child is Marker3D and child.has_meta("trajectory_waypoint"):
			waypoint_count += 1
	_assert(waypoint_count == 8, "carrier trajectory has eight editable waypoints")
	var carrier := root.get_node_or_null("ManualCarryBlock/MaleCarrier") as Node3D
	player.play(ANIMATION_NAME)
	player.advance(0.0)
	root.call("restart_carrier_trajectory")
	var trajectory_start := carrier.global_position
	root.call("_apply_carrier_trajectory", 1.0)
	var carrier_advance := carrier.global_position.distance_to(trajectory_start)
	_assert(carrier_advance > 0.5, "carrier advances along planned trajectory")
	var first_waypoint := trajectory.get_node("Waypoint_00") as Marker3D
	var second_waypoint := trajectory.get_node("Waypoint_01") as Marker3D
	var plane_normal := walk_plane.global_basis.y.normalized()
	var planned_forward := (second_waypoint.global_position - first_waypoint.global_position).slide(plane_normal).normalized()
	var carrier_forward := (carrier.global_basis * Vector3(0.0, 0.0, 1.0)).normalized()
	_assert(carrier_forward.dot(planned_forward) > 0.999, "male local +Z faces the travel direction")
	var plane_distance := (carrier.global_position - walk_plane.global_position).dot(plane_normal)
	var expected_height := float(root.get("carrier_height_above_plane"))
	_assert(absf(plane_distance - expected_height) < 0.001, "carrier remains on selected walk plane")
	var male_skeleton := root.get_node("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	var frame_delta := 1.0 / 24.0
	var test_progress := 2.0
	for foot_name in [&"LeftFoot", &"RightFoot"]:
		var before_end := _foot_world_at(root, player, carrier, male_skeleton, foot_name, animation.length - frame_delta, test_progress - carrier_walk_distance(root, frame_delta))
		var at_end := _foot_world_at(root, player, carrier, male_skeleton, foot_name, animation.length, test_progress)
		var at_start := _foot_world_at(root, player, carrier, male_skeleton, foot_name, 0.0, test_progress)
		var after_start := _foot_world_at(root, player, carrier, male_skeleton, foot_name, frame_delta, test_progress + carrier_walk_distance(root, frame_delta))
		var incoming_velocity := (at_end - before_end) / frame_delta
		var outgoing_velocity := (after_start - at_start) / frame_delta
		_assert(incoming_velocity.distance_to(outgoing_velocity) < 0.1, "%s velocity remains continuous across cycle seam" % foot_name)
	print("OTS_WALK_CYCLE_VERIFY_OK length=%.6f tracks=%d waypoints=%d" % [
		animation.length, animation.get_track_count(), waypoint_count,
	])
	root.free()
	quit(0)


func carrier_walk_distance(root: Node, seconds: float) -> float:
	return float(root.get("carrier_walk_speed_mps")) * seconds


func _foot_world_at(root: Node, player: AnimationPlayer, carrier: Node3D, skeleton: Skeleton3D,
		bone_name: StringName, animation_time: float, progress: float) -> Vector3:
	player.seek(animation_time, true)
	root.call("_place_carrier_on_trajectory", carrier, progress)
	skeleton.force_update_all_bone_transforms()
	var bone_index := skeleton.find_bone(bone_name)
	return (skeleton.global_transform * skeleton.get_bone_global_pose(bone_index)).origin


func _assert(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("OTS walk-cycle verification failed: %s" % message)
	quit(1)
