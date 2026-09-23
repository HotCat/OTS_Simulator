@tool
extends EditorPlugin

signal editor_camera_video_state_changed(active: bool, status: String)
signal editor_camera_follow_state_changed(active: bool, status: String)
signal editor_camera_program_state_changed(state: String, status: String)

const CameraMotionProgram = preload("res://scripts/editor_camera_motion_program.gd")

## Captures the current 3D editor view without requiring a Camera3D node in
## the saved scene.  An isolated duplicate of the edited scene prevents editor
## gizmos, selection outlines, and camera icons from leaking into the exported
## passes.  A temporary camera still copies the selected editor viewport's
## exact transform and projection, including unsaved camera framing.

const FEMALE_PATH := NodePath("IK_character")
const MALE_PATH := NodePath("MaleCarrier")
const CAMERA_REFERENCE_NAME := "CameraOrbitReference"
const OUTPUT_ROOT := "res://renders/ots_quickview"
const CAPTURE_SERVICE_GROUP := &"ots_render_capture_service"

# The color-reference pass is intentionally different from the binary ID mask:
# it keeps the whole scene and normal 3D shading in one coherent image while
# making the overlapping actors trivial to distinguish by color.
const FEMALE_REFERENCE_COLOR := Color(0.96, 0.18, 0.46, 1.0)
const MALE_REFERENCE_COLOR := Color(0.08, 0.58, 1.0, 1.0)
const ENVIRONMENT_REFERENCE_COLOR := Color(0.52, 0.55, 0.60, 1.0)

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1024, 1024),
	Vector2i(1536, 1024),
	Vector2i(1920, 1080),
]
const VIDEO_FRAME_RATES: Array[int] = [12, 24, 30]

var _dock: ScrollContainer
var _dock_content: VBoxContainer
var _viewport_choice: OptionButton
var _resolution_choice: OptionButton
var _capture_button: Button
var _video_duration: SpinBox
var _use_camera_program_duration: CheckButton
var _video_program_end_padding: SpinBox
var _video_fps_choice: OptionButton
var _video_start_delay: SpinBox
var _keep_video_frames: CheckButton
var _record_video_button: Button
var _open_button: Button
var _status_label: Label
var _last_output_directory := ""
var _capturing := false
var _capture_scheduled := false
var _video_recording := false
var _video_capture_scheduled := false
var _video_cancel_requested := false
var _auto_video_resolution := false
var _recording_walk_controller: Node
var _recording_walk_was_playing := false
var _recording_fixed_step_active := false
var _recording_camera_program_was_playing := false
var _camera_follow_active := false
var _camera_follow_character: Node3D
var _camera_follow_target_path := FEMALE_PATH
var _camera_follow_base_relative_transform := Transform3D.IDENTITY
var _camera_follow_relative_transform := Transform3D.IDENTITY
## Canonical, reproducible shot setup.  Keep the orientation as a quaternion;
## Euler angles are only a calibration/readout convenience and can suffer from
## gimbal singularities or multiple equivalent representations.
var _camera_initial_view_relative_transform := Transform3D.IDENTITY
var _camera_initial_view_valid := false
var _camera_follow_viewport_index := 0
var _camera_work_zero_valid := false
var _camera_motion_program = CameraMotionProgram.new()
var _camera_program_loaded := false
var _camera_program_playing := false
var _camera_program_elapsed := 0.0
var _orbit_reference: Marker3D
var _camera_coordinate_status: Label
var _camera_coordinate_values: Label
var _camera_orbit_status: Label
var _camera_orbit_values: Label
var _calibration_refresh_accumulator := 0.0


func _enter_tree() -> void:
	# Scene @tool controllers cannot hold a serialized reference to an
	# EditorPlugin. Advertising this instance through a named editor-only group
	# gives inspector transport buttons a stable, dependency-free bridge.
	add_to_group(CAPTURE_SERVICE_GROUP)
	process_priority = 100
	set_process(true)
	_build_dock()
	# Keep the director panel beside Inspector where it remains discoverable.
	# The previous lower-right slot can collapse to zero height in saved editor
	# layouts, making a technically active dock look as if it disappeared.
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)
	# A menu command gives the capture a second, editor-native entry point. It is
	# also useful when another editor plugin consumes a dock button's mouse-up
	# event before Button.pressed can be emitted.
	add_tool_menu_item("Capture OTS Render Passes", _on_capture_pressed)
	add_tool_menu_item("Record OTS Editor Camera Video", _on_record_video_pressed)


func _exit_tree() -> void:
	_camera_follow_active = false
	set_process(false)
	remove_from_group(CAPTURE_SERVICE_GROUP)
	remove_tool_menu_item("Capture OTS Render Passes")
	remove_tool_menu_item("Record OTS Editor Camera Video")
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()


## Public editor-service entry point used by scene inspector transports. The
## same call stops an active recording, matching the capture dock button.
func request_editor_camera_video(options: Dictionary = {}) -> void:
	_on_record_video_pressed(options)


func set_editor_camera_initial_view(view: Dictionary) -> Dictionary:
	"""Store and apply a character-relative initial camera pose.

	The preferred wire representation is ``position`` plus
	``quaternion_xyzw``.  ``rotation_degrees`` is accepted as a compatibility
	fallback for hand-authored messages, but is never used as the canonical
	stored value.
	"""
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {"ok": false, "error": "edited_scene_missing"}
	var target_path := NodePath(str(view.get("target_node", str(FEMALE_PATH))))
	var character := scene_root.get_node_or_null(target_path) as Node3D
	if character == null:
		return {"ok": false, "error": "camera_follow_target_missing", "target_node": str(target_path)}
	var viewport_index := clampi(int(view.get("viewport_index", 0)), 0, 3)
	var position_value = view.get("position", view.get("translation", null))
	if not position_value is Array or (position_value as Array).size() < 3:
		return {"ok": false, "error": "camera_initial_position_missing"}
	var position := Vector3(float(position_value[0]), float(position_value[1]), float(position_value[2]))
	var quaternion_value = view.get("quaternion_xyzw", view.get("quaternion", null))
	var basis := Basis.IDENTITY
	if quaternion_value is Array and (quaternion_value as Array).size() >= 4:
		basis = Basis(Quaternion(
			float(quaternion_value[0]), float(quaternion_value[1]),
			float(quaternion_value[2]), float(quaternion_value[3])
		).normalized())
	else:
		var degrees_value = view.get("rotation_degrees", null)
		if not degrees_value is Array or (degrees_value as Array).size() < 3:
			return {"ok": false, "error": "camera_initial_quaternion_missing"}
		var degrees := Vector3(float(degrees_value[0]), float(degrees_value[1]), float(degrees_value[2]))
		basis = Basis.from_euler(Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)), EULER_ORDER_YXZ)
	var relative := Transform3D(basis, position)
	_camera_initial_view_relative_transform = relative
	_camera_initial_view_valid = true
	_camera_follow_character = character
	_camera_follow_target_path = target_path
	_camera_follow_viewport_index = viewport_index
	_camera_follow_base_relative_transform = relative
	_camera_follow_relative_transform = relative
	_camera_work_zero_valid = true
	var restore_result := _apply_camera_relative_transform(relative, character, viewport_index)
	if not bool(restore_result.get("ok", false)):
		return restore_result
	var payload := _camera_view_payload(relative)
	payload.merge({"ok": true, "target_node": str(target_path), "viewport_index": viewport_index}, true)
	return payload


func restore_editor_camera_initial_view() -> Dictionary:
	if not _camera_initial_view_valid:
		return {"ok": false, "error": "camera_initial_view_not_set"}
	var scene_root := EditorInterface.get_edited_scene_root()
	var character := scene_root.get_node_or_null(_camera_follow_target_path) as Node3D if scene_root != null else null
	if character == null:
		return {"ok": false, "error": "camera_follow_target_missing", "target_node": str(_camera_follow_target_path)}
	_camera_follow_character = character
	_camera_follow_base_relative_transform = _camera_initial_view_relative_transform
	_camera_follow_relative_transform = _camera_initial_view_relative_transform
	_camera_work_zero_valid = true
	var result := _apply_camera_relative_transform(
		_camera_initial_view_relative_transform, character, _camera_follow_viewport_index
	)
	if bool(result.get("ok", false)):
		result.merge(_camera_view_payload(_camera_initial_view_relative_transform), true)
	return result


func _apply_camera_relative_transform(relative: Transform3D, character: Node3D, viewport_index: int) -> Dictionary:
	var editor_viewport := EditorInterface.get_editor_viewport_3d(viewport_index)
	var editor_camera := editor_viewport.get_camera_3d() if editor_viewport != null else null
	if editor_camera == null:
		return {"ok": false, "error": "editor_camera_missing", "viewport_index": viewport_index}
	editor_camera.global_transform = character.global_transform * relative
	return {"ok": true}


func _camera_view_payload(relative: Transform3D) -> Dictionary:
	var q := relative.basis.get_rotation_quaternion()
	var euler := relative.basis.get_euler()
	return {
		"position": [relative.origin.x, relative.origin.y, relative.origin.z],
		"quaternion_xyzw": [q.x, q.y, q.z, q.w],
		"rotation_degrees": [rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z)],
	}


## Freeze the current editor camera's complete offset from the female root.
## Translation and heading changes then carry the camera without changing the
## director-authored shot angle, pitch, or distance.
func confirm_editor_camera_follow(options: Dictionary = {}) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_set_camera_follow_error("Open an editable scene before confirming camera follow.")
		return {"ok": false, "error": "edited_scene_missing"}
	var target_path := NodePath(str(options.get("target_node", str(FEMALE_PATH))))
	var character := scene_root.get_node_or_null(target_path) as Node3D
	if character == null:
		_set_camera_follow_error("The edited scene has no camera-follow target at %s." % target_path)
		return {"ok": false, "error": "camera_follow_target_missing", "target_node": str(target_path)}
	var viewport_index := int(options.get(
		"viewport_index",
		_viewport_choice.get_selected_id() if is_instance_valid(_viewport_choice) else 0
	))
	viewport_index = clampi(viewport_index, 0, 3)
	var editor_viewport := EditorInterface.get_editor_viewport_3d(viewport_index)
	var editor_camera := editor_viewport.get_camera_3d() if editor_viewport != null else null
	if editor_camera == null:
		_set_camera_follow_error("The selected editor viewport has no active 3D camera.")
		return {"ok": false, "error": "editor_camera_missing", "viewport_index": viewport_index}
	_camera_follow_character = character
	_camera_follow_target_path = target_path
	_camera_follow_viewport_index = viewport_index
	_camera_follow_base_relative_transform = character.global_transform.affine_inverse() \
		* editor_camera.global_transform
	_camera_work_zero_valid = true
	_camera_follow_relative_transform = _camera_follow_base_relative_transform
	_camera_follow_active = true
	_camera_program_loaded = false
	_camera_program_playing = false
	if _recording_fixed_step_active:
		_recording_camera_program_was_playing = false
	_camera_program_elapsed = 0.0
	var distance := _camera_follow_relative_transform.origin.length()
	var status := "Locked Viewport %d at %.2f m from %s." % [
		viewport_index + 1, distance, str(target_path),
	]
	_status_label.text = "Camera follow active. %s" % status
	editor_camera_follow_state_changed.emit(true, status)
	print("OTS_CAMERA_FOLLOW confirmed: %s" % status)
	return {
		"ok": true,
		"active": true,
		"target_node": str(target_path),
		"viewport_index": viewport_index,
		"distance": distance,
	}


