@tool
extends Node

## Deterministic, nine-second CPR reference layer. The separate Mixamo CPR
## clips supply only the authored starting pose. A single compression clock
## drives the rescuer's stacked-hand targets; the receiver follows that clock
## with small, independently delayed skeletal responses. No ventilation.

@export_category("CPR Timing")
@export_range(80.0, 130.0, 1.0, "suffix:/min") var compressions_per_minute := 108.0
@export_range(0.0, 1.0, 0.01, "suffix:s") var start_delay_seconds := 0.2
@export_range(0.1, 20.0, 0.1, "suffix:s") var shot_duration_seconds := 9.0
@export_range(0, 40, 1) var compression_limit := 0
@export_range(0.35, 0.65, 0.01) var downstroke_fraction := 0.48
@export_range(0.0, 0.2, 0.01) var bottom_hold_fraction := 0.02

@export_category("Primary Compression")
## Adult CPR reference range: 5–6 cm at 100–120 compressions/minute. This
## moves the wrist targets by the measured depth; the proxy torso receives a
## smaller deformation so its rigid skin does not look crushed.
@export_range(0.0, 0.08, 0.001, "suffix:m") var press_depth_m := 0.052
@export var press_axis_world := Vector3.DOWN
@export_range(0.0, 1.0, 0.01) var left_hand_ik_influence := 1.0
@export_range(0.0, 1.0, 0.01) var right_hand_ik_influence := 1.0
@export_range(0.0, 1.0, 0.01) var left_hand_orientation_influence := 1.0
@export_range(0.0, 1.0, 0.01) var right_hand_orientation_influence := 1.0
@export var prevent_hand_chest_penetration := true
@export_range(0.0, 0.05, 0.001, "suffix:m") var hand_surface_clearance_m := 0.012
@export_range(0.0, 0.08, 0.001, "suffix:m") var max_hand_surface_depression_m := 0.012
@export_range(0.0, 0.06, 0.001, "suffix:m") var male_spine_drop_m := 0.012
@export_range(0.0, 0.06, 0.001, "suffix:m") var male_chest_drop_m := 0.018
@export_range(0.0, 0.04, 0.001, "suffix:m") var male_upper_chest_drop_m := 0.005

@export_category("Receiver Compression and Lag")
@export_range(0.0, 1.0, 0.01) var receiver_sternum_follow := 0.68
@export_range(0.0, 10.0, 0.01, "suffix:m") var floor_plane_world_y := 0.0
@export_range(0.0, 0.02, 0.001, "suffix:m") var receiver_floor_clearance_m := 0.002
@export var receiver_floor_constraint_enabled := true
@export_range(0.0, 0.2, 0.005, "suffix:s") var chest_lag_seconds := 0.025
@export_range(0.0, 0.3, 0.005, "suffix:s") var abdomen_lag_seconds := 0.060
@export_range(0.0, 0.3, 0.005, "suffix:s") var neck_lag_seconds := 0.075
@export_range(0.0, 0.4, 0.005, "suffix:s") var head_lag_seconds := 0.110
@export_range(0.0, 0.5, 0.005, "suffix:s") var arm_lag_seconds := 0.140
@export_range(0.0, 0.5, 0.005, "suffix:s") var leg_lag_seconds := 0.170
@export_range(0.0, 0.6, 0.005, "suffix:s") var hair_lag_seconds := 0.210
@export_range(0.0, 0.015, 0.0005, "suffix:m") var abdomen_response_m := 0.004
@export_range(0.0, 8.0, 0.1, "degrees") var neck_nod_degrees := 1.5
@export_range(0.0, 10.0, 0.1, "degrees") var head_nod_degrees := 2.0
@export_range(0.0, 12.0, 0.1, "degrees") var arm_recoil_degrees := 2.0
@export_range(0.0, 8.0, 0.1, "degrees") var leg_recoil_degrees := 0.8
@export_range(0.0, 20.0, 0.1, "degrees") var ponytail_root_swing_degrees := 3.0
@export_range(0.0, 25.0, 0.1, "degrees") var ponytail_tip_swing_degrees := 5.0

