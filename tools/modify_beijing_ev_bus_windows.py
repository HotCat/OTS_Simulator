"""Open the front windshield and driver's-side window on the clay EV bus.

The SAM3D bus is intentionally a single clay mesh.  These two Boolean
cutters are kept in bus-local coordinates so the resulting GLB remains a
drop-in replacement for BeijingEVBus_Clay_Proxy in Godot.  The cutters extend
slightly outside the body; this is important on the rounded front because it
removes the front skin instead of leaving a paper-thin cap over the opening.

Run from Blender, for example:

    blender -b beijing_ev_bus_sam3d_clay_proxy.blend \
      --python tools/modify_beijing_ev_bus_windows.py -- \
      --output /tmp/beijing_ev_bus_windows.glb
"""

import argparse
import bpy
import sys


BUS_NAME = "BeijingEVBus_SAM3D_ClayProxy"


def add_cutter(name: str, location: tuple[float, float, float], dimensions: tuple[float, float, float]):
    bpy.ops.mesh.primitive_cube_add(location=location)
    cutter = bpy.context.object
    cutter.name = name
    cutter.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return cutter


def apply_difference(bus, cutter) -> None:
    modifier = bus.modifiers.new(name=f"Open {cutter.name}", type="BOOLEAN")
    modifier.operation = "DIFFERENCE"
    modifier.solver = "EXACT"
    modifier.object = cutter
    bpy.context.view_layer.objects.active = bus
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    bpy.data.objects.remove(cutter, do_unlink=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    blender_args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parser.parse_args(blender_args)

    bus = bpy.data.objects.get(BUS_NAME)
    if bus is None or bus.type != "MESH":
        meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
        if not meshes:
            raise RuntimeError("No mesh found in the Beijing EV bus blend")
        bus = meshes[0]

    # The bus is 7.0 m long (X), 2.742 m wide (Y), and 2.663 m tall (Z).
    # In this imported proxy the actual front is -X; the +X end is the rear.
    # Leave the lower bumper and the side pillars intact.
    windshield = add_cutter(
        "Cutter_FrontWindshield",
        location=(-3.48, 0.0, 1.82),
        dimensions=(0.92, 1.82, 0.94),
    )
    apply_difference(bus, windshield)

    # Driver-side/left-side window, immediately behind the -X front corner.
    # The y=- side is the left side used by the supplied front/left reference.
    left_window = add_cutter(
        "Cutter_LeftSideWindow",
        location=(-2.46, -1.02, 1.88),
        dimensions=(1.12, 0.62, 0.76),
    )
    apply_difference(bus, left_window)

    # Two passenger-door openings on the opposite side from the earlier test.
    # In this proxy's coordinate convention the requested visible left side is
    # y=+1.02.  Cut down close to the floor so Godot/H3 can read the entries as
    # walkable hollow doorways rather than painted panels.
    for name, x, width in [
        # Front is -X in this imported mesh.  Put the forward passenger door
        # ahead of the front axle, between the axle and the front end.
        ("Cutter_LeftFrontDoor", -2.70, 0.78),
        ("Cutter_LeftRearDoor", 0.68, 0.86),
    ]:
        door = add_cutter(
            name,
            location=(x, 1.02, 1.00),
            dimensions=(width, 0.62, 1.86),
        )
        apply_difference(bus, door)

    bus.select_set(True)
    bpy.context.view_layer.objects.active = bus
    bpy.ops.wm.save_as_mainfile(filepath=bpy.data.filepath)
    bpy.ops.export_scene.gltf(
        filepath=args.output,
        export_format="GLB",
        export_apply=True,
        use_selection=True,
    )
    print(f"Exported modified bus: {args.output}")


if __name__ == "__main__":
    main()
