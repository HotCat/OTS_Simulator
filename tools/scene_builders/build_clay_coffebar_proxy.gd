extends SceneTree

## Build a texture-free clay proxy for the evaluated coffee-bar street scene.
## The current working scene is used as the source so editable overrides such
## as the curb placement are baked into the proxy.  The Jeep subtree is
## removed because the working scene supplies the dedicated clay Jeep proxy.

const SOURCE_SCENE := "res://demos/coffebar_female_walk_scene.tscn"
const STREET_PATH := NodePath("CoffeeBarStreet")
const OUTPUT_GLB := "res://assets/environments/coffebar_street/coffebar_street_clay_proxy.glb"
const OUTPUT_TSCN := "res://assets/environments/coffebar_street/coffebar_street_clay_proxy.tscn"


func _init() -> void:
	call_deferred("_build")


func _build() -> void:
	var source := load(SOURCE_SCENE) as PackedScene
	if source == null:
		_fail("Could not load source scene: %s" % SOURCE_SCENE)
		return
	var evaluated_root := source.instantiate() as Node3D
	if evaluated_root == null:
		_fail("Source scene did not instantiate as Node3D")
		return
	root.add_child(evaluated_root)
	var street := evaluated_root.get_node_or_null(STREET_PATH) as Node3D
	if street == null:
		_fail("Could not resolve CoffeeBarStreet")
		return

	var street_transform := street.transform
	street.get_parent().remove_child(street)
	root.add_child(street)
	street.transform = Transform3D.IDENTITY
	street.name = "CoffeeBarStreetClayProxy"
	street.set_meta("proxy_source", SOURCE_SCENE)
	street.set_meta("proxy_style", "neutral gray clay")
	street.set_meta("proxy_note", "Evaluated coffee-bar street overrides baked; Jeep supplied separately")

	for child_name in ["Jeep_Street_Instance", "Jeep_Clay_Proxy"]:
		var vehicle := street.get_node_or_null(child_name)
		if vehicle != null:
			vehicle.get_parent().remove_child(vehicle)
			vehicle.queue_free()

	# Remove storefront sign/lightbox geometry so the proxy reads as a neutral
	# architectural blockout instead of a game-style neon street.
	var removed_signs := 0
	for node in street.find_children("*", "Node3D", true, false):
		var node_name := (node as Node).name.to_lower()
		if node_name.contains("sign") or node_name.contains("logo_lightbox") or node_name.begins_with("coffee_logo"):
			var sign_node := node as Node
			sign_node.get_parent().remove_child(sign_node)
			sign_node.queue_free()
			removed_signs += 1

	var clay := StandardMaterial3D.new()
	clay.resource_name = "CoffeeBarClayProxyMaterial"
	clay.albedo_color = Color(0.55, 0.55, 0.55, 1.0)
	clay.roughness = 0.86
	clay.metallic = 0.0
	clay.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	clay.cull_mode = BaseMaterial3D.CULL_BACK

	var mesh_count := 0
	for node in street.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null:
			continue
		var baked_mesh := mesh_instance.mesh.duplicate() as ArrayMesh if mesh_instance.mesh != null else null
		if baked_mesh != null:
			for surface_index in baked_mesh.get_surface_count():
				baked_mesh.surface_set_material(surface_index, clay)
			mesh_instance.mesh = baked_mesh
		mesh_instance.material_override = clay
		mesh_count += 1

	if mesh_count == 0:
		_fail("No street MeshInstance3D nodes found")
		return

	var packed := PackedScene.new()
	var pack_error := packed.pack(street)
	if pack_error != OK:
		_fail("PackedScene.pack failed: %s" % error_string(pack_error))
		return
	var tscn_error := ResourceSaver.save(packed, OUTPUT_TSCN)
	if tscn_error != OK:
		_fail("Could not save clay street scene: %s" % error_string(tscn_error))
		return

	var state := GLTFState.new()
	var document := GLTFDocument.new()
	var append_error := document.append_from_scene(street, state)
	if append_error != OK:
		_fail("GLTFDocument.append_from_scene failed: %s" % error_string(append_error))
		return
	var glb_error := document.write_to_filesystem(state, ProjectSettings.globalize_path(OUTPUT_GLB))
	if glb_error != OK:
		_fail("Could not save clay street GLB: %s" % error_string(glb_error))
		return

	print("CLAY_COFFEBAR_PROXY_OK")
	print("source=", SOURCE_SCENE)
	print("street_transform=", street_transform)
	print("mesh_count=", mesh_count)
	print("removed_sign_nodes=", removed_signs)
	print("output_glb=", OUTPUT_GLB)
	print("output_tscn=", OUTPUT_TSCN)
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