func stop_editor_camera_follow() -> Dictionary:
	_camera_follow_active = false
	_camera_follow_character = null
	_camera_program_playing = false
	var status := "Camera follow released; the editor camera remains at its current shot."
	if is_instance_valid(_status_label):
		_status_label.text = status
	editor_camera_follow_state_changed.emit(false, status)
	print("OTS_CAMERA_FOLLOW stopped")
	return {"ok": true, "active": false}


func load_editor_camera_program(program: Dictionary, auto_play: bool = true) -> Dictionary:
	var requested_target := NodePath(str(program.get("target_node", str(FEMALE_PATH))))
	var requested_viewport := clampi(int(program.get("viewport_index", 0)), 0, 3)
	# A program carrying initial_view is reproducible from any current editor
	# camera.  Apply the exact quaternion pose before confirming follow so the
	# existing follow/work-zero path adopts this setup instead of the transient
	# viewport framing.
	var initial_view_value = program.get("initial_view", null)
	if initial_view_value is Dictionary:
		var initial_view := (initial_view_value as Dictionary).duplicate(true)
		initial_view["target_node"] = str(requested_target)
		initial_view["viewport_index"] = requested_viewport
		var initial_result := set_editor_camera_initial_view(initial_view)
		if not bool(initial_result.get("ok", false)):
			return initial_result
	if not _camera_follow_active or requested_target != _camera_follow_target_path or \
			requested_viewport != _camera_follow_viewport_index:
		var confirm_result := confirm_editor_camera_follow({
			"target_node": str(requested_target),
			"viewport_index": requested_viewport,
		})
		if not bool(confirm_result.get("ok", false)):
			return confirm_result
	var result := _camera_motion_program.configure(
		program, _camera_follow_base_relative_transform
	) as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_camera_program_loaded = true
	_camera_program_elapsed = 0.0
	# A program can be loaded after recording was requested (common for an
	# Emacs shot function). Adopt that late start into the recorder's fixed clock
	# instead of allowing the normal editor _process(delta) clock to race it.
	if (_video_recording or _video_capture_scheduled) and _recording_fixed_step_active and auto_play:
		_recording_camera_program_was_playing = true
		_camera_program_playing = false
	else:
		_camera_program_playing = auto_play
	_camera_follow_relative_transform = (_camera_motion_program.sample(0.0) as Dictionary).get(
		"transform", _camera_follow_base_relative_transform
	) as Transform3D
	var state := "playing" if auto_play else "loaded"
	var status := "%s %s: %d commands, %.3f seconds%s." % [
		"Playing" if auto_play else "Loaded",
		str(result.get("name", "camera program")),
		int(result.get("command_count", 0)),
		float(result.get("duration_seconds", 0.0)),
		", looping" if bool(result.get("loop", false)) else "",
	]
	editor_camera_program_state_changed.emit(state, status)
	if is_instance_valid(_status_label):
		_status_label.text = status
	return result.merged({"state": state}, true)


func play_editor_camera_program(restart: bool = false) -> Dictionary:
	if not _camera_program_loaded:
		return {"ok": false, "error": "camera_program_not_loaded"}
	if not _camera_follow_active:
		return {"ok": false, "error": "camera_follow_not_active"}
	if restart:
		_camera_program_elapsed = 0.0
	if (_video_recording or _video_capture_scheduled) and _recording_fixed_step_active:
		_recording_camera_program_was_playing = true
		_camera_program_playing = false
	else:
		_camera_program_playing = true
	var status := "Camera program playing at %.3f seconds." % _camera_program_elapsed
	editor_camera_program_state_changed.emit("playing", status)
	return {"ok": true, "state": "playing", "time_seconds": _camera_program_elapsed}


func pause_editor_camera_program() -> Dictionary:
	_camera_program_playing = false
	if (_video_recording or _video_capture_scheduled) and _recording_fixed_step_active:
		_recording_camera_program_was_playing = false
	var status := "Camera program paused at %.3f seconds." % _camera_program_elapsed
	editor_camera_program_state_changed.emit("paused", status)
	return {"ok": true, "state": "paused", "time_seconds": _camera_program_elapsed}


func reset_editor_camera_program() -> Dictionary:
	_camera_program_elapsed = 0.0
	_camera_program_playing = false
	_camera_follow_relative_transform = _camera_follow_base_relative_transform
	if _camera_program_loaded:
		_camera_follow_relative_transform = (_camera_motion_program.sample(0.0) as Dictionary).get(
			"transform", _camera_follow_base_relative_transform
		) as Transform3D
	var status := "Camera program reset to work zero."
	editor_camera_program_state_changed.emit("reset", status)
	return {"ok": true, "state": "reset", "time_seconds": 0.0}


func clear_editor_camera_program() -> Dictionary:
	_camera_program_loaded = false
	_camera_program_playing = false
	_camera_program_elapsed = 0.0
	_camera_follow_relative_transform = _camera_follow_base_relative_transform
	var status := "Camera program cleared; fixed follow remains active."
	editor_camera_program_state_changed.emit("cleared", status)
	return {"ok": true, "state": "cleared"}


func editor_camera_program_status() -> Dictionary:
	return {
		"ok": true,
		"follow_active": _camera_follow_active,
		"program_loaded": _camera_program_loaded,
		"program_playing": _camera_program_playing,
		"program_name": _camera_motion_program.name if _camera_program_loaded else "",
		"initial_view_valid": _camera_initial_view_valid,
		"target_node": str(_camera_follow_target_path) if _camera_follow_active else "",
		"viewport_index": _camera_follow_viewport_index if _camera_follow_active else -1,
		"time_seconds": _camera_program_elapsed,
		"duration_seconds": _camera_motion_program.duration_seconds if _camera_program_loaded else 0.0,
	}


func _process(delta: float) -> void:
	_calibration_refresh_accumulator += maxf(0.0, delta)
	var refresh_calibration := _calibration_refresh_accumulator >= 1.0 / 15.0
	if refresh_calibration:
		_calibration_refresh_accumulator = 0.0
	if not _camera_follow_active:
		if refresh_calibration:
			_update_camera_coordinate_panel()
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or not is_instance_valid(_camera_follow_character) or \
			_camera_follow_character != scene_root.get_node_or_null(_camera_follow_target_path):
		stop_editor_camera_follow()
		return
	var editor_viewport := EditorInterface.get_editor_viewport_3d(_camera_follow_viewport_index)
	var editor_camera := editor_viewport.get_camera_3d() if editor_viewport != null else null
	if editor_camera == null:
		stop_editor_camera_follow()
		return
	if _camera_program_loaded and _camera_program_playing:
		_camera_program_elapsed += maxf(0.0, delta)
		var program_sample := _camera_motion_program.sample(_camera_program_elapsed) as Dictionary
		_camera_follow_relative_transform = program_sample.get(
			"transform", _camera_follow_relative_transform
		) as Transform3D
		if bool(program_sample.get("finished", false)) and not _camera_motion_program.loop:
			_camera_program_elapsed = _camera_motion_program.duration_seconds
			_camera_program_playing = false
			editor_camera_program_state_changed.emit(
				"finished", "Camera program finished; holding its final work coordinate."
			)
	editor_camera.global_transform = _camera_follow_character.global_transform \
		* _camera_follow_relative_transform
	if refresh_calibration:
		_update_camera_coordinate_panel()


func _set_camera_follow_error(message: String) -> void:
	_camera_follow_active = false
	if is_instance_valid(_status_label):
		_status_label.text = message
	editor_camera_follow_state_changed.emit(false, "Error: %s" % message)
	push_warning("OTS Camera Follow: %s" % message)


