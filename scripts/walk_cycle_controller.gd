@tool
extends Node

## Editor-first gait preview controller.
##
## The AnimationPlayer owns only the periodic, in-place bone animation. This
## node owns time, straight-line trajectory travel, and character heading. The
## separation keeps one gait reusable while making the same preview available
## in the scene editor and at runtime.

enum WalkStyle {
	NORMAL_HUMAN,
	LEG_WOUNDED,
	WOUNDED_TERMINATOR,
}

enum TravelMode {
	FOOT_CONTACT_SYNC,
	CAPTURED_ROOT_PACE,
	CONSTANT_SPEED,
	IN_PLACE,
}

const NORMAL_ANIMATION := &"female_walk_cycle"
const LEG_WOUNDED_ANIMATION := &"leg_wounded/female_walk_leg_wounded"
const WOUNDED_ANIMATION := &"wounded/female_walk_wounded_terminator"
const NORMAL_NATURAL_SPEED_MPS := 0.7510994
const LEG_WOUNDED_NATURAL_SPEED_MPS := 0.9782337
const WOUNDED_NATURAL_SPEED_MPS := 0.9909845
const NORMAL_MOTION_CACHE := "res://renders/mocap/6aaba7_walk_bezier/female_walk_cycle.json"
const LEG_WOUNDED_MOTION_CACHE := "res://renders/mocap/6aaba7_walk_bezier/female_walk_leg_wounded.json"
const WOUNDED_MOTION_CACHE := "res://renders/mocap/6aaba7_walk_bezier/female_walk_wounded_terminator.json"
const CAPTURE_SERVICE_GROUP := &"ots_render_capture_service"

@export_group("Scene References")
@export var character_path := NodePath("../IK_character")
@export var skeleton_path := NodePath("../IK_character/Skeleton3D")
@export var trajectory_path := NodePath("../FemaleWalkTrajectory")
@export var animation_player_path := NodePath("../FemaleWalkAnimationPlayer")

@export_group("Gait Style")
@export var walk_style: WalkStyle = WalkStyle.NORMAL_HUMAN:
	set(value):
		walk_style = value
		if is_inside_tree():
			_apply_preview_time(preview_time_seconds)
@export_tool_button("Apply selected constant gait speed")
var apply_natural_speed_action: Callable = _apply_selected_natural_speed

@export_group("Gait Shaping")
## Symmetrically adducts only the airborne thigh. Planted legs remain exactly
## on the captured animation so Foot Contact Sync keeps its stance anchors.
@export_range(0.0, 12.0, 0.1, "suffix:°")
var thigh_closure_degrees := 4.0:
	set(value):
		thigh_closure_degrees = clampf(value, 0.0, 12.0)
		if is_inside_tree():
			_apply_preview_time(preview_time_seconds)

## Positive values advance the gait phase before sampling the proxy. This is
## useful when the source performer wears a raised heel: the source heel-strike
## can occur a few frames before the flat-foot proxy reaches the same visual
## contact. Travel is phase shifted by the same amount and re-zeroed at t=0, so
## the character does not jump forward when preview/restart begins.
@export_range(-12.0, 12.0, 0.1, "suffix:frames")
var heel_contact_lead_frames := 0.0:
	set(value):
		heel_contact_lead_frames = clampf(value, -12.0, 12.0)
		if is_inside_tree():
			_apply_preview_time(preview_time_seconds)

@export_group("Trajectory Layout")
@export_range(1.0, 200.0, 0.1, "or_greater", "suffix:m")
var planned_path_length_m := 24.0
@export_tool_button("Arrange straight trajectory length")
var arrange_trajectory_action: Callable = _arrange_straight_trajectory

@export_group("Walk Preview")
@export var travel_mode: TravelMode = TravelMode.FOOT_CONTACT_SYNC:
	set(value):
		travel_mode = value
		if is_inside_tree():
			_apply_preview_time(preview_time_seconds)
@export_range(0.0, 5.0, 0.01, "or_greater")
## Feed override for the legacy Captured Root Pace diagnostic only. Foot
## Contact Sync always uses the unscaled bilateral anchor solution.
var captured_pace_scale := 1.0:
	set(value):
		captured_pace_scale = maxf(0.0, value)
		if is_inside_tree():
			_apply_preview_time(preview_time_seconds)
@export var preview_in_editor := false
## Limits expensive editor-only AnimationPlayer seeks and 56-bone skinning.
## Runtime playback remains uncapped and camera capture samples this live pose.
@export_range(1.0, 60.0, 1.0, "suffix:FPS")
var editor_preview_fps := 30.0
@export_range(0.0, 600.0, 0.001, "or_greater", "suffix:s")
var preview_time_seconds := 0.0:
	set(value):
		preview_time_seconds = maxf(0.0, value)
		if is_inside_tree() and not _advancing_time:
			_apply_preview_time(preview_time_seconds)
