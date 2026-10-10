@tool
extends Node3D

## Shared director for multi-character blocking scenes.
##
## Each character keeps an independent WalkCycleController, AnimationPlayer,
## trajectory and Skeleton3D. The director only coordinates editor transport and
## fixed-step capture, so OTS Render advances both rigs on the same frame clock
## without one controller stealing the other's state.

@export var controller_paths: Array[NodePath] = [
	NodePath("Female181/WalkController"),
	NodePath("Female190/WalkController"),
]

@export_tool_button("Play both walk previews")
var play_both_action: Callable = editor_transport_play
@export_tool_button("Pause both walk previews")
var pause_both_action: Callable = editor_transport_pause
@export_tool_button("Restart both walk paths")
var restart_both_action: Callable = editor_transport_restart
@export_tool_button("Play Female181 sleeping idle")
var play_female181_sleep_action: Callable = editor_female181_sleep_play
@export_tool_button("Pause Female181 sleeping idle")
var pause_female181_sleep_action: Callable = editor_female181_sleep_pause

const MALE_CPR_ANIMATION := &"cpr/administering_cpr"
const FEMALE_CPR_ANIMATION := &"cpr/receiving_cpr"
@export_tool_button("Play CPR on male + Female190")
var play_cpr_action: Callable = editor_cpr_play
@export_tool_button("Pause CPR")
var pause_cpr_action: Callable = editor_cpr_pause
@export_tool_button("Restart CPR")
var restart_cpr_action: Callable = editor_cpr_restart
@export_tool_button("Play 9s CPR servo")
var play_cpr_servo_action: Callable = editor_servo_play
@export_tool_button("Pause CPR servo")
var pause_cpr_servo_action: Callable = editor_servo_pause
@export_tool_button("Restart CPR servo")
var restart_cpr_servo_action: Callable = editor_servo_restart
@export_tool_button("Calibrate CPR palm contact at source pose")
var calibrate_cpr_servo_action: Callable = editor_servo_calibrate
@export_tool_button("Capture current CPR palm markers")
var capture_cpr_servo_markers_action: Callable = editor_servo_capture_markers
@export_tool_button("Capture male hand pose as CPR contacts")
var capture_cpr_male_pose_action: Callable = editor_servo_capture_current_male_pose
@export_tool_button("Capture current female CPR pose")
var capture_cpr_female_pose_action: Callable = editor_servo_capture_current_female_pose
@export_tool_button("Enable CPR IK / edit markers")
var enable_cpr_marker_edit_action: Callable = editor_servo_enable_marker_edit
@export_tool_button("Disable CPR IK / restore source pose")
var disable_cpr_marker_edit_action: Callable = editor_servo_disable_marker_edit
@export_tool_button("Show CPR hand/pole handles")
var show_cpr_servo_markers_action: Callable = editor_servo_show_markers
@export_tool_button("Hide CPR hand/pole handles")
var hide_cpr_servo_markers_action: Callable = editor_servo_hide_markers
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY)
var cpr_ik_state: String:
	get:
		var servo := _servo_controller()
		if servo != null and bool((servo.call("status") as Dictionary).get("ik_enabled", false)):
			return "ON - marker controls active"
		return "OFF - edit source pose"

var _capture_fixed_step_active := false
var _capture_resume_playing := false
var _female181_sleep_playing := false
var _female181_sleep_time := 0.0
var _cpr_mode := false
var _cpr_playing := false
var _cpr_time := 0.0
var _servo_mode := false
var _servo_playing := false
var _servo_pose_prepared := false
var _female190_previous_motion_source := "walk_cycle"
var _cpr_rest_transforms: Dictionary = {}
var _cpr_rest_bones: Dictionary = {}

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	if _female181_sleep_playing:
		var sleep_player := get_node_or_null("SleepingIdleAnimationPlayer") as AnimationPlayer
		if sleep_player != null and sleep_player.has_animation(&"sleep/sleeping_idle"):
			var length := sleep_player.get_animation(&"sleep/sleeping_idle").length
			_female181_sleep_time = fposmod(_female181_sleep_time + delta, length)
			sleep_player.seek(_female181_sleep_time, true)
	if _servo_mode and _servo_playing and not _capture_fixed_step_active:
		var servo := _servo_controller()
		if servo != null:
			var state := servo.call("advance", delta) as Dictionary
			if float(state.get("time", 0.0)) >= float(state.get("length", 9.0)):
				_servo_playing = false
	elif _cpr_mode and _cpr_playing and not _capture_fixed_step_active:
		_advance_cpr(delta)

