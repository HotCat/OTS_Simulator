extends Node

## Runtime bridge for text-authored poses and future motion-capture sources.
##
## Protocol: UTF-8 newline-delimited JSON over localhost TCP. Deliberate
## `pose.apply` messages are evaluated immediately. High-rate `pose.frame`
## messages are coalesced by character and only the newest frame is evaluated
## during each Godot frame, preventing stale mocap data from accumulating.

const PROTOCOL_NAME := "godot-pose-stream"
const PROTOCOL_VERSION := 1
const DEFAULT_BIND_ADDRESS := "127.0.0.1"
const DEFAULT_PORT := 7007
const MAX_CLIENTS := 8
const MAX_BUFFER_BYTES := 4 * 1024 * 1024
const MAX_MESSAGE_BYTES := 2 * 1024 * 1024
const CAMERA_SERVICE_GROUP := &"ots_render_capture_service"
const DEFAULT_WALK_CONTROLLER_PATH := NodePath("FemaleWalkController")

const CAMERA_CAPABILITIES: Array[String] = [
	"camera.follow.confirm",
	"camera.follow.stop",
	"camera.view.set",
	"camera.view.restore",
	"camera.program.load",
	"camera.program.play",
	"camera.program.pause",
	"camera.program.reset",
	"camera.program.clear",
	"camera.program.status",
]

const WALK_TRANSPORT_CAPABILITIES: Array[String] = [
	"walk.play",
	"walk.pause",
	"walk.restart",
	"walk.refresh_trajectory",
	"walk.record_camera_motion",
	"walk.motion_source.set",
	"walk.motion_source.status",
	"walk.status",
]

## Motion-source transport deliberately lives beside the legacy walk commands.
## This keeps existing clients compatible while allowing a shot to declare
## whether the controller owns motion (`walk_cycle`), should hold still
## (`stationary`), or should yield to pose.frame/pose.apply (`external_pose`).

signal pose_applied(message: Dictionary, response: Dictionary)

## EditorPlugin sets these before adding the receiver to the editor tree.
## Runtime autoloads leave them at their defaults.
var allow_editor := false
var bind_address_override := ""
var port_override := -1
var scene_root_provider: Callable

var _server := TCPServer.new()
var _clients: Array[Dictionary] = []
var _pending_frames: Dictionary = {}
var _root_motion_base_positions: Dictionary = {}
var _root_motion_base_rotations: Dictionary = {}
var _root_motion_origin_paths: Dictionary = {}
var _listening := false

func _ready() -> void:
	if Engine.is_editor_hint() and not allow_editor:
		return
	var bind_address := bind_address_override
	if bind_address.is_empty():
		bind_address = str(ProjectSettings.get_setting("pose_stream/bind_address", DEFAULT_BIND_ADDRESS))
	var setting_name := "pose_stream/editor_port" if Engine.is_editor_hint() else "pose_stream/runtime_port"
	var port := port_override
	if port < 0:
		port = int(ProjectSettings.get_setting(setting_name, DEFAULT_PORT))
	var error := _server.listen(port, bind_address)
	if error != OK:
		push_error("PoseStream could not listen on %s:%d (error %d)" % [bind_address, port, error])
		return
	_listening = true
	print("POSE_STREAM listening on %s:%d protocol=%s/%d" % [bind_address, port, PROTOCOL_NAME, PROTOCOL_VERSION])

func _exit_tree() -> void:
	for client in _clients:
		var peer := client.get("peer") as StreamPeerTCP
		if peer != null:
			peer.disconnect_from_host()
	_clients.clear()
	if _listening:
		_server.stop()

func _process(_delta: float) -> void:
	if not _listening:
		return
	_accept_clients()
	_poll_clients()
	_apply_pending_frames()

func _accept_clients() -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			return
		if _clients.size() >= MAX_CLIENTS:
			_reply(peer, {"type": "error", "error": "too_many_clients"})
			peer.disconnect_from_host()
			continue
		peer.set_no_delay(true)
		_clients.append({"peer": peer, "buffer": ""})
		var capabilities: Array[String] = [
			"pose.apply", "pose.capture", "pose.frame", "fk", "ik",
			"hybrid", "quaternion", "euler_degrees",
		]
		if Engine.is_editor_hint():
			capabilities.append_array(CAMERA_CAPABILITIES)
			capabilities.append_array(WALK_TRANSPORT_CAPABILITIES)
		_reply(peer, {
			"protocol": PROTOCOL_NAME,
			"version": PROTOCOL_VERSION,
			"type": "hello",
			"capabilities": capabilities,
		})

