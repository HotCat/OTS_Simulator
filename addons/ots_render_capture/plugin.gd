@tool
extends EditorPlugin

## Captures the current 3D editor view without requiring a Camera3D node in
## the saved scene.  An isolated duplicate of the edited scene prevents editor
## gizmos, selection outlines, and camera icons from leaking into the exported
## passes.  A temporary camera still copies the selected editor viewport's
## exact transform and projection, including unsaved camera framing.

const FEMALE_PATH := NodePath("IK_character")
const MALE_PATH := NodePath("MaleCarrier")
const OUTPUT_ROOT := "res://renders/ots_quickview"

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

var _dock: VBoxContainer
var _viewport_choice: OptionButton
var _resolution_choice: OptionButton
var _capture_button: Button
var _video_duration: SpinBox
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


func _enter_tree() -> void:
	_build_dock()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _dock)
	# A menu command gives the capture a second, editor-native entry point. It is
	# also useful when another editor plugin consumes a dock button's mouse-up
	# event before Button.pressed can be emitted.
	add_tool_menu_item("Capture OTS Render Passes", _on_capture_pressed)
	add_tool_menu_item("Record OTS Editor Camera Video", _on_record_video_pressed)


func _exit_tree() -> void:
	remove_tool_menu_item("Capture OTS Render Passes")
	remove_tool_menu_item("Record OTS Editor Camera Video")
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()


func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "OTS Render"
	_dock.custom_minimum_size = Vector2(260.0, 0.0)
	_dock.add_theme_constant_override("separation", 8)

	var title := Label.new()
	title.text = "OTS Quick Render"
	title.add_theme_font_size_override("font_size", 16)
	_dock.add_child(title)

	var explanation := Label.new()
	explanation.text = "Frame the actors in the 3D editor, then capture the same camera as image-generation passes. If this dock button is intercepted, use Project > Tools > Capture OTS Render Passes."
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.modulate = Color(0.78, 0.82, 0.88)
	_dock.add_child(explanation)

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
	_dock.add_child(viewport_row)

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
	_dock.add_child(resolution_row)

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
	_dock.add_child(_capture_button)

	var video_separator := HSeparator.new()
	_dock.add_child(video_separator)

	var video_title := Label.new()
	video_title.text = "H3 camera-motion guide"
	video_title.add_theme_font_size_override("font_size", 14)
	_dock.add_child(video_title)

	var video_explanation := Label.new()
	video_explanation.text = "Record the live editor camera and animated scene, then encode the sampled frames as an H.264 MP4. Camera navigation and streamed character poses are captured together."
	video_explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	video_explanation.modulate = Color(0.78, 0.82, 0.88)
	_dock.add_child(video_explanation)

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
	_dock.add_child(duration_row)

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
	_dock.add_child(fps_row)

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
	_dock.add_child(delay_row)

	_keep_video_frames = CheckButton.new()
	_keep_video_frames.text = "Keep source JPEG frames"
	_keep_video_frames.tooltip_text = "Normally the temporary JPEG sequence is deleted after MP4 encoding. Enable this for debugging or external encoders."
	_dock.add_child(_keep_video_frames)

	_record_video_button = Button.new()
	_record_video_button.text = "Record editor camera motion"
	_record_video_button.focus_mode = Control.FOCUS_CLICK
	_record_video_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_record_video_button.tooltip_text = "After the start delay, orbit/pan/zoom or stream character motion. Click again to stop early."
	_record_video_button.button_down.connect(_on_record_video_pressed)
	_dock.add_child(_record_video_button)

	_open_button = Button.new()
	_open_button.text = "Show last capture in Finder"
	_open_button.disabled = true
	_open_button.pressed.connect(_show_last_capture)
	_dock.add_child(_open_button)

	_status_label = Label.new()
	_status_label.text = "Open my_manual_rig_pose.tscn and frame the OTS shot."
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.modulate = Color(0.9, 0.76, 0.38)
	_dock.add_child(_status_label)


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
	_copy_camera(editor_camera, capture_camera)
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


