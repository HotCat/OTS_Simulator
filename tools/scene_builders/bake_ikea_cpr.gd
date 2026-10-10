extends SceneTree

## The CPR FBX is a re-export of the project's exact Humanizer male rig.
## Blender's FBX importer expresses some bone rotations in different local
## bases from Godot's importer. A Blender-local "absolute" quaternion cannot
## be written directly to Skeleton3D:Bone, even when the bone names match.
## Sample Godot's imported FBX animation, verify the target's Godot rest axes
## and hierarchy, then copy/rebase the already-converted Godot-space keys.
const REST_TOLERANCE_RADIANS := 0.001

func _initialize() -> void:
	if "--female181-sleeping-idle" in OS.get_cmdline_user_args():
		quit(0 if _bake_target([
			"res://assets/downloads/Sleeping Idle.fbx",
			"res://assets/models/actor_1787313553107_v2_realtime_proxy.glb",
			"Female181/IK_character/Skeleton3D", "Female181/IK_character",
			&"sleeping_idle", "res://animations/ikea_female181_sleeping_idle.tres",
		]) else 1)
		return
	var success := true
	for spec in [
		["res://assets/downloads/Administering Cpr.fbx", "res://assets/models/male_carrier/male_1785818633452_humanizer_proxy.glb", "MaleCarrier/Character/Skeleton3D", "MaleCarrier/Character", &"administering_cpr", "res://animations/ikea_cpr_male.tres"],
		["res://assets/downloads/Receiving Cpr.fbx", "res://assets/models/female_1791377232602/female_1791377232602_cpr_deform.glb", "Female190/IK_character/Skeleton3D", "Female190/IK_character", &"receiving_cpr", "res://animations/ikea_cpr_female190.tres"],
	]:
		if not _bake_target(spec):
			success = false
			break
	quit(0 if success else 1)

func _first_animation(player: AnimationPlayer) -> Animation:
	for library_name in player.get_animation_library_list():
		var library := player.get_animation_library(library_name)
		if not library.get_animation_list().is_empty():
			return library.get_animation(library.get_animation_list()[0])
	return null

