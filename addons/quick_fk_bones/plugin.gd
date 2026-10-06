@tool
extends EditorPlugin

const COMMON_BONE_NAMES: Array[StringName] = [
	&"Hips",
	&"LeftUpperLeg",
	&"LeftLowerLeg",
	&"LeftFoot",
	&"LeftToes",
	&"RightUpperLeg",
	&"RightLowerLeg",
	&"RightFoot",
	&"RightToes",
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
]
const FEMALE_EXTRA_BONE_NAMES: Array[StringName] = [&"Ponytail_Bone1", &"Ponytail_Bone2"]
const FINGER_SEGMENT_NAMES: Array[StringName] = [
	&"Proximal", &"Intermediate", &"Distal"
]
const FINGER_NAMES: Array[StringName] = [
	&"Index", &"Middle", &"Ring", &"Little"
]
# Values are rest-relative curl angles in degrees for proximal/intermediate/
# distal joints. Humanizer's imported finger chains extend mostly along local
# X, so rotating around X twists a finger around its own length. The hinge is
# derived from each joint's rest-chain direction and the palmar curl direction,
# which naturally mirrors between hands without guessing a fixed Euler axis.
# The final pose also has to retain each imported rest quaternion; this matters
# especially for the thumb metacarpal, whose neutral opposition is encoded as
# a large non-identity rest rotation.
const FINGER_POSE_PRESETS := {
	&"Relaxed": {
		# OTS-carried/dangling hand: a shallow natural arc rather than a loose
		# fist. The curl increases gently toward the little finger while leaving
		# each fingertip visibly separate from its neighbor.
		&"Index": [7.0, 11.0, 5.0], &"Middle": [9.0, 14.0, 7.0],
		&"Ring": [11.0, 17.0, 9.0], &"Little": [13.0, 19.0, 11.0],
		# A passive thumb is visibly flexed at all three joints and rests toward
		# the index finger. Keep the imported metacarpal opposition, then add a
		# moderate hinge-only arc; this avoids both the old straight/thumbs-up
		# silhouette and the palm-crossing curl used by a fist.
		&"Thumb": [12.0, 22.0, 14.0],
	},
	&"Open": {
		&"Index": [0.0, 0.0, 0.0], &"Middle": [0.0, 0.0, 0.0],
		&"Ring": [0.0, 0.0, 0.0], &"Little": [0.0, 0.0, 0.0],
		&"Thumb": [0.0, 0.0, 0.0],
	},
	&"Fist": {
		&"Index": [62.0, 78.0, 55.0], &"Middle": [68.0, 84.0, 60.0],
		&"Ring": [72.0, 88.0, 64.0], &"Little": [68.0, 84.0, 62.0],
		&"Thumb": [20.0, 34.0, 24.0],
	},
	&"Point": {
		&"Index": [0.0, 0.0, 0.0], &"Middle": [70.0, 84.0, 60.0],
		&"Ring": [74.0, 88.0, 64.0], &"Little": [70.0, 84.0, 62.0],
		&"Thumb": [18.0, 28.0, 18.0],
	},
	&"Pinch": {
		&"Index": [28.0, 52.0, 38.0], &"Middle": [38.0, 62.0, 44.0],
		&"Ring": [70.0, 86.0, 62.0], &"Little": [68.0, 84.0, 60.0],
		&"Thumb": [32.0, 50.0, 34.0],
	},
	&"Carry grip": {
		&"Index": [38.0, 58.0, 38.0], &"Middle": [44.0, 64.0, 44.0],
		&"Ring": [48.0, 68.0, 48.0], &"Little": [52.0, 72.0, 52.0],
		&"Thumb": [28.0, 44.0, 30.0],
	},
}
# Proximal adduction closes the fan-shaped rest hand while preserving small
# seams between adjacent fingers. The axis is derived toward the middle-finger
# rest direction per hand, so positive values work symmetrically on both rigs.
# Only Relaxed needs this subtle grouping; gesture presets intentionally keep
# their authored silhouettes.
const FINGER_POSE_ADDUCTION_DEGREES := {
	&"Relaxed": {
		&"Index": 2.25,
		&"Middle": 0.0,
		&"Ring": 1.25,
		&"Little": 2.5,
	},
}
# The seam control is expressed as visible spacing rather than an abstract
# rotation angle: 0% applies eight times the tuned adduction, deliberately
# converging the clay-proxy fingers until no background seam remains between
# them. A tiny amount of silhouette overlap is preferable to a visible gap at
# this endpoint. 50% uses the authored Relaxed spacing, and 100% keeps the
# imported rest-hand spread. The asymmetric curve concentrates the extra
# closing range below 50% without changing the already-approved midpoint.
# Individual fingers still use the weighted values above, preserving a natural
# fan instead of rotating every proximal joint by the same amount.
const RELAXED_SEAM_DEFAULT_PERCENT := 50.0
const RELAXED_SEAM_MAX_ADDUCTION_SCALE := 8.0
const EULER_ORDER := EULER_ORDER_YXZ
const PoseStreamServer = preload("res://scripts/pose_stream_server.gd")
# A compact dock leaves enough room for posing in the 3D viewport while still
# showing several animation tracks.  Editor split offsets are multiplied by
# the editor scale, exactly like Godot's own saved-layout restoration.
const ANIMATION_DOCK_HEIGHT := 250.0