@export_range(0.01, 5.0, 0.001, "or_greater", "suffix:m/s")
var walk_speed_mps := 0.97:
	set(value):
		walk_speed_mps = maxf(0.01, value)
		if is_inside_tree():
			_apply_preview_time(preview_time_seconds)
@export_range(-2.0, 2.0, 0.001, "or_less", "or_greater", "suffix:m")
var character_height_offset_m := 0.0:
	set(value):
		character_height_offset_m = value
		if is_inside_tree():
			_apply_preview_time(preview_time_seconds)
@export var stop_at_path_end := true
@export var continue_past_end := false
@export var auto_start_runtime := true
@export var local_forward := Vector3.FORWARD

@export_group("Editor Transport")
@export_tool_button("Play walk preview") var play_action: Callable = _play_preview
@export_tool_button("Pause walk preview") var pause_action: Callable = _pause_preview
@export_tool_button("Restart walk preview") var restart_action: Callable = _restart_preview
@export_tool_button("Refresh trajectory markers") var refresh_path_action: Callable = _refresh_path
@export_tool_button("Record editor camera motion")
var record_camera_motion_action: Callable = _record_editor_camera_motion
@export var camera_recording_active := false
@export_multiline var camera_recording_status := "Ready. Capture settings come from the OTS Render dock."

@export_group("Editor Camera Tracking")
@export_tool_button("Confirm current camera follow")
var confirm_camera_follow_action: Callable = _confirm_editor_camera_follow
@export_tool_button("Stop camera follow")
var stop_camera_follow_action: Callable = _stop_editor_camera_follow
@export var camera_follow_active := false
@export_multiline var camera_follow_status := "Frame the female in the 3D viewport, then confirm."

var _character: Node3D
var _skeleton: Skeleton3D
var _animation_player: AnimationPlayer
var _points: Array[Vector3] = []
var _cumulative := PackedFloat32Array()
var _playing := false
var _advancing_time := false
var _editor_frame_accumulator := 0.0
var _pace_profiles: Dictionary = {}
var _capture_fixed_step_active := false
var _capture_resume_playing := false


func _ready() -> void:
	_resolve_nodes()
	_load_pace_profiles()
	_rebuild_path()
	set_process(true)
	if Engine.is_editor_hint():
		_playing = preview_in_editor
		_apply_preview_time(preview_time_seconds)
	elif auto_start_runtime:
		_restart_preview()
	else:
		_apply_preview_time(preview_time_seconds)


func _process(delta: float) -> void:
	# The recorder owns time while fixed-step capture is active. Transport
	# commands may arrive after recording was requested; never allow them to
	# re-enable the ordinary wall-clock evaluator during that take.
	if _capture_fixed_step_active:
		return
	if Engine.is_editor_hint() and preview_in_editor and not _playing:
		_playing = true
	if not _playing:
		return
	if Engine.is_editor_hint() and not preview_in_editor:
		_playing = false
		return
	var advance_delta := maxf(0.0, delta)
	if Engine.is_editor_hint():
		_editor_frame_accumulator += advance_delta
		var preview_interval := 1.0 / maxf(1.0, editor_preview_fps)
		if _editor_frame_accumulator < preview_interval:
			return
		advance_delta = _editor_frame_accumulator
		_editor_frame_accumulator = 0.0
	var next_time := preview_time_seconds + advance_delta
	if stop_at_path_end and not continue_past_end:
		var path_length := _path_length()
		var animation := _animation_player.get_animation(_active_animation_name()) \
			if _animation_player != null else null
		if path_length > 0.0 and _travel_distance_for_time(next_time, animation) >= path_length:
			_playing = false
			preview_in_editor = false
	_advancing_time = true
	preview_time_seconds = next_time
	_advancing_time = false
	_apply_preview_time(next_time)


func _play_preview() -> void:
	_resolve_nodes()
	_rebuild_path()
	if _character == null or _animation_player == null or _points.size() < 2:
		push_warning("Walk preview needs the character, AnimationPlayer, and at least two trajectory markers")
		return
	_editor_frame_accumulator = 0.0
	if _capture_fixed_step_active:
		_capture_resume_playing = true
		_playing = false
		if Engine.is_editor_hint():
			preview_in_editor = false
	else:
		_playing = true
		if Engine.is_editor_hint():
			preview_in_editor = true
	_apply_preview_time(preview_time_seconds)