func _servo_controller() -> Node:
	return get_node_or_null("CPRServoController")

func editor_female181_sleep_play() -> Dictionary:
	var player := get_node_or_null("SleepingIdleAnimationPlayer") as AnimationPlayer
	var character := get_node_or_null("Female181") as Node3D
	if player == null or character == null or not player.has_animation(&"sleep/sleeping_idle"):
		return {"ok": false, "error": "Female181 sleeping idle library missing"}
	var walk := get_node_or_null("Female181/WalkController")
	if walk != null and walk.has_method("editor_transport_pause"):
		walk.call("editor_transport_pause")
	character.visible = true
	_female181_sleep_time = 0.0
	player.assigned_animation = &"sleep/sleeping_idle"
	player.seek(0.0, true)
	_female181_sleep_playing = true
	return {"ok": true, "animation": "sleep/sleeping_idle", "length": player.get_animation(&"sleep/sleeping_idle").length}

func editor_female181_sleep_pause() -> Dictionary:
	_female181_sleep_playing = false
	return {"ok": true, "time": _female181_sleep_time}

func editor_servo_play() -> Dictionary:
	var servo := _servo_controller()
	if servo == null:
		return {"ok": false, "error": "CPRServoController missing"}
	if not _servo_mode:
		var reference: Dictionary
		if _servo_pose_prepared or bool(servo.get("female_pose_calibrated")):
			# Quick FK may have deliberately changed MaleCarrier's wrists while
			# the CPR source pose was paused. Preserve that pose as the servo
			# baseline instead of sampling the baked clip over it.
			reference = {"ok": true}
		else:
			reference = editor_cpr_seek(0.0)
			if not bool(reference.get("ok", false)):
				return reference
		var started := servo.call("begin_from_current_cpr_pose") as Dictionary
		if not bool(started.get("ok", false)):
			return started
		_servo_mode = true
		_servo_pose_prepared = false
	if float((servo.call("status") as Dictionary).get("time", 0.0)) >= float((servo.call("status") as Dictionary).get("length", 9.0)):
		servo.call("seek", 0.0)
	_cpr_playing = false
	_servo_playing = true
	return editor_servo_status()

func editor_servo_pause() -> Dictionary:
	_servo_playing = false
	return editor_servo_status()

func editor_servo_restart() -> Dictionary:
	if not _servo_mode:
		return editor_servo_play()
	var servo := _servo_controller()
	servo.call("seek", 0.0)
	_servo_playing = true
	return editor_servo_status()

func editor_servo_seek(seconds: float) -> Dictionary:
	if not _servo_mode:
		var started := editor_servo_play()
		if not bool(started.get("ok", false)):
			return started
	_servo_playing = false
	return _servo_controller().call("seek", seconds) as Dictionary

func editor_servo_calibrate() -> Dictionary:
	if _servo_mode:
		_servo_controller().call("stop_and_restore")
		_servo_mode = false
		_servo_playing = false
	_cpr_playing = false
	_servo_pose_prepared = false
	var reference := editor_cpr_seek(0.0)
	if not bool(reference.get("ok", false)):
		return reference
	return _servo_controller().call("calibrate_contact_from_current_pose") as Dictionary

func editor_servo_capture_markers() -> Dictionary:
	# Use after making both palm markers visible and positioning them directly
	# in the 3D viewport. The resulting offsets follow the receiver's chest.
	_servo_playing = false
	var captured := _servo_controller().call("capture_current_markers_as_contact") as Dictionary
	# Capturing markers establishes a complete zero-time servo pose, even when
	# IK was enabled manually in the inspector rather than through this
	# director. Keep Play from seeking the baked CPR animation on the next call.
	if bool(captured.get("ok", false)):
		_servo_mode = bool((_servo_controller().call("status") as Dictionary).get("ok", false))
		_servo_pose_prepared = false
		notify_property_list_changed()
	return captured