func _poll_clients() -> void:
	for client_index in range(_clients.size() - 1, -1, -1):
		var client := _clients[client_index]
		var peer := client.get("peer") as StreamPeerTCP
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_clients.remove_at(client_index)
			continue
		var available := peer.get_available_bytes()
		if available <= 0:
			continue
		var read_result := peer.get_data(available)
		if read_result[0] != OK:
			_clients.remove_at(client_index)
			continue
		client["buffer"] = str(client.get("buffer", "")) + (read_result[1] as PackedByteArray).get_string_from_utf8()
		if client["buffer"].length() > MAX_BUFFER_BYTES:
			_reply(peer, {"type": "error", "error": "input_buffer_too_large"})
			peer.disconnect_from_host()
			_clients.remove_at(client_index)
			continue
		_consume_lines(client)

func _consume_lines(client: Dictionary) -> void:
	var peer := client.get("peer") as StreamPeerTCP
	var buffer := str(client.get("buffer", ""))
	while true:
		var newline := buffer.find("\n")
		if newline < 0:
			break
		var line := buffer.substr(0, newline).strip_edges()
		buffer = buffer.substr(newline + 1)
		if line.is_empty():
			continue
		if line.length() > MAX_MESSAGE_BYTES:
			_reply(peer, {"type": "error", "error": "message_too_large"})
			continue
		_handle_line(peer, line)
	client["buffer"] = buffer

func _handle_line(peer: StreamPeerTCP, line: String) -> void:
	var parsed = JSON.parse_string(line)
	if not parsed is Dictionary:
		_reply(peer, {"type": "error", "error": "invalid_json_object"})
		return
	var message := parsed as Dictionary
	var message_type := str(message.get("type", ""))
	if message_type == "ping":
		_reply(peer, {"type": "pong", "request_id": message.get("request_id", "")})
		return
	if message_type == "pose.frame":
		var frame_key := _character_key(message)
		_pending_frames[frame_key] = {"peer": peer, "message": message}
		return
	if message_type == "pose.apply":
		var result := _apply_message(message)
		pose_applied.emit(message, result)
		_reply_with_request(peer, result, message)
		return
	if message_type == "pose.capture":
		var capture_result := _capture_message(message)
		_reply_with_request(peer, capture_result, message)
		return
	if message_type.begins_with("camera."):
		var camera_result := _handle_camera_message(message_type, message)
		_reply_with_request(peer, camera_result, message)
		return
	if message_type.begins_with("walk."):
		var walk_result := _handle_walk_transport_message(message_type, message)
		_reply_with_request(peer, walk_result, message)
		return
	_reply_with_request(peer, {"type": "error", "error": "unsupported_message_type"}, message)

func _handle_walk_transport_message(message_type: String, message: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"type": "error", "error": "walk_transport_editor_only"}
	var scene := _pose_scene_root()
	if scene == null:
		return {"type": "error", "error": "edited_scene_missing"}
	var controller_path := NodePath(str(message.get(
		"controller_node", str(DEFAULT_WALK_CONTROLLER_PATH)
	)))
	var controller := scene.get_node_or_null(controller_path)
	if controller == null:
		return {
			"type": "error",
			"error": "walk_controller_not_found",
			"controller_node": str(controller_path),
		}
	var method_name := ""
	match message_type:
		"walk.play": method_name = "editor_transport_play"
		"walk.pause": method_name = "editor_transport_pause"
		"walk.restart": method_name = "editor_transport_restart"
		"walk.refresh_trajectory": method_name = "editor_transport_refresh_trajectory"
		"walk.record_camera_motion": method_name = "editor_transport_record_camera_motion"
		"walk.motion_source.set": method_name = "editor_transport_set_motion_source"
		"walk.motion_source.status": method_name = "editor_transport_status"
		"walk.status": method_name = "editor_transport_status"
		_:
			return {"type": "error", "error": "unsupported_walk_message_type"}
	if not controller.has_method(method_name):
		return {
			"type": "error",
			"error": "walk_transport_method_unavailable",
			"method": method_name,
		}
	var result: Dictionary
	if message_type == "walk.record_camera_motion":
		var options_value = message.get("options", {})
		if not options_value is Dictionary:
			return {"type": "error", "error": "walk_record_options_must_be_object"}
		result = controller.call(method_name, options_value) as Dictionary
	elif message_type == "walk.motion_source.set":
		var source_value := str(message.get("source", ""))
		result = controller.call(method_name, source_value) as Dictionary
	else:
		result = controller.call(method_name) as Dictionary
	if not bool(result.get("ok", false)):
		result["type"] = "error"
		return result
	result["controller_node"] = str(controller_path)
	result["type"] = _walk_response_type(message_type)
	return result