var _panel: PanelContainer
var _bone_option: OptionButton
var _binding_label: Label
var _rotation_fields: Array[SpinBox] = []
var _status_label: Label
var _selected_bone: StringName = &"Hips"
var _updating_fields := false
var _editor_pose_server: Node
var _bound_skeleton: Skeleton3D
var _bound_bone_names: Array[StringName] = []
var _finger_hand_option: OptionButton
var _finger_preset_option: OptionButton
var _finger_seam_slider: HSlider
var _finger_seam_value_label: Label
var _finger_status_label: Label
var _dock_repair_frames := 12

func _enter_tree() -> void:
	_build_panel()
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _panel)
	# EditorPlugin input is separate from the running game's input tree. Keep a
	# small editor-side hook so a click in the 3D workspace really gives the
	# keyboard back to viewport/TCP navigation after a SpinBox LineEdit was
	# edited.
	set_process_input(true)
	scene_changed.connect(_on_scene_changed)
	EditorInterface.get_selection().selection_changed.connect(_on_editor_selection_changed)
	_start_editor_pose_server()
	_select_bone(_selected_bone)
	set_process(true)
	# Godot 4.7 can restore a selected bottom-dock tab while leaving its center
	# split collapsed.  In that state selecting Animation only shows the
	# AnimationPlayer Inspector and the timeline appears to be missing.  Pulse
	# the saved tab after all editor plugins have entered the tree so the dock's
	# normal tab-changed handler restores its saved height below the viewport.
	call_deferred("_restore_saved_bottom_dock")

func _exit_tree() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if EditorInterface.get_selection().selection_changed.is_connected(_on_editor_selection_changed):
		EditorInterface.get_selection().selection_changed.disconnect(_on_editor_selection_changed)
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

func _restore_saved_bottom_dock() -> void:
	# Editor layout restoration finishes after EditorPlugin._enter_tree(). Wait
	# through a few frames so our repair runs after Godot has applied the saved
	# selected tab and collapsed state, not before it.
	for _frame in 3:
		await get_tree().process_frame
	var bottom_panel := _find_control_by_class(EditorInterface.get_base_control(), &"EditorBottomPanel") as TabContainer
	if bottom_panel == null:
		return
	var saved_tab := bottom_panel.current_tab
	if saved_tab < 0:
		return
	# set_current_tab() is intentional here: assigning the same index does not
	# emit tab_changed, so briefly deselect before restoring the saved tab.
	bottom_panel.current_tab = -1
	bottom_panel.current_tab = saved_tab
	# Keep a defensive fallback for the Godot 4.7 stale-layout case: if the
	# internal center split remains collapsed even after tab_changed, explicitly
	# restore the normal docked height (scaled exactly as editor layout offsets
	# are scaled by Godot itself).
	var center_split := bottom_panel.get_parent() as SplitContainer
	if center_split != null:
		center_split.collapsed = false
		center_split.split_offset = -int(ANIMATION_DOCK_HEIGHT * EditorInterface.get_editor_scale())

func _find_control_by_class(node: Node, class_name_to_find: StringName) -> Control:
	if node is Control and node.get_class() == class_name_to_find:
		return node as Control
	for child in node.get_children(true):
		var match := _find_control_by_class(child, class_name_to_find)
		if match != null:
			return match
	return null

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
	_dock_repair_frames = 12
	call_deferred("_ensure_animation_dock")

func _on_editor_selection_changed() -> void:
	# The built-in AnimationPlayer editor normally opens its bottom panel here.
	# Re-assert that behavior after Quick FK/editor layout changes, but only
	# when the user actually selects an AnimationPlayer (so manually closing the
	# panel remains possible).
	var selection := EditorInterface.get_selection()
	for node in selection.get_selected_nodes():
		if node is AnimationPlayer:
			_dock_repair_frames = 12
			call_deferred("_ensure_animation_dock")
			return