func _pause_preview() -> void:
	_editor_frame_accumulator = 0.0
	if _capture_fixed_step_active:
		_capture_resume_playing = false
	_playing = false
	if Engine.is_editor_hint():
		preview_in_editor = false
	_apply_preview_time(preview_time_seconds)


func _restart_preview() -> void:
	_resolve_nodes()
	_rebuild_path()
	_editor_frame_accumulator = 0.0
	_advancing_time = true
	preview_time_seconds = 0.0
	_advancing_time = false
	_apply_preview_time(0.0)
	if _character != null and _animation_player != null and _points.size() >= 2:
		if _capture_fixed_step_active:
			_capture_resume_playing = true
			_playing = false
			if Engine.is_editor_hint():
				preview_in_editor = false
		else:
			_playing = true
			if Engine.is_editor_hint():
				preview_in_editor = true


func _refresh_path() -> void:
	_resolve_nodes()
	_rebuild_path()
	_apply_preview_time(preview_time_seconds)


## Stable editor-service API used by the localhost director protocol. These
## methods execute the same paths as the five Inspector buttons but return the
## observed controller state, so external clients never have to infer whether
## a click or toggle was accepted.
func editor_transport_play() -> Dictionary:
	_play_preview()
	var result := editor_transport_status()
	if not _playing:
		result["ok"] = false
		result["error"] = "walk_preview_not_ready"
	return result


func editor_transport_pause() -> Dictionary:
	_pause_preview()
	return editor_transport_status()


func editor_transport_restart() -> Dictionary:
	_restart_preview()
	var result := editor_transport_status()
	if not _playing:
		result["ok"] = false
		result["error"] = "walk_preview_not_ready"
	return result


func editor_transport_refresh_trajectory() -> Dictionary:
	_refresh_path()
	return editor_transport_status()


func editor_transport_record_camera_motion(options: Dictionary = {}) -> Dictionary:
	var accepted := _record_editor_camera_motion(options)
	var result := editor_transport_status()
	if not accepted:
		result["ok"] = false
		result["error"] = "camera_recording_service_unavailable"
	return result


## Video capture uses this pair to decouple gait time from GPU/render time.
## Without it, a slow avatar render lets the editor's normal _process(delta)
## advance several gait seconds while only one frame is being written, which
## produces an apparently fast-forwarded MP4.
func editor_capture_begin_fixed_step() -> Dictionary:
	var was_playing := _playing or preview_in_editor
	_capture_fixed_step_active = true
	_capture_resume_playing = was_playing
	_editor_frame_accumulator = 0.0
	_playing = false
	preview_in_editor = false
	return {"ok": true, "was_playing": was_playing, "preview_time_seconds": preview_time_seconds}


func editor_capture_step_fixed(delta_seconds: float) -> Dictionary:
	var step := maxf(0.0, delta_seconds)
	if step <= 0.0:
		return editor_transport_status()
	_resolve_nodes()
	_advancing_time = true
	preview_time_seconds += step
	_advancing_time = false
	_apply_preview_time(preview_time_seconds)
	return editor_transport_status()


func editor_capture_end_fixed_step(was_playing: bool) -> Dictionary:
	_editor_frame_accumulator = 0.0
	var should_resume := _capture_resume_playing or was_playing
	_capture_fixed_step_active = false
	_capture_resume_playing = false
	if should_resume:
		_playing = true
		if Engine.is_editor_hint():
			preview_in_editor = true
	return editor_transport_status()


func editor_transport_status() -> Dictionary:
	return {
		"ok": true,
		"playing": _playing,
		"preview_in_editor": preview_in_editor,
		"preview_time_seconds": preview_time_seconds,
		"trajectory_point_count": _points.size(),
		"trajectory_length_m": _path_length(),
		"camera_recording_active": camera_recording_active,
		"camera_recording_status": camera_recording_status,
	}


