@tool
extends EditorPlugin

## Scene-native authoring for the external motion stream's linear walk path.
## Waypoint positions are relative to the trajectory root. Consecutive points
## are connected by straight segments; legacy handle children are ignored.

const ROOT_NAME := "FemaleWalkTrajectory"
const PREVIEW_NAME := "CurvePreview"
const DEFAULT_JSON_PATH := "res://trajectories/female_walk_bezier.json"
const CHARACTER_PATH := NodePath("IK_character")

var _dock: VBoxContainer
var _path_field: LineEdit
var _waypoint_list: VBoxContainer
var _status: Label
var _last_marker_state := ""
var _last_selected_path := NodePath()
var _preview_material: StandardMaterial3D


func _enter_tree() -> void:
	_build_dock()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)
	add_tool_menu_item("Load Walk Trajectory Markers", _load_or_select_markers)
	add_tool_menu_item("Export Walk Trajectory JSON", _export_json)
	scene_changed.connect(_on_scene_changed)
	set_process(true)
	call_deferred("_refresh_ui")


func _exit_tree() -> void:
	set_process(false)
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	remove_tool_menu_item("Load Walk Trajectory Markers")
	remove_tool_menu_item("Export Walk Trajectory JSON")
	if is_instance_valid(_dock):
		remove_control_from_docks(_dock)
		_dock.queue_free()


func _process(_delta: float) -> void:
	var root := _trajectory_root()
	if root == null:
		return
	var state := _marker_state(root)
	if state != _last_marker_state:
		_last_marker_state = state
		_update_preview(root)
		_update_selected_status()
	var selected_path := _selected_marker_path()
	if selected_path != _last_selected_path:
		_last_selected_path = selected_path
		_update_selected_status()


func _build_dock() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "Walk Path"
	_dock.custom_minimum_size = Vector2(285.0, 0.0)
	_dock.add_theme_constant_override("separation", 7)

	var title := Label.new()
	title.text = "Walk Trajectory"
	title.add_theme_font_size_override("font_size", 16)
	_dock.add_child(title)

	var path_row := HBoxContainer.new()
	_path_field = LineEdit.new()
	_path_field.text = DEFAULT_JSON_PATH
	_path_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_field.tooltip_text = "Godot resource path written by Export JSON."
	path_row.add_child(_path_field)
	var load_button := Button.new()
	load_button.text = "Load"
	load_button.tooltip_text = "Create draggable markers from this JSON, or select existing markers."
	load_button.pressed.connect(_load_or_select_markers)
	path_row.add_child(load_button)
	_dock.add_child(path_row)

	var action_row := HBoxContainer.new()
	var add_button := Button.new()
	add_button.text = "Add waypoint"
	add_button.tooltip_text = "Append a waypoint and select it for movement with the 3D gizmo."
	add_button.pressed.connect(_add_waypoint)
	action_row.add_child(add_button)
	var remove_button := Button.new()
	remove_button.text = "Remove"
	remove_button.tooltip_text = "Remove the selected waypoint while keeping at least two points."
	remove_button.pressed.connect(_remove_selected_waypoint)
	action_row.add_child(remove_button)
	var export_button := Button.new()
	export_button.text = "Export JSON"
	export_button.tooltip_text = "Write the straight-line waypoint positions to the path above."
	export_button.pressed.connect(_export_json)
	action_row.add_child(export_button)
	_dock.add_child(action_row)

	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size.y = 190.0
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_waypoint_list = VBoxContainer.new()
	_waypoint_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_waypoint_list)
	_dock.add_child(list_scroll)

	var copy_button := Button.new()
	copy_button.text = "Copy selected waypoint JSON"
	copy_button.tooltip_text = "Copy the selected waypoint position."
	copy_button.pressed.connect(_copy_selected_waypoint)
	_dock.add_child(copy_button)

	_status = Label.new()
	_status.text = "Load a trajectory to create draggable scene markers."
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(0.82, 0.86, 0.91)
	_dock.add_child(_status)


