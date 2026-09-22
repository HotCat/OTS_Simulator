extends SceneTree

const SOURCE_SCENE := "res://demos/my_manual_rig_pose.tscn"
const TARGET_SCENE := "res://demos/coffebar_female_walk_scene.tscn"


func _init() -> void:
	call_deferred("_verify")


func _verify() -> void:
	var source_resource := load(SOURCE_SCENE) as PackedScene
	var target_resource := load(TARGET_SCENE) as PackedScene
	_assert(source_resource != null, "source PackedScene loads")
	_assert(target_resource != null, "target PackedScene loads")
	if source_resource == null or target_resource == null:
		quit(1)
		return

	var source := source_resource.instantiate()
	var target := target_resource.instantiate()
	for path in [
		"PoseControls",
		"IK_character",
		"IK_character/Skeleton3D",
		"FemaleWalkTrajectory",
		"FemaleWalkAnimationPlayer",
		"FemaleWalkController",
		"CoffeeBarStreet",
		"StreetWorldEnvironment",
		"JeepRoadsideFillOmniLight3D",
		"JeepRearQuarterRimOmniLight3D",
		"StreetCamera3D",
	]:
		_assert(target.get_node_or_null(NodePath(path)) != null, "target contains %s" % path)

	var source_character := source.get_node("IK_character") as Node3D
	var target_character := target.get_node("IK_character") as Node3D
	_assert(source_character.transform.is_equal_approx(target_character.transform), "IK_character transform preserved")
	_assert(source_character.get_script() == target_character.get_script(), "IK_character controller script preserved")
	_assert((source_character.get("saved_fk_pose") as Array).size() == (target_character.get("saved_fk_pose") as Array).size(), "saved FK pose array preserved")

	var source_skeleton := source.get_node("IK_character/Skeleton3D") as Skeleton3D
	var target_skeleton := target.get_node("IK_character/Skeleton3D") as Skeleton3D
	_assert(source_skeleton.get_bone_count() == 56, "source is the expected 56-bone skeleton")
	_assert(target_skeleton.get_bone_count() == source_skeleton.get_bone_count(), "56-bone skeleton copied")
	var bone_mismatches := 0
	for bone_index in source_skeleton.get_bone_count():
		if not source_skeleton.get_bone_pose(bone_index).is_equal_approx(target_skeleton.get_bone_pose(bone_index)):
			bone_mismatches += 1
	_assert(bone_mismatches == 0, "all local bone pose overrides preserved")

	for modifier_name in ["pelvis_control", "center_back_ik", "neck_ik", "r_leg", "l_leg", "r_arm", "l_arm", "head_look_at", "r_hand_copy_trans"]:
		var source_modifier := source_skeleton.get_node_or_null(modifier_name)
		var target_modifier := target_skeleton.get_node_or_null(modifier_name)
		_assert(source_modifier != null and target_modifier != null, "IK modifier copied: %s" % modifier_name)
		if source_modifier != null and target_modifier != null:
			_assert(source_modifier.get("active") == target_modifier.get("active"), "IK active state preserved: %s" % modifier_name)

	var source_trajectory := source.get_node("FemaleWalkTrajectory") as Node3D
	var target_trajectory := target.get_node("FemaleWalkTrajectory") as Node3D
	_assert(source_trajectory.transform.is_equal_approx(target_trajectory.transform), "trajectory root transform preserved")
	_assert(source_trajectory.get_child_count() == target_trajectory.get_child_count(), "trajectory waypoint count preserved")
	for child_index in source_trajectory.get_child_count():
		var source_waypoint := source_trajectory.get_child(child_index) as Node3D
		var target_waypoint := target_trajectory.get_child(child_index) as Node3D
		_assert(source_waypoint.transform.is_equal_approx(target_waypoint.transform), "waypoint transform preserved: %s" % source_waypoint.name)

	var source_player := source.get_node("FemaleWalkAnimationPlayer") as AnimationPlayer
	var target_player := target.get_node("FemaleWalkAnimationPlayer") as AnimationPlayer
	_assert(source_player.get_animation_library_list() == target_player.get_animation_library_list(), "animation libraries preserved")

	var source_controller := source.get_node("FemaleWalkController")
	var target_controller := target.get_node("FemaleWalkController")
	_assert(source_controller.get_script() == target_controller.get_script(), "walk controller script preserved")
	for property_name in ["thigh_closure_degrees", "heel_contact_lead_frames", "captured_pace_scale", "walk_speed_mps", "character_height_offset_m", "stop_at_path_end", "local_forward"]:
		_assert(source_controller.get(property_name) == target_controller.get(property_name), "walk tuning preserved: %s" % property_name)

	var street := target.get_node("CoffeeBarStreet")
	_assert(street.get_meta("contains_custom_two_door_jeep", false), "street contains custom two-door Jeep")
	_assert(street.get_meta("bicycle_free_frontage", false), "street marked bicycle-free")

	var roadside_fill := target.get_node("JeepRoadsideFillOmniLight3D") as OmniLight3D
	var rear_rim := target.get_node("JeepRearQuarterRimOmniLight3D") as OmniLight3D
	_assert(roadside_fill.shadow_enabled, "road-side Jeep fill casts grounding shadows")
	_assert(roadside_fill.position.z > 0.0, "road-side Jeep fill is opposite the storefront")
	_assert(rear_rim.light_energy < roadside_fill.light_energy, "rear-quarter rim remains subordinate to the main fill")

	print("VERIFY_COMPLETE failures=", _failures)
	source.free()
	target.free()
	quit(0 if _failures == 0 else 1)


var _failures := 0


func _assert(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: %s" % label)
