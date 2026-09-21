#!/usr/bin/env python3
"""Extract a phase-aligned, in-place loop from a fitted motion cache."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any, Sequence

import numpy as np

import video_to_pose_stream as mocap


def quat_normalize(value: Sequence[float]) -> np.ndarray:
    result = np.asarray(value, dtype=np.float64)
    return result / max(1e-12, float(np.linalg.norm(result)))


def quat_slerp(first: Sequence[float], second: Sequence[float], amount: float) -> list[float]:
    a, b = quat_normalize(first), quat_normalize(second)
    dot = float(np.dot(a, b))
    if dot < 0.0:
        b, dot = -b, -dot
    if dot > 0.9995:
        value = quat_normalize(a + amount * (b - a))
    else:
        angle = math.acos(min(1.0, max(-1.0, dot)))
        value = (math.sin((1.0 - amount) * angle) * a
                 + math.sin(amount * angle) * b) / math.sin(angle)
    return [round(float(item), 8) for item in value]


def captured_directed_pace(
    positions: Sequence[Sequence[float]], start: int, end: int,
) -> tuple[list[float], float]:
    """Return monotonic captured travel samples and the cycle endpoint.

    Projecting onto the net horizontal travel axis removes lateral pelvis sway
    and vertical bob.  A same-phase endpoint just outside the sampled cycle is
    retained as its cycle distance, so the controller can cross the loop seam
    without dropping the final root-motion increment.
    """
    values = np.asarray(positions, dtype=np.float64)
    endpoint = min(len(values), end + 1 if end < len(values) else end)
    horizontal = values[start:endpoint, [0, 2]]
    if len(horizontal) < 2:
        return [0.0] * max(0, end - start), 0.0
    relative = horizontal - horizontal[0]
    net = relative[-1]
    if np.linalg.norm(net) > 1e-8:
        axis = net / np.linalg.norm(net)
    else:
        centered = relative - np.mean(relative, axis=0)
        _, _, principal = np.linalg.svd(centered, full_matrices=False)
        axis = principal[0]
    signed = relative @ axis
    monotonic = np.maximum.accumulate(np.maximum(signed - signed[0], 0.0))
    captured_distance = float(monotonic[-1])
    # The tracker reports long zero-motion plateaus followed by single-frame
    # corrections. Preserve the captured total and broad tempo changes, but
    # distribute positive increments over half a second to avoid root bursts.
    increments = np.maximum(np.diff(signed), 0.0)
    window = min(15, len(increments) if len(increments) % 2 == 1 else len(increments) - 1)
    if window >= 3 and float(np.sum(increments)) > 1e-12:
        kernel = np.bartlett(window)
        kernel /= np.sum(kernel)
        padding = window // 2
        increments = np.convolve(
            np.pad(increments, (padding, padding), mode="wrap"), kernel, mode="valid",
        )[:len(increments)]
    if float(np.sum(increments)) > 1e-12 and captured_distance > 0.0:
        increments *= captured_distance / float(np.sum(increments))
    progress = np.concatenate(([0.0], np.cumsum(increments)))
    sample_count = end - start
    samples = [round(float(value), 8) for value in progress[:sample_count]]
    return samples, round(captured_distance, 8)


def infer_target_cycle_contacts(
    rig: mocap.Rig,
    local_pose: dict[str, np.ndarray],
    fps: float,
    local_forward: Sequence[float],
) -> tuple[dict[str, list[bool]], float, dict[str, Any]]:
    """Infer cyclic stance intervals from the final avatar, not NLF flags.

    A planted foot is both low and moving backward relative to the pelvis. The
    median of those backward speeds is the gait's natural travel speed. This is
    intentionally target-rig based: source-detector contact flags may be absent
    or unreliable even when the fitted avatar feet are clear.
    """
    positions = mocap.fk_bone_positions(
        rig, local_pose, ("LeftFoot", "LeftToes", "RightFoot", "RightToes")
    )
    forward = np.asarray(local_forward, dtype=np.float64)
    forward[1] = 0.0
    forward /= max(1e-12, float(np.linalg.norm(forward)))
    contacts: dict[str, list[bool]] = {}
    candidate_speeds: list[float] = []
    diagnostics: dict[str, Any] = {}
    side_values: dict[str, tuple[np.ndarray, np.ndarray, float]] = {}
    for side, title in (("left", "Left"), ("right", "Right")):
        foot = positions[f"{title}Foot"]
        toes = positions[f"{title}Toes"]
        sole_height = np.minimum(foot[:, 1], toes[:, 1])
        cyclic_delta = np.roll(foot, -1, axis=0) - foot
        backward_speed = -(cyclic_delta @ forward) * fps
        height_limit = float(np.quantile(sole_height, 0.50))
        low_and_backward = (sole_height <= height_limit) & (backward_speed > 0.0)
        candidate_speeds.extend(float(value) for value in backward_speed[low_and_backward])
        side_values[side] = (sole_height, backward_speed, height_limit)
    natural_speed = float(np.median(candidate_speeds)) if candidate_speeds else 0.0
    if not math.isfinite(natural_speed) or natural_speed <= 1e-6:
        raise ValueError("could not infer a positive gait speed from target-rig feet")
    for side in ("left", "right"):
        sole_height, backward_speed, height_limit = side_values[side]
        active = ((sole_height <= height_limit)
                  & (backward_speed >= natural_speed * 0.15))
        contacts[side] = [bool(value) for value in active]
        diagnostics[side] = {
            "height_limit": height_limit,
            "contact_frames": int(np.count_nonzero(active)),
            "support_speed_median": (
                float(np.median(backward_speed[active])) if np.any(active) else 0.0
            ),
        }
    diagnostics["recommended_speed_mps"] = natural_speed
    diagnostics["method"] = "target_sole_height+cyclic_backward_foot_velocity"
    return contacts, natural_speed, diagnostics


def solve_bilateral_contact_pace(
    rig: mocap.Rig,
    local_pose: dict[str, np.ndarray],
    contacts: dict[str, list[bool]],
    natural_speed: float,
    fps: float,
    local_forward: Sequence[float],
) -> tuple[list[float], list[float], float, list[float], dict[str, float]]:
    """Solve cyclic root distance from alternating target-rig foot anchors.

    Continuing stance feet constrain root distance exactly. A newly planted
    foot receives its anchor at the already accumulated root position, so a
    left/right support handoff cannot reset the character to either foot. When
    both feet are planted, the least-squares mean shares any residual equally.
    Three repeated cycles make boundary-spanning contacts continuous.
    """
    positions = mocap.fk_bone_positions(rig, local_pose, ("LeftFoot", "RightFoot"))
    forward = np.asarray(local_forward, dtype=np.float64)
    forward[1] = 0.0
    forward /= max(1e-12, float(np.linalg.norm(forward)))
    horizontal = {
        "left": positions["LeftFoot"][:, [0, 2]],
        "right": positions["RightFoot"][:, [0, 2]],
    }
    frame_count = len(horizontal["left"])
    repeated_horizontal = {side: np.tile(values, (3, 1)) for side, values in horizontal.items()}
    repeated_contacts = {
        side: np.asarray(values * 3, dtype=bool) for side, values in contacts.items()
    }
    repeated_count = frame_count * 3
    root_xz = np.zeros((repeated_count, 2), dtype=np.float64)
    anchors: dict[str, np.ndarray | None] = {"left": None, "right": None}
    previous = {"left": False, "right": False}
    nominal_step = natural_speed / fps
    lock_errors: list[float] = []
    for frame in range(repeated_count):
        nominal = (root_xz[frame - 1] + forward[[0, 2]] * nominal_step
                   if frame > 0 else np.zeros(2, dtype=np.float64))
        candidates: list[np.ndarray] = []
        for side in ("left", "right"):
            active = bool(repeated_contacts[side][frame])
            if active and previous[side] and anchors[side] is not None:
                candidates.append(anchors[side] - repeated_horizontal[side][frame])
        root_xz[frame] = np.mean(candidates, axis=0) if candidates else nominal
        for side in ("left", "right"):
            active = bool(repeated_contacts[side][frame])
            if active and not previous[side]:
                anchors[side] = root_xz[frame] + repeated_horizontal[side][frame]
            elif not active:
                anchors[side] = None
            if active and previous[side] and anchors[side] is not None:
                lock_errors.append(float(np.linalg.norm(
                    root_xz[frame] + repeated_horizontal[side][frame] - anchors[side]
                )))
            previous[side] = active
    start = frame_count
    base = root_xz[start].copy()
    samples_xz = root_xz[start:start + frame_count] - base
    cycle_vector = root_xz[start + frame_count] - base
    cycle_distance = float(np.linalg.norm(cycle_vector))
    gait_forward = cycle_vector / max(1e-12, cycle_distance)
    gait_side = np.array([-gait_forward[1], gait_forward[0]], dtype=np.float64)
    samples = samples_xz @ gait_forward
    lateral = samples_xz @ gait_side
    # Tiny numerical reversals during noisy double support are not meaningful
    # trajectory commands. Preserve timing while guaranteeing forward travel.
    samples = np.maximum.accumulate(samples)
    cycle_distance = max(cycle_distance, float(samples[-1]))
    return (
        [round(float(value), 8) for value in samples],
        [round(float(value), 8) for value in lateral],
        round(cycle_distance, 8),
        [round(float(gait_forward[0]), 8), 0.0, round(float(gait_forward[1]), 8)],
        {
            "nominal_speed_mps": natural_speed,
            "cycle_distance_m": cycle_distance,
            "local_travel_axis_x": float(gait_forward[0]),
            "local_travel_axis_z": float(gait_forward[1]),
            "lateral_sway_min_m": float(np.min(lateral)),
            "lateral_sway_max_m": float(np.max(lateral)),
            "mean_stance_lock_error_m": float(np.mean(lock_errors)) if lock_errors else 0.0,
            "max_stance_lock_error_m": float(np.max(lock_errors)) if lock_errors else 0.0,
        },
    )


def fit_cycle_feet(
    cycle: dict[str, Any],
    target_rig_path: Path,
    skeleton_origin_y: float,
    ground_clearance: float,
    ik_strength: float = 1.0,
) -> dict[str, Any]:
    """Fit cyclic stance feet while preserving their captured orientations."""
    rig = mocap.load_gltf_rig(target_rig_path)
    frames = cycle["frames"]
    frame_count = len(frames)
    local_pose = {
        name: np.asarray([frame[name] for frame in frames], dtype=np.float64)
        for name in rig.names
    }
    root = cycle["root_motion"]
    local_forward = root.get("local_forward", [0.0, 0.0, -1.0])
    contacts, natural_speed, contact_diagnostics = infer_target_cycle_contacts(
        rig, local_pose, float(cycle["fps"]), local_forward,
    )
    contact_pace, contact_lateral, contact_cycle_distance, contact_forward, \
            contact_pace_diagnostics = \
        solve_bilateral_contact_pace(
            rig, local_pose, contacts, natural_speed,
            float(cycle["fps"]), local_forward,
        )
    root["foot_contact_pace_distances_m"] = contact_pace
    root["foot_contact_lateral_offsets_m"] = contact_lateral
    root["foot_contact_pace_cycle_distance_m"] = contact_cycle_distance
    root["foot_contact_local_forward"] = contact_forward
    root["foot_contact_pace_method"] = "bilateral_cyclic_stance_anchors"

    # Solve three copies as one continuous walk and retain the middle copy.
    # This lets a stance interval cross the loop boundary without receiving a
    # fresh ankle anchor or a visibly different correction at frame zero.
    repeated_pose = {name: np.tile(values, (3, 1)) for name, values in local_pose.items()}
    repeated_contacts = {side: values * 3 for side, values in contacts.items()}
    repeated_count = frame_count * 3
    distances = np.arange(repeated_count, dtype=np.float64) * natural_speed / float(cycle["fps"])
    repeated_root = np.zeros((repeated_count, 3), dtype=np.float64)
    repeated_root[:, 2] = distances
    repeated_yaw = np.zeros(repeated_count, dtype=np.float64)
    fitted_foot_globals = {}
    for foot_name in ("LeftFoot", "RightFoot"):
        fitted_foot_globals[foot_name] = []
        for frame in range(repeated_count):
            _, rotations = mocap._fk_frame(rig, repeated_pose, frame)
            fitted_foot_globals[foot_name].append(rotations[rig.index[foot_name]].copy())
    ik_diagnostics = mocap.solve_planted_foot_ik(
        rig, repeated_pose, repeated_root, repeated_yaw, repeated_contacts,
        local_forward, ik_strength,
    )
    middle = slice(frame_count, frame_count * 2)
    fitted_pose = {name: values[middle].copy() for name, values in repeated_pose.items()}

    # Guard the defining contract: position IK must not yaw or roll the feet.
    max_foot_orientation_error = 0.0
    for foot_name in ("LeftFoot", "RightFoot"):
        for frame in range(frame_count):
            _, rotations = mocap._fk_frame(rig, fitted_pose, frame)
            before = fitted_foot_globals[foot_name][frame_count + frame]
            after = rotations[rig.index[foot_name]]
            dot = min(1.0, max(-1.0, abs(float(np.dot(before, after)))))
            max_foot_orientation_error = max(max_foot_orientation_error, 2.0 * math.acos(dot))

    feet = mocap.fk_bone_positions(
        rig, fitted_pose, ("LeftFoot", "LeftToes", "RightFoot", "RightToes")
    )
    in_place_root = np.zeros((frame_count, 3), dtype=np.float64)
    in_place_root, ground_diagnostics = mocap.apply_ground_lock(
        in_place_root,
        {
            "left_foot": feet["LeftFoot"], "left_toes": feet["LeftToes"],
            "right_foot": feet["RightFoot"], "right_toes": feet["RightToes"],
        },
        contacts,
        skeleton_origin_y,
        ground_clearance,
    )
    cycle["frames"] = [
        {name: [round(float(value), 8) for value in fitted_pose[name][frame]]
         for name in rig.names}
        for frame in range(frame_count)
    ]
    root["positions"] = [
        [0.0, round(float(position[1]), 8), 0.0] for position in in_place_root
    ]
    root["contacts"] = contacts
    cycle["clip"]["recommended_speed_mps"] = natural_speed
    cycle["clip"]["foot_fit"] = (
        "target_rig_cyclic_planted_foot_ik"
        if ik_strength > 0.0 else "disabled_preserve_captured_leg_motion"
    )
    cycle.setdefault("diagnostics", {})["cycle_foot_fit"] = {
        "contacts": contact_diagnostics,
        "planted_foot_ik": ik_diagnostics,
        "ground_lock": ground_diagnostics,
        "foot_contact_pace": contact_pace_diagnostics,
        "max_preserved_foot_orientation_error_radians": max_foot_orientation_error,
    }
    return cycle


def extract_cycle(source: dict[str, Any], start: int, end: int,
                  animation_name: str, seam_blend_frames: int = 0) -> dict[str, Any]:
    frames = source["frames"]
    if start < 0 or end <= start or end > len(frames):
        raise ValueError("cycle requires 0 <= start < end <= source frame_count")
    if end == len(frames) and seam_blend_frames <= 0:
        raise ValueError("a full-source cycle requires seam_blend_frames > 0")
    # ``end`` is the same gait phase as ``start``. Keep it as the seam sample,
    # not a second frame in the cycle, and meet halfway between the two fitted
    # estimates so loop wrap is exact without favoring either observation.
    cycle_frames = [dict(frame) for frame in frames[start:end]]
    if seam_blend_frames > 0:
        blend_count = min(seam_blend_frames, len(cycle_frames) // 2)
        for bone_name in cycle_frames[0]:
            midpoint = quat_slerp(
                cycle_frames[0][bone_name], cycle_frames[-1][bone_name], 0.5,
            )
            for offset in range(blend_count):
                linear = (blend_count - offset) / blend_count
                weight = linear * linear * (3.0 - 2.0 * linear)
                cycle_frames[offset][bone_name] = quat_slerp(
                    cycle_frames[offset][bone_name], midpoint, weight,
                )
                cycle_frames[-1 - offset][bone_name] = quat_slerp(
                    cycle_frames[-1 - offset][bone_name], midpoint, weight,
                )
    else:
        for bone_name in cycle_frames[0]:
            cycle_frames[0][bone_name] = quat_slerp(
                frames[start][bone_name], frames[end][bone_name], 0.5,
            )
    fps = float(source["fps"])
    root = source.get("root_motion", {})
    source_positions = root.get("positions", [])
    vertical = []
    captured_pace: list[float] = []
    captured_cycle_distance = 0.0
    if len(source_positions) == len(frames):
        captured_pace, captured_cycle_distance = captured_directed_pace(
            source_positions, start, end,
        )
        vertical = [[0.0, float(source_positions[index][1]), 0.0]
                    for index in range(start, end)]
        if seam_blend_frames > 0:
            blend_count = min(seam_blend_frames, len(vertical) // 2)
            midpoint_y = (vertical[0][1] + vertical[-1][1]) * 0.5
            for offset in range(blend_count):
                linear = (blend_count - offset) / blend_count
                weight = linear * linear * (3.0 - 2.0 * linear)
                vertical[offset][1] += (midpoint_y - vertical[offset][1]) * weight
                vertical[-1 - offset][1] += (midpoint_y - vertical[-1 - offset][1]) * weight
        else:
            vertical[0][1] = (float(source_positions[start][1])
                              + float(source_positions[end][1])) * 0.5
    horizontal = np.asarray(source_positions, dtype=float)[:, [0, 2]]
    steps = np.linalg.norm(np.diff(horizontal, axis=0), axis=1)
    recommended_speed = float(np.median(steps) * fps)
    contacts = root.get("contacts", {})
    cycle_contacts = {
        side: list(values[start:end])
        for side, values in contacts.items()
        if isinstance(values, list) and len(values) == len(frames)
    }
    result = dict(source)
    result.update({
        "duration": len(cycle_frames) / fps,
        "frame_count": len(cycle_frames),
        "frames": cycle_frames,
        "clip": {
            "kind": "looping_gait_cycle",
            "animation_name": animation_name,
            "source_start_frame": start,
            "source_end_frame": end,
            "source_start_seconds": start / fps,
            "source_end_seconds": end / fps,
            "seam_method": (
                "smooth_window_to_shared_quaternion_midpoint"
                if seam_blend_frames > 0 else "quaternion_midpoint_then_exact_loop_wrap"
            ),
            "seam_blend_frames": seam_blend_frames,
            "recommended_speed_mps": recommended_speed,
        },
        "root_motion": {
            "positions": vertical,
            "rotation_y": [0.0] * len(cycle_frames),
            "heading_directions": [],
            "local_forward": root.get("local_forward", [0.0, 0.0, -1.0]),
            "upright_root": True,
            "scene_origin_node": root.get("scene_origin_node", ""),
            "ground_y": root.get("ground_y", 0.0),
            "contacts": cycle_contacts,
            "bake_mode": "in_place_cycle",
            "captured_pace_distances_m": captured_pace,
            "captured_pace_cycle_distance_m": captured_cycle_distance,
            "captured_pace_method": "smoothed_positive_net_horizontal_root_projection",
            "captured_pace_smoothing_frames": 15,
        },
    })
    result.setdefault("diagnostics", {})["cycle_extraction"] = result["clip"]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--start-frame", type=int, required=True)
    parser.add_argument("--end-frame", type=int, required=True)
    parser.add_argument("--animation-name", default="female_walk_cycle")
    parser.add_argument("--seam-blend-frames", type=int, default=0,
                        help="smooth this many frames at both ends toward a shared loop pose")
    parser.add_argument("--fit-planted-feet", action="store_true",
                        help="infer cyclic contacts on the target rig and fit planted feet")
    parser.add_argument("--target-rig", type=Path,
                        help="target GLB; defaults to source cache target_rig")
    parser.add_argument("--skeleton-origin-y", type=float, default=0.0)
    parser.add_argument("--ground-clearance", type=float, default=0.0)
    parser.add_argument("--ik-strength", type=float, default=0.0,
                        help="optional planted-foot leg IK; 0 preserves captured leg motion")
    args = parser.parse_args()
    source = json.loads(args.source.read_text(encoding="utf-8"))
    result = extract_cycle(
        source, args.start_frame, args.end_frame,
        args.animation_name, args.seam_blend_frames,
    )
    if args.fit_planted_feet:
        target_rig = args.target_rig or Path(str(source.get("target_rig", "")))
        if not target_rig.is_file():
            parser.error("--fit-planted-feet needs an existing --target-rig or source target_rig")
        result = fit_cycle_feet(
            result, target_rig, args.skeleton_origin_y,
            args.ground_clearance, args.ik_strength,
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    temporary.replace(args.output)
    clip = result["clip"]
    print("Extracted frames %d..%d as %.3fs loop; recommended speed %.5f m/s -> %s" % (
        args.start_frame, args.end_frame, result["duration"],
        clip["recommended_speed_mps"], args.output,
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
