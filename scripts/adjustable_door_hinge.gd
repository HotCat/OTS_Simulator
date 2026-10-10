@tool
extends Node3D

## Door leaves are separate imported scenes. The hinge's own transform locates
## the doorway; only its Leaf child rotates, so both doors can be tuned safely
## in the editor without altering the architectural shell.
@export_range(0.0, 120.0, 1.0, "degrees") var opening_angle_degrees := 0.0:
	set(value):
		opening_angle_degrees = clampf(value, 0.0, 120.0)
		_apply_opening_angle()

func _ready() -> void:
	_apply_opening_angle()

func _apply_opening_angle() -> void:
	var leaf := get_node_or_null("Leaf") as Node3D
	if leaf != null:
		leaf.rotation_degrees.y = opening_angle_degrees
