extends SceneTree

## Build a seam-safe loop variant from the Godot-imported Mixamo gait.
## Rotation endpoints are blended toward a shared seam pose over a short
## window.  RootMotionSampler remains cumulative; its wrap is consumed by the
## carrier trajectory and must not be averaged across the travel distance.

const LIBRARY_PATH := "res://animations/mixamo_walking_male_godot_direct.tres"
const SOURCE_NAME := &"mixamo_walking_male_godot_direct"
const LOOP_NAME := &"mixamo_walking_male_godot_direct_loop"
const SEAM_FRAMES := 6

func _initialize() -> void:
	var library := load(LIBRARY_PATH) as AnimationLibrary
	if library == null:
		push_error("cannot load %s" % LIBRARY_PATH)
		quit(1)
		return
	var source := library.get_animation(SOURCE_NAME)
	if source == null:
		push_error("missing source animation %s" % SOURCE_NAME)
		quit(1)
		return
	var looped := source.duplicate(true) as Animation
	looped.resource_name = str(LOOP_NAME)
	looped.loop_mode = Animation.LOOP_LINEAR
	var changed_tracks := 0
	for track in looped.get_track_count():
		if looped.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			continue
		var key_count := looped.track_get_key_count(track)
		if key_count < 2:
			continue
		var seam := (looped.track_get_key_value(track, 0) as Quaternion).slerp(
			looped.track_get_key_value(track, key_count - 1) as Quaternion, 0.5).normalized()
		var window := mini(SEAM_FRAMES, key_count / 2)
		for offset in window:
			var weight := float(window - offset) / float(window)
			var start := looped.track_get_key_value(track, offset) as Quaternion
			var end_index := key_count - 1 - offset
			var finish := looped.track_get_key_value(track, end_index) as Quaternion
			looped.track_set_key_value(track, offset, start.slerp(seam, weight).normalized())
			looped.track_set_key_value(track, end_index, finish.slerp(seam, weight).normalized())
		# Make the loop boundary exact after the blend. This is deliberately done
		# for rotations only; root translation must retain its cycle displacement.
		looped.track_set_key_value(track, key_count - 1, looped.track_get_key_value(track, 0))
		changed_tracks += 1
	looped.set_meta("ots_cycle_kind", "mixamo_godot_direct_loop")
	looped.set_meta("ots_cycle_seam_method", "six-frame quaternion seam blend")
	looped.set_meta("ots_cycle_seam_blend_frames", SEAM_FRAMES)
	looped.set_meta("ots_root_motion_stride_scale", source.get_meta("ots_root_motion_stride_scale", 1.0))
	if library.has_animation(LOOP_NAME):
		library.remove_animation(LOOP_NAME)
	var error := library.add_animation(LOOP_NAME, looped)
	if error != OK:
		push_error("failed to add loop animation: %d" % error)
		quit(1)
		return
	var save_error := ResourceSaver.save(library, LIBRARY_PATH)
	if save_error != OK:
		push_error("failed to save loop library: %d" % save_error)
		quit(1)
		return
	print("MIXAMO_DIRECT_LOOP_OK tracks=%d length=%.3f seam_frames=%d output=%s" % [
		changed_tracks, looped.length, SEAM_FRAMES, LIBRARY_PATH])
	quit(0)