@export_category("Receiver Soft Tissue")
## These six controls are deforming bones in the CPR-only 62-bone GLB. They
## inherit the chest pose, then add a much smaller delayed tissue response.
@export_range(0.0, 0.3, 0.005, "suffix:s") var breast_upper_lag_seconds := 0.060
@export_range(0.0, 0.3, 0.005, "suffix:s") var breast_lower_lag_seconds := 0.095
@export_range(0.0, 0.3, 0.005, "suffix:s") var abdomen_upper_lag_seconds := 0.085
@export_range(0.0, 0.3, 0.005, "suffix:s") var abdomen_lower_lag_seconds := 0.135
@export_range(0.0, 0.03, 0.0005, "suffix:m") var breast_upper_settle_m := 0.012
@export_range(0.0, 0.03, 0.0005, "suffix:m") var breast_lower_settle_m := 0.020
@export_range(0.0, 0.02, 0.0005, "suffix:m") var breast_lateral_spread_m := 0.005
@export_range(0.0, 0.025, 0.0005, "suffix:m") var upper_abdomen_inflate_m := 0.006
@export_range(0.0, 0.025, 0.0005, "suffix:m") var lower_abdomen_inflate_m := 0.003

@export_category("Contact Calibration")
@export var male_skeleton_path := NodePath("../MaleCarrier/Character/Skeleton3D")
@export var female_skeleton_path := NodePath("../Female190/IK_character/Skeleton3D")
@export var left_target_path := NodePath("../CPRServoAnchors/LeftPalmTarget")
@export var right_target_path := NodePath("../CPRServoAnchors/RightPalmTarget")
@export var left_pole_path := NodePath("../CPRServoAnchors/LeftElbowPole")
@export var right_pole_path := NodePath("../CPRServoAnchors/RightElbowPole")
@export var left_ik_path := NodePath("../MaleCarrier/Character/Skeleton3D/cpr_left_arm_ik")
@export var right_ik_path := NodePath("../MaleCarrier/Character/Skeleton3D/cpr_right_arm_ik")
@export var left_orientation_path := NodePath("../MaleCarrier/Character/Skeleton3D/cpr_left_hand_orientation")
@export var right_orientation_path := NodePath("../MaleCarrier/Character/Skeleton3D/cpr_right_hand_orientation")
@export_storage var contact_calibrated := false
@export_storage var left_wrist_in_chest := Transform3D.IDENTITY
@export_storage var right_wrist_in_chest := Transform3D.IDENTITY
@export_storage var female_pose_calibrated := false

var _baseline_male: Array = []
var _baseline_female: Array = []
var _baseline_left_hand_world := Vector3.ZERO
var _baseline_right_hand_world := Vector3.ZERO
var _baseline_sternum_world := Vector3.ZERO
var _solved_left_hand_world := Vector3.ZERO
var _solved_right_hand_world := Vector3.ZERO
var _solved_left_hand_orientation := Quaternion.IDENTITY
var _solved_right_hand_orientation := Quaternion.IDENTITY
var _captured_marker_hand_left := Vector3.ZERO
var _captured_marker_hand_right := Vector3.ZERO
var _captured_marker_hand_pose_valid := false
var _active := false
var _time := 0.0

func _ready() -> void:
	# Targets are written before the male's modifier stack evaluates. Explicit
	# fixed-step capture also advances the male skeleton after target placement.
	var male := _male()
	if male != null:
		male.process_priority = process_priority + 1
	var last_modifier := get_node_or_null(right_orientation_path) as SkeletonModifier3D
	if last_modifier == null:
		last_modifier = get_node_or_null(right_ik_path) as SkeletonModifier3D
	if last_modifier != null and not last_modifier.modification_processed.is_connected(_capture_solved_hands):
		last_modifier.modification_processed.connect(_capture_solved_hands)
	_set_ik_enabled(false)

