extends SceneTree

const SCENE := "res://demos/ikea_sample_room_female_compare.tscn"

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var scene := (load(SCENE) as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	var player := scene.get_node_or_null("SleepingIdleAnimationPlayer") as AnimationPlayer
	var skeleton := scene.get_node_or_null("Female181/IK_character/Skeleton3D") as Skeleton3D
	if player == null or skeleton == null or not player.has_animation(&"sleep/sleeping_idle"):
		_fail("Female181 sleeping idle binding missing")
		return
	var animation := player.get_animation(&"sleep/sleeping_idle")
	if animation.length < 6.0 or animation.get_track_count() < 50:
		_fail("retargeted animation is incomplete")
		return
	var preview := scene.call("editor_female181_sleep_play") as Dictionary
	if not bool(preview.get("ok", false)) or not (scene.get_node("Female181") as Node3D).visible:
		_fail("Female181 sleeping idle editor preview is unavailable")
		return
	scene.call("editor_female181_sleep_pause")
	var source := (load("res://assets/downloads/Sleeping Idle.fbx") as PackedScene).instantiate()
	root.add_child(source)
	var source_skeleton := source.find_child("Skeleton3D", true, false) as Skeleton3D
	var source_player := source.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var source_animation_name := source_player.get_animation_list()[0]
	var actor := scene.get_node("Female181") as Node3D
	var max_joint_error := 0.0
	var first: Dictionary = {}
	var last: Dictionary = {}
	var max_seam := 0.0
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var path := str(animation.track_get_path(track))
		if not path.contains("Skeleton3D:") or animation.track_get_key_count(track) < 2:
			continue
		var start := animation.track_get_key_value(track, 0) as Quaternion
		var end := animation.track_get_key_value(track, animation.track_get_key_count(track) - 1) as Quaternion
		max_seam = maxf(max_seam, rad_to_deg(start.angle_to(end)))
		first[path] = start
		last[path] = end
	for time in [0.0, animation.length * 0.5, animation.length - 0.001]:
		player.assigned_animation = &"sleep/sleeping_idle"
		player.seek(time, true)
		source_player.assigned_animation = source_animation_name
		source_player.seek(time, true)
		for name in [&"Hips", &"Spine", &"Head", &"LeftHand", &"RightHand", &"LeftFoot", &"RightFoot"]:
			var index := skeleton.find_bone(name)
			if index < 0 or not skeleton.get_bone_global_pose(index).origin.is_finite():
				_fail("invalid sleeping pose at %s time=%f" % [name, time])
				return
			var source_index := source_skeleton.find_bone(name)
			var source_joint: Vector3 = (source as Node3D).to_local(source_skeleton.to_global(source_skeleton.get_bone_global_pose(source_index).origin))
			var target_joint: Vector3 = actor.to_local(skeleton.to_global(skeleton.get_bone_global_pose(index).origin))
			max_joint_error = maxf(max_joint_error, source_joint.distance_to(target_joint))
	if max_joint_error > 0.001 or max_seam > 1.0:
		_fail("retargeted joint motion or loop seam diverged from the source")
		return
	print("FEMALE181_SLEEPING_IDLE_OK length=", animation.length, " tracks=", animation.get_track_count(), " mapped_rotations=", first.size(), " max_loop_seam_degrees=", max_seam, " max_joint_error_m=", max_joint_error)
	quit(0)

func _fail(message: String) -> void:
	push_error("FEMALE181_SLEEPING_IDLE_FAILED: " + message)
	quit(1)