func _build_dock() -> void:
	_dock = ScrollContainer.new()
	_dock.name = "OTS Render"
	_dock.custom_minimum_size = Vector2(260.0, 0.0)
	_dock.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_dock.follow_focus = true
	_dock.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Always expose the scrollbar: the dock contains both capture controls and
	# the camera calibration panel, which is taller than many editor layouts.
	_dock.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_dock_content = VBoxContainer.new()
	_dock_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dock_content.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_dock_content.add_theme_constant_override("separation", 8)
	_dock.add_child(_dock_content)

	var title := Label.new()
	title.text = "OTS Quick Render"
	title.add_theme_font_size_override("font_size", 16)
	_dock_content.add_child(title)

	var explanation := Label.new()
	explanation.text = "Frame the actors in the 3D editor, then capture the same camera as image-generation passes. If this dock button is intercepted, use Project > Tools > Capture OTS Render Passes."
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.modulate = Color(0.78, 0.82, 0.88)
	_dock_content.add_child(explanation)

	var viewport_row := HBoxContainer.new()
	var viewport_label := Label.new()
	viewport_label.text = "Editor view"
	viewport_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport_row.add_child(viewport_label)
	_viewport_choice = OptionButton.new()
	for index in 4:
		_viewport_choice.add_item("Viewport %d" % (index + 1), index)
		_viewport_choice.tooltip_text = "Viewport 1 is the normal single-view 3D editor. Choose 2–4 when using a split layout."
	viewport_row.add_child(_viewport_choice)
	_dock_content.add_child(viewport_row)

	var resolution_row := HBoxContainer.new()
	var resolution_label := Label.new()
	resolution_label.text = "Resolution"
	resolution_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resolution_row.add_child(resolution_label)
	_resolution_choice = OptionButton.new()
	for index in RESOLUTIONS.size():
		var resolution := RESOLUTIONS[index]
		_resolution_choice.add_item("%d × %d" % [resolution.x, resolution.y], index)
	resolution_row.add_child(_resolution_choice)
	_dock_content.add_child(resolution_row)

	_capture_button = Button.new()
	_capture_button.text = "Capture current editor camera"
	_capture_button.focus_mode = Control.FOCUS_CLICK
	_capture_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_capture_button.tooltip_text = "Write beauty, shaded character colors, linear depth, masks, and camera metadata. Fallback: Project > Tools > Capture OTS Render Passes."
	# Use button_down rather than pressed. Godot's pressed signal waits for the
	# matching mouse-up, which can be consumed by other editor plugins that
	# manage global viewport focus. The work itself is deferred below, so the
	# mouse event still completes before scene duplication begins.
	_capture_button.button_down.connect(_on_capture_pressed)
	_dock_content.add_child(_capture_button)

	var video_separator := HSeparator.new()
	_dock_content.add_child(video_separator)

	var video_title := Label.new()
	video_title.text = "H3 camera-motion guide"
	video_title.add_theme_font_size_override("font_size", 14)
	_dock_content.add_child(video_title)

	var video_explanation := Label.new()
	video_explanation.text = "Record the live editor camera and animated scene, then encode the sampled frames as an H.264 MP4. Camera navigation and streamed character poses are captured together."
	video_explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	video_explanation.modulate = Color(0.78, 0.82, 0.88)
	_dock_content.add_child(video_explanation)

	var duration_row := HBoxContainer.new()
	var duration_label := Label.new()
	duration_label.text = "Duration"
	duration_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	duration_row.add_child(duration_label)
	_video_duration = SpinBox.new()
	_video_duration.min_value = 1.0
	_video_duration.max_value = 30.0
	_video_duration.step = 0.5
	_video_duration.value = 5.0
	_video_duration.suffix = " s"
	_video_duration.tooltip_text = "Length of the encoded guide video. Longer or high-FPS captures take more disk space and time."
	duration_row.add_child(_video_duration)
	_dock_content.add_child(duration_row)

	_use_camera_program_duration = CheckButton.new()
	_use_camera_program_duration.text = "Auto-clip to camera program"
	_use_camera_program_duration.tooltip_text = "Use the loaded camera program's exact timeline duration instead of the manual Duration value."
	_dock_content.add_child(_use_camera_program_duration)

	var padding_row := HBoxContainer.new()
	var padding_label := Label.new()
	padding_label.text = "Program end padding"
	padding_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	padding_row.add_child(padding_label)
	_video_program_end_padding = SpinBox.new()
	_video_program_end_padding.min_value = -5.0
	_video_program_end_padding.max_value = 10.0
	_video_program_end_padding.step = 0.05
	_video_program_end_padding.value = 0.0
	_video_program_end_padding.suffix = " s"
	_video_program_end_padding.tooltip_text = "Add a final hold after the program; negative values clip before its authored end. Zero ends exactly with the camera program."
	padding_row.add_child(_video_program_end_padding)
	_dock_content.add_child(padding_row)

	var fps_row := HBoxContainer.new()
	var fps_label := Label.new()
	fps_label.text = "Capture FPS"
	fps_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fps_row.add_child(fps_label)
	_video_fps_choice = OptionButton.new()
	for index in VIDEO_FRAME_RATES.size():
		var frame_rate := VIDEO_FRAME_RATES[index]
		_video_fps_choice.add_item("%d FPS" % frame_rate, index)
	_video_fps_choice.select(0)
	_video_fps_choice.tooltip_text = "12 FPS is the most responsive editor-camera guide. Use 24/30 FPS only when the machine can capture the selected resolution fast enough."
	fps_row.add_child(_video_fps_choice)
	_dock_content.add_child(fps_row)

	var delay_row := HBoxContainer.new()
	var delay_label := Label.new()
	delay_label.text = "Start delay"
	delay_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	delay_row.add_child(delay_label)
	_video_start_delay = SpinBox.new()
	_video_start_delay.min_value = 0.0
	_video_start_delay.max_value = 10.0
	_video_start_delay.step = 0.5
	_video_start_delay.value = 2.0
	_video_start_delay.suffix = " s"
	_video_start_delay.tooltip_text = "Time to move the pointer from this dock into the 3D viewport before frame capture begins."
	delay_row.add_child(_video_start_delay)
	_dock_content.add_child(delay_row)

	_keep_video_frames = CheckButton.new()
	_keep_video_frames.text = "Keep source JPEG frames"
	_keep_video_frames.tooltip_text = "Normally the temporary JPEG sequence is deleted after MP4 encoding. Enable this for debugging or external encoders."
	_dock_content.add_child(_keep_video_frames)

	_record_video_button = Button.new()
	_record_video_button.text = "Record editor camera motion"
	_record_video_button.focus_mode = Control.FOCUS_CLICK
	_record_video_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_record_video_button.tooltip_text = "After the start delay, orbit/pan/zoom or stream character motion. Click again to stop early. Emacs can supply duration, FPS, resolution, delay, and frame-retention options."
	_record_video_button.button_down.connect(_on_record_video_pressed)
	_dock_content.add_child(_record_video_button)

	_open_button = Button.new()
	_open_button.text = "Show last capture in Finder"
	_open_button.disabled = true
	_open_button.pressed.connect(_show_last_capture)
	_dock_content.add_child(_open_button)

	_status_label = Label.new()
	_status_label.text = "Open my_manual_rig_pose.tscn and frame the OTS shot."
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.modulate = Color(0.9, 0.76, 0.38)
	_dock_content.add_child(_status_label)

	# Keep the primary recording workflow near the top of the dock. Camera
	# calibration is intentionally appended below it and remains reachable via
	# the always-visible vertical scrollbar.
	_build_camera_calibration_panel()


func _build_camera_calibration_panel() -> void:
	## Live director readout for the transient editor camera. These values are
	## the exact character-local coordinates consumed by the Emacs G-code DSL.
	var separator := HSeparator.new()
	_dock_content.add_child(separator)
	var title := Label.new()
	title.text = "Camera Work Coordinates"
	title.add_theme_font_size_override("font_size", 14)
	_dock_content.add_child(title)
	var help := Label.new()
	help.text = "Live editor view relative to IK_character. Quaternion XYZW is authoritative; Euler is only a readable angle view. Confirm follow to get G1 offsets from work zero."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate = Color(0.78, 0.82, 0.88)
	_dock_content.add_child(help)
	_camera_coordinate_status = Label.new()
	_camera_coordinate_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_camera_coordinate_status.modulate = Color(0.9, 0.76, 0.38)
	_dock_content.add_child(_camera_coordinate_status)
	_camera_coordinate_values = Label.new()
	_camera_coordinate_values.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_camera_coordinate_values.text = "Position: unavailable"
	_dock_content.add_child(_camera_coordinate_values)
	var calibration_actions := HBoxContainer.new()
	var set_zero := Button.new()
	set_zero.text = "Set work zero"
	set_zero.tooltip_text = "Remember the current framing as G-code work zero without locking the editor camera."
	set_zero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	set_zero.button_down.connect(_set_camera_work_zero_unlocked)
	calibration_actions.add_child(set_zero)
	var copy_g1 := Button.new()
	copy_g1.text = "Copy current G1 target"
	copy_g1.tooltip_text = "Copy a godot-camera-g1 form using the current camera offset from confirmed work zero."
	copy_g1.button_down.connect(_copy_current_g1_target)
	calibration_actions.add_child(copy_g1)
	_dock_content.add_child(calibration_actions)
	var initial_view_actions := HBoxContainer.new()
	var copy_initial_view := Button.new()
	copy_initial_view.text = "Copy initial view API"
	copy_initial_view.tooltip_text = "Copy a quaternion-based godot-camera-set-initial-view form for this exact framing."
	copy_initial_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_initial_view.button_down.connect(_copy_current_initial_view)
	initial_view_actions.add_child(copy_initial_view)
	var restore_initial_view := Button.new()
	restore_initial_view.text = "Restore initial view"
	restore_initial_view.tooltip_text = "Restore the last initial view captured through the API."
	restore_initial_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restore_initial_view.button_down.connect(_restore_initial_view_from_panel)
	initial_view_actions.add_child(restore_initial_view)
	_dock_content.add_child(initial_view_actions)
	var character_transform_actions := HBoxContainer.new()
	var copy_character_transform := Button.new()
	copy_character_transform.text = "Copy character placement API"
	copy_character_transform.tooltip_text = "Copy IK_character's current local position and quaternion as a godot-character-set-initial-position form."
	copy_character_transform.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_character_transform.button_down.connect(_copy_current_character_transform)
	character_transform_actions.add_child(copy_character_transform)
	_dock_content.add_child(character_transform_actions)

	var orbit_separator := HSeparator.new()
	_dock_content.add_child(orbit_separator)
	var orbit_title := Label.new()
	orbit_title.text = "Orbit Reference Gizmo"
	orbit_title.add_theme_font_size_override("font_size", 14)
	_dock_content.add_child(orbit_title)
	var orbit_help := Label.new()
	orbit_help.text = "Create/select the marker, then drag its gizmo in the 3D viewport. It defines the character-local orbit pivot."
	orbit_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	orbit_help.modulate = Color(0.78, 0.82, 0.88)
	_dock_content.add_child(orbit_help)
	var orbit_actions := HBoxContainer.new()
	var create_reference := Button.new()
	create_reference.text = "Create / select pivot"
	create_reference.tooltip_text = "Create CameraOrbitReference under IK_character and select it in the scene tree."
	create_reference.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create_reference.button_down.connect(_create_or_select_orbit_reference)
	orbit_actions.add_child(create_reference)
	var copy_g2 := Button.new()
	copy_g2.text = "Copy G2"
	copy_g2.tooltip_text = "Copy the measured orbit values as a godot-camera-g2-orbit form."
	copy_g2.button_down.connect(_copy_current_g2_orbit)
	orbit_actions.add_child(copy_g2)
	_dock_content.add_child(orbit_actions)
	_camera_orbit_status = Label.new()
	_camera_orbit_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_camera_orbit_status.modulate = Color(0.9, 0.76, 0.38)
	_dock_content.add_child(_camera_orbit_status)
	_camera_orbit_values = Label.new()
	_camera_orbit_values.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_camera_orbit_values.text = "Pivot: unavailable"
	_dock_content.add_child(_camera_orbit_values)


func _current_editor_camera() -> Camera3D:
	var viewport_index := _camera_follow_viewport_index
	if not _camera_follow_active and is_instance_valid(_viewport_choice):
		viewport_index = _viewport_choice.get_selected_id()
	var viewport := EditorInterface.get_editor_viewport_3d(clampi(viewport_index, 0, 3))
	return viewport.get_camera_3d() if viewport != null else null


func _camera_measurement_character() -> Node3D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	if is_instance_valid(_camera_follow_character):
		return _camera_follow_character
	return scene_root.get_node_or_null(FEMALE_PATH) as Node3D


func _camera_relative_transform() -> Transform3D:
	var character := _camera_measurement_character()
	var camera := _current_editor_camera()
	if character == null or not character.is_inside_tree() or camera == null or not camera.is_inside_tree():
		return Transform3D.IDENTITY
	return character.global_transform.affine_inverse() * camera.global_transform


