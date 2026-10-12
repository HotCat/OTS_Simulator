import bpy

SOURCE = "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/assets/environments/ikea_sample_room/ikea_sample_room.glb"
OUTPUT = "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/assets/environments/ikea_sample_room/ikea_rug.glb"

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SOURCE)

rug = bpy.data.objects.get("Rug_240x160cm")
if rug is None or rug.type != "MESH":
    raise RuntimeError("Rug_240x160cm mesh was not found in the room GLB")

# The source room stores the rug's placement on the scene node. Export the
# accessory at a zero origin so Godot can position/rotate the whole rug with a
# normal top-level transform, without baking the room placement twice.
for obj in list(bpy.context.scene.objects):
    obj.select_set(False)
rug.select_set(True)
bpy.context.view_layer.objects.active = rug
rug.location = (0.0, 0.0, 0.0)

bpy.ops.export_scene.gltf(
    filepath=OUTPUT,
    export_format="GLB",
    use_selection=True,
    export_apply=True,
)
print("WROTE", OUTPUT)
