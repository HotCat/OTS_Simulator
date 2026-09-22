extends SceneTree

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
	var original := scene.get_node_or_null("CoffeeBarStreet") as Node3D
	var clay := scene.get_node_or_null("CoffeeBarStreet_Clay_Proxy") as Node3D
	if original == null or original.visible:
		_fail("Original textured CoffeeBarStreet is missing or still visible")
		return
	if clay == null:
		_fail("Clay CoffeeBarStreet proxy instance is missing")
		return
	var mesh_count := 0
	var clay_count := 0
	for node in clay.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh == null:
			continue
		mesh_count += 1
		var surface_material := mesh.mesh.surface_get_material(0) if mesh.mesh != null and mesh.mesh.get_surface_count() > 0 else null
		if mesh.material_override != null or surface_material is StandardMaterial3D:
			clay_count += 1
	var sign_count := 0
	for node in clay.find_children("*", "Node3D", true, false):
		var node_name := (node as Node).name.to_lower()
		if node_name.contains("sign") or node_name.contains("logo_lightbox") or node_name.begins_with("coffee_logo"):
			sign_count += 1
	if mesh_count <= 0 or clay_count != mesh_count or sign_count != 0:
		_fail("Unexpected clay street coverage: %d meshes, %d clay materials" % [mesh_count, clay_count])
		return
	print("VERIFY_CLAY_COFFEBAR_PROXY_OK meshes=", mesh_count, " clay_materials=", clay_count, " sign_nodes=", sign_count)
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
