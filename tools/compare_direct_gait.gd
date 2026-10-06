extends SceneTree

func _initialize() -> void:
	# PackedScene instances must be in the SceneTree before global bone poses are
	# queried.  The previous diagnostic ran in _initialize() and consequently
	# produced misleading `!is_inside_tree()` errors and never advanced either
	# AnimationPlayer reliably.
	call_deferred("_run")

func _run() -> void:
	var target_root := (load("res://demos/ots_carry_clay_proxy.tscn") as PackedScene).instantiate()
	var source_root := (load("res://assets/downloads/Standard Walk.fbx") as PackedScene).instantiate()
	root.add_child(target_root)
	root.add_child(source_root)
	await process_frame
	var target_player := target_root.get_node("OTSCarryAnimationPlayer") as AnimationPlayer
	var source_player := source_root.get_node("AnimationPlayer") as AnimationPlayer
	target_player.play("mixamo_walking_male_godot_direct/mixamo_walking_male_godot_direct")
	source_player.play(source_player.get_animation_library("").get_animation_list()[0])
	var target_skeleton := target_root.get_node("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	var source_skeleton := source_root.get_node("male_1785818633452_humanizer_proxy_Humanizer_RealtimeProxy/Skeleton3D") as Skeleton3D
	for time in [0.0, 0.5, 1.0, 1.5, 2.0]:
		target_player.seek(time, true); source_player.seek(time, true)
		await process_frame
		target_skeleton.force_update_all_bone_transforms(); source_skeleton.force_update_all_bone_transforms()
		print("TIME ", time)
		for side in [&"Left", &"Right"]:
			print(side, " target=", _points(target_skeleton, side), " source=", _points(source_skeleton, side))
	target_root.free(); source_root.free(); quit(0)

func _points(skeleton: Skeleton3D, side: StringName) -> String:
	var names := [String(side) + "UpperLeg", String(side) + "LowerLeg", String(side) + "Foot"]
	var values: Array[String] = []
	for name in names:
		var index := skeleton.find_bone(name)
		# Compare in Skeleton3D space.  The source GLB is travelling in its own
		# scene root while OTSCarryClayProxy is already placed on CarrierTrajectory;
		# world-space values would mostly measure the two unrelated root poses.
		var p := skeleton.get_bone_global_pose(index)
		values.append("%s(%.3f,%.3f,%.3f)" % [name, p.origin.x, p.origin.y, p.origin.z])
	return " ".join(values)
