extends SceneTree

## Validate that a native AnimationPlayer clip reconstructs the cache's target
## local rotations. Both absolute-local and legacy rest-relative caches are
## accepted; the baker composes the latter with the imported rest basis.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("Usage: ... -- <scene.tscn> <animation-name> <cache.json>")
		quit(1)
		return
	var scene := load(args[0]) as PackedScene
	var root := scene.instantiate()
	root.process_mode = Node.PROCESS_MODE_DISABLED
	var player := root.get_node("FemaleWalkAnimationPlayer") as AnimationPlayer
	var skeleton := root.get_node("IK_character/Skeleton3D") as Skeleton3D
	var cache_file := FileAccess.open(args[2], FileAccess.READ)
	var cache = JSON.parse_string(cache_file.get_as_text())
	var rotation_space := str(cache.get("rotation_space", "godot4_absolute_local_bone_pose"))
	player.play(args[1])
	var worst := 0.0
	var frames: Array = cache["frames"]
	for frame_index in frames.size():
		var frame: Dictionary = frames[frame_index]
		player.seek(float(frame_index) / float(cache["fps"]), true)
		player.advance(0.0)
		for bone_name_value in frame:
			var bone_name := str(bone_name_value)
			var bone_index := skeleton.find_bone(bone_name)
			if bone_index < 0:
				continue
			var values = frame[bone_name]
			if values is Dictionary:
				values = values.get("rotation_quaternion", [])
			if not values is Array or values.size() < 4:
				continue
			var expected := Quaternion(float(values[0]), float(values[1]), float(values[2]), float(values[3])).normalized()
			if rotation_space == "godot4_rest_relative_local_pose":
				expected = (skeleton.get_bone_rest(bone_index).basis.get_rotation_quaternion() * expected).normalized()
			var actual := skeleton.get_bone_pose_rotation(bone_index).normalized()
			var error := rad_to_deg(expected.angle_to(actual))
			worst = maxf(worst, error)
	print("WORST_ALL_FRAME_ROTATION_ERROR_DEGREES ", worst)
	root.free()
	quit(0 if worst <= 1.0 else 1)
