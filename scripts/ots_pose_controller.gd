@tool
extends Node3D

## Manual posing helper for the Mixamo-style mannequin.
## It resets the imported armature to its exact rest T-pose, disables modifiers
## that would fight manual edits, and distributes a waist bend over four bones.

const MIXAMO_WAIST_BONES: Array[String] = [
	"mixamorig_Hips",
	"mixamorig_Spine",
	"mixamorig_Spine1",
	"mixamorig_Spine2",
]
const HUMANOID_WAIST_BONES: Array[String] = ["Hips", "Spine", "Chest", "UpperChest"]
const WAIST_WEIGHTS := [0.12, 0.30, 0.32, 0.26]
const BODY_MODIFIERS := [&"pelvis_control", &"center_back_ik", &"neck_ik"]
const LIMB_IK_MODIFIERS := [&"r_leg", &"l_leg", &"r_arm", &"l_arm"]

@export_category("Manual OTS Pose")
@export var manual_pose_enabled := false:
	set(value):
		manual_pose_enabled = value
		_queue_pose_refresh(true)

@export_range(-110.0, 110.0, 1.0, "degrees") var waist_bend_degrees := 0.0:
	set(value):
		waist_bend_degrees = value
		_queue_pose_refresh(false)

@export_range(-60.0, 60.0, 1.0, "degrees") var waist_side_bend_degrees := 0.0:
	set(value):
		waist_side_bend_degrees = value
		_queue_pose_refresh(false)

@export_range(-90.0, 90.0, 1.0, "degrees") var waist_twist_degrees := 0.0:
	set(value):
		waist_twist_degrees = value
		_queue_pose_refresh(false)

@export_category("Modifier State")
@export var body_ik_enabled := false:
	set(value):
		body_ik_enabled = value
		_queue_modifier_refresh()

@export var limb_ik_enabled := false:
	set(value):
		limb_ik_enabled = value
		_queue_modifier_refresh()

@export_category("Pose Actions")
@export_tool_button("Reset armature to T-pose") var reset_t_pose_action: Callable = reset_to_t_pose
@export_tool_button("Apply waist bend") var apply_waist_action: Callable = apply_waist_bend
@export_tool_button("Apply proxy forward drape") var apply_forward_drape_action: Callable = apply_proxy_forward_drape
@export_tool_button("Restore proxy control markers") var restore_markers_action: Callable = restore_proxy_control_layout
@export_tool_button("Bake current IK pose to bones") var bake_ik_action: Callable = bake_current_ik_pose_to_bones
@export_tool_button("Commit current FK adjustments for saving") var commit_fk_action: Callable = commit_current_fk_pose_for_saving

@export_category("Pose Mode Status")
@export_multiline var pose_mode_status := "Target-driven IK mode":
	set(value):
		pose_mode_status = value
		if is_inside_tree():
			notify_property_list_changed()

# A controller-owned copy is more reliable than relying only on overrides of
# bone properties inside an imported GLB instance. It is intentionally hidden
# from the Inspector because 56 Transform3D entries would obscure the controls.
@export_storage var saved_fk_pose: Array[Transform3D] = []

var _pose_refresh_queued := false
var _modifier_refresh_queued := false
var _full_reset_requested := false
var _bake_capture_pending := false
var _captured_bone_globals: Array[Transform3D] = []
var _fk_capture_queued := false
var _suppress_fk_capture := false
var _external_pose_preview_depth := 0

func _ready() -> void:
	var skeleton := _get_skeleton()
	if skeleton != null:
		_restore_saved_fk_pose(skeleton)
		var pose_callable := Callable(self, "_on_skeleton_pose_updated")
		if not skeleton.pose_updated.is_connected(pose_callable):
			skeleton.pose_updated.connect(pose_callable)
	if manual_pose_enabled:
		_queue_pose_refresh(true)

func reset_to_t_pose() -> void:
	manual_pose_enabled = true
	waist_bend_degrees = 0.0
	waist_side_bend_degrees = 0.0
	waist_twist_degrees = 0.0
	body_ik_enabled = false
	limb_ik_enabled = false
	pose_mode_status = "T-pose / FK mode (all IK modifiers disabled)"
	restore_proxy_control_layout()
	_queue_pose_refresh(true)

func apply_waist_bend() -> void:
	manual_pose_enabled = true
	body_ik_enabled = false
	limb_ik_enabled = false
	pose_mode_status = "Manual waist FK mode (all IK modifiers disabled)"
	_queue_pose_refresh(false)

