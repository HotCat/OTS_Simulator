"""Build an editable, render-agnostic clay proxy for the reference Beijing EV bus.

The local workspace does not include a runnable SAM3D Object checkpoint.  This
script is therefore the deterministic fallback: it uses the supplied photo as
the proportion authority and creates a deliberately simple Blender model whose
silhouette, wheelbase and roof equipment are suitable for Godot blocking and
MiniMax H3 camera/vehicle layout.  All parts share one matte clay material and
there are no textures, decals, logos or baked lighting.

Coordinate convention: bus length is Blender/Godot X, width is Y, height is Z;
the front is -X.  The rear axle is intentionally close to +X tail, matching
the original Chinese street photo and maximizing the usable passenger bay.
"""

import bpy
import math
import os
from mathutils import Vector


OUT_GLB = os.environ.get(
    "BUS_PROXY_GLB",
    "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/assets/models/vehicles/beijing_ev_bus/beijing_ev_bus_clay_proxy.glb",
)
OUT_BLEND = os.environ.get(
    "BUS_PROXY_BLEND",
    "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/assets/models/vehicles/beijing_ev_bus/beijing_ev_bus_clay_proxy.blend",
)


def clean_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.meshes, bpy.data.curves, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            if block.users == 0:
                datablocks.remove(block)


def clay_material():
    mat = bpy.data.materials.new("BusClay_Matte")
    mat.diffuse_color = (0.56, 0.56, 0.56, 1.0)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (0.56, 0.56, 0.56, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.82
    bsdf.inputs["Metallic"].default_value = 0.0
    return mat


MAT = None

# The first blocking draft used a conventional 12 m city-bus envelope.  The
# supplied reference is a compact approximately 7 m EV bus, so all geometry is
# uniformly rescaled before export.  Keeping this as an explicit calibration
# constant makes later SAM3D replacement straightforward.
SOURCE_LENGTH_METERS = 12.0
REFERENCE_LENGTH_METERS = 7.0
BUS_SCALE = REFERENCE_LENGTH_METERS / SOURCE_LENGTH_METERS


def finish(obj, bevel=0.04):
    obj.data.materials.append(MAT)
    if bevel:
        mod = obj.modifiers.new("Small manufactured edge radius", "BEVEL")
        mod.width = bevel
        mod.segments = 2
        mod.limit_method = "ANGLE"
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=mod.name)
    return obj


def cube(name, location, scale, bevel=0.04):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return finish(obj, bevel)


def cylinder(name, location, radius, depth, rotation=(math.pi / 2, 0, 0), vertices=32):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    return finish(obj, 0.025)


def bus_window_band(side_y, prefix):
    # Shallow solid panels preserve the window rhythm without introducing a
    # colored or transparent material; they remain clay geometry in the proxy.
    x_centers = [-4.45, -3.15, -1.85, -0.55, 0.75, 2.05, 3.35, 4.45]
    widths = [1.05, 1.08, 1.08, 1.08, 1.08, 1.08, 1.08, 0.86]
    for i, (x, w) in enumerate(zip(x_centers, widths)):
        cube(f"{prefix}_Window_{i:02d}", (x, side_y, 2.64), (w, 0.045, 0.78), 0.018)


def add_mirror(side_y):
    sign = 1 if side_y > 0 else -1
    x = -5.35
    cube("MirrorStem_L" if sign > 0 else "MirrorStem_R", (x, side_y * 1.33, 2.72), (0.10, 0.32, 0.10), 0.025)
    cube("Mirror_L" if sign > 0 else "Mirror_R", (x - 0.06, side_y * 1.49, 2.78), (0.20, 0.12, 0.34), 0.045)


def add_roof_equipment():
    cube("RoofBatteryHousing", (0.45, 0.0, 3.42), (7.2, 1.55, 0.20), 0.12)
    cube("RoofFrontFairing", (-3.45, 0.0, 3.48), (2.0, 1.45, 0.16), 0.10)
    cube("RoofRearFairing", (4.05, 0.0, 3.44), (1.25, 1.35, 0.15), 0.08)
    for i, x in enumerate((1.9, 2.35, 2.8)):
        cube(f"RoofVent_{i}", (x, 0.0, 3.62), (0.22, 0.85, 0.12), 0.025)