func begin_from_current_cpr_pose() -> Dictionary:
	var male := _male()
	var female := _female()
	if male == null or female == null or male.find_bone("LeftHand") < 0 or female.find_bone("UpperChest") < 0:
		return {"ok": false, "error": "CPR skeleton or required contact bone missing"}
	_baseline_male = _capture_pose(male)
	_baseline_female = _capture_pose(female)
	_baseline_left_hand_world = _bone_world(male, "LeftHand").origin
	_baseline_right_hand_world = _bone_world(male, "RightHand").origin
	_baseline_sternum_world = _bone_world(female, "UpperChest").origin
	_solved_left_hand_world = _baseline_left_hand_world
	_solved_right_hand_world = _baseline_right_hand_world
	if not contact_calibrated:
		calibrate_contact_from_current_pose()
	_active = true
	_time = 0.0
	_set_ik_enabled(true)
	_apply_at_time(0.0, 1.0 / 120.0)
	return status()

func calibrate_contact_from_current_pose() -> Dictionary:
	var male := _male()
	var female := _female()
	var left := get_node_or_null(left_target_path) as Marker3D
	var right := get_node_or_null(right_target_path) as Marker3D
	var left_pole := get_node_or_null(left_pole_path) as Marker3D
	var right_pole := get_node_or_null(right_pole_path) as Marker3D
	if male == null or female == null or left == null or right == null or left_pole == null or right_pole == null:
		return {"ok": false, "error": "CPR contact nodes missing"}
	var chest := _bone_world(female, "UpperChest")
	left_wrist_in_chest = chest.affine_inverse() * _bone_world(male, "LeftHand")
	right_wrist_in_chest = chest.affine_inverse() * _bone_world(male, "RightHand")
	left.global_transform = chest * left_wrist_in_chest
	right.global_transform = chest * right_wrist_in_chest
	left_pole.global_transform = _bone_world(male, "LeftLowerArm")
	right_pole.global_transform = _bone_world(male, "RightLowerArm")
	contact_calibrated = true
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()
	return {"ok": true, "left_wrist": left.global_position, "right_wrist": right.global_position}

func capture_current_markers_as_contact() -> Dictionary:
	# Move the visible palm markers where the rescuer's wrists should land,
	# then capture them relative to the woman's current upper chest. This is
	# the interactive correction when automatic wrist calibration looks off.
	var male := _male()
	var female := _female()
	var left := get_node_or_null(left_target_path) as Marker3D
	var right := get_node_or_null(right_target_path) as Marker3D
	if male == null or female == null or left == null or right == null:
		return {"ok": false, "error": "CPR chest or palm markers missing"}
	var chest := _bone_world(female, "UpperChest")
	left_wrist_in_chest = chest.affine_inverse() * left.global_transform
	right_wrist_in_chest = chest.affine_inverse() * right.global_transform
	contact_calibrated = true
	# Marker capture is also a calibration boundary. If IK was enabled from the
	# editor but the servo clock was not started yet, preserve the currently
	# visible CPR pose as the zero-time baseline. Otherwise Play would first
	# seek the baked CPR clip and replace the hand placement the user just set.
	if not _active:
		_baseline_male = _capture_pose(male)
		_baseline_female = _capture_pose(female)
		_baseline_left_hand_world = _bone_world(male, "LeftHand").origin
		_baseline_right_hand_world = _bone_world(male, "RightHand").origin
		_baseline_sternum_world = chest.origin
		_solved_left_hand_world = _baseline_left_hand_world
		_solved_right_hand_world = _baseline_right_hand_world
		_active = true
		_time = 0.0
		_set_ik_enabled(true)
	# The marker edit is an authored CPR zero pose. Re-evaluate the IK stack
	# immediately and remember the resulting wrists so starting playback cannot
	# restore an older pre-marker hand placement. The regular per-frame restore
	# still uses the original FK source pose; the markers remain the authority
	# for the evaluated hands.
	_captured_marker_hand_left = left.global_position
	_captured_marker_hand_right = right.global_position
	_captured_marker_hand_pose_valid = true
	_apply_at_time(_time, 1.0 / 120.0)
	_captured_marker_hand_left = _solved_left_hand_world
	_captured_marker_hand_right = _solved_right_hand_world
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()
	return {"ok": true, "left_target": left.global_position, "right_target": right.global_position,
		"zero_left_hand": _captured_marker_hand_left, "zero_right_hand": _captured_marker_hand_right}

