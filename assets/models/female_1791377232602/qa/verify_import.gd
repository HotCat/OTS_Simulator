extends SceneTree

const ACTOR_PATH := "res://assets/models/female_1791377232602/female_1791377232602_humanizer_proxy.glb"


func _initialize() -> void:
	var packed := load(ACTOR_PATH) as PackedScene
	if packed == null:
		_fail("Could not load the female proxy GLB")
		return
	var actor := packed.instantiate()
	root.add_child(actor)
	var skeletons: Array[Skeleton3D] = []
	var meshes: Array[MeshInstance3D] = []
	var players: Array[AnimationPlayer] = []
	_collect(actor, skeletons, meshes, players)
	if skeletons.size() != 1 or meshes.size() != 1 or players.size() != 1:
		_fail("Expected one skeleton, one Avatar mesh, and one animation player")
		return
	var skeleton := skeletons[0]
	var avatar := meshes[0]
	var player := players[0]
	if skeleton.get_bone_count() != 56 or avatar.mesh.get_surface_count() != 8:
		_fail("Unexpected bone or surface count")
		return
	if avatar.skin == null:
		_fail("Avatar has no skin")
		return
	var available := player.get_animation_list()
	var idle_name := _find_clip(available, "Idle")
	var run_name := _find_clip(available, "Run")
	if idle_name.is_empty() or run_name.is_empty():
		_fail("Missing Idle or Run animation")
		return
	player.play(run_name)
	player.advance(0.5)
	if not player.is_playing():
		_fail("Run animation did not play")
		return
	print("FEMALE_PROXY_IMPORT_OK bones=", skeleton.get_bone_count(),
		" surfaces=", avatar.mesh.get_surface_count(),
		" skin_binds=", avatar.skin.get_bind_count(),
		" clips=", available,
		" run_length=", player.get_animation(run_name).length,
		" root_scale=", actor.scale)
	quit(0)


func _collect(node: Node, skeletons: Array[Skeleton3D], meshes: Array[MeshInstance3D], players: Array[AnimationPlayer]) -> void:
	if node is Skeleton3D:
		skeletons.append(node as Skeleton3D)
	elif node is MeshInstance3D:
		meshes.append(node as MeshInstance3D)
	elif node is AnimationPlayer:
		players.append(node as AnimationPlayer)
	for child in node.get_children():
		_collect(child, skeletons, meshes, players)


func _find_clip(available: PackedStringArray, fragment: String) -> StringName:
	for clip in available:
		if clip.contains(fragment):
			return StringName(clip)
	return &""


func _fail(message: String) -> void:
	push_error("FEMALE_PROXY_IMPORT_FAILED: " + message)
	quit(1)
