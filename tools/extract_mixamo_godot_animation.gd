extends SceneTree

## Extract lower-body/root tracks after Godot has imported the Mixamo FBX.
## Godot has already converted the source axes, so no Blender quaternion
## conversion is needed here. The OTS carrier's authored Hips orientation is
## pinned explicitly, then the complete source lower-body chain is copied in
## the same Godot local frame. Leaving Hips implicit while rebasing only upper
## legs mixes parent frames and produced the severe right-foot toe-out.

## Source is the deliberately slowed Mixamo Standard Walk export. Keep the
## output names stable so existing scene/API references are replaced in place.
const SOURCE_ANIMATION := "res://assets/downloads/Standard Walk.fbx"
const OUTPUT_LIBRARY := "res://animations/mixamo_walking_male_godot_direct.tres"
const OUTPUT_ANIMATION := &"mixamo_walking_male_godot_direct"
const LOOP_ANIMATION := &"mixamo_walking_male_godot_direct_loop"
const TARGET_SKELETON := "ManualCarryBlock/MaleCarrier/Skeleton3D"
const SEAM_BLEND_FRAMES := 6

const LOWER_BONES := [
	&"LeftUpperLeg", &"LeftLowerLeg", &"LeftFoot",
	&"RightUpperLeg", &"RightLowerLeg", &"RightFoot",
]
const UPPER_LEG_BONES := [&"LeftUpperLeg", &"RightUpperLeg"]
# The Mixamo source and the OTS clay scene use the same skeleton dimensions,
# but their authored carrier roots sit on slightly different floor planes.  A
# small pelvis translation is preferable to moving MaleCarrier itself: the
# trajectory, camera target, and route remain unchanged, while the carried
# female and hand contacts continue to follow the evaluated male skeleton.
const OTS_GROUND_OFFSET := Vector3(0.0, -0.06, 0.0)