func apply_proxy_forward_drape() -> void:
	var skeleton := _get_skeleton()
	if skeleton == null or skeleton.find_bone("Hips") < 0:
		return
	manual_pose_enabled = true
	waist_bend_degrees = 0.0
	waist_side_bend_degrees = 0.0
	waist_twist_degrees = 0.0
	body_ik_enabled = true
	limb_ik_enabled = true
	pose_mode_status = "Target-driven forward-drape IK mode"
	var controls := get_node_or_null("../PoseControls") as Node3D
	if controls == null:
		return
	_set_control_transform(controls, "pelvis_target", Vector3(-0.12, 1.42, 0.12))
	_set_control_transform(controls, "center_back_target", Vector3(-0.04, 1.26, 0.38))
	_set_control_transform(controls, "neck_target", Vector3(-0.02, 0.92, 0.92))
	_set_control_transform(controls, "r_arm_marker", Vector3(-0.24, 0.62, 1.02))
	_set_control_transform(controls, "l_arm_marker", Vector3(0.24, 0.54, 1.12))
	_queue_pose_refresh(true)

func restore_proxy_control_layout() -> void:
	var controls := get_node_or_null("../PoseControls") as Node3D
	if controls == null:
		return
	_set_control_transform(controls, "pelvis_target", Vector3(-0.12, 1.42, 0.12))
	_set_control_transform(controls, "center_back_target", Vector3(-0.04, 1.26, 0.38))
	_set_control_transform(controls, "neck_target", Vector3(-0.02, 0.92, 0.92))
	_set_control_transform(controls, "r_feet_marker", Vector3(-0.24, 0.08, -0.26))
	_set_control_transform(controls, "r_feet_pole", Vector3(-0.21, 0.77, 0.95))
	_set_control_transform(controls, "l_feet_marker", Vector3(0.10, 0.08, -0.18))
	_set_control_transform(controls, "l_feet_pole", Vector3(0.34, 0.79, 0.60))
	_set_control_transform(controls, "r_arm_marker", Vector3(-0.24, 0.62, 1.02))
	_set_control_transform(controls, "r_arm_pole", Vector3(-0.47, 1.40, -0.52))
	_set_control_transform(controls, "l_arm_marker", Vector3(0.24, 0.54, 1.12))
	_set_control_transform(controls, "l_arm_pole", Vector3(0.42, 1.40, -0.42))
	_set_control_transform(controls, "head_target", Vector3(0.07, 1.78, 1.03))

func bake_current_ik_pose_to_bones() -> void:
	if _bake_capture_pending:
		return
	var skeleton := _get_skeleton()
	if skeleton == null:
		pose_mode_status = "Bake failed: Skeleton3D was not found"
		return
	_bake_capture_pending = true
	pose_mode_status = "Baking evaluated IK pose..."
	var last_active_modifier: SkeletonModifier3D = null
	for child in skeleton.get_children():
		if child is SkeletonModifier3D and (child as SkeletonModifier3D).active:
			last_active_modifier = child as SkeletonModifier3D
	if last_active_modifier == null:
		_capture_current_fk_pose_for_bake()
		return
	var capture_callable := Callable(self, "_capture_evaluated_pose_for_bake")
	if not last_active_modifier.modification_processed.is_connected(capture_callable):
		last_active_modifier.modification_processed.connect(capture_callable, CONNECT_ONE_SHOT)
	# Capture from the final active modifier. Skeleton3D.skeleton_updated is not
	# reliably emitted for a manually advanced @tool skeleton in the editor.
	skeleton.advance(0.0)
	call_deferred("_report_bake_capture_failure_if_pending")

func commit_current_fk_pose_for_saving() -> void:
	var skeleton := _get_skeleton()
	if skeleton == null:
		pose_mode_status = "FK commit failed: Skeleton3D was not found"
		return
	if _has_active_modifiers(skeleton):
		pose_mode_status = "FK commit skipped: IK is active; use Bake current IK pose to bones"
		return
	manual_pose_enabled = false
	body_ik_enabled = false
	limb_ik_enabled = false
	_capture_local_fk_pose(skeleton)
	pose_mode_status = "FK pose committed: %d bone adjustments saved; press Cmd+S" % skeleton.get_bone_count()
	_mark_scene_unsaved()

