extends SceneTree

const SCENE_PATH := "res://demos/coffebar_female_walk_scene.tscn"
const GLB_PATH := "res://assets/models/vehicles/jeep_wrangler/jeep_wrangler_two_door_clay_proxy.glb"

func _init() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		_fail("Could not load scene")
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	var old_jeep := scene.get_node_or_null("CoffeeBarStreet/Jeep_Street_Instance") as Node3D
	var clay_jeep := scene.get_node_or_null("Jeep_Clay_Proxy") as Node3D
	if old_jeep == null or old_jeep.visible:
		_fail("Original textured Jeep is missing or still visible")
		return
	if clay_jeep == null:
		_fail("Clay Jeep proxy instance is missing")
		return
	var mesh_count := 0
	var material_count := 0
	for node in clay_jeep.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh == null:
			continue
		mesh_count += 1
		var surface_material := mesh.mesh.surface_get_material(0) if mesh.mesh != null and mesh.mesh.get_surface_count() > 0 else null
		if mesh.material_override != null or surface_material is StandardMaterial3D:
			material_count += 1
	if mesh_count != 207 or material_count != mesh_count:
		_fail("Unexpected clay mesh/material coverage: %d meshes, %d overrides" % [mesh_count, material_count])
		return
	var glb_packed := load(GLB_PATH) as PackedScene
	if glb_packed == null:
		_fail("Clay proxy GLB could not be loaded")
		return
	var glb_root := glb_packed.instantiate()
	root.add_child(glb_root)
	var glb_mesh: MeshInstance3D = null
	for glb_node in glb_root.find_children("*", "MeshInstance3D", true, false):
		glb_mesh = glb_node as MeshInstance3D
		if glb_mesh != null:
			break
	var glb_material := glb_mesh.mesh.surface_get_material(0) if glb_mesh != null and glb_mesh.mesh != null and glb_mesh.mesh.get_surface_count() > 0 else null
	if glb_mesh == null or glb_material == null:
		_fail("Clay proxy GLB lost its clay surface material")
		return
	if glb_material is StandardMaterial3D:
		var clay_material := glb_material as StandardMaterial3D
		var expected := Color(0.55, 0.55, 0.55, 1.0)
		var albedo_error := absf(clay_material.albedo_color.r - expected.r) + absf(clay_material.albedo_color.g - expected.g) + absf(clay_material.albedo_color.b - expected.b)
		if albedo_error > 0.03:
			_fail("Clay proxy GLB surface material has unexpected albedo")
			return
	print("VERIFY_CLAY_JEEP_PROXY_OK meshes=", mesh_count, " material_overrides=", material_count)
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	quit(1)
