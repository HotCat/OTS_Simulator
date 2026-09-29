"""Normalize a Meta SAM 3D Objects bus export for the Godot clay-proxy scene.

The web demo exports an object in arbitrary units and commonly includes the
source-image appearance as materials.  This pass makes the asset deterministic
for blocking: one mesh, neutral clay material, seven metre vehicle length,
grounded at z=0, and no camera/light/default helper objects.
"""

import bpy
from mathutils import Vector
import os

SOURCE = "/Users/hotcat/Downloads/object_0 (2).glb"
OUT_GLB = "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/assets/models/vehicles/beijing_ev_bus/beijing_ev_bus_sam3d_clay_proxy.glb"
OUT_BLEND = "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/assets/models/vehicles/beijing_ev_bus/beijing_ev_bus_sam3d_clay_proxy.blend"


def main() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=SOURCE)

    # Blender's startup scene can retain a default Cube even with
    # ``use_empty=True``.  Only geometry imported from the SAM export belongs
    # in the vehicle; discard that helper before any joining/export.
    meshes = [
        obj
        for obj in bpy.context.scene.objects
        if obj.type == "MESH" and obj.name not in {"Cube", "Cube.001"}
    ]
    if not meshes:
        raise RuntimeError("SAM 3D export contains no mesh objects")

    # Join fragments into one predictable vehicle object.
    bpy.ops.object.select_all(action="DESELECT")
    for obj in meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    bus = meshes[0]
    bus.name = "BeijingEVBus_SAM3D_ClayProxy"

    # Apply source transforms before measuring.  The longest local dimension is
    # the bus length; keep its existing orientation from SAM3D.
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    length = max(float(v) for v in bus.dimensions)
    if length <= 1e-6:
        raise RuntimeError("SAM 3D mesh has invalid dimensions")
    bus.scale = (7.0 / length,) * 3
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    # Center width/length and place the lowest vertex on the ground plane.
    corners = [bus.matrix_world @ Vector(corner) for corner in bus.bound_box]
    min_x = min(c.x for c in corners)
    max_x = max(c.x for c in corners)
    min_y = min(c.y for c in corners)
    max_y = max(c.y for c in corners)
    min_z = min(c.z for c in corners)
    bus.location.x -= (min_x + max_x) * 0.5
    bus.location.y -= (min_y + max_y) * 0.5
    bus.location.z -= min_z
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)

    # Replace every imported material with one monochrome clay material.
    clay = bpy.data.materials.new("SAM3D_Clay_Neutral")
    clay.use_nodes = True
    bsdf = clay.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (0.62, 0.62, 0.62, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.82
    bsdf.inputs["Metallic"].default_value = 0.0
    bus.data.materials.clear()
    bus.data.materials.append(clay)

    # Remove non-vehicle helpers imported or created by the file loader.
    for obj in list(bpy.context.scene.objects):
        if obj != bus:
            bpy.data.objects.remove(obj, do_unlink=True)
    bpy.ops.object.select_all(action="DESELECT")
    bus.select_set(True)
    bpy.context.view_layer.objects.active = bus

    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
    bpy.ops.export_scene.gltf(
        filepath=OUT_GLB,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_materials="EXPORT",
    )
    print("SAM3D bus dimensions:", tuple(round(v, 4) for v in bus.dimensions))
    print("SAM3D bus output:", OUT_GLB)


if __name__ == "__main__":
    main()