func _record_editor_camera_motion(options: Dictionary = {}) -> bool:
	if not Engine.is_editor_hint():
		push_warning("Editor camera recording is available only inside the Godot editor")
		return false
	var capture_service := get_tree().get_first_node_in_group(CAPTURE_SERVICE_GROUP)
	# A script hot-reload updates the already-running EditorPlugin instance but
	# does not necessarily call its _enter_tree() again. In that case the group
	# registration added by a newer script version is absent until editor restart.
	# Locate the live plugin in the full editor tree so the button works now.
	if capture_service == null:
		capture_service = _find_capture_service(get_tree().root)
	if capture_service == null:
		# Last-resort bridge for a plugin instance created before the service API
		# was hot-reloaded: invoke its already-connected dock button signal.
		var capture_button := _find_capture_dock_button(EditorInterface.get_base_control())
		if capture_button != null:
			_set_camera_recording_status(true, "Recording requested through OTS Render dock…")
			print("FemaleWalkController requested recording through the OTS Render dock")
			capture_button.button_down.emit()
			return true
		_set_camera_recording_status(
			false,
			"OTS Render Capture is unavailable; enable its plugin and retry."
		)
		push_warning(
			"OTS Render Capture is unavailable. Enable res://addons/ots_render_capture/plugin.cfg"
		)
		return false
	# Do not pause the controller: the capture plugin synchronizes this evaluated
	# scene into its clean off-screen viewport once per recorded frame.
	var status_callback := Callable(self, "_on_camera_recording_state_changed")
	if capture_service.has_signal("editor_camera_video_state_changed") and not \
			capture_service.is_connected("editor_camera_video_state_changed", status_callback):
		capture_service.connect("editor_camera_video_state_changed", status_callback)
	_set_camera_recording_status(true, "Recording requested; preparing capture…")
	print("FemaleWalkController requested editor camera-motion recording")
	if capture_service.has_method("request_editor_camera_video"):
		capture_service.call("request_editor_camera_video", options)
	else:
		# Compatibility with the plugin instance that predates the public bridge.
		capture_service.call("_on_record_video_pressed", options)
	return true


func _confirm_editor_camera_follow() -> void:
	var capture_service := _editor_capture_service()
	if capture_service == null or not capture_service.has_method("confirm_editor_camera_follow"):
		_set_camera_follow_status(
			false, "OTS Render Capture is unavailable; reload or enable its plugin."
		)
		push_warning("OTS Render Capture does not provide editor camera tracking")
		return
	_connect_camera_follow_status(capture_service)
	capture_service.call("confirm_editor_camera_follow")


func _stop_editor_camera_follow() -> void:
	var capture_service := _editor_capture_service()
	if capture_service == null or not capture_service.has_method("stop_editor_camera_follow"):
		_set_camera_follow_status(false, "Camera follow service is unavailable.")
		return
	_connect_camera_follow_status(capture_service)
	capture_service.call("stop_editor_camera_follow")


func _editor_capture_service() -> Node:
	var capture_service := get_tree().get_first_node_in_group(CAPTURE_SERVICE_GROUP)
	if capture_service == null:
		capture_service = _find_capture_service(get_tree().root)
	return capture_service


func _connect_camera_follow_status(capture_service: Node) -> void:
	var callback := Callable(self, "_on_camera_follow_state_changed")
	if capture_service.has_signal("editor_camera_follow_state_changed") and not \
			capture_service.is_connected("editor_camera_follow_state_changed", callback):
		capture_service.connect("editor_camera_follow_state_changed", callback)


func _on_camera_follow_state_changed(active: bool, status: String) -> void:
	_set_camera_follow_status(active, status)


func _set_camera_follow_status(active: bool, status: String) -> void:
	camera_follow_active = active
	camera_follow_status = status
	notify_property_list_changed()


func _on_camera_recording_state_changed(active: bool, status: String) -> void:
	_set_camera_recording_status(active, status)


func _set_camera_recording_status(active: bool, status: String) -> void:
	camera_recording_active = active
	camera_recording_status = status
	notify_property_list_changed()


func _find_capture_service(node: Node) -> Node:
	if node != self:
		if node.has_method("request_editor_camera_video"):
			return node
		if node.has_method("_on_record_video_pressed"):
			var node_script := node.get_script() as Script
			if node_script != null and node_script.resource_path == \
					"res://addons/ots_render_capture/plugin.gd":
				return node
	for child in node.get_children(true):
		var result := _find_capture_service(child)
		if result != null:
			return result
	return null


func _find_capture_dock_button(node: Node) -> Button:
	if node is Button:
		var button := node as Button
		if button.text == "Record editor camera motion" and \
				button.tooltip_text.begins_with("After the start delay"):
			return button
	for child in node.get_children(true):
		var result := _find_capture_dock_button(child)
		if result != null:
			return result
	return null


func _apply_selected_natural_speed() -> void:
	walk_speed_mps = _active_natural_speed()


