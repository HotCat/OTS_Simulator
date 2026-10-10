@tool
extends EditorScenePostImport

## Blender's glTF exporter drops Godot's single-root and physics extensions.
## Recreate the Humanizer root contract so existing Skeleton3D, collider,
## scene override, and animation paths keep working.

const MODEL_ROOT := "female_1791377232602_humanizer_proxy_Humanizer_RealtimeProxy"

func _post_import(scene: Node) -> Object:
	var model := scene.get_node_or_null(NodePath(MODEL_ROOT))
	if model == null or model.get_node_or_null("Skeleton3D") == null:
		push_error("CPR female import: expected Humanizer root and Skeleton3D were not found")
		return scene
	var character := AnimatableBody3D.new()
	character.name = MODEL_ROOT
	character.transform = model.transform
	character.sync_to_physics = false
	for child_name in ["Skeleton3D", "_PhysicalBoneSimulator3D_2", "AnimationTree"]:
		var child := model.get_node_or_null(NodePath(child_name))
		if child != null:
			model.remove_child(child)
			child.owner = null
			character.add_child(child)
	var old_collider := model.get_node_or_null("MainCollider") as Node3D
	var collider := CollisionShape3D.new()
	collider.name = "MainCollider"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.29587996
	capsule.height = 1.92749417
	collider.shape = capsule
	if old_collider != null:
		collider.transform = old_collider.transform
	character.add_child(collider)
	_assign_owner(character, character)
	scene.free()
	return character

func _assign_owner(parent: Node, root: Node) -> void:
	for child in parent.get_children():
		child.owner = root
		_assign_owner(child, root)
