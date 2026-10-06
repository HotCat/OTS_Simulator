@tool
extends Node3D

## Procedural, render-agnostic OTS carry blocking.
##
## The carrier gait is the only captured motion. The carried character is
## solved in layers: pelvis follow, low-frequency dangle, then optional hand
## contact IK. Every layer is additive to the authored FK pose, so the scene
## remains a stable reference block for H3 rather than pretending to be a
## physically exact mocap solve.

const HIDDEN_STAGE_NODES := ["stage", "WaistSupportWall", "AsymmetricObstacleField", "WalkTrajectory"]
const MIN_REASONABLE_PELVIS_OFFSET_METERS := 0.05
const MAX_REASONABLE_PELVIS_OFFSET_METERS := 1.50

@export_category("Carrier Trajectory")
@export var carrier_trajectory_enabled := true
@export var preview_trajectory_in_editor := true
@export var restore_carrier_when_preview_stops := true
@export var carrier_root_path: NodePath = NodePath("ManualCarryBlock/MaleCarrier")
@export var carrier_trajectory_path: NodePath = NodePath("CarrierTrajectory")
## The selected node's local XZ plane is the walkable plane. Assign the street
## root when it is level, or position CarrierWalkPlane for an explicit surface.
@export var carrier_walk_plane_path: NodePath = NodePath("CarrierWalkPlane")
@export_range(-2.0, 2.0, 0.001, "suffix:m") var carrier_height_above_plane := -0.007662
@export_range(0.0, 5.0, 0.01, "suffix:m/s") var carrier_walk_speed_mps := 0.78
@export var carrier_trajectory_loop := false
@export var carrier_face_trajectory := true
@export var ots_carry_animation_player_path: NodePath = NodePath("OTSCarryAnimationPlayer")
@export var ots_carry_walk_animation: StringName = &"ots_carry_walk_cycle"

## Rounds waypoint corners without changing the authored marker positions.
## 0 keeps the original straight polyline; 1 gives the largest practical
## Catmull-Rom corner radius while remaining inside the neighboring spans.
@export_range(0.0, 1.0, 0.01) var trajectory_corner_smoothing := 0.7
## A denser route polyline keeps position interpolation accurate. Heading is
## filtered separately below, so this is not the only corner-stability control.
@export_range(2, 64, 1) var trajectory_samples_per_segment := 32
## Distance along the route used to estimate a central-difference heading.
## Looking across several samples avoids the instantaneous tangent change at a
## waypoint. A ratio makes the setting scale with short and long routes alike.
@export_range(0.0, 0.25, 0.005, "suffix:route") var trajectory_heading_lookahead_ratio := 0.08
## Exponential time constant for route heading. This is deliberately separate
## from trajectory_corner_smoothing: it filters orientation without changing
## the authored path or the carrier's translation.
@export_range(0.0, 1.0, 0.01, "suffix:s") var trajectory_heading_smoothing_seconds := 0.12
## A loaded carrier should not spin around a planted foot merely because the
## route tangent changes quickly. This cap turns sharp spline curvature into a
## broad, physically readable change of heading.
@export_range(10.0, 180.0, 1.0, "degrees") var trajectory_max_yaw_rate_degrees := 65.0
## Reduce requested speed as route curvature rises. Root-motion clips keep
## their gait/translation synchronized because their playback rate is reduced
## by the same factor.
@export_range(0.0, 0.75, 0.01) var trajectory_turn_speed_reduction := 0.35
# This MakeHuman carrier faces local +Z. Using Godot's conventional -Z here
# turns the mesh 180 degrees and makes a correct forward gait travel backward.
@export var carrier_local_forward := Vector3(0.0, 0.0, 1.0)
@export_category("Carrier Foot Lock")
@export var carrier_foot_lock_enabled := true
@export var carrier_left_foot_bone: StringName = &"LeftFoot"
@export var carrier_right_foot_bone: StringName = &"RightFoot"
@export_range(0.001, 0.25, 0.001, "suffix:m") var carrier_contact_height := 0.08
## Maximum local vertical foot velocity still considered planted. Horizontal
## local motion is ignored because the root-motion stride naturally moves it.
@export_range(0.01, 3.0, 0.01, "suffix:m/s") var carrier_contact_speed := 0.35
@export_range(0.0, 1.0, 0.01) var carrier_foot_lock_strength := 0.85
@export_range(0.0, 1.0, 0.01) var carrier_foot_lock_planar_strength := 0.72
## Correct the carrier root along the walk-plane normal while a foot is
## planted. Root-motion clips can have a few centimetres of authored ankle
## clearance; horizontal locking alone then makes the character look as if he
## is wading or floating above the floor.
@export_range(0.0, 1.0, 0.01) var carrier_foot_lock_vertical_strength := 0.45
@export_range(0.01, 0.5, 0.01, "suffix:m") var carrier_foot_lock_max_planar_offset := 0.18
@export_range(0.01, 0.25, 0.01, "suffix:m") var carrier_foot_lock_max_vertical_offset := 0.08
@export_range(0.01, 1.0, 0.01, "suffix:s") var carrier_foot_lock_release_seconds := 0.16
@export_category("Carrier Root Motion")
## Travelling clips are consumed rather than applied to Skeleton3D:Root. Their
## displacement advances CarrierTrajectory, while the route still determines
## the authored street position and direction.
@export var carrier_root_motion_enabled := true
@export var carrier_root_motion_sampler_path: NodePath = NodePath("RootMotionSampler")
## Spatially shorten the normal-speed Mixamo stride for a person carrying a
## heavy passenger. Playback rate is then derived so feet and route speed stay
## synchronized instead of merely slowing one side of the system.
@export_range(0.4, 1.25, 0.01) var carrier_root_motion_stride_scale := 0.65
@export_range(0.2, 2.0, 0.01) var carrier_root_motion_min_playback_rate := 0.35
@export_range(0.2, 2.0, 0.01) var carrier_root_motion_max_playback_rate := 1.25
@export_tool_button("Restart carrier at trajectory start")
var restart_trajectory_action: Callable = restart_carrier_trajectory
@export_tool_button("Project trajectory markers onto walk plane")
var project_trajectory_action: Callable = project_trajectory_to_walk_plane

@export_category("Pelvis Follow")
@export var female_pelvis_attachment_enabled := true
@export var preview_female_attachment_in_editor := false:
	set(value):
		if preview_female_attachment_in_editor == value:
			return
		if Engine.is_editor_hint() and is_inside_tree():
			if value:
				_capture_editor_preview_baseline()
			elif not preview_procedural_motion_in_editor:
				_restore_editor_preview_baseline()
		preview_female_attachment_in_editor = value
@export var carrier_shoulder_bone: StringName = &"RightShoulder"
@export var carried_pelvis_bone: StringName = &"Hips"
@export var follow_shoulder_rotation := false
@export var auto_calibrate_pelvis_offset := true
@export_range(0.0, 2.0, 0.01, "suffix:s") var pelvis_position_lag_seconds := 0.06
@export_range(0.0, 2.0, 0.01, "suffix:s") var pelvis_rotation_lag_seconds := 0.10
@export_range(0.0, 1.0, 0.01) var pelvis_position_weight := 1.0
@export_range(0.0, 1.0, 0.01) var pelvis_rotation_weight := 0.65
@export_storage var female_pelvis_in_shoulder := Transform3D(
	Basis.IDENTITY,
	Vector3.ZERO
)
@export_tool_button("Calibrate pelvis to current shoulder pose")
var calibrate_attachment_action: Callable = calibrate_female_pelvis_attachment

@export_category("Carried Secondary Motion")
@export var secondary_motion_enabled := true
@export var preview_procedural_motion_in_editor := false:
	set(value):
		if preview_procedural_motion_in_editor == value:
			return
		if Engine.is_editor_hint() and is_inside_tree():
			if value:
				_capture_editor_preview_baseline()
			elif not preview_female_attachment_in_editor:
				_restore_editor_preview_baseline()
		preview_procedural_motion_in_editor = value
@export var secondary_motion_when_stopped := false
@export_enum("Animation timeline", "Measured foot height") var rhythm_source := 0
@export_range(0.1, 4.0, 0.01, "suffix:s") var gait_cycle_seconds := 1.0
@export_range(-6.283, 6.283, 0.01, "radians") var gait_phase_offset := 0.0
@export_range(0.0, 2.0, 0.01, "suffix:s") var secondary_motion_lag_seconds := 0.08
@export_range(0.0, 0.5, 0.001, "suffix:m") var measured_foot_contact_height := 0.0
@export_range(0.01, 1.0, 0.01, "suffix:m") var measured_foot_lift_height := 0.08
@export_range(0.0, 45.0, 0.1, "degrees") var leg_swing_degrees := 7.0
@export_range(0.0, 45.0, 0.1, "degrees") var knee_dangle_degrees := 5.0
@export_range(0.0, 45.0, 0.1, "degrees") var foot_dangle_degrees := 4.0
@export_range(0.0, 45.0, 0.1, "degrees") var arm_swing_degrees := 8.0
@export_range(0.0, 45.0, 0.1, "degrees") var forearm_dangle_degrees := 6.0
@export_range(0.0, 30.0, 0.1, "degrees") var head_sway_degrees := 5.0
@export_range(0.0, 30.0, 0.1, "degrees") var head_nod_degrees := 3.0
@export_range(0.0, 30.0, 0.1, "degrees") var torso_bob_degrees := 2.0
## Roll the carried woman's spine slightly around local Z with the carrier's
## alternating foot rhythm. This independent channel gives the torso a soft
## side-to-side load response without changing pelvis attachment or hand IK.
@export_range(0.0, 30.0, 0.1, "degrees") var spine_sway_degrees := 3.5
@export var leg_swing_axis := Vector3(1.0, 0.0, 0.0)
@export var knee_dangle_axis := Vector3(1.0, 0.0, 0.0)
@export var foot_dangle_axis := Vector3(1.0, 0.0, 0.0)
@export var arm_swing_axis := Vector3(1.0, 0.0, 0.0)
@export var forearm_dangle_axis := Vector3(0.0, 0.0, 1.0)
@export var head_sway_axis := Vector3(0.0, 1.0, 0.0)
@export var head_nod_axis := Vector3(1.0, 0.0, 0.0)
@export var spine_sway_axis := Vector3(0.0, 0.0, 1.0)
@export_tool_button("Capture current female pose as dangle baseline")
var capture_dangle_baseline_action: Callable = capture_female_secondary_baseline

