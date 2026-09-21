extends SceneTree

## Headless integration check for the editor/runtime-shared walk controller.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed := load("res://demos/my_manual_rig_pose.tscn") as PackedScene
	if packed == null:
		_fail("could not load walk scene")
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var character := scene.get_node_or_null("IK_character") as Node3D
	var controller := scene.get_node_or_null("FemaleWalkController")
	var player := scene.get_node_or_null("FemaleWalkAnimationPlayer") as AnimationPlayer
	if character == null or controller == null or player == null:
		_fail("walk scene is missing the character, controller, or AnimationPlayer")
		return
	if int(controller.get("travel_mode")) != 0:
		_fail("foot-contact synchronization is not the default travel mode")
		return
	if absf(float(controller.call("_path_length")) - 24.0) > 0.001:
		_fail("the authored long trajectory is not 24 metres")
		return
	var start := character.global_position
	controller.call("_process", 0.5)
	var displacement := character.global_position.distance_to(start)
	var normal_animation := player.get_animation(&"female_walk_cycle")
	var expected_displacement := float(controller.call(
		"_travel_distance_for_time", 0.5, normal_animation
	))
	if absf(displacement - expected_displacement) > 0.001:
		_fail("captured pace advanced %.6f m; expected %.6f m" % [
			displacement, expected_displacement,
		])
		return
	if displacement > 0.5:
		_fail("foot-contact travel incorrectly inherited Captured Pace Scale")
		return
	if player.assigned_animation != &"female_walk_cycle":
		_fail("walk controller did not assign the normal human gait")
		return
	# Ask the controller for the same phase transform used by the preview; this
	# keeps the regression independent of cache FPS metadata.
	var expected_animation_time := fposmod(
		controller.call("_phase_shifted_time", 0.5, normal_animation),
		normal_animation.length
	)
	if absf(player.current_animation_position - expected_animation_time) > 0.01:
		_fail("walk controller did not sample the gait at 0.5 seconds")
		return
	# Fixed-step capture must advance exactly the requested gait interval,
	# independent of how long an off-screen avatar render takes. Reproduce the
	# Emacs ordering where restart arrives after recording has already begun.
	var fixed_state := controller.call("editor_capture_begin_fixed_step") as Dictionary
	controller.call("_restart_preview")
	controller.call("_process", 2.0)
	if absf(float(controller.get("preview_time_seconds"))) > 0.000001:
		_fail("late restart re-enabled wall-clock advancement during fixed capture")
		return
	var fixed_start_time := float(controller.get("preview_time_seconds"))
	controller.call("editor_capture_step_fixed", 0.125)
	var fixed_elapsed := float(controller.get("preview_time_seconds")) - fixed_start_time
	if absf(fixed_elapsed - 0.125) > 0.000001:
		_fail("fixed-step capture advanced %.6f seconds; expected 0.125" % fixed_elapsed)
	controller.call("editor_capture_end_fixed_step", bool(fixed_state.get("was_playing", false)))
	var first := scene.get_node("FemaleWalkTrajectory/Waypoint_00") as Marker3D
	# A positive heel lead advances both pose and periodic contact travel, but
	# re-zeroes the phase at restart so the character does not jump at t=0.
	controller.set("heel_contact_lead_frames", 3.0)
	controller.call("_restart_preview")
	var lead_start := character.global_position
	if lead_start.distance_to(first.global_position + Vector3.UP * float(controller.get("character_height_offset_m"))) > 0.001:
		_fail("heel contact lead introduced a restart position jump")
		return
	controller.call("_process", 0.5)
	var lead_displacement := character.global_position.distance_to(lead_start)
	var lead_expected := float(controller.call(
		"_travel_distance_for_time", 0.5, normal_animation
	))
	if absf(lead_displacement - lead_expected) > 0.001:
		_fail("heel contact lead desynchronized periodic travel")
		return
	controller.set("heel_contact_lead_frames", 0.0)
	controller.call("_restart_preview")
	var skeleton := scene.get_node("IK_character/Skeleton3D") as Skeleton3D
	var left_knee_index := skeleton.find_bone("LeftLowerLeg")
	var right_knee_index := skeleton.find_bone("RightLowerLeg")
	var left_foot_index := skeleton.find_bone("LeftFoot")
	controller.set("thigh_closure_degrees", 0.0)
	controller.call("_apply_preview_time", 0.5)
	var open_knee_separation := skeleton.get_bone_global_pose(left_knee_index).origin.distance_to(
		skeleton.get_bone_global_pose(right_knee_index).origin
	)
	var planted_foot_before := skeleton.get_bone_global_pose(left_foot_index).origin
	controller.set("thigh_closure_degrees", 4.0)
	controller.call("_apply_preview_time", 0.5)
	var closed_knee_separation := skeleton.get_bone_global_pose(left_knee_index).origin.distance_to(
		skeleton.get_bone_global_pose(right_knee_index).origin
	)
	var planted_foot_after := skeleton.get_bone_global_pose(left_foot_index).origin
	if closed_knee_separation >= open_knee_separation - 0.0001:
		_fail("thigh closure did not narrow the swing-phase knee separation")
		return
	if planted_foot_before.distance_to(planted_foot_after) > 0.00001:
		_fail("thigh closure moved a planted foot and could reintroduce sliding")
		return
	var second := scene.get_node("FemaleWalkTrajectory/Waypoint_01") as Marker3D
	var direction := (second.global_position - first.global_position).normalized()
	var active_forward := controller.call("_active_local_forward") as Vector3
	var facing := (character.global_basis * active_forward).normalized()
	if facing.dot(direction) < 0.999:
		_fail("character does not face the active straight trajectory segment")
		return
	controller.set("travel_mode", 2)
	controller.call("_restart_preview")
	var constant_start := character.global_position
	controller.call("_process", 0.5)
	var constant_distance := character.global_position.distance_to(constant_start)
	if absf(constant_distance - float(controller.get("walk_speed_mps")) * 0.5) > 0.001:
		_fail("constant-speed travel mode did not use walk_speed_mps")
		return
	controller.set("travel_mode", 3)
	controller.call("_restart_preview")
	var in_place_start := character.global_position
	controller.call("_process", 0.5)
	if character.global_position.distance_to(in_place_start) > 0.000001:
		_fail("in-place travel mode moved the character")
		return
	controller.set("travel_mode", 0)
	controller.call("_restart_preview")
	controller.call("_process", 0.5)
	var preserved_height := float(controller.get("character_height_offset_m"))
	controller.set("walk_style", 1)
	controller.call("_apply_preview_time", 0.25)
	if player.assigned_animation != &"leg_wounded/female_walk_leg_wounded":
		_fail("walk controller did not switch to the preserved leg-wounded gait")
		return
	if absf(float(controller.get("character_height_offset_m")) - preserved_height) > 0.000001:
		_fail("switching gait style changed the user's height calibration")
		return
	controller.set("walk_style", 2)
	controller.call("_apply_preview_time", 0.25)
	if player.assigned_animation != &"wounded/female_walk_wounded_terminator":
		_fail("walk controller did not switch to the preserved Terminator gait")
		return
	controller.set("walk_style", 0)
	controller.call("_apply_preview_time", 0.5)
	controller.set("travel_mode", 2)
	controller.call("_process", 100.0)
	var last := scene.get_node("FemaleWalkTrajectory/Waypoint_02") as Marker3D
	var height_offset := float(controller.get("character_height_offset_m"))
	if character.global_position.distance_to(last.global_position + Vector3.UP * height_offset) > 0.001:
		_fail("walk controller did not stop at the final waypoint")
		return
	controller.call("_restart_preview")
	if character.global_position.distance_to(first.global_position + Vector3.UP * height_offset) > 0.001:
		_fail("restart did not return the character to the first waypoint")
		return
	print("Walk controller regression passed: moved %.4f m in 0.5 s" % displacement)
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
