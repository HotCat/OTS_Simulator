extends SceneTree

## Convert a godot-pose-motion-cache JSON file into a native AnimationLibrary.
## The baker accepts both rest-relative pose rotations and absolute local
## rotations in the imported GLB basis. Native tracks consume final absolute
## parent-local rotations; legacy rest-relative values are composed with the
## imported rest quaternion. Rich bone entries may also carry local position
## samples, but those are intentionally ignored here; root motion is
## represented by the character node track.

# The base scene is only used for absolute root-position keys. Bone tracks are
# local to IK_character/Skeleton3D and therefore remain reusable on another
# instance of the same rig. Keep the historical manual-rig default for walk
# clips, and pass the active scene explicitly when baking a scene-bound clip.
const DEFAULT_BASE_SCENE := "res://demos/my_manual_rig_pose.tscn"
var _base_scene_path := DEFAULT_BASE_SCENE
var _rotation_space := ""
var _rest_rotations: Dictionary = {}

func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() < 2:
		_fail("Usage: Godot --headless --path . --script res://tools/bake_motion_cache.gd -- <cache.json> <library.tres> [base-scene.tscn]")
		return
	var cache_path := _globalize(arguments[0])
	var output_path := arguments[1]
	if arguments.size() >= 3:
		_base_scene_path = arguments[2]
		if not _base_scene_path.begins_with("res://"):
			_base_scene_path = _globalize(_base_scene_path)
	var file := FileAccess.open(cache_path, FileAccess.READ)
	if file == null:
		_fail("Cannot open motion cache: %s" % cache_path)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_fail("Motion cache is not a JSON object: %s" % cache_path)
		return
	var cache := parsed as Dictionary
	_rotation_space = str(cache.get("rotation_space", ""))
	if _rotation_space not in ["godot4_rest_relative_local_pose", "godot4_absolute_local_bone_pose"]:
		_fail("Refusing to bake an unsupported bone rotation space: %s" % _rotation_space)
		return
	_load_rest_rotations()
	var frames_value = cache.get("frames", [])
	if not frames_value is Array or frames_value.is_empty():
		_fail("Motion cache contains no frames")
		return
	var frames := frames_value as Array
	var clip_value = cache.get("clip", {})
	var clip := clip_value as Dictionary if clip_value is Dictionary else {}
	var is_cycle := str(clip.get("kind", "")) == "looping_gait_cycle"
	var default_animation_name := "female_collapse_motion" if str(cache.get("source_video", "")).contains("collapse") else "female_walk_linear"
	var animation_name := StringName(str(clip.get("animation_name", default_animation_name)))
	var fps := float(cache.get("fps", 30.0))
	if fps <= 0.0:
		_fail("Motion cache FPS must be positive")
		return
	var animation := Animation.new()
	animation.resource_name = str(animation_name)
	animation.length = frames.size() / fps
	animation.loop_mode = Animation.LOOP_LINEAR if is_cycle else Animation.LOOP_NONE
	animation.step = 1.0 / fps

	var first_frame = frames[0]
	if not first_frame is Dictionary:
		_fail("Motion cache frame zero is not an object")
		return
	for bone_name_value in (first_frame as Dictionary):
		var bone_name := str(bone_name_value)
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("IK_character/Skeleton3D:%s" % bone_name))
		animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
		for frame_index in frames.size():
			var frame = frames[frame_index]
			if not frame is Dictionary:
				continue
			var values = (frame as Dictionary).get(bone_name, [])
			var quaternion: Variant = _bone_quaternion(values, bone_name)
			if quaternion != null:
				animation.rotation_track_insert_key(
					track,
					frame_index / fps,
					quaternion
				)
		if is_cycle:
			var values = (frames[0] as Dictionary).get(bone_name, [])
			var quaternion: Variant = _bone_quaternion(values, bone_name)
			if quaternion == null:
				continue
			animation.rotation_track_insert_key(
				track, animation.length,
				quaternion
			)

	var root_value = cache.get("root_motion", {})
	if root_value is Dictionary:
		if is_cycle:
			_bake_cycle_vertical_track(animation, root_value as Dictionary, frames.size(), fps)
		else:
			_bake_root_tracks(animation, root_value as Dictionary, frames.size(), fps)
	var library := AnimationLibrary.new()
	library.add_animation(animation_name, animation)
	var error := ResourceSaver.save(library, output_path)
	if error != OK:
		_fail("ResourceSaver failed for %s with error %d" % [output_path, error])
		return
	print("Baked %d frames, %d tracks, %.3f seconds to %s" % [
		frames.size(), animation.get_track_count(), animation.length, output_path,
	])
	quit(0)


func _bake_cycle_vertical_track(animation: Animation, root: Dictionary,
		frame_count: int, fps: float) -> void:
	var positions = root.get("positions", [])
	if not positions is Array or positions.size() != frame_count:
		return
	var base := _scene_node_position("IK_character/Skeleton3D")
	var track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(track, NodePath("IK_character/Skeleton3D"))
	animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
	for frame_index in frame_count:
		var vertical := float(positions[frame_index][1])
		animation.position_track_insert_key(
			track, frame_index / fps, base + Vector3(0.0, vertical, 0.0)
		)
	var first_vertical := float(positions[0][1])
	animation.position_track_insert_key(
		track, animation.length, base + Vector3(0.0, first_vertical, 0.0)
	)


