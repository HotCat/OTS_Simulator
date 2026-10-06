#!/usr/bin/env python3
"""Extract a Mixamo FBX gait as target-rig local rotations.

This script is executed by Blender because Blender's FBX importer is the most
reliable way to evaluate Mixamo actions.  It imports the source FBX and the
project's MaleCarrier GLB, converts each mapped Mixamo pose into the target
rig's rest-relative local rotation, and writes a small Godot motion cache.

Only rotations are exported.  Root translation and heading remain owned by
OTSCarryClayProxy's predefined CarrierTrajectory.  The default ``lower`` set
is intentional for an OTS carry: it transfers the useful loaded leg mechanics
without replacing the authored shoulder-carry arms and torso.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


LOWER_BONES = [
    "Hips", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot",
]
BODY_BONES = LOWER_BONES + [
    "Spine", "Chest", "UpperChest", "Neck", "Head",
    "LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
]

MIXAMO_TO_TARGET = {
    "Root": "Root",
    "mixamorig:Hips": "Hips",
    "mixamorig:Spine": "Spine",
    "mixamorig:Spine1": "Chest",
    "mixamorig:Spine2": "UpperChest",
    "mixamorig:Neck": "Neck",
    "mixamorig:Head": "Head",
    "mixamorig:LeftShoulder": "LeftShoulder",
    "mixamorig:LeftArm": "LeftUpperArm",
    "mixamorig:LeftForeArm": "LeftLowerArm",
    "mixamorig:LeftHand": "LeftHand",
    "mixamorig:RightShoulder": "RightShoulder",
    "mixamorig:RightArm": "RightUpperArm",
    "mixamorig:RightForeArm": "RightLowerArm",
    "mixamorig:RightHand": "RightHand",
    "mixamorig:LeftUpLeg": "LeftUpperLeg",
    "mixamorig:LeftLeg": "LeftLowerLeg",
    "mixamorig:LeftFoot": "LeftFoot",
    "mixamorig:RightUpLeg": "RightUpperLeg",
    "mixamorig:RightLeg": "RightLowerLeg",
    "mixamorig:RightFoot": "RightFoot",
    # Mixamo returns the uploaded Humanizer character with its original
    # target-rig names rather than the usual mixamorig:* names. Keeping these
    # aliases lets the same calibrated retargeter consume both downloads.
    "Hips": "Hips",
    "Spine": "Spine",
    "Chest": "Chest",
    "UpperChest": "UpperChest",
    "Neck": "Neck",
    "Head": "Head",
    "LeftShoulder": "LeftShoulder",
    "LeftUpperArm": "LeftUpperArm",
    "LeftLowerArm": "LeftLowerArm",
    "LeftHand": "LeftHand",
    "RightShoulder": "RightShoulder",
    "RightUpperArm": "RightUpperArm",
    "RightLowerArm": "RightLowerArm",
    "RightHand": "RightHand",
    "LeftUpperLeg": "LeftUpperLeg",
    "LeftLowerLeg": "LeftLowerLeg",
    "LeftFoot": "LeftFoot",
    "RightUpperLeg": "RightUpperLeg",
    "RightLowerLeg": "RightLowerLeg",
    "RightFoot": "RightFoot",
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--start", type=float, default=1.0)
    parser.add_argument("--end", type=float, default=0.0)
    parser.add_argument("--bone-set", choices=("lower", "body"), default="lower")
    parser.add_argument("--animation-name", default="mixamo_walking_root_motion")
    parser.add_argument("--application-mode", choices=("additive", "absolute"), default="additive",
                        help="additive rebasing preserves the authored pose; absolute uses the Mixamo rest-relative pose")
    parser.add_argument("--include-root", action="store_true",
                        help="include the preprocessed Root bone and root_position channel")
    return parser.parse_args(argv)


def import_source(path: Path) -> tuple[bpy.types.Object, bpy.types.Action]:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=str(path))
    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if not armatures:
        raise RuntimeError("Mixamo FBX contains no armature")
    armature = armatures[0]
    action = armature.animation_data.action if armature.animation_data else None
    if action is None:
        actions = list(bpy.data.actions)
        if not actions:
            raise RuntimeError("Mixamo FBX contains no animation action")
        action = actions[0]
        armature.animation_data_create()
        armature.animation_data.action = action
    return armature, action


def import_target(path: Path) -> bpy.types.Object:
    bpy.ops.import_scene.gltf(filepath=str(path))
    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if not armatures:
        raise RuntimeError("target GLB contains no armature")
    return armatures[-1]


def local_rest(armature: bpy.types.Object, bone: bpy.types.EditBone | bpy.types.Bone) -> Matrix:
    parent = bone.parent
    return (parent.matrix_local.inverted() @ bone.matrix_local) if parent else bone.matrix_local.copy()


def pose_local(armature: bpy.types.Object, bone: bpy.types.PoseBone) -> Matrix:
    parent = bone.parent
    return (parent.matrix.inverted() @ bone.matrix) if parent else bone.matrix.copy()


def frame_quaternion(source: bpy.types.Object, target: bpy.types.Object,
                     source_name: str, target_name: str,
                     first_source_local: Matrix, axis_calibration: Matrix,
                     application_mode: str) -> tuple[float, float, float, float]:
    source_bone = source.data.bones.get(source_name)
    source_pose_bone = source.pose.bones.get(source_name)
    target_bone = target.data.bones.get(target_name)
    if source_bone is None or source_pose_bone is None or target_bone is None:
        raise RuntimeError("missing mapping %s -> %s" % (source_name, target_name))
    source_pose = pose_local(source, source_pose_bone)
    # Retarget the motion relative to the clip's first pose, not by copying
    # Mixamo's local quaternion directly. Mixamo and the Humanizer rig use
    # different bone axes (for example Mixamo's lower-leg rest basis is rotated
    # almost 90 degrees from the target). Applying the raw delta is what causes
    # the target legs to twist or stretch. The calibration matrix maps the
    # source bone-local basis into the target bone-local basis, while the
    # authored OTS pose supplies the target's actual starting orientation in
    # Godot during baking.
    if application_mode == "absolute":
        source_rest = local_rest(source, source_bone).to_quaternion().to_matrix().to_4x4()
        source_delta = source_rest.inverted() @ source_pose
    else:
        source_delta = first_source_local.inverted() @ source_pose
    target_delta = axis_calibration @ source_delta @ axis_calibration.inverted()
    q = target_delta.to_quaternion().normalized()
    return (float(q.x), float(q.y), float(q.z), float(q.w))


def axis_calibration(source: bpy.types.Object, target: bpy.types.Object,
                     source_name: str, target_name: str) -> Matrix:
    source_bone = source.data.bones.get(source_name)
    target_bone = target.data.bones.get(target_name)
    if source_bone is None or target_bone is None:
        raise RuntimeError("missing rest-basis mapping %s -> %s" % (source_name, target_name))
    source_rest = local_rest(source, source_bone).to_quaternion().to_matrix()
    target_rest = local_rest(target, target_bone).to_quaternion().to_matrix()
    return (target_rest.inverted() @ source_rest).to_4x4()


def frame_hip_position(source: bpy.types.Object, first_world_position: Vector) -> tuple[float, float, float]:
    """Return Mixamo pelvis bob/sway in the target's Godot axes.

    The FBX armature is imported with Blender's Z-up conversion. Evaluating
    the pelvis in world space before converting axes preserves translation in
    meters. Forward motion is discarded because CarrierTrajectory owns world
    translation; lateral sway and vertical compression remain useful local
    gait cues. The original rotation-only retarget omitted this channel, which
    made the legs overextend while the root stayed fixed.
    """
    pose_bone = source.pose.bones.get("mixamorig:Hips") or source.pose.bones.get("Hips")
    if pose_bone is None:
        raise RuntimeError("Mixamo source has no mixamorig:Hips pose bone")
    world_position = source.matrix_world @ pose_bone.matrix.translation
    displacement = world_position - first_world_position
    # Blender world (X, Y, Z) -> Godot local (X, Z, -Y). The third component
    # is forward/back and remains owned by the carrier trajectory.
    return (float(displacement.x), float(displacement.z), 0.0)


def frame_root_position(source: bpy.types.Object, first_world_position: Vector) -> tuple[float, float, float]:
    """Return root displacement in Godot axes.

    A clean Mixamo root is normally stationary for an in-place walk.  When a
    downloaded clip contains actual travel but Mixamo left that travel on the
    hips, the evaluated hips world position is used as a fallback instead of
    mistaking pelvis bob for locomotion.  Forward is Blender -Y after the FBX
    importer, which maps to Godot +Z in the target scene.
    """
    root = source.pose.bones.get("Root")
    # A Mixamo walk downloaded with the root option can still put travel on
    # Hips while the newly-created Root has no F-curves.  Read the evaluated
    # hips world position in that case; a small in-place bob is filtered out by
    # the caller's net-travel gate, while real locomotion is retained.
    source_bone = root if root is not None else (source.pose.bones.get("mixamorig:Hips") or source.pose.bones.get("Hips"))
    if source_bone is None:
        return (0.0, 0.0, 0.0)
    if root is not None and root.location.length_squared > 1.0e-10:
        displacement = (source.matrix_world @ root.matrix.translation) - (source.matrix_world @ source.data.bones["Root"].head_local)
    else:
        hips = source.pose.bones.get("mixamorig:Hips") or source.pose.bones.get("Hips")
        displacement = (source.matrix_world @ hips.matrix.translation) - first_world_position
    return (float(displacement.x), float(displacement.z), float(-displacement.y))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    source, action = import_source(args.source)
    scene = bpy.context.scene
    source_start, source_end = action.frame_range
    start = max(source_start, args.start)
    end = args.end if args.end > 0.0 else source_end
    end = min(end, source_end)
    if end <= start:
        raise RuntimeError("invalid source frame range")
    target = import_target(args.target)
    wanted = list(LOWER_BONES if args.bone_set == "lower" else BODY_BONES)
    if args.include_root and source.data.bones.get("Root") and target.data.bones.get("Root"):
        wanted.insert(0, "Root")
    mappings = [(src, dst) for src, dst in MIXAMO_TO_TARGET.items() if dst in wanted and source.data.bones.get(src) and target.data.bones.get(dst)]
    if len(mappings) != len(wanted):
        missing = sorted(set(wanted) - {dst for _, dst in mappings})
        raise RuntimeError("target/source mapping incomplete: %s" % ", ".join(missing))
    fps = float(scene.render.fps) / max(1.0e-8, float(scene.render.fps_base))
    frames = []
    # Blender's Scene.frame_set accepts integer frame numbers.  The CLI keeps
    # the arguments as floats so callers can pass a range without shell-side
    # coercion, but Mixamo actions are sampled on their integer source frames.
    scene.frame_set(int(round(start)))
    first_hips = source.pose.bones.get("mixamorig:Hips") or source.pose.bones.get("Hips")
    if first_hips is None:
        raise RuntimeError("source animation has no Hips pose bone")
    first_hip_world_position = source.matrix_world @ first_hips.matrix.translation
    first_source_locals: dict[str, Matrix] = {}
    calibrations: dict[tuple[str, str], Matrix] = {}
    for source_name, target_name in mappings:
        source_pose_bone = source.pose.bones.get(source_name)
        if source_pose_bone is None:
            raise RuntimeError("source pose is missing %s" % source_name)
        first_source_locals[source_name] = pose_local(source, source_pose_bone)
        calibrations[(source_name, target_name)] = axis_calibration(source, target, source_name, target_name)
    frame = int(round(start))
    end_frame = int(round(end))
    while frame <= end_frame:
        scene.frame_set(frame)
        record = {}
        for source_name, target_name in mappings:
            record[target_name] = list(frame_quaternion(
                source,
                target,
                source_name,
                target_name,
                first_source_locals[source_name],
                calibrations[(source_name, target_name)],
                args.application_mode,
            ))
        if args.bone_set == "lower":
            record["hip_position"] = list(frame_hip_position(source, first_hip_world_position))
        if args.include_root:
            record["root_position"] = list(frame_root_position(source, first_hip_world_position))
        frames.append(record)
        frame += 1
    if args.include_root:
        # Holding Walk is an in-place clip: its pelvis can sway a few
        # millimetres but that is not locomotion.  Only keep a root channel
        # when the evaluated clip travels at least five centimetres in the
        # horizontal plane; otherwise emit exact zeroes so the carrier route
        # remains the sole world-motion owner.
        first_root = frames[0].get("root_position", [0.0, 0.0, 0.0]) if frames else [0.0, 0.0, 0.0]
        last_root = frames[-1].get("root_position", [0.0, 0.0, 0.0]) if frames else [0.0, 0.0, 0.0]
        terminal_travel = ((float(last_root[0]) - float(first_root[0])) ** 2
                           + (float(last_root[2]) - float(first_root[2])) ** 2) ** 0.5
        if terminal_travel < 0.05:
            for record in frames:
                record["root_position"] = [0.0, 0.0, 0.0]
    # Blender's matrix-to-quaternion conversion is free to choose either sign
    # for the same rotation.  Godot's rotation tracks interpolate the stored
    # quaternion values, so an otherwise identical sign flip can become a
    # visible 360-degree knee swing. Make every bone's sequence sign-continuous
    # before it reaches the baker.
    previous_quaternions: dict[str, tuple[float, float, float, float]] = {}
    for record in frames:
        for bone_name in wanted:
            values = record.get(bone_name)
            if not isinstance(values, list) or len(values) < 4:
                continue
            current = tuple(float(value) for value in values[:4])
            previous = previous_quaternions.get(bone_name)
            if previous is not None and sum(a * b for a, b in zip(previous, current)) < 0.0:
                current = tuple(-value for value in current)
                record[bone_name] = list(current)
            previous_quaternions[bone_name] = current
    root_cycle_displacement = [0.0, 0.0, 0.0]
    root_cycle_distance = 0.0
    source_duration = float(max(1, len(frames) - 1)) / fps
    if args.include_root and frames:
        first_root = frames[0].get("root_position", [0.0, 0.0, 0.0])
        last_root = frames[-1].get("root_position", [0.0, 0.0, 0.0])
        root_cycle_displacement = [
            float(last_root[index]) - float(first_root[index]) for index in range(3)
        ]
        root_cycle_distance = (root_cycle_displacement[0] ** 2
                               + root_cycle_displacement[2] ** 2) ** 0.5
    result = {
        "schema": "godot-pose-motion",
        "source_video": str(args.source),
        "source_kind": "mixamo_fbx",
        "rotation_space": "godot4_absolute_local_bone_pose",
        "fps": fps,
        "frames": frames,
        "diagnostics": {
            "driven_bones": wanted,
            "source_action": action.name,
            "source_frame_range": [int(round(start)), end_frame],
            "bone_set": args.bone_set,
            "retarget_method": "first_pose_relative_local_rotation_with_per_bone_rest_axis_calibration",
            "retarget_application": args.application_mode,
            "hip_translation": "pelvis_local_lateral_and_vertical_only",
            "root_translation": "preprocessed_root_bone_world_displacement",
            "quaternion_sign_continuity": True,
        },
        "clip": {
            "kind": "mixamo_loaded_walk",
            "animation_name": args.animation_name,
            "source_start_frame": start,
            "source_end_frame": end,
            "seam_method": "baker repeats frame zero at loop endpoint",
            "seam_blend_frames": 0,
            "recommended_speed_mps": root_cycle_distance / source_duration if source_duration > 0.0 else 0.0,
        },
        "root_motion": {
            "mode": "baked_root_bone" if args.include_root else "off",
            "trajectory_owner": "OTSCarryClayProxy/CarrierTrajectory",
            "cycle_displacement": root_cycle_displacement,
            "captured_pace_cycle_distance_m": root_cycle_distance,
            "source_duration_seconds": source_duration,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("MIXAMO_RETARGET_OK action=%s frames=%d fps=%.3f bones=%d output=%s" % (action.name, len(frames), fps, len(wanted), args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]))
