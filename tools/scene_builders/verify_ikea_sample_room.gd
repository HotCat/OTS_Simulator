extends SceneTree

const SCENE_PATH := "res://demos/ikea_sample_room_female_compare.tscn"

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("comparison room scene did not load")
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	for actor_name in [&"Female181", &"Female190"]:
		var actor := scene.get_node_or_null(NodePath("%s/IK_character" % actor_name)) as Node3D
		var skeleton := scene.get_node_or_null(NodePath("%s/IK_character/Skeleton3D" % actor_name)) as Skeleton3D
		var player := scene.get_node_or_null(NodePath("%s/WalkAnimationPlayer" % actor_name)) as AnimationPlayer
		var controller := scene.get_node_or_null(NodePath("%s/WalkController" % actor_name))
		var trajectory := scene.get_node_or_null(NodePath("%s/WalkTrajectory" % actor_name))
		if actor == null or skeleton == null or player == null or controller == null or trajectory == null:
			_fail("missing rig contract for " + actor_name)
			return
		if skeleton.get_bone_count() < 50:
			_fail("unexpected skeleton size for " + actor_name)
			return
		if player.get_animation(&"female_walk_cycle") == null:
			_fail("walk animation missing for " + actor_name)
			return
		if trajectory.get_child_count() < 2:
			_fail("walk trajectory missing waypoints for " + actor_name)
			return
		print("IKEA_ROOM_RIG_OK ", actor_name, " bones=", skeleton.get_bone_count())
	var male := scene.get_node_or_null("MaleCarrier/Character/Skeleton3D") as Skeleton3D
	var female190 := scene.get_node_or_null("Female190/IK_character/Skeleton3D") as Skeleton3D
	var male_player := scene.get_node_or_null("MaleCPRAnimationPlayer") as AnimationPlayer
	var female_player := scene.get_node_or_null("Female190CPRAnimationPlayer") as AnimationPlayer
	if male == null or female190 == null or male_player == null or female_player == null:
		_fail("male carrier or independent CPR animation players missing")
		return
	if male.get_bone_count() != 53 or female190.get_bone_count() != 62:
		_fail("CPR target skeletons do not match the expected Humanizer rigs")
		return
	var male_mesh := scene.get_node_or_null("MaleCarrier/Character/Skeleton3D/Avatar") as MeshInstance3D
	var female_actor := scene.get_node_or_null("Female190/IK_character") as Node3D
	if male_mesh == null or not male_mesh.visible or female_actor == null or not female_actor.visible:
		_fail("CPR characters are not visible in the IKEA scene")
		return
	var female_collider := scene.get_node_or_null("Female190/IK_character/MainCollider") as CollisionShape3D
	if not female_actor is AnimatableBody3D or female_collider == null or not female_collider.shape is CapsuleShape3D:
		_fail("CPR variant lost the original Humanizer body or capsule collider contract")
		return
	for binding in [[male_player, &"cpr/administering_cpr"], [female_player, &"cpr/receiving_cpr"]]:
		var player := binding[0] as AnimationPlayer
		var clip := player.get_animation(binding[1] as StringName)
		if clip == null or clip.get_track_count() < 57 or clip.loop_mode != Animation.LOOP_NONE:
			_fail("independent non-looping full-body CPR clip missing")
			return
		for track in clip.get_track_count():
			var path := str(clip.track_get_path(track))
			var node_path := NodePath(path.get_slice(":", 0))
			if scene.get_node_or_null(node_path) == null:
				_fail("CPR track does not resolve: " + path)
				return
			if player == male_player and not (path.begins_with("MaleCarrier/Character/Skeleton3D:") or path == "MaleCarrier/Character" or path == "MaleCarrier/Character/Skeleton3D"):
				_fail("male CPR track targets another character")
				return
			if player == female_player and not (path.begins_with("Female190/IK_character/Skeleton3D:") or path == "Female190/IK_character" or path == "Female190/IK_character/Skeleton3D"):
				_fail("female CPR track targets another character")
				return
	for bone_name in ["CPR_LeftBreastUpper", "CPR_LeftBreastLower", "CPR_RightBreastUpper", "CPR_RightBreastLower", "CPR_UpperAbdomen", "CPR_LowerAbdomen"]:
		if female190.find_bone(bone_name) < 56:
			_fail("CPR receiver deform bone missing or shifted original indices: " + bone_name)
			return
	print("IKEA_CPR_BINDINGS_OK male=administering_cpr female=receiving_cpr bones=62")
	if scene.get_node_or_null("IkeaSampleRoom") == null:
		_fail("room model instance missing")
		return
	var room := scene.get_node("IkeaSampleRoom")
	# The old bedside pieces, leaves and ceiling must not remain baked into the
	# shell, or hiding/moving their new sibling instances would leave duplicates.
	# Furniture must not be baked into the shell: otherwise moving the sibling
	# instance leaves a duplicate at the original position.
	for forbidden in [&"Bed_Frame_192x207cm", &"Wardrobe_LeftSide", &"Nightstand", &"Bedside_Lamp", &"Bedside_Shade", &"Ceiling_5x6m", &"GridDoor_Glass", &"SolidDoor_Panel"]:
		if room.find_child(forbidden, true, false) != null:
			_fail("movable or removed geometry remains baked into room shell: " + forbidden)
			return
	var ceiling := scene.get_node_or_null("Ceiling") as Node3D
	var grid_hinge := scene.get_node_or_null("GridDoorHinge") as Node3D
	var solid_hinge := scene.get_node_or_null("SolidDoorHinge") as Node3D
	var grid_leaf := scene.get_node_or_null("GridDoorHinge/Leaf") as Node3D
	var solid_leaf := scene.get_node_or_null("SolidDoorHinge/Leaf") as Node3D
	if ceiling == null or ceiling.visible or grid_hinge == null or solid_hinge == null or grid_leaf == null or solid_leaf == null:
		_fail("separate hidden ceiling or independently hinged door leaves missing")
		return
	if ceiling.find_child("Ceiling_5x6m", true, false) == null or grid_leaf.find_child("GridDoor_Glass", true, false) == null or solid_leaf.find_child("SolidDoor_Panel", true, false) == null:
		_fail("ceiling or door leaf geometry missing")
		return
	var original_solid_angle := solid_leaf.rotation_degrees.y
	grid_hinge.set("opening_angle_degrees", 65.0)
	if not is_equal_approx(grid_leaf.rotation_degrees.y, 65.0) or not is_equal_approx(solid_leaf.rotation_degrees.y, original_solid_angle):
		_fail("grid door angle does not update independently")
		return
	solid_hinge.set("opening_angle_degrees", 90.0)
	if not is_equal_approx(solid_leaf.rotation_degrees.y, 90.0) or not is_equal_approx(grid_leaf.rotation_degrees.y, 65.0):
		_fail("solid door angle does not update independently")
		return
	print("IKEA_ROOM_DOORS_OK grid=65 solid=90 ceiling_hidden=true")
	var bed := scene.get_node_or_null("Bed") as Node3D
	var wardrobe := scene.get_node_or_null("Wardrobe") as Node3D
	if bed == null or wardrobe == null or bed.get_parent() != scene or wardrobe.get_parent() != scene:
		_fail("bed and wardrobe are not independent top-level scene instances")
		return
	var bed_frame := bed.find_child("Bed_Frame_192x207cm", true, false) as MeshInstance3D
	var wardrobe_left := wardrobe.find_child("Wardrobe_LeftSide", true, false) as MeshInstance3D
	var wardrobe_right := wardrobe.find_child("Wardrobe_RightSide", true, false) as MeshInstance3D
	if bed_frame == null or wardrobe_left == null or wardrobe_right == null:
		_fail("separate furniture models have missing geometry")
		return
	var bed_size := bed_frame.mesh.get_aabb().size
	if not is_equal_approx(bed_size.x, 1.92) or not is_equal_approx(bed_size.z, 2.07):
		_fail("bed envelope is not 1.92 x 2.07 m: " + str(bed_size))
		return
	var side_size := wardrobe_left.mesh.get_aabb().size
	var cabinet_width := wardrobe_right.position.x - wardrobe_left.position.x + side_size.x
	if not is_equal_approx(cabinet_width, 0.82) or not is_equal_approx(side_size.z, 0.60) or not is_equal_approx(side_size.y, 1.94):
		_fail("wardrobe cabinet is not 0.82 x 0.60 x 1.94 m: " + str(side_size))
		return
	var old_wardrobe_position := wardrobe.position
	bed.position += Vector3(0.2, 0.0, 0.0)
	if wardrobe.position != old_wardrobe_position:
		_fail("moving bed unexpectedly moved wardrobe")
		return
	print("IKEA_FURNITURE_INDEPENDENT_OK bed=", bed_size, " wardrobe_parts=", wardrobe.get_child_count())
	var director := scene as Node
	if not director.has_method("editor_transport_restart") or not director.has_method("editor_capture_step_fixed"):
		_fail("shared multi-character director contract missing")
		return
	var authored_male_transform := (scene.get_node("MaleCarrier/Character") as Node3D).transform
	var authored_female_transform := female_actor.transform
	var authored_female_skeleton_transform := female190.transform
	var authored_female_arm := female190.get_bone_pose_rotation(female190.find_bone("LeftUpperArm"))
	var cpr_at_start := director.call("editor_cpr_seek", 0.0) as Dictionary
	if not bool(cpr_at_start.get("ok", false)):
		_fail("CPR editor seek did not start")
		return
	var male_character := scene.get_node("MaleCarrier/Character") as Node3D
	if not is_equal_approx(male_character.position.y, -0.577572) or not is_equal_approx(female_actor.position.y, 0.028025):
		_fail("independent source floor-contact offsets did not apply")
		return
	for skeleton in [male, female190]:
		var foot_heights := []
		for bone_name in ["LeftFoot", "RightFoot", "LeftToes", "RightToes"]:
			var foot_index: int = skeleton.find_bone(bone_name)
			foot_heights.append(skeleton.to_global(skeleton.get_bone_global_pose(foot_index).origin).y)
		print("IKEA_CPR_FEET ", skeleton.get_path(), " ", foot_heights)
	for source_spec in [["res://assets/downloads/Administering Cpr.fbx", male_player, &"cpr/administering_cpr", 38, male, scene.get_node("MaleCarrier")], ["res://assets/downloads/Receiving Cpr.fbx", female_player, &"cpr/receiving_cpr", 41, female190, scene.get_node("Female190")]]:
		var source_cpr := (load(str(source_spec[0])) as PackedScene).instantiate()
		root.add_child(source_cpr)
		var source_player := source_cpr.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var source_skeleton := source_cpr.find_child("Skeleton3D", true, false) as Skeleton3D
		var source_animation := source_player.get_animation(source_player.get_animation_list()[0])
		var target_player := source_spec[1] as AnimationPlayer
		var target_skeleton := source_spec[4] as Skeleton3D
		var staging_root := source_spec[5] as Node3D
		var target_animation := target_player.get_animation(source_spec[2] as StringName)
		if str(target_animation.get_meta("source_fbx", "")) != str(source_spec[0]):
			_fail("CPR clip provenance points to the wrong FBX: " + str(target_player.name))
			return
		var matched_tracks := 0
		for source_track in source_animation.get_track_count():
			if source_animation.track_get_type(source_track) != Animation.TYPE_ROTATION_3D:
				continue
			var source_path := str(source_animation.track_get_path(source_track))
			if not source_path.contains("/Skeleton3D:"):
				continue
			var bone_name := source_path.get_slice(":", 1)
			var target_track := _rotation_track(target_animation, bone_name)
			if target_track < 0:
				_fail("Godot-native CPR bone track missing: " + bone_name)
				return
			for key_index in [0, int(source_animation.track_get_key_count(source_track) / 2), source_animation.track_get_key_count(source_track) - 1]:
				var source_rotation := source_animation.track_get_key_value(source_track, key_index) as Quaternion
				var target_rotation := target_animation.track_get_key_value(target_track, key_index) as Quaternion
				if source_rotation.angle_to(target_rotation) > 0.001:
					_fail("Godot CPR pose-basis mismatch: " + bone_name + " on " + str(target_player.name))
					return
			matched_tracks += 1
		if matched_tracks < int(source_spec[3]):
			_fail("Too few Godot-native CPR tracks matched: " + str(matched_tracks))
			return
		var source_object_position := source_animation.track_get_key_value(0, 0) as Vector3
		for seconds in [0.0, 4.0]:
			source_player.play(source_player.get_animation_list()[0])
			source_player.seek(seconds, true)
			director.call("editor_cpr_seek", seconds)
			for bone_name in ["Hips", "Head", "LeftHand", "RightHand", "LeftToes", "RightToes"]:
				var source_index := source_skeleton.find_bone(bone_name)
				var target_index := target_skeleton.find_bone(bone_name)
				var source_joint := source_skeleton.to_global(source_skeleton.get_bone_global_pose(source_index).origin)
				source_joint.x -= source_object_position.x
				source_joint.z -= source_object_position.z
				var target_joint := staging_root.to_local(target_skeleton.to_global(target_skeleton.get_bone_global_pose(target_index).origin))
				if source_joint.distance_to(target_joint) > 0.025:
					_fail("CPR world-joint mismatch on %s at %.2fs: source=%s target=%s" % [bone_name, seconds, source_joint, target_joint])
					return
		print("IKEA_CPR_GODOT_BASIS_OK source=", source_spec[0], " tracks=", matched_tracks)
		source_cpr.free()
	director.call("editor_cpr_seek", 0.0)
	var upper_arm_index := male.find_bone("LeftUpperArm")
	var start_arm := male.get_bone_pose_rotation(upper_arm_index)
	var female_arm_index := female190.find_bone("LeftUpperArm")
	var female_start_arm := female190.get_bone_pose_rotation(female_arm_index)
	var cpr_at_mid := director.call("editor_cpr_seek", 4.0) as Dictionary
	var mid_arm := male.get_bone_pose_rotation(upper_arm_index)
	if not is_equal_approx(float(cpr_at_mid.get("time", -1.0)), 4.0) or start_arm.angle_to(mid_arm) < 0.01:
		_fail("CPR editor seek does not move the male arm")
		return
	var female_mid_arm := female190.get_bone_pose_rotation(female_arm_index)
	if female_mid_arm.angle_to(female_start_arm) < 0.01:
		_fail("Female190 CPR motion did not retarget independently")
		return
	print("IKEA_CPR_EDITOR_SEEK_OK arm_delta=", start_arm.angle_to(mid_arm), " time=4.0")
	director.call("editor_cpr_restart")
	var cpr_capture_state := director.call("editor_capture_begin_fixed_step", {}) as Dictionary
	director.call("editor_capture_step_fixed", 1.0 / 24.0)
	var cpr_step_time := float((director.call("editor_cpr_status") as Dictionary).get("time", 0.0))
	director.call("editor_capture_end_fixed_step", bool(cpr_capture_state.get("was_playing", false)))
	if not is_equal_approx(cpr_step_time, 1.0 / 24.0):
		_fail("CPR fixed-step capture does not advance in lockstep")
		return
	print("IKEA_CPR_FIXED_STEP_OK time=", cpr_step_time)
	director.call("editor_transport_restart")
	director.call("editor_transport_play")
	if not male_character.transform.is_equal_approx(authored_male_transform) or not female_actor.transform.is_equal_approx(authored_female_transform) or not female190.transform.is_equal_approx(authored_female_skeleton_transform) or female190.get_bone_pose_rotation(female190.find_bone("LeftUpperArm")).angle_to(authored_female_arm) > 0.001:
		_fail("leaving CPR did not restore authored character and skeleton pose")
		return
	var capture_state := director.call("editor_capture_begin_fixed_step", {}) as Dictionary
	director.call("editor_capture_step_fixed", 1.0 / 24.0)
	director.call("editor_capture_end_fixed_step", bool(capture_state.get("was_playing", false)))
	print("IKEA_ROOM_DIRECTOR_OK controllers=", capture_state.get("controllers", 0))
	print("IKEA_ROOM_SCENE_OK")
	quit(0)

func _fail(message: String) -> void:
	push_error("IKEA_ROOM_SCENE_FAILED: " + message)
	quit(1)

func _rotation_track(animation: Animation, bone_name: String) -> int:
	for track in animation.get_track_count():
		if animation.track_get_type(track) == Animation.TYPE_ROTATION_3D and str(animation.track_get_path(track)).ends_with(":" + bone_name):
			return track
	return -1
