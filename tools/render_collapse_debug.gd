extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var scene := (load("res://demos/coffebar_female_walk_scene.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	for path in ["CoffeeBarStreet", "Jeep_Clay_Proxy", "CoffeeBarStreet_Clay_Proxy"]:
		var prop := scene.get_node_or_null(NodePath(path)) as Node3D
		if prop != null:
			prop.visible = false
	var player := scene.get_node("FemaleWalkAnimationPlayer") as AnimationPlayer
	var clip_library_name := "collapse"
	if not args.is_empty():
		var diagnostic_library := load(args[0]) as AnimationLibrary
		if diagnostic_library != null:
			player.add_animation_library("debug_clip", diagnostic_library)
			clip_library_name = "debug_clip"
	var camera := Camera3D.new()
	scene.add_child(camera)
	var character := scene.get_node("IK_character") as Node3D
	camera.global_position = character.global_position + Vector3(0.0, 1.1, 3.0)
	camera.look_at(character.global_position + Vector3(0.0, 0.9, 0.0), Vector3.UP)
	camera.fov = 45.0
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, 25.0, 0.0)
	light.light_energy = 2.0
	scene.add_child(light)
	for sample in [0.0, 3.0, 6.0]:
		player.play("%s/female_collapse_motion" % clip_library_name)
		player.seek(sample, true)
		player.advance(0.0)
		await process_frame
		await process_frame
		# Keep the diagnostic framing centered on the animated root; collapse
		# root motion otherwise moves the character out of the fixed camera view.
		camera.global_position = character.global_position + Vector3(0.0, 1.1, 3.0)
		camera.look_at(character.global_position + Vector3(0.0, 0.9, 0.0), Vector3.UP)
		var image := get_root().get_viewport().get_texture().get_image()
		image.save_png("/tmp/collapse_debug_%d.png" % int(sample))
	print("WROTE_DEBUG_FRAMES")
	quit(0)