func _arrange_straight_trajectory() -> void:
	var trajectory := get_node_or_null(trajectory_path) as Node3D
	if trajectory == null:
		push_warning("Cannot arrange trajectory: trajectory node is missing")
		return
	var markers: Array[Marker3D] = []
	for child in trajectory.get_children():
		if child is Marker3D and child.has_meta("trajectory_waypoint"):
			markers.append(child as Marker3D)
	markers.sort_custom(func(a: Marker3D, b: Marker3D) -> bool: return str(a.name) < str(b.name))
	if markers.size() < 2:
		push_warning("Cannot arrange trajectory: at least two waypoint markers are required")
		return
	var start := markers[0].position
	var direction := markers[-1].position - start
	direction.y = 0.0
	if direction.is_zero_approx():
		direction = Vector3.FORWARD
	direction = direction.normalized()
	for index in markers.size():
		var amount := float(index) / float(markers.size() - 1)
		markers[index].position = start + direction * planned_path_length_m * amount
	_rebuild_path()
	_apply_preview_time(preview_time_seconds)


func _active_animation_name() -> StringName:
	if walk_style == WalkStyle.LEG_WOUNDED:
		return LEG_WOUNDED_ANIMATION
	if walk_style == WalkStyle.WOUNDED_TERMINATOR:
		return WOUNDED_ANIMATION
	return NORMAL_ANIMATION


func _active_natural_speed() -> float:
	if walk_style == WalkStyle.LEG_WOUNDED:
		return LEG_WOUNDED_NATURAL_SPEED_MPS
	if walk_style == WalkStyle.WOUNDED_TERMINATOR:
		return WOUNDED_NATURAL_SPEED_MPS
	return NORMAL_NATURAL_SPEED_MPS


func _active_motion_cache_path() -> String:
	if walk_style == WalkStyle.LEG_WOUNDED:
		return LEG_WOUNDED_MOTION_CACHE
	if walk_style == WalkStyle.WOUNDED_TERMINATOR:
		return WOUNDED_MOTION_CACHE
	return NORMAL_MOTION_CACHE


func _load_pace_profiles() -> void:
	_pace_profiles.clear()
	_load_pace_profile(NORMAL_ANIMATION, NORMAL_MOTION_CACHE)
	_load_pace_profile(LEG_WOUNDED_ANIMATION, LEG_WOUNDED_MOTION_CACHE)
	_load_pace_profile(WOUNDED_ANIMATION, WOUNDED_MOTION_CACHE)


func _load_pace_profile(animation_name: StringName, cache_path: String) -> void:
	var file := FileAccess.open(cache_path, FileAccess.READ)
	if file == null:
		push_warning("Captured gait pace is unavailable: %s" % cache_path)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_warning("Captured gait pace is not valid JSON: %s" % cache_path)
		return
	var root_value = (parsed as Dictionary).get("root_motion", {})
	if not root_value is Dictionary:
		return
	var root := root_value as Dictionary
	var captured_values = root.get("captured_pace_distances_m", [])
	var contact_values = root.get("foot_contact_pace_distances_m", [])
	var lateral_values = root.get("foot_contact_lateral_offsets_m", [])
	if not captured_values is Array or captured_values.is_empty():
		return
	var captured_samples := PackedFloat32Array()
	for value in captured_values:
		captured_samples.append(float(value))
	var contact_samples := PackedFloat32Array()
	if contact_values is Array:
		for value in contact_values:
			contact_samples.append(float(value))
	var lateral_samples := PackedFloat32Array()
	if lateral_values is Array:
		for value in lateral_values:
			lateral_samples.append(float(value))
	var left_swing_samples := PackedFloat32Array()
	var right_swing_samples := PackedFloat32Array()
	var contacts_value = root.get("contacts", {})
	if contacts_value is Dictionary:
		var contacts := contacts_value as Dictionary
		left_swing_samples = _build_swing_samples(contacts.get("left", []))
		right_swing_samples = _build_swing_samples(contacts.get("right", []))
	var contact_forward := local_forward
	var forward_values = root.get("foot_contact_local_forward", [])
	if forward_values is Array and forward_values.size() >= 3:
		contact_forward = Vector3(
			float(forward_values[0]), float(forward_values[1]), float(forward_values[2])
		)
	_pace_profiles[animation_name] = {
		"captured_samples": captured_samples,
		"contact_samples": contact_samples,
		"lateral_samples": lateral_samples,
		"left_swing_samples": left_swing_samples,
		"right_swing_samples": right_swing_samples,
		"contact_forward": contact_forward,
		"fps": float((parsed as Dictionary).get("fps", 30.0)),
		"captured_cycle_distance": float(root.get(
			"captured_pace_cycle_distance_m", captured_samples[-1]
		)),
		"contact_cycle_distance": float(root.get(
			"foot_contact_pace_cycle_distance_m",
			contact_samples[-1] if not contact_samples.is_empty() else captured_samples[-1]
		)),
	}


