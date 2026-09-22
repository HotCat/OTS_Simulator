@tool
extends SceneTree

## Deterministically assembles the coffee-bar street and the complete female
## editor rig copied from my_manual_rig_pose.tscn. The female subtree is
## flattened into the new scene so per-bone Skeleton3D overrides, IK modifier
## settings, saved FK state, walk markers, and controller tuning are retained.

const SOURCE_SCENE := "res://demos/my_manual_rig_pose.tscn"
const STREET_SCENE := "res://assets/environments/coffebar_street/coffebar_street_with_jeep.glb"
const OUTPUT_SCENE := "res://demos/coffebar_female_walk_scene.tscn"

const FEMALE_ROOT_NODES := [
	"PoseControls",
	"IK_character",
	"FemaleWalkTrajectory",
	"FemaleWalkAnimationPlayer",
	"FemaleWalkController",
]


func _init() -> void:
	call_deferred("_build")


func _build() -> void:
	var source_resource := load(SOURCE_SCENE) as PackedScene
	var street_resource := load(STREET_SCENE) as PackedScene
	if source_resource == null:
		_fail("Cannot load source scene: %s" % SOURCE_SCENE)
		return
	if street_resource == null:
		_fail("Cannot load imported street scene: %s" % STREET_SCENE)
		return

	var source_root := source_resource.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var output_root := Node3D.new()
	output_root.name = "CoffeeBarFemaleWalkScene"
	output_root.editor_description = (
		"Bicycle-free coffee-bar street with the rigged two-door Jeep and the "
		+ "complete female editor rig migrated from my_manual_rig_pose.tscn."
	)
	output_root.set_meta("female_rig_source", SOURCE_SCENE)
	output_root.set_meta("street_asset_source", STREET_SCENE)
	output_root.set_meta("migration_note", "Source-exact female pose, 56-bone overrides, IK controls, walk trajectory, animations, and controller tuning")

	var street := street_resource.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	street.name = "CoffeeBarStreet"
	street.set_meta("contains_custom_two_door_jeep", true)
	street.set_meta("bicycle_free_frontage", true)
	output_root.add_child(street)
	street.owner = output_root
	output_root.set_editable_instance(street, true)

	# DUPLICATE_USE_INSTANTIATION is deliberately omitted. Flattening the
	# configured IK_character preserves its editable Skeleton3D child overrides
	# instead of recreating a clean GLB instance and losing the active pose.
	var duplicate_flags := (
		Node.DUPLICATE_SIGNALS
		| Node.DUPLICATE_GROUPS
		| Node.DUPLICATE_SCRIPTS
	)
	for node_name in FEMALE_ROOT_NODES:
		var source_node := source_root.get_node_or_null(NodePath(node_name))
		if source_node == null:
			source_root.free()
			output_root.free()
			_fail("Missing required female node in source: %s" % node_name)
			return
		var copied_node := source_node.duplicate(duplicate_flags)
		if copied_node == null:
			source_root.free()
			output_root.free()
			_fail("Could not duplicate required female node: %s" % node_name)
			return
		# duplicate() retains the imported GLB scene_file_path even when
		# DUPLICATE_USE_INSTANTIATION is omitted. If the copied descendants are
		# then owned by the new scene, PackedScene writes both an instance and a
		# second local Skeleton3D subtree. The editor correctly rejects those
		# duplicate paths. Clearing the path makes this one self-contained local
		# rig, which is exactly what migration of all bone/IK overrides requires.
		if node_name == "IK_character":
			copied_node.scene_file_path = ""
		copied_node.name = node_name
		output_root.add_child(copied_node)
		_set_owner_recursive(copied_node, output_root)

	_add_environment(output_root)
	_add_street_lighting(output_root)
	_add_runtime_camera(output_root)

	var packed := PackedScene.new()
	var pack_error := packed.pack(output_root)
	if pack_error != OK:
		source_root.free()
		output_root.free()
		_fail("PackedScene.pack failed: %s" % error_string(pack_error))
		return
	var save_error := ResourceSaver.save(packed, OUTPUT_SCENE)
	if save_error != OK:
		source_root.free()
		output_root.free()
		_fail("ResourceSaver.save failed: %s" % error_string(save_error))
		return

	print("BUILT_SCENE=", OUTPUT_SCENE)
	print("COPIED_FEMALE_NODES=", ",".join(FEMALE_ROOT_NODES))
	print("STREET_SCENE=", STREET_SCENE)
	source_root.free()
	output_root.free()
	quit(0)