func _bake_root_tracks(animation: Animation, root: Dictionary,
		frame_count: int, fps: float) -> void:
	var positions = root.get("positions", [])
	var directions = root.get("heading_directions", [])
	var yaws = root.get("rotation_y", [])
	var local_forward := _vec3(root.get("local_forward", [0.0, 0.0, -1.0]), Vector3.FORWARD)
	local_forward.y = 0.0
	if local_forward.is_zero_approx():
		local_forward = Vector3.FORWARD
	local_forward = local_forward.normalized()
	var origin := _scene_node_position("IK_character")
	if not str(root.get("scene_origin_node", "")).is_empty():
		origin = _trajectory_origin(str(root.get("scene_origin_node", "")))
	# JSON stores an absent optional ground override as null. Godot 4.7 no
	# longer accepts float(null), so only coerce an actual numeric override.
	var ground_y = root.get("ground_y")
	if ground_y is float or ground_y is int:
		origin.y = float(ground_y)
	if positions is Array and positions.size() == frame_count:
		var position_track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(position_track, NodePath("IK_character"))
		animation.track_set_interpolation_type(position_track, Animation.INTERPOLATION_LINEAR)
		for frame_index in frame_count:
			animation.position_track_insert_key(
				position_track, frame_index / fps,
				origin + _vec3(positions[frame_index], Vector3.ZERO)
			)
	var should_bake_rotation := false
	if directions is Array and directions.size() == frame_count:
		should_bake_rotation = true
	elif yaws is Array and yaws.size() == frame_count:
		for yaw in yaws:
			if absf(float(yaw)) > 0.000001:
				should_bake_rotation = true
				break
	if should_bake_rotation:
		var rotation_track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(rotation_track, NodePath("IK_character"))
		animation.track_set_interpolation_type(rotation_track, Animation.INTERPOLATION_LINEAR)
		for frame_index in frame_count:
			var rotation := Quaternion.IDENTITY
			if directions is Array and directions.size() == frame_count:
				var desired := _vec3(directions[frame_index], Vector3.FORWARD)
				desired.y = 0.0
				if not desired.is_zero_approx():
					rotation = Quaternion(Vector3.UP, local_forward.signed_angle_to(desired.normalized(), Vector3.UP))
			elif yaws is Array and yaws.size() == frame_count:
				rotation = Quaternion(Vector3.UP, float(yaws[frame_index]))
			animation.rotation_track_insert_key(rotation_track, frame_index / fps, rotation.normalized())

func _bone_quaternion(value: Variant, bone_name: String) -> Variant:
	var values = value.get("rotation_quaternion", []) if value is Dictionary else value
	if values is Array and values.size() >= 4:
		var quaternion := Quaternion(float(values[0]), float(values[1]), float(values[2]), float(values[3])).normalized()
		if _rotation_space == "godot4_rest_relative_local_pose":
			# Legacy caches may store a delta from the imported rest pose. Native
			# Animation tracks and Skeleton3D setters consume the final absolute
			# parent-local rotation, so restore the target GLB rest basis here.
			var rest: Quaternion = _rest_rotations.get(bone_name, Quaternion.IDENTITY)
			quaternion = (rest * quaternion).normalized()
		return quaternion
	return null

func _load_rest_rotations() -> void:
	_rest_rotations.clear()
	var scene := load(_base_scene_path) as PackedScene
	if scene == null:
		return
	var root := scene.instantiate()
	var skeleton := root.get_node_or_null(NodePath("IK_character/Skeleton3D")) as Skeleton3D
	if skeleton != null:
		for bone_index in skeleton.get_bone_count():
			var bone_name := skeleton.get_bone_name(bone_index)
			var rest := skeleton.get_bone_rest(bone_index)
			_rest_rotations[bone_name] = rest.basis.get_rotation_quaternion()
	root.free()


func _trajectory_origin(path_string: String) -> Vector3:
	if path_string.is_empty():
		return Vector3.ZERO
	var scene := load(_base_scene_path) as PackedScene
	if scene == null:
		return Vector3.ZERO
	var root := scene.instantiate()
	var marker := root.get_node_or_null(NodePath(path_string)) as Node3D
	var result := marker.position if marker != null else Vector3.ZERO
	if marker != null and marker.get_parent() is Node3D:
		result = (marker.get_parent() as Node3D).transform * marker.position
	root.free()
	return result


func _scene_node_position(path_string: String) -> Vector3:
	var scene := load(_base_scene_path) as PackedScene
	if scene == null:
		return Vector3.ZERO
	var root := scene.instantiate()
	var node := root.get_node_or_null(NodePath(path_string)) as Node3D
	var result := node.position if node != null else Vector3.ZERO
	root.free()
	return result


func _vec3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback


func _globalize(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") else path


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