func capture_current_female_pose() -> Dictionary:
	"""Capture the receiver's currently visible FK pose as the CPR baseline.

	This intentionally does not sample Female190CPRAnimationPlayer. It is used
	after editing the female Skeleton3D so starting the servo cannot restore the
	baked receiving pose. Existing palm markers are re-expressed relative to the
	new UpperChest position, preserving their visible world placement.
	"""
	var male := _male()
	var female := _female()
	var left := get_node_or_null(left_target_path) as Marker3D
	var right := get_node_or_null(right_target_path) as Marker3D
	if male == null or female == null or left == null or right == null:
		return {"ok": false, "error": "CPR skeleton or palm markers missing"}
	if not _active:
		_baseline_male = _capture_pose(male)
		_baseline_left_hand_world = _bone_world(male, "LeftHand").origin
		_baseline_right_hand_world = _bone_world(male, "RightHand").origin
	_baseline_female = _capture_pose(female)
	var chest := _bone_world(female, "UpperChest")
	_baseline_sternum_world = chest.origin
	left_wrist_in_chest = chest.affine_inverse() * left.global_transform
	right_wrist_in_chest = chest.affine_inverse() * right.global_transform
	female_pose_calibrated = true
	contact_calibrated = true
	_active = true
	_time = 0.0
	_apply_at_time(0.0, 1.0 / 120.0)
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()
	return {"ok": true, "female_pose_calibrated": true,
		"upper_chest": chest.origin, "next_step": "Enable CPR IK / edit markers, then capture markers if needed."}

func set_contact_markers_visible(enabled: bool) -> void:
	for path in [left_target_path, right_target_path, left_pole_path, right_pole_path]:
		var marker := get_node_or_null(path) as Marker3D
		if marker != null:
			marker.visible = enabled

func seek(seconds: float) -> Dictionary:
	if not _active:
		return {"ok": false, "error": "CPR servo baseline has not been captured"}
	_time = clampf(seconds, 0.0, shot_duration_seconds)
	_apply_at_time(_time, 1.0 / 120.0)
	return status()

func advance(delta_seconds: float) -> Dictionary:
	return seek(_time + maxf(0.0, delta_seconds))

func stop_and_restore() -> void:
	if _active:
		_restore_pose(_male(), _baseline_male)
		_restore_pose(_female(), _baseline_female)
	_active = false
	_set_ik_enabled(false)

func stop_without_restoring_source_pose() -> void:
	# Quick FK may have changed the live male pose while a previous servo
	# baseline was active. Never restore that stale baseline before capturing
	# the newly authored wrists as CPR contacts.
	_active = false
	_set_ik_enabled(false)