func _bake_target(spec: Array) -> bool:
	var source_scene := load(str(spec[0])) as PackedScene
	var target_scene := load(str(spec[1])) as PackedScene
	if source_scene == null:
		push_error("CPR source FBX missing: " + str(spec[0]))
		return false
	if target_scene == null:
		push_error("CPR target GLB missing: " + str(spec[1]))
		return false
	var source_root := source_scene.instantiate()
	var source_skeleton := source_root.find_child("Skeleton3D", true, false) as Skeleton3D
	var source_player := source_root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var target_root := target_scene.instantiate()
	var target_skeleton := target_root.find_child("Skeleton3D", true, false) as Skeleton3D
	if source_skeleton == null or source_player == null or target_skeleton == null:
		push_error("CPR source/target armature missing: " + str(spec[0]))
		source_root.free()
		target_root.free()
		return false
	var source_animation := _first_animation(source_player)
	if source_animation == null or source_animation.length <= 0.0:
		push_error("CPR source action empty: " + str(spec[0]))
		source_root.free()
		target_root.free()
		return false
	var source_tracks := _source_rotation_tracks(source_animation)
	var animation := Animation.new()
	animation.resource_name = str(spec[4])
	animation.length = source_animation.length
	animation.step = source_animation.step
	animation.loop_mode = Animation.LOOP_LINEAR if str(spec[4]) == "sleeping_idle" else Animation.LOOP_NONE
	var mapped := 0
	var animated := 0
	for bone_index in target_skeleton.get_bone_count():
		var bone_name := str(target_skeleton.get_bone_name(bone_index))
		if bone_name == "Root":
			# The imported FBX Root has a 90-degree rest-axis difference.
			# Its static correction is folded into the animated armature below.
			continue
		var source_index := source_skeleton.find_bone(bone_name)
		if source_index < 0:
			# Female ponytail joints have no source counterpart. Leave them to
			# the female rig's own neutral pose or secondary-motion controller.
			continue
		var source_parent := source_skeleton.get_bone_parent(source_index)
		var target_parent := target_skeleton.get_bone_parent(bone_index)
		var source_parent_name := str(source_skeleton.get_bone_name(source_parent)) if source_parent >= 0 else ""
		var target_parent_name := str(target_skeleton.get_bone_name(target_parent)) if target_parent >= 0 else ""
		var rest_angle := source_skeleton.get_bone_rest(source_index).basis.get_rotation_quaternion().angle_to(
			target_skeleton.get_bone_rest(bone_index).basis.get_rotation_quaternion())
		if source_parent_name != target_parent_name or rest_angle > REST_TOLERANCE_RADIANS:
			push_error("CPR Godot rest/hierarchy mismatch: %s parent=%s/%s angle=%f" % [bone_name, source_parent_name, target_parent_name, rest_angle])
			source_root.free()
			target_root.free()
			return false
		var source_length := source_skeleton.get_bone_rest(source_index).origin.length()
		var target_length := target_skeleton.get_bone_rest(bone_index).origin.length()
		if source_length > 0.00001 and absf(target_length / source_length - 100.0) > 1.0:
			push_error("CPR source/target rest length mismatch: " + bone_name)
			source_root.free()
			target_root.free()
			return false
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("%s:%s" % [spec[2], bone_name]))
		animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
		if source_tracks.has(bone_name):
			var source_track := int(source_tracks[bone_name])
			var previous := Quaternion.IDENTITY
			for key_index in source_animation.track_get_key_count(source_track):
				var value := (source_animation.track_get_key_value(source_track, key_index) as Quaternion).normalized()
				if key_index > 0 and previous.dot(value) < 0.0:
					value = -value
				animation.rotation_track_insert_key(track, source_animation.track_get_key_time(source_track, key_index), value)
				previous = value
			animated += 1
		else:
			# Explicitly clear old scene-authored OTS bone overrides, including
			# the female's Hips and distal fingers, during this independent clip.
			var neutral := target_skeleton.get_bone_pose_rotation(bone_index)
			animation.rotation_track_insert_key(track, 0.0, neutral)
			animation.rotation_track_insert_key(track, animation.length, neutral)
		mapped += 1
	var hips_index := target_skeleton.find_bone("Hips")
	if hips_index >= 0:
		var hip_track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(hip_track, NodePath("%s:Hips" % spec[2]))
		var neutral_hips := target_skeleton.get_bone_pose_position(hips_index)
		animation.position_track_insert_key(hip_track, 0.0, neutral_hips)
		animation.position_track_insert_key(hip_track, animation.length, neutral_hips)
	# Mixamo placed the actor's overall pose and motion on the animated
	# armature node. Its scale is 100, while its bone positions are 1/100 of
	# the target GLB. Copying only bone rotations discards the CPR body pose.
	if not _copy_armature_motion(animation, source_animation, source_skeleton, str(spec[3]), str(spec[4]) == "sleeping_idle"):
		push_error("CPR animated armature transform missing: " + str(spec[0]))
		source_root.free()
		target_root.free()
		return false
	# The saved comparison scene contains a manually adjusted Skeleton3D node
	# transform. Neutralize it during this independent CPR clip, not in the scene.
	var skeleton_position := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(skeleton_position, NodePath(str(spec[2])))
	animation.position_track_insert_key(skeleton_position, 0.0, Vector3.ZERO)
	animation.position_track_insert_key(skeleton_position, animation.length, Vector3.ZERO)
	var skeleton_rotation := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(skeleton_rotation, NodePath(str(spec[2])))
	animation.rotation_track_insert_key(skeleton_rotation, 0.0, Quaternion.IDENTITY)
	animation.rotation_track_insert_key(skeleton_rotation, animation.length, Quaternion.IDENTITY)
	animation.set_meta("source_fbx", str(spec[0]))
	animation.set_meta("source_action_range", Vector2i(1, 260) if str(spec[4]) != "sleeping_idle" else Vector2i(1, roundi(animation.length * 30.0) + 1))
	animation.set_meta("source_fps", 30.0)
	animation.set_meta("retarget_mode", "Godot-imported local keys; rest/hierarchy-verified shared Humanizer bones")
	animation.set_meta("bone_set", "all matching non-root bones; receiver ponytail source keys retained")
	animation.set_meta("root_owner", "source animated armature, with source local placement preserved" if str(spec[4]) == "sleeping_idle" else "source animated armature, with horizontal start rebased to actor staging root")
	animation.set_meta("loop_mode_note", "looping sleeping idle" if str(spec[4]) == "sleeping_idle" else "non-looping CPR action")
	animation.set_meta("quaternion_sign_continuity", true)
	var library := AnimationLibrary.new()
	if library.add_animation(spec[4] as StringName, animation) != OK:
		source_root.free()
		target_root.free()
		push_error("Cannot add CPR animation")
		return false
	var save_error := ResourceSaver.save(library, str(spec[5]))
	source_root.free()
	target_root.free()
	if save_error != OK:
		push_error("Cannot save CPR library: " + str(spec[5]))
		return false
	print("IKEA_CPR_BAKE_OK source=", spec[0], " target=", spec[2], " animated=", animated, " shared=", mapped, " tracks=", animation.get_track_count(), " length=", animation.length)
	return true

