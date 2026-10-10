extends SceneTree

const SCENE := "res://demos/ikea_sample_room_female_compare.tscn"

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var scene := (load(SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	var servo := scene.get_node_or_null("CPRServoController")
	var male := scene.get_node_or_null("MaleCarrier/Character/Skeleton3D") as Skeleton3D
	var female := scene.get_node_or_null("Female190/IK_character/Skeleton3D") as Skeleton3D
	var left_target := scene.get_node_or_null("CPRServoAnchors/LeftPalmTarget") as Marker3D
	var right_target := scene.get_node_or_null("CPRServoAnchors/RightPalmTarget") as Marker3D
	var left_ik := scene.get_node_or_null("MaleCarrier/Character/Skeleton3D/cpr_left_arm_ik") as TwoBoneIK3D
	var right_ik := scene.get_node_or_null("MaleCarrier/Character/Skeleton3D/cpr_right_arm_ik") as TwoBoneIK3D
	if servo == null or male == null or female == null or left_target == null or right_target == null or left_ik == null or right_ik == null:
		_fail("servo hierarchy incomplete")
		return
	var start := scene.call("editor_servo_seek", 0.0) as Dictionary
	if not bool(start.get("ok", false)) or not left_ik.active or not right_ik.active:
		_fail("servo could not start both hand IK chains")
		return
	await process_frame
	var initial_left := left_target.global_position
	var initial_right := right_target.global_position
	var initial_chest := _bone_position(female, "UpperChest")
	var initial_head := _bone_position(female, "Head")
	var initial_breast := _bone_position(female, "CPR_LeftBreastLower")
	var initial_abdomen := _bone_position(female, "CPR_UpperAbdomen")
	var period := 60.0 / float(servo.get("compressions_per_minute"))
	var peak_time := float(servo.get("start_delay_seconds")) + period * float(servo.get("downstroke_fraction"))
	var peak := scene.call("editor_servo_seek", peak_time) as Dictionary
	await process_frame
	peak = scene.call("editor_servo_status") as Dictionary
	var expected_depth := float(servo.get("press_depth_m"))
	if absf(float(peak.get("press_depth_m", -1.0)) - expected_depth) > 0.001:
		_fail("servo peak is not the configured compression depth")
		return
	var left_drop := initial_left.y - left_target.global_position.y
	var right_drop := initial_right.y - right_target.global_position.y
	var chest_drop := initial_chest.y - _bone_position(female, "UpperChest").y
	var target_depth := expected_depth
	if bool(servo.get("prevent_hand_chest_penetration")):
		target_depth = minf(expected_depth, float(servo.get("max_hand_surface_depression_m")))
	var floor_clearance := float(peak.get("receiver_floor_clearance_m", -INF))
	if absf(left_drop - target_depth) > 0.008 or absf(right_drop - target_depth) > 0.008 or chest_drop < 0.0 or chest_drop > 0.008 or floor_clearance < 0.001:
		_fail("hand targets and secondary chest response are not coupled to compression: left=%f right=%f chest=%f" % [left_drop, right_drop, chest_drop])
		return
	var left_hand_error := float(peak.get("left_contact_error_m", INF))
	var right_hand_error := float(peak.get("right_contact_error_m", INF))
	print("IKEA_CPR_SERVO_CONTACT left_error=", left_hand_error, " right_error=", right_hand_error, " chest_drop=", chest_drop, " floor_clearance=", floor_clearance, " measured_left=", peak.get("measured_left_wrist_travel_m"), " measured_right=", peak.get("measured_right_wrist_travel_m"))
	print("IKEA_CPR_SERVO_ORIENTATION left=", peak.get("left_hand_orientation_error_degrees"), " right=", peak.get("right_hand_orientation_error_degrees"))
	if left_hand_error > 0.045 or right_hand_error > 0.045:
		_fail("hand IK does not reach both driven targets")
		return
	if initial_breast.distance_to(_bone_position(female, "CPR_LeftBreastLower")) < 0.005 or initial_abdomen.distance_to(_bone_position(female, "CPR_UpperAbdomen")) < 0.002:
		_fail("new breast/abdomen controls do not respond to compression")
		return
	var weighted := _count_new_bone_weights(female)
	if weighted < 700:
		_fail("CPR soft-tissue controls are not weighted to the imported skin: %d" % weighted)
		return
	var head_peak := _bone_position(female, "Head")
	if head_peak.distance_to(initial_head) < 0.001:
		_fail("receiver head does not respond to compression")
		return
	var repeated := scene.call("editor_servo_seek", peak_time) as Dictionary
	if not bool(repeated.get("ok", false)) or _bone_position(female, "Head").distance_to(head_peak) > 0.0001:
		_fail("servo seek is not deterministic")
		return
	# User calibration must survive a servo seek, including palm orientation.
	scene.call("editor_servo_seek", 0.0)
	await process_frame
	var original_left := left_target.global_transform
	left_target.global_position += Vector3(0.012, 0.0, 0.0)
	left_target.global_transform.basis = left_target.global_transform.basis.rotated(Vector3.UP, deg_to_rad(12.0))
	var edited_left := left_target.global_transform
	var captured := scene.call("editor_servo_capture_markers") as Dictionary
	if not bool(captured.get("ok", false)):
		_fail("edited CPR palm marker could not be captured")
		return
	scene.call("editor_servo_seek", 0.0)
	await process_frame
	var edited_status := scene.call("editor_servo_status") as Dictionary
	if left_target.global_position.distance_to(edited_left.origin) > 0.001 or left_target.global_position.distance_to(original_left.origin) < 0.009:
		_fail("palm contact position edit did not survive servo seek")
		return
	if float(edited_status.get("left_contact_error_m", INF)) > 0.045 or float(edited_status.get("left_hand_orientation_error_degrees", INF)) > 8.0:
		_fail("hand IK did not follow edited palm position and orientation")
		return
	var capture := scene.call("editor_capture_begin_fixed_step", {}) as Dictionary
	if str(capture.get("motion_source", "")) != "cpr_servo":
		_fail("OTS Render did not select servo fixed-step clock")
		return
	scene.call("editor_servo_play")
	var prior_time := float((scene.call("editor_servo_status") as Dictionary).get("time", -1.0))
	scene.call("editor_capture_step_fixed", 1.0 / 24.0)
	var next_time := float((scene.call("editor_servo_status") as Dictionary).get("time", -1.0))
	if absf(next_time - prior_time - 1.0 / 24.0) > 0.0001:
		_fail("servo fixed-step clock is not advancing at video FPS")
		return
	scene.call("editor_capture_end_fixed_step", true)
	scene.call("editor_transport_play")
	if left_ik.active or right_ik.active:
		_fail("switching back to walk leaves CPR hand IK active")
		return
	print("IKEA_CPR_SERVO_OK depth=", expected_depth, " period=", period, " shot=", servo.get("shot_duration_seconds"), " new_weights=", weighted)
	quit(0)

func _count_new_bone_weights(skeleton: Skeleton3D) -> int:
	var count := 0
	for child in skeleton.get_children():
		if not child is MeshInstance3D:
			continue
		var mesh := (child as MeshInstance3D).mesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				if not vertex.is_finite():
					return -1
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			for index in mini(bones.size(), weights.size()):
				if not is_finite(weights[index]):
					return -1
				if bones[index] >= 56 and bones[index] <= 61 and weights[index] > 0.005:
					count += 1
	return count

func _bone_position(skeleton: Skeleton3D, name: String) -> Vector3:
	return skeleton.to_global(skeleton.get_bone_global_pose(skeleton.find_bone(name)).origin)

func _fail(message: String) -> void:
	push_error("IKEA_CPR_SERVO_FAILED: " + message)
	quit(1)