func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "QuickFKBones"
	# The pose panel is edited with the mouse while the keyboard is reserved for
	# viewport/TCP exploration. FOCUS_CLICK still lets a user click a field and
	# type a value, but prevents Godot's default arrow-key focus traversal from
	# moving the selection rectangle between Roll/Pitch/Yaw controls.
	_panel.focus_mode = Control.FOCUS_NONE
	# Keep the tool narrow enough that posing remains a viewport-first workflow.
	# Long status strings are clipped below, so they no longer inflate this
	# spatial-editor side column to the width of their full text.
	_panel.custom_minimum_size = Vector2(176.0, 0.0)
	# Cap the editor-side tool vertically as well as making its contents
	# scrollable.  Godot 4.7 uses desired/maximum sizes while negotiating the
	# center split, so a finite maximum prevents this optional tool from taking
	# the space reserved for the Animation bottom dock.
	_panel.custom_maximum_size = Vector2(-1.0, 330.0)
	_panel.tooltip_text = "Fine-tune local FK rotations without expanding the Skeleton3D bone hierarchy."

	# The complete Quick FK tool must be scrollable, not only its bone list.
	# Finger presets add useful controls but also make the tool taller.  Without
	# this outer ScrollContainer the left spatial-editor panel reports the full
	# content height as its minimum height, which can squeeze Godot's bottom
	# Animation/Output dock to zero pixels and make it look as if it vanished.
	var panel_scroll := ScrollContainer.new()
	panel_scroll.name = "QuickFKScroll"
	panel_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_panel.add_child(panel_scroll)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel_scroll.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 5)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	content.add_child(header)
	var title := Label.new()
	title.text = "Quick FK"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_binding_label = Label.new()
	_binding_label.text = "No rig"
	_binding_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_binding_label.modulate = Color(0.55, 0.78, 0.98)
	_binding_label.tooltip_text = "Skeleton currently controlled by Quick FK."
	header.add_child(_binding_label)

	var hint := Label.new()
	hint.text = "Bone rotation + hand presets"
	hint.modulate = Color(0.78, 0.82, 0.88)
	hint.clip_text = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.max_lines_visible = 1
	hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hint.tooltip_text = "Rotate a body bone or apply a complete-hand finger pose."
	content.add_child(hint)

	# A dropdown replaces the old vertical stack of bone buttons.  It preserves
	# one-click access while returning most of the viewport height to the user.
	var bone_row := HBoxContainer.new()
	bone_row.add_theme_constant_override("separation", 6)
	content.add_child(bone_row)
	var bone_label := Label.new()
	bone_label.text = "Bone"
	bone_label.custom_minimum_size.x = 42.0
	bone_row.add_child(bone_label)
	_bone_option = OptionButton.new()
	_bone_option.name = "BoneSelector"
	_bone_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bone_option.focus_mode = Control.FOCUS_CLICK
	_bone_option.tooltip_text = "Choose the body or ponytail bone to rotate."
	for bone_name in _bone_names_for_skeleton(_find_skeleton()):
		_bone_option.add_item(str(bone_name))
	_bone_option.item_selected.connect(_on_bone_option_selected)
	bone_row.add_child(_bone_option)

	content.add_child(HSeparator.new())

	var rotation_title := Label.new()
	rotation_title.text = "Local rotation"
	rotation_title.name = "RotationTitle"
	rotation_title.clip_text = true
	rotation_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rotation_title.max_lines_visible = 1
	rotation_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	content.add_child(rotation_title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 3)
	content.add_child(grid)

	for axis_number in 3:
		var axis_label := Label.new()
		axis_label.text = ["X", "Y", "Z"][axis_number]
		axis_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		axis_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
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
		field.custom_minimum_size.x = 108.0
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		field.tooltip_text = "Local %s rotation in degrees. Type a value or drag horizontally." % axis_label.text
		# SpinBox owns a LineEdit child. Apply the same focus policy to that
		# child, otherwise it can still hand arrow presses to sibling Controls.
		var line_edit := field.get_line_edit()
		if line_edit != null:
			line_edit.focus_mode = Control.FOCUS_CLICK
		field.value_changed.connect(_rotation_value_changed.bind(axis_number))
		grid.add_child(field)
		_rotation_fields.append(field)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 6)
	content.add_child(action_row)
	var reset_button := Button.new()
	reset_button.text = "Reset"
	reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_button.focus_mode = Control.FOCUS_CLICK
	reset_button.tooltip_text = "Set this bone's local pose rotation to 0°, 0°, 0°."
	reset_button.pressed.connect(_reset_selected_rotation)
	action_row.add_child(reset_button)

	var refresh_button := Button.new()
	refresh_button.text = "Sync from rig"
	refresh_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh_button.focus_mode = Control.FOCUS_CLICK
	refresh_button.tooltip_text = "Reload the displayed Euler angles from the current bone pose."
	refresh_button.pressed.connect(_refresh_rotation_fields)
	action_row.add_child(refresh_button)

	# Complete-hand presets stay visible without forcing this narrow dock to
	# grow sideways: hand selection occupies one short row and pose/application
	# share the next one.
	content.add_child(HSeparator.new())
	var finger_title := Label.new()
	finger_title.text = "Hand pose"
	content.add_child(finger_title)
	var hand_row := HBoxContainer.new()
	hand_row.add_theme_constant_override("separation", 5)
	content.add_child(hand_row)
	var hand_label := Label.new()
	hand_label.text = "Hand"
	hand_label.custom_minimum_size.x = 42.0
	hand_row.add_child(hand_label)
	_finger_hand_option = OptionButton.new()
	_finger_hand_option.name = "FingerHand"
	_finger_hand_option.add_item("Left")
	_finger_hand_option.add_item("Right")
	_finger_hand_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_finger_hand_option.focus_mode = Control.FOCUS_CLICK
	hand_row.add_child(_finger_hand_option)
	var pose_row := HBoxContainer.new()
	pose_row.add_theme_constant_override("separation", 5)
	content.add_child(pose_row)
	var pose_label := Label.new()
	pose_label.text = "Pose"
	pose_label.custom_minimum_size.x = 42.0
	pose_row.add_child(pose_label)
	_finger_preset_option = OptionButton.new()
	_finger_preset_option.name = "FingerPreset"
	for preset_name in FINGER_POSE_PRESETS.keys():
		_finger_preset_option.add_item(str(preset_name))
	_finger_preset_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_finger_preset_option.focus_mode = Control.FOCUS_CLICK
	_finger_preset_option.item_selected.connect(_on_finger_preset_selected)
	pose_row.add_child(_finger_preset_option)
	var apply_fingers_button := Button.new()
	apply_fingers_button.text = "Apply"
	apply_fingers_button.focus_mode = Control.FOCUS_CLICK
	apply_fingers_button.tooltip_text = "Set all finger joints on this hand. Supports Undo (Cmd/Ctrl+Z)."
	apply_fingers_button.pressed.connect(_apply_finger_preset)
	pose_row.add_child(apply_fingers_button)

	# Relaxed-pose spacing is deliberately adjustable after the preset was
	# authored: character proportions and camera distance change how much seam
	# reads on screen. The exact percentage remains visible, and once focused
	# the slider accepts one-percent arrow-key steps for precise tuning.
	var seam_row := HBoxContainer.new()
	seam_row.add_theme_constant_override("separation", 5)
	content.add_child(seam_row)
	var seam_label := Label.new()
	seam_label.text = "Seam"
	seam_label.custom_minimum_size.x = 42.0
	seam_label.tooltip_text = "Visible spacing between the four fingers in the Relaxed preset."
	seam_row.add_child(seam_label)
	_finger_seam_slider = HSlider.new()
	_finger_seam_slider.name = "RelaxedFingerSeam"
	_finger_seam_slider.min_value = 0.0
	_finger_seam_slider.max_value = 100.0
	_finger_seam_slider.step = 1.0
	_finger_seam_slider.value = RELAXED_SEAM_DEFAULT_PERCENT
	_finger_seam_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_finger_seam_slider.focus_mode = Control.FOCUS_CLICK
	_finger_seam_slider.tooltip_text = "0% = closed/no visible seams; 50% = tuned OTS Relaxed seam; 100% = imported rest spread."
	_finger_seam_slider.value_changed.connect(_on_finger_seam_changed)
	seam_row.add_child(_finger_seam_slider)
	_finger_seam_value_label = Label.new()
	_finger_seam_value_label.text = "%d%%" % int(RELAXED_SEAM_DEFAULT_PERCENT)
	_finger_seam_value_label.custom_minimum_size.x = 38.0
	_finger_seam_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_finger_seam_value_label.tooltip_text = _finger_seam_slider.tooltip_text
	seam_row.add_child(_finger_seam_value_label)
	_update_finger_seam_enabled()

	_finger_status_label = Label.new()
	_finger_status_label.clip_text = true
	_finger_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_finger_status_label.max_lines_visible = 1
	_finger_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_finger_status_label.modulate = Color(0.72, 0.82, 0.9)
	_finger_status_label.tooltip_text = "Result of the last complete-hand preset operation."
	content.add_child(_finger_status_label)

	_status_label = Label.new()
	_status_label.clip_text = true
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.max_lines_visible = 1
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.modulate = Color(0.9, 0.76, 0.38)
	content.add_child(_status_label)

