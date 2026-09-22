extends SceneTree

## Verify that the standalone editor-baked Jeep preserves the evaluated
## transforms from the coffee scene after the source street placement is
## neutralized.  This guards the workflow against a GLTF exporter succeeding
## while silently dropping editable-instance child overrides.

const SOURCE_SCENE := "res://demos/coffebar_female_walk_scene.tscn"
const SOURCE_JEEP_PATH := NodePath("CoffeeBarStreet/Jeep_Street_Instance")
const BAKED_GLB := "res://assets/models/vehicles/jeep_wrangler/jeep_wrangler_two_door_editor_baked.glb"

const CHECKED_NODES := [
	"SAM3D_Body",
	"SAM3D_Hood",
	"SAM3D_Door_L",
	"SAM3D_Door_R",
	"FrontBumper_Center",
	"FrontBumper_Wing_L",
	"FrontBumper_Wing_R",
	"FrontSkid",
	"RearBumper",
	"Wheel_FL_Tire",
	"Wheel_RL_Tire",
]

# The manually overridden panels should round-trip almost exactly.  Rigid
# wheel meshes are bone-parented, so Blender -> glTF -> Godot can add a tiny
# float/bone-space reconstruction error without changing their useful rig or
# visible placement.
const DEFAULT_ORIGIN_TOLERANCE := 0.0005
const DEFAULT_ROTATION_TOLERANCE := 0.001
const ROUNDTRIP_TOLERANCES := {
	"Wheel_FL_Tire": Vector2(0.0015, 0.01),
	"Wheel_RL_Tire": Vector2(0.0015, 0.001),
}
const REQUIRED_RIG_BONES := [
	"Door_L", "Door_R", "Hood", "Tailgate", "RearGlass",
	"Axle_Front", "Axle_Rear", "Knuckle_FL", "Knuckle_FR",
]


func _init() -> void:
	call_deferred("_verify")


func _verify() -> void:
	var source_packed := load(SOURCE_SCENE) as PackedScene
	var baked_packed := load(BAKED_GLB) as PackedScene
	if source_packed == null or baked_packed == null:
		_fail("Source scene or baked GLB could not be loaded")
		return

	var source_root := source_packed.instantiate()
	root.add_child(source_root)
	var source_jeep := source_root.get_node(SOURCE_JEEP_PATH) as Node3D
	source_jeep.transform = Transform3D.IDENTITY

	var baked_root := baked_packed.instantiate() as Node3D
	root.add_child(baked_root)
	baked_root.transform = Transform3D.IDENTITY

	var failures := 0
	for node_name in CHECKED_NODES:
		var source_node := source_jeep.find_child(node_name, true, false) as Node3D
		var baked_node := baked_root.find_child(node_name, true, false) as Node3D
		if source_node == null or baked_node == null:
			push_error("Missing comparison node: %s" % node_name)
			failures += 1
			continue
		var source_relative := source_jeep.global_transform.affine_inverse() * source_node.global_transform
		var baked_relative := baked_root.global_transform.affine_inverse() * baked_node.global_transform
		var origin_error := source_relative.origin.distance_to(baked_relative.origin)
		var rotation_error := source_relative.basis.get_rotation_quaternion().angle_to(
			baked_relative.basis.get_rotation_quaternion()
		)
		var tolerances: Vector2 = ROUNDTRIP_TOLERANCES.get(
			node_name,
			Vector2(DEFAULT_ORIGIN_TOLERANCE, DEFAULT_ROTATION_TOLERANCE)
		)
		if origin_error > tolerances.x or rotation_error > tolerances.y:
			push_error("Transform mismatch %s: origin=%f m rotation=%f rad" % [
				node_name, origin_error, rotation_error
			])
			failures += 1
		else:
			print("PASS transform ", node_name, " origin_error=", origin_error,
				" rotation_error=", rotation_error)

	var source_skeleton := _find_first_skeleton(source_jeep)
	var baked_skeleton := _find_first_skeleton(baked_root)
	if source_skeleton == null or baked_skeleton == null:
		push_error("Skeleton3D missing after bake")
		_print_typed_tree(baked_root)
		failures += 1
	elif source_skeleton.get_bone_count() != baked_skeleton.get_bone_count():
		push_error("Skeleton bone count changed: %d -> %d" % [
			source_skeleton.get_bone_count(), baked_skeleton.get_bone_count()
		])
		failures += 1
	else:
		print("PASS skeleton_bones=", baked_skeleton.get_bone_count())
		for bone_name in REQUIRED_RIG_BONES:
			if baked_skeleton.find_bone(bone_name) < 0:
				push_error("Required reusable rig bone missing: %s" % bone_name)
				failures += 1
			else:
				print("PASS rig_bone=", bone_name)

	var front := baked_root.find_child("Wheel_FL_Tire", true, false) as Node3D
	var rear := baked_root.find_child("Wheel_RL_Tire", true, false) as Node3D
	if front != null and rear != null:
		var wheelbase := absf(front.global_position.z - rear.global_position.z)
		# GLTF's Y-up conversion maps Blender/Godot vehicle fore-aft to local Z.
		if absf(wheelbase - 2.44) > 0.01:
			push_error("Baked wheelbase changed: %f m" % wheelbase)
			failures += 1
		else:
			print("PASS wheelbase_m=", wheelbase)

	print("VERIFY_BAKED_JEEP failures=", failures)
	quit(0 if failures == 0 else 1)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)


func _find_first_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_first_skeleton(child)
		if found != null:
			return found
	return null


func _print_typed_tree(node: Node, indent := "") -> void:
	print(indent, node.name, " [", node.get_class(), "]")
	for child in node.get_children():
		_print_typed_tree(child, indent + "  ")