func _initialize() -> void:
	var source_scene := load(SOURCE_ANIMATION) as PackedScene
	if source_scene == null:
		_fail("cannot load source animation: %s" % SOURCE_ANIMATION)
		return
	var source_root := source_scene.instantiate()
	var source_player := _find_animation_player(source_root)
	if source_player == null:
		_fail("source GLB has no AnimationPlayer")
		return
	var source_names := source_player.get_animation_library_list()
	if source_names.is_empty():
		_fail("source GLB has no animation library")
		return
	var source_library := source_player.get_animation_library(source_names[0])
	var source_animation_names := source_library.get_animation_list()
	if source_animation_names.is_empty():
		_fail("source GLB animation library is empty")
		return
	var source_animation := source_library.get_animation(source_animation_names[0])
	var target_scene := load("res://demos/ots_carry_clay_proxy.tscn") as PackedScene
	var target_root := target_scene.instantiate() if target_scene != null else null
	var target_skeleton := target_root.get_node_or_null(TARGET_SKELETON) as Skeleton3D if target_root != null else null
	var authored_pose: Dictionary = {}
	if target_skeleton != null:
		for bone_name in LOWER_BONES + [&"Hips"]:
			var bone_index := target_skeleton.find_bone(bone_name)
			if bone_index >= 0:
				authored_pose[bone_name] = target_skeleton.get_bone_pose_rotation(bone_index)
	var result := Animation.new()
	result.resource_name = str(OUTPUT_ANIMATION)
	result.length = source_animation.length
	result.step = source_animation.step
	result.loop_mode = Animation.LOOP_LINEAR
	var hips_index := target_skeleton.find_bone("Hips") if target_skeleton != null else -1

	var lower_count := 0
	var root_source_track := -1
	for source_track in source_animation.get_track_count():
		var path := str(source_animation.track_get_path(source_track))
		var bone := _bone_name(path)
		if bone in LOWER_BONES:
			var target_track := _copy_track(source_animation, source_track, result,
				NodePath("%s:%s" % [TARGET_SKELETON, bone]),
				Quaternion.IDENTITY)
			if target_track >= 0:
				lower_count += 1
		elif path == "male_1785818633452_humanizer_proxy_Humanizer_RealtimeProxy":
			if source_animation.track_get_type(source_track) == Animation.TYPE_POSITION_3D:
				root_source_track = source_track

	# Keep the authored OTS pelvis rotation explicit. This is the parent frame
	# for both upper legs; without this key the source local tracks are evaluated
	# against whichever stale pose the editor last left on the Skeleton3D.
	if target_skeleton != null and authored_pose.has(&"Hips"):
		var hips_rotation_track := result.add_track(Animation.TYPE_ROTATION_3D)
		result.track_set_path(hips_rotation_track, NodePath("%s:Hips" % TARGET_SKELETON))
		result.track_set_interpolation_type(hips_rotation_track, Animation.INTERPOLATION_LINEAR)
		result.track_set_interpolation_loop_wrap(hips_rotation_track, true)
		var authored_hips := authored_pose[&"Hips"] as Quaternion
		result.rotation_track_insert_key(hips_rotation_track, 0.0, authored_hips)
		result.rotation_track_insert_key(hips_rotation_track, source_animation.length, authored_hips)

	# Keep the authored OTS pelvis position, but explicitly key it so
	# this travelling clip starts on the same walk plane as ots_carry_walk_cycle.
	# Without this track the imported Mixamo ankles are consistently airborne in
	# the OTS scene and the planted-foot solver never acquires a contact anchor.
	if target_skeleton != null and hips_index >= 0:
		var hips_track := result.add_track(Animation.TYPE_POSITION_3D)
		result.track_set_path(hips_track, NodePath("%s:Hips" % TARGET_SKELETON))
		result.track_set_interpolation_type(hips_track, Animation.INTERPOLATION_LINEAR)
		result.track_set_interpolation_loop_wrap(hips_track, true)
		var hips_position := target_skeleton.get_bone_pose_position(hips_index) + OTS_GROUND_OFFSET
		var sample_count := 2
		if source_animation.length > 0.0:
			sample_count = maxi(2, int(ceil(source_animation.length / maxf(source_animation.step, 1.0 / 30.0))) + 1)
		for sample in sample_count:
			var sample_time := minf(float(sample) * source_animation.step, source_animation.length)
			result.position_track_insert_key(hips_track, sample_time, hips_position)

	if root_source_track >= 0:
		var root_track := result.add_track(Animation.TYPE_POSITION_3D)
		result.track_set_path(root_track, NodePath("RootMotionSampler:position"))
		result.track_set_interpolation_type(root_track, Animation.INTERPOLATION_LINEAR)
		result.track_set_interpolation_loop_wrap(root_track, true)
		var first_position := source_animation.track_get_key_value(root_source_track, 0) as Vector3
		for key in source_animation.track_get_key_count(root_source_track):
			var position := source_animation.track_get_key_value(root_source_track, key) as Vector3
			position -= first_position
			position.y = 0.0
			result.position_track_insert_key(root_track,
				source_animation.track_get_key_time(root_source_track, key), position)
		var last_position := source_animation.track_get_key_value(
			root_source_track, source_animation.track_get_key_count(root_source_track) - 1
		) as Vector3
		result.set_meta("ots_root_cycle_displacement", last_position - first_position)

	result.set_meta("ots_source_video", "assets/downloads/Standard Walk.fbx")
	# Keep the historical metadata key for consumers that inspect it, while
	# recording the actual Godot-imported source (this clip is an FBX).
	result.set_meta("ots_source_glb", SOURCE_ANIMATION)
	result.set_meta("ots_godot_axis_conversion", "Godot-imported lower-body local tracks; authored OTS Hips parent frame pinned")
	result.set_meta("ots_root_translation", "RootMotionSampler position consumed by CarrierTrajectory")
	var source_root_speed := _root_speed(source_animation, root_source_track)
	result.set_meta("ots_recommended_speed_mps", source_root_speed)
	# Use one shared time scale for the gait and its root channel.  At the OTS
	# target of 0.78 m/s the controller therefore slows both the leg cadence and
	# root displacement together, keeping foot contacts locked to route advance.
	result.set_meta("ots_root_motion_stride_scale", 1.0)
	result.set_meta("ots_animation_name", str(OUTPUT_ANIMATION))
	result.set_meta("ots_direct_godot_tracks", true)
	result.set_meta("ots_ground_offset", OTS_GROUND_OFFSET)

	var output_library := AnimationLibrary.new()
	var add_error := output_library.add_animation(OUTPUT_ANIMATION, result)
	if add_error != OK:
		_fail("AnimationLibrary.add_animation failed: %d" % add_error)
		return
	var looped := _make_loop_variant(result)
	var loop_error := output_library.add_animation(LOOP_ANIMATION, looped)
	if loop_error != OK:
		_fail("AnimationLibrary.add_animation loop failed: %d" % loop_error)
		return
	var save_error := ResourceSaver.save(output_library, OUTPUT_LIBRARY)
	if save_error != OK:
		_fail("could not save %s: %d" % [OUTPUT_LIBRARY, save_error])
		return
	print("MIXAMO_GODOT_DIRECT_OK lower_tracks=%d root_track=%s length=%.3f loop=%s output=%s" % [
		lower_count, str(root_source_track >= 0), result.length, str(LOOP_ANIMATION), OUTPUT_LIBRARY])
	source_root.free()
	if target_root != null:
		target_root.free()
	quit(0)

