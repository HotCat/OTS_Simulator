#!/usr/bin/env python3
"""Convert a Mixamo-rigged walk FBX to a Godot-friendly GLB.

The GLB is used as an animation-space reference: Godot performs the FBX/GLTF
axis conversion itself, so we can extract the resulting animation tracks
without guessing how Blender's bone basis maps to Skeleton3D pose rotations.
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
    bpy.ops.import_scene.fbx(filepath=str(args.input), automatic_bone_orientation=False)
    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError("expected one armature, found %d" % len(armatures))
    armature = armatures[0]
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError("FBX contains no mesh")
    for obj in bpy.context.scene.objects:
        obj.select_set(False)
    armature.select_set(True)
    for mesh in meshes:
        mesh.select_set(True)
    bpy.context.view_layer.objects.active = armature
    action = armature.animation_data.action if armature.animation_data else None
    if action is not None:
        start, end = action.frame_range
        bpy.context.scene.frame_start = int(round(start))
        bpy.context.scene.frame_end = int(round(end))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(args.output),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_animations=action is not None,
        export_frame_range=True,
        export_force_sampling=True,
        export_nla_strips=False,
        export_skins=True,
        export_morph=False,
    )
    print("MIXAMO_WALKING_GLB_OK action=%s output=%s" % (action.name if action else "none", args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