func _process(_delta: float) -> void:
	if _dock_repair_frames > 0:
		_dock_repair_frames -= 1
		_ensure_animation_dock()
	var selected_skeleton := _selected_skeleton()
	var resolved := selected_skeleton if selected_skeleton != null else _find_skeleton()
	if resolved != _bound_skeleton:
		_bound_skeleton = resolved
		_rebuild_bone_buttons()
		_refresh_rotation_fields()

func _ensure_animation_dock() -> void:
	if not _animation_player_is_selected():
		return
	var bottom_panel := _find_control_by_class(EditorInterface.get_base_control(), &"EditorBottomPanel") as TabContainer
	if bottom_panel == null:
		return
	var animation_tab := -1
	for tab_index in bottom_panel.get_tab_count():
		if bottom_panel.get_tab_title(tab_index) == "Animation":
			animation_tab = tab_index
			break
	if animation_tab < 0:
		return
	# Make the central split a normal docked split.  This is the same state
	# produced by Godot's bottom-panel tab button, but repairs the stale
	# selected-tab/collapsed-split combination left by older layouts.
	var center_split := bottom_panel.get_parent() as SplitContainer
	if center_split != null:
		if center_split.get_child_count() > 0:
			center_split.get_child(0).show()
		center_split.collapsed = false
		center_split.split_offset = -int(ANIMATION_DOCK_HEIGHT * EditorInterface.get_editor_scale())
	# The Animation timeline is the only bottom editor surface needed for this
	# workflow.  Keep the EditorBottomPanel content visible, but hide its
	# built-in Output/Debugger/Audio/etc. tab selector so the selector bar does
	# not consume space or invite accidental panel switches.  The editor menu
	# can still switch panels programmatically if another diagnostic surface is
	# needed later.
	bottom_panel.tabs_visible = false
	if bottom_panel.current_tab != animation_tab:
		bottom_panel.current_tab = animation_tab