func _on_scene_changed(_scene_root: Node) -> void:
	_last_marker_state = ""
	call_deferred("_refresh_ui")


func _refresh_ui() -> void:
	_rebuild_waypoint_list()
	var root := _trajectory_root()
	if root != null:
		_ensure_preview(root)
		_update_preview(root)
		_update_selected_status()


func _load_or_select_markers() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_status.text = "Open an editable 3D scene first."
		return
	var existing := _trajectory_root()
	if existing != null:
		_select_node(existing)
		_status.text = "Existing trajectory selected. Choose W, IN, or OUT below."
		_refresh_ui()
		return
	var path := _path_field.text.strip_edges()
	if not FileAccess.file_exists(path):
		_status.text = "Trajectory JSON does not exist: %s" % path
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_status.text = "Could not read trajectory JSON: %s" % path
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_status.text = "Trajectory JSON must contain an object."
		return
	var data := parsed as Dictionary
	var values = data.get("waypoints", [])
	if not values is Array or values.size() < 2:
		_status.text = "Trajectory JSON needs at least two waypoints."
		return

	var root := Node3D.new()
	root.name = ROOT_NAME
	root.editor_description = "DRAGGABLE LINEAR WALK PATH: waypoint positions are relative to this origin and connected by straight segments."
	var character := scene_root.get_node_or_null(CHARACTER_PATH) as Node3D
	if character != null:
		root.position = character.position
	for index in values.size():
		var item = values[index]
		if not item is Dictionary:
			continue
		var waypoint := _make_waypoint(index, _array_to_vector(item.get("position", [0.0, 0.0, 0.0])))
		(waypoint.get_node("InHandle") as Marker3D).position = _array_to_vector(item.get("in_handle", [0.0, 0.0, 0.0]))
		(waypoint.get_node("OutHandle") as Marker3D).position = _array_to_vector(item.get("out_handle", [0.0, 0.0, 0.0]))
		root.add_child(waypoint)
	_attach_root(scene_root, root)
	_ensure_preview(root)
	EditorInterface.mark_scene_as_unsaved()
	_select_node(_waypoints(root)[0])
	_last_marker_state = ""
	_refresh_ui()
	_status.text = "Linear markers loaded. Drag W to position each straight segment."


func _attach_root(scene_root: Node, root: Node3D) -> void:
	scene_root.add_child(root)
	root.owner = scene_root
	_set_marker_owners(root, scene_root)


func _set_marker_owners(node: Node, scene_root: Node) -> void:
	for child in node.get_children():
		if child.name == PREVIEW_NAME:
			continue
		child.owner = scene_root
		_set_marker_owners(child, scene_root)


func _make_waypoint(index: int, point: Vector3) -> Marker3D:
	var waypoint := Marker3D.new()
	waypoint.name = "Waypoint_%02d" % index
	waypoint.position = point
	waypoint.gizmo_extents = 0.24
	waypoint.set_meta("trajectory_waypoint", true)
	waypoint.editor_description = "WAYPOINT: drag this marker to change the path position."

	var incoming := Marker3D.new()
	incoming.name = "InHandle"
	incoming.gizmo_extents = 0.13
	incoming.editor_description = "IN HANDLE: relative vector controlling how the curve arrives at this waypoint."
	waypoint.add_child(incoming)

	var outgoing := Marker3D.new()
	outgoing.name = "OutHandle"
	outgoing.gizmo_extents = 0.13
	outgoing.editor_description = "OUT HANDLE: relative vector controlling how the curve leaves this waypoint."
	waypoint.add_child(outgoing)
	return waypoint