@export_category("Carrier Hand Contacts")
@export var hand_contact_ik_enabled := false
@export_range(0.0, 1.0, 0.01) var right_hand_contact_influence := 1.0
@export_range(0.0, 1.0, 0.01) var left_hand_contact_influence := 1.0
@export var update_female_contact_markers := true
## Which leg of the carried female supplies the hand-contact reference. An
## explicit enum keeps this editable in Godot's Inspector; plain StringName
## values can otherwise appear as a read-only `&"..."` token in some builds.
@export_enum("LeftUpperLeg", "RightUpperLeg") var carried_thigh_bone: String = "LeftUpperLeg"
@export var right_hand_contact_modifier: NodePath = NodePath("ManualCarryBlock/MaleCarrier/Skeleton3D/carry_right_arm_ik")
@export var left_hand_contact_modifier: NodePath = NodePath("ManualCarryBlock/MaleCarrier/Skeleton3D/carry_left_arm_ik")
@export var right_hand_contact_orientation_modifier: NodePath = NodePath("ManualCarryBlock/MaleCarrier/Skeleton3D/carry_right_hand_contact_copy")
@export var left_hand_contact_orientation_modifier: NodePath = NodePath("ManualCarryBlock/MaleCarrier/Skeleton3D/carry_left_hand_contact_copy")
@export_storage var female_pelvis_contact_offset := Transform3D.IDENTITY
@export_storage var female_thigh_contact_offset := Transform3D.IDENTITY
@export_storage var right_hand_contact_pole_offset := Transform3D.IDENTITY
@export_storage var left_hand_contact_pole_offset := Transform3D.IDENTITY
@export_storage var right_hand_contact_pole_captured := false
@export_storage var left_hand_contact_pole_captured := false
@export var right_hand_contact_orientation_enabled := true
@export var left_hand_contact_orientation_enabled := true
@export_tool_button("Capture right hand contact from current pose")
var capture_right_hand_contact_action: Callable = capture_right_hand_contact_from_current_pose
@export_tool_button("Calibrate thigh contact to current marker")
var calibrate_thigh_contact_action: Callable = calibrate_female_thigh_contact
@export_tool_button("Capture left hand contact from current pose")
var capture_left_hand_contact_action: Callable = capture_left_hand_contact_from_current_pose

var _attachment_updating := false
var _editor_preview_baseline := Transform3D.IDENTITY
var _editor_preview_has_baseline := false
var _editor_preview_bone_baseline: Array[Transform3D] = []
var _editor_preview_has_bone_baseline := false
# The filtered attachment target is stored in carrier-root space. Filtering a
# world-space target makes the carried character trail behind by roughly
# walk_speed * lag_seconds for the entire walk, then visibly catch up when the
# carrier stops. Carrier-root space keeps trajectory translation/turning rigid
# while still allowing the animated shoulder motion to have adjustable lag.
var _follow_target_initialized := false
var _follow_target_in_carrier := Transform3D.IDENTITY
var _female_secondary_baseline: Array[Transform3D] = []
var _secondary_baseline_initialized := false
var _smoothed_rhythm := Vector3.ZERO
var _male_foot_contact_baseline := Vector2.ZERO
var _male_foot_contact_baseline_initialized := [false, false]
var _carrier_initial_transform := Transform3D.IDENTITY
var _carrier_baseline_initialized := false
var _carrier_heading_rotation := Quaternion.IDENTITY
var _carrier_heading_initialized := false
var _trajectory_progress := 0.0
var _trajectory_was_active := false
var _trajectory_points: Array[Vector3] = []
var _trajectory_cumulative := PackedFloat32Array()
var _trajectory_marker_signature := ""
var _carrier_previous_feet := {"left": Vector3.ZERO, "right": Vector3.ZERO}
var _carrier_previous_feet_local := {"left": Vector3.ZERO, "right": Vector3.ZERO}
var _carrier_foot_anchors := {"left": Vector3.ZERO, "right": Vector3.ZERO}
var _carrier_foot_was_contact := {"left": false, "right": false}
var _carrier_foot_lock_offset := Vector3.ZERO
var _carrier_foot_lock_height_offset := 0.0
var _root_motion_previous_position := Vector3.ZERO
var _root_motion_previous_time := 0.0
var _root_motion_previous_animation := StringName()
var _root_motion_initialized := false
## OTS Render Capture calls this fixed-step contract while encoding a video.
## Keeping the AnimationPlayer paused between explicit steps prevents a slow
## JPEG/FFmpeg frame from advancing the gait by wall-clock time.
var _capture_fixed_step_active := false
var _capture_player_was_playing := false
var _capture_player_animation := StringName()
var _capture_player_position := 0.0
var _capture_stationary := false

func _ready() -> void:
	# AnimationPlayer evaluates at the default priority. Run the contact solve
	# later so an editor timeline seek cannot leave the carried pelvis one frame
	# behind the carrier's shoulder.
	process_priority = 100
	_apply_carry_shot_visibility()
	_capture_carrier_baseline()
	_normalize_female_root_scale()
	_rebuild_carrier_trajectory()
	_capture_secondary_baseline_if_needed()
	_configure_hand_contact_evaluation_order()
	_auto_capture_pelvis_contact_offset_if_missing()
	_auto_capture_thigh_contact_offset_if_missing()
	_configure_hand_contact_ik()
	# Do not sample or rewrite the authored mounting offset while the editor is
	# still instantiating inherited scenes and evaluating Skeleton3D modifiers.
	# Runtime auto-calibration remains available for procedural scenes that do not
	# store an authored offset; editor users should use the explicit Calibrate
	# button after the pose is visibly settled.
	if auto_calibrate_pelvis_offset and not Engine.is_editor_hint():
		calibrate_female_pelvis_attachment()
	# Never rewrite an authored female transform merely because the scene is
	# open in the editor. Runtime playback still enables the rigid attachment,
	# while editor playback is an explicit preview mode that can be reverted.
	if not Engine.is_editor_hint():
		call_deferred("_apply_female_pelvis_attachment", 0.0)

func _configure_hand_contact_evaluation_order() -> void:
	"""Evaluate contact targets before the carrier's SkeletonModifier3D stack.

		The controller intentionally runs after AnimationPlayer so the female
		attachment and secondary motion see the current animated pose. The male
		skeleton must then run one priority step later; otherwise TwoBoneIK3D
		reads the previous frame's thigh marker and visibly trails during a walk.
		Contact markers also opt out of physics interpolation because both the IK
		and CopyTransform modifiers request interpolated target transforms.
	"""
	var male_skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	if male_skeleton != null:
		male_skeleton.process_priority = process_priority + 1
	var anchors := get_node_or_null("CarryInteractionAnchors") as Node3D
	if anchors == null:
		return
	for marker_name in [
		"FemalePelvisContact",
		"FemaleThighContact",
		"MaleRightArmPole",
		"MaleLeftArmPole",
	]:
		var marker := anchors.get_node_or_null(marker_name) as Marker3D
		if marker != null:
			marker.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

func _auto_capture_thigh_contact_offset_if_missing() -> void:
	"""Preserve a manually authored marker when no offset was serialized.

		Older versions exposed FemaleThighContact as a free marker but did not
		persist the derived offset. Without this bootstrap, enabling marker
	updates would immediately snap that marker to the thigh-bone origin. Only
	identity offsets are bootstrapped, so an explicit calibration is never
	 overwritten.
	"""
	if not update_female_contact_markers or not female_thigh_contact_offset.is_equal_approx(Transform3D.IDENTITY):
		return
	var female_skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	var marker := get_node_or_null("CarryInteractionAnchors/FemaleThighContact") as Marker3D
	if female_skeleton == null or marker == null:
		return
	var thigh_index := female_skeleton.find_bone(carried_thigh_bone)
	if thigh_index < 0:
		return
	var thigh_global := female_skeleton.global_transform * female_skeleton.get_bone_global_pose(thigh_index)
	if not thigh_global.is_equal_approx(marker.global_transform):
		female_thigh_contact_offset = thigh_global.affine_inverse() * marker.global_transform
		if Engine.is_editor_hint():
			EditorInterface.mark_scene_as_unsaved()

func _auto_capture_pelvis_contact_offset_if_missing() -> void:
	"""Preserve a manually authored pelvis contact when no offset is stored."""
	if not update_female_contact_markers or not female_pelvis_contact_offset.is_equal_approx(Transform3D.IDENTITY):
		return
	var female_skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	var marker := get_node_or_null("CarryInteractionAnchors/FemalePelvisContact") as Marker3D
	if female_skeleton == null or marker == null:
		return
	var pelvis_index := female_skeleton.find_bone(carried_pelvis_bone)
	if pelvis_index < 0:
		return
	var pelvis_global := female_skeleton.global_transform * female_skeleton.get_bone_global_pose(pelvis_index)
	if not pelvis_global.is_equal_approx(marker.global_transform):
		female_pelvis_contact_offset = pelvis_global.affine_inverse() * marker.global_transform
		if Engine.is_editor_hint():
			EditorInterface.mark_scene_as_unsaved()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		_apply_carry_shot_visibility()
	if _capture_fixed_step_active:
		return
	_apply_carrier_trajectory(_delta)
	# AnimationPlayer has evaluated the keyed leg pose before this controller
	# runs. Force the Skeleton3D transforms so the secondary solver samples the
	# current root-motion frame rather than the previous frame.
	_refresh_male_pose_for_sampling()
	_apply_female_pelvis_attachment(_delta)
	_apply_secondary_motion(_delta)
	_update_female_contact_markers()
	_configure_hand_contact_ik()