func _animation_player_is_selected() -> bool:
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is AnimationPlayer:
			return true
	return false

func _rebuild_bone_buttons() -> void:
	if not is_instance_valid(_bone_option):
		return
	_bone_option.clear()
	var bone_names := _bone_names_for_skeleton(_bound_skeleton)
	for bone_name in bone_names:
		_bone_option.add_item(str(bone_name))
	if is_instance_valid(_binding_label):
		_binding_label.text = _character_label_for_skeleton(_bound_skeleton)
	if bone_names.is_empty():
		_bone_option.disabled = true
		return
	_bone_option.disabled = false
	var selected_index := bone_names.find(_selected_bone)
	if selected_index < 0:
		selected_index = 0
		_selected_bone = bone_names[0]
	_bone_option.select(selected_index)
	_select_bone(_selected_bone)

func _on_bone_option_selected(index: int) -> void:
	if not is_instance_valid(_bone_option) or index < 0 or index >= _bone_option.item_count:
		return
	_select_bone(StringName(_bone_option.get_item_text(index)))

func _character_label_for_skeleton(skeleton: Skeleton3D) -> String:
	if skeleton == null:
		return "No rig"
	var character := skeleton.get_parent()
	if character != null:
		if character.name == &"MaleCarrier":
			return "Male"
		if character.name == &"IK_character":
			return "Female"
	return str(skeleton.name)

func _bone_names_for_skeleton(skeleton: Skeleton3D) -> Array[StringName]:
	var names: Array[StringName] = []
	for bone_name in COMMON_BONE_NAMES:
		if skeleton != null and skeleton.find_bone(bone_name) >= 0:
			names.append(bone_name)
	if skeleton != null:
		for bone_name in FEMALE_EXTRA_BONE_NAMES:
			if skeleton.find_bone(bone_name) >= 0:
				names.append(bone_name)
	return names

func _selected_skeleton() -> Skeleton3D:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	for node in selected:
		if node is Skeleton3D:
			return node as Skeleton3D
		var skeleton := (node as Node).get_node_or_null("Skeleton3D") as Skeleton3D
		if skeleton != null:
			return skeleton
	return null

func _select_bone(bone_name: StringName) -> void:
	_selected_bone = bone_name
	if is_instance_valid(_bone_option):
		for index in _bone_option.item_count:
			if _bone_option.get_item_text(index) == str(bone_name):
				_bone_option.select(index)
				break
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
	var modifier_locked := _selected_bone_is_modifier_locked(skeleton)
	_set_fields_enabled(not modifier_locked)
	if modifier_locked:
		_status_label.text = "Active IK owns %s. Choose a non-contact bone or bake the current IK pose first." % _selected_bone
	else:
		_status_label.text = "%s selected. Changes are captured for Cmd+S." % _selected_bone

func _rotation_value_changed(value: float, axis_number: int) -> void:
	if _updating_fields:
		return
	var skeleton := _find_skeleton()
	var bone_idx := _find_selected_bone(skeleton)
	if skeleton == null or bone_idx < 0 or _selected_bone_is_modifier_locked(skeleton):
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
	if skeleton == null or bone_idx < 0 or _selected_bone_is_modifier_locked(skeleton):
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
	var selected := _selected_skeleton()
	if selected != null:
		return selected
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	# Prefer the female character explicitly. In OTSCarryClayProxy the male
	# carrier is also a Skeleton3D, so a generic find_child("Skeleton3D") can
	# silently bind the Quick FK panel to MaleCarrier instead of IK_character.
	var character_candidates: Array[Node] = []
	for character_path in [
		NodePath("IK_character"),
		NodePath("ManualCarryBlock/IK_character"),
	]:
		var candidate := scene_root.get_node_or_null(character_path)
		if candidate != null:
			character_candidates.append(candidate)
	if scene_root.name == "IK_character":
		character_candidates.append(scene_root)
	if character_candidates.is_empty():
		_find_nodes_by_name(scene_root, &"IK_character", character_candidates)
	if character_candidates.size() != 1:
		return null
	return character_candidates[0].get_node_or_null("Skeleton3D") as Skeleton3D