func begin_external_pose_preview() -> void:
	_external_pose_preview_depth += 1

func end_external_pose_preview() -> void:
	_external_pose_preview_depth = maxi(0, _external_pose_preview_depth - 1)

func _capture_current_fk_pose_for_bake() -> void:
	var skeleton := _get_skeleton()
	if skeleton == null:
		_bake_capture_pending = false
		pose_mode_status = "Bake failed: Skeleton3D disappeared during capture"
		return
	_captured_bone_globals.clear()
	for bone_idx in skeleton.get_bone_count():
		_captured_bone_globals.append(skeleton.get_bone_global_pose(bone_idx))
	call_deferred("_commit_baked_fk_pose")

func _capture_evaluated_pose_for_bake() -> void:
	var skeleton := _get_skeleton()
	if skeleton == null:
		_bake_capture_pending = false
		pose_mode_status = "Bake failed: Skeleton3D disappeared during capture"
		return
	_captured_bone_globals.clear()
	for bone_idx in skeleton.get_bone_count():
		_captured_bone_globals.append(skeleton.get_bone_global_pose(bone_idx))
	call_deferred("_commit_baked_fk_pose")

func _report_bake_capture_failure_if_pending() -> void:
	if not _bake_capture_pending or not _captured_bone_globals.is_empty():
		return
	_bake_capture_pending = false
	pose_mode_status = "Bake failed: modifier callback was not processed; reload the scene and try again"

func _commit_baked_fk_pose() -> void:
	var skeleton := _get_skeleton()
	if skeleton == null or _captured_bone_globals.size() != skeleton.get_bone_count():
		_bake_capture_pending = false
		pose_mode_status = "Bake failed: captured bone count did not match the skeleton"
		return

	# Baked FK is deliberately separate from both manual-waist and target IK
	# modes. Disable the controller first so no deferred refresh can rewrite the
	# captured bone rotations after they are committed.
	manual_pose_enabled = false
	body_ik_enabled = false
	limb_ik_enabled = false
	_pose_refresh_queued = false
	_modifier_refresh_queued = false
	_full_reset_requested = false
	for child in skeleton.get_children():
		if child is SkeletonModifier3D:
			(child as SkeletonModifier3D).active = false

	# set_bone_global_pose converts each captured skeleton-space transform back
	# into the local pose relative to its already-baked parent.
	_suppress_fk_capture = true
	skeleton.reset_bone_poses()
	for bone_idx in skeleton.get_bone_count():
		skeleton.set_bone_global_pose(bone_idx, _captured_bone_globals[bone_idx])
	skeleton.force_update_all_bone_transforms()
	_capture_local_fk_pose(skeleton)
	_suppress_fk_capture = false
	_bake_capture_pending = false
	pose_mode_status = "Baked FK mode: %d bone poses captured; all IK modifiers disabled" % skeleton.get_bone_count()
	_mark_scene_unsaved()

func _on_skeleton_pose_updated() -> void:
	if _external_pose_preview_depth > 0 or _suppress_fk_capture or _bake_capture_pending or manual_pose_enabled or not Engine.is_editor_hint():
		return
	var skeleton := _get_skeleton()
	if skeleton == null or _has_active_modifiers(skeleton) or _fk_capture_queued:
		return
	_fk_capture_queued = true
	call_deferred("_capture_edited_fk_pose")

func _capture_edited_fk_pose() -> void:
	_fk_capture_queued = false
	if _suppress_fk_capture or _bake_capture_pending or manual_pose_enabled:
		return
	var skeleton := _get_skeleton()
	if skeleton == null or _has_active_modifiers(skeleton):
		return
	_capture_local_fk_pose(skeleton)
	pose_mode_status = "FK bone adjustment captured: %d bones ready to save; press Cmd+S" % skeleton.get_bone_count()
	_mark_scene_unsaved()

func _capture_local_fk_pose(skeleton: Skeleton3D) -> void:
	var snapshot: Array[Transform3D] = []
	snapshot.resize(skeleton.get_bone_count())
	for bone_idx in skeleton.get_bone_count():
		snapshot[bone_idx] = skeleton.get_bone_pose(bone_idx)
	saved_fk_pose = snapshot

func _restore_saved_fk_pose(skeleton: Skeleton3D) -> void:
	if saved_fk_pose.size() != skeleton.get_bone_count():
		return
	_suppress_fk_capture = true
	for bone_idx in skeleton.get_bone_count():
		skeleton.set_bone_pose(bone_idx, saved_fk_pose[bone_idx])
	skeleton.force_update_all_bone_transforms()
	_suppress_fk_capture = false