## Fixed-step editor video hooks.  These mirror FemaleWalkController's hooks
## but advance the OTS AnimationPlayer and its procedural attachment layers as
## one deterministic unit per encoded frame.
func editor_capture_begin_fixed_step(options: Dictionary = {}) -> Dictionary:
	var player := get_node_or_null(ots_carry_animation_player_path) as AnimationPlayer
	var matcher := get_node_or_null("OTSMotionMatching")
	if matcher != null and matcher.has_method("editor_capture_begin_fixed_step"):
		matcher.call("editor_capture_begin_fixed_step")
	var requested_source := str(options.get("motion_source", "walk_cycle")).to_lower().replace("-", "_")
	_capture_stationary = requested_source in ["stationary", "still", "static"]
	_capture_fixed_step_active = true
	_capture_player_was_playing = player != null and player.is_playing()
	_capture_player_animation = player.current_animation if player != null else StringName()
	_capture_player_position = player.current_animation_position if player != null else 0.0
	if _capture_player_was_playing:
		# pause() preserves the evaluated pose and current animation position;
		# editor_capture_step_fixed() advances it explicitly below.
		player.pause()
	return {
		"ok": true,
		"was_playing": _capture_player_was_playing,
		"motion_source": "stationary" if _capture_stationary else "walk_cycle",
		"animation": str(_capture_player_animation),
		"animation_time_seconds": player.current_animation_position if player != null else 0.0,
	}


func editor_capture_step_fixed(delta_seconds: float) -> Dictionary:
	var step := maxf(0.0, delta_seconds)
	var player := get_node_or_null(ots_carry_animation_player_path) as AnimationPlayer
	if not _capture_fixed_step_active:
		return {"ok": false, "error": "ots_capture_fixed_step_not_active"}
	# A stationary take is an exact hold of the editor's current OTS block. The
	# autoplay AnimationPlayer has already been paused by begin_fixed_step; do
	# not advance the route, attachment lag, secondary motion, or hand targets.
	# Camera-program time is owned by OTS Render Capture and still advances.
	if _capture_stationary:
		return {
			"ok": true,
			"motion_source": "stationary",
			"animation_time_seconds": player.current_animation_position if player != null else 0.0,
		}
	var matcher := get_node_or_null("OTSMotionMatching")
	if matcher != null and matcher.has_method("editor_capture_step_fixed"):
		matcher.call("editor_capture_step_fixed", step)
		# The matcher may have selected a different source clip at this frame.
		# Keep the deterministic capture clock pointed at that clip instead of
		# seeking the animation that was active when recording began.
		# A paused AnimationPlayer may transiently expose an empty
		# current_animation. Never replace the deterministic capture clip with
		# that empty value; only accept a real animation selected by the matcher.
		if player != null and not player.current_animation.is_empty() and player.current_animation != _capture_player_animation:
			_capture_player_animation = player.current_animation
			_capture_player_position = player.current_animation_position
	if player != null and _capture_player_was_playing and step > 0.0:
		# Seek the paused player explicitly.  AnimationPlayer.advance() depends
		# on its playback state in some Godot editor builds; seek(..., true) is
		# deterministic while still evaluating every keyed bone at this frame.
		var animation := player.get_animation(_capture_player_animation)
		_capture_player_position += step * maxf(player.speed_scale, 0.0)
		if animation != null and animation.loop_mode != 0 and animation.length > 0.0001:
			_capture_player_position = fposmod(_capture_player_position, animation.length)
		elif animation != null:
			_capture_player_position = minf(_capture_player_position, animation.length)
		player.seek(_capture_player_position, true)
	# AnimationPlayer.seek evaluates keyed properties, but Godot may defer the
	# Skeleton3D pose/modifier update until the next idle tick. Refresh before
	# sampling foot rhythm so captured secondary motion follows this exact frame,
	# not the previous one.
	var sampled_male_skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	if sampled_male_skeleton != null:
		sampled_male_skeleton.advance(step)
		sampled_male_skeleton.force_update_all_bone_transforms()
	_apply_carrier_trajectory(step)
	_apply_female_pelvis_attachment(step)
	_apply_secondary_motion(step)
	_update_female_contact_markers()
	_configure_hand_contact_ik()
	# During OTS video capture this controller owns the clock and normal
	# Node3D._process() callbacks are intentionally paused. Explicitly run the
	# male Skeleton3D modifier stack here so the contact IK is present in the
	# very frame that OTS Render copies, rather than only appearing in the next
	# editor preview frame.
	var male_skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	if male_skeleton != null:
		# A zero delta can be treated as a no-op by Godot 4.7's modifier stack.
		# Pass the capture step so TwoBoneIK3D and CopyTransformModifier3D are
		# guaranteed to evaluate for this output frame.
		male_skeleton.advance(step)
		male_skeleton.force_update_all_bone_transforms()
	return {
		"ok": true,
		"animation_time_seconds": player.current_animation_position if player != null else 0.0,
	}


func editor_capture_end_fixed_step(was_playing: bool = false) -> Dictionary:
	var player := get_node_or_null(ots_carry_animation_player_path) as AnimationPlayer
	var matcher := get_node_or_null("OTSMotionMatching")
	if matcher != null and matcher.has_method("editor_capture_end_fixed_step"):
		matcher.call("editor_capture_end_fixed_step")
	var should_resume := _capture_player_was_playing or was_playing
	_capture_fixed_step_active = false
	_capture_player_was_playing = false
	_capture_stationary = false
	if should_resume and player != null and not _capture_player_animation.is_empty():
		player.play(_capture_player_animation)
		player.seek(_capture_player_position, true)
	return {
		"ok": true,
		"resumed": should_resume,
		"animation": str(_capture_player_animation),
	}

func restart_carrier_trajectory() -> void:
	_trajectory_progress = 0.0
	_reset_carrier_foot_lock()
	_reset_carrier_heading_filter()
	_reset_root_motion_consumer()
	_reset_secondary_rhythm()
	_reset_pelvis_follow_filter()
	_rebuild_carrier_trajectory()
	var carrier := get_node_or_null(carrier_root_path) as Node3D
	if carrier != null and _trajectory_points.size() >= 2:
		_place_carrier_on_trajectory(carrier, 0.0)
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()


func get_camera_follow_transform() -> Transform3D:
	"""Return the stable, route-driven carrier transform for camera tracking.

	The male skeleton can contain gait and foot-lock motion every frame.  Camera
	follow should instead use the evaluated carrier root, whose position and
	heading come only from the predefined CarrierTrajectory.  The OTS Render
	dock calls this method when the semantic target is `CarrierTrajectory`.
	"""
	var carrier := get_node_or_null(carrier_root_path) as Node3D
	return carrier.global_transform if carrier != null else global_transform

func get_motion_matching_query() -> Dictionary:
	"""Return the route-owned request used by OTSMotionMatchingController.

		Motion matching must not infer heading from the animated pelvis: the
		pelvis deliberately contains gait bob and loaded-carry sway.  This query
		uses the predefined CarrierTrajectory instead, so changing clips cannot
		make the carrier turn or drift away from the authored path.
	"""
	var speed := maxf(carrier_walk_speed_mps, 0.0)
	var turn_amount := 0.0
	var route_length := float(_trajectory_cumulative[-1]) if not _trajectory_cumulative.is_empty() else 0.0
	if route_length > 0.0001 and _trajectory_points.size() >= 2:
		var lookahead := clampf(maxf(speed * 0.35, 0.12), 0.05, route_length * 0.2)
		var before := _sample_route_tangent(maxf(_trajectory_progress - lookahead, 0.0))
		var after := _sample_route_tangent(minf(_trajectory_progress + lookahead, route_length))
		if before.length_squared() > 0.0001 and after.length_squared() > 0.0001:
			turn_amount = clampf(absf(atan2(before.cross(after).dot(_walk_plane_normal()), before.dot(after))) / PI, 0.0, 1.0)
	return {
		"speed": speed,
		"turn": turn_amount,
		"progress": _trajectory_progress,
		"route_length": route_length,
	}

func editor_transport_enable_motion_matching(enabled: bool = true) -> Dictionary:
	var matcher := get_node_or_null("OTSMotionMatching")
	if matcher == null or not matcher.has_method("enable_motion_matching"):
		return {"ok": false, "error": "motion_matching_controller_not_found"}
	return matcher.call("enable_motion_matching") if enabled else matcher.call("disable_motion_matching")

func editor_transport_play_motion_matching(restart: bool = true) -> Dictionary:
	var matcher := get_node_or_null("OTSMotionMatching")
	if matcher == null or not matcher.has_method("start_motion_matching"):
		return {"ok": false, "error": "motion_matching_controller_not_found"}
	return matcher.call("start_motion_matching", restart)

func editor_transport_motion_matching_status() -> Dictionary:
	var matcher := get_node_or_null("OTSMotionMatching")
	if matcher == null or not matcher.has_method("status"):
		return {"ok": false, "error": "motion_matching_controller_not_found"}
	return matcher.call("status")

func editor_transport_configure_motion_matching(options: Dictionary = {}) -> Dictionary:
	var matcher := get_node_or_null("OTSMotionMatching")
	if matcher == null or not matcher.has_method("status"):
		return {"ok": false, "error": "motion_matching_controller_not_found"}
	if options.has("desired_load"):
		matcher.set("desired_load", clampf(float(options.get("desired_load")), 0.0, 1.0))
	if options.has("desired_speed_mps"):
		matcher.set("desired_speed_mps", maxf(float(options.get("desired_speed_mps")), 0.1))
	if options.has("matching_interval_seconds"):
		matcher.set("matching_interval_seconds", maxf(float(options.get("matching_interval_seconds")), 0.05))
	if options.has("blend_seconds"):
		matcher.set("blend_seconds", clampf(float(options.get("blend_seconds")), 0.0, 1.0))
	matcher.set("_matching_elapsed", matcher.get("matching_interval_seconds"))
	if bool(options.get("select_now", true)) and bool(matcher.get("enabled")):
		matcher.call("select_best_gait")
	return matcher.call("status")


