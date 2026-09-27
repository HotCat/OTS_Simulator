extends SceneTree

const SCENE_PATH := "res://demos/ots_carry_clay_proxy.tscn"
const MIN_VISIBLE_ROTATION_DEGREES := 0.5

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("Could not load %s" % SCENE_PATH)
		return
	var shot := packed.instantiate() as Node3D
	root.add_child(shot)
	await process_frame

	shot.carrier_trajectory_enabled = false
	shot.secondary_motion_enabled = true
	shot.rhythm_source = 1
	shot.secondary_motion_lag_seconds = 0.0
	shot._reset_secondary_rhythm()
	var player := shot.get_node("OTSCarryAnimationPlayer") as AnimationPlayer
	var female := shot.get_node("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	var male := shot.get_node("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	player.play(&"ots_carry_walk_cycle")

	var checks := {
		"LeftUpperLeg": 0.0,
		"LeftUpperArm": 0.0,
		"Head": 0.0,
	}
	var animation_length := player.get_animation(&"ots_carry_walk_cycle").length
	# Two passes allow the adaptive planted-foot baseline to observe each foot's
	# lowest point before we assert that the carried body receives motion.
	for sample_index in 97:
		var time := fmod(float(sample_index) / 48.0 * animation_length, animation_length)
		player.seek(time, true)
		male.force_update_all_bone_transforms()
		shot._apply_secondary_motion(1.0 / 48.0)
		for bone_name in checks:
			var bone_index := female.find_bone(StringName(bone_name))
			var baseline: Transform3D = shot._female_secondary_baseline[bone_index]
			var posed := female.get_bone_pose(bone_index)
			var angle := rad_to_deg(baseline.basis.get_rotation_quaternion().angle_to(posed.basis.get_rotation_quaternion()))
			checks[bone_name] = maxf(float(checks[bone_name]), angle)

	for bone_name in checks:
		if float(checks[bone_name]) < MIN_VISIBLE_ROTATION_DEGREES:
			_fail("%s secondary motion stayed at %.3f degrees" % [bone_name, checks[bone_name]])
			return
	print("OTS_CARRY_SECONDARY_TEST_OK leg=%.3f arm=%.3f head=%.3f" % [
		checks.LeftUpperLeg,
		checks.LeftUpperArm,
		checks.Head,
	])
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
