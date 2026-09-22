extends SceneTree

const INPUT_CACHE := "res://renders/mocap/girl_collapse_lean_wall_6s_grounded_contact/motion_pose_frames_vertical.json"
const OUTPUT_CACHE := "res://renders/mocap/girl_collapse_lean_wall_6s_skinned_contact/motion_pose_frames_vertical.json"
const BASE_CHARACTER_POSITION := Vector3(-0.59765434, 0.0549866, 3.245457)

func _initialize() -> void:
	# The mocap cache contains rotations in the imported GLB's absolute-local
	# basis.  We deliberately leave those rotations untouched and correct only
	# the vertical root translation that would put the skinned contact region
	# below the clay road.
	var packed := load("res://demos/coffebar_female_walk_scene.tscn") as PackedScene
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var character := scene.get_node("IK_character") as Node3D
	var skeleton := scene.get_node("IK_character/Skeleton3D") as Skeleton3D
	var avatar := scene.get_node("IK_character/Skeleton3D/Avatar") as MeshInstance3D
	var skin := avatar.skin as Skin
	var cache := JSON.parse_string(FileAccess.get_file_as_string(INPUT_CACHE)) as Dictionary
	var frames: Array = cache["frames"]
	var root_positions: Array = cache["root_motion"]["positions"]
	var ground_y := 0.01 # top of CoffeeBarStreet_Clay_Proxy/Road_Wet_Asphalt
	var total_raise := 0.0
	for frame_index in frames.size():
		var frame: Dictionary = frames[frame_index]
		skeleton.reset_bone_poses()
		apply_frame(skeleton, frame)
		var root_offset: Array = root_positions[frame_index]
		character.position = BASE_CHARACTER_POSITION + Vector3(float(root_offset[0]), float(root_offset[1]), float(root_offset[2]))
		skeleton.advance(0.0)
		var contact_low := find_contact_lowest_y(skeleton, avatar, skin)
		if contact_low < ground_y:
			var raise := ground_y - contact_low
			root_offset[1] = float(root_offset[1]) + raise
			total_raise = max(total_raise, raise)
			character.position.y += raise
			root_positions[frame_index] = root_offset
	cache["root_motion"]["positions"] = root_positions
	var output_cache := OUTPUT_CACHE
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--output="):
			output_cache = arg.trim_prefix("--output=")
	var output_path := ProjectSettings.globalize_path(output_cache)
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var file := FileAccess.open(output_cache, FileAccess.WRITE)
	file.store_string(JSON.stringify(cache, "\t"))
	file.close()
	print("WROTE ", output_cache)
	print("MAX_VERTICAL_RAISE ", total_raise)
	quit(0)

func apply_frame(skeleton: Skeleton3D, frame: Dictionary) -> void:
	for bone_name in frame:
		var bone_index := skeleton.find_bone(str(bone_name))
		if bone_index < 0:
			continue
		var value = frame[bone_name]
		var q: Array = value["rotation_quaternion"] if value is Dictionary else value
		if value is Dictionary and value.has("position"):
			var p: Array = value["position"]
			skeleton.set_bone_pose_position(bone_index, Vector3(float(p[0]), float(p[1]), float(p[2])))
		skeleton.set_bone_pose_rotation(bone_index, Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])))

func find_contact_lowest_y(skeleton: Skeleton3D, avatar: MeshInstance3D, skin: Skin) -> float:
	# Bone origins are not reliable contact proxies: the foot mesh can be above
	# or below its origin after a collapse pose.  Evaluate the actual weighted
	# vertices, restricting the minimum to hips/thigh/shin/foot influences so a
	# lowered hand or torso does not incorrectly determine the road height.
	var lowest := INF
	for surface in avatar.mesh.get_surface_count():
		var arrays := avatar.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if bones.is_empty() or weights.is_empty():
			continue
		for vertex_index in vertices.size():
			var contact_weight := 0.0
			var deformed := Vector3.ZERO
			var weight_sum := 0.0
			for slot in 4:
				var weight := float(weights[vertex_index * 4 + slot])
				if weight <= 0.000001:
					continue
				var bind_index := int(bones[vertex_index * 4 + slot])
				var bind_name := skin.get_bind_name(bind_index)
				if bind_name == "Hips" or bind_name in ["LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes", "RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes"]:
					contact_weight += weight
				# Godot's imported glTF Skin may expose bind/bone=-1 while keeping the
				# authoritative name. Resolve that name against the live skeleton.
				var bone_index := skin.get_bind_bone(bind_index)
				if bone_index < 0:
					bone_index = skeleton.find_bone(bind_name)
				if bone_index < 0:
					continue
				deformed += weight * (skeleton.get_bone_global_pose(bone_index) * skin.get_bind_pose(bind_index) * vertices[vertex_index])
				weight_sum += weight
			# Ignore boundary vertices that merely have a tiny hip/leg blend;
			# otherwise a torso vertex could be mistaken for a sole/thigh contact.
			if contact_weight < 0.25 or weight_sum <= 0.000001:
				continue
			var world := avatar.global_transform * (deformed / weight_sum)
			lowest = min(lowest, world.y)
	return lowest