func _update_camera_coordinate_panel() -> void:
	if not is_instance_valid(_camera_coordinate_values):
		return
	var character := _camera_measurement_character()
	var camera := _current_editor_camera()
	if character == null or not character.is_inside_tree() or camera == null or not camera.is_inside_tree():
		_camera_coordinate_status.text = "Open a 3D scene and select an editor viewport."
		_camera_coordinate_values.text = "Position: unavailable"
		_camera_orbit_status.text = "Create the pivot marker after opening the scene."
		_camera_orbit_values.text = "Pivot: unavailable"
		return
	var relative := character.global_transform.affine_inverse() * camera.global_transform
	var p := relative.origin
	var quaternion := relative.basis.get_rotation_quaternion()
	var degrees := relative.basis.get_euler() * 180.0 / PI
	var work_offset := relative.origin - _camera_follow_base_relative_transform.origin
	var zero_state := "follow active" if _camera_follow_active else \
		("work zero set; camera unlocked" if _camera_work_zero_valid else "work zero not set")
	_camera_coordinate_status.text = "Viewport %d • %s" % [
		(_camera_follow_viewport_index if _camera_follow_active else _viewport_choice.get_selected_id()) + 1,
		zero_state,
	]
	_camera_coordinate_values.text = "Current local camera\n  X %+.3f   Y %+.3f   Z %+.3f\nRotation (quaternion XYZW)\n  X %+.6f  Y %+.6f  Z %+.6f  W %+.6f\nEuler readout (degrees)\n  X %+.1f   Y %+.1f   Z %+.1f\nG1 target from work zero\n  X %+.3f   Y %+.3f   Z %+.3f" % [
		p.x, p.y, p.z, quaternion.x, quaternion.y, quaternion.z, quaternion.w,
		degrees.x, degrees.y, degrees.z,
		work_offset.x, work_offset.y, work_offset.z,
	]
	_update_orbit_measurement(relative)


func _update_orbit_measurement(camera_relative: Transform3D) -> void:
	var character := _camera_measurement_character()
	if not is_instance_valid(_orbit_reference) and character != null:
		_orbit_reference = character.get_node_or_null(NodePath(CAMERA_REFERENCE_NAME)) as Marker3D
	if character == null or not character.is_inside_tree() or \
			not is_instance_valid(_orbit_reference) or not _orbit_reference.is_inside_tree():
		_camera_orbit_status.text = "Create / select the pivot marker to measure orbit."
		_camera_orbit_values.text = "Pivot: unavailable"
		return
	var pivot := character.global_transform.affine_inverse() * _orbit_reference.global_transform
	var base_arm := _camera_follow_base_relative_transform.origin - pivot.origin
	var current_arm := camera_relative.origin - pivot.origin
	var base_horizontal := Vector2(base_arm.x, base_arm.z)
	var current_horizontal := Vector2(current_arm.x, current_arm.z)
	var base_radius := base_horizontal.length()
	var current_radius := current_horizontal.length()
	var radius_delta := current_radius - base_radius
	var base_pitch := rad_to_deg(atan2(base_arm.y, maxf(0.0001, base_radius)))
	var current_pitch := rad_to_deg(atan2(current_arm.y, maxf(0.0001, current_radius)))
	var pitch_delta := current_pitch - base_pitch
	var yaw_delta := 0.0
	if base_radius > 0.0001 and current_radius > 0.0001:
		yaw_delta = rad_to_deg(base_horizontal.angle_to(current_horizontal))
	var height_delta := camera_relative.origin.y - _camera_follow_base_relative_transform.origin.y
	_camera_orbit_status.text = "Marker: %s (drag its gizmo)" % _orbit_reference.name
	_camera_orbit_values.text = "Pivot local\n  X %+.3f   Y %+.3f   Z %+.3f\nDerived G2/G3 values\n  yaw %+.1f°   pitch %+.1f°\n  radius-delta %+.3f m\n  height-delta %+.3f m" % [
		pivot.origin.x, pivot.origin.y, pivot.origin.z,
		yaw_delta, pitch_delta, radius_delta, height_delta,
	]


func _create_or_select_orbit_reference() -> void:
	var character := _camera_measurement_character()
	var scene_root := EditorInterface.get_edited_scene_root()
	if character == null or scene_root == null:
		return
	if not is_instance_valid(_orbit_reference):
		_orbit_reference = character.get_node_or_null(NodePath(CAMERA_REFERENCE_NAME)) as Marker3D
	if not is_instance_valid(_orbit_reference):
		_orbit_reference = Marker3D.new()
		_orbit_reference.name = CAMERA_REFERENCE_NAME
		_orbit_reference.gizmo_extents = 0.35
		character.add_child(_orbit_reference)
		_orbit_reference.owner = scene_root
		_orbit_reference.position = Vector3(0.0, 1.2, 0.0)
		_orbit_reference.set_meta("ots_camera_orbit_reference", true)
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(_orbit_reference)
	_camera_orbit_status.text = "Marker selected; drag its gizmo, then copy G2."
	_update_camera_coordinate_panel()


func _copy_current_g1_target() -> void:
	if not _camera_work_zero_valid:
		_camera_coordinate_status.text = "Set work zero first; G1 uses offsets from that framing."
		return
	var relative := _camera_relative_transform()
	var offset := relative.origin - _camera_follow_base_relative_transform.origin
	DisplayServer.clipboard_set(
		"(godot-camera-g1 :x %.4f :y %.4f :z %.4f)" % [offset.x, offset.y, offset.z]
	)
	_status_label.text = "Copied current G1 target to the system clipboard."


func _copy_current_initial_view() -> void:
	var character := _camera_measurement_character()
	var camera := _current_editor_camera()
	if character == null or camera == null:
		_camera_coordinate_status.text = "Open a 3D scene and select an editor viewport first."
		return
	var relative := character.global_transform.affine_inverse() * camera.global_transform
	var q := relative.basis.get_rotation_quaternion()
	var command := "(godot-camera-set-initial-view :position '(%.6f %.6f %.6f) :quaternion '(%.9f %.9f %.9f %.9f))" % [
		relative.origin.x, relative.origin.y, relative.origin.z,
		q.x, q.y, q.z, q.w,
	]
	DisplayServer.clipboard_set(command)
	_camera_initial_view_relative_transform = relative
	_camera_initial_view_valid = true
	_camera_follow_character = character
	_camera_follow_target_path = character.get_path()
	_camera_follow_viewport_index = _viewport_choice.get_selected_id() if is_instance_valid(_viewport_choice) else _camera_follow_viewport_index
	_camera_follow_base_relative_transform = relative
	_camera_work_zero_valid = true
	_status_label.text = "Copied quaternion initial-view API to the system clipboard."


func _copy_current_character_transform() -> void:
	## Copy the transform consumed by `godot-character-set-initial-position`.
	##
	## `position` and `quaternion` are intentionally read from the character's
	## local transform, rather than its global transform. The Emacs API places
	## IK_character relative to its scene parent, and the quaternion is emitted
	## in the same XYZW order accepted by the pose-stream receiver.
	var character := _camera_measurement_character()
	if character == null:
		_camera_coordinate_status.text = "Open a scene containing IK_character first."
		return
	var p := character.position
	var q := character.quaternion.normalized()
	var command := "(godot-character-set-initial-position\n :position '(%.6f %.6f %.6f)\n :quaternion '(%.9f %.9f %.9f %.9f))" % [
		p.x, p.y, p.z, q.x, q.y, q.z, q.w,
	]
	DisplayServer.clipboard_set(command)
	_status_label.text = "Copied IK_character position/quaternion API to the system clipboard."


func _restore_initial_view_from_panel() -> void:
	var result := restore_editor_camera_initial_view()
	if bool(result.get("ok", false)):
		_status_label.text = "Restored quaternion initial camera view."
	else:
		_camera_coordinate_status.text = "No initial view captured yet. Use Copy initial view API after framing the shot."


func _copy_current_g2_orbit() -> void:
	if not _camera_work_zero_valid or not is_instance_valid(_orbit_reference):
		_camera_orbit_status.text = "Set work zero and create the pivot marker first."
		return
	var relative := _camera_relative_transform()
	var character := _camera_measurement_character()
	var pivot := character.global_transform.affine_inverse() * _orbit_reference.global_transform
	var base_arm := _camera_follow_base_relative_transform.origin - pivot.origin
	var current_arm := relative.origin - pivot.origin
	var base_horizontal := Vector2(base_arm.x, base_arm.z)
	var current_horizontal := Vector2(current_arm.x, current_arm.z)
	var base_radius := base_horizontal.length()
	var current_radius := current_horizontal.length()
	var yaw := rad_to_deg(base_horizontal.angle_to(current_horizontal)) if base_radius > 0.0001 and current_radius > 0.0001 else 0.0
	var pitch := rad_to_deg(atan2(current_arm.y, maxf(0.0001, current_radius))) - rad_to_deg(atan2(base_arm.y, maxf(0.0001, base_radius)))
	var radius_delta := current_radius - base_radius
	var height_delta := relative.origin.y - _camera_follow_base_relative_transform.origin.y
	var command := "(godot-camera-g%s-orbit :degrees %.2f :pitch %.2f :radius-delta %.4f :height-delta %.4f :pivot '(%.4f %.4f %.4f))" % [
		"2" if yaw <= 0.0 else "3", absf(yaw), pitch, radius_delta, height_delta,
		pivot.origin.x, pivot.origin.y, pivot.origin.z,
	]
	DisplayServer.clipboard_set(command)
	_status_label.text = "Copied current orbit parameters to the system clipboard."


func _set_camera_work_zero_unlocked() -> void:
	var character := _camera_measurement_character()
	var camera := _current_editor_camera()
	if character == null or camera == null:
		_camera_coordinate_status.text = "Open a 3D scene and select an editor viewport first."
		return
	_camera_follow_character = null
	_camera_follow_target_path = FEMALE_PATH
	_camera_follow_viewport_index = _viewport_choice.get_selected_id()
	_camera_follow_base_relative_transform = character.global_transform.affine_inverse() \
		* camera.global_transform
	_camera_follow_relative_transform = _camera_follow_base_relative_transform
	_camera_follow_active = false
	_camera_work_zero_valid = true
	_camera_program_playing = false
	_camera_coordinate_status.text = "Work zero set; editor camera remains unlocked for calibration."
	_status_label.text = "Camera work zero set. Navigate to an endpoint, then copy G1 or G2/G3."
	_update_camera_coordinate_panel()


func _on_capture_pressed() -> void:
	if _capturing or _capture_scheduled or _video_recording or _video_capture_scheduled:
		_status_label.text = "A capture is already active. Wait for completion or reload the OTS Render plugin if it remains stuck."
		return
	_capture_scheduled = true
	_status_label.text = "Capture requested; preparing the current editor camera…"
	print("OTS_CAPTURE requested from editor viewport %d" % (_viewport_choice.get_selected_id() + 1))
	call_deferred("_capture_current_editor_camera")