func _copy_armature_motion(output: Animation, source: Animation, source_skeleton: Skeleton3D, target_child: String, preserve_horizontal_start := false) -> bool:
	var rotation_source := -1
	var position_source := -1
	for track in source.get_track_count():
		var path := str(source.track_get_path(track))
		if path.contains("/") or path.contains(":"):
			continue
		if source.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			rotation_source = track
		elif source.track_get_type(track) == Animation.TYPE_POSITION_3D:
			position_source = track
	if rotation_source < 0 or position_source < 0:
		return false
	var root_index := source_skeleton.find_bone("Root")
	if root_index < 0:
		return false
	var root_rest := source_skeleton.get_bone_rest(root_index).basis.get_rotation_quaternion()
	var rotation_target := output.add_track(Animation.TYPE_ROTATION_3D)
	output.track_set_path(rotation_target, NodePath(target_child))
	var previous := Quaternion.IDENTITY
	for key_index in source.track_get_key_count(rotation_source):
		var rotation := ((source.track_get_key_value(rotation_source, key_index) as Quaternion) * root_rest).normalized()
		if key_index > 0 and previous.dot(rotation) < 0.0:
			rotation = -rotation
		output.rotation_track_insert_key(rotation_target, source.track_get_key_time(rotation_source, key_index), rotation)
		previous = rotation
	var start_position := source.track_get_key_value(position_source, 0) as Vector3
	var position_target := output.add_track(Animation.TYPE_POSITION_3D)
	output.track_set_path(position_target, NodePath(target_child))
	for key_index in source.track_get_key_count(position_source):
		var position := source.track_get_key_value(position_source, key_index) as Vector3
		# Keep Mixamo's floor height and vertical compression while removing
		# arbitrary horizontal placement inside its download scene.
		if not preserve_horizontal_start:
			position.x -= start_position.x
			position.z -= start_position.z
		output.position_track_insert_key(position_target, source.track_get_key_time(position_source, key_index), position)
	output.set_meta("source_armature_start_position", start_position)
	return true

func _source_rotation_tracks(animation: Animation) -> Dictionary:
	var result := {}
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var path := str(animation.track_get_path(track))
		if not path.contains("/Skeleton3D:"):
			continue
		result[path.get_slice(":", 1)] = track
	return result

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