func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	node.owner = scene_owner
	for child in node.get_children(true):
		_set_owner_recursive(child, scene_owner)


func _add_environment(root: Node3D) -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.006, 0.009, 0.018, 1.0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.20, 0.27, 0.42, 1.0)
	environment.ambient_light_energy = 0.34
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.glow_enabled = true
	var world_environment := WorldEnvironment.new()
	world_environment.name = "StreetWorldEnvironment"
	world_environment.environment = environment
	root.add_child(world_environment)
	world_environment.owner = root


func _add_street_lighting(root: Node3D) -> void:
	var moon := DirectionalLight3D.new()
	moon.name = "NightFillDirectionalLight3D"
	moon.light_color = Color(0.30, 0.42, 0.72, 1.0)
	moon.light_energy = 0.58
	moon.shadow_enabled = true
	moon.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	root.add_child(moon)
	moon.owner = root

	var coffee_light := OmniLight3D.new()
	coffee_light.name = "CoffeeWarmOmniLight3D"
	coffee_light.position = Vector3(0.0, 2.6, -3.1)
	coffee_light.light_color = Color(1.0, 0.31, 0.08, 1.0)
	coffee_light.light_energy = 5.2
	coffee_light.omni_range = 8.0
	coffee_light.shadow_enabled = true
	root.add_child(coffee_light)
	coffee_light.owner = root

	var bakery_light := OmniLight3D.new()
	bakery_light.name = "NeighborBlueOmniLight3D"
	bakery_light.position = Vector3(6.4, 2.5, -3.0)
	bakery_light.light_color = Color(0.05, 0.18, 1.0, 1.0)
	bakery_light.light_energy = 4.0
	bakery_light.omni_range = 7.0
	root.add_child(bakery_light)
	bakery_light.owner = root

	# The storefront lights above mostly illuminate the curb-facing side of the
	# Jeep.  These two restrained fills live on the road side and reveal the
	# opposite doors, fenders, wheels, and suspension without turning the night
	# scene into flat daylight.  Keeping them as explicit scene nodes also makes
	# their placement and exposure easy to art-direct in Godot.
	var jeep_roadside_fill := OmniLight3D.new()
	jeep_roadside_fill.name = "JeepRoadsideFillOmniLight3D"
	jeep_roadside_fill.position = Vector3(-0.35, 2.35, 3.4)
	jeep_roadside_fill.light_color = Color(0.48, 0.63, 1.0, 1.0)
	jeep_roadside_fill.light_energy = 3.8
	jeep_roadside_fill.omni_range = 7.5
	jeep_roadside_fill.omni_attenuation = 1.35
	jeep_roadside_fill.shadow_enabled = true
	root.add_child(jeep_roadside_fill)
	jeep_roadside_fill.owner = root

	var jeep_rear_rim := OmniLight3D.new()
	jeep_rear_rim.name = "JeepRearQuarterRimOmniLight3D"
	jeep_rear_rim.position = Vector3(-3.7, 1.65, 1.15)
	jeep_rear_rim.light_color = Color(1.0, 0.56, 0.30, 1.0)
	jeep_rear_rim.light_energy = 2.1
	jeep_rear_rim.omni_range = 5.0
	jeep_rear_rim.omni_attenuation = 1.6
	root.add_child(jeep_rear_rim)
	jeep_rear_rim.owner = root


func _add_runtime_camera(root: Node3D) -> void:
	var camera := Camera3D.new()
	camera.name = "StreetCamera3D"
	camera.fov = 54.0
	camera.current = true
	root.add_child(camera)
	camera.owner = root
	camera.look_at_from_position(
		Vector3(0.0, 3.45, 18.7),
		Vector3(0.0, 2.5, -4.2),
		Vector3.UP
	)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