func _add_waypoint() -> void:
	var root := _trajectory_root()
	if root == null:
		_status.text = "Load the trajectory markers before adding a waypoint."
		return
	var points := _waypoints(root)
	var previous := points[-1]
	var delta := Vector3(0.0, 0.0, 1.5)
	if points.size() >= 2:
		var candidate := previous.position - points[-2].position
		if candidate.length() > 0.05:
			delta = candidate
	var waypoint := _make_waypoint(points.size(), previous.position + delta)
	(previous.get_node("OutHandle") as Marker3D).position = delta / 3.0
	(waypoint.get_node("InHandle") as Marker3D).position = -delta / 3.0
	(waypoint.get_node("OutHandle") as Marker3D).position = delta / 3.0
	root.add_child(waypoint)
	waypoint.owner = EditorInterface.get_edited_scene_root()
	_set_marker_owners(waypoint, EditorInterface.get_edited_scene_root())
	EditorInterface.mark_scene_as_unsaved()
	_select_node(waypoint)
	_last_marker_state = ""
	call_deferred("_refresh_ui")


func _remove_selected_waypoint() -> void:
	var root := _trajectory_root()
	if root == null:
		return
	var waypoint := _selected_waypoint()
	if waypoint == null:
		_status.text = "Select W, IN, or OUT for the waypoint to remove."
		return
	if _waypoints(root).size() <= 2:
		_status.text = "A linear path needs at least two waypoints."
		return
	root.remove_child(waypoint)
	waypoint.queue_free()
	_rename_waypoints(root)
	EditorInterface.mark_scene_as_unsaved()
	_last_marker_state = ""
	call_deferred("_refresh_ui")


func _rename_waypoints(root: Node3D) -> void:
	var points := _waypoints(root)
	for index in points.size():
		points[index].name = "Waypoint_%02d" % index


func _export_json() -> void:
	var root := _trajectory_root()
	if root == null:
		_status.text = "No trajectory markers are present in this scene."
		return
	var points := _waypoints(root)
	if points.size() < 2:
		_status.text = "At least two waypoints are required."
		return
	var items: Array = []
	for waypoint in points:
		items.append(_waypoint_data(waypoint))
	var data := {
		"type": "linear",
		"distance_mode": "fit",
		"speed_profile": "constant",
		"pace_scale": 1.0,
		"contact_correction": 0.0,
		"foot_ik": true,
		"foot_ik_strength": 1.0,
		"local_forward": [0.0, 0.0, -1.0],
		"upright_root": true,
		"ground_lock": true,
		"ground_y": 0.0,
		"ground_clearance": 0.045,
		"skeleton_origin_y": 0.0944922,
		"max_torso_tilt_degrees": 5.0,
		"torso_upright_strength": 1.0,
		"max_head_up_degrees": 4.0,
		"head_forward_axis": [0.0, 0.0, 1.0],
		"scene_origin_node": "%s/Waypoint_00" % ROOT_NAME,
		"waypoints": items,
	}
	var path := _path_field.text.strip_edges()
	var absolute_directory := ProjectSettings.globalize_path(path.get_base_dir())
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		_status.text = "Could not create trajectory directory: %s" % path.get_base_dir()
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_status.text = "Could not write trajectory JSON: %s" % path
		return
	file.store_string(JSON.stringify(data, "\t") + "\n")
	file.close()
	_status.text = "Exported %d waypoints to %s" % [points.size(), path]
	print("TRAJECTORY exported %d waypoints to %s" % [points.size(), path])


func _copy_selected_waypoint() -> void:
	var waypoint := _selected_waypoint()
	if waypoint == null:
		_status.text = "Select a waypoint first."
		return
	DisplayServer.clipboard_set(JSON.stringify(_waypoint_data(waypoint), "\t"))
	_status.text = "Copied %s values to the clipboard." % waypoint.name


func _waypoint_data(waypoint: Marker3D) -> Dictionary:
	return {
		"position": _vector_array(waypoint.position),
	}


