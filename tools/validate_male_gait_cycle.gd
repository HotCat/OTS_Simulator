extends SceneTree

## Lightweight regression checks for independent male gait clips.
## It confirms the H3 comparison clip and the Godot-direct Mixamo loop are
## mounted in the OTS scene, target MaleCarrier only, loop, and close at frame 0.

const SCENE_PATH := "res://demos/ots_carry_clay_proxy.tscn"
const EPSILON := 0.0001
const BASELINE_UPPER_BONES := ["Spine", "Chest", "UpperChest", "Neck", "Head"]


func _initialize() -> void:
	var hybrid_animation := _validate_library(
		"res://animations/ots_h3_heavy_load_walk_hybrid.tres", &"ots_h3_heavy_load_walk_hybrid")
	var hybrid_smooth_animation := _validate_library(
		"res://animations/ots_h3_heavy_load_walk_hybrid_smooth.tres", &"ots_h3_heavy_load_walk_hybrid_smooth")
	var mixamo_animation := _validate_library(
		"res://animations/mixamo_walking_male_godot_direct.tres", &"mixamo_walking_male_godot_direct_loop")
	var scene := load(SCENE_PATH) as PackedScene
	var root := scene.instantiate()
	var player := root.get_node("OTSCarryAnimationPlayer") as AnimationPlayer
	if not player.has_animation("h3_heavy_load_hybrid/ots_h3_heavy_load_walk_hybrid"):
		_fail("hybrid H3 gait library is not mounted on OTSCarryAnimationPlayer")
		return
	if not player.has_animation("h3_heavy_load_hybrid_smooth/ots_h3_heavy_load_walk_hybrid_smooth"):
		_fail("smoothed H3 gait library is not mounted on OTSCarryAnimationPlayer")
		return
	if not player.has_animation("mixamo_walking_male_godot_direct/mixamo_walking_male_godot_direct_loop"):
		_fail("Mixamo gait library is not mounted on OTSCarryAnimationPlayer")
		return
	# The calibrated Mixamo replacement carries the source Root/Hips rotation
	# deltas as well as six leg rotations, Hips bob, and RootMotionSampler. Older
	# direct-only resources had eight tracks; accept both while requiring the
	# travelling channels and the calibration marker on the current resource.
	if mixamo_animation.get_track_count() < 8:
		_fail("Mixamo direct loop is missing lower-body/root-motion tracks")
	if not mixamo_animation.has_meta("ots_retarget_base_scene") and not mixamo_animation.has_meta("ots_direct_godot_tracks"):
		_fail("Mixamo direct loop has no retarget provenance metadata")
	if hybrid_smooth_animation.get_track_count() != 12:
		_fail("baseline-upper H3 clip must contain seven lower-body plus five torso tracks")
		return
	for track in hybrid_smooth_animation.get_track_count():
		var smooth_path := str(hybrid_smooth_animation.track_get_path(track))
		var smooth_bone := smooth_path.get_slice(":", 1)
		if smooth_bone in ["LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
				"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]:
			_fail("baseline-upper H3 clip retained a noisy arm track: %s" % smooth_path)
		if track >= 7 and not BASELINE_UPPER_BONES.has(smooth_bone):
			_fail("unexpected baseline upper-body track: %s" % smooth_path)
	if not _loop_endpoint_matches(hybrid_smooth_animation):
		_fail("smoothed H3 clip loop endpoint is not closed")
		return
	if int(hybrid_smooth_animation.get_meta("ots_cycle_seam_frame", -1)) != 6:
		_fail("smoothed H3 clip seam was not relocated to the measured foot-contact frame")
		return
	print("MALE_GAIT_CYCLE_VALID hybrid_tracks=%d hybrid_length=%.3f smooth_tracks=%d smooth_length=%.3f mixamo_tracks=%d mixamo_length=%.3f mounted=true" % [
		hybrid_animation.get_track_count(), hybrid_animation.length,
		hybrid_smooth_animation.get_track_count(), hybrid_smooth_animation.length,
		mixamo_animation.get_track_count(), mixamo_animation.length,
	])
	root.free()
	quit(0)


func _validate_library(path: String, name: StringName) -> Animation:
	var library := load(path) as AnimationLibrary
	if library == null or not library.has_animation(name):
		_fail("missing gait library or animation: %s/%s" % [path, name])
	var animation := library.get_animation(name)
	if animation.loop_mode != Animation.LOOP_LINEAR:
		_fail("gait is not configured as a linear loop: %s" % name)
	if animation.get_track_count() <= 0:
		_fail("gait has no bone tracks: %s" % name)
	for track in animation.get_track_count():
		var track_path := str(animation.track_get_path(track))
		var is_root_motion := track_path == "RootMotionSampler:position"
		if not is_root_motion and not track_path.begins_with("ManualCarryBlock/MaleCarrier/Skeleton3D:"):
			_fail("track targets the wrong character: %s" % track_path)
		var track_type := animation.track_get_type(track)
		if track_type != Animation.TYPE_ROTATION_3D and track_type != Animation.TYPE_POSITION_3D:
			_fail("gait contains an unsupported track type: %s" % track_path)
		if track_type == Animation.TYPE_POSITION_3D and not track_path.ends_with(":Hips") and not is_root_motion:
			_fail("only Hips may have a position track: %s" % track_path)
		var count := animation.track_get_key_count(track)
		if count < 2:
			_fail("track has too few keys: %s" % track_path)
		if track_type == Animation.TYPE_ROTATION_3D:
			var first := animation.track_get_key_value(track, 0) as Quaternion
			var last := animation.track_get_key_value(track, count - 1) as Quaternion
			if 1.0 - absf(first.normalized().dot(last.normalized())) > EPSILON:
				_fail("loop endpoint is not equal to frame 0: %s" % track_path)
		elif not is_root_motion:
			var first_position := animation.track_get_key_value(track, 0) as Vector3
			var last_position := animation.track_get_key_value(track, count - 1) as Vector3
			if first_position.distance_to(last_position) > EPSILON:
				_fail("position loop endpoint is not equal to frame 0: %s" % track_path)
	return animation


func _loop_endpoint_matches(animation: Animation) -> bool:
	for track in animation.get_track_count():
		var key_count := animation.track_get_key_count(track)
		if key_count < 2:
			continue
		var first = animation.track_get_key_value(track, 0)
		var last = animation.track_get_key_value(track, key_count - 1)
		if first is Quaternion and last is Quaternion:
			if absf((first as Quaternion).dot(last as Quaternion)) < 0.9999:
				return false
		elif first is Vector3 and last is Vector3:
			if (first as Vector3).distance_to(last as Vector3) > EPSILON:
				return false
	return true


func _fail(message: String) -> void:
	push_error("MALE_GAIT_CYCLE_INVALID: " + message)
	quit(1)
