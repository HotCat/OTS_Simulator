#!/usr/bin/env python3
"""Prepare a Mixamo FBX for Godot root motion without the abandoned add-on.

The Mixamo FBX importer commonly leaves an armature object at scale 0.01 and
the hips as the scene root.  Godot then receives a giant/mis-scaled root or
loses the locomotion channel.  This script keeps the source file untouched,
normalizes the armature object, removes duplicate armatures, and adds a small
``Root`` bone above the Mixamo hips bone.  The existing action is preserved;
the root is deliberately not animated here when the source is an in-place
clip.  The retargeter can therefore distinguish real root travel from pelvis
bob instead of guessing from a malformed imported hierarchy.

Usage (run with Blender):
  blender -b --python tools/mixamo_to_godot_root_motion.py -- \
    --input '/Users/hotcat/Downloads/Holding Walk.fbx' \
    --output assets/animations/mixamo_holding_walk_root_fixed.fbx
"""

from __future__ import annotations

import argparse
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--root-name", default="Root")
    parser.add_argument("--hips-name", default="mixamorig:Hips")
    parser.add_argument("--root-length", type=float, default=0.08)
    parser.add_argument("--no-normalize-scale", action="store_true")
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:])


def _armatures() -> list[bpy.types.Object]:
    return [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]


def _choose_armature(armatures: list[bpy.types.Object], hips_name: str) -> bpy.types.Object:
    for armature in armatures:
        if armature.data.bones.get(hips_name):
            return armature
    if not armatures:
        raise RuntimeError("FBX contains no armature")
    return armatures[0]


def _remove_duplicate_armatures(main: bpy.types.Object) -> None:
    for armature in list(_armatures()):
        if armature == main:
            continue
        bpy.data.objects.remove(armature, do_unlink=True)


def _normalize_armature_scale(armature: bpy.types.Object) -> float:
    scale = float(armature.scale.x)
    if abs(scale) < 1.0e-8:
        raise RuntimeError("armature has an invalid zero scale")
    if abs(scale - 1.0) < 1.0e-6:
        return scale
    bpy.context.view_layer.objects.active = armature
    armature.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    # FBX stores pose-bone translations in the pre-object-scale space.  Applying
    # the object scale changes the rest bones but does not rewrite F-curve
    # values, so scale every animated bone location by the same factor.  This
    # is the important guard against the 100x oversized gait/root reported by
    # the tutorial comments.
    for action in bpy.data.actions:
        for fcurve in action.fcurves:
            if fcurve.data_path.startswith('pose.bones[') and fcurve.data_path.endswith('].location'):
                for key in fcurve.keyframe_points:
                    key.co.y *= scale
                fcurve.update()
    armature.select_set(False)
    return scale


def _add_root(armature: bpy.types.Object, hips_name: str, root_name: str, length: float) -> None:
    if armature.data.bones.get(root_name):
        return
    old_hips_matrix = armature.data.bones[hips_name].matrix_local.copy()
    bpy.context.view_layer.objects.active = armature
    armature.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    root = armature.data.edit_bones.new(root_name)
    root.head = Vector((0.0, 0.0, 0.0))
    root.tail = Vector((0.0, 0.0, max(length, 0.001)))
    root.use_connect = False
    hips = armature.data.edit_bones.get(hips_name)
    if hips is None:
        bpy.ops.object.mode_set(mode="OBJECT")
        raise RuntimeError("cannot find hips bone %s" % hips_name)
    hips.parent = root
    hips.use_connect = False
    # Preserve the original rest matrix.  Do not resize or rotate the mesh.
    hips.matrix = old_hips_matrix
    bpy.ops.object.mode_set(mode="OBJECT")
    armature.select_set(False)


def _set_metadata(armature: bpy.types.Object, input_path: Path, original_scale: float,
                  hips_name: str, root_name: str) -> None:
    armature["godot_root_motion_preprocessed"] = True
    armature["godot_root_motion_source"] = str(input_path)
    armature["godot_root_motion_root_bone"] = root_name
    armature["godot_root_motion_hips_bone"] = hips_name
    armature["godot_root_motion_original_armature_scale"] = original_scale
    armature["godot_root_motion_scale_normalized"] = abs(original_scale - 1.0) > 1.0e-6
    armature["godot_root_motion_note"] = "Root is a clean parent; source action remains unchanged and in-place clips retain pelvis bob."


def main() -> int:
    args = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=str(args.input), automatic_bone_orientation=False)
    armature = _choose_armature(_armatures(), args.hips_name)
    _remove_duplicate_armatures(armature)
    original_scale = float(armature.scale.x)
    if not args.no_normalize_scale:
        _normalize_armature_scale(armature)
    _add_root(armature, args.hips_name, args.root_name, args.root_length)
    _set_metadata(armature, args.input, original_scale, args.hips_name, args.root_name)
    # Keep the exported action's exact Mixamo range; Blender otherwise bakes
    # the default 1..250 scene range and appends a long frozen tail.
    action = armature.animation_data.action if armature.animation_data else None
    if action is not None:
        bpy.context.scene.frame_start = int(round(action.frame_range[0]))
        bpy.context.scene.frame_end = int(round(action.frame_range[1]))
        bpy.context.scene.frame_set(bpy.context.scene.frame_start)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    armature.select_set(True)
    bpy.context.view_layer.objects.active = armature
    for obj in bpy.context.scene.objects:
        if obj.type == "MESH":
            obj.select_set(True)
    bpy.ops.export_scene.fbx(
        filepath=str(args.output),
        use_selection=True,
        object_types={"ARMATURE", "MESH"},
        add_leaf_bones=False,
        bake_anim=True,
        bake_anim_use_all_actions=False,
        bake_anim_use_nla_strips=False,
        apply_unit_scale=True,
        axis_forward="-Z",
        axis_up="Y",
        primary_bone_axis="Y",
        secondary_bone_axis="X",
    )
    print("MIXAMO_ROOT_PREPROCESS_OK root=%s hips=%s original_scale=%.6f output=%s" % (
        args.root_name, args.hips_name, original_scale, args.output))
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(main())