func editor_transport_play_ots_carry(animation_name: String = "", restart: bool = true) -> Dictionary:
	"""Play the OTS carrier AnimationPlayer from an editor transport command."""
	var player := get_node_or_null(ots_carry_animation_player_path) as AnimationPlayer
	if player == null:
		return {"ok": false, "error": "ots_carry_animation_player_not_found", "path": str(ots_carry_animation_player_path)}
	var requested := StringName(animation_name) if not animation_name.is_empty() else ots_carry_walk_animation
	if not player.has_animation(requested):
		return {"ok": false, "error": "ots_carry_animation_not_found", "animation": str(requested)}
	if restart:
		restart_carrier_trajectory()
		player.stop()
		player.play(requested)
		player.seek(0.0, true)
	else:
		player.play(requested)
	# Prime a travelling clip before the first editor/capture frame. Without
	# this, the first frame uses AnimationPlayer.speed_scale == 1.0 and consumes
	# one full-speed root delta before the trajectory solver can derive the
	# requested 0.78 m/s loaded-carrier pace.
	_configure_root_motion_playback(player, carrier_walk_speed_mps)
	return {
		"ok": true,
		"animation": str(requested),
		"playing": player.is_playing(),
		"length_seconds": player.get_animation(requested).length,
	}

func project_trajectory_to_walk_plane() -> void:
	var trajectory := get_node_or_null(carrier_trajectory_path) as Node3D
	if trajectory == null:
		return
	for child in trajectory.get_children():
		if child is Marker3D and child.has_meta("trajectory_waypoint"):
			var marker := child as Marker3D
			marker.global_position = _project_to_walk_plane(marker.global_position, 0.0)
	_trajectory_marker_signature = ""
	_rebuild_carrier_trajectory()
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func _capture_carrier_baseline() -> void:
	var carrier := get_node_or_null(carrier_root_path) as Node3D
	if carrier == null:
		return
	# Imported GLB character roots may be AnimatableBody3D nodes. Their default
	# physics synchronization queues transform edits, which makes editor
	# trajectory preview appear frozen even though progress is advancing.
	if carrier is AnimatableBody3D:
		(carrier as AnimatableBody3D).sync_to_physics = false
	_carrier_initial_transform = carrier.global_transform
	_carrier_baseline_initialized = true

func _apply_carrier_trajectory(delta: float) -> void:
	var player := get_node_or_null(ots_carry_animation_player_path) as AnimationPlayer
	var carrier := get_node_or_null(carrier_root_path) as Node3D
	var preview_allowed := not Engine.is_editor_hint() or preview_trajectory_in_editor
	var active := carrier_trajectory_enabled and preview_allowed and player != null and \
		(player.is_playing() or _capture_fixed_step_active)
	if not active:
		if _trajectory_was_active and Engine.is_editor_hint() and restore_carrier_when_preview_stops and carrier != null and _carrier_baseline_initialized:
			carrier.global_transform = _carrier_initial_transform
			_trajectory_progress = 0.0
			_reset_carrier_foot_lock()
		_reset_carrier_heading_filter()
		_trajectory_was_active = false
		return
	if carrier == null:
		return
	if not _carrier_baseline_initialized:
		_capture_carrier_baseline()
	var signature := _carrier_trajectory_signature()
	if signature != _trajectory_marker_signature:
		_rebuild_carrier_trajectory()
	if _trajectory_points.size() < 2 or _trajectory_cumulative.is_empty():
		return
	var length := float(_trajectory_cumulative[-1])
	if length <= 0.0001:
		return
	if not _trajectory_was_active:
		_trajectory_progress = 0.0
		_reset_carrier_foot_lock()
		_reset_carrier_heading_filter()
		_trajectory_was_active = true
	var turn_amount := _route_turn_amount()
	var turn_speed_factor := 1.0 - trajectory_turn_speed_reduction * turn_amount
	var desired_speed := carrier_walk_speed_mps * clampf(turn_speed_factor, 0.2, 1.0)
	_configure_root_motion_playback(player, desired_speed)
	var root_advance := _consume_root_motion_distance(player, delta)
	_trajectory_progress += root_advance if root_advance >= 0.0 else desired_speed * maxf(delta, 0.0)
	_trajectory_progress = fposmod(_trajectory_progress, length) if carrier_trajectory_loop else clampf(_trajectory_progress, 0.0, length)
	_place_carrier_on_trajectory(carrier, _trajectory_progress, delta)
	_apply_carrier_foot_lock(carrier, delta, length)

func _rebuild_carrier_trajectory() -> void:
	var control_points: Array[Vector3] = []
	_trajectory_points.clear()
	_trajectory_cumulative = PackedFloat32Array()
	var trajectory := get_node_or_null(carrier_trajectory_path) as Node3D
	if trajectory == null:
		return
	var markers: Array[Marker3D] = []
	for child in trajectory.get_children():
		if child is Marker3D and child.has_meta("trajectory_waypoint"):
			markers.append(child as Marker3D)
	markers.sort_custom(func(a: Marker3D, b: Marker3D) -> bool: return a.name.naturalnocasecmp_to(b.name) < 0)
	for marker in markers:
		control_points.append(_project_to_walk_plane(marker.global_position, 0.0))
	if control_points.is_empty():
		return
	if trajectory_corner_smoothing <= 0.001 or control_points.size() < 3:
		_trajectory_points.append_array(control_points)
	else:
		_trajectory_points = _build_smoothed_trajectory(control_points)
	_trajectory_cumulative.append(0.0)
	for index in range(1, _trajectory_points.size()):
		_trajectory_cumulative.append(_trajectory_cumulative[index - 1] + _trajectory_points[index - 1].distance_to(_trajectory_points[index]))
	_trajectory_marker_signature = _carrier_trajectory_signature()

func _build_smoothed_trajectory(control_points: Array[Vector3]) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var sample_count := maxi(2, trajectory_samples_per_segment)
	# Duplicate endpoint controls keep the route anchored at the first and last
	# authored waypoint while giving interior joints a continuous tangent.
	for segment in range(control_points.size() - 1):
		var p0: Vector3 = control_points[maxi(segment - 1, 0)]
		var p1: Vector3 = control_points[segment]
		var p2: Vector3 = control_points[segment + 1]
		var p3: Vector3 = control_points[mini(segment + 2, control_points.size() - 1)]
		for sample in range(sample_count):
			if segment > 0 and sample == 0:
				continue
			var t := float(sample) / float(sample_count)
			var raw := _catmull_rom(p0, p1, p2, p3, t)
			# Blend from the straight chord toward the curve. This avoids
			# overshoot while making smoothing continuously tunable in the Inspector.
			var chord := p1.lerp(p2, t)
			result.append(chord.lerp(raw, trajectory_corner_smoothing))
	result.append(control_points[-1])
	return result

