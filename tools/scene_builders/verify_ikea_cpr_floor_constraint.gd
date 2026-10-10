extends SceneTree

const SCENE := "res://demos/ikea_sample_room_female_compare.tscn"
const FLOOR_Y := 0.0
const REQUIRED_CLEARANCE := 0.002

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
	var female := scene.get_node("Female190/IK_character/Skeleton3D") as Skeleton3D
	var peak_time := float(servo.get("start_delay_seconds")) + 0.5 * 60.0 / float(servo.get("compressions_per_minute"))
	var source := scene.call("editor_servo_seek", 0.0) as Dictionary
	if not bool(source.get("ok", false)):
		_fail("servo source-pose seek failed")
		return
	var initial_upper_chest := _bone_position(female, "UpperChest")
	var initial_breast := _bone_position(female, "CPR_LeftBreastLower")
	for frame in 217:
		var time := 9.0 * float(frame) / 216.0
		var result := scene.call("editor_servo_seek", time) as Dictionary
		if not bool(result.get("ok", false)):
			_fail("servo seek failed during floor sweep at t=%.3f" % time)
			return
		var status := scene.call("editor_servo_status") as Dictionary
		var clearance := float(status.get("receiver_floor_clearance_m", -INF))
		if clearance < REQUIRED_CLEARANCE - 0.001:
			_fail("receiver torso crossed its floor clearance at t=%.3f: %.4f m" % [time, clearance])
			return
	var peak := scene.call("editor_servo_seek", peak_time) as Dictionary
	if not bool(peak.get("ok", false)):
		_fail("peak compression seek failed")
		return
	var upper_chest_drop := initial_upper_chest.y - _bone_position(female, "UpperChest").y
	var breast_drop := initial_breast.y - _bone_position(female, "CPR_LeftBreastLower").y
	if upper_chest_drop < -0.001 or upper_chest_drop > 0.002:
		_fail("supported rib cage translated too far during compression: %.4f m" % upper_chest_drop)
		return
	if breast_drop < 0.6 * float(servo.get("breast_lower_settle_m")):
		_fail("localized breast deformation is too small: %.4f m" % breast_drop)
		return
	print("IKEA_CPR_FLOOR_CONSTRAINT_OK upper_chest_drop=", upper_chest_drop, " local_breast_drop=", breast_drop)
	quit(0)

func _bone_position(skeleton: Skeleton3D, name: String) -> Vector3:
	return skeleton.to_global(skeleton.get_bone_global_pose(skeleton.find_bone(name)).origin)

func _fail(message: String) -> void:
	push_error("IKEA_CPR_FLOOR_CONSTRAINT_FAILED: " + message)
	quit(1)