def add_wheel(x, side, axle_name):
    y = side * 1.29
    wheel = cylinder(f"{axle_name}_{'Left' if side > 0 else 'Right'}_Wheel", (x, y, 0.58), 0.53, 0.22)
    hub = cylinder(f"{axle_name}_{'Left' if side > 0 else 'Right'}_Hub", (x, y + side * 0.13, 0.58), 0.22, 0.035)
    return wheel, hub


def build_bus():
    # 12 m long, 2.5 m wide, 3.55 m tall.  The rear axle is at +4.55 m,
    # deliberately close to the tail (+6 m), matching the source photograph.
    cube("Bus_LowerBody", (0.0, 0.0, 1.24), (11.9, 2.42, 1.18), 0.18)
    cube("Bus_UpperBody", (0.15, 0.0, 2.27), (11.25, 2.32, 1.20), 0.14)
    cube("Bus_RoofCap", (0.25, 0.0, 3.12), (10.9, 2.22, 0.36), 0.18)
    # Sloped front cap and tail panel are separate, so the blocking silhouette
    # remains easy to replace with a higher-fidelity asset later.
    front = cube("Bus_FrontCap", (-5.64, 0.0, 2.05), (0.42, 2.25, 1.75), 0.10)
    front.rotation_euler.y = math.radians(-8)
    bpy.context.view_layer.objects.active = front
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    cube("Bus_RearPanel", (5.73, 0.0, 2.10), (0.30, 2.20, 1.78), 0.10)

    bus_window_band(1.175, "Bus_Right")
    bus_window_band(-1.175, "Bus_Left")
    cube("Bus_Windshield", (-5.87, 0.0, 2.72), (0.045, 1.72, 0.72), 0.02)
    cube("Bus_RearWindow", (5.89, 0.0, 2.72), (0.045, 1.72, 0.62), 0.02)

    # Door and lower access-panel seams are represented by thin clay bars.
    for side in (-1, 1):
        y = side * 1.19
        for x in (-4.72, -3.72, 4.88):
            cube(f"BodySeam_{side}_{x}", (x, y, 1.32), (0.025, 0.035, 0.92), 0.005)

    add_roof_equipment()
    add_mirror(1)
    add_mirror(-1)

    # Long wheelbase / short rear overhang: rear axle at +4.55 m.
    for x, axle in ((-4.15, "FrontAxle"), (4.55, "RearAxle")):
        add_wheel(x, 1, axle)
        add_wheel(x, -1, axle)

    # Minimal bumpers and head/tail light housings, all clay.
    cube("FrontBumper", (-5.98, 0.0, 0.86), (0.16, 2.05, 0.18), 0.05)
    cube("RearBumper", (5.98, 0.0, 0.86), (0.16, 2.05, 0.18), 0.05)
    for y in (-0.78, 0.78):
        cube(f"FrontLamp_{y}", (-6.06, y, 1.30), (0.05, 0.38, 0.18), 0.025)
        cube(f"RearLamp_{y}", (6.06, y, 1.38), (0.05, 0.25, 0.48), 0.025)

    # Calibrate the complete proxy to the user's approximately 7 m reference
    # bus.  Scale both mesh dimensions and object locations so the exported
    # GLB has real-world dimensions, rather than relying on a Godot node scale.
    for obj in list(bpy.context.scene.objects):
        if obj.type != "MESH":
            continue
        obj.location *= BUS_SCALE
        obj.scale *= BUS_SCALE
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        obj.select_set(False)

    # Keep origins and names stable for later replacement/retargeting.
    root = bpy.data.objects.new("BeijingEVBus_Clay_Proxy", None)
    bpy.context.collection.objects.link(root)
    for obj in list(bpy.context.scene.objects):
        if obj is root:
            continue
        if obj.parent is None:
            obj.parent = root
    root.location = (0.0, 0.0, 0.0)
    return root


def main():
    global MAT
    clean_scene()
    MAT = clay_material()
    root = build_bus()
    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
    bpy.context.view_layer.objects.active = root
    root.select_set(True)
    bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
    bpy.ops.export_scene.gltf(
        filepath=OUT_GLB,
        export_format="GLB",
        export_apply=True,
        export_materials="EXPORT",
        export_cameras=False,
        export_lights=False,
    )
    print(f"BUS_PROXY_GLB={OUT_GLB}")
    print(f"BUS_PROXY_BLEND={OUT_BLEND}")
    print(f"BUS_LENGTH_METERS={REFERENCE_LENGTH_METERS}")


if __name__ == "__main__":
    main()
