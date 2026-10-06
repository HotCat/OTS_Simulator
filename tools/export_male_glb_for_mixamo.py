#!/usr/bin/env python3
"""Export the Humanizer male proxy as a clean FBX for Mixamo upload.

The Godot GLB contains editor/runtime helper nodes, an idle action, a collider,
and a separate physics icosphere.  Mixamo should receive only the deforming
character mesh and its armature in a neutral rest pose.  This exporter keeps the
source GLB untouched, removes non-deforming helpers from the export selection,
clears the imported action, and writes a scale-normalized FBX.

Usage::

    blender -b --python tools/export_male_glb_for_mixamo.py -- \
      --input assets/models/male_carrier/male_1785818633452_humanizer_proxy.glb \
      --output assets/downloads/male_carrier_mixamo_upload.fbx
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import bpy


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:])


def main() -> int:
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(args.input))

    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError("expected exactly one armature, found %d" % len(armatures))
    armature = armatures[0]
    deform_meshes = [
        obj for obj in bpy.context.scene.objects
        if obj.type == "MESH" and any(mod.type == "ARMATURE" and mod.object == armature for mod in obj.modifiers)
    ]
    if not deform_meshes:
        raise RuntimeError("could not find a mesh skinned to the imported armature")

    # Mixamo's auto-rigger should inspect the neutral skeleton, not the GLB's
    # imported idle animation or Godot physics helpers.
    armature.animation_data_clear()
    armature.data.pose_position = "REST"
    for obj in bpy.context.scene.objects:
        obj.select_set(False)
    armature.select_set(True)
    for mesh in deform_meshes:
        mesh.select_set(True)
    bpy.context.view_layer.objects.active = armature

    # The GLB is already normalized, but apply transforms explicitly so FBX
    # does not carry a hidden object scale that changes the Mixamo upload size.
    for obj in [armature, *deform_meshes]:
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        obj.select_set(False)
    armature.select_set(True)
    for mesh in deform_meshes:
        mesh.select_set(True)
    bpy.context.view_layer.objects.active = armature

    args.output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.fbx(
        filepath=str(args.output),
        use_selection=True,
        object_types={"ARMATURE", "MESH"},
        use_mesh_modifiers=True,
        add_leaf_bones=False,
        bake_anim=False,
        use_custom_props=False,
        apply_unit_scale=True,
        axis_forward="-Z",
        axis_up="Y",
        primary_bone_axis="Y",
        secondary_bone_axis="X",
        use_armature_deform_only=False,
    )
    print("MIXAMO_UPLOAD_FBX_OK armature=%s meshes=%d output=%s" % (
        armature.name, len(deform_meshes), args.output
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