func status() -> Dictionary:
	var report := {"ok": _active, "time": _time, "length": shot_duration_seconds,
		"press_index": _press_index(_time), "press_fraction": _press_fraction(_time),
		"press_depth_m": press_depth_m * _press_fraction(_time), "playing": false}
	var left_ik := get_node_or_null(left_ik_path) as SkeletonModifier3D
	var right_ik := get_node_or_null(right_ik_path) as SkeletonModifier3D
	var left_target := get_node_or_null(left_target_path) as Marker3D
	var right_target := get_node_or_null(right_target_path) as Marker3D
	report["ik_enabled"] = left_ik != null and right_ik != null and left_ik.active and right_ik.active and left_ik.influence > 0.0 and right_ik.influence > 0.0
	report["markers_visible"] = left_target != null and right_target != null and left_target.visible and right_target.visible
	report["contact_calibrated"] = contact_calibrated
	if _active:
		var male := _male()
		var female := _female()
		var axis := press_axis_world.normalized() if press_axis_world.length_squared() > 0.001 else Vector3.DOWN
		var left := left_target
		var right := right_target
		if male != null and female != null and left != null and right != null:
			report["minimum_receiver_torso_bone_y"] = _minimum_receiver_torso_bone_y(female)
			report["receiver_floor_clearance_m"] = _minimum_receiver_torso_bone_y(female) - floor_plane_world_y
			report["receiver_floor_constraint_enabled"] = receiver_floor_constraint_enabled
			report["measured_left_wrist_travel_m"] = (_solved_left_hand_world - _baseline_left_hand_world).dot(axis)
			report["measured_right_wrist_travel_m"] = (_solved_right_hand_world - _baseline_right_hand_world).dot(axis)
			report["measured_sternum_travel_m"] = (_bone_world(female, "UpperChest").origin - _baseline_sternum_world).dot(axis)
			report["left_contact_error_m"] = _solved_left_hand_world.distance_to(left.global_position)
			report["right_contact_error_m"] = _solved_right_hand_world.distance_to(right.global_position)
			report["captured_zero_hand_pose"] = _captured_marker_hand_pose_valid
			report["zero_left_hand_error_m"] = _solved_left_hand_world.distance_to(_captured_marker_hand_left) if _captured_marker_hand_pose_valid else 0.0
			report["zero_right_hand_error_m"] = _solved_right_hand_world.distance_to(_captured_marker_hand_right) if _captured_marker_hand_pose_valid else 0.0
			report["left_hand_orientation_error_degrees"] = rad_to_deg(_solved_left_hand_orientation.angle_to(left.global_transform.basis.get_rotation_quaternion()))
			report["right_hand_orientation_error_degrees"] = rad_to_deg(_solved_right_hand_orientation.angle_to(right.global_transform.basis.get_rotation_quaternion()))
	return report