func _find_nodes_by_name(node: Node, wanted_name: StringName, matches: Array[Node]) -> void:
	for child in node.get_children():
		if child.name == wanted_name:
			matches.append(child)
		_find_nodes_by_name(child, wanted_name, matches)

func _find_selected_bone(skeleton: Skeleton3D) -> int:
	if skeleton == null:
		return -1
	return skeleton.find_bone(_selected_bone)

func _has_active_modifiers(skeleton: Skeleton3D) -> bool:
	if skeleton == null:
		return false
	for child in skeleton.get_children():
		if child is SkeletonModifier3D and (child as SkeletonModifier3D).active:
			return true
	return false

func _selected_bone_is_modifier_locked(skeleton: Skeleton3D) -> bool:
	if skeleton == null or not _has_active_modifiers(skeleton):
		return false
	# MaleCarrier's active modifiers are contact IK on the two arms/hands.
	# They must not make hips, spine, legs, feet, or head uneditable in Quick FK.
	# Female IK remains conservative: its full-body solve owns the displayed FK
	# pose until the user explicitly bakes it.
	var character := skeleton.get_parent()
	if character != null and character.name == &"MaleCarrier":
		return _selected_bone in [
			&"LeftUpperArm", &"LeftLowerArm", &"LeftHand",
			&"RightUpperArm", &"RightLowerArm", &"RightHand",
		]
	return true

func _set_fields_enabled(enabled: bool) -> void:
	for field in _rotation_fields:
		field.editable = enabled
	# Finger presets are a local FK operation on the selected hand.  A carrier
	# can legitimately have active contact/secondary-motion modifiers on the
	# rest of the body while its fingers still need authoring.  The old code
	# used the body-wide `enabled` flag for these controls, which made both hand
	# selectors gray whenever *any* carrier IK modifier was active.  Keep the
	# rotation fields protected, but expose hand presets whenever the selected
	# skeleton actually contains the canonical finger chains.
	var skeleton := _selected_skeleton()
	if skeleton == null:
		skeleton = _bound_skeleton if is_instance_valid(_bound_skeleton) else _find_skeleton()
	var fingers_available := _has_finger_bones(skeleton)
	if is_instance_valid(_finger_hand_option):
		_finger_hand_option.disabled = not fingers_available
	if is_instance_valid(_finger_preset_option):
		_finger_preset_option.disabled = not fingers_available
	if is_instance_valid(_finger_seam_slider):
		_finger_seam_slider.editable = fingers_available and _selected_finger_preset_name() == &"Relaxed"
	if is_instance_valid(_finger_status_label):
		if not fingers_available:
			_finger_status_label.text = "No canonical finger chains on the selected skeleton."
		elif not enabled:
			_finger_status_label.text = "Finger presets available; body IK does not block hand authoring."

func _has_finger_bones(skeleton: Skeleton3D) -> bool:
	if skeleton == null:
		return false
	# Require at least one complete non-thumb chain.  This keeps the controls
	# disabled for environment/helper Skeleton3D nodes while supporting both the
	# male carrier and the female Humanizer rig.
	for side in [&"Left", &"Right"]:
		for finger in FINGER_NAMES:
			var proximal := skeleton.find_bone(StringName("%s%sProximal" % [side, finger]))
			var intermediate := skeleton.find_bone(StringName("%s%sIntermediate" % [side, finger]))
			var distal := skeleton.find_bone(StringName("%s%sDistal" % [side, finger]))
			if proximal >= 0 and intermediate >= 0 and distal >= 0:
				return true
	return false

func _apply_finger_preset() -> void:
	var skeleton := _selected_skeleton()
	if skeleton == null:
		skeleton = _bound_skeleton if is_instance_valid(_bound_skeleton) else _find_skeleton()
	if skeleton == null:
		if is_instance_valid(_finger_status_label):
			_finger_status_label.text = "Select a character or Skeleton3D first."
		return
	if not _has_finger_bones(skeleton):
		if is_instance_valid(_finger_status_label):
			_finger_status_label.text = "No canonical finger chains found on the selected skeleton."
		return
	var hand_prefix := "Left" if _finger_hand_option.selected == 0 else "Right"
	var preset_name := _selected_finger_preset_name()
	var changes := _collect_finger_changes(skeleton, hand_prefix, preset_name)
	_commit_finger_changes(skeleton, changes, "Apply %s %s-hand finger preset" % [preset_name, hand_prefix])
	if changes.is_empty():
		if is_instance_valid(_finger_status_label):
			_finger_status_label.text = "No matching finger bones found on the selected character."
		return
	if is_instance_valid(_finger_status_label):
		_finger_status_label.text = "%s %s preset applied to %d joints." % [hand_prefix, preset_name, changes.size()]