func editor_servo_capture_current_male_pose() -> Dictionary:
	# This is intentionally separate from calibrate_contact_from_current_pose:
	# it never seeks either CPR AnimationPlayer, so Quick FK edits on
	# MaleCarrier/Character/Skeleton3D become the servo's actual baseline.
	# Quick FK's Restore IK may have reactivated the old contact modifiers even
	# though the director is not in servo mode. Disable them unconditionally so
	# this capture samples the edited FK source pose, not a stale marker solve.
	var servo := _servo_controller()
	if servo == null:
		return {"ok": false, "error": "CPRServoController missing"}
	servo.call("stop_without_restoring_source_pose")
	_servo_mode = false
	_servo_playing = false
	_cpr_playing = false
	_servo_pose_prepared = false
	var captured := servo.call("calibrate_contact_from_current_pose") as Dictionary
	if bool(captured.get("ok", false)):
		_servo_pose_prepared = true
		captured["next_step"] = "Run Enable CPR IK / edit markers, then move CPRServoAnchors."
	return captured

func editor_servo_capture_current_female_pose() -> Dictionary:
	# Preserve an edited Female190 Skeleton3D pose instead of letting Play seek
	# the baked receiving clip before the servo baseline is captured.
	var servo := _servo_controller()
	if servo == null:
		return {"ok": false, "error": "CPRServoController missing"}
	_servo_playing = false
	_cpr_mode = false
	_cpr_playing = false
	var captured := servo.call("capture_current_female_pose") as Dictionary
	if bool(captured.get("ok", false)):
		_servo_mode = true
		_servo_pose_prepared = false
		notify_property_list_changed()
	return captured

func editor_servo_enable_marker_edit() -> Dictionary:
	"""Enable the CPR modifier stack without advancing the compression clock.

	This is the bridge between Quick FK source-pose authoring and marker editing:
	the captured male pose remains the servo baseline, while both TwoBoneIK3D
	chains and palm orientation modifiers evaluate the visible CPRServoAnchors.
	"""
	var servo := _servo_controller()
	if servo == null:
		return {"ok": false, "error": "CPRServoController missing"}
	if not _servo_mode:
		if not _servo_pose_prepared and not bool(servo.get("female_pose_calibrated")):
			var reference := editor_cpr_seek(0.0)
			if not bool(reference.get("ok", false)):
				return reference
		var started := servo.call("begin_from_current_cpr_pose") as Dictionary
		if not bool(started.get("ok", false)):
			return started
		_servo_mode = true
		_servo_pose_prepared = false
	_servo_playing = false
	_cpr_playing = false
	servo.call("seek", 0.0)
	servo.call("set_contact_markers_visible", true)
	notify_property_list_changed()
	var result := editor_servo_status()
	result["editor_mode"] = "marker_edit"
	result["message"] = "CPR IK enabled; move LeftPalmTarget, RightPalmTarget, and elbow poles."
	return result

func editor_servo_disable_marker_edit() -> Dictionary:
	"""Disable CPR IK and restore the captured source pose for Quick FK editing."""
	if _servo_mode:
		_servo_controller().call("stop_and_restore")
	_servo_mode = false
	_servo_playing = false
	_servo_pose_prepared = true
	notify_property_list_changed()
	var result := editor_servo_status()
	result["editor_mode"] = "source_pose"
	result["message"] = "CPR IK disabled; Quick FK can edit the male source pose."
	return result

func editor_servo_show_markers() -> void:
	_servo_controller().call("set_contact_markers_visible", true)

func editor_servo_hide_markers() -> void:
	_servo_controller().call("set_contact_markers_visible", false)

func editor_servo_status() -> Dictionary:
	var servo := _servo_controller()
	if servo == null:
		return {"ok": false}
	var status := servo.call("status") as Dictionary
	status["servo_active"] = bool(status.get("ok", false))
	status["ok"] = true
	status["playing"] = _servo_playing
	status["servo_mode"] = _servo_mode
	status["source_pose_prepared"] = _servo_pose_prepared
	status["editor_mode"] = "playing" if _servo_playing else ("marker_edit" if _servo_mode else "source_pose")
	return status

func _cpr_players() -> Array[AnimationPlayer]:
	var result: Array[AnimationPlayer] = []
	for path in ["MaleCPRAnimationPlayer", "Female190CPRAnimationPlayer"]:
		var player := get_node_or_null(path) as AnimationPlayer
		if player != null:
			result.append(player)
	return result