func _apply_at_time(seconds: float, step: float) -> void:
	var male := _male()
	var female := _female()
	if male == null or female == null:
		return
	_restore_pose(male, _baseline_male)
	_restore_pose(female, _baseline_female)
	var axis := press_axis_world.normalized() if press_axis_world.length_squared() > 0.001 else Vector3.DOWN
	var primary := _press_fraction(seconds)
	var depth := press_depth_m * primary
	# Knees and hips stay planted. A smaller shoulder drop adds visible body
	# weight transfer, while the hand targets prescribe the full stroke depth.
	_add_world_translation(male, "Spine", axis * male_spine_drop_m * primary)
	_add_world_translation(male, "Chest", axis * male_chest_drop_m * primary)
	_add_world_translation(male, "UpperChest", axis * male_upper_chest_drop_m * primary)
	var torso_amount := _press_fraction(seconds - chest_lag_seconds)
	var sternum_depth := press_depth_m * receiver_sternum_follow * torso_amount
	# The source pose lies almost against the room floor. Treat the chest skeleton
	# as a supported rib cage: only its measured clearance may translate down.
	# The remaining visual stroke is represented by localized weighted controls.
	_add_receiver_world_translation(female, "Spine", axis * abdomen_response_m * _press_fraction(seconds - abdomen_lag_seconds))
	_add_receiver_world_translation(female, "Chest", axis * sternum_depth * 0.30)
	_add_receiver_world_translation(female, "UpperChest", axis * sternum_depth * 0.70)
	var lateral_axis := (_bone_world(female, "LeftShoulder").origin - _bone_world(female, "RightShoulder").origin).normalized()
	if lateral_axis.length_squared() > 0.1:
		var breast_upper := _press_fraction(seconds - breast_upper_lag_seconds)
		var breast_lower := _press_fraction(seconds - breast_lower_lag_seconds)
		_add_receiver_world_translation(female, "CPR_LeftBreastUpper", (axis * breast_upper_settle_m + lateral_axis * breast_lateral_spread_m) * breast_upper)
		_add_receiver_world_translation(female, "CPR_RightBreastUpper", (axis * breast_upper_settle_m - lateral_axis * breast_lateral_spread_m) * breast_upper)
		_add_receiver_world_translation(female, "CPR_LeftBreastLower", (axis * breast_lower_settle_m + lateral_axis * breast_lateral_spread_m * 1.25) * breast_lower)
		_add_receiver_world_translation(female, "CPR_RightBreastLower", (axis * breast_lower_settle_m - lateral_axis * breast_lateral_spread_m * 1.25) * breast_lower)
	# The upper abdomen rises slightly as the sternum descends. This is a
	# visual proxy for tissue displacement, not a ventilation/breath cycle.
	_add_receiver_world_translation(female, "CPR_UpperAbdomen", -axis * upper_abdomen_inflate_m * _press_fraction(seconds - abdomen_upper_lag_seconds))
	_add_receiver_world_translation(female, "CPR_LowerAbdomen", -axis * lower_abdomen_inflate_m * _press_fraction(seconds - abdomen_lower_lag_seconds))
	# Sagittal nod is around the receiver's shoulder line, not a guessed local
	# bone axis. Response is deliberately much weaker than the primary stroke.
	var shoulder_axis := (_bone_world(female, "RightShoulder").origin - _bone_world(female, "LeftShoulder").origin).normalized()
	if shoulder_axis.length_squared() > 0.1:
		_add_world_rotation(female, "Neck", shoulder_axis, deg_to_rad(neck_nod_degrees) * _press_fraction(seconds - neck_lag_seconds))
		_add_world_rotation(female, "Head", shoulder_axis, deg_to_rad(head_nod_degrees) * _press_fraction(seconds - head_lag_seconds))
		var arms := _press_fraction(seconds - arm_lag_seconds)
		_add_world_rotation(female, "LeftUpperArm", shoulder_axis, deg_to_rad(arm_recoil_degrees) * arms)
		_add_world_rotation(female, "RightUpperArm", shoulder_axis, -deg_to_rad(arm_recoil_degrees) * arms)
		var legs := _press_fraction(seconds - leg_lag_seconds)
		_add_world_rotation(female, "LeftUpperLeg", shoulder_axis, deg_to_rad(leg_recoil_degrees) * legs)
		_add_world_rotation(female, "RightUpperLeg", shoulder_axis, -deg_to_rad(leg_recoil_degrees) * legs)
		_add_world_rotation(female, "Ponytail_Bone1", shoulder_axis, -deg_to_rad(ponytail_root_swing_degrees) * _press_fraction(seconds - hair_lag_seconds))
		_add_world_rotation(female, "Ponytail_Bone2", shoulder_axis, -deg_to_rad(ponytail_tip_swing_degrees) * _press_fraction(seconds - hair_lag_seconds - 0.045))
	female.force_update_all_bone_transforms()
	var chest := _bone_world(female, "UpperChest")
	var actual_sternum_follow := (chest.origin - _baseline_sternum_world).dot(axis)
	var remaining_stroke := depth - actual_sternum_follow
	if prevent_hand_chest_penetration:
		remaining_stroke = minf(remaining_stroke, max_hand_surface_depression_m)
	var left := get_node_or_null(left_target_path) as Marker3D
	var right := get_node_or_null(right_target_path) as Marker3D
	if left != null:
		left.global_transform = _safe_palm_target(chest * left_wrist_in_chest, chest, axis * remaining_stroke)
	if right != null:
		right.global_transform = _safe_palm_target(chest * right_wrist_in_chest, chest, axis * remaining_stroke)
	_set_ik_enabled(true)
	# A zero delta may skip Godot 4.7's SkeletonModifier3D stack. Evaluate the
	# IK now for deterministic editor seeks and off-screen OTS Render capture.
	male.advance(maxf(step, 1.0 / 120.0))
	male.force_update_all_bone_transforms()

func _safe_palm_target(base_target: Transform3D, chest: Transform3D, stroke: Vector3) -> Transform3D:
	var target := base_target
	target.origin += stroke
	if not prevent_hand_chest_penetration:
		return target
	var axis := press_axis_world.normalized() if press_axis_world.length_squared() > 0.001 else Vector3.DOWN
	# Use the calibrated marker offsets to estimate the receiver's outward chest
	# normal. This remains correct when the female is rotated or posed; using
	# world up (or simply -press_axis) caused valid contacts to be classified as
	# penetration in non-supine staging. The guard is a proxy-level half-space,
	# not mesh collision: it only prevents a target from crossing inward.
	var local_normal := (left_wrist_in_chest.origin + right_wrist_in_chest.origin) * 0.5
	var surface_normal := (chest.basis * local_normal).normalized()
	if surface_normal.length_squared() < 0.001:
		surface_normal = -axis
	var outward_distance := (target.origin - chest.origin).dot(surface_normal)
	if outward_distance < hand_surface_clearance_m:
		target.origin += surface_normal * (hand_surface_clearance_m - outward_distance)
	return target

