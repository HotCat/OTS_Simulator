extends SceneTree

const SCENE_PATH := "res://demos/ots_carry_clay_proxy.tscn"
const MAX_RIGID_TRANSPORT_ERROR_METERS := 0.0001

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("Could not load %s" % SCENE_PATH)
		return
	var shot := packed.instantiate() as Node3D
	root.add_child(shot)
	await process_frame

	var player := shot.get_node_or_null("OTSCarryAnimationPlayer") as AnimationPlayer
	if player != null:
		player.stop()
	shot.carrier_trajectory_enabled = false
	shot.secondary_motion_enabled = false
	shot.follow_shoulder_rotation = true
	shot.pelvis_position_lag_seconds = 0.5
	shot.pelvis_rotation_lag_seconds = 0.5
	shot.calibrate_female_pelvis_attachment()
	shot._apply_female_pelvis_attachment(1.0 / 60.0)

	var carrier := shot.get_node("ManualCarryBlock/MaleCarrier") as Node3D
	var worst_error := 0.0
	for frame in 30:
		# Move and turn the complete carrier root. Even with deliberately large
		# shoulder lag, this rigid path motion must not pull the carried pelvis
		# away from its calibrated contact point.
		carrier.global_position += Vector3(0.025, 0.0, 0.0125)
		carrier.rotate_y(deg_to_rad(0.5))
		shot._apply_female_pelvis_attachment(1.0 / 60.0)
		var transforms := shot._attachment_transforms() as Dictionary
		var expected: Transform3D = (transforms.shoulder as Transform3D) * shot.female_pelvis_in_shoulder
		var actual: Transform3D = transforms.pelvis as Transform3D
		worst_error = maxf(worst_error, actual.origin.distance_to(expected.origin))

	if worst_error > MAX_RIGID_TRANSPORT_ERROR_METERS:
		_fail("Rigid carrier transport left %.6f m of pelvis error" % worst_error)
		return
	print("OTS_CARRY_ATTACHMENT_TEST_OK rigid_transport_error=%.8f" % worst_error)
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
