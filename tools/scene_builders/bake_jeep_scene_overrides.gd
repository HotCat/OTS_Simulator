extends SceneTree

## Bake the Jeep's editable-instance overrides from the coffee-bar scene into
## a standalone GLB that can be instantiated in any Godot scene.
##
## Godot stores edits made to children of an imported scene as overrides in the
## owning .tscn; it does not write them back into the source GLB.  Loading and
## instantiating the coffee scene evaluates those overrides exactly as the
## editor does.  We then detach only the Jeep subtree, neutralize its street
## placement transform, and serialize the resulting hierarchy through
## GLTFDocument.  Mesh-local corrections (SAM body, hood, doors, bumpers, and
## any future child edits) remain baked, while the reusable asset starts at the
## origin instead of carrying its coffee-street position and yaw.

const SOURCE_SCENE := "res://demos/coffebar_female_walk_scene.tscn"
const JEEP_PATH := NodePath("CoffeeBarStreet/Jeep_Street_Instance")
const OUTPUT_GLB := "res://assets/models/vehicles/jeep_wrangler/jeep_wrangler_two_door_editor_baked.glb"


func _init() -> void:
	call_deferred("_bake")


func _bake() -> void:
	var packed := load(SOURCE_SCENE) as PackedScene
	if packed == null:
		_fail("Could not load source scene: %s" % SOURCE_SCENE)
		return

	var scene_root := packed.instantiate()
	root.add_child(scene_root)
	var jeep := scene_root.get_node_or_null(JEEP_PATH) as Node3D
	if jeep == null:
		_fail("Could not resolve Jeep node: %s" % JEEP_PATH)
		return

	var street_transform := jeep.transform
	var source_parent := jeep.get_parent()
	source_parent.remove_child(jeep)
	root.add_child(jeep)
	jeep.transform = Transform3D.IDENTITY
	jeep.name = "JeepWranglerTwoDoorEditorBaked"
	jeep.set_meta("baked_from_scene", SOURCE_SCENE)
	jeep.set_meta("baked_from_node", str(JEEP_PATH))
	jeep.set_meta("excluded_street_transform", street_transform)
	jeep.set_meta("bake_note", "Godot editable-instance child transforms baked; reusable origin is identity")

	var state := GLTFState.new()
	var document := GLTFDocument.new()
	var append_error := document.append_from_scene(jeep, state)
	if append_error != OK:
		_fail("GLTFDocument.append_from_scene failed: %s" % error_string(append_error))
		return

	var absolute_output := ProjectSettings.globalize_path(OUTPUT_GLB)
	var write_error := document.write_to_filesystem(state, absolute_output)
	if write_error != OK:
		_fail("GLTFDocument.write_to_filesystem failed: %s" % error_string(write_error))
		return

	print("JEEP_BAKE_OK")
	print("source_scene=", SOURCE_SCENE)
	print("source_node=", JEEP_PATH)
	print("excluded_street_transform=", street_transform)
	print("output=", OUTPUT_GLB)
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