func _press_index(seconds: float) -> int:
	if seconds < start_delay_seconds:
		return -1
	var period := 60.0 / maxf(1.0, compressions_per_minute)
	return int(floor((seconds - start_delay_seconds) / period))

func _press_fraction(seconds: float) -> float:
	if seconds < start_delay_seconds or seconds >= shot_duration_seconds:
		return 0.0
	var period := 60.0 / maxf(1.0, compressions_per_minute)
	var index := _press_index(seconds)
	if compression_limit > 0 and index >= compression_limit:
		return 0.0
	var phase := fposmod(seconds - start_delay_seconds, period) / period
	var down_end := clampf(downstroke_fraction, 0.1, 0.8)
	var hold_end := minf(0.9, down_end + bottom_hold_fraction)
	if phase < down_end:
		return 0.5 - 0.5 * cos(PI * phase / down_end)
	if phase < hold_end:
		return 1.0
	var release := (phase - hold_end) / maxf(0.001, 1.0 - hold_end)
	return 0.5 + 0.5 * cos(PI * release)

func _capture_pose(skeleton: Skeleton3D) -> Array:
	var result := []
	for bone_index in skeleton.get_bone_count():
		result.append([skeleton.get_bone_pose_position(bone_index), skeleton.get_bone_pose_rotation(bone_index), skeleton.get_bone_pose_scale(bone_index)])
	return result

func _restore_pose(skeleton: Skeleton3D, baseline: Array) -> void:
	if skeleton == null:
		return
	for bone_index in mini(skeleton.get_bone_count(), baseline.size()):
		var pose := baseline[bone_index] as Array
		skeleton.set_bone_pose_position(bone_index, pose[0] as Vector3)
		skeleton.set_bone_pose_rotation(bone_index, pose[1] as Quaternion)
		skeleton.set_bone_pose_scale(bone_index, pose[2] as Vector3)
	skeleton.force_update_all_bone_transforms()

func _add_world_translation(skeleton: Skeleton3D, bone_name: String, world_delta: Vector3) -> void:
	var index := skeleton.find_bone(bone_name)
	if index < 0 or world_delta.length_squared() < 1e-12:
		return
	var parent := skeleton.get_bone_parent(index)
	var parent_basis := skeleton.global_transform.basis
	if parent >= 0:
		parent_basis = parent_basis * skeleton.get_bone_global_pose(parent).basis
	skeleton.set_bone_pose_position(index, skeleton.get_bone_pose_position(index) + parent_basis.inverse() * world_delta)
	skeleton.force_update_all_bone_transforms()

func _add_receiver_world_translation(skeleton: Skeleton3D, bone_name: String, world_delta: Vector3) -> void:
	if not receiver_floor_constraint_enabled or world_delta.y >= 0.0:
		_add_world_translation(skeleton, bone_name, world_delta)
		return
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index < 0:
		return
	# A parent-bone translation moves every descendant. Clamp against the lowest
	# descendant bone origin, not just the named joint, so the back/rib cage
	# cannot be pushed through the floor as a connected rigid section.
	var lowest_y := _minimum_bone_subtree_world_y(skeleton, bone_index)
	var allowed_drop := maxf(0.0, lowest_y - floor_plane_world_y - receiver_floor_clearance_m)
	var clamped_delta := world_delta
	clamped_delta.y = maxf(world_delta.y, -allowed_drop)
	_add_world_translation(skeleton, bone_name, clamped_delta)