func _build_swing_samples(contact_value: Variant) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if not contact_value is Array or contact_value.is_empty():
		return result
	var contacts := contact_value as Array
	var frame_count := contacts.size()
	var transition_frames := 5
	for frame in frame_count:
		if bool(contacts[frame]):
			result.append(0.0)
			continue
		var nearest_contact := transition_frames + 1
		for distance in range(1, transition_frames + 1):
			var before := posmod(frame - distance, frame_count)
			var after := posmod(frame + distance, frame_count)
			if bool(contacts[before]) or bool(contacts[after]):
				nearest_contact = distance
				break
		result.append(clampf(
			float(nearest_contact) / float(transition_frames + 1), 0.0, 1.0
		))
	return result


func _profile_distance_for_time(time_seconds: float, animation: Animation,
		samples_key: String, distance_key: String, distance_scale: float) -> float:
	var animation_name := _active_animation_name()
	if not _pace_profiles.has(animation_name) or animation == null or animation.length <= 0.0:
		return walk_speed_mps * time_seconds
	var profile := _pace_profiles[animation_name] as Dictionary
	var samples := profile.get(samples_key, PackedFloat32Array()) as PackedFloat32Array
	if samples.is_empty():
		return walk_speed_mps * time_seconds
	var cycle_distance := maxf(0.0, float(profile.get(distance_key, samples[-1])))
	var cycle_count := floori(time_seconds / animation.length)
	var loop_time := fposmod(time_seconds, animation.length)
	var frame_position := loop_time * maxf(0.001, float(profile.get("fps", 30.0)))
	var left := clampi(floori(frame_position), 0, samples.size() - 1)
	var amount := clampf(frame_position - left, 0.0, 1.0)
	var left_distance := float(samples[left])
	var right_distance := cycle_distance if left + 1 >= samples.size() else float(samples[left + 1])
	var within_cycle := lerpf(left_distance, right_distance, amount)
	return (cycle_count * cycle_distance + within_cycle) * distance_scale


func _phase_lead_seconds(animation: Animation) -> float:
	if animation == null or animation.length <= 0.0:
		return 0.0
	var fps := 30.0
	if _pace_profiles.has(_active_animation_name()):
		fps = maxf(0.001, float((_pace_profiles[_active_animation_name()] as Dictionary).get("fps", 30.0)))
	return heel_contact_lead_frames / fps


func _phase_shifted_time(time_seconds: float, animation: Animation) -> float:
	if animation == null or animation.length <= 0.0:
		return time_seconds
	return time_seconds + _phase_lead_seconds(animation)


func _contact_motion_for_time(time_seconds: float, animation: Animation) -> Vector2:
	var animation_name := _active_animation_name()
	if not _pace_profiles.has(animation_name) or animation == null or animation.length <= 0.0:
		return Vector2(walk_speed_mps * time_seconds, 0.0)
	var profile := _pace_profiles[animation_name] as Dictionary
	var samples := profile.get("contact_samples", PackedFloat32Array()) as PackedFloat32Array
	var lateral := profile.get("lateral_samples", PackedFloat32Array()) as PackedFloat32Array
	if samples.is_empty() or lateral.size() != samples.size():
		return Vector2(walk_speed_mps * time_seconds, 0.0)
	var cycle_distance := maxf(0.0, float(profile.get("contact_cycle_distance", samples[-1])))
	var cycle_count := floori(time_seconds / animation.length)
	var loop_time := fposmod(time_seconds, animation.length)
	var frame_position := loop_time * maxf(0.001, float(profile.get("fps", 30.0)))
	var left := clampi(floori(frame_position), 0, samples.size() - 1)
	var amount := clampf(frame_position - left, 0.0, 1.0)
	var right_distance := cycle_distance if left + 1 >= samples.size() else float(samples[left + 1])
	var right_lateral := 0.0 if left + 1 >= lateral.size() else float(lateral[left + 1])
	return Vector2(
		cycle_count * cycle_distance + lerpf(float(samples[left]), right_distance, amount),
		lerpf(float(lateral[left]), right_lateral, amount),
	)


func _raw_travel_motion_for_time(time_seconds: float, animation: Animation) -> Vector2:
	match travel_mode:
		TravelMode.IN_PLACE:
			return Vector2.ZERO
		TravelMode.CONSTANT_SPEED:
			return Vector2(walk_speed_mps * time_seconds, 0.0)
		TravelMode.CAPTURED_ROOT_PACE:
			return Vector2(_profile_distance_for_time(
				time_seconds, animation, "captured_samples", "captured_cycle_distance",
				captured_pace_scale
			), 0.0)
		_:
			return _contact_motion_for_time(time_seconds, animation)