func _walk_response_type(message_type: String) -> String:
	match message_type:
		"walk.play": return "walk.playing"
		"walk.pause": return "walk.paused"
		"walk.restart": return "walk.restarted"
		"walk.refresh_trajectory": return "walk.trajectory_refreshed"
		"walk.record_camera_motion": return "walk.camera_recording_toggled"
		"walk.motion_source.set": return "walk.motion_source_set"
		"walk.motion_source.status": return "walk.motion_source_status"
		"walk.status": return "walk.status"
		_: return "walk.response"

func _handle_camera_message(message_type: String, message: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"type": "error", "error": "camera_editor_only"}
	var service := get_tree().get_first_node_in_group(CAMERA_SERVICE_GROUP)
	if service == null:
		return {"type": "error", "error": "camera_service_unavailable"}
	var result: Dictionary
	match message_type:
		"camera.follow.confirm":
			var options_value = message.get("options", {})
			if not options_value is Dictionary:
				return {"type": "error", "error": "camera_options_must_be_object"}
			result = service.call("confirm_editor_camera_follow", options_value) as Dictionary
		"camera.follow.stop":
			result = service.call("stop_editor_camera_follow") as Dictionary
		"camera.view.set":
			var view_value = message.get("view")
			if not view_value is Dictionary:
				return {"type": "error", "error": "camera_view_missing"}
			result = service.call("set_editor_camera_initial_view", view_value) as Dictionary
		"camera.view.restore":
			result = service.call("restore_editor_camera_initial_view") as Dictionary
		"camera.program.load":
			var program_value = message.get("program")
			if not program_value is Dictionary:
				return {"type": "error", "error": "camera_program_missing"}
			result = service.call(
				"load_editor_camera_program",
				program_value,
				bool(message.get("auto_play", true))
			) as Dictionary
		"camera.program.play":
			result = service.call(
				"play_editor_camera_program", bool(message.get("restart", false))
			) as Dictionary
		"camera.program.pause":
			result = service.call("pause_editor_camera_program") as Dictionary
		"camera.program.reset":
			result = service.call("reset_editor_camera_program") as Dictionary
		"camera.program.clear":
			result = service.call("clear_editor_camera_program") as Dictionary
		"camera.program.status":
			result = service.call("editor_camera_program_status") as Dictionary
		_:
			return {"type": "error", "error": "unsupported_camera_message_type"}
	if not bool(result.get("ok", false)):
		result["type"] = "error"
		return result
	result["type"] = _camera_response_type(message_type)
	return result

func _camera_response_type(message_type: String) -> String:
	match message_type:
		"camera.follow.confirm": return "camera.follow.confirmed"
		"camera.follow.stop": return "camera.follow.stopped"
		"camera.view.set": return "camera.view.set"
		"camera.view.restore": return "camera.view.restored"
		"camera.program.load": return "camera.program.loaded"
		"camera.program.play": return "camera.program.playing"
		"camera.program.pause": return "camera.program.paused"
		"camera.program.reset": return "camera.program.reset"
		"camera.program.clear": return "camera.program.cleared"
		"camera.program.status": return "camera.program.status"
		_: return "camera.response"