func _capture_current_editor_camera() -> void:
	_capture_scheduled = false
	_capturing = true
	_capture_button.disabled = true
	_record_video_button.disabled = true
	_open_button.disabled = true
	_status_label.text = "Preparing off-screen capture…"

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_finish_with_error("Open an editable 3D scene before capturing.")
		return
	if scene_root.get_node_or_null(FEMALE_PATH) == null or scene_root.get_node_or_null(MALE_PATH) == null:
		_finish_with_error("The scene needs both IK_character and MaleCarrier nodes.")
		return

	var editor_viewport := EditorInterface.get_editor_viewport_3d(_viewport_choice.get_selected_id())
	if editor_viewport == null:
		_finish_with_error("The selected editor viewport is unavailable.")
		return
	var editor_camera := editor_viewport.get_camera_3d()
	if editor_camera == null:
		_finish_with_error("The selected editor viewport has no active 3D camera.")
		return

	var resolution := RESOLUTIONS[_resolution_choice.get_selected_id()]
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var output_resource_path := "%s/%s" % [OUTPUT_ROOT, timestamp]
	var output_directory := ProjectSettings.globalize_path(output_resource_path)
	var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error != OK:
		_finish_with_error("Could not create %s (error %d)." % [output_directory, directory_error])
		return

	var capture_viewport := SubViewport.new()
	capture_viewport.name = "OTSOffscreenCapture"
	capture_viewport.size = resolution
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	capture_viewport.own_world_3d = true
	capture_viewport.msaa_3d = Viewport.MSAA_DISABLED
	capture_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	capture_viewport.use_taa = false
	add_child(capture_viewport)

	var capture_scene := _duplicate_scene_snapshot(scene_root)
	if capture_scene == null:
		capture_viewport.queue_free()
		_finish_with_error("Could not duplicate the edited scene for an isolated capture.")
		return
	capture_scene.name = "OTSCaptureScene"
	capture_viewport.add_child(capture_scene)
	var female_root := capture_scene.get_node_or_null(FEMALE_PATH)
	var male_root := capture_scene.get_node_or_null(MALE_PATH)
	var geometry := _collect_geometry(capture_scene)
	if geometry.is_empty():
		capture_viewport.queue_free()
		_finish_with_error("No GeometryInstance3D nodes were found in the edited scene.")
		return

	var capture_camera := Camera3D.new()
	capture_camera.name = "OTSEditorCameraCopy"
	capture_viewport.add_child(capture_camera)
	_copy_camera(editor_camera, capture_camera, Vector2(resolution))
	capture_camera.current = true
	var depth_range := _calculate_depth_range(capture_camera, geometry)

	_status_label.text = "Rendering beauty pass…"
	capture_viewport.transparent_bg = false
	var beauty := await _render_image(capture_viewport)
	var beauty_error := beauty.save_png(output_directory.path_join("beauty.png"))

	_status_label.text = "Rendering shaded character-color reference…"
	var female_reference_material := _make_reference_material(FEMALE_REFERENCE_COLOR)
	var male_reference_material := _make_reference_material(MALE_REFERENCE_COLOR)
	var environment_reference_material := _make_reference_material(ENVIRONMENT_REFERENCE_COLOR)
	for instance in geometry:
		if _is_within(instance, female_root):
			instance.material_override = female_reference_material
		elif _is_within(instance, male_root):
			instance.material_override = male_reference_material
		else:
			instance.material_override = environment_reference_material
	capture_viewport.transparent_bg = false
	var character_color_reference := await _render_image(capture_viewport)
	var character_color_reference_error := character_color_reference.save_png(
		output_directory.path_join("character_color_reference.png")
	)

	_status_label.text = "Rendering linear depth…"
	var depth_material := _make_depth_material(depth_range.x, depth_range.y)
	for instance in geometry:
		instance.material_override = depth_material
	capture_viewport.transparent_bg = true
	var depth_source := await _render_image(capture_viewport)
	var depth := _flatten_depth_over_black(depth_source)
	var depth_error := depth.save_png(output_directory.path_join("depth_near_white.png"))

	_status_label.text = "Rendering female and male masks…"
	var female_material := _make_id_material(Color(1.0, 0.0, 0.0, 1.0))
	var male_material := _make_id_material(Color(0.0, 1.0, 0.0, 1.0))
	var other_material := _make_id_material(Color(0.0, 0.0, 0.0, 1.0))
	for instance in geometry:
		if _is_within(instance, female_root):
			instance.material_override = female_material
		elif _is_within(instance, male_root):
			instance.material_override = male_material
		else:
			# Keep props as black depth occluders so masks represent the pixels
			# actually visible from this camera, rather than X-ray silhouettes.
			instance.material_override = other_material
	var id_source := await _render_image(capture_viewport)
	var masks := _split_character_masks(id_source)
	var female_mask: Image = masks[0]
	var male_mask: Image = masks[1]
	var id_mask: Image = masks[2]
	var female_error := female_mask.save_png(output_directory.path_join("mask_female.png"))
	var male_error := male_mask.save_png(output_directory.path_join("mask_male_carrier.png"))
	var id_error := id_mask.save_png(output_directory.path_join("mask_character_ids.png"))

	var metadata_error := _write_camera_metadata(
		output_directory.path_join("camera.json"),
		capture_camera,
		resolution,
		output_resource_path,
		depth_range
	)
	capture_viewport.queue_free()
	var errors := [
		beauty_error,
		character_color_reference_error,
		depth_error,
		female_error,
		male_error,
		id_error,
		metadata_error,
	]
	for error in errors:
		if error != OK:
			_finish_with_error("Capture finished incompletely; an output file returned error %d." % error)
			return

	_last_output_directory = output_directory
	_open_button.disabled = false
	_capture_button.disabled = false
	_record_video_button.disabled = false
	_capturing = false
	_status_label.text = "Captured beauty, shaded character colors, depth, masks, and camera.json to:\n%s" % output_resource_path
	print("OTS_CAPTURE completed: %s" % output_directory)


func _on_record_video_pressed(options: Dictionary = {}) -> void:
	if _video_recording:
		_video_cancel_requested = true
		_record_video_button.disabled = true
		_record_video_button.text = "Stopping after current frame…"
		_status_label.text = "Stopping the camera-motion capture after the current frame…"
		editor_camera_video_state_changed.emit(
			true, "Stopping after the current captured frame…"
		)
		return
	if _capturing or _capture_scheduled or _video_capture_scheduled:
		_status_label.text = "A capture is already active. Wait for it to finish."
		return
	_video_capture_scheduled = true
	_video_cancel_requested = false
	_apply_video_options(options)
	# Enter the fixed-step clock immediately, before the deferred scene-copy
	# setup. Emacs commonly sends walk.restart and camera.program.load directly
	# after this request; locking here prevents even one ordinary editor frame
	# from racing those commands.
	var pending_scene_root := EditorInterface.get_edited_scene_root()
	if pending_scene_root != null:
		_begin_fixed_step_capture(pending_scene_root)
	_status_label.text = "Camera-motion recording requested; preparing fixed-step scene capture…"
	editor_camera_video_state_changed.emit(
		true, "Recording requested; preparing fixed-step off-screen capture…"
	)
	print("OTS_VIDEO requested from editor viewport %d" % (_viewport_choice.get_selected_id() + 1))
	call_deferred("_record_editor_camera_video")


func _apply_video_options(options: Dictionary) -> void:
	"""Apply transport-supplied recording options before a new take.

	The dock remains the visual editor, while Emacs/TCP can author the same
	parameters deterministically. Unknown fields are ignored for forward
	compatibility.
	"""
	if options.is_empty():
		return
	if options.has("auto_resolution"):
		_auto_video_resolution = bool(options.get("auto_resolution"))
	if options.has("duration") and is_instance_valid(_video_duration):
		_video_duration.value = clampf(float(options.get("duration")), _video_duration.min_value, _video_duration.max_value)
	if options.has("auto_clip_to_camera_program") and is_instance_valid(_use_camera_program_duration):
		_use_camera_program_duration.button_pressed = bool(options.get("auto_clip_to_camera_program"))
	if options.has("program_end_padding") and is_instance_valid(_video_program_end_padding):
		_video_program_end_padding.value = clampf(
			float(options.get("program_end_padding")),
			_video_program_end_padding.min_value,
			_video_program_end_padding.max_value
		)
	if options.has("start_delay") and is_instance_valid(_video_start_delay):
		_video_start_delay.value = clampf(float(options.get("start_delay")), _video_start_delay.min_value, _video_start_delay.max_value)
	if options.has("keep_frames") and is_instance_valid(_keep_video_frames):
		_keep_video_frames.button_pressed = bool(options.get("keep_frames"))
	if options.has("fps") and is_instance_valid(_video_fps_choice):
		var requested_fps := int(options.get("fps"))
		for index in VIDEO_FRAME_RATES.size():
			if VIDEO_FRAME_RATES[index] == requested_fps:
				_video_fps_choice.select(index)
				break
	if (options.has("resolution") or (options.has("width") and options.has("height"))) and is_instance_valid(_resolution_choice):
		_auto_video_resolution = false
		var resolution_value = options.get("resolution", null)
		var requested_size := Vector2i.ZERO
		if resolution_value is Array and (resolution_value as Array).size() >= 2:
			requested_size = Vector2i(int(resolution_value[0]), int(resolution_value[1]))
		elif options.has("width") and options.has("height"):
			requested_size = Vector2i(int(options.get("width")), int(options.get("height")))
		if requested_size != Vector2i.ZERO:
			for index in RESOLUTIONS.size():
				if RESOLUTIONS[index] == requested_size:
					_resolution_choice.select(index)
					break
	if options.has("viewport") and is_instance_valid(_viewport_choice):
		# Emacs presents viewport numbers as 1-based; the Godot control stores ids.
		_viewport_choice.select(clampi(int(options.get("viewport")) - 1, 0, 3))
	elif options.has("viewport_index") and is_instance_valid(_viewport_choice):
		_viewport_choice.select(clampi(int(options.get("viewport_index")), 0, 3))


