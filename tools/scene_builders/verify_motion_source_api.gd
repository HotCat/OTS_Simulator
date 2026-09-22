extends SceneTree

## Focused regression check for stationary/external motion ownership during
## fixed-step camera capture.  The walk-cycle source remains the default.

const SCENE_PATH := "res://demos/coffebar_female_walk_scene.tscn"

func _init() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("Could not load working scene")
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	var controller := scene.get_node_or_null("FemaleWalkController")
	if controller == null:
		_fail("FemaleWalkController is missing")
		return
	var character := scene.get_node_or_null("IK_character") as Node3D
	if character == null:
		_fail("IK_character is missing")
		return

	var source_result := controller.call("editor_transport_set_motion_source", "stationary") as Dictionary
	if not bool(source_result.get("ok", false)):
		_fail("Could not select stationary motion source")
		return
	var before := character.global_transform
	controller.call("editor_capture_begin_fixed_step")
	controller.call("editor_capture_step_fixed", 1.0 / 24.0)
	controller.call("editor_capture_end_fixed_step", false)
	var after := character.global_transform
	if not before.is_equal_approx(after):
		_fail("Stationary source changed the character transform")
		return
	var status := controller.call("editor_transport_status") as Dictionary
	if status.get("motion_source", "") != "stationary":
		_fail("Status did not report stationary motion source")
		return

	var external_result := controller.call("editor_transport_set_motion_source", "external_pose") as Dictionary
	if not bool(external_result.get("ok", false)) or external_result.get("motion_source", "") != "external_pose":
		_fail("Could not select external_pose motion source")
		return
	print("VERIFY_MOTION_SOURCE_API_OK stationary_transform_preserved=true external_pose_selectable=true")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