func _apply_pending_frames() -> void:
	if _pending_frames.is_empty():
		return
	var frames := _pending_frames.values()
	_pending_frames.clear()
	for entry in frames:
		var peer := entry.get("peer") as StreamPeerTCP
		var message := entry.get("message") as Dictionary
		var result := _apply_message(message)
		pose_applied.emit(message, result)
		if bool(message.get("ack", false)):
			_reply_with_request(peer, result, message)

func _apply_message(message: Dictionary) -> Dictionary:
	if int(message.get("version", PROTOCOL_VERSION)) != PROTOCOL_VERSION:
		return {"type": "error", "error": "unsupported_protocol_version"}
	var pose_value = message.get("pose")
	if not pose_value is Dictionary:
		return {"type": "error", "error": "pose_missing"}
	var character_spec_value = message.get("character", {})
	if not character_spec_value is Dictionary:
		return {"type": "error", "error": "character_must_be_object"}
	var character_spec := character_spec_value as Dictionary
	var character := _find_character(character_spec)
	if character == null:
		return {"type": "error", "error": "character_not_found", "character_path": _character_key(message)}
	var skeleton_path := NodePath(str(character_spec.get("skeleton_path", "Skeleton3D")))
	var skeleton := character.get_node_or_null(skeleton_path) as Skeleton3D
	if skeleton == null:
		return {"type": "error", "error": "skeleton_not_found", "skeleton_path": str(skeleton_path)}
	var pose := pose_value as Dictionary
	var mode := str(pose.get("mode", "fk")).to_lower()
	if mode not in ["fk", "ik", "hybrid"]:
		return {"type": "error", "error": "invalid_pose_mode", "mode": mode}

	if character.has_method("begin_external_pose_preview"):
		character.call("begin_external_pose_preview")
	_apply_character_transform(character, pose)
	if bool(pose.get("reset_to_rest", true)):
		skeleton.reset_bone_poses()
	var root_motion_result := _apply_root_motion(character, message, pose)
	var control_result := _apply_ik_controls(character, character_spec, pose)
	var modifier_result := _apply_modifiers(skeleton, pose, mode)
	# Hybrid poses combine target-driven IK with explicit FK overrides. Let IK
	# evaluate first, then apply absolute-local bone rotations last; otherwise a
	# modifier such as pelvis_control or center_back_ik silently overwrites an
	# intentional Hips/torso correction (for example a 180-degree front/back
	# disambiguation). FK-only poses still take the same final-bone path, while IK
	# poses simply have no bone overrides to apply.
	if mode != "fk":
		skeleton.force_update_all_bone_transforms()
		skeleton.advance(0.0)
	var bone_result := _apply_bones(skeleton, pose)
	skeleton.force_update_all_bone_transforms()
	if character.has_method("end_external_pose_preview"):
		character.call("end_external_pose_preview")

	var pose_name := str(message.get("pose_name", "unnamed"))
	print("POSE_STREAM applied pose=%s mode=%s bones=%d controls=%d modifiers=%d" % [
		pose_name,
		mode,
		bone_result.applied,
		control_result.applied,
		modifier_result.applied,
	])
	return {
		"type": "pose.applied",
		"pose_name": pose_name,
		"mode": mode,
		"bones_applied": bone_result.applied,
		"bone_names_missing": bone_result.missing,
		"controls_applied": control_result.applied,
		"control_names_missing": control_result.missing,
		"modifiers_applied": modifier_result.applied,
		"modifier_names_missing": modifier_result.missing,
		"root_motion_applied": root_motion_result.applied,
		"root_motion_space": root_motion_result.space,
		"root_motion_origin": root_motion_result.get("origin", ""),
		"seq": message.get("seq", null),
		"timestamp_usec": Time.get_ticks_usec(),
	}