func _record_editor_camera_video() -> void:
	_video_capture_scheduled = false
	_video_recording = true
	_capture_button.disabled = true
	_open_button.disabled = true
	_set_video_options_enabled(false)
	_record_video_button.disabled = false
	_record_video_button.text = "Stop recording"

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_finish_video_with_error("Open an editable 3D scene before recording.")
		return
	if not _recording_fixed_step_active:
		_begin_fixed_step_capture(scene_root)

	var editor_viewport := EditorInterface.get_editor_viewport_3d(_viewport_choice.get_selected_id())
	if editor_viewport == null:
		_finish_video_with_error("The selected editor viewport is unavailable.")
		return
	var editor_camera := editor_viewport.get_camera_3d()
	if editor_camera == null:
		_finish_video_with_error("The selected editor viewport has no active 3D camera.")
		return

	var ffmpeg_path := _find_ffmpeg()
	if ffmpeg_path.is_empty():
		_finish_video_with_error("FFmpeg was not found. Install it with `brew install ffmpeg`, then retry.")
		return

	var resolution := _video_resolution_for_viewport(editor_viewport)
	var fps := VIDEO_FRAME_RATES[_video_fps_choice.get_selected_id()]
	var start_delay := float(_video_start_delay.value)
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var output_resource_path := "%s/%s-camera-motion" % [OUTPUT_ROOT, timestamp]
	var output_directory := ProjectSettings.globalize_path(output_resource_path)
	var frames_directory := output_directory.path_join("camera_motion_frames")
	var directory_error := DirAccess.make_dir_recursive_absolute(frames_directory)
	if directory_error != OK:
		_finish_video_with_error("Could not create %s (error %d)." % [frames_directory, directory_error])
		return

	var capture_viewport := SubViewport.new()
	capture_viewport.name = "OTSVideoOffscreenCapture"
	capture_viewport.size = resolution
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	capture_viewport.own_world_3d = true
	capture_viewport.msaa_3d = Viewport.MSAA_DISABLED
	capture_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	capture_viewport.use_taa = false
	capture_viewport.transparent_bg = false
	add_child(capture_viewport)

	# Render through an isolated copy so editor gizmos never enter the video.
	# Unlike a still snapshot, the copy is synchronized from the evaluated editor
	# scene before every frame; this captures pose.frame FK, modifier-evaluated IK,
	# root motion, animated props, and camera motion without touching the scene.
	var capture_scene := _duplicate_scene_snapshot(scene_root)
	if capture_scene == null:
		capture_viewport.queue_free()
		_finish_video_with_error("Could not duplicate the edited scene for video capture.")
		return
	capture_scene.name = "OTSVideoCaptureScene"
	capture_viewport.add_child(capture_scene)
	_prepare_live_capture_copy(capture_scene)
	var live_scene_bindings := _build_live_capture_bindings(scene_root, capture_scene)
	var skeleton_binding_count := (live_scene_bindings.get("skeletons", []) as Array).size()
	print("OTS_VIDEO live scene bindings: nodes=%d skeletons=%d meshes=%d" % [
		(live_scene_bindings.get("nodes", []) as Array).size(),
		skeleton_binding_count,
		(live_scene_bindings.get("meshes", []) as Array).size(),
	])

	var capture_camera := Camera3D.new()
	capture_camera.name = "OTSVideoEditorCameraCopy"
	capture_viewport.add_child(capture_camera)
	_copy_camera(editor_camera, capture_camera, Vector2(resolution))
	capture_camera.current = true

	var delay_deadline_usec := Time.get_ticks_usec() + int(start_delay * 1000000.0)
	while Time.get_ticks_usec() < delay_deadline_usec and not _video_cancel_requested:
		var remaining := maxf(float(delay_deadline_usec - Time.get_ticks_usec()) / 1000000.0, 0.0)
		_status_label.text = "Camera recording begins in %.1f s — move the pointer into the 3D viewport." % remaining
		await get_tree().process_frame

	if _video_cancel_requested:
		capture_viewport.queue_free()
		_remove_frame_directory(frames_directory)
		DirAccess.remove_absolute(output_directory)
		_end_fixed_step_capture()
		_finish_video_cancelled("Camera-motion recording cancelled before the first frame.")
		return

	# Resolve automatic duration after the preparation delay. This permits a
	# program sent immediately after the record request to be adopted before the
	# first output frame, while the preferred workflow still loads it first.
	var requested_duration := float(_video_duration.value)
	var duration_source := "manual"
	var camera_program_duration := 0.0
	var program_end_padding := float(_video_program_end_padding.value)
	if _use_camera_program_duration.button_pressed:
		if not _camera_program_loaded or _camera_motion_program.duration_seconds <= 0.0:
			capture_viewport.queue_free()
			_remove_frame_directory(frames_directory)
			DirAccess.remove_absolute(output_directory)
			_finish_video_with_error(
				"Auto-clip requires a loaded camera program. Send the program before starting the recording."
			)
			return
		camera_program_duration = _camera_motion_program.duration_seconds
		requested_duration = maxf(1.0 / float(fps), camera_program_duration + program_end_padding)
		duration_source = "camera_program"
	var requested_frames := maxi(1, ceili(requested_duration * float(fps)))

	var camera_samples: Array[Dictionary] = []
	var captured_frames := 0
	for frame_index in requested_frames:
		if _video_cancel_requested:
			break

		_sync_live_capture_state(live_scene_bindings)
		_copy_camera(editor_camera, capture_camera, Vector2(resolution))
		var timing_sample := _serialize_camera_sample(capture_camera, frame_index, fps)
		if is_instance_valid(_recording_walk_controller):
			timing_sample["walk_time_seconds"] = float(
				_recording_walk_controller.get("preview_time_seconds")
			)
		timing_sample["camera_program_time_seconds"] = _camera_program_elapsed
		var sampled_character := scene_root.get_node_or_null(FEMALE_PATH) as Node3D
		if sampled_character != null:
			timing_sample["character_position"] = [
				sampled_character.global_position.x,
				sampled_character.global_position.y,
				sampled_character.global_position.z,
			]
		camera_samples.append(timing_sample)
		var frame_image := await _render_image(capture_viewport)
		var frame_path := frames_directory.path_join("frame_%06d.jpg" % frame_index)
		var frame_error := frame_image.save_jpg(frame_path, 0.94)
		if frame_error != OK:
			capture_viewport.queue_free()
			_finish_video_with_error(
				"Could not save video frame %d (error %d). Source frames were retained in %s."
				% [frame_index, frame_error, frames_directory]
			)
			return
		captured_frames += 1
		_status_label.text = "Recording camera + live scene: frame %d / %d — orbit, navigate, or stream motion now." % [captured_frames, requested_frames]
		# Advance the source evaluator only after the frame has been rendered.
		# This fixed-step clock is independent of GPU/JPEG latency, so expensive
		# avatar skinning cannot make the resulting MP4 play fast-forwarded.
		_advance_fixed_step_capture(1.0 / float(fps))

	capture_viewport.queue_free()
	if captured_frames == 0:
		_remove_frame_directory(frames_directory)
		DirAccess.remove_absolute(output_directory)
		_end_fixed_step_capture()
		_finish_video_cancelled("Camera-motion recording stopped before a frame was captured.")
		return

	_status_label.text = "Encoding %d frames as H.264 MP4…" % captured_frames
	await get_tree().process_frame
	var video_path := output_directory.path_join("editor_camera_motion.mp4")
	var ffmpeg_arguments := PackedStringArray([
		"-hide_banner",
		"-loglevel", "error",
		"-y",
		"-framerate", str(fps),
		"-start_number", "0",
		"-i", frames_directory.path_join("frame_%06d.jpg"),
		"-frames:v", str(captured_frames),
		"-an",
		"-c:v", "libx264",
		"-preset", "medium",
		"-crf", "17",
		"-vf", "scale=in_range=full:out_range=tv,format=yuv420p",
		"-pix_fmt", "yuv420p",
		"-color_range", "tv",
		"-colorspace", "bt709",
		"-color_primaries", "bt709",
		"-color_trc", "bt709",
		"-movflags", "+faststart",
		video_path,
	])
	var encoder_output: Array = []
	var encoder_exit_code := OS.execute(ffmpeg_path, ffmpeg_arguments, encoder_output, true)
	if encoder_exit_code != 0 or not FileAccess.file_exists(video_path):
		var diagnostic := "\n".join(encoder_output)
		_finish_video_with_error(
			"FFmpeg failed with exit code %d. Source frames were retained in %s.\n%s"
			% [encoder_exit_code, frames_directory, diagnostic]
		)
		return

	var metadata_error := _write_video_metadata(
		output_directory.path_join("camera_motion.json"),
		resolution,
		fps,
		requested_duration,
		duration_source,
		camera_program_duration,
		program_end_padding,
		captured_frames,
		output_resource_path,
		camera_samples,
		ffmpeg_path,
		live_scene_bindings
	)
	if metadata_error != OK:
		_finish_video_with_error("MP4 was encoded, but camera_motion.json could not be written (error %d)." % metadata_error)
		return

	if not _keep_video_frames.button_pressed:
		_remove_frame_directory(frames_directory)

	_last_output_directory = output_directory
	_end_fixed_step_capture()
	_open_button.disabled = false
	_capture_button.disabled = false
	_video_recording = false
	_video_cancel_requested = false
	_set_video_options_enabled(true)
	_record_video_button.disabled = false
	_record_video_button.text = "Record editor camera motion"
	var actual_duration := float(captured_frames) / float(fps)
	_status_label.text = "Recorded %d frames (%.2f s at %d FPS, fixed-step timing) to:\n%s" % [captured_frames, actual_duration, fps, output_resource_path]
	editor_camera_video_state_changed.emit(
		false,
		"Finished: %s/editor_camera_motion.mp4" % output_resource_path
	)
	print("OTS_VIDEO completed: %s" % video_path)


func _begin_fixed_step_capture(scene_root: Node) -> void:
	_recording_fixed_step_active = true
	_recording_walk_controller = scene_root.find_child("FemaleWalkController", true, false)
	if _recording_walk_controller == null:
		_recording_walk_controller = _find_fixed_step_controller(scene_root)
	_recording_walk_was_playing = false
	if is_instance_valid(_recording_walk_controller) and \
			_recording_walk_controller.has_method("editor_capture_begin_fixed_step"):
		var walk_state := _recording_walk_controller.call("editor_capture_begin_fixed_step") as Dictionary
		_recording_walk_was_playing = bool(walk_state.get("was_playing", false))
	# A programmed camera has the same wall-clock problem as the walk evaluator.
	# Freeze its normal _process clock and advance it beside the fixed gait step.
	_recording_camera_program_was_playing = _camera_program_loaded and _camera_program_playing
	if _recording_camera_program_was_playing:
		_camera_program_playing = false


func _find_fixed_step_controller(node: Node) -> Node:
	if node.has_method("editor_capture_begin_fixed_step") and \
			node.has_method("editor_capture_step_fixed"):
		return node
	for child in node.get_children():
		var found := _find_fixed_step_controller(child)
		if found != null:
			return found
	return null


func _advance_fixed_step_capture(delta_seconds: float) -> void:
	if not _recording_fixed_step_active:
		return
	if is_instance_valid(_recording_walk_controller) and \
			_recording_walk_controller.has_method("editor_capture_step_fixed"):
		_recording_walk_controller.call("editor_capture_step_fixed", delta_seconds)
	if _recording_camera_program_was_playing and _camera_program_loaded:
		_camera_program_elapsed += maxf(0.0, delta_seconds)
		var program_sample := _camera_motion_program.sample(_camera_program_elapsed) as Dictionary
		_camera_follow_relative_transform = program_sample.get(
			"transform", _camera_follow_relative_transform
		) as Transform3D
		if bool(program_sample.get("finished", false)) and not _camera_motion_program.loop:
			_camera_program_elapsed = _camera_motion_program.duration_seconds
			_recording_camera_program_was_playing = false
	# Apply the newly sampled character-relative camera immediately. Waiting for
	# the plugin's next _process() would make capture_camera copy the previous
	# frame's global transform while the character is already at the new frame.
	if _camera_follow_active and is_instance_valid(_camera_follow_character):
		var editor_viewport := EditorInterface.get_editor_viewport_3d(_camera_follow_viewport_index)
		var editor_camera := editor_viewport.get_camera_3d() if editor_viewport != null else null
		if editor_camera != null:
			editor_camera.global_transform = _camera_follow_character.global_transform \
				* _camera_follow_relative_transform