func _has_active_modifiers(skeleton: Skeleton3D) -> bool:
	for child in skeleton.get_children():
		if child is SkeletonModifier3D and (child as SkeletonModifier3D).active:
			return true
	return false

func _mark_scene_unsaved() -> void:
	if Engine.is_editor_hint():
		EditorInterface.mark_scene_as_unsaved()

func _set_control_transform(controls: Node3D, control_name: String, control_position: Vector3) -> void:
	var control := controls.get_node_or_null(control_name) as Node3D
	if control == null:
		return
	control.position = control_position
	control.rotation = Vector3.ZERO

func _queue_pose_refresh(full_reset: bool) -> void:
	if not manual_pose_enabled or not is_inside_tree():
		return
	_full_reset_requested = _full_reset_requested or full_reset
	if _pose_refresh_queued:
		return
	_pose_refresh_queued = true
	call_deferred("_refresh_pose")

func _queue_modifier_refresh() -> void:
	if not manual_pose_enabled or not is_inside_tree() or _modifier_refresh_queued:
		return
	_modifier_refresh_queued = true
	call_deferred("_refresh_modifiers")

func _refresh_pose() -> void:
	_pose_refresh_queued = false
	if not manual_pose_enabled:
		return
	var skeleton := _get_skeleton()
	if skeleton == null:
		return
	_refresh_modifiers()
	if _full_reset_requested:
		skeleton.reset_bone_poses()
		_full_reset_requested = false
	_apply_waist_to_skeleton(skeleton)
	# Run the modifier stack immediately in the editor after an Inspector action.
	# Without this, the new target positions may not be visible until the next
	# editor/game update.
	skeleton.advance(0.0)

func _refresh_modifiers() -> void:
	_modifier_refresh_queued = false
	var skeleton := _get_skeleton()
	if skeleton == null:
		return
	for child in skeleton.get_children():
		if child is SkeletonModifier3D:
			if child.name in BODY_MODIFIERS:
				child.active = body_ik_enabled
			elif child.name in LIMB_IK_MODIFIERS:
				child.active = limb_ik_enabled
			else:
				# Gaze and hand-orientation helpers are intentionally off while
				# manually posing; they can otherwise pull a solved limb apart.
				child.active = false

func _apply_waist_to_skeleton(skeleton: Skeleton3D) -> void:
	var waist_bones := _get_waist_bones(skeleton)
	for bone_name in waist_bones:
		var bone_idx := skeleton.find_bone(bone_name)
		if bone_idx >= 0:
			skeleton.set_bone_pose_rotation(bone_idx, Quaternion.IDENTITY)

	for bone_number in waist_bones.size():
		var bone_name: String = waist_bones[bone_number]
		var weight: float = WAIST_WEIGHTS[bone_number]
		_set_skeleton_space_rotation(
			skeleton,
			bone_name,
			Vector3(
				waist_bend_degrees * weight,
				waist_twist_degrees * weight,
				waist_side_bend_degrees * weight
			)
		)

func _set_skeleton_space_rotation(skeleton: Skeleton3D, bone_name: String, degrees_xyz: Vector3) -> void:
	var bone_idx := skeleton.find_bone(bone_name)
	if bone_idx < 0:
		return
	var radians := Vector3(
		deg_to_rad(degrees_xyz.x),
		deg_to_rad(degrees_xyz.y),
		deg_to_rad(degrees_xyz.z)
	)
	var global_rest := skeleton.get_bone_global_rest(bone_idx)
	var skeleton_delta := Basis.from_euler(radians)
	var local_delta := global_rest.basis.inverse() * skeleton_delta * global_rest.basis
	skeleton.set_bone_pose_rotation(bone_idx, local_delta.get_rotation_quaternion())

func _get_skeleton() -> Skeleton3D:
	var skeleton := get_node_or_null("Armature/Skeleton3D") as Skeleton3D
	if skeleton == null:
		skeleton = get_node_or_null("Skeleton3D") as Skeleton3D
	return skeleton

func _get_waist_bones(skeleton: Skeleton3D) -> Array[String]:
	if skeleton.find_bone("mixamorig_Hips") >= 0:
		return MIXAMO_WAIST_BONES
	return HUMANOID_WAIST_BONES
