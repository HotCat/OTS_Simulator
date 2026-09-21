extends SceneTree

const CameraMotionProgram = preload("res://scripts/editor_camera_motion_program.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var base := Transform3D(Basis.IDENTITY, Vector3(10.0, 2.0, 5.0))
	var motion = CameraMotionProgram.new()
	var result := motion.configure({
		"name": "regression",
		"commands": [
			{"kind": "g1", "to": [2.0, 0.0, -1.0], "duration": 2.0, "easing": "linear"},
			{"kind": "g4", "duration": 1.0},
			{"kind": "g5", "to": [4.0, 1.0, -2.0], "control1": [2.5, 0.0, -1.0], "control2": [3.5, 1.0, -2.0], "duration": 2.0, "easing": "linear"},
		],
	}, base)
	if not bool(result.get("ok", false)):
		_fail("program failed to compile")
		return
	var midpoint := (motion.sample(1.0) as Dictionary).get("transform") as Transform3D
	if midpoint.origin.distance_to(Vector3(11.0, 2.0, 4.5)) > 0.00001:
		_fail("linear midpoint is not relative to confirmed work zero")
		return
	var dwell := (motion.sample(2.5) as Dictionary).get("transform") as Transform3D
	if dwell.origin.distance_to(Vector3(12.0, 2.0, 4.0)) > 0.00001:
		_fail("dwell did not hold the preceding endpoint")
		return
	var final_sample := motion.sample(99.0) as Dictionary
	var final_transform := final_sample.get("transform") as Transform3D
	if final_transform.origin.distance_to(Vector3(14.0, 3.0, 3.0)) > 0.00001:
		_fail("Bezier did not finish at its absolute endpoint")
		return
	if not bool(final_sample.get("finished", false)):
		_fail("non-looping program did not report completion")
		return
	var orbit = CameraMotionProgram.new()
	orbit.configure({"commands": [{
		"kind": "g3", "yaw_degrees": 90.0, "pivot": [0.0, 0.0, 0.0],
		"duration": 1.0, "easing": "linear",
	}]}, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 2.0)))
	var orbit_end := (orbit.sample(1.0) as Dictionary).get("transform") as Transform3D
	if orbit_end.origin.distance_to(Vector3(2.0, 0.0, 0.0)) > 0.0001:
		_fail("counter-clockwise orbit endpoint is incorrect")
		return
	var looping = CameraMotionProgram.new()
	looping.configure({
		"loop": true,
		"commands": [{"kind": "g1", "to": [1.0, 0.0, 0.0], "duration": 1.0, "easing": "linear"}],
	}, Transform3D.IDENTITY)
	var wrapped := (looping.sample(1.5) as Dictionary).get("transform") as Transform3D
	if wrapped.origin.distance_to(Vector3(0.5, 0.0, 0.0)) > 0.00001:
		_fail("looping program did not wrap time")
		return
	print("Editor camera motion program regression passed")
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