func _end_fixed_step_capture() -> void:
	if _recording_fixed_step_active and is_instance_valid(_recording_walk_controller) and \
			_recording_walk_controller.has_method("editor_capture_end_fixed_step"):
		_recording_walk_controller.call("editor_capture_end_fixed_step", _recording_walk_was_playing)
	# Resume a camera program that was active before recording. If it finished
	# during the fixed-step take, leave it at its final authored frame.
	if _recording_camera_program_was_playing and _camera_program_loaded:
		_camera_program_playing = true
	_recording_walk_controller = null
	_recording_walk_was_playing = false
	_recording_fixed_step_active = false
	_recording_camera_program_was_playing = false


func _copy_camera(
		source: Camera3D,
		destination: Camera3D,
		output_size: Vector2 = Vector2.ZERO
	) -> void:
	destination.global_transform = source.global_transform
	destination.projection = source.projection
	destination.size = source.size
	destination.near = source.near
	destination.far = source.far
	destination.frustum_offset = source.frustum_offset
	destination.h_offset = source.h_offset
	destination.v_offset = source.v_offset
	destination.cull_mask = source.cull_mask
	destination.attributes = source.attributes
	if source.projection != Camera3D.PROJECTION_PERSPECTIVE or output_size.x <= 1.0 or output_size.y <= 1.0:
		destination.keep_aspect = source.keep_aspect
		destination.fov = source.fov
		return
	# The editor viewport and the output SubViewport usually have different
	# aspect ratios. Copying Camera3D.fov verbatim then changes the horizontal
	# framing, which is especially obvious when the editor is a tall docked
	# viewport and the video is 16:9. Read the source projection matrix and
	# preserve its horizontal field of view in the output camera. This keeps the
	# shot's left/right composition identical; the output resolution determines
	# only the new vertical extent.
	var source_projection := source.get_camera_projection()
	var source_m00 := absf(source_projection.x.x)
	if source_m00 <= 0.000001:
		destination.keep_aspect = source.keep_aspect
		destination.fov = source.fov
		return
	var horizontal_fov := rad_to_deg(2.0 * atan(1.0 / source_m00))
	destination.keep_aspect = Camera3D.KEEP_WIDTH
	destination.fov = clampf(horizontal_fov, 1.0, 179.0)


func _video_resolution_for_viewport(editor_viewport: SubViewport) -> Vector2i:
	if not _auto_video_resolution:
		return RESOLUTIONS[_resolution_choice.get_selected_id()]
	var viewport_size := Vector2i(editor_viewport.size)
	if viewport_size.x <= 1 or viewport_size.y <= 1:
		viewport_size = Vector2i(editor_viewport.get_visible_rect().size)
	# H.264/YUV420 requires even dimensions. Preserve the viewport's actual
	# aspect ratio and only round each dimension down by at most one pixel.
	viewport_size.x = maxi(2, viewport_size.x - viewport_size.x % 2)
	viewport_size.y = maxi(2, viewport_size.y - viewport_size.y % 2)
	return viewport_size


func _duplicate_scene_snapshot(source: Node) -> Node:
	# Do not use DUPLICATE_USE_INSTANTIATION here. Re-instantiating imported GLB
	# and tool-script sub-scenes can add/remove internal children while Godot is
	# traversing them, which produces "Child node disappeared while duplicating"
	# and a stale children_cache index. A direct deep duplicate copies the scene
	# exactly as it is currently evaluated in the editor—including unsaved bone
	# transforms—without running a second set of @tool scripts. Shared mesh and
	# material resources are safe because capture changes only per-node
	# material_override properties.
	return source.duplicate(Node.DUPLICATE_GROUPS)


func _prepare_live_capture_copy(node: Node) -> void:
	# The editor scene remains the sole evaluator. Native modifiers and animation
	# players in the off-screen duplicate must not overwrite the pose copied from
	# the source between synchronization and RenderingServer submission.
	var editor_only_trajectory_preview := node.has_meta("editor_only_trajectory_preview")
	if node.name == "CurvePreview" and node.get_parent() != null and \
			node.get_parent().name == "FemaleWalkTrajectory":
		editor_only_trajectory_preview = true
	if editor_only_trajectory_preview:
		if node is Node3D:
			(node as Node3D).visible = false
		return
	if node is SkeletonModifier3D:
		(node as SkeletonModifier3D).active = false
	elif node is AnimationPlayer:
		(node as AnimationPlayer).stop()
	elif node is AnimationTree:
		(node as AnimationTree).active = false
	for child in node.get_children(true):
		_prepare_live_capture_copy(child)


func _build_live_capture_bindings(source_root: Node, capture_root: Node) -> Dictionary:
	var node_pairs: Array[Dictionary] = []
	var skeleton_pairs: Array[Dictionary] = []
	var mesh_pairs: Array[Dictionary] = []
	_collect_live_capture_bindings(
		source_root,
		source_root,
		capture_root,
		node_pairs,
		skeleton_pairs,
		mesh_pairs
	)
	return {
		"nodes": node_pairs,
		"skeletons": skeleton_pairs,
		"meshes": mesh_pairs,
	}


func _collect_live_capture_bindings(
	source_root: Node,
	source_node: Node,
	capture_root: Node,
	node_pairs: Array[Dictionary],
	skeleton_pairs: Array[Dictionary],
	mesh_pairs: Array[Dictionary]
) -> void:
	var relative_path := source_root.get_path_to(source_node)
	var capture_node := capture_root.get_node_or_null(relative_path)
	if capture_node != null:
		if source_node is Node3D and capture_node is Node3D:
			node_pairs.append({"source": source_node, "capture": capture_node})
		if source_node is Skeleton3D and capture_node is Skeleton3D:
			var source_skeleton := source_node as Skeleton3D
			var capture_skeleton := capture_node as Skeleton3D
			var bone_pairs: Array[Vector2i] = []
			for source_bone_index in source_skeleton.get_bone_count():
				var capture_bone_index := capture_skeleton.find_bone(
					source_skeleton.get_bone_name(source_bone_index)
				)
				if capture_bone_index >= 0:
					bone_pairs.append(Vector2i(source_bone_index, capture_bone_index))
			skeleton_pairs.append({
				"source": source_skeleton,
				"capture": capture_skeleton,
				"bones": bone_pairs,
			})
		if source_node is MeshInstance3D and capture_node is MeshInstance3D:
			var source_mesh_instance := source_node as MeshInstance3D
			var capture_mesh_instance := capture_node as MeshInstance3D
			if source_mesh_instance.mesh != null and capture_mesh_instance.mesh != null:
				var blend_shape_count := mini(
					source_mesh_instance.mesh.get_blend_shape_count(),
					capture_mesh_instance.mesh.get_blend_shape_count()
				)
				if blend_shape_count > 0:
					mesh_pairs.append({
						"source": source_mesh_instance,
						"capture": capture_mesh_instance,
						"blend_shape_count": blend_shape_count,
					})
	for child in source_node.get_children(true):
		_collect_live_capture_bindings(
			source_root,
			child,
			capture_root,
			node_pairs,
			skeleton_pairs,
			mesh_pairs
		)


func _sync_live_capture_state(bindings: Dictionary) -> void:
	# Copy ordinary local transforms first so skeleton-space bone poses are
	# interpreted under the same character/root transform in both worlds.
	for binding_value in bindings.get("nodes", []):
		var binding := binding_value as Dictionary
		var source := binding.get("source") as Node3D
		var capture := binding.get("capture") as Node3D
		if is_instance_valid(source) and is_instance_valid(capture):
			capture.transform = source.transform

	# get_bone_global_pose() is the evaluated skeleton-space result. Copying it
	# parent-first also records active SkeletonModifier3D/IK output; copying only
	# get_bone_pose_rotation() would miss modifier-generated deformation.
	for binding_value in bindings.get("skeletons", []):
		var binding := binding_value as Dictionary
		var source := binding.get("source") as Skeleton3D
		var capture := binding.get("capture") as Skeleton3D
		if not is_instance_valid(source) or not is_instance_valid(capture):
			continue
		source.force_update_all_bone_transforms()
		capture.reset_bone_poses()
		for bone_pair_value in binding.get("bones", []):
			var bone_pair := bone_pair_value as Vector2i
			capture.set_bone_global_pose(
				bone_pair.y,
				source.get_bone_global_pose(bone_pair.x)
			)
		capture.force_update_all_bone_transforms()
		capture.advance(0.0)

	for binding_value in bindings.get("meshes", []):
		var binding := binding_value as Dictionary
		var source := binding.get("source") as MeshInstance3D
		var capture := binding.get("capture") as MeshInstance3D
		if not is_instance_valid(source) or not is_instance_valid(capture):
			continue
		for blend_shape_index in int(binding.get("blend_shape_count", 0)):
			capture.set_blend_shape_value(
				blend_shape_index,
				source.get_blend_shape_value(blend_shape_index)
			)


func _serialize_camera_sample(camera: Camera3D, frame_index: int, fps: int) -> Dictionary:
	var quaternion := camera.global_transform.basis.get_rotation_quaternion()
	var origin := camera.global_position
	return {
		"frame": frame_index,
		"time_seconds": float(frame_index) / float(fps),
		"position": [origin.x, origin.y, origin.z],
		"quaternion_xyzw": [quaternion.x, quaternion.y, quaternion.z, quaternion.w],
		"projection": int(camera.projection),
		"fov_degrees": camera.fov,
		"orthographic_size": camera.size,
	}


func _render_image(viewport: SubViewport) -> Image:
	# Let scene changes reach RenderingServer before requesting exactly one
	# off-screen frame. frame_post_draw guarantees the texture is readable.
	await get_tree().process_frame
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


func _collect_geometry(root: Node) -> Array[GeometryInstance3D]:
	var result: Array[GeometryInstance3D] = []
	_collect_geometry_recursive(root, result)
	return result


func _collect_geometry_recursive(node: Node, result: Array[GeometryInstance3D]) -> void:
	if node is GeometryInstance3D:
		result.append(node as GeometryInstance3D)
	for child in node.get_children():
		_collect_geometry_recursive(child, result)


