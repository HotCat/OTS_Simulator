extends SceneTree

const COMPARISON_PATH := "res://assets/models/female_1791377232602/female_1791377232602.tscn"


func _initialize() -> void:
	call_deferred("_verify")


func _verify() -> void:
	var packed := load(COMPARISON_PATH) as PackedScene
	if packed == null:
		_fail("Could not load comparison scene")
		return
	var comparison := packed.instantiate() as Node3D
	root.add_child(comparison)
	var current := comparison.get_node_or_null("Current_OTS_Female_About_180cm") as Node3D
	var added := comparison.get_node_or_null("New_Female_190cm") as Node3D
	if current == null or added == null:
		_fail("One or both comparison actors are missing")
		return
	if not is_equal_approx(current.position.x, -1.0) or not is_equal_approx(added.position.x, 1.0):
		_fail("Comparison actors are not at the intended separation")
		return
	if current.scale != Vector3.ONE or added.scale != Vector3.ONE:
		_fail("Comparison actors have unequal/non-unit scaling")
		return
	var current_skeleton := current.find_child("Skeleton3D", true, false) as Skeleton3D
	var new_skeleton := added.find_child("Skeleton3D", true, false) as Skeleton3D
	if current_skeleton == null or new_skeleton == null:
		_fail("One or both skeletons are missing")
		return
	print("FEMALE_COMPARISON_OK current_bones=", current_skeleton.get_bone_count(),
		" new_bones=", new_skeleton.get_bone_count(),
		" separation_m=", added.position.x - current.position.x,
		" scales=", current.scale, "/", added.scale)
	quit(0)


func _fail(message: String) -> void:
	push_error("FEMALE_COMPARISON_FAILED: " + message)
	quit(1)