func _apply_root_motion(character: Node3D, message: Dictionary, pose: Dictionary) -> Dictionary:
	var root_value = pose.get("root_motion", {})
	if not root_value is Dictionary:
		return {"applied": false, "space": ""}
	var root_motion := root_value as Dictionary
	var key := _character_key(message)
	var origin_path := ""
	if bool(pose.get("reset_to_rest", false)) or not _root_motion_base_positions.has(key):
		var base_position := character.position
		origin_path = str(root_motion.get("scene_origin_node", ""))
		if not origin_path.is_empty():
			var scene := _pose_scene_root()
			var origin := scene.get_node_or_null(NodePath(origin_path)) as Node3D if scene != null else null
			var character_parent := character.get_parent() as Node3D
			if origin != null and character_parent != null:
				base_position = character_parent.to_local(origin.global_position)
		if root_motion.has("ground_y"):
			base_position.y = float(root_motion.get("ground_y", base_position.y))
		_root_motion_base_positions[key] = base_position
		_root_motion_base_rotations[key] = character.quaternion
		_root_motion_origin_paths[key] = origin_path
	var offset := _vec3(root_motion.get("position"), Vector3.ZERO)
	var space := str(root_motion.get("space", "character_parent"))
	if space != "character_parent":
		return {"applied": false, "space": space}
	character.position = (_root_motion_base_positions[key] as Vector3) + offset
	if root_motion.has("heading_direction"):
		var desired_forward := _vec3(root_motion.get("heading_direction"), Vector3.FORWARD)
		desired_forward.y = 0.0
		var local_forward := _vec3(root_motion.get("local_forward"), Vector3.FORWARD)
		local_forward.y = 0.0
		var base_rotation := _root_motion_base_rotations[key] as Quaternion
		var base_forward := base_rotation * local_forward
		base_forward.y = 0.0
		var upright_root := bool(root_motion.get("upright_root", false))
		var current_forward := local_forward if upright_root else base_forward
		if not desired_forward.is_zero_approx() and not current_forward.is_zero_approx():
			desired_forward = desired_forward.normalized()
			current_forward = current_forward.normalized()
			var correction := current_forward.signed_angle_to(desired_forward, Vector3.UP)
			var starting_rotation := Quaternion.IDENTITY if upright_root else base_rotation
			character.quaternion = (Quaternion(Vector3.UP, correction) * starting_rotation).normalized()
	elif root_motion.has("rotation_y"):
		var delta := Quaternion(Vector3.UP, float(root_motion.get("rotation_y", 0.0)))
		character.quaternion = ((_root_motion_base_rotations[key] as Quaternion) * delta).normalized()
	return {"applied": true, "space": space, "origin": str(_root_motion_origin_paths.get(key, ""))}

func _capture_message(message: Dictionary) -> Dictionary:
	var character_spec_value = message.get("character", {})
	if not character_spec_value is Dictionary:
		return {"type": "error", "error": "character_must_be_object"}
	var character_spec := character_spec_value as Dictionary
	var character := _find_character(character_spec)
	if character == null:
		return {"type": "error", "error": "character_not_found", "character_path": _character_key(message)}
	var skeleton_path := NodePath(str(character_spec.get("skeleton_path", "Skeleton3D")))
	var skeleton := character.get_node_or_null(skeleton_path) as Skeleton3D
	if skeleton == null:
		return {"type": "error", "error": "skeleton_not_found", "skeleton_path": str(skeleton_path)}

	var bones: Dictionary = {}
	for bone_idx in skeleton.get_bone_count():
		var rotation := skeleton.get_bone_pose_rotation(bone_idx).normalized()
		var position := skeleton.get_bone_pose_position(bone_idx)
		var scale := skeleton.get_bone_pose_scale(bone_idx)
		bones[str(skeleton.get_bone_name(bone_idx))] = {
			"position": [position.x, position.y, position.z],
			"rotation_quaternion": [rotation.x, rotation.y, rotation.z, rotation.w],
			"scale": [scale.x, scale.y, scale.z],
		}

	var modifiers: Dictionary = {}
	var active_modifier_count := 0
	for child in skeleton.get_children():
		if child is SkeletonModifier3D:
			var active := (child as SkeletonModifier3D).active
			modifiers[str(child.name)] = active
			if active:
				active_modifier_count += 1

	var controls: Dictionary = {}
	var controls_root := _find_controls_root(character, character_spec)
	if controls_root != null:
		for child in controls_root.get_children():
			if child is Node3D:
				controls[str(child.name)] = _node_transform_data(child as Node3D)

	var mode := "hybrid" if active_modifier_count > 0 else "fk"
	var captured_pose := {
		"mode": mode,
		"reset_to_rest": true,
		"euler_order": "YXZ",
		"character_transform": _node_transform_data(character),
		"modifiers": modifiers,
		"ik": controls,
		"bones": bones,
		"capture_metadata": {
			"source": "godot_editor" if Engine.is_editor_hint() else "godot_runtime",
			"captured_at_unix_msec": Time.get_unix_time_from_system() * 1000.0,
			"bone_count": skeleton.get_bone_count(),
			"active_modifier_count": active_modifier_count,
		},
	}
	var pose_name := str(message.get("pose_name", "editor_capture"))
	print("POSE_STREAM captured pose=%s mode=%s bones=%d controls=%d active_modifiers=%d" % [
		pose_name,
		mode,
		skeleton.get_bone_count(),
		controls.size(),
		active_modifier_count,
	])
	return {
		"type": "pose.captured",
		"pose_name": pose_name,
		"pose": captured_pose,
		"bones_captured": skeleton.get_bone_count(),
		"controls_captured": controls.size(),
		"active_modifiers": active_modifier_count,
	}