func _minimum_bone_subtree_world_y(skeleton: Skeleton3D, root_bone: int) -> float:
	var minimum_y := INF
	for bone_index in skeleton.get_bone_count():
		var ancestor := bone_index
		while ancestor >= 0 and ancestor != root_bone:
			ancestor = skeleton.get_bone_parent(ancestor)
		if ancestor != root_bone:
			continue
		var world_position := skeleton.to_global(skeleton.get_bone_global_pose(bone_index).origin)
		minimum_y = minf(minimum_y, world_position.y)
	return minimum_y

func _minimum_receiver_torso_bone_y(skeleton: Skeleton3D) -> float:
	var minimum_y := INF
	for bone_name in [
		"Hips", "Spine", "Chest", "UpperChest",
		"CPR_LeftBreastUpper", "CPR_LeftBreastLower",
		"CPR_RightBreastUpper", "CPR_RightBreastLower",
		"CPR_UpperAbdomen", "CPR_LowerAbdomen",
	]:
		var bone_index := skeleton.find_bone(bone_name)
		if bone_index < 0:
			continue
		var world_position := skeleton.to_global(skeleton.get_bone_global_pose(bone_index).origin)
		minimum_y = minf(minimum_y, world_position.y)
	return minimum_y

func _add_world_rotation(skeleton: Skeleton3D, bone_name: String, world_axis: Vector3, angle: float) -> void:
	var index := skeleton.find_bone(bone_name)
	if index < 0 or absf(angle) < 1e-7:
		return
	var parent := skeleton.get_bone_parent(index)
	var frame_basis := skeleton.global_transform.basis
	if parent >= 0:
		frame_basis = frame_basis * skeleton.get_bone_global_pose(parent).basis
	frame_basis = frame_basis * skeleton.get_bone_rest(index).basis
	var local_axis := (frame_basis.inverse() * world_axis).normalized()
	var base_rotation := skeleton.get_bone_pose_rotation(index)
	skeleton.set_bone_pose_rotation(index, (Quaternion(local_axis, angle) * base_rotation).normalized())
	skeleton.force_update_all_bone_transforms()

func _bone_world(skeleton: Skeleton3D, bone_name: String) -> Transform3D:
	var index := skeleton.find_bone(bone_name)
	return skeleton.global_transform * skeleton.get_bone_global_pose(index) if index >= 0 else skeleton.global_transform

func _set_ik_enabled(enabled: bool) -> void:
	var left := get_node_or_null(left_ik_path) as SkeletonModifier3D
	var right := get_node_or_null(right_ik_path) as SkeletonModifier3D
	if left != null:
		left.active = enabled and left_hand_ik_influence > 0.0
		left.influence = left_hand_ik_influence if enabled else 0.0
	if right != null:
		right.active = enabled and right_hand_ik_influence > 0.0
		right.influence = right_hand_ik_influence if enabled else 0.0
	var left_orientation := get_node_or_null(left_orientation_path) as SkeletonModifier3D
	var right_orientation := get_node_or_null(right_orientation_path) as SkeletonModifier3D
	if left_orientation != null:
		left_orientation.active = enabled and left_hand_orientation_influence > 0.0
		left_orientation.influence = left_hand_orientation_influence if enabled else 0.0
	if right_orientation != null:
		right_orientation.active = enabled and right_hand_orientation_influence > 0.0
		right_orientation.influence = right_hand_orientation_influence if enabled else 0.0

func _capture_solved_hands() -> void:
	# SkeletonModifier3D exposes its evaluated pose during this signal. Outside
	# the callback, Skeleton3D.get_bone_global_pose() returns the base FK pose,
	# which falsely suggests the IK did nothing in headless tests and telemetry.
	var male := _male()
	if male == null:
		return
	var left := _bone_world(male, "LeftHand")
	var right := _bone_world(male, "RightHand")
	_solved_left_hand_world = left.origin
	_solved_right_hand_world = right.origin
	_solved_left_hand_orientation = left.basis.get_rotation_quaternion()
	_solved_right_hand_orientation = right.basis.get_rotation_quaternion()

func _male() -> Skeleton3D:
	return get_node_or_null(male_skeleton_path) as Skeleton3D

func _female() -> Skeleton3D:
	return get_node_or_null(female_skeleton_path) as Skeleton3D
