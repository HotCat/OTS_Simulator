extends SceneTree

const SCENE := "res://demos/ikea_sample_room_female_compare.tscn"

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var packed := load(SCENE) as PackedScene
	if packed == null:
		_fail("IKEA scene did not load")
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var servo := scene.get_node("CPRServoController")
	var left_target := scene.get_node("CPRServoAnchors/LeftPalmTarget") as Marker3D
	var right_target := scene.get_node("CPRServoAnchors/RightPalmTarget") as Marker3D
	var left_pole := scene.get_node("CPRServoAnchors/LeftElbowPole") as Marker3D
	var right_pole := scene.get_node("CPRServoAnchors/RightElbowPole") as Marker3D
	var left_ik := scene.get_node("MaleCarrier/Character/Skeleton3D/cpr_left_arm_ik") as TwoBoneIK3D
	var male := scene.get_node("MaleCarrier/Character/Skeleton3D") as Skeleton3D
	var female := scene.get_node("Female190/IK_character/Skeleton3D") as Skeleton3D
	for bone_name in ["Hips", "Spine", "Chest", "UpperChest", "CPR_UpperAbdomen", "CPR_LowerAbdomen", "CPR_LeftBreastLower", "CPR_RightBreastLower"]:
		var bone_index := female.find_bone(bone_name)
		print("CPR_GROUND_SAMPLE ", bone_name, " y=", female.to_global(female.get_bone_global_pose(bone_index).origin).y)
	var initial := scene.call("editor_servo_status") as Dictionary
	if not bool(initial.get("ok", false)) or bool(initial.get("ik_enabled", true)) or str(initial.get("editor_mode")) != "source_pose":
		_fail("initial status does not report source-pose mode with IK off")
		return
	# Quick FK Restore IK can leave this modifier active before pose capture.
	# Capture must explicitly return to FK before sampling the male wrists.
	left_ik.active = true
	var captured := scene.call("editor_servo_capture_current_male_pose") as Dictionary
	if not bool(captured.get("ok", false)) or left_ik.active:
		_fail("source male pose capture failed to disable stale IK")
		return
	var enabled := scene.call("editor_servo_enable_marker_edit") as Dictionary
	if not bool(enabled.get("ik_enabled", false)) or str(enabled.get("editor_mode")) != "marker_edit" or not bool(enabled.get("markers_visible", false)) or bool(enabled.get("playing", true)) or not left_ik.active or not left_target.visible or not right_target.visible or not left_pole.visible or not right_pole.visible:
		_fail("marker edit did not enable visible paused IK")
		return
	var edited_position := left_target.global_position + Vector3(0.01, 0.0, 0.0)
	left_target.global_position = edited_position
	var stored := scene.call("editor_servo_capture_markers") as Dictionary
	if not bool(stored.get("ok", false)):
		_fail("edited palm marker was not captured")
		return
	var captured_left_hand: Vector3 = stored.get("zero_left_hand", Vector3.INF)
	var captured_right_hand: Vector3 = stored.get("zero_right_hand", Vector3.INF)
	if captured_left_hand.is_equal_approx(Vector3.INF) or captured_right_hand.is_equal_approx(Vector3.INF):
		_fail("marker capture did not save the evaluated hands as the zero pose")
		return
	var started := scene.call("editor_servo_play") as Dictionary
	if not bool(started.get("ok", false)) or not bool(started.get("playing", false)):
		_fail("servo did not start from the captured marker pose")
		return
	var zero_status := scene.call("editor_servo_status") as Dictionary
	if float(zero_status.get("zero_left_hand_error_m", INF)) > 0.001 or float(zero_status.get("zero_right_hand_error_m", INF)) > 0.001:
		_fail("starting CPR moved the hands away from the captured zero pose")
		return
	servo.call("seek", 0.0)
	if left_target.global_position.distance_to(edited_position) > 0.001:
		_fail("captured marker moved after servo seek")
		return
	var disabled := scene.call("editor_servo_disable_marker_edit") as Dictionary
	if bool(disabled.get("ik_enabled", true)) or str(disabled.get("editor_mode")) != "source_pose" or left_ik.active:
		_fail("source-pose mode did not disable IK")
		return
	# Recapturing while an old servo baseline is active must preserve a newly
	# edited FK hand rotation instead of restoring the old baseline first.
	scene.call("editor_servo_enable_marker_edit")
	var hand_index := male.find_bone("LeftHand")
	var authored_rotation := (Quaternion(Vector3.UP, 0.1) * male.get_bone_pose_rotation(hand_index)).normalized()
	male.set_bone_pose_rotation(hand_index, authored_rotation)
	scene.call("editor_servo_capture_current_male_pose")
	if male.get_bone_pose_rotation(hand_index).angle_to(authored_rotation) > 0.001 or left_ik.active:
		_fail("capturing an edited hand restored the stale servo baseline")
		return
	# Receiver edits must become the servo's source pose instead of triggering
	# an implicit seek of the baked Receiving CPR animation on Play.
	var head_index := female.find_bone("Head")
	var female_rotation := (Quaternion(Vector3.RIGHT, 0.08) * female.get_bone_pose_rotation(head_index)).normalized()
	female.set_bone_pose_rotation(head_index, female_rotation)
	var female_captured := scene.call("editor_servo_capture_current_female_pose") as Dictionary
	if not bool(female_captured.get("ok", false)) or not bool(servo.get("female_pose_calibrated")):
		_fail("female source pose capture failed")
		return
	var female_started := scene.call("editor_servo_play") as Dictionary
	if not bool(female_started.get("ok", false)):
		_fail("servo could not play from the captured female pose")
		return
	servo.call("seek", 0.0)
	if female.get_bone_pose_rotation(head_index).angle_to(female_rotation) > 0.001:
		_fail("servo restored the baked female pose after calibration")
		return
	# A marker authored at the surface may move inward only as far as the
	# configured depression budget, even when Press Depth is larger.
	var zero_left := left_target.global_position
	var period := 60.0 / float(servo.get("compressions_per_minute"))
	var peak_time := float(servo.get("start_delay_seconds")) + period * float(servo.get("downstroke_fraction"))
	servo.call("seek", peak_time)
	var hand_drop := zero_left.y - left_target.global_position.y
	if hand_drop > float(servo.get("max_hand_surface_depression_m")) + 0.002:
		_fail("palm target passed the configured chest-surface depression limit")
		return
	print("IKEA_CPR_MARKER_EDIT_OK")
	quit(0)

func _fail(message: String) -> void:
	push_error("IKEA_CPR_MARKER_EDIT_FAILED: " + message)
	quit(1)