func _node_transform_data(node: Node3D) -> Dictionary:
	var rotation := node.quaternion.normalized()
	return {
		"position": [node.position.x, node.position.y, node.position.z],
		"rotation_quaternion": [rotation.x, rotation.y, rotation.z, rotation.w],
		"scale": [node.scale.x, node.scale.y, node.scale.z],
	}

func _find_character(character_spec: Dictionary) -> Node3D:
	var scene := _pose_scene_root()
	if scene == null:
		return null
	var path_string := str(character_spec.get("node_path", "IK_character"))
	var character := scene.get_node_or_null(NodePath(path_string)) as Node3D
	if character == null and str(scene.name) == path_string:
		character = scene as Node3D
	return character

func _pose_scene_root() -> Node:
	var scene: Node = null
	if scene_root_provider.is_valid():
		scene = scene_root_provider.call() as Node
	else:
		scene = get_tree().current_scene
	return scene

func _character_key(message: Dictionary) -> String:
	var spec_value = message.get("character", {})
	if spec_value is Dictionary:
		return str((spec_value as Dictionary).get("node_path", "IK_character"))
	return "IK_character"

func _apply_character_transform(character: Node3D, pose: Dictionary) -> void:
	var root_value = pose.get("character_transform")
	if not root_value is Dictionary:
		return
	_apply_node_transform(character, root_value as Dictionary)

func _apply_bones(skeleton: Skeleton3D, pose: Dictionary) -> Dictionary:
	var applied := 0
	var missing: Array[String] = []
	var bones_value = pose.get("bones", {})
	if not bones_value is Dictionary:
		return {"applied": applied, "missing": missing}
	var bones := bones_value as Dictionary
	var euler_order := _euler_order_from_name(str(pose.get("euler_order", "YXZ")))
	for bone_name_value in bones:
		var bone_name := str(bone_name_value)
		var bone_data_value = bones[bone_name_value]
		if not bone_data_value is Dictionary:
			continue
		var bone_idx := skeleton.find_bone(bone_name)
		if bone_idx < 0:
			missing.append(bone_name)
			continue
		var bone_data := bone_data_value as Dictionary
		var weight := clampf(float(bone_data.get("weight", 1.0)), 0.0, 1.0)
		if bone_data.has("position"):
			var position := _vec3(bone_data.get("position"), skeleton.get_bone_pose_position(bone_idx))
			skeleton.set_bone_pose_position(bone_idx, skeleton.get_bone_pose_position(bone_idx).lerp(position, weight))
		var target_rotation: Variant = _rotation_from_data(bone_data, euler_order)
		if target_rotation != null:
			var current_rotation := skeleton.get_bone_pose_rotation(bone_idx)
			skeleton.set_bone_pose_rotation(bone_idx, current_rotation.slerp(target_rotation as Quaternion, weight).normalized())
		if bone_data.has("scale"):
			var scale := _vec3(bone_data.get("scale"), skeleton.get_bone_pose_scale(bone_idx))
			skeleton.set_bone_pose_scale(bone_idx, skeleton.get_bone_pose_scale(bone_idx).lerp(scale, weight))
		applied += 1
	return {"applied": applied, "missing": missing}