func _calculate_depth_range(camera: Camera3D, geometry: Array[GeometryInstance3D]) -> Vector2:
	# Editor cameras use a very distant far plane (often 4000 m). Normalizing to
	# that range collapses a room-sized scene into almost pure white. Instead,
	# use the positive camera-space bounds of the geometry in this shot.
	var world_to_camera := camera.global_transform.affine_inverse()
	var nearest := INF
	var farthest := 0.0
	for instance in geometry:
		if not instance.is_visible_in_tree():
			continue
		var bounds := instance.get_aabb()
		for corner_index in 8:
			var corner := bounds.position + Vector3(
				bounds.size.x if (corner_index & 1) != 0 else 0.0,
				bounds.size.y if (corner_index & 2) != 0 else 0.0,
				bounds.size.z if (corner_index & 4) != 0 else 0.0
			)
			var world_position := instance.global_transform * corner
			var camera_position := world_to_camera * world_position
			var depth := -camera_position.z
			if depth >= camera.near:
				nearest = min(nearest, depth)
				farthest = max(farthest, depth)
	if nearest == INF or farthest <= nearest:
		return Vector2(camera.near, min(camera.far, camera.near + 25.0))
	var padding := max((farthest - nearest) * 0.03, 0.05)
	return Vector2(max(camera.near, nearest - padding), min(camera.far, farthest + padding))


func _is_within(node: Node, ancestor: Node) -> bool:
	return node == ancestor or ancestor.is_ancestor_of(node)


func _make_id_material(color: Color) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;
uniform vec4 id_color : source_color = vec4(1.0);
void fragment() {
	ALBEDO = id_color.rgb;
	ALPHA = id_color.a;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("id_color", color)
	return material


func _make_reference_material(color: Color) -> StandardMaterial3D:
	# Unlike the unshaded ID material, this material participates in the scene's
	# normal lighting and shadows. That preserves body volume and prop geometry
	# for an image model while removing distracting textures and wardrobe colors.
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.0
	material.roughness = 0.82
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _make_depth_material(near_distance: float, far_distance: float) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;
uniform float depth_near = 0.05;
uniform float depth_far = 100.0;
varying float camera_depth;
void vertex() {
	camera_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}
void fragment() {
	float linear_depth = clamp((camera_depth - depth_near) / max(depth_far - depth_near, 0.0001), 0.0, 1.0);
	float near_white = 1.0 - linear_depth;
	ALBEDO = vec3(near_white);
	ALPHA = 1.0;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("depth_near", near_distance)
	material.set_shader_parameter("depth_far", far_distance)
	return material


func _flatten_depth_over_black(source: Image) -> Image:
	source.convert(Image.FORMAT_RGBA8)
	var output := Image.create(source.get_width(), source.get_height(), false, Image.FORMAT_RGBA8)
	for y in source.get_height():
		for x in source.get_width():
			var pixel := source.get_pixel(x, y)
			var value := pixel.r * pixel.a
			output.set_pixel(x, y, Color(value, value, value, 1.0))
	return output


func _split_character_masks(source: Image) -> Array[Image]:
	source.convert(Image.FORMAT_RGBA8)
	var width := source.get_width()
	var height := source.get_height()
	var female := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var male := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var ids := Image.create(width, height, false, Image.FORMAT_RGBA8)
	for y in height:
		for x in width:
			var pixel := source.get_pixel(x, y)
			var female_coverage := clamp((pixel.r - pixel.g) * pixel.a, 0.0, 1.0)
			var male_coverage := clamp((pixel.g - pixel.r) * pixel.a, 0.0, 1.0)
			female.set_pixel(x, y, Color(female_coverage, female_coverage, female_coverage, 1.0))
			male.set_pixel(x, y, Color(male_coverage, male_coverage, male_coverage, 1.0))
			ids.set_pixel(x, y, Color(female_coverage, male_coverage, 0.0, 1.0))
	return [female, male, ids]


func _write_camera_metadata(
	path: String,
	camera: Camera3D,
	resolution: Vector2i,
	resource_directory: String,
	depth_range: Vector2
) -> Error:
	var quaternion := camera.global_transform.basis.get_rotation_quaternion()
	var origin := camera.global_position
	var metadata := {
		"schema": "godot-ots-render-capture",
		"version": 2,
		"source_scene": EditorInterface.get_edited_scene_root().scene_file_path,
		"editor_viewport": _viewport_choice.get_selected_id() + 1,
		"resolution": [resolution.x, resolution.y],
		"camera": {
			"projection": "perspective" if camera.projection == Camera3D.PROJECTION_PERSPECTIVE else "orthogonal_or_frustum",
			"position": [origin.x, origin.y, origin.z],
			"quaternion_xyzw": [quaternion.x, quaternion.y, quaternion.z, quaternion.w],
			"fov_degrees": camera.fov,
			"orthographic_size": camera.size,
			"near": camera.near,
			"far": camera.far,
			"keep_aspect": int(camera.keep_aspect),
		},
		"actors": {
			"female": str(FEMALE_PATH),
			"male_carrier": str(MALE_PATH),
		},
		"passes": {
			"beauty": "beauty.png",
			"character_color_reference": "character_color_reference.png",
			"depth": "depth_near_white.png",
			"female_mask": "mask_female.png",
			"male_mask": "mask_male_carrier.png",
			"character_ids": "mask_character_ids.png",
		},
		"depth_encoding": "linear camera depth; near is white, far and background are black",
		"depth_range_meters": {
			"near": depth_range.x,
			"far": depth_range.y,
		},
		"character_id_colors": {
			"female": [255, 0, 0],
			"male_carrier": [0, 255, 0],
			"other_or_background": [0, 0, 0],
		},
		"character_reference_colors": {
			"female": [
				roundi(FEMALE_REFERENCE_COLOR.r * 255.0),
				roundi(FEMALE_REFERENCE_COLOR.g * 255.0),
				roundi(FEMALE_REFERENCE_COLOR.b * 255.0),
			],
			"male_carrier": [
				roundi(MALE_REFERENCE_COLOR.r * 255.0),
				roundi(MALE_REFERENCE_COLOR.g * 255.0),
				roundi(MALE_REFERENCE_COLOR.b * 255.0),
			],
			"environment": [
				roundi(ENVIRONMENT_REFERENCE_COLOR.r * 255.0),
				roundi(ENVIRONMENT_REFERENCE_COLOR.g * 255.0),
				roundi(ENVIRONMENT_REFERENCE_COLOR.b * 255.0),
			],
		},
		"resource_directory": resource_directory,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(metadata, "  ") + "\n")
	file.close()
	return OK


func _write_video_metadata(
	path: String,
	resolution: Vector2i,
	fps: int,
	requested_duration: float,
	duration_source: String,
	camera_program_duration: float,
	program_end_padding: float,
	captured_frames: int,
	resource_directory: String,
	camera_samples: Array[Dictionary],
	ffmpeg_path: String,
	live_scene_bindings: Dictionary
) -> Error:
	var metadata := {
		"schema": "godot-ots-editor-camera-video",
		"version": 2,
		"source_scene": EditorInterface.get_edited_scene_root().scene_file_path,
		"editor_viewport": _viewport_choice.get_selected_id() + 1,
		"resolution": [resolution.x, resolution.y],
		"fps": fps,
		"requested_duration_seconds": requested_duration,
		"duration_source": duration_source,
		"camera_program_duration_seconds": camera_program_duration,
		"program_end_padding_seconds": program_end_padding,
		"captured_frames": captured_frames,
		"encoded_duration_seconds": float(captured_frames) / float(fps),
		"timing": {
			"mode": "fixed_step_after_render",
			"description": "Source gait and camera-program time advance by exactly one output frame after each rendered frame; GPU latency cannot fast-forward the MP4.",
		},
		"video_codec": "H.264 / libx264",
		"pixel_format": "yuv420p",
		"color_space": "BT.709 limited range",
		"video": "editor_camera_motion.mp4",
		"ffmpeg_path": ffmpeg_path,
		"scene_sampling": {
			"mode": "live_editor_scene_to_isolated_render_copy",
			"node_transform_bindings": (live_scene_bindings.get("nodes", []) as Array).size(),
			"skeleton_bindings": (live_scene_bindings.get("skeletons", []) as Array).size(),
			"blend_shape_mesh_bindings": (live_scene_bindings.get("meshes", []) as Array).size(),
			"bone_pose_space": "evaluated_skeleton_global_pose",
		},
		"camera_samples": camera_samples,
		"resource_directory": resource_directory,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(metadata, "  ") + "\n")
	file.close()
	return OK


func _find_ffmpeg() -> String:
	var candidates := PackedStringArray([
		"/opt/homebrew/bin/ffmpeg",
		"/usr/local/bin/ffmpeg",
		"/usr/bin/ffmpeg",
	])
	var environment_path := OS.get_environment("PATH")
	if not environment_path.is_empty():
		for directory in environment_path.split(":", false):
			candidates.append(directory.path_join("ffmpeg"))
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


func _remove_frame_directory(frames_directory: String) -> void:
	# This directory is created exclusively by the plugin for the current
	# capture. Remove only its known files; never recurse into an arbitrary path.
	var directory := DirAccess.open(frames_directory)
	if directory == null:
		return
	for filename in directory.get_files():
		if filename.begins_with("frame_") and filename.ends_with(".jpg"):
			DirAccess.remove_absolute(frames_directory.path_join(filename))
	DirAccess.remove_absolute(frames_directory)


func _set_video_options_enabled(enabled: bool) -> void:
	_video_duration.editable = enabled
	_use_camera_program_duration.disabled = not enabled
	_video_program_end_padding.editable = enabled
	_video_fps_choice.disabled = not enabled
	_video_start_delay.editable = enabled
	_keep_video_frames.disabled = not enabled
	_viewport_choice.disabled = not enabled
	_resolution_choice.disabled = not enabled


func _finish_video_with_error(message: String) -> void:
	_end_fixed_step_capture()
	_video_capture_scheduled = false
	_video_recording = false
	_video_cancel_requested = false
	_capture_button.disabled = false
	_set_video_options_enabled(true)
	_record_video_button.disabled = false
	_record_video_button.text = "Record editor camera motion"
	_status_label.text = message
	editor_camera_video_state_changed.emit(false, "Error: %s" % message)
	push_error("OTS Video: %s" % message)


func _finish_video_cancelled(message: String) -> void:
	_end_fixed_step_capture()
	_video_capture_scheduled = false
	_video_recording = false
	_video_cancel_requested = false
	_capture_button.disabled = false
	_set_video_options_enabled(true)
	_record_video_button.disabled = false
	_record_video_button.text = "Record editor camera motion"
	_status_label.text = message
	editor_camera_video_state_changed.emit(false, message)
	print("OTS_VIDEO cancelled: %s" % message)


func _finish_with_error(message: String) -> void:
	_capture_scheduled = false
	_capturing = false
	_capture_button.disabled = false
	_record_video_button.disabled = false
	_status_label.text = message
	push_error("OTS Capture: %s" % message)


func _show_last_capture() -> void:
	if _last_output_directory.is_empty():
		return
	OS.shell_show_in_file_manager(_last_output_directory)