func _on_record_video_pressed() -> void:
	if _video_recording:
		_video_cancel_requested = true
		_record_video_button.disabled = true
		_record_video_button.text = "Stopping after current frame…"
		_status_label.text = "Stopping the camera-motion capture after the current frame…"
		return
	if _capturing or _capture_scheduled or _video_capture_scheduled:
		_status_label.text = "A capture is already active. Wait for it to finish."
		return
	_video_capture_scheduled = true
	_video_cancel_requested = false
	_status_label.text = "Camera-motion recording requested; preparing the scene…"
	print("OTS_VIDEO requested from editor viewport %d" % (_viewport_choice.get_selected_id() + 1))
	call_deferred("_record_editor_camera_video")


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

	var resolution := RESOLUTIONS[_resolution_choice.get_selected_id()]
	var fps := VIDEO_FRAME_RATES[_video_fps_choice.get_selected_id()]
	var requested_duration := float(_video_duration.value)
	var requested_frames := maxi(1, ceili(requested_duration * float(fps)))
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
	_copy_camera(editor_camera, capture_camera)
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
		_finish_video_cancelled("Camera-motion recording cancelled before the first frame.")
		return

	var camera_samples: Array[Dictionary] = []
	var captured_frames := 0
	var start_usec := Time.get_ticks_usec()
	for frame_index in requested_frames:
		if _video_cancel_requested:
			break

		# Pace samples in real editor time so mouse navigation remains responsive.
		# If image encoding falls behind, the next sample is captured immediately
		# rather than blocking editor input in a catch-up sleep.
		var target_usec := start_usec + int(float(frame_index) * 1000000.0 / float(fps))
		while Time.get_ticks_usec() < target_usec and not _video_cancel_requested:
			await get_tree().process_frame
		if _video_cancel_requested:
			break

		_sync_live_capture_state(live_scene_bindings)
		_copy_camera(editor_camera, capture_camera)
		camera_samples.append(_serialize_camera_sample(capture_camera, frame_index, fps))
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

	capture_viewport.queue_free()
	if captured_frames == 0:
		_remove_frame_directory(frames_directory)
		DirAccess.remove_absolute(output_directory)
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
	_open_button.disabled = false
	_capture_button.disabled = false
	_video_recording = false
	_video_cancel_requested = false
	_set_video_options_enabled(true)
	_record_video_button.disabled = false
	_record_video_button.text = "Record editor camera motion"
	var actual_duration := float(captured_frames) / float(fps)
	_status_label.text = "Recorded %d frames (%.2f s at %d FPS) to:\n%s" % [captured_frames, actual_duration, fps, output_resource_path]
	print("OTS_VIDEO completed: %s" % video_path)


func _copy_camera(source: Camera3D, destination: Camera3D) -> void:
	destination.global_transform = source.global_transform
	destination.projection = source.projection
	destination.keep_aspect = source.keep_aspect
	destination.fov = source.fov
	destination.size = source.size
	destination.near = source.near
	destination.far = source.far
	destination.frustum_offset = source.frustum_offset
	destination.h_offset = source.h_offset
	destination.v_offset = source.v_offset
	destination.cull_mask = source.cull_mask
	destination.attributes = source.attributes


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
		"captured_frames": captured_frames,
		"encoded_duration_seconds": float(captured_frames) / float(fps),
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
	_video_fps_choice.disabled = not enabled
	_video_start_delay.editable = enabled
	_keep_video_frames.disabled = not enabled
	_viewport_choice.disabled = not enabled
	_resolution_choice.disabled = not enabled


func _finish_video_with_error(message: String) -> void:
	_video_capture_scheduled = false
	_video_recording = false
	_video_cancel_requested = false
	_capture_button.disabled = false
	_set_video_options_enabled(true)
	_record_video_button.disabled = false
	_record_video_button.text = "Record editor camera motion"
	_status_label.text = message
	push_error("OTS Video: %s" % message)


func _finish_video_cancelled(message: String) -> void:
	_video_capture_scheduled = false
	_video_recording = false
	_video_cancel_requested = false
	_capture_button.disabled = false
	_set_video_options_enabled(true)
	_record_video_button.disabled = false
	_record_video_button.text = "Record editor camera motion"
	_status_label.text = message
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