func _apply_ik_controls(character: Node3D, character_spec: Dictionary, pose: Dictionary) -> Dictionary:
	var applied := 0
	var missing: Array[String] = []
	var controls_value = pose.get("ik", {})
	if not controls_value is Dictionary:
		return {"applied": applied, "missing": missing}
	if (controls_value as Dictionary).is_empty():
		return {"applied": applied, "missing": missing}
	var controls_root := _find_controls_root(character, character_spec)
	if controls_root == null:
		return {"applied": applied, "missing": [str(character_spec.get("controls_path", ""))]}
	for control_name_value in (controls_value as Dictionary):
		var control_name := str(control_name_value)
		var control_data_value = controls_value[control_name_value]
		if not control_data_value is Dictionary:
			continue
		var control := controls_root.get_node_or_null(NodePath(control_name)) as Node3D
		if control == null:
			missing.append(control_name)
			continue
		_apply_node_transform(control, control_data_value as Dictionary)
		applied += 1
	return {"applied": applied, "missing": missing}

func _find_controls_root(character: Node3D, character_spec: Dictionary) -> Node3D:
	# An empty path explicitly declares an FK-only character. This prevents a
	# second actor from accidentally capturing or driving another actor's scene-
	# level PoseControls through the old ../PoseControls default.
	var controls_path_string := str(character_spec.get("controls_path", "../PoseControls"))
	if controls_path_string.is_empty():
		return null
	return character.get_node_or_null(NodePath(controls_path_string)) as Node3D

func _apply_modifiers(skeleton: Skeleton3D, pose: Dictionary, mode: String) -> Dictionary:
	var applied := 0
	var missing: Array[String] = []
	for child in skeleton.get_children():
		if child is SkeletonModifier3D:
			(child as SkeletonModifier3D).active = false
	if mode == "fk":
		return {"applied": applied, "missing": missing}
	var modifiers_value = pose.get("modifiers", {})
	if not modifiers_value is Dictionary:
		return {"applied": applied, "missing": missing}
	for modifier_name_value in (modifiers_value as Dictionary):
		var modifier_name := str(modifier_name_value)
		var modifier := skeleton.get_node_or_null(NodePath(modifier_name)) as SkeletonModifier3D
		if modifier == null:
			missing.append(modifier_name)
			continue
		modifier.active = bool(modifiers_value[modifier_name_value])
		applied += 1
	return {"applied": applied, "missing": missing}

func _apply_node_transform(node: Node3D, data: Dictionary) -> void:
	if data.has("position"):
		node.position = _vec3(data.get("position"), node.position)
	var rotation: Variant = _rotation_from_data(data, _euler_order_from_name(str(data.get("euler_order", "YXZ"))))
	if rotation != null:
		node.quaternion = rotation as Quaternion
	if data.has("scale"):
		node.scale = _vec3(data.get("scale"), node.scale)

func _rotation_from_data(data: Dictionary, euler_order: int) -> Variant:
	var quaternion_value = data.get("rotation_quaternion")
	if quaternion_value is Array and quaternion_value.size() >= 4:
		return Quaternion(
			float(quaternion_value[0]),
			float(quaternion_value[1]),
			float(quaternion_value[2]),
			float(quaternion_value[3])
		).normalized()
	var degrees_value = data.get("rotation_degrees")
	if degrees_value is Array and degrees_value.size() >= 3:
		var degrees := _vec3(degrees_value, Vector3.ZERO)
		return Basis.from_euler(Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)), euler_order).get_rotation_quaternion()
	return null

func _vec3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback

func _euler_order_from_name(order_name: String) -> int:
	match order_name.to_upper():
		"XYZ": return EULER_ORDER_XYZ
		"XZY": return EULER_ORDER_XZY
		"YZX": return EULER_ORDER_YZX
		"ZXY": return EULER_ORDER_ZXY
		"ZYX": return EULER_ORDER_ZYX
		_: return EULER_ORDER_YXZ

func _reply_with_request(peer: StreamPeerTCP, response: Dictionary, request: Dictionary) -> void:
	response["request_id"] = request.get("request_id", "")
	response["protocol"] = PROTOCOL_NAME
	response["version"] = PROTOCOL_VERSION
	_reply(peer, response)

func _reply(peer: StreamPeerTCP, response: Dictionary) -> void:
	if peer == null or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())
