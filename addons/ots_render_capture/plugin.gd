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

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1024, 1024),
	Vector2i(1536, 1024),
	Vector2i(1920, 1080),
]

var _dock: VBoxContainer
var _viewport_choice: OptionButton
var _resolution_choice: OptionButton
var _capture_button: Button
var _open_button: Button
var _status_label: Label
var _last_output_directory := ""
var _capturing := false


func _enter_tree() -> void:
	_build_dock()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _dock)


func _exit_tree() -> void:
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
	explanation.text = "Frame the actors in the 3D editor, then capture the same camera as image-generation passes."
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
	_capture_button.tooltip_text = "Write beauty, linear depth, female mask, male mask, combined ID mask, and camera metadata."
	_capture_button.pressed.connect(_on_capture_pressed)
	_dock.add_child(_capture_button)

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
	if _capturing:
		return
	_capture_current_editor_camera()


func _capture_current_editor_camera() -> void:
	_capturing = true
	_capture_button.disabled = true
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

	# DUPLICATE_USE_INSTANTIATION preserves imported GLB sub-scenes and the
	# current unsaved bone/node properties. Omitting DUPLICATE_SCRIPTS prevents
	# @tool controllers from evaluating a second time inside the capture world.
	var capture_scene := scene_root.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_USE_INSTANTIATION)
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
	var errors := [beauty_error, depth_error, female_error, male_error, id_error, metadata_error]
	for error in errors:
		if error != OK:
			_finish_with_error("Capture finished incompletely; an output file returned error %d." % error)
			return

	_last_output_directory = output_directory
	_open_button.disabled = false
	_capture_button.disabled = false
	_capturing = false
	_status_label.text = "Captured beauty, depth, two masks, ID mask, and camera.json to:\n%s" % output_resource_path
	print("OTS_CAPTURE completed: %s" % output_directory)


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
		"version": 1,
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
		"resource_directory": resource_directory,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(metadata, "  ") + "\n")
	file.close()
	return OK


func _finish_with_error(message: String) -> void:
	_capturing = false
	_capture_button.disabled = false
	_status_label.text = message
	push_error("OTS Capture: %s" % message)


func _show_last_capture() -> void:
	if _last_output_directory.is_empty():
		return
	OS.shell_show_in_file_manager(_last_output_directory)
