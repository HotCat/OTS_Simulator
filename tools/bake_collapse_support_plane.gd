extends SceneTree

## Correct only the vertical root channel of a collapse cache.
##
## A seated collapse is unlike walking: at the end, the pelvis, thighs, shins,
## and feet can all be close to the floor. Using the lowest deformed vertex as
## a universal ground constraint is incorrect because a folded hand or torso
## may be lower than the intended support plane. It also raises the character
## root and visibly cancels the captured pelvic slide.

const INPUT_CACHE := "res://renders/mocap/girl_collapse_lean_wall_6s_grounded_contact/motion_pose_frames_vertical.json"
const OUTPUT_CACHE := "res://renders/mocap/girl_collapse_lean_wall_6s_support_plane/motion_pose_frames_vertical.json"
const BASE_CHARACTER_POSITION := Vector3(-0.59765434, 0.0549866, 3.245457)
const ROAD_TOP_Y := 0.01
const SEATED_ROOT_THRESHOLD := -0.50
const STANDING_SUPPORT_BONES := ["LeftFoot", "RightFoot"]
const SEATED_SUPPORT_BONES := [
	"Hips",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot",
]

func _initialize() -> void:
	var scene := (load("res://demos/coffebar_female_walk_scene.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	var character := scene.get_node("IK_character") as Node3D
	var skeleton := scene.get_node("IK_character/Skeleton3D") as Skeleton3D
	var cache := JSON.parse_string(FileAccess.get_file_as_string(INPUT_CACHE)) as Dictionary
	var frames: Array = cache["frames"]
	var rotation_space := str(cache.get("rotation_space", "godot4_rest_relative_local_pose"))
	var root_positions: Array = cache["root_motion"]["positions"]
	var largest_correction := 0.0

	for frame_index in frames.size():
		skeleton.reset_bone_poses()
		_apply_frame(skeleton, frames[frame_index] as Dictionary, rotation_space)
		var root_offset: Array = root_positions[frame_index]
		character.position = BASE_CHARACTER_POSITION + Vector3(
			float(root_offset[0]), float(root_offset[1]), float(root_offset[2]))
		skeleton.advance(0.0)

		# The source root channel tells us which contact model is appropriate.
		# Do not infer this state from leg height: the reported failure was
		# precisely that the legs rose to pelvic height while the pelvis failed
		# to travel downward in world space.
		var support_bones := (
			SEATED_SUPPORT_BONES
			if float(root_offset[1]) <= SEATED_ROOT_THRESHOLD
			else STANDING_SUPPORT_BONES
		)
		var support_y := _median_bone_y(skeleton, support_bones)
		var correction := ROAD_TOP_Y - support_y
		root_offset[1] = float(root_offset[1]) + correction
		root_positions[frame_index] = root_offset
		largest_correction = max(largest_correction, absf(correction))

	cache["root_motion"]["positions"] = root_positions
	var output_cache := OUTPUT_CACHE
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--output="):
			output_cache = arg.trim_prefix("--output=")
	var absolute_output := ProjectSettings.globalize_path(output_cache)
	DirAccess.make_dir_recursive_absolute(absolute_output.get_base_dir())
	var file := FileAccess.open(output_cache, FileAccess.WRITE)
	file.store_string(JSON.stringify(cache, "\t"))
	file.close()
	print("WROTE ", output_cache)
	print("FINAL_ROOT_Y ", root_positions[-1][1])
	print("LARGEST_SUPPORT_CORRECTION ", largest_correction)
	quit(0)

func _apply_frame(skeleton: Skeleton3D, frame: Dictionary, rotation_space: String) -> void:
	for bone_name in frame:
		var bone_index := skeleton.find_bone(str(bone_name))
		if bone_index < 0:
			continue
		var value = frame[bone_name]
		var quaternion: Array = value["rotation_quaternion"] if value is Dictionary else value
		if value is Dictionary and value.has("position"):
			var position: Array = value["position"]
			skeleton.set_bone_pose_position(bone_index, Vector3(
				float(position[0]), float(position[1]), float(position[2])))
		var rotation := Quaternion(
			float(quaternion[0]), float(quaternion[1]),
			float(quaternion[2]), float(quaternion[3]))
		if rotation_space == "godot4_absolute_local_bone_pose":
			rotation = (skeleton.get_bone_rest(bone_index).basis.get_rotation_quaternion().inverse() * rotation).normalized()
		skeleton.set_bone_pose_rotation(bone_index, rotation)

func _median_bone_y(skeleton: Skeleton3D, bone_names: Array) -> float:
	var heights: Array[float] = []
	for bone_name in bone_names:
		var bone_index := skeleton.find_bone(str(bone_name))
		if bone_index >= 0:
			var world_position := skeleton.global_transform * skeleton.get_bone_global_pose(bone_index).origin
			heights.append(world_position.y)
	heights.sort()
	if heights.is_empty():
		return ROAD_TOP_Y
	var middle := heights.size() / 2
	if heights.size() % 2 == 1:
		return heights[middle]
	return (heights[middle - 1] + heights[middle]) * 0.5
