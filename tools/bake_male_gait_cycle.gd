extends SceneTree

## Bake a retargeted male gait cache into an independent AnimationLibrary.
##
## The capture cache contains absolute local rotations in the source target
## GLB's Godot basis.  The OTS scene already has an authored carry pose, so the
## first captured frame is used as the delta reference and every key is
## rebased onto the authored MaleCarrier pose.  This prevents importing the
## detector's T-pose (or its source rig's rest quaternion) into the carry shot.
##
## The clip is intentionally rotation-only.  World translation and heading
## remain owned by OTSCarryClayProxy's trajectory solver, which means this
## loop can be repeated indefinitely on any authored walk plane.  The captured
## pace is stored as resource metadata for later trajectory tuning, but is not
## baked into the carrier root and cannot alter the existing walk cycle.

const DEFAULT_BASE_SCENE := "res://demos/ots_carry_clay_proxy.tscn"
const MALE_SCENE_SKELETON_PATH := "ManualCarryBlock/MaleCarrier/Skeleton3D"
const MALE_ANIMATION_TRACK_SKELETON_PATH := "ManualCarryBlock/MaleCarrier/Skeleton3D"
const ROTATION_SPACE := "godot4_absolute_local_bone_pose"

const FALLBACK_DRIVEN_BONES := [
	"Hips", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot", "Spine", "Chest",
	"UpperChest", "Neck", "Head", "LeftShoulder", "LeftUpperArm",
	"LeftLowerArm", "LeftHand", "RightShoulder", "RightUpperArm",
	"RightLowerArm", "RightHand",
]


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() < 2:
		_fail("Usage: Godot --headless --path . --script res://tools/bake_male_gait_cycle.gd -- <cycle-cache.json> <library.tres> [animation-name] [base-scene]")
		return
	var cache := _load_cache(arguments[0])
	if cache.is_empty():
		return
	var output_path := arguments[1]
	var animation_name := StringName(arguments[2]) if arguments.size() >= 3 else &"ots_h3_heavy_load_walk_loop"
	var base_scene_path := arguments[3] if arguments.size() >= 4 else DEFAULT_BASE_SCENE
	var frames := cache.get("frames", []) as Array
	var fps := float(cache.get("fps", 0.0))
	if frames.size() < 2 or fps <= 0.0:
		_fail("Cache must contain at least two frames and a positive fps")
		return
	var base_scene := load(base_scene_path) as PackedScene
	if base_scene == null:
		_fail("Cannot load authored base scene: %s" % base_scene_path)
		return
	var base_root := base_scene.instantiate()
	var base_pose := _capture_base_pose(base_root, MALE_SCENE_SKELETON_PATH)
	var base_positions := _capture_base_positions(base_root, MALE_SCENE_SKELETON_PATH)
	if base_pose.is_empty():
		base_root.free()
		_fail("Could not read the authored MaleCarrier skeleton pose")
		return

	var first_frame := frames[0] as Dictionary
	var diagnostic_value = cache.get("diagnostics", {})
	var diagnostic := diagnostic_value as Dictionary if diagnostic_value is Dictionary else {}
	var absolute_pose := str(diagnostic.get("retarget_application", "additive")) == "absolute"
	var driven := _driven_bones(cache, first_frame, base_pose)
	var root_cycle := _root_cycle_data(frames)
	var has_travel_root := bool(root_cycle.get("has_travel", false))
	var animation := Animation.new()
	animation.resource_name = str(animation_name)
	# A travelling Mixamo clip normally contains the closing pose as its final
	# source frame.  Use that frame as the exact loop boundary instead of adding
	# another frozen frame, which previously produced a visible one-frame foot
	# slide. Rotation/hips close to frame zero there; root distance stays
	# cumulative so the trajectory consumer can bridge the wrap without a jump.
	animation.length = float(frames.size() - 1) / fps if has_travel_root else float(frames.size()) / fps
	animation.step = 1.0 / fps
	animation.loop_mode = Animation.LOOP_LINEAR

	for bone_name in driven:
		var first_captured: Variant = _quaternion(first_frame.get(bone_name, []))
		if first_captured == null:
			continue
		var authored_base := (base_pose[bone_name] as Quaternion).normalized()
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("%s:%s" % [MALE_ANIMATION_TRACK_SKELETON_PATH, bone_name]))
		animation.track_set_interpolation_type(track, Animation.INTERPOLATION_LINEAR)
		animation.track_set_interpolation_loop_wrap(track, true)
		# Include an exact loop endpoint.  It is the same rebased pose as frame 0,
		# so looping uses a continuous first/last quaternion instead of a visible
		# one-frame snap when the AnimationPlayer wraps.
		var key_count := frames.size() if has_travel_root else frames.size() + 1
		for frame_index in range(key_count):
			var source_index := frame_index % frames.size()
			var captured: Variant = _quaternion((frames[source_index] as Dictionary).get(bone_name, []))
			if captured == null:
				continue
			var delta := ((first_captured as Quaternion).inverse() * (captured as Quaternion)).normalized()
			var value := (captured as Quaternion).normalized() if absolute_pose else (authored_base * delta).normalized()
			if has_travel_root and frame_index == frames.size() - 1 and not absolute_pose:
				value = authored_base
			animation.rotation_track_insert_key(track, float(frame_index) / fps, value)

	# Preserve Mixamo's local pelvis sway and vertical compression. Forward root
	# travel is deliberately absent from the cache because CarrierTrajectory owns
	# world translation. This position track is the missing channel that keeps
	# knees and feet from overextending while the root stays frozen.
	var hip_delta_value: Variant = first_frame.get("hip_position", [])
	if hip_delta_value is Array and (hip_delta_value as Array).size() >= 3 and base_positions.has("Hips"):
		var hip_track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(hip_track, NodePath("%s:Hips" % MALE_ANIMATION_TRACK_SKELETON_PATH))
		animation.track_set_interpolation_type(hip_track, Animation.INTERPOLATION_LINEAR)
		animation.track_set_interpolation_loop_wrap(hip_track, true)
		var authored_hips := base_positions["Hips"] as Vector3
		var key_count := frames.size() if has_travel_root else frames.size() + 1
		for frame_index in range(key_count):
			var source_index := frame_index % frames.size()
			var delta_value: Variant = (frames[source_index] as Dictionary).get("hip_position", [])
			if not delta_value is Array or (delta_value as Array).size() < 3:
				continue
			var delta := Vector3.ZERO if has_travel_root and frame_index == frames.size() - 1 else Vector3(float(delta_value[0]), float(delta_value[1]), float(delta_value[2]))
			animation.position_track_insert_key(hip_track, float(frame_index) / fps, authored_hips + delta)

	# Do not apply travelling root data directly to the skeleton. The OTS scene
	# consumes it through a neutral sampler and maps the distance onto its
	# predefined path. Applying it to both Skeleton3D:Root and MaleCarrier would
	# double the travel and break the shoulder-mounted passenger.
	var root_value: Variant = first_frame.get("root_position", [])
	if has_travel_root and root_value is Array and (root_value as Array).size() >= 3:
		var root_track := animation.add_track(Animation.TYPE_POSITION_3D)
		animation.track_set_path(root_track, NodePath("RootMotionSampler:position"))
		animation.track_set_interpolation_type(root_track, Animation.INTERPOLATION_LINEAR)
		animation.track_set_interpolation_loop_wrap(root_track, true)
		var first_root := _vector3(root_value)
		for frame_index in range(frames.size()):
			var source_index := frame_index
			var root_delta: Variant = (frames[source_index] as Dictionary).get("root_position", [])
			if not root_delta is Array or (root_delta as Array).size() < 3:
				continue
			var delta := _vector3(root_delta) - first_root
			# Vertical pelvis compression remains on Hips. The sampler represents
			# ground-plane locomotion only and therefore never lifts the carrier.
			delta.y = 0.0
			animation.position_track_insert_key(root_track, float(frame_index) / fps, delta)

	_set_metadata(animation, cache, animation_name, base_scene_path, animation.get_track_count())
	base_root.free()
	var library := AnimationLibrary.new()
	var add_error := library.add_animation(animation_name, animation)
	if add_error != OK:
		_fail("AnimationLibrary.add_animation failed with error %d" % add_error)
		return
	var save_error := ResourceSaver.save(library, output_path)
	if save_error != OK:
		_fail("ResourceSaver failed for %s with error %d" % [output_path, save_error])
		return
	print("MALE_GAIT_CYCLE_OK animation=%s frames=%d fps=%.3f length=%.3f tracks=%d output=%s" % [
		animation_name, frames.size(), fps, animation.length, animation.get_track_count(), output_path,
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
		_fail("Cache must use %s" % ROTATION_SPACE)
	return cache


func _capture_base_pose(root: Node, skeleton_path: String) -> Dictionary:
	var result := {}
	var skeleton := root.get_node_or_null(NodePath(skeleton_path)) as Skeleton3D
	if skeleton == null:
		return result
	for bone_index in skeleton.get_bone_count():
		result[str(skeleton.get_bone_name(bone_index))] = skeleton.get_bone_pose_rotation(bone_index)
	return result


func _capture_base_positions(root: Node, skeleton_path: String) -> Dictionary:
	var result := {}
	var skeleton := root.get_node_or_null(NodePath(skeleton_path)) as Skeleton3D
	if skeleton == null:
		return result
	for bone_index in skeleton.get_bone_count():
		result[str(skeleton.get_bone_name(bone_index))] = skeleton.get_bone_pose_position(bone_index)
	return result


func _driven_bones(cache: Dictionary, first_frame: Dictionary, base_pose: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var diagnostic_value = cache.get("diagnostics", {})
	var diagnostic := diagnostic_value as Dictionary if diagnostic_value is Dictionary else {}
	var driven_value = diagnostic.get("driven_bones", [])
	var candidates: Array = driven_value if driven_value is Array and not driven_value.is_empty() else FALLBACK_DRIVEN_BONES
	for value in candidates:
		var name := str(value)
		if first_frame.has(name) and base_pose.has(name):
			result.append(name)
	return result


func _quaternion(values: Variant) -> Variant:
	if values is Array and values.size() >= 4:
		return Quaternion(float(values[0]), float(values[1]), float(values[2]), float(values[3])).normalized()
	return null


func _set_metadata(animation: Animation, cache: Dictionary, animation_name: StringName,
		base_scene_path: String, track_count: int) -> void:
	var clip_value = cache.get("clip", {})
	var clip := clip_value as Dictionary if clip_value is Dictionary else {}
	var root_value = cache.get("root_motion", {})
	var root := root_value as Dictionary if root_value is Dictionary else {}
	animation.set_meta("ots_source_video", str(cache.get("source_video", "")))
	# The cache path is supplied to the baker rather than embedded in the JSON;
	# keep the provenance field explicitly about the source video and avoid
	# pretending that it is a path to a cache file.
	animation.set_meta("ots_source_cache", "cycle cache supplied to bake_male_gait_cycle.gd")
	var source_kind := str(cache.get("source_kind", "retargeted_motion"))
	animation.set_meta("ots_cycle_kind", "%s_loop" % source_kind)
	animation.set_meta("ots_cycle_source_start_frame", int(clip.get("source_start_frame", 0)))
	animation.set_meta("ots_cycle_source_end_frame", int(clip.get("source_end_frame", cache.get("frame_count", 0))))
	animation.set_meta("ots_cycle_seam_method", str(clip.get("seam_method", "cache-provided quaternion seam blend")))
	animation.set_meta("ots_cycle_seam_blend_frames", int(clip.get("seam_blend_frames", 0)))
	animation.set_meta("ots_retarget_base_scene", base_scene_path)
	animation.set_meta("ots_retarget_track_count", track_count)
	animation.set_meta("ots_rotation_space", ROTATION_SPACE)
	animation.set_meta("ots_root_translation", "travelling Root displacement is keyed on RootMotionSampler and consumed by CarrierTrajectory; Skeleton3D:Root is not translated twice")
	var diagnostic_value = cache.get("diagnostics", {})
	var diagnostic := diagnostic_value as Dictionary if diagnostic_value is Dictionary else {}
	animation.set_meta("ots_quaternion_sign_continuity", bool(diagnostic.get("quaternion_sign_continuity", false)))
	animation.set_meta("ots_hip_translation", str(diagnostic.get("hip_translation", "none")))
	animation.set_meta("ots_recommended_speed_mps", float(clip.get("recommended_speed_mps", 0.0)))
	animation.set_meta("ots_captured_pace_cycle_distance_m", float(root.get("captured_pace_cycle_distance_m", 0.0)))
	animation.set_meta("ots_root_cycle_displacement", _vector3(root.get("cycle_displacement", [0.0, 0.0, 0.0])))
	animation.set_meta("ots_root_motion_sampler_path", "RootMotionSampler:position")
	animation.set_meta("ots_capture_fps", float(cache.get("fps", 0.0)))
	animation.set_meta("ots_animation_name", str(animation_name))


func _root_cycle_data(frames: Array) -> Dictionary:
	if frames.size() < 2:
		return {"has_travel": false, "displacement": Vector3.ZERO}
	var first_value: Variant = (frames[0] as Dictionary).get("root_position", [])
	var last_value: Variant = (frames[-1] as Dictionary).get("root_position", [])
	if not first_value is Array or not last_value is Array:
		return {"has_travel": false, "displacement": Vector3.ZERO}
	var displacement := _vector3(last_value) - _vector3(first_value)
	return {
		"has_travel": Vector2(displacement.x, displacement.z).length() >= 0.05,
		"displacement": displacement,
	}


func _vector3(values: Variant) -> Vector3:
	if values is Array and values.size() >= 3:
		return Vector3(float(values[0]), float(values[1]), float(values[2]))
	return Vector3.ZERO


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