func _rebuild_waypoint_list() -> void:
	if not is_instance_valid(_waypoint_list):
		return
	for child in _waypoint_list.get_children():
		_waypoint_list.remove_child(child)
		child.queue_free()
	var root := _trajectory_root()
	if root == null:
		return
	var points := _waypoints(root)
	for index in points.size():
		var waypoint := points[index]
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "%02d" % index
		label.custom_minimum_size.x = 30.0
		row.add_child(label)
		_add_select_button(row, "W", waypoint, "Select waypoint position marker")
		_waypoint_list.add_child(row)


func _add_select_button(row: HBoxContainer, text: String, node: Node, tooltip: String) -> void:
	var button := Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.tooltip_text = tooltip
	button.pressed.connect(_select_node.bind(node))
	row.add_child(button)


func _select_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(node)
	EditorInterface.edit_node(node)
	_update_selected_status()


func _update_selected_status() -> void:
	if not is_instance_valid(_status):
		return
	var waypoint := _selected_waypoint()
	if waypoint == null:
		return
	var data := _waypoint_data(waypoint)
	_status.text = "%s\nP %s\nPress F in the 3D view to frame the selected marker." % [
		waypoint.name,
		_format_vector(data.position),
	]


func _trajectory_root() -> Node3D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	return scene_root.get_node_or_null(NodePath(ROOT_NAME)) as Node3D


func _waypoints(root: Node3D) -> Array[Marker3D]:
	var result: Array[Marker3D] = []
	for child in root.get_children():
		if child is Marker3D and child.has_meta("trajectory_waypoint"):
			result.append(child as Marker3D)
	result.sort_custom(func(a: Marker3D, b: Marker3D) -> bool: return a.name.naturalnocasecmp_to(b.name) < 0)
	return result


func _selected_waypoint() -> Marker3D:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if selected.is_empty():
		return null
	var node := selected[0] as Node
	if node is Marker3D and node.has_meta("trajectory_waypoint"):
		return node as Marker3D
	if node is Marker3D and node.get_parent() is Marker3D and node.get_parent().has_meta("trajectory_waypoint"):
		return node.get_parent() as Marker3D
	return null


func _selected_marker_path() -> NodePath:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if selected.is_empty() or not selected[0] is Node:
		return NodePath()
	return (selected[0] as Node).get_path()


func _ensure_preview(root: Node3D) -> MeshInstance3D:
	var preview := root.get_node_or_null(NodePath(PREVIEW_NAME)) as MeshInstance3D
	if preview == null:
		preview = MeshInstance3D.new()
		preview.name = PREVIEW_NAME
		# This is an editor authoring aid only. The OTS render plugin uses this
		# metadata to hide the line in off-screen beauty/video captures while
		# leaving it visible in the live 3D editor.
		preview.set_meta("editor_only_trajectory_preview", true)
		preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(preview)
	if _preview_material == null:
		_preview_material = StandardMaterial3D.new()
		_preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_preview_material.vertex_color_use_as_albedo = true
		_preview_material.no_depth_test = true
	return preview


func _update_preview(root: Node3D) -> void:
	var preview := _ensure_preview(root)
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _preview_material)
	var points := _waypoints(root)
	for index in range(points.size() - 1):
		var current := points[index]
		var following := points[index + 1]
		_add_line(mesh, current.position, following.position, Color(0.1, 0.85, 1.0))
	mesh.surface_end()
	preview.mesh = mesh


func _add_line(mesh: ImmediateMesh, from: Vector3, to: Vector3, color: Color) -> void:
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(from)
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(to)


func _marker_state(root: Node3D) -> String:
	var values: Array[String] = []
	for waypoint in _waypoints(root):
		values.append(str(waypoint.position))
	return "|".join(values)


func _array_to_vector(value: Variant) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


func _vector_array(value: Vector3) -> Array[float]:
	return [snappedf(value.x, 0.000001), snappedf(value.y, 0.000001), snappedf(value.z, 0.000001)]


func _format_vector(value: Variant) -> String:
	if not value is Array or value.size() < 3:
		return "[0, 0, 0]"
	return "[%.3f, %.3f, %.3f]" % [float(value[0]), float(value[1]), float(value[2])]