func _collect_finger_changes(
	skeleton: Skeleton3D,
	hand_prefix: String,
	preset_name: StringName,
) -> Array[Dictionary]:
	var preset: Dictionary = FINGER_POSE_PRESETS.get(preset_name, {})
	var changes: Array[Dictionary] = []
	var preset_adduction: Dictionary = FINGER_POSE_ADDUCTION_DEGREES.get(preset_name, {})
	var adduction_scale := _relaxed_adduction_scale() if preset_name == &"Relaxed" else 1.0
	for finger_name in FINGER_NAMES:
		var angles: Array = preset.get(finger_name, [0.0, 0.0, 0.0])
		for segment_index in 3:
			var bone_name := StringName("%s%s%s" % [hand_prefix, finger_name, FINGER_SEGMENT_NAMES[segment_index]])
			var adduction_degrees := (
				float(preset_adduction.get(finger_name, 0.0)) * adduction_scale
				if segment_index == 0 else 0.0
			)
			_append_finger_change(skeleton, bone_name, float(angles[segment_index]), changes, adduction_degrees)
	for segment_index in 3:
		var thumb_bone := StringName("%sThumb%s" % [hand_prefix, [&"Metacarpal", &"Proximal", &"Distal"][segment_index]])
		var thumb_angles: Array = preset.get(&"Thumb", [0.0, 0.0, 0.0])
		_append_finger_change(skeleton, thumb_bone, float(thumb_angles[segment_index]), changes)
	return changes

func _commit_finger_changes(
	skeleton: Skeleton3D,
	changes: Array[Dictionary],
	action_name: String,
	merge_mode: UndoRedo.MergeMode = UndoRedo.MERGE_DISABLE,
) -> void:
	if changes.is_empty():
		return
	var undo := get_undo_redo()
	undo.create_action(action_name, merge_mode)
	for change in changes:
		undo.add_do_method(skeleton, "set_bone_pose_rotation", change["bone_idx"], change["new_rotation"])
		undo.add_undo_method(skeleton, "set_bone_pose_rotation", change["bone_idx"], change["old_rotation"])
	undo.add_do_method(self, "_after_finger_preset", skeleton)
	undo.add_undo_method(self, "_after_finger_preset", skeleton)
	undo.commit_action()

func _selected_finger_preset_name() -> StringName:
	if not is_instance_valid(_finger_preset_option) or _finger_preset_option.selected < 0:
		return &""
	return StringName(_finger_preset_option.get_item_text(_finger_preset_option.selected))

func _relaxed_adduction_scale() -> float:
	if not is_instance_valid(_finger_seam_slider):
		return 1.0
	var seam_ratio := clampf(_finger_seam_slider.value / 100.0, 0.0, 1.0)
	# Preserve the authored 50% pose exactly. Below the midpoint, spend much
	# more slider travel on closing the visible seams; above it, interpolate
	# normally back to the rig's natural rest spread. This is intentionally
	# piecewise instead of one linear multiplier because increasing the maximum
	# must not silently tighten every existing Relaxed pose at its default value.
	if seam_ratio <= 0.5:
		return lerpf(RELAXED_SEAM_MAX_ADDUCTION_SCALE, 1.0, seam_ratio * 2.0)
	return lerpf(1.0, 0.0, (seam_ratio - 0.5) * 2.0)

func _on_finger_preset_selected(_index: int) -> void:
	_update_finger_seam_enabled()

func _update_finger_seam_enabled() -> void:
	if not is_instance_valid(_finger_seam_slider):
		return
	var skeleton := _selected_skeleton()
	if skeleton == null:
		skeleton = _bound_skeleton if is_instance_valid(_bound_skeleton) else _find_skeleton()
	_finger_seam_slider.editable = (
		_selected_finger_preset_name() == &"Relaxed"
		and _has_finger_bones(skeleton)
	)

func _on_finger_seam_changed(value: float) -> void:
	if is_instance_valid(_finger_seam_value_label):
		_finger_seam_value_label.text = "%d%%" % int(round(value))
	if _selected_finger_preset_name() != &"Relaxed":
		return
	var skeleton := _selected_skeleton()
	if skeleton == null:
		skeleton = _bound_skeleton if is_instance_valid(_bound_skeleton) else _find_skeleton()
	if skeleton == null or not _has_finger_bones(skeleton):
		_update_finger_seam_enabled()
		return
	var hand_prefix := "Left" if _finger_hand_option.selected == 0 else "Right"
	var changes := _collect_finger_changes(skeleton, hand_prefix, &"Relaxed")
	# MERGE_ENDS turns a continuous slider gesture into one useful Undo step:
	# the first pose is retained as the undo state and the final percentage as
	# the redo state, rather than adding dozens of intermediate seam values.
	_commit_finger_changes(
		skeleton,
		changes,
		"Adjust %s relaxed finger seam" % hand_prefix,
		UndoRedo.MERGE_ENDS,
	)
	if is_instance_valid(_finger_status_label):
		_finger_status_label.text = "%s Relaxed seam: %d%%." % [hand_prefix, int(round(value))]

