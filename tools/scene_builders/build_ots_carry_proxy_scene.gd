extends SceneTree

## Build a reusable OTS carry blocking scene from the manually posed rig.
## The character instances and their authored bone overrides are taken from
## my_manual_rig_pose.tscn. The old mannequin stage, obstacles, and Jeep are
## intentionally omitted; the clay coffee-bar street is the only environment.

const SOURCE_SCENE := "res://demos/my_manual_rig_pose.tscn"
const STREET_SCENE := "res://assets/environments/coffebar_street/coffebar_street_clay_proxy.glb"
const OUTPUT_SCENE := "res://demos/ots_carry_clay_proxy.tscn"
const ROOT_SCRIPT := "res://scripts/ots_carry_proxy_scene.gd"
const CARRIER_CYCLE_LIBRARY := "res://animations/ots_carry_walk_cycle.tres"
const CARRIER_CYCLE_NAME := &"ots_carry_walk_cycle"

func _init() -> void:
	call_deferred("_build")

func _build() -> void:
	var source_packed := load(SOURCE_SCENE) as PackedScene
	if source_packed == null:
		_fail("Could not load manual pose scene: %s" % SOURCE_SCENE)
		return
	var source_root := source_packed.instantiate() as Node3D
	if source_root == null:
		_fail("Manual pose scene did not instantiate as Node3D")
		return

	var carry_root := Node3D.new()
	carry_root.name = "OTSCarryClayProxy"
	carry_root.editor_description = "Render-agnostic over-the-shoulder carry blocking. ManualCarryBlock preserves the authored skin/skeleton bindings."
	carry_root.set_meta("source_manual_pose_scene", SOURCE_SCENE)
	carry_root.set_meta("street_proxy_scene", STREET_SCENE)
	carry_root.set_meta("interaction_mode", "ots_carry")
	carry_root.set_script(load(ROOT_SCRIPT))
	carry_root.set("preview_female_attachment_in_editor", true)
	carry_root.set("follow_shoulder_rotation", true)
	carry_root.set("preview_procedural_motion_in_editor", true)
	carry_root.set("rhythm_source", 1)
	carry_root.add_child(source_root)
	source_root.name = "ManualCarryBlock"
	# Keep the manual scene as an intact nested instance. Flattening imported
	# GLB children into this scene duplicates Skeleton3D/skin nodes and causes
	# the visible mesh to use a different bind transform than the editor rig.
	source_root.owner = carry_root
	var male := source_root.get_node_or_null("MaleCarrier") as Node3D
	var female := source_root.get_node_or_null("IK_character") as Node3D
	var controls := source_root.get_node_or_null("PoseControls") as Node3D
	var camera := source_root.get_node_or_null("Camera3D") as Camera3D
	if male == null or female == null or controls == null:
		_fail("Manual scene is missing MaleCarrier, IK_character, or PoseControls")
		return
	female.set_meta("interaction_role", "female_carried")
	# Disable the old staging geometry while retaining the authored environment
	# light, camera, controls, and character bindings inside the nested scene.
	if camera != null:
		camera.current = true

	var street_packed := load(STREET_SCENE) as PackedScene
	if street_packed == null:
		_fail("Could not load clay street scene: %s" % STREET_SCENE)
		return
	var street := street_packed.instantiate() as Node3D
	if street == null:
		_fail("Clay street scene did not instantiate as Node3D")
		return
	street.name = "CoffeeBarStreet_Clay_Proxy"
	street.editor_description = "Monochrome CoffeeBarStreet clay proxy for this shot; the vehicle proxy is intentionally omitted."
	carry_root.add_child(street)
	street.owner = carry_root

	var walk_plane := Marker3D.new()
	walk_plane.name = "CarrierWalkPlane"
	walk_plane.editor_description = "Walkable plane used by the carrier trajectory. Its local Y axis is the plane normal."
	walk_plane.gizmo_extents = 0.35
	carry_root.add_child(walk_plane)
	walk_plane.owner = carry_root

	var trajectory := Node3D.new()
	trajectory.name = "CarrierTrajectory"
	trajectory.editor_description = "Editable carrier route. Drag the ordered waypoint markers; the controller projects them onto CarrierWalkPlane."
	trajectory.set_meta("walk_trajectory", true)
	carry_root.add_child(trajectory)
	trajectory.owner = carry_root
	_add_trajectory_waypoint(trajectory, "Waypoint_00", Vector3(-1.3950183, 0.0, 0.68233526), carry_root)
	_add_trajectory_waypoint(trajectory, "Waypoint_01", Vector3(-1.744, 0.0, -7.31), carry_root)
	_add_trajectory_waypoint(trajectory, "Waypoint_02", Vector3(-2.093, 0.0, -15.302), carry_root)
	_add_trajectory_waypoint(trajectory, "Waypoint_03", Vector3(-2.442, 0.0, -23.294), carry_root)
	_add_trajectory_waypoint(trajectory, "Waypoint_04", Vector3(-2.791, 0.0, -31.286), carry_root)
	_add_trajectory_waypoint(trajectory, "Waypoint_05", Vector3(-3.140, 0.0, -39.278), carry_root)
	_add_trajectory_waypoint(trajectory, "Waypoint_06", Vector3(-3.489, 0.0, -47.270), carry_root)
	_add_trajectory_waypoint(trajectory, "Waypoint_07", Vector3(-3.838, 0.0, -55.262), carry_root)

	var cycle_library := load(CARRIER_CYCLE_LIBRARY) as AnimationLibrary
	if cycle_library == null or not cycle_library.has_animation(CARRIER_CYCLE_NAME):
		_fail("Could not load carrier cycle: %s" % CARRIER_CYCLE_LIBRARY)
		return
	var animation_player := AnimationPlayer.new()
	animation_player.name = "OTSCarryAnimationPlayer"
	animation_player.editor_description = "Infinite male-only OTS gait. The trajectory owns world translation and heading."
	animation_player.add_animation_library(&"", cycle_library)
	animation_player.autoplay = CARRIER_CYCLE_NAME
	carry_root.add_child(animation_player)
	animation_player.owner = carry_root

	var anchors := Node3D.new()
	anchors.name = "CarryInteractionAnchors"
	anchors.editor_description = "Named world-space contacts for the carry solve and later gait migration."
	carry_root.add_child(anchors)
	anchors.owner = carry_root
	anchors.owner = carry_root
	_add_anchor(anchors, "MaleShoulderAnchor", "Primary shoulder support contact for the carried torso.")
	_add_anchor(anchors, "MaleSupportHandAnchor", "Carrier hand contact under the carried thigh.")
	_add_anchor(anchors, "MaleStabilizingHandAnchor", "Carrier hand contact at the carried waist or hip.")
	_add_anchor(anchors, "FemaleTorsoContact", "Carried abdomen/ribcage contact against the shoulder.")
	_add_anchor(anchors, "FemalePelvisContact", "Carried pelvis support reference.")
	_add_anchor(anchors, "FemaleThighContact", "Carried thigh contact for the supporting hand.")
	_add_anchor(anchors, "GaitRoot", "Shared root for migrated loaded-walk motion.")
	_assign_owner(anchors, carry_root)

	var controller := Node.new()
	controller.name = "CarryInteractionController"
	controller.editor_description = "Interaction evaluation order: male root and feet, contact anchors, carried root, then secondary wobble."
	controller.set_meta("evaluation_order", "male_gait > contacts > carried_root > secondary_wobble")
	controller.set_meta("male_character_path", NodePath("ManualCarryBlock/MaleCarrier"))
	controller.set_meta("female_character_path", NodePath("ManualCarryBlock/IK_character"))
	controller.set_meta("camera_path", NodePath("ManualCarryBlock/Camera3D"))
	controller.set_meta("environment_path", NodePath("ManualCarryBlock/env/WorldEnvironment"))
	controller.set_meta("key_light_path", NodePath("ManualCarryBlock/env/DirectionalLight3D"))
	carry_root.add_child(controller)
	controller.owner = carry_root

	# PackedScene.pack only serializes nodes owned by the packed root. The
	# source instances were reparented at runtime, so explicitly assign the
	# new ownership tree before saving the reusable scene.
	var packed := PackedScene.new()
	var pack_error := packed.pack(carry_root)
	if pack_error != OK:
		_fail("Could not pack OTS carry scene: %s" % error_string(pack_error))
		return
	var save_error := ResourceSaver.save(packed, OUTPUT_SCENE)
	if save_error != OK:
		_fail("Could not save OTS carry scene: %s" % error_string(save_error))
		return
	print("OTS_CARRY_PROXY_OK")
	print("output=", OUTPUT_SCENE)
	print("street=", STREET_SCENE)
	print("male=ManualCarryBlock/MaleCarrier female=ManualCarryBlock/IK_character anchors=7")
	quit(0)

func _add_anchor(parent: Node3D, anchor_name: String, description: String) -> void:
	var marker := Marker3D.new()
	marker.name = anchor_name
	marker.editor_description = description
	marker.gizmo_extents = 0.12
	parent.add_child(marker)

func _add_trajectory_waypoint(parent: Node3D, waypoint_name: String, point: Vector3, scene_owner: Node) -> void:
	var waypoint := Marker3D.new()
	waypoint.name = waypoint_name
	waypoint.position = point
	waypoint.gizmo_extents = 0.24
	waypoint.set_meta("trajectory_waypoint", true)
	parent.add_child(waypoint)
	waypoint.owner = scene_owner

func _assign_owner(node: Node, scene_owner: Node) -> void:
	for child in node.get_children():
		child.owner = scene_owner
		_assign_owner(child, scene_owner)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
