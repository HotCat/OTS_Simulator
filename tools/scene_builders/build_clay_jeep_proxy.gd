extends SceneTree

## Build a monochrome clay proxy from the editor-baked Wrangler GLB.
## Geometry, skinning, bones, and node transforms are retained; only the
## rendered material is replaced with a warm neutral clay material.

const SOURCE_GLB := "res://assets/models/vehicles/jeep_wrangler/jeep_wrangler_two_door_editor_baked.glb"
const OUTPUT_GLB := "res://assets/models/vehicles/jeep_wrangler/jeep_wrangler_two_door_clay_proxy.glb"
const OUTPUT_TSCN := "res://assets/models/vehicles/jeep_wrangler/jeep_wrangler_two_door_clay_proxy.tscn"


func _init() -> void:
	call_deferred("_build")


func _build() -> void:
	var source := load(SOURCE_GLB) as PackedScene
	if source == null:
		_fail("Could not load source GLB: %s" % SOURCE_GLB)
		return

	var proxy := source.instantiate() as Node3D
	if proxy == null:
		_fail("Source GLB did not instantiate as Node3D")
		return
	root.add_child(proxy)
	proxy.name = "JeepWranglerTwoDoorClayProxy"
	proxy.set_meta("proxy_source", SOURCE_GLB)
	proxy.set_meta("proxy_style", "neutral gray clay")
	proxy.set_meta("proxy_note", "Geometry and rig retained; all MeshInstance3D materials replaced")

	var clay := StandardMaterial3D.new()
	clay.resource_name = "JeepClayProxyMaterial"
	clay.albedo_color = Color(0.55, 0.55, 0.55, 1.0)
	clay.roughness = 0.86
	clay.metallic = 0.0
	clay.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	clay.cull_mode = BaseMaterial3D.CULL_BACK

	var mesh_count := 0
	for node in proxy.find_children("*", "MeshInstance3D", true, false):
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
		_fail("No MeshInstance3D nodes found in source GLB")
		return

	var packed := PackedScene.new()
	var pack_error := packed.pack(proxy)
	if pack_error != OK:
		_fail("PackedScene.pack failed: %s" % error_string(pack_error))
		return
	var tscn_error := ResourceSaver.save(packed, OUTPUT_TSCN)
	if tscn_error != OK:
		_fail("Could not save clay proxy scene: %s" % error_string(tscn_error))
		return

	var state := GLTFState.new()
	var document := GLTFDocument.new()
	var append_error := document.append_from_scene(proxy, state)
	if append_error != OK:
		_fail("GLTFDocument.append_from_scene failed: %s" % error_string(append_error))
		return
	var glb_error := document.write_to_filesystem(state, ProjectSettings.globalize_path(OUTPUT_GLB))
	if glb_error != OK:
		_fail("Could not save clay proxy GLB: %s" % error_string(glb_error))
		return

	print("CLAY_JEEP_PROXY_OK")
	print("source=", SOURCE_GLB)
	print("mesh_count=", mesh_count)
	print("output_glb=", OUTPUT_GLB)
	print("output_tscn=", OUTPUT_TSCN)
	quit(0)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