func _cpr_length() -> float:
	var players := _cpr_players()
	if players.size() != 2 or not players[0].has_animation(MALE_CPR_ANIMATION) or not players[1].has_animation(FEMALE_CPR_ANIMATION):
		return 0.0
	var male_length := players[0].get_animation(MALE_CPR_ANIMATION).length
	var female_length := players[1].get_animation(FEMALE_CPR_ANIMATION).length
	return male_length if absf(male_length - female_length) < 1.0 / 30.0 else 0.0

func _sample_cpr() -> void:
	var players := _cpr_players()
	for index in players.size():
		var player := players[index]
		var clip := MALE_CPR_ANIMATION if index == 0 else FEMALE_CPR_ANIMATION
		if not player.has_animation(clip):
			continue
		if player.assigned_animation != clip:
			player.assigned_animation = clip
		player.seek(_cpr_time, true)

func _advance_cpr(delta: float) -> void:
	_cpr_time = minf(_cpr_time + maxf(0.0, delta), _cpr_length())
	_sample_cpr()
	if _cpr_time >= _cpr_length():
		_cpr_playing = false

func editor_cpr_play() -> Dictionary:
	if _servo_mode:
		_servo_controller().call("stop_and_restore")
		_servo_mode = false
		_servo_playing = false
		_cpr_time = 0.0
	if _cpr_players().size() != 2 or _cpr_length() <= 0.0:
		return {"ok": false, "error": "CPR players or clip missing"}
	if not _cpr_mode:
		_cpr_rest_transforms.clear()
		_cpr_rest_bones.clear()
		for path in ["MaleCarrier/Character", "Female190/IK_character", "MaleCarrier/Character/Skeleton3D", "Female190/IK_character/Skeleton3D"]:
			var actor := get_node_or_null(path) as Node3D
			if actor != null:
				_cpr_rest_transforms[path] = actor.transform
			if actor is Skeleton3D:
				var skeleton := actor as Skeleton3D
				var bone_poses := []
				for bone_index in skeleton.get_bone_count():
					bone_poses.append([skeleton.get_bone_pose_position(bone_index), skeleton.get_bone_pose_rotation(bone_index), skeleton.get_bone_pose_scale(bone_index)])
				_cpr_rest_bones[path] = bone_poses
		_cpr_time = 0.0
		var female_controller := get_node_or_null("Female190/WalkController")
		if female_controller != null and female_controller.has_method("editor_transport_status"):
			_female190_previous_motion_source = str((female_controller.call("editor_transport_status") as Dictionary).get("motion_source", "walk_cycle"))
		if female_controller != null and female_controller.has_method("editor_transport_set_external_pose"):
			female_controller.call("editor_transport_set_external_pose")
		for controller in _controllers():
			if controller.has_method("editor_transport_pause"):
				controller.call("editor_transport_pause")
		_cpr_mode = true
	if _cpr_time >= _cpr_length():
		_cpr_time = 0.0
	_cpr_playing = true
	_sample_cpr()
	return editor_cpr_status()

func editor_cpr_pause() -> Dictionary:
	_cpr_playing = false
	return editor_cpr_status()

func editor_cpr_restart() -> Dictionary:
	var started := editor_cpr_play()
	if not bool(started.get("ok", false)):
		return started
	_cpr_time = 0.0
	_sample_cpr()
	return editor_cpr_status()

func editor_cpr_seek(seconds: float) -> Dictionary:
	if not _cpr_mode:
		var started := editor_cpr_play()
		if not bool(started.get("ok", false)):
			return started
	_cpr_playing = false
	_cpr_time = clampf(seconds, 0.0, _cpr_length())
	_sample_cpr()
	return editor_cpr_status()

func editor_cpr_status() -> Dictionary:
	return {"ok": _cpr_players().size() == 2, "playing": _cpr_playing, "time": _cpr_time, "length": _cpr_length()}

func _controllers() -> Array[Node]:
	var result: Array[Node] = []
	for path in controller_paths:
		var controller := get_node_or_null(path)
		if controller != null:
			result.append(controller)
	return result