func _append_finger_change(
	skeleton: Skeleton3D,
	bone_name: StringName,
	curl_degrees: float,
	changes: Array[Dictionary],
	adduction_degrees: float = 0.0,
) -> void:
	var bone_idx := skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return
	var old_rotation := skeleton.get_bone_pose_rotation(bone_idx)
	# Skeleton3D stores an absolute parent-local bone orientation, not a bare
	# rest-relative delta. Replacing it with Quaternion(axis, angle) discards the
	# imported rest basis and severely twists the thumb. Start from rest and
	# post-multiply the deterministic local hinge delta instead. Deriving the
	# hinge perpendicular to the actual rest-chain direction also avoids leaving
	# any axial component that could twist the skinned finger around its length.
	var rest_rotation := skeleton.get_bone_rest(bone_idx).basis.get_rotation_quaternion().normalized()
	var hinge_axis := _finger_hinge_axis(skeleton, bone_idx, bone_name)
	var curl_delta := Quaternion(hinge_axis, deg_to_rad(curl_degrees))
	var adduction_delta := Quaternion.IDENTITY
	if not is_zero_approx(adduction_degrees):
		var adduction_axis := _finger_adduction_axis(skeleton, bone_idx, bone_name)
		adduction_delta = Quaternion(adduction_axis, deg_to_rad(adduction_degrees))
	# Both axes are expressed in the imported rest-local frame. Apply the tiny
	# grouping correction first, then the shallow flexion arc, without ever
	# accumulating from the previously selected preset.
	var new_rotation := (rest_rotation * curl_delta * adduction_delta).normalized()
	changes.append({"bone_idx": bone_idx, "old_rotation": old_rotation, "new_rotation": new_rotation})

func _finger_hinge_axis(skeleton: Skeleton3D, bone_idx: int, bone_name: StringName) -> Vector3:
	# Child rest origins describe the outgoing phalanx direction in this bone's
	# local rest frame. Distal joints have no child, so their own incoming rest
	# offset is the best available continuation direction (these distal rest
	# bases are identity on both Humanizer characters).
	var chain_direction := Vector3.ZERO
	var children := skeleton.get_bone_children(bone_idx)
	if not children.is_empty():
		chain_direction = skeleton.get_bone_rest(int(children[0])).origin
	else:
		chain_direction = skeleton.get_bone_rest(bone_idx).origin
	if chain_direction.length_squared() < 0.00000001:
		return Vector3(0.0, 0.0, -1.0) if str(bone_name).begins_with("Right") else Vector3(0.0, 0.0, 1.0)
	chain_direction = chain_direction.normalized()

	# Humanizer's palm/finger rest frames use local -Y as the closing direction.
	# Project it onto the plane perpendicular to the phalanx so the resulting
	# hinge contains exactly zero roll/twist around the finger itself.
	var curl_direction := Vector3.DOWN - chain_direction * chain_direction.dot(Vector3.DOWN)
	if curl_direction.length_squared() < 0.00000001:
		curl_direction = Vector3.FORWARD - chain_direction * chain_direction.dot(Vector3.FORWARD)
	var hinge_axis := chain_direction.cross(curl_direction.normalized()).normalized()
	return hinge_axis

func _finger_adduction_axis(skeleton: Skeleton3D, bone_idx: int, bone_name: StringName) -> Vector3:
	# Aim each proximal phalanx a few degrees toward the middle finger. Working
	# from global rest directions and converting the target back into this bone's
	# local frame makes the same preset valid for mirrored left/right hands and
	# for the slightly different male/female proportions.
	var side_prefix := "Right" if str(bone_name).begins_with("Right") else "Left"
	var middle_idx := skeleton.find_bone(StringName(side_prefix + "MiddleProximal"))
	if middle_idx < 0:
		return Vector3.UP
	var middle_children := skeleton.get_bone_children(middle_idx)
	var bone_children := skeleton.get_bone_children(bone_idx)
	if middle_children.is_empty() or bone_children.is_empty():
		return Vector3.UP

	var bone_global_rest := skeleton.get_bone_global_rest(bone_idx)
	var middle_global_rest := skeleton.get_bone_global_rest(middle_idx)
	var current_direction := skeleton.get_bone_rest(int(bone_children[0])).origin.normalized()
	var middle_direction_global := (
		middle_global_rest.basis * skeleton.get_bone_rest(int(middle_children[0])).origin
	).normalized()
	var middle_direction_local := (bone_global_rest.basis.inverse() * middle_direction_global).normalized()
	var axis := current_direction.cross(middle_direction_local)
	if axis.length_squared() < 0.00000001:
		return Vector3.UP
	return axis.normalized()

func _after_finger_preset(skeleton: Skeleton3D) -> void:
	if skeleton != null:
		skeleton.force_update_all_bone_transforms()
		var controller := skeleton.get_parent()
		if controller != null and controller.has_method("commit_current_fk_pose_for_saving"):
			controller.call("commit_current_fk_pose_for_saving")
	_refresh_rotation_fields()
