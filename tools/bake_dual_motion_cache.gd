extends SceneTree

## Bake the usable tail of the captured male gait into one AnimationLibrary.
## The carried female intentionally has no tracks: the OTS scene attaches her
## saved static FK pose to the carrier's shoulder instead.

const ANIMATION_NAME := &"ots_carry_captured"
const ROTATION_SPACE := "godot4_absolute_local_bone_pose"
const BASE_SCENE := "res://demos/ots_carry_clay_proxy.tscn"
## The base-pose lookup starts at the shot root, while animation tracks are
## relative to the AnimationPlayer's MaleCarrier parent. Keeping these paths
## separate makes it structurally impossible for this library to resolve to
## IK_character, even though both actors use familiar humanoid bone names.
const MALE_SCENE_SKELETON_PATH := "ManualCarryBlock/MaleCarrier/Skeleton3D"
const MALE_ANIMATION_TRACK_SKELETON_PATH := "Skeleton3D"
const CLIP_START_SECONDS := 4.32
const MALE_CAPTURED_BONES := {
	"Hips": true,
	"LeftUpperLeg": true,
	"LeftLowerLeg": true,
	"LeftFoot": true,
	"RightUpperLeg": true,
	"RightLowerLeg": true,
	"RightFoot": true,
	"Spine": true,
	"Chest": true,
	"UpperChest": true,
	"Neck": true,
	"Head": true,
}

func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() < 3:
		_fail("Usage: Godot --headless --path . --script res://tools/bake_dual_motion_cache.gd -- <male-cache.json> <female-cache.json> <library.tres>")
		return
	var male := _load_cache(arguments[0])
	if male.is_empty():
		return
	var male_frames := male.get("frames", []) as Array
	var fps := float(male.get("fps", 0.0))
	var source_end_seconds := (male_frames.size() - 1) / fps if fps > 0.0 else 0.0
	if fps <= 0.0 or male_frames.size() < 2 or CLIP_START_SECONDS >= source_end_seconds:
		_fail("Male cache does not extend beyond the requested 4.32-second start")
		return
	var clip_length := source_end_seconds - CLIP_START_SECONDS
	var animation := Animation.new()
	animation.resource_name = str(ANIMATION_NAME)
	animation.length = clip_length
	animation.step = 1.0 / fps
	animation.loop_mode = Animation.LOOP_NONE
	var base_scene := load(BASE_SCENE) as PackedScene
	if base_scene == null:
		_fail("Cannot load authored carry scene: %s" % BASE_SCENE)
		return
	var base_root := base_scene.instantiate()
	var male_base := _capture_base_pose(base_root, MALE_SCENE_SKELETON_PATH)
	if male_base.is_empty():
		base_root.free()
		_fail("Could not read the authored male carry skeleton")
		return
	_add_tail_delta_tracks(animation, male_frames, fps, MALE_ANIMATION_TRACK_SKELETON_PATH,
		male_base, MALE_CAPTURED_BONES)
	base_root.free()
	var library := AnimationLibrary.new()
	library.add_animation(ANIMATION_NAME, animation)
	var error := ResourceSaver.save(library, arguments[2])
	if error != OK:
		_fail("ResourceSaver failed for %s with error %d" % [arguments[2], error])
		return
	print("Baked male-only OTS carry tail: source %.3f-%.3f, %d tracks, %.3f seconds; female tracks=0" % [
		CLIP_START_SECONDS, source_end_seconds, animation.get_track_count(), animation.length,
	])
	quit(0)

func _load_cache(path_string: String) -> Dictionary:
	var path := ProjectSettings.globalize_path(path_string) if path_string.begins_with("res://") else path_string
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("Cannot open motion cache: %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_fail("Motion cache is not a JSON object: %s" % path)
		return {}
	var cache := parsed as Dictionary
	if str(cache.get("rotation_space", "")) != ROTATION_SPACE:
		_fail("Cache must use %s: %s" % [ROTATION_SPACE, path])
		return {}
	return cache

func _capture_base_pose(root: Node, skeleton_path: String) -> Dictionary:
	var result := {}
	var skeleton := root.get_node_or_null(NodePath(skeleton_path)) as Skeleton3D
	if skeleton == null:
		return result
	for bone_index in skeleton.get_bone_count():
		result[str(skeleton.get_bone_name(bone_index))] = skeleton.get_bone_pose_rotation(bone_index)
	return result

func _add_tail_delta_tracks(animation: Animation, frames: Array, fps: float,
		skeleton_path: String, base_pose: Dictionary, allowed_bones: Dictionary) -> void:
	if frames.is_empty() or not frames[0] is Dictionary:
		return
	var exact_start_frame := CLIP_START_SECONDS * fps
	var start_frame_a := floori(exact_start_frame)
	var start_frame_b := ceili(exact_start_frame)
	var start_alpha := exact_start_frame - start_frame_a
	for bone_name_value in (frames[0] as Dictionary):
		var bone_name := str(bone_name_value)
		if not allowed_bones.has(bone_name) or not base_pose.has(bone_name):
			continue
		var start_a: Variant = _quaternion((frames[start_frame_a] as Dictionary).get(bone_name, []))
		var start_b: Variant = _quaternion((frames[start_frame_b] as Dictionary).get(bone_name, []))
		if start_a == null or start_b == null:
			continue
		# 4.32 seconds falls between source frames 103 and 104. Use the exact
		# interpolated pose as the zero-delta reference so the authored carry
		# pose is preserved at editor time 0 without a one-frame jump.
		var captured_start := (start_a as Quaternion).slerp(start_b as Quaternion, start_alpha).normalized()
		var authored_base := (base_pose[bone_name] as Quaternion).normalized()
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("%s:%s" % [skeleton_path, bone_name]))
		animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
		animation.rotation_track_insert_key(track, 0.0, authored_base)
		# Preserve every captured frame after the sub-frame clip boundary and
		# shift its timestamp so the AnimationPlayer timeline begins at zero.
		for frame_index in range(start_frame_b, frames.size()):
			var frame = frames[frame_index]
			if not frame is Dictionary:
				continue
			var captured: Variant = _quaternion((frame as Dictionary).get(bone_name, []))
			if captured != null:
				var delta := (captured_start.inverse() * (captured as Quaternion)).normalized()
				animation.rotation_track_insert_key(
					track, frame_index / fps - CLIP_START_SECONDS, (authored_base * delta).normalized()
				)

func _quaternion(values: Variant) -> Variant:
	if values is Array and values.size() >= 4:
		return Quaternion(float(values[0]), float(values[1]), float(values[2]), float(values[3])).normalized()
	return null

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