func _travel_motion_for_time(time_seconds: float, animation: Animation) -> Vector2:
	var lead_seconds := _phase_lead_seconds(animation)
	if absf(lead_seconds) <= 0.000001:
		return _raw_travel_motion_for_time(time_seconds, animation)
	var shifted := _raw_travel_motion_for_time(time_seconds + lead_seconds, animation)
	var initial := _raw_travel_motion_for_time(lead_seconds, animation)
	var result := shifted - initial
	# A negative phase lead can cross a cycle boundary. Add whole cycle travel
	# until the re-zeroed distance is non-negative and monotonic at the seam.
	var cycle := _raw_travel_motion_for_time(animation.length, animation)
	if cycle.x > 0.0:
		while result.x < -0.000001:
			result.x += cycle.x
	return result


func _travel_distance_for_time(time_seconds: float, animation: Animation) -> float:
	return _travel_motion_for_time(time_seconds, animation).x


func _active_local_forward() -> Vector3:
	if travel_mode == TravelMode.FOOT_CONTACT_SYNC and _pace_profiles.has(_active_animation_name()):
		var profile := _pace_profiles[_active_animation_name()] as Dictionary
		var contact_forward = profile.get("contact_forward", local_forward)
		if contact_forward is Vector3 and not (contact_forward as Vector3).is_zero_approx():
			return contact_forward as Vector3
	return local_forward


func _profile_sample_for_time(time_seconds: float, animation: Animation,
		samples_key: String, fallback: float = 0.0) -> float:
	if animation == null or animation.length <= 0.0 or \
			not _pace_profiles.has(_active_animation_name()):
		return fallback
	var profile := _pace_profiles[_active_animation_name()] as Dictionary
	var samples := profile.get(samples_key, PackedFloat32Array()) as PackedFloat32Array
	if samples.is_empty():
		return fallback
	var loop_time := fposmod(time_seconds, animation.length)
	var frame_position := loop_time * maxf(0.001, float(profile.get("fps", 30.0)))
	var left := clampi(floori(frame_position), 0, samples.size() - 1)
	var right := (left + 1) % samples.size()
	var amount := clampf(frame_position - float(left), 0.0, 1.0)
	return lerpf(float(samples[left]), float(samples[right]), amount)


func _apply_thigh_closure(time_seconds: float, animation: Animation) -> void:
	if _skeleton == null or animation == null or thigh_closure_degrees <= 0.0001:
		return
	var left_upper := _skeleton.find_bone("LeftUpperLeg")
	var left_lower := _skeleton.find_bone("LeftLowerLeg")
	var right_upper := _skeleton.find_bone("RightUpperLeg")
	var right_lower := _skeleton.find_bone("RightLowerLeg")
	if left_upper < 0 or left_lower < 0 or right_upper < 0 or right_lower < 0:
		return
	_skeleton.force_update_all_bone_transforms()
	var left_hip := _skeleton.get_bone_global_pose(left_upper).origin
	var right_hip := _skeleton.get_bone_global_pose(right_upper).origin
	var lateral_axis := left_hip - right_hip
	if lateral_axis.is_zero_approx():
		return
	lateral_axis = lateral_axis.normalized()
	var closure_axis := lateral_axis.cross(Vector3.UP).normalized()
	if closure_axis.is_zero_approx():
		return
	var hip_center := (left_hip + right_hip) * 0.5
	_close_swing_thigh(
		left_upper, left_lower, lateral_axis, closure_axis, hip_center,
		_profile_sample_for_time(time_seconds, animation, "left_swing_samples")
	)
	_close_swing_thigh(
		right_upper, right_lower, lateral_axis, closure_axis, hip_center,
		_profile_sample_for_time(time_seconds, animation, "right_swing_samples")
	)
	_skeleton.force_update_all_bone_transforms()


func _close_swing_thigh(upper_index: int, lower_index: int,
		lateral_axis: Vector3, closure_axis: Vector3, hip_center: Vector3,
		swing_weight: float) -> void:
	if swing_weight <= 0.0001:
		return
	var upper_pose := _skeleton.get_bone_global_pose(upper_index)
	var knee_position := _skeleton.get_bone_global_pose(lower_index).origin
	var knee_vector := knee_position - upper_pose.origin
	var angle := deg_to_rad(thigh_closure_degrees * clampf(swing_weight, 0.0, 1.0))
	var positive := Quaternion(closure_axis, angle)
	var negative := Quaternion(closure_axis, -angle)
	var positive_knee := upper_pose.origin + positive * knee_vector
	var negative_knee := upper_pose.origin + negative * knee_vector
	var positive_distance := absf((positive_knee - hip_center).dot(lateral_axis))
	var negative_distance := absf((negative_knee - hip_center).dot(lateral_axis))
	var correction := positive if positive_distance <= negative_distance else negative
	upper_pose.basis = Basis(correction) * upper_pose.basis
	_skeleton.set_bone_global_pose(upper_index, upper_pose)


