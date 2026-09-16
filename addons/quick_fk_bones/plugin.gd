@tool
extends EditorPlugin

const BONE_NAMES: Array[StringName] = [
	&"Hips",
	&"Spine",
	&"Chest",
	&"UpperChest",
	&"LeftShoulder",
	&"LeftUpperArm",
	&"LeftLowerArm",
	&"LeftHand",
	&"RightShoulder",
	&"RightUpperArm",
	&"RightLowerArm",
	&"RightHand",
	&"Neck",
	&"Head",
	&"Ponytail_Bone1",
	&"Ponytail_Bone2",
]
const EULER_ORDER := EULER_ORDER_YXZ
const PoseStreamServer = preload("res://scripts/pose_stream_server.gd")

var _panel: PanelContainer
var _bone_buttons: Dictionary = {}
var _rotation_fields: Array[SpinBox] = []
var _status_label: Label
var _selected_bone: StringName = &"Hips"
var _updating_fields := false
var _editor_pose_server: Node

func _enter_tree() -> void:
	_build_panel()
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _panel)
	# EditorPlugin input is separate from the running game's input tree. Keep a
	# small editor-side hook so a click in the 3D workspace really gives the
	# keyboard back to viewport/TCP navigation after a SpinBox LineEdit was
	# edited.
	set_process_input(true)
	scene_changed.connect(_on_scene_changed)
	_start_editor_pose_server()
	_select_bone(_selected_bone)

func _exit_tree() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if is_instance_valid(_panel):
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _panel)
		_panel.queue_free()
	if is_instance_valid(_editor_pose_server):
		_editor_pose_server.queue_free()
		_editor_pose_server = null

func _input(event: InputEvent) -> void:
	# This catches clicks in editor docks that are not forwarded through the
	# 3D viewport. Do not steal focus when the click is on our own pose panel;
	# that click must still focus the selected field/button.
	if not _is_background_left_click(event):
		return
	call_deferred("_release_editor_focus")

func _forward_3d_gui_input(_viewport_camera: Camera3D, event: InputEvent) -> int:
	# The 3D editor viewport is where users click to resume arrow/R/F TCP
	# exploration. _unhandled_input is too late for editor controls, while this
	# forwarding hook runs for the viewport click itself.
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_LEFT:
			call_deferred("_release_editor_focus")
	return EditorPlugin.AFTER_GUI_INPUT_PASS

func _is_background_left_click(event: InputEvent) -> bool:
	if not event is InputEventMouseButton:
		return false
	var mouse_event := event as InputEventMouseButton
	if not mouse_event.pressed or mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if is_instance_valid(_panel) and _panel.get_global_rect().has_point(mouse_event.position):
		return false
	return true

func _release_editor_focus() -> void:
	var base_control := EditorInterface.get_base_control()
	if base_control == null:
		return
	var editor_viewport := base_control.get_viewport()
	if editor_viewport == null:
		return
	var focus_owner := editor_viewport.gui_get_focus_owner()
	if focus_owner != null:
		focus_owner.release_focus()
	# gui_release_focus() exists in current Godot 4 builds, but keep this
	# guarded so the plugin remains loadable on older 4.x editor versions.
	if editor_viewport.has_method("gui_release_focus"):
		editor_viewport.call("gui_release_focus")

func _start_editor_pose_server() -> void:
	_editor_pose_server = PoseStreamServer.new()
	_editor_pose_server.name = "GodotPoseEditorStream"
	_editor_pose_server.allow_editor = true
	_editor_pose_server.bind_address_override = str(ProjectSettings.get_setting("pose_stream/bind_address", "127.0.0.1"))
	_editor_pose_server.port_override = int(ProjectSettings.get_setting("pose_stream/editor_port", 7007))
	_editor_pose_server.scene_root_provider = Callable(self, "_get_edited_scene_root")
	_editor_pose_server.pose_applied.connect(_on_stream_pose_applied)
	add_child(_editor_pose_server)

func _get_edited_scene_root() -> Node:
	return EditorInterface.get_edited_scene_root()

func _on_stream_pose_applied(message: Dictionary, response: Dictionary) -> void:
	var response_type := str(response.get("type", ""))
	if response_type == "pose.applied":
		_status_label.text = "Emacs applied ‘%s’ to the editor scene." % str(message.get("pose_name", "unnamed"))
		call_deferred("_refresh_rotation_fields")
	else:
		_status_label.text = "Pose stream error: %s" % str(response.get("error", "unknown"))