func editor_transport_play() -> Dictionary:
	_female181_sleep_playing = false
	if _servo_mode:
		_servo_controller().call("stop_and_restore")
		_servo_mode = false
		_servo_playing = false
	if _cpr_mode:
		_cpr_mode = false
		_cpr_playing = false
		for path in _cpr_rest_transforms:
			var actor := get_node_or_null(str(path)) as Node3D
			if actor != null:
				actor.transform = _cpr_rest_transforms[path] as Transform3D
			if actor is Skeleton3D and _cpr_rest_bones.has(path):
				var skeleton := actor as Skeleton3D
				var bone_poses := _cpr_rest_bones[path] as Array
				for bone_index in mini(skeleton.get_bone_count(), bone_poses.size()):
					var pose := bone_poses[bone_index] as Array
					skeleton.set_bone_pose_position(bone_index, pose[0] as Vector3)
					skeleton.set_bone_pose_rotation(bone_index, pose[1] as Quaternion)
					skeleton.set_bone_pose_scale(bone_index, pose[2] as Vector3)
		_cpr_rest_transforms.clear()
		_cpr_rest_bones.clear()
		var female_controller := get_node_or_null("Female190/WalkController")
		if female_controller != null and female_controller.has_method("editor_transport_set_motion_source"):
			female_controller.call("editor_transport_set_motion_source", _female190_previous_motion_source)
	var count := 0
	for controller in _controllers():
		if controller.has_method("editor_transport_play"):
			controller.call("editor_transport_play")
			count += 1
	return {"ok": count > 0, "controllers": count, "playing": true}

func editor_transport_pause() -> Dictionary:
	var count := 0
	for controller in _controllers():
		if controller.has_method("editor_transport_pause"):
			controller.call("editor_transport_pause")
			count += 1
	return {"ok": count > 0, "controllers": count, "playing": false}

func editor_transport_restart() -> Dictionary:
	var count := 0
	for controller in _controllers():
		if controller.has_method("editor_transport_restart"):
			controller.call("editor_transport_restart")
			count += 1
	return {"ok": count > 0, "controllers": count, "restarted": true}

func editor_transport_status() -> Dictionary:
	var statuses: Array[Dictionary] = []
	for controller in _controllers():
		if controller.has_method("editor_transport_status"):
			statuses.append(controller.call("editor_transport_status") as Dictionary)
	return {"ok": not statuses.is_empty(), "controllers": statuses}

func editor_capture_begin_fixed_step(options: Dictionary = {}) -> Dictionary:
	if _servo_mode:
		_capture_fixed_step_active = true
		_capture_resume_playing = _servo_playing
		return {"ok": true, "controllers": 2, "was_playing": _servo_playing, "motion_source": "cpr_servo"}
	if _cpr_mode:
		_capture_fixed_step_active = true
		_capture_resume_playing = _cpr_playing
		return {"ok": true, "controllers": 2, "was_playing": _cpr_playing, "motion_source": "cpr"}
	var was_playing := false
	var count := 0
	for controller in _controllers():
		if not controller.has_method("editor_capture_begin_fixed_step"):
			continue
		var state := controller.call("editor_capture_begin_fixed_step", options) as Dictionary
		was_playing = was_playing or bool(state.get("was_playing", false))
		count += 1
	_capture_fixed_step_active = true
	_capture_resume_playing = was_playing
	return {"ok": count > 0, "controllers": count, "was_playing": was_playing}

func editor_capture_step_fixed(delta_seconds: float) -> Dictionary:
	if not _capture_fixed_step_active:
		return editor_transport_status()
	if _servo_mode:
		if _servo_playing:
			var status := _servo_controller().call("advance", delta_seconds) as Dictionary
			if float(status.get("time", 0.0)) >= float(status.get("length", 9.0)):
				_servo_playing = false
		return editor_servo_status()
	if _cpr_mode:
		if _cpr_playing:
			_advance_cpr(delta_seconds)
		return editor_cpr_status()
	for controller in _controllers():
		if controller.has_method("editor_capture_step_fixed"):
			controller.call("editor_capture_step_fixed", delta_seconds)
	return editor_transport_status()

func editor_capture_end_fixed_step(was_playing: bool) -> Dictionary:
	if _servo_mode:
		_capture_fixed_step_active = false
		_capture_resume_playing = false
		return editor_servo_status()
	if _cpr_mode:
		_capture_fixed_step_active = false
		_capture_resume_playing = false
		return editor_cpr_status()
	var should_resume := _capture_resume_playing or was_playing
	for controller in _controllers():
		if controller.has_method("editor_capture_end_fixed_step"):
			controller.call("editor_capture_end_fixed_step", should_resume)
	_capture_fixed_step_active = false
	_capture_resume_playing = false
	return editor_transport_status()
