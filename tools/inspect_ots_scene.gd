extends SceneTree

func _initialize() -> void:
	var scene := load("res://demos/ots_carry_clay_proxy.tscn") as PackedScene
	var root := scene.instantiate()
	get_root().add_child(root)
	var player := root.get_node("OTSCarryAnimationPlayer") as AnimationPlayer
	player.stop()
	await process_frame
	var male_skeleton := root.get_node("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	var female_skeleton := root.get_node("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	var clip := player.get_animation("ots_carry_walk_cycle")
	print("player=", player.get_path(), " animations=", player.get_animation_list(), " clip_length=", clip.length if clip else -1.0, " tracks=", clip.get_track_count() if clip else -1)
	if clip == null or clip.loop_mode != Animation.LOOP_LINEAR:
		push_error("OTS carrier animation is missing or is not a linear loop")
		quit(1)
		return
	var trajectory := root.get_node_or_null("CarrierTrajectory") as Node3D
	var walk_plane := root.get_node_or_null("CarrierWalkPlane") as Node3D
	if trajectory == null or walk_plane == null or trajectory.get_child_count() < 2:
		push_error("Carrier trajectory or walk plane is missing")
		quit(1)
		return
	var male_leg := male_skeleton.find_bone("LeftUpperLeg")
	var female_leg := female_skeleton.find_bone("LeftUpperLeg")
	var male_before := male_skeleton.get_bone_pose_rotation(male_leg) if male_leg >= 0 else Quaternion.IDENTITY
	var female_before := female_skeleton.get_bone_pose_rotation(female_leg) if female_leg >= 0 else Quaternion.IDENTITY
	var male_hips := male_skeleton.find_bone("Hips")
	var male_hips_before := male_skeleton.get_bone_pose_rotation(male_hips) if male_hips >= 0 else Quaternion.IDENTITY
	player.play("ots_carry_walk_cycle")
	player.seek(0.0, true)
	await process_frame
	var male_hips_after_frame0 := male_skeleton.get_bone_pose_rotation(male_hips) if male_hips >= 0 else Quaternion.IDENTITY
	print("frame0 male_left_upper_leg_delta=", male_before.angle_to(male_skeleton.get_bone_pose_rotation(male_leg)), " male_hips_delta=", male_hips_before.angle_to(male_hips_after_frame0))
	player.seek(minf(1.0, clip.length if clip else 1.0), true)
	await process_frame
	var male_after := male_skeleton.get_bone_pose_rotation(male_leg) if male_leg >= 0 else Quaternion.IDENTITY
	var female_after := female_skeleton.get_bone_pose_rotation(female_leg) if female_leg >= 0 else Quaternion.IDENTITY
	print("male_left_upper_leg_delta=", male_before.angle_to(male_after), " female_delta=", female_before.angle_to(female_after))
	for bone_name in ["Hips", "Spine", "LeftShoulder", "RightShoulder"]:
		var mi := male_skeleton.find_bone(bone_name)
		var fi := female_skeleton.find_bone(bone_name)
		if mi >= 0:
			print("male ", bone_name, "=", male_skeleton.get_bone_global_pose(mi).origin)
		if fi >= 0:
			print("female ", bone_name, "=", female_skeleton.get_bone_global_pose(fi).origin)
	root.free()
	quit(0)