func _copy_track(source: Animation, source_track: int, destination: Animation, target_path: NodePath,
		rotation_prefix: Quaternion = Quaternion.IDENTITY) -> int:
	var track_type := source.track_get_type(source_track)
	if track_type != Animation.TYPE_ROTATION_3D:
		return -1
	var destination_track := destination.add_track(track_type)
	destination.track_set_path(destination_track, target_path)
	destination.track_set_interpolation_type(destination_track, source.track_get_interpolation_type(source_track))
	destination.track_set_interpolation_loop_wrap(destination_track, true)
	for key in source.track_get_key_count(source_track):
		destination.rotation_track_insert_key(
			destination_track,
			source.track_get_key_time(source_track, key),
			rotation_prefix * (source.track_get_key_value(source_track, key) as Quaternion))
	return destination_track

func _make_loop_variant(source: Animation) -> Animation:
	var looped := source.duplicate(true) as Animation
	looped.resource_name = str(LOOP_ANIMATION)
	looped.loop_mode = Animation.LOOP_LINEAR
	for track in looped.get_track_count():
		if looped.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var key_count := looped.track_get_key_count(track)
		if key_count < 2:
			continue
		var seam := (looped.track_get_key_value(track, 0) as Quaternion).slerp(
			looped.track_get_key_value(track, key_count - 1) as Quaternion, 0.5).normalized()
		var window := mini(SEAM_BLEND_FRAMES, key_count / 2)
		for offset in window:
			var weight := float(window - offset) / float(window)
			var start := looped.track_get_key_value(track, offset) as Quaternion
			var end_index := key_count - 1 - offset
			var finish := looped.track_get_key_value(track, end_index) as Quaternion
			looped.track_set_key_value(track, offset, start.slerp(seam, weight).normalized())
			looped.track_set_key_value(track, end_index, finish.slerp(seam, weight).normalized())
		looped.track_set_key_value(track, key_count - 1, looped.track_get_key_value(track, 0))
	looped.set_meta("ots_cycle_kind", "mixamo_godot_direct_loop")
	looped.set_meta("ots_cycle_seam_method", "six-frame quaternion seam blend")
	looped.set_meta("ots_cycle_seam_blend_frames", SEAM_BLEND_FRAMES)
	looped.set_meta("ots_root_motion_stride_scale", source.get_meta("ots_root_motion_stride_scale", 1.0))
	return looped

func _root_speed(animation: Animation, track: int) -> float:
	if track < 0 or animation.track_get_key_count(track) < 2:
		return 0.0
	var first := animation.track_get_key_value(track, 0) as Vector3
	var last := animation.track_get_key_value(track, animation.track_get_key_count(track) - 1) as Vector3
	var distance := Vector2(last.x - first.x, last.z - first.z).length()
	var duration := maxf(animation.length, 0.0001)
	return distance / duration

func _bone_name(path: String) -> StringName:
	var colon := path.rfind(":")
	return StringName(path.substr(colon + 1)) if colon >= 0 else StringName()

func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root
	for child in root.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