func _on_scene_changed(_scene_root: Node) -> void:
	call_deferred("_refresh_rotation_fields")

func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "QuickFKBones"
	# The pose panel is edited with the mouse while the keyboard is reserved for
	# viewport/TCP exploration. FOCUS_CLICK still lets a user click a field and
	# type a value, but prevents Godot's default arrow-key focus traversal from
	# moving the selection rectangle between Roll/Pitch/Yaw controls.
	_panel.focus_mode = Control.FOCUS_NONE
	_panel.custom_minimum_size = Vector2(238.0, 0.0)
	_panel.tooltip_text = "Fine-tune local FK rotations without expanding the Skeleton3D bone hierarchy."

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	var title := Label.new()
	title.text = "Quick FK — Body & Ponytail"
	title.add_theme_font_size_override("font_size", 16)
	content.add_child(title)

	var hint := Label.new()
	hint.text = "Bake IK first, then edit local rotation."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(0.78, 0.82, 0.88)
	content.add_child(hint)

	# Keep the rotation editor visible even as the frequently used bone list
	# grows. Only the buttons scroll; X/Y/Z and the action buttons stay fixed
	# below this viewport.
	var bone_scroll := ScrollContainer.new()
	bone_scroll.name = "BoneScroll"
	bone_scroll.custom_minimum_size.y = 260.0
	bone_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bone_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	bone_scroll.tooltip_text = "Scroll to choose a Quick FK bone."
	content.add_child(bone_scroll)

	var bone_list := VBoxContainer.new()
	bone_list.name = "BoneList"
	bone_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bone_list.add_theme_constant_override("separation", 4)
	bone_scroll.add_child(bone_list)

	var button_group := ButtonGroup.new()
	for bone_name in BONE_NAMES:
		var button := Button.new()
		button.text = bone_name
		button.toggle_mode = true
		button.button_group = button_group
		button.focus_mode = Control.FOCUS_CLICK
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.tooltip_text = "Edit the %s bone" % bone_name
		button.pressed.connect(_select_bone.bind(bone_name))
		bone_list.add_child(button)
		_bone_buttons[bone_name] = button

	content.add_child(HSeparator.new())

	var rotation_title := Label.new()
	rotation_title.text = "Local rotation — %s" % _selected_bone
	rotation_title.name = "RotationTitle"
	content.add_child(rotation_title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	content.add_child(grid)

	for axis_number in 3:
		var axis_label := Label.new()
		axis_label.text = ["X", "Y", "Z"][axis_number]
		axis_label.custom_minimum_size.x = 18.0
		grid.add_child(axis_label)

		var field := SpinBox.new()
		field.min_value = -180.0
		field.max_value = 180.0
		field.step = 0.5
		field.suffix = "°"
		field.allow_greater = true
		field.allow_lesser = true
		field.focus_mode = Control.FOCUS_CLICK
		field.custom_minimum_size.x = 170.0
		field.tooltip_text = "Local %s rotation in degrees. Type a value or drag horizontally." % axis_label.text
		# SpinBox owns a LineEdit child. Apply the same focus policy to that
		# child, otherwise it can still hand arrow presses to sibling Controls.
		var line_edit := field.get_line_edit()
		if line_edit != null:
			line_edit.focus_mode = Control.FOCUS_CLICK
		field.value_changed.connect(_rotation_value_changed.bind(axis_number))
		grid.add_child(field)
		_rotation_fields.append(field)

	var reset_button := Button.new()
	reset_button.text = "Reset selected rotation"
	reset_button.focus_mode = Control.FOCUS_CLICK
	reset_button.tooltip_text = "Set this bone's local pose rotation to 0°, 0°, 0°."
	reset_button.pressed.connect(_reset_selected_rotation)
	content.add_child(reset_button)

	var refresh_button := Button.new()
	refresh_button.text = "Refresh from skeleton"
	refresh_button.focus_mode = Control.FOCUS_CLICK
	refresh_button.tooltip_text = "Reload the displayed Euler angles from the current bone pose."
	refresh_button.pressed.connect(_refresh_rotation_fields)
	content.add_child(refresh_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.modulate = Color(0.9, 0.76, 0.38)
	content.add_child(_status_label)

func _select_bone(bone_name: StringName) -> void:
	_selected_bone = bone_name
	for candidate in _bone_buttons:
		(_bone_buttons[candidate] as Button).set_pressed_no_signal(candidate == bone_name)
	var title := _panel.find_child("RotationTitle", true, false) as Label
	if title != null:
		title.text = "Local rotation — %s" % bone_name
	_refresh_rotation_fields()

func _refresh_rotation_fields() -> void:
	var skeleton := _find_skeleton()
	var bone_idx := _find_selected_bone(skeleton)
	if skeleton == null or bone_idx < 0:
		_set_fields_enabled(false)
		_status_label.text = "Open the manual rig scene to edit its skeleton."
		return
	var rotation := Basis(skeleton.get_bone_pose_rotation(bone_idx)).get_euler(EULER_ORDER)
	_updating_fields = true
	for axis_number in 3:
		_rotation_fields[axis_number].value = rad_to_deg(rotation[axis_number])
	_updating_fields = false
	var ik_active := _has_active_modifiers(skeleton)
	_set_fields_enabled(not ik_active)
	if ik_active:
		_status_label.text = "IK is active. Click ‘Bake current IK pose to bones’ on IK_character first."
	else:
		_status_label.text = "%s selected. Changes are captured for Cmd+S." % _selected_bone

func _rotation_value_changed(value: float, axis_number: int) -> void:
	if _updating_fields:
		return
	var skeleton := _find_skeleton()
	var bone_idx := _find_selected_bone(skeleton)
	if skeleton == null or bone_idx < 0 or _has_active_modifiers(skeleton):
		_refresh_rotation_fields()
		return
	var old_rotation := skeleton.get_bone_pose_rotation(bone_idx)
	var euler := Basis(old_rotation).get_euler(EULER_ORDER)
	euler[axis_number] = deg_to_rad(value)
	var new_rotation := Basis.from_euler(euler, EULER_ORDER).get_rotation_quaternion()
	if old_rotation.is_equal_approx(new_rotation):
		return
	var undo := get_undo_redo()
	undo.create_action("Rotate %s %s" % [_selected_bone, ["X", "Y", "Z"][axis_number]])
	undo.add_do_method(skeleton, "set_bone_pose_rotation", bone_idx, new_rotation)
	undo.add_undo_method(skeleton, "set_bone_pose_rotation", bone_idx, old_rotation)
	undo.add_do_method(self, "_after_rotation_change")
	undo.add_undo_method(self, "_after_rotation_change")
	undo.commit_action()

func _reset_selected_rotation() -> void:
	var skeleton := _find_skeleton()
	var bone_idx := _find_selected_bone(skeleton)
	if skeleton == null or bone_idx < 0 or _has_active_modifiers(skeleton):
		_refresh_rotation_fields()
		return
	var old_rotation := skeleton.get_bone_pose_rotation(bone_idx)
	if old_rotation.is_equal_approx(Quaternion.IDENTITY):
		return
	var undo := get_undo_redo()
	undo.create_action("Reset %s rotation" % _selected_bone)
	undo.add_do_method(skeleton, "set_bone_pose_rotation", bone_idx, Quaternion.IDENTITY)
	undo.add_undo_method(skeleton, "set_bone_pose_rotation", bone_idx, old_rotation)
	undo.add_do_method(self, "_after_rotation_change")
	undo.add_undo_method(self, "_after_rotation_change")
	undo.commit_action()

func _after_rotation_change() -> void:
	var skeleton := _find_skeleton()
	if skeleton != null:
		skeleton.force_update_all_bone_transforms()
		var controller := skeleton.get_parent()
		if controller != null and controller.has_method("commit_current_fk_pose_for_saving"):
			controller.call("commit_current_fk_pose_for_saving")
	_refresh_rotation_fields()

func _find_skeleton() -> Skeleton3D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var skeleton := scene_root.get_node_or_null("IK_character/Skeleton3D") as Skeleton3D
	if skeleton == null and scene_root.name == "IK_character":
		skeleton = scene_root.get_node_or_null("Skeleton3D") as Skeleton3D
	if skeleton == null:
		skeleton = scene_root.find_child("Skeleton3D", true, false) as Skeleton3D
	return skeleton

func _find_selected_bone(skeleton: Skeleton3D) -> int:
	if skeleton == null:
		return -1
	return skeleton.find_bone(_selected_bone)

func _has_active_modifiers(skeleton: Skeleton3D) -> bool:
	for child in skeleton.get_children():
		if child is SkeletonModifier3D and (child as SkeletonModifier3D).active:
			return true
	return false

func _set_fields_enabled(enabled: bool) -> void:
	for field in _rotation_fields:
		field.editable = enabled