func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t +
		(2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
		(-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

func _carrier_trajectory_signature() -> String:
	var trajectory := get_node_or_null(carrier_trajectory_path) as Node3D
	if trajectory == null:
		return ""
	var values: Array[String] = []
	values.append("smooth=%.3f samples=%d heading_lookahead=%.3f heading_tau=%.3f" % [
		trajectory_corner_smoothing,
		trajectory_samples_per_segment,
		trajectory_heading_lookahead_ratio,
		trajectory_heading_smoothing_seconds,
	])
	var plane_node := get_node_or_null(carrier_walk_plane_path) as Node3D
	if plane_node != null:
		values.append("plane=%s" % plane_node.global_transform)
	for child in trajectory.get_children():
		if child is Marker3D and child.has_meta("trajectory_waypoint"):
			values.append("%s=%s" % [child.name, (child as Marker3D).global_position])
	return "|".join(values)

func _place_carrier_on_trajectory(carrier: Node3D, progress: float, delta: float = 0.0, update_heading: bool = true) -> void:
	var sample := _sample_carrier_trajectory(progress)
	if sample.is_empty():
		return
	carrier.global_position = _project_to_walk_plane(sample.position as Vector3, carrier_height_above_plane) + _carrier_foot_lock_offset + _walk_plane_normal() * _carrier_foot_lock_height_offset
	if not carrier_face_trajectory or not _carrier_baseline_initialized:
		return
	var normal := _walk_plane_normal()
	var tangent := (sample.tangent as Vector3).slide(normal).normalized()
	var initial_forward := (_carrier_initial_transform.basis * carrier_local_forward.normalized()).slide(normal).normalized()
	if tangent.length_squared() > 0.0001 and initial_forward.length_squared() > 0.0001:
		var target_rotation := Quaternion(initial_forward, tangent).normalized()
		if not _carrier_heading_initialized or delta <= 0.0:
			_carrier_heading_rotation = target_rotation
			_carrier_heading_initialized = true
		elif update_heading:
			var smoothing_seconds := maxf(trajectory_heading_smoothing_seconds, 0.0)
			var alpha := 1.0 if smoothing_seconds <= 0.0001 else 1.0 - exp(-delta / smoothing_seconds)
			var angle := _carrier_heading_rotation.angle_to(target_rotation)
			if angle > 0.000001:
				var max_step := deg_to_rad(trajectory_max_yaw_rate_degrees) * maxf(delta, 0.0)
				alpha = minf(alpha, max_step / angle)
			_carrier_heading_rotation = _carrier_heading_rotation.slerp(target_rotation, clampf(alpha, 0.0, 1.0)).normalized()
		carrier.global_basis = Basis(_carrier_heading_rotation) * _carrier_initial_transform.basis

func _sample_carrier_trajectory(progress: float) -> Dictionary:
	if _trajectory_points.size() < 2:
		return {}
	var length := float(_trajectory_cumulative[-1])
	var distance := clampf(progress, 0.0, length)
	for index in range(1, _trajectory_points.size()):
		if distance <= _trajectory_cumulative[index] or index == _trajectory_points.size() - 1:
			var from := _trajectory_points[index - 1]
			var to := _trajectory_points[index]
			var segment_length := maxf(from.distance_to(to), 0.000001)
			var alpha := clampf((distance - _trajectory_cumulative[index - 1]) / segment_length, 0.0, 1.0)
			var position := from.lerp(to, alpha)
			return {"position": position, "tangent": _sample_route_tangent(distance)}
	return {"position": _trajectory_points[-1], "tangent": _sample_route_tangent(length)}

func _sample_route_tangent(distance: float) -> Vector3:
	"""Estimate a continuous route heading around the current distance.

	The rendered camera follows the carrier root. Using one sampled segment's
	tangent made that root yaw by a visible step at every polyline vertex. A
	central difference over a configurable route distance gives a stable tangent
	while retaining the exact sampled position. At the ends of an open route the
	window becomes a forward/backward difference so the carrier never looks
	outside the authored path.
	"""
	if _trajectory_points.size() < 2 or _trajectory_cumulative.is_empty():
		return Vector3.ZERO
	var length := float(_trajectory_cumulative[-1])
	var window := clampf(length * trajectory_heading_lookahead_ratio, 0.0, length * 0.25)
	if window <= 0.0001:
		var fallback := _nearest_route_segment_tangent(distance)
		return fallback
	var lower := maxf(0.0, distance - window)
	var upper := minf(length, distance + window)
	if upper - lower <= 0.0001:
		return _nearest_route_segment_tangent(distance)
	var lower_position := _sample_route_position(lower)
	var upper_position := _sample_route_position(upper)
	var chord := upper_position - lower_position
	return chord.normalized() if chord.length_squared() > 0.00000001 else _nearest_route_segment_tangent(distance)

func _sample_route_position(distance: float) -> Vector3:
	if _trajectory_points.size() < 2 or _trajectory_cumulative.is_empty():
		return Vector3.ZERO
	var length := float(_trajectory_cumulative[-1])
	var clamped_distance := clampf(distance, 0.0, length)
	for index in range(1, _trajectory_points.size()):
		if clamped_distance <= _trajectory_cumulative[index] or index == _trajectory_points.size() - 1:
			var from := _trajectory_points[index - 1]
			var to := _trajectory_points[index]
			var segment_length := maxf(from.distance_to(to), 0.000001)
			var alpha := clampf((clamped_distance - _trajectory_cumulative[index - 1]) / segment_length, 0.0, 1.0)
			return from.lerp(to, alpha)
	return _trajectory_points[-1]

func _nearest_route_segment_tangent(distance: float) -> Vector3:
	var length := float(_trajectory_cumulative[-1])
	var clamped_distance := clampf(distance, 0.0, length)
	for index in range(1, _trajectory_points.size()):
		if clamped_distance <= _trajectory_cumulative[index] or index == _trajectory_points.size() - 1:
			return (_trajectory_points[index] - _trajectory_points[index - 1]).normalized()
	return (_trajectory_points[-1] - _trajectory_points[-2]).normalized()

func _reset_carrier_heading_filter() -> void:
	_carrier_heading_rotation = Quaternion.IDENTITY
	_carrier_heading_initialized = false

func _project_to_walk_plane(point: Vector3, height: float) -> Vector3:
	var plane_node := get_node_or_null(carrier_walk_plane_path) as Node3D
	if plane_node == null:
		return Vector3(point.x, height, point.z)
	var normal := _walk_plane_normal()
	var projected := point - normal * (point - plane_node.global_position).dot(normal)
	return projected + normal * height

func _walk_plane_normal() -> Vector3:
	var plane_node := get_node_or_null(carrier_walk_plane_path) as Node3D
	if plane_node == null:
		return Vector3.UP
	var normal := plane_node.global_basis.y.normalized()
	return normal if normal.length_squared() > 0.0001 else Vector3.UP

func _apply_carrier_foot_lock(carrier: Node3D, delta: float, trajectory_length: float) -> void:
	if not carrier_foot_lock_enabled:
		return
	var contacts := {"left": false, "right": false}
	for side in ["left", "right"]:
		var foot := _carrier_foot_world(side)
		# Contact is measured relative to the animated carrier. The external
		# root-motion route intentionally moves the whole carrier at walking
		# speed; using world velocity here prevented a planted foot from ever
		# acquiring an anchor.
		var local_foot := carrier.global_transform.affine_inverse() * foot
		var previous_local := _carrier_previous_feet_local[side] as Vector3
		# Horizontal local motion is expected while the source clip translates
		# its feet through a stride. Use only local vertical velocity to decide
		# whether a near-plane foot is planted; otherwise a perfectly valid
		# stance is rejected as soon as the carrier starts root motion.
		var vertical_speed := absf(local_foot.y - previous_local.y) / maxf(delta, 0.0001) if not previous_local.is_zero_approx() else INF
		var plane_distance := absf((foot - _project_to_walk_plane(foot, 0.0)).dot(_walk_plane_normal()))
		# Once planted, retain contact until the foot actually lifts. The old
		# speed-only test rejected the very frame that external root yaw swept a
		# planted foot sideways, preventing the lock from correcting the slide.
		var contact := plane_distance <= carrier_contact_height and (vertical_speed <= carrier_contact_speed or bool(_carrier_foot_was_contact[side]))
		contacts[side] = contact
		if contact and not bool(_carrier_foot_was_contact[side]):
			_carrier_foot_anchors[side] = foot
	var sample := _sample_carrier_trajectory(_trajectory_progress)
	var tangent := (sample.get("tangent", Vector3.ZERO) as Vector3).normalized()
	var correction_sum := 0.0
	var correction_count := 0
	for side in ["left", "right"]:
		if bool(contacts[side]) and bool(_carrier_foot_was_contact[side]):
			correction_sum += ((_carrier_foot_anchors[side] as Vector3) - _carrier_foot_world(side)).dot(tangent)
			correction_count += 1
	# A travelling clip already supplies the authoritative longitudinal
	# displacement through RootMotionSampler. Do not apply a second tangential
	# correction or the carrier will surge/backtrack at every foot plant.
	if correction_count > 0 and tangent.length_squared() > 0.0001 and not _root_motion_initialized:
		_trajectory_progress += correction_sum / float(correction_count) * carrier_foot_lock_strength
		_trajectory_progress = fposmod(_trajectory_progress, trajectory_length) if carrier_trajectory_loop else clampf(_trajectory_progress, 0.0, trajectory_length)
		_place_carrier_on_trajectory(carrier, _trajectory_progress, 0.0, false)
	# Preserve the supporting foot in the full walk plane, not only along the
	# path tangent. This absorbs the lateral arc generated when the route turns
	# beneath a straight-walk source clip.
	var planar_correction := Vector3.ZERO
	var planar_count := 0
	if not _root_motion_initialized:
		for side in ["left", "right"]:
			if bool(contacts[side]) and bool(_carrier_foot_was_contact[side]):
				var correction := ((_carrier_foot_anchors[side] as Vector3) - _carrier_foot_world(side)).slide(_walk_plane_normal())
				planar_correction += correction
				planar_count += 1
	var previous_offset := _carrier_foot_lock_offset
	var previous_height_offset := _carrier_foot_lock_height_offset
	if planar_count > 0:
		_carrier_foot_lock_offset += planar_correction / float(planar_count) * carrier_foot_lock_planar_strength
		if _carrier_foot_lock_offset.length() > carrier_foot_lock_max_planar_offset:
			_carrier_foot_lock_offset = _carrier_foot_lock_offset.normalized() * carrier_foot_lock_max_planar_offset
	else:
		var release_alpha := 1.0 - exp(-maxf(delta, 0.0) / maxf(carrier_foot_lock_release_seconds, 0.0001))
		_carrier_foot_lock_offset = _carrier_foot_lock_offset.lerp(Vector3.ZERO, release_alpha)
	# Recalibrate height only when a new foot becomes planted. Continuously
	# averaging the two animated ankle heights made the carrier bob up and down
	# as one foot entered swing, which reads as floating in water.
	var vertical_correction := 0.0
	var vertical_count := 0
	for side in ["left", "right"]:
		if bool(contacts[side]) and not bool(_carrier_foot_was_contact[side]):
			var foot := _carrier_foot_world(side)
			var signed_height := (foot - _project_to_walk_plane(foot, 0.0)).dot(_walk_plane_normal())
			vertical_correction += -signed_height
			vertical_count += 1
	if vertical_count > 0:
		var target_height_offset := clampf(
			_carrier_foot_lock_height_offset + vertical_correction / float(vertical_count),
			-carrier_foot_lock_max_vertical_offset,
			carrier_foot_lock_max_vertical_offset
		)
		_carrier_foot_lock_height_offset = lerpf(
			_carrier_foot_lock_height_offset, target_height_offset,
			carrier_foot_lock_vertical_strength)
	carrier.global_position += _carrier_foot_lock_offset - previous_offset
	carrier.global_position += _walk_plane_normal() * (
		_carrier_foot_lock_height_offset - previous_height_offset)
	for side in ["left", "right"]:
		_carrier_previous_feet[side] = _carrier_foot_world(side)
		_carrier_previous_feet_local[side] = carrier.global_transform.affine_inverse() * _carrier_previous_feet[side]
		_carrier_foot_was_contact[side] = bool(contacts[side])

func _carrier_foot_world(side: String) -> Vector3:
	var skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	if skeleton == null:
		return Vector3.ZERO
	var bone_name := carrier_left_foot_bone if side == "left" else carrier_right_foot_bone
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index < 0:
		return Vector3.ZERO
	return (skeleton.global_transform * skeleton.get_bone_global_pose(bone_index)).origin

func _reset_carrier_foot_lock() -> void:
	_carrier_previous_feet = {"left": Vector3.ZERO, "right": Vector3.ZERO}
	_carrier_previous_feet_local = {"left": Vector3.ZERO, "right": Vector3.ZERO}
	_carrier_foot_anchors = {"left": Vector3.ZERO, "right": Vector3.ZERO}
	_carrier_foot_was_contact = {"left": false, "right": false}
	_carrier_foot_lock_offset = Vector3.ZERO
	_carrier_foot_lock_height_offset = 0.0

func _refresh_male_pose_for_sampling() -> void:
	var skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	if skeleton != null:
		skeleton.force_update_all_bone_transforms()


func _route_turn_amount() -> float:
	var query := get_motion_matching_query()
	return clampf(float(query.get("turn", 0.0)), 0.0, 1.0)

func _effective_animation_name(player: AnimationPlayer) -> StringName:
	if player == null:
		return StringName()
	if not player.current_animation.is_empty():
		return player.current_animation
	if _capture_fixed_step_active and not _capture_player_animation.is_empty():
		return _capture_player_animation
	return StringName()


func _configure_root_motion_playback(player: AnimationPlayer, desired_speed: float) -> void:
	var animation_name := _effective_animation_name(player)
	if player == null or animation_name.is_empty():
		return
	var animation := player.get_animation(animation_name)
	if animation == null or not carrier_root_motion_enabled:
		return
	var source_speed := float(animation.get_meta("ots_recommended_speed_mps", 0.0))
	if source_speed <= 0.0001:
		# Existing in-place clips retain their authored playback rate.
		player.speed_scale = 1.0
		return
	var warped_speed := source_speed * _root_motion_stride_scale(animation)
	player.speed_scale = clampf(
		desired_speed / maxf(warped_speed, 0.0001),
		carrier_root_motion_min_playback_rate,
		carrier_root_motion_max_playback_rate
	)


func _consume_root_motion_distance(player: AnimationPlayer, delta: float) -> float:
	"""Return path distance from the current travelling clip, or -1 if absent."""
	var animation_name := _effective_animation_name(player)
	if not carrier_root_motion_enabled or player == null or animation_name.is_empty():
		_reset_root_motion_consumer()
		return -1.0
	var animation := player.get_animation(animation_name)
	var sampler := get_node_or_null(carrier_root_motion_sampler_path) as Node3D
	if animation == null or sampler == null:
		_reset_root_motion_consumer()
		return -1.0
	var source_speed := float(animation.get_meta("ots_recommended_speed_mps", 0.0))
	var stride_scale := _root_motion_stride_scale(animation)
	var cycle_displacement_value: Variant = animation.get_meta("ots_root_cycle_displacement", Vector3.ZERO)
	var cycle_displacement := cycle_displacement_value as Vector3 if cycle_displacement_value is Vector3 else Vector3.ZERO
	if cycle_displacement.length_squared() <= 0.000001:
		# Older extracted libraries may contain the sampler track but predate
		# the displacement metadata. Derive it once from the keyed channel so
		# those clips still drive CarrierTrajectory and secondary motion.
		cycle_displacement = _root_cycle_displacement_from_track(animation)
	var cycle_planar := cycle_displacement.slide(_walk_plane_normal())
	if source_speed <= 0.0001 or cycle_planar.length_squared() <= 0.000001:
		_reset_root_motion_consumer()
		return -1.0
	var current_position := sampler.position
	current_position.y = 0.0
	var current_time := player.current_animation_position
	if not _root_motion_initialized or animation_name != _root_motion_previous_animation:
		_root_motion_previous_position = current_position
		_root_motion_previous_time = current_time
		_root_motion_previous_animation = animation_name
		_root_motion_initialized = true
		return 0.0
	var displacement := current_position - _root_motion_previous_position
	if current_time + 0.00001 < _root_motion_previous_time:
		displacement = (cycle_planar - _root_motion_previous_position) + current_position
	_root_motion_previous_position = current_position
	_root_motion_previous_time = current_time
	var forward := cycle_planar.normalized()
	var distance := maxf(0.0, displacement.dot(forward)) * stride_scale
	# A malformed key or editor seek must never teleport the carrier. Normal
	# playback stays far below this generous three-frame-speed envelope.
	var max_distance := source_speed * stride_scale * maxf(delta, 1.0 / 120.0) * 3.0
	return minf(distance, max_distance)

func _root_cycle_displacement_from_track(animation: Animation) -> Vector3:
	if animation == null:
		return Vector3.ZERO
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_POSITION_3D:
			continue
		if str(animation.track_get_path(track)) != "RootMotionSampler:position":
			continue
		var key_count := animation.track_get_key_count(track)
		if key_count < 2:
			return Vector3.ZERO
		var first := animation.track_get_key_value(track, 0) as Vector3
		var last := animation.track_get_key_value(track, key_count - 1) as Vector3
		return last - first
	return Vector3.ZERO


func _root_motion_stride_scale(animation: Animation) -> float:
	if animation != null and animation.has_meta("ots_root_motion_stride_scale"):
		return clampf(float(animation.get_meta("ots_root_motion_stride_scale")), 0.1, 2.0)
	return carrier_root_motion_stride_scale


func _reset_root_motion_consumer() -> void:
	_root_motion_previous_position = Vector3.ZERO
	_root_motion_previous_time = 0.0
	_root_motion_previous_animation = StringName()
	_root_motion_initialized = false

func calibrate_female_pelvis_attachment() -> void:
	var transforms := _attachment_transforms()
	if transforms.is_empty():
		return
	var calibrated := (transforms.shoulder as Transform3D).affine_inverse() * (transforms.pelvis as Transform3D)
	var offset_distance := calibrated.origin.length()
	if offset_distance < MIN_REASONABLE_PELVIS_OFFSET_METERS or \
			offset_distance > MAX_REASONABLE_PELVIS_OFFSET_METERS:
		push_warning(
			"OTS carry calibration rejected pelvis offset %.4f m; expected %.2f-%.2f m. " % [
				offset_distance,
				MIN_REASONABLE_PELVIS_OFFSET_METERS,
				MAX_REASONABLE_PELVIS_OFFSET_METERS,
			] +
			"The skeleton may still be settling. Wait for the authored pose to appear, then press 'Calibrate pelvis to current shoulder pose'."
		)
		return
	female_pelvis_in_shoulder = calibrated
	_reset_pelvis_follow_filter()
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func calibrate_female_thigh_contact() -> void:
	"""Store the marker's current pose relative to the selected thigh bone.

		When update_female_contact_markers is enabled, the marker is rebuilt from
		this offset every frame. This button makes that workflow editable: turn
		marker updates off, place FemaleThighContact on the desired point, press
		this button, then turn marker updates back on for a walking shot.
	"""
	var female_skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	var marker := get_node_or_null("CarryInteractionAnchors/FemaleThighContact") as Marker3D
	if female_skeleton == null or marker == null:
		return
	var thigh_index := female_skeleton.find_bone(carried_thigh_bone)
	if thigh_index < 0:
		push_warning("Cannot calibrate thigh contact: bone '%s' was not found on the female skeleton." % carried_thigh_bone)
		return
	var thigh_global := female_skeleton.global_transform * female_skeleton.get_bone_global_pose(thigh_index)
	female_thigh_contact_offset = thigh_global.affine_inverse() * marker.global_transform
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func capture_left_hand_contact_from_current_pose() -> void:
	"""Capture the authored male left-hand contact as a reusable thigh offset.

		Pose the carrier's left hand with IK disabled, including its palm
		orientation. This action copies that transform to FemaleThighContact,
		stores the offset relative to the selected female thigh bone, and records
		the current elbow direction so the TwoBoneIK solve reproduces the pose.
		Afterward, enable Hand Contact IK and the anchor will follow the female
		through the walk without the hand twisting back to its old animation pose.
	"""
	var male_skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	var female_skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	var marker := get_node_or_null("CarryInteractionAnchors/FemaleThighContact") as Marker3D
	var pole := get_node_or_null("CarryInteractionAnchors/MaleLeftArmPole") as Marker3D
	if male_skeleton == null or female_skeleton == null or marker == null or pole == null:
		return
	var hand_index := male_skeleton.find_bone("LeftHand")
	var elbow_index := male_skeleton.find_bone("LeftLowerArm")
	var thigh_index := female_skeleton.find_bone(carried_thigh_bone)
	if hand_index < 0 or elbow_index < 0 or thigh_index < 0:
		push_warning("Cannot capture left hand contact: required hand, elbow, or thigh bone was not found.")
		return
	var hand_global := male_skeleton.global_transform * male_skeleton.get_bone_global_pose(hand_index)
	var elbow_global := male_skeleton.global_transform * male_skeleton.get_bone_global_pose(elbow_index)
	var thigh_global := female_skeleton.global_transform * female_skeleton.get_bone_global_pose(thigh_index)
	marker.global_transform = hand_global
	female_thigh_contact_offset = thigh_global.affine_inverse() * hand_global
	# Keep the elbow on the same bend side when the carrier root moves. The
	# stored offset is evaluated in carrier-root space by the marker updater.
	var carrier := get_node_or_null(carrier_root_path) as Node3D
	if carrier != null:
		left_hand_contact_pole_offset = carrier.global_transform.affine_inverse() * elbow_global
		left_hand_contact_pole_captured = true
	else:
		pole.global_transform = elbow_global
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func capture_right_hand_contact_from_current_pose() -> void:
	"""Capture the authored male right-hand hold as a pelvis-relative contact.

		Pose the carrier's right hand on the female pelvis with hand IK disabled,
		then press the Inspector button. The pelvis marker receives the hand's
		position and orientation, while the right-arm pole preserves the authored
		elbow bend when the carrier starts walking.
	"""
	var male_skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	var female_skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	var marker := get_node_or_null("CarryInteractionAnchors/FemalePelvisContact") as Marker3D
	var pole := get_node_or_null("CarryInteractionAnchors/MaleRightArmPole") as Marker3D
	if male_skeleton == null or female_skeleton == null or marker == null or pole == null:
		return
	var hand_index := male_skeleton.find_bone("RightHand")
	var elbow_index := male_skeleton.find_bone("RightLowerArm")
	var pelvis_index := female_skeleton.find_bone(carried_pelvis_bone)
	if hand_index < 0 or elbow_index < 0 or pelvis_index < 0:
		push_warning("Cannot capture right hand contact: required hand, elbow, or pelvis bone was not found.")
		return
	var hand_global := male_skeleton.global_transform * male_skeleton.get_bone_global_pose(hand_index)
	var elbow_global := male_skeleton.global_transform * male_skeleton.get_bone_global_pose(elbow_index)
	var pelvis_global := female_skeleton.global_transform * female_skeleton.get_bone_global_pose(pelvis_index)
	marker.global_transform = hand_global
	female_pelvis_contact_offset = pelvis_global.affine_inverse() * hand_global
	var carrier := get_node_or_null(carrier_root_path) as Node3D
	if carrier != null:
		right_hand_contact_pole_offset = carrier.global_transform.affine_inverse() * elbow_global
		right_hand_contact_pole_captured = true
	else:
		pole.global_transform = elbow_global
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func capture_female_secondary_baseline() -> void:
	var skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	if skeleton == null:
		return
	_female_secondary_baseline.clear()
	_female_secondary_baseline.resize(skeleton.get_bone_count())
	for bone_index in skeleton.get_bone_count():
		_female_secondary_baseline[bone_index] = skeleton.get_bone_pose(bone_index)
	_secondary_baseline_initialized = true
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func _apply_female_pelvis_attachment(delta: float) -> void:
	if not female_pelvis_attachment_enabled or _attachment_updating:
		return
	if Engine.is_editor_hint() and not preview_female_attachment_in_editor:
		return
	var transforms := _attachment_transforms()
	if transforms.is_empty():
		return
	var female := transforms.female as Node3D
	var carrier := transforms.carrier as Node3D
	var current_pelvis := transforms.pelvis as Transform3D
	var target_pelvis := (transforms.shoulder as Transform3D) * female_pelvis_in_shoulder
	var target_in_carrier := carrier.global_transform.affine_inverse() * target_pelvis
	if not _follow_target_initialized:
		_follow_target_in_carrier = target_in_carrier
		_follow_target_initialized = true
	var position_alpha := _lag_alpha(pelvis_position_lag_seconds, delta)
	var rotation_alpha := _lag_alpha(pelvis_rotation_lag_seconds, delta)
	_follow_target_in_carrier.origin = _follow_target_in_carrier.origin.lerp(target_in_carrier.origin, position_alpha)
	_follow_target_in_carrier.basis = Basis(_follow_target_in_carrier.basis.get_rotation_quaternion().slerp(
		target_in_carrier.basis.get_rotation_quaternion(), rotation_alpha
	))
	# Recompose with the current carrier root after filtering. Global path motion
	# therefore stays locked; only the shoulder's motion relative to the carrier
	# receives the authored positional/rotational lag.
	var filtered_target_pelvis := carrier.global_transform * _follow_target_in_carrier
	# The authored FK pose remains the reference. The follow solve only applies
	# the requested weighted delta from the current pelvis to the smoothed target.
	var correction := Transform3D.IDENTITY
	var position_delta := (filtered_target_pelvis.origin - current_pelvis.origin) * pelvis_position_weight
	if follow_shoulder_rotation:
		var delta_rotation := filtered_target_pelvis.basis.get_rotation_quaternion() * current_pelvis.basis.get_rotation_quaternion().inverse()
		correction.basis = Basis(Quaternion.IDENTITY.slerp(delta_rotation, pelvis_rotation_weight))
	# Premultiply around the pelvis pivot, not the world origin, then layer in
	# weighted translation. This prevents orientation follow from orbiting the
	# whole carried character around (0, 0, 0).
	correction.origin = current_pelvis.origin - correction.basis * current_pelvis.origin + position_delta
	if correction.is_equal_approx(Transform3D.IDENTITY):
		return
	_attachment_updating = true
	female.global_transform = correction * female.global_transform
	_normalize_female_root_scale()
	_attachment_updating = false


func _normalize_female_root_scale() -> void:
	"""Remove tiny accidental root scale drift without changing the pose.

	Bone calibration and repeated transform composition can turn an intended
	rotation matrix into a basis with values such as (0.9997, 0.9982, 0.9994).
	Godot propagates that drift to IK_character/MainCollider and displays the
	"non-uniform scale" node warning. Orthonormalizing only the root basis keeps
	the current world position and orientation, leaves all bone poses untouched,
	and restores the collider's required uniform scale.
	"""
	var female := get_node_or_null("ManualCarryBlock/IK_character") as Node3D
	if female == null:
		return
	var current := female.global_transform
	var current_scale := current.basis.get_scale()
	if absf(current_scale.x - 1.0) < 0.0001 and \
			absf(current_scale.y - 1.0) < 0.0001 and \
			absf(current_scale.z - 1.0) < 0.0001:
		return
	current.basis = current.basis.orthonormalized()
	female.global_transform = current
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func _reset_pelvis_follow_filter() -> void:
	_follow_target_initialized = false
	_follow_target_in_carrier = Transform3D.IDENTITY

func _capture_secondary_baseline_if_needed() -> void:
	if not _secondary_baseline_initialized:
		capture_female_secondary_baseline()

func _apply_secondary_motion(delta: float) -> void:
	if not secondary_motion_enabled:
		return
	if Engine.is_editor_hint() and not preview_procedural_motion_in_editor:
		return
	var player := get_node_or_null("OTSCarryAnimationPlayer") as AnimationPlayer
	if player == null:
		return
	if not secondary_motion_when_stopped and not player.is_playing() and not _capture_fixed_step_active:
		return
	var skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	var male_skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	if skeleton == null or male_skeleton == null or not _secondary_baseline_initialized:
		return
	# The carried character supplies the bones being offset, but the carrier's
	# planted/lifted feet supply the gait rhythm that drives those offsets.
	var rhythm := _target_rhythm(player, male_skeleton)
	var rhythm_alpha := _lag_alpha(secondary_motion_lag_seconds, delta)
	_smoothed_rhythm = _smoothed_rhythm.lerp(rhythm, rhythm_alpha)
	var alternating := _smoothed_rhythm.x
	var bob := _smoothed_rhythm.y
	var left_swing := _smoothed_rhythm.z
	var right_swing := -left_swing
	_apply_bone_dangle(skeleton, &"LeftUpperLeg", leg_swing_axis, alternating * leg_swing_degrees)
	_apply_bone_dangle(skeleton, &"RightUpperLeg", leg_swing_axis, -alternating * leg_swing_degrees)
	_apply_bone_dangle(skeleton, &"LeftLowerLeg", knee_dangle_axis, left_swing * knee_dangle_degrees)
	_apply_bone_dangle(skeleton, &"RightLowerLeg", knee_dangle_axis, right_swing * knee_dangle_degrees)
	_apply_bone_dangle(skeleton, &"LeftFoot", foot_dangle_axis, left_swing * foot_dangle_degrees)
	_apply_bone_dangle(skeleton, &"RightFoot", foot_dangle_axis, right_swing * foot_dangle_degrees)
	_apply_bone_dangle(skeleton, &"LeftUpperArm", arm_swing_axis, left_swing * arm_swing_degrees)
	_apply_bone_dangle(skeleton, &"RightUpperArm", arm_swing_axis, right_swing * arm_swing_degrees)
	_apply_bone_dangle(skeleton, &"LeftLowerArm", forearm_dangle_axis, -left_swing * forearm_dangle_degrees)
	_apply_bone_dangle(skeleton, &"RightLowerArm", forearm_dangle_axis, -right_swing * forearm_dangle_degrees)
	_apply_bone_dangle(skeleton, &"Neck", head_sway_axis, alternating * head_sway_degrees)
	_apply_bone_dangle(skeleton, &"Head", head_nod_axis, bob * head_nod_degrees)
	_apply_spine_secondary_motion(skeleton, bob, alternating)
	skeleton.force_update_all_bone_transforms()

func _apply_bone_dangle(skeleton: Skeleton3D, bone_name: StringName, axis: Vector3, degrees: float) -> void:
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index < 0 or bone_index >= _female_secondary_baseline.size():
		return
	var baseline := _female_secondary_baseline[bone_index]
	skeleton.set_bone_pose(bone_index, baseline)
	if is_zero_approx(degrees) or axis.length_squared() < 0.000001:
		return
	var offset := Quaternion(axis.normalized(), deg_to_rad(degrees))
	var posed := baseline
	posed.basis = Basis(baseline.basis.get_rotation_quaternion() * offset)
	skeleton.set_bone_pose(bone_index, posed)

func _apply_spine_secondary_motion(skeleton: Skeleton3D, bob: float, alternating: float) -> void:
	# Spine receives two independent inertial components. Compose them before
	# writing the pose because _apply_bone_dangle intentionally resets each bone
	# to its captured baseline on every call; two separate calls would erase the
	# first component instead of producing a combined bob-and-roll response.
	var bone_index := skeleton.find_bone(&"Spine")
	if bone_index < 0 or bone_index >= _female_secondary_baseline.size():
		return
	var baseline := _female_secondary_baseline[bone_index]
	skeleton.set_bone_pose(bone_index, baseline)
	var rotation := Quaternion.IDENTITY
	if not is_zero_approx(torso_bob_degrees) and head_nod_axis.length_squared() >= 0.000001:
		rotation = rotation * Quaternion(head_nod_axis.normalized(), deg_to_rad(bob * torso_bob_degrees))
	if not is_zero_approx(spine_sway_degrees) and spine_sway_axis.length_squared() >= 0.000001:
		rotation = rotation * Quaternion(spine_sway_axis.normalized(), deg_to_rad(alternating * spine_sway_degrees))
	var posed := baseline
	posed.basis = Basis(baseline.basis.get_rotation_quaternion() * rotation.normalized())
	skeleton.set_bone_pose(bone_index, posed)

func _target_rhythm(player: AnimationPlayer, male_skeleton: Skeleton3D) -> Vector3:
	if rhythm_source == 1:
		var left_lift := _measure_foot_lift(male_skeleton, &"LeftFoot", 0)
		var right_lift := _measure_foot_lift(male_skeleton, &"RightFoot", 1)
		return Vector3(left_lift - right_lift, (left_lift + right_lift) * 0.5, left_lift - right_lift)
	var phase := gait_phase_offset
	if gait_cycle_seconds > 0.001:
		phase += TAU * fmod(player.current_animation_position, gait_cycle_seconds) / gait_cycle_seconds
	var left_swing := maxf(0.0, sin(phase))
	var right_swing := maxf(0.0, sin(phase + PI))
	return Vector3(left_swing - right_swing, sin(phase * 2.0), left_swing - right_swing)

func _measure_foot_lift(skeleton: Skeleton3D, bone_name: StringName, side: int) -> float:
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index < 0:
		return 0.0
	var world_foot := skeleton.global_transform * skeleton.get_bone_global_pose(bone_index)
	var plane_height := (world_foot.origin - _project_to_walk_plane(world_foot.origin, 0.0)).dot(_walk_plane_normal())
	if not bool(_male_foot_contact_baseline_initialized[side]):
		_male_foot_contact_baseline[side] = plane_height
		_male_foot_contact_baseline_initialized[side] = true
	else:
		# Learn the planted height as each foot first reaches the ground. A
		# separate initialized flag is required because a valid baseline can be
		# exactly zero on a level walk plane.
		_male_foot_contact_baseline[side] = minf(_male_foot_contact_baseline[side], plane_height)
	# A normal walk begins with at least one planted foot. Share the lowest
	# observed height across both sides so a foot that starts raised produces a
	# lift signal immediately instead of waiting for a complete first cycle.
	var shared_baseline := INF
	for baseline_side in 2:
		if bool(_male_foot_contact_baseline_initialized[baseline_side]):
			shared_baseline = minf(shared_baseline, _male_foot_contact_baseline[baseline_side])
	if is_finite(shared_baseline):
		for baseline_side in 2:
			if bool(_male_foot_contact_baseline_initialized[baseline_side]):
				_male_foot_contact_baseline[baseline_side] = minf(_male_foot_contact_baseline[baseline_side], shared_baseline)
	var baseline := _male_foot_contact_baseline[side]
	return clampf((plane_height - baseline - measured_foot_contact_height) / measured_foot_lift_height, 0.0, 1.0)

func _reset_secondary_rhythm() -> void:
	_smoothed_rhythm = Vector3.ZERO
	_male_foot_contact_baseline = Vector2.ZERO
	_male_foot_contact_baseline_initialized = [false, false]

func _lag_alpha(lag_seconds: float, delta: float) -> float:
	if lag_seconds <= 0.0001:
		return 1.0
	return 1.0 - exp(-maxf(delta, 0.0) / lag_seconds)

func _update_female_contact_markers() -> void:
	if not update_female_contact_markers:
		return
	var female_skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	if female_skeleton == null:
		return
	var pelvis_index := female_skeleton.find_bone(carried_pelvis_bone)
	var thigh_index := female_skeleton.find_bone(carried_thigh_bone)
	if pelvis_index < 0 or thigh_index < 0:
		return
	var anchors := get_node_or_null("CarryInteractionAnchors") as Node3D
	if anchors == null:
		return
	var pelvis_marker := anchors.get_node_or_null("FemalePelvisContact") as Marker3D
	var thigh_marker := anchors.get_node_or_null("FemaleThighContact") as Marker3D
	if pelvis_marker != null:
		pelvis_marker.global_transform = female_skeleton.global_transform * female_skeleton.get_bone_global_pose(pelvis_index) * female_pelvis_contact_offset
	if thigh_marker != null:
		thigh_marker.global_transform = female_skeleton.global_transform * female_skeleton.get_bone_global_pose(thigh_index) * female_thigh_contact_offset
	var carrier := get_node_or_null(carrier_root_path) as Node3D
	var right_pole := anchors.get_node_or_null("MaleRightArmPole") as Marker3D
	var pole := anchors.get_node_or_null("MaleLeftArmPole") as Marker3D
	if carrier != null and right_pole != null and right_hand_contact_pole_captured:
		right_pole.global_transform = carrier.global_transform * right_hand_contact_pole_offset
	if carrier != null and pole != null and left_hand_contact_pole_captured:
		pole.global_transform = carrier.global_transform * left_hand_contact_pole_offset

func _configure_hand_contact_ik() -> void:
	var right := get_node_or_null(right_hand_contact_modifier) as SkeletonModifier3D
	var left := get_node_or_null(left_hand_contact_modifier) as SkeletonModifier3D
	var right_orientation := get_node_or_null(right_hand_contact_orientation_modifier) as SkeletonModifier3D
	var left_orientation := get_node_or_null(left_hand_contact_orientation_modifier) as SkeletonModifier3D
	# Hand contact is an explicit interaction feature. Do not silently gate it
	# behind the broader secondary-motion preview switch: in the editor a user
	# may want only the carrier's hand solve while keeping female dangle motion
	# disabled. The hand-contact checkbox itself is the opt-in in that case.
	var preview_allowed := not Engine.is_editor_hint() or preview_procedural_motion_in_editor or hand_contact_ik_enabled
	if right != null:
		right.active = preview_allowed and hand_contact_ik_enabled and right_hand_contact_influence > 0.0
		right.influence = right_hand_contact_influence if preview_allowed and hand_contact_ik_enabled else 0.0
	if right_orientation != null:
		right_orientation.active = preview_allowed and hand_contact_ik_enabled and right_hand_contact_orientation_enabled and right_hand_contact_influence > 0.0
		right_orientation.influence = right_hand_contact_influence if preview_allowed and hand_contact_ik_enabled and right_hand_contact_orientation_enabled else 0.0
	if left != null:
		left.active = preview_allowed and hand_contact_ik_enabled and left_hand_contact_influence > 0.0
		left.influence = left_hand_contact_influence if preview_allowed and hand_contact_ik_enabled else 0.0
	if left_orientation != null:
		left_orientation.active = preview_allowed and hand_contact_ik_enabled and left_hand_contact_orientation_enabled and left_hand_contact_influence > 0.0
		left_orientation.influence = left_hand_contact_influence if preview_allowed and hand_contact_ik_enabled and left_hand_contact_orientation_enabled else 0.0

func _capture_editor_preview_baseline() -> void:
	var female := get_node_or_null("ManualCarryBlock/IK_character") as Node3D
	if female == null:
		return
	_editor_preview_baseline = female.global_transform
	_editor_preview_has_baseline = true
	var skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	if skeleton != null:
		_editor_preview_bone_baseline.clear()
		_editor_preview_bone_baseline.resize(skeleton.get_bone_count())
		for bone_index in skeleton.get_bone_count():
			_editor_preview_bone_baseline[bone_index] = skeleton.get_bone_pose(bone_index)
		# A preview should be additive to the pose that is visible when the user
		# enables it, not to a stale pose captured during scene construction.
		_female_secondary_baseline = _editor_preview_bone_baseline.duplicate()
		_secondary_baseline_initialized = true
		_editor_preview_has_bone_baseline = true

func _restore_editor_preview_baseline() -> void:
	if not _editor_preview_has_baseline and not _editor_preview_has_bone_baseline:
		return
	var female := get_node_or_null("ManualCarryBlock/IK_character") as Node3D
	if female != null:
		if _editor_preview_has_baseline:
			female.global_transform = _editor_preview_baseline
	var skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	if skeleton != null and _editor_preview_has_bone_baseline and \
			_editor_preview_bone_baseline.size() == skeleton.get_bone_count():
		for bone_index in skeleton.get_bone_count():
			skeleton.set_bone_pose(bone_index, _editor_preview_bone_baseline[bone_index])
		skeleton.force_update_all_bone_transforms()
	_editor_preview_has_baseline = false
	_editor_preview_has_bone_baseline = false
	_reset_pelvis_follow_filter()
	_reset_secondary_rhythm()

func _attachment_transforms() -> Dictionary:
	var male_skeleton := get_node_or_null("ManualCarryBlock/MaleCarrier/Skeleton3D") as Skeleton3D
	var carrier := get_node_or_null(carrier_root_path) as Node3D
	var female := get_node_or_null("ManualCarryBlock/IK_character") as Node3D
	var female_skeleton := get_node_or_null("ManualCarryBlock/IK_character/Skeleton3D") as Skeleton3D
	if male_skeleton == null or carrier == null or female == null or female_skeleton == null:
		return {}
	var shoulder_index := male_skeleton.find_bone(carrier_shoulder_bone)
	var pelvis_index := female_skeleton.find_bone(carried_pelvis_bone)
	if shoulder_index < 0 or pelvis_index < 0:
		return {}
	return {
		"carrier": carrier,
		"female": female,
		"shoulder": male_skeleton.global_transform * male_skeleton.get_bone_global_pose(shoulder_index),
		"pelvis": female_skeleton.global_transform * female_skeleton.get_bone_global_pose(pelvis_index),
	}

func _apply_carry_shot_visibility() -> void:
	var block := get_node_or_null("ManualCarryBlock")
	if block == null:
		return
	for node_name in HIDDEN_STAGE_NODES:
		var stage_node := block.get_node_or_null(NodePath(node_name)) as Node3D
		if stage_node != null:
			stage_node.visible = false
	var walk_controller := block.get_node_or_null("FemaleWalkController")
	if walk_controller != null:
		walk_controller.process_mode = Node.PROCESS_MODE_DISABLED
