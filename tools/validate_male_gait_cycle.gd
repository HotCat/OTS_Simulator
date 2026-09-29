extends SceneTree

## Lightweight regression check for the independent H3 heavy-load gait clip.
## It confirms the new library is mounted in the OTS scene, the track paths
## target MaleCarrier only, the clip loops, and its endpoint returns to frame 0.

const SCENE_PATH := "res://demos/ots_carry_clay_proxy.tscn"
const EPSILON := 0.0001


func _initialize() -> void:
	var hybrid_animation := _validate_library(
		"res://animations/ots_h3_heavy_load_walk_hybrid.tres", &"ots_h3_heavy_load_walk_hybrid")
	var scene := load(SCENE_PATH) as PackedScene
	var root := scene.instantiate()
	var player := root.get_node("OTSCarryAnimationPlayer") as AnimationPlayer
	if not player.has_animation("h3_heavy_load_hybrid/ots_h3_heavy_load_walk_hybrid"):
		_fail("hybrid H3 gait library is not mounted on OTSCarryAnimationPlayer")
		return
	print("MALE_GAIT_CYCLE_VALID hybrid_tracks=%d hybrid_length=%.3f mounted=true" % [
		hybrid_animation.get_track_count(), hybrid_animation.length,
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
		if animation.track_get_type(track) != Animation.TYPE_ROTATION_3D:
			_fail("gait contains a non-rotation track: %s" % name)
		var track_path := str(animation.track_get_path(track))
		if not track_path.begins_with("ManualCarryBlock/MaleCarrier/Skeleton3D:"):
			_fail("track targets the wrong character: %s" % track_path)
		var count := animation.track_get_key_count(track)
		if count < 2:
			_fail("track has too few keys: %s" % track_path)
		var first := animation.track_get_key_value(track, 0) as Quaternion
		var last := animation.track_get_key_value(track, count - 1) as Quaternion
		if 1.0 - absf(first.normalized().dot(last.normalized())) > EPSILON:
			_fail("loop endpoint is not equal to frame 0: %s" % track_path)
	return animation


func _fail(message: String) -> void:
	push_error("MALE_GAIT_CYCLE_INVALID: " + message)
	quit(1)
