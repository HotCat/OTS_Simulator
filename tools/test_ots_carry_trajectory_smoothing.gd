extends SceneTree

const SCENE_PATH := "res://demos/ots_carry_clay_proxy.tscn"
const MAX_TANGENT_STEP_DEGREES := 18.0

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
	shot.trajectory_corner_smoothing = 0.7
	shot.trajectory_samples_per_segment = 10
	shot._rebuild_carrier_trajectory()
	var points: Array = shot._trajectory_points
	if points.size() < 6:
		_fail("Expected a sampled smoothed route, got %d points" % points.size())
		return
	var worst_turn := 0.0
	for index in range(1, points.size() - 1):
		var incoming: Vector3 = (points[index] - points[index - 1]).normalized()
		var outgoing: Vector3 = (points[index + 1] - points[index]).normalized()
		if incoming.length_squared() < 0.0001 or outgoing.length_squared() < 0.0001:
			continue
		worst_turn = maxf(worst_turn, rad_to_deg(incoming.angle_to(outgoing)))
	if worst_turn > MAX_TANGENT_STEP_DEGREES:
		_fail("Smoothed route still has %.2f degree tangent step" % worst_turn)
		return
	print("OTS_CARRY_TRAJECTORY_SMOOTHING_TEST_OK samples=%d worst_tangent_step=%.3f" % [points.size(), worst_turn])
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
