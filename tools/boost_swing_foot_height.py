#!/usr/bin/env python3
"""Raise airborne feet in a fitted cyclic gait without moving planted feet.

The H3 carry reference partially occludes the carrier's shoes, so monocular
ankle height can collapse toward the ground.  This small target-rig pass uses
the fitted cycle's own contact mask, builds a smooth lift arc between contacts,
and solves only the two leg bones.  It preserves each foot's global
orientation and never changes the carrier root translation.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import numpy as np

import video_to_pose_stream as mocap


def _solve_leg(rig: mocap.Rig, pose: dict[str, np.ndarray], frame: int,
               side: str, target: np.ndarray, blend: float) -> None:
    upper_name, lower_name, foot_name = (
        ("LeftUpperLeg", "LeftLowerLeg", "LeftFoot") if side == "left"
        else ("RightUpperLeg", "RightLowerLeg", "RightFoot")
    )
    positions, rotations = mocap._fk_frame(rig, pose, frame)
    upper_index, lower_index, foot_index = (
        rig.index[upper_name], rig.index[lower_name], rig.index[foot_name]
    )
    hip = positions[upper_index]
    knee = positions[lower_index]
    ankle = positions[foot_index]
    thigh = float(np.linalg.norm(knee - hip))
    shin = float(np.linalg.norm(ankle - knee))
    distance = float(np.linalg.norm(target - hip))
    if min(thigh, shin, distance) <= 1.0e-8:
        return
    reachable = min(thigh + shin - 1.0e-6,
                    max(abs(thigh - shin) + 1.0e-6, distance))
    direction = (target - hip) / distance
    along = (thigh * thigh - shin * shin + reachable * reachable) / (2.0 * reachable)
    bend_height = math.sqrt(max(0.0, thigh * thigh - along * along))
    bend = knee - hip - direction * float(np.dot(knee - hip, direction))
    if np.linalg.norm(bend) <= 1.0e-8:
        bend = np.cross(direction, np.array([0.0, 0.0, 1.0]))
        if np.linalg.norm(bend) <= 1.0e-8:
            bend = np.cross(direction, np.array([1.0, 0.0, 0.0]))
    desired_knee = hip + direction * along + bend / max(1.0e-8, np.linalg.norm(bend)) * bend_height

    old_upper = pose[upper_name][frame].copy()
    old_lower = pose[lower_name][frame].copy()
    old_foot = pose[foot_name][frame].copy()
    old_foot_global = rotations[foot_index].copy()
    upper_parent = int(rig.parents[upper_index])
    parent_global = (np.array([0.0, 0.0, 0.0, 1.0]) if upper_parent < 0
                     else rotations[upper_parent])
    solved_upper_global = mocap.quat_multiply(
        mocap.quat_from_to(knee - hip, desired_knee - hip), rotations[upper_index]
    )
    pose[upper_name][frame] = mocap.quat_slerp(
        old_upper,
        mocap.quat_multiply(mocap.quat_conjugate(parent_global), solved_upper_global),
        blend,
    )
    positions, rotations = mocap._fk_frame(rig, pose, frame)
    knee = positions[lower_index]
    ankle = positions[foot_index]
    solved_lower_global = mocap.quat_multiply(
        mocap.quat_from_to(ankle - knee, target - knee), rotations[lower_index]
    )
    pose[lower_name][frame] = mocap.quat_slerp(
        old_lower,
        mocap.quat_multiply(mocap.quat_conjugate(rotations[upper_index]), solved_lower_global),
        blend,
    )
    positions, rotations = mocap._fk_frame(rig, pose, frame)
    pose[foot_name][frame] = mocap.quat_slerp(
        old_foot,
        mocap.quat_multiply(mocap.quat_conjugate(rotations[lower_index]), old_foot_global),
        blend,
    )


def _cyclic_lift(contact: list[bool], index: int, lift_m: float) -> float:
    if contact[index]:
        return 0.0
    count = len(contact)
    previous = next((d for d in range(1, count + 1) if contact[(index - d) % count]), count)
    following = next((d for d in range(1, count + 1) if contact[(index + d) % count]), count)
    span = max(1, previous + following)
    phase = float(previous) / float(span)
    return lift_m * math.sin(math.pi * phase)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--target-rig", type=Path, required=True)
    parser.add_argument("--lift-m", type=float, default=0.11,
                        help="peak additional airborne foot height in target units")
    parser.add_argument("--blend", type=float, default=0.82)
    parser.add_argument("--pace-mps", type=float,
                        help="optional captured pace metadata to preserve")
    args = parser.parse_args()
    cycle = json.loads(args.source.read_text(encoding="utf-8"))
    rig = mocap.load_gltf_rig(args.target_rig)
    frames = cycle.get("frames", [])
    if len(frames) < 2 or args.lift_m < 0.0 or not 0.0 <= args.blend <= 1.0:
        raise SystemExit("invalid cycle or lift parameters")
    pose = {name: np.asarray([frame[name] for frame in frames], dtype=np.float64)
            for name in rig.names}
    contacts_value = cycle.get("root_motion", {}).get("contacts", {})
    contacts = {
        side: [bool(x) for x in contacts_value.get(side, [False] * len(frames))]
        for side in ("left", "right")
    }
    if any(len(values) != len(frames) for values in contacts.values()):
        raise SystemExit("contact mask length does not match cycle")
    before: dict[str, float] = {}
    after: dict[str, float] = {}
    for side, foot_name in (("left", "LeftFoot"), ("right", "RightFoot")):
        foot_index = rig.index[foot_name]
        heights = []
        for frame in range(len(frames)):
            heights.append(mocap._fk_frame(rig, pose, frame)[0][foot_index][1])
        baseline = float(np.percentile(np.asarray(heights), 10.0))
        before[side] = float(max(heights) - baseline)
        for frame in range(len(frames)):
            lift = _cyclic_lift(contacts[side], frame, args.lift_m)
            if lift <= 0.0:
                continue
            positions, _ = mocap._fk_frame(rig, pose, frame)
            foot = positions[foot_index].copy()
            foot[1] = max(float(foot[1]), baseline + lift)
            _solve_leg(rig, pose, frame, side, foot, args.blend)
        heights_after = [mocap._fk_frame(rig, pose, i)[0][foot_index][1]
                         for i in range(len(frames))]
        after[side] = float(max(heights_after) - baseline)
    result = dict(cycle)
    result["frames"] = [
        {name: [round(float(value), 8) for value in pose[name][frame]]
         for name in rig.names}
        for frame in range(len(frames))
    ]
    result.setdefault("diagnostics", {})["swing_foot_height"] = {
        "lift_m": args.lift_m, "blend": args.blend,
        "before_range_m": before, "after_range_m": after,
        "method": "cyclic_contact_arc_target_rig_two_bone_ik",
    }
    # `fit_cycle_feet` computes a target-rig contact diagnostic speed, which is
    # useful for foot fitting but too conservative for the authored heavy-load
    # pace. Preserve the captured gait pace for the trajectory metadata.
    root = result.get("root_motion", {})
    if isinstance(root, dict):
        captured_distance = float(root.get("captured_pace_cycle_distance_m", 0.0))
        fps = float(result.get("fps", 0.0))
        if captured_distance > 0.0 and fps > 0.0:
            result.setdefault("clip", {})["recommended_speed_mps"] = (
                captured_distance / max(1.0e-6, len(frames) / fps)
            )
    if args.pace_mps is not None:
        result.setdefault("clip", {})["recommended_speed_mps"] = args.pace_mps
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("SWING_FOOT_HEIGHT_OK before=%s after=%s output=%s" % (before, after, args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