func _resolve_nodes() -> void:
	_character = get_node_or_null(character_path) as Node3D
	_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	_animation_player = get_node_or_null(animation_player_path) as AnimationPlayer
	# Imported GLBs may use AnimatableBody3D with transform synchronization.
	# That queues direct position edits for physics and makes editor scrubbing
	# appear stationary. Director-controlled characters need immediate transforms.
	if _character is AnimatableBody3D:
		(_character as AnimatableBody3D).sync_to_physics = false


func _rebuild_path() -> void:
	_points.clear()
	_cumulative = PackedFloat32Array()
	var trajectory := get_node_or_null(trajectory_path) as Node3D
	if trajectory == null or _character == null or _character.get_parent() == null:
		return
	var markers: Array[Marker3D] = []
	for child in trajectory.get_children():
		if child is Marker3D and child.has_meta("trajectory_waypoint"):
			markers.append(child as Marker3D)
	markers.sort_custom(func(a: Marker3D, b: Marker3D) -> bool: return str(a.name) < str(b.name))
	var character_parent := _character.get_parent() as Node3D
	for marker in markers:
		_points.append(character_parent.to_local(marker.global_position))
	if _points.is_empty():
		return
	_cumulative.append(0.0)
	for index in range(1, _points.size()):
		_cumulative.append(_cumulative[index - 1] + _points[index - 1].distance_to(_points[index]))


func _apply_preview_time(time_seconds: float) -> void:
	if _character == null or _animation_player == null:
		_resolve_nodes()
	if _points.size() < 2:
		_rebuild_path()
	if _character == null or _animation_player == null:
		return
	var animation_name := _active_animation_name()
	var animation := _animation_player.get_animation(animation_name)
	if animation != null and animation.length > 0.0:
		if _animation_player.assigned_animation != animation_name:
			_animation_player.assigned_animation = animation_name
		var loop_time := fposmod(_phase_shifted_time(time_seconds, animation), animation.length)
		_animation_player.seek(loop_time, true)
		_apply_thigh_closure(_phase_shifted_time(time_seconds, animation), animation)
	var travel := _travel_motion_for_time(time_seconds, animation)
	_apply_distance(travel.x, travel.y)


func _path_length() -> float:
	return float(_cumulative[-1]) if not _cumulative.is_empty() else 0.0


func _apply_distance(distance: float, lateral_offset: float = 0.0) -> void:
	if _character == null or _points.size() < 2:
		return
	var path_length := _path_length()
	var sample_distance := maxf(0.0, distance)
	if sample_distance > path_length:
		if continue_past_end:
			var tail_direction := (_points[-1] - _points[-2]).normalized()
			var tail_right := tail_direction.cross(Vector3.UP).normalized()
			_character.position = (_points[-1]
				+ tail_direction * (sample_distance - path_length)
				+ tail_right * lateral_offset
				+ Vector3.UP * character_height_offset_m)
			_face_direction(tail_direction)
			return
		sample_distance = path_length
	var segment := 0
	while segment + 1 < _cumulative.size() and sample_distance > _cumulative[segment + 1]:
		segment += 1
	segment = mini(segment, _points.size() - 2)
	var segment_start := float(_cumulative[segment])
	var segment_length := maxf(0.000001, float(_cumulative[segment + 1]) - segment_start)
	var amount := clampf((sample_distance - segment_start) / segment_length, 0.0, 1.0)
	var segment_direction := (_points[segment + 1] - _points[segment]).normalized()
	var segment_right := segment_direction.cross(Vector3.UP).normalized()
	_character.position = (_points[segment].lerp(_points[segment + 1], amount)
		+ segment_right * lateral_offset
		+ Vector3.UP * character_height_offset_m)
	_face_direction(segment_direction)


func _face_direction(direction: Vector3) -> void:
	direction.y = 0.0
	var forward := _active_local_forward()
	forward.y = 0.0
	if direction.is_zero_approx() or forward.is_zero_approx():
		return
	var yaw := forward.normalized().signed_angle_to(direction.normalized(), Vector3.UP)
	_character.quaternion = Quaternion(Vector3.UP, yaw)
