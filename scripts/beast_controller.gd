extends MeshInstance3D

@export var rotation_speed := 40
@export var movement_speed := 3

func _process(delta: float) -> void:
	var input_dir := Vector2.ZERO
	if not _is_gui_input_focused():
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	position += -basis.z * input_dir.y * delta * movement_speed
	rotation.y += deg_to_rad(-input_dir.x * delta * rotation_speed)

func _is_gui_input_focused() -> bool:
	return get_viewport().gui_get_focus_owner() != null
	
