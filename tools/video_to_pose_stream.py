#!/usr/bin/env python3
"""Fit a short video to the female humanoid and stream ``pose.frame`` FK.

This tool deliberately keeps motion capture outside Godot.  NLF supplies dense
3D joint observations, SAM 3D Body supplies sparse orientation/twist anchors,
and a small temporal solver retargets the fused result to the project's actual
56-bone rest rig.  The finished frames are stored as JSON and can be replayed
through the existing newline-delimited TCP protocol; no Animation resource is
created or modified.

Apple Silicon note: the public NLF multiperson wrapper converts predictions to
float64, which MPS cannot execute.  ``NlfObserver`` uses the same scripted crop
network and crop transform directly, keeping inference in float32/float16.  SAM
3D Body's MHR forward pass has the same float64 limitation, so SAM anchors run
on CPU by default while NLF remains dense and fast on MPS.
"""

from __future__ import annotations

import argparse
import json
import math
import socket
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import numpy as np


PROTOCOL_NAME = "godot-pose-stream"
PROTOCOL_VERSION = 1

MHR_TO_GODOT = {
    "Hips": "root",
    "LeftUpperLeg": "l_upleg",
    "LeftLowerLeg": "l_lowleg",
    "LeftFoot": "l_foot",
    "LeftToes": "l_ball",
    "RightUpperLeg": "r_upleg",
    "RightLowerLeg": "r_lowleg",
    "RightFoot": "r_foot",
    "RightToes": "r_ball",
    "Spine": "c_spine0",
    "Chest": "c_spine1",
    "UpperChest": "c_spine3",
    "LeftShoulder": "l_clavicle",
    "LeftUpperArm": "l_uparm",
    "LeftLowerArm": "l_lowarm",
    "LeftHand": "l_wrist",
    "RightShoulder": "r_clavicle",
    "RightUpperArm": "r_uparm",
    "RightLowerArm": "r_lowarm",
    "RightHand": "r_wrist",
    "Neck": "c_neck",
    "Head": "c_head",
    "LeftIndexProximal": "l_index1",
    "LeftIndexIntermediate": "l_index2",
    "LeftIndexDistal": "l_index3",
    "LeftMiddleProximal": "l_middle1",
    "LeftMiddleIntermediate": "l_middle2",
    "LeftMiddleDistal": "l_middle3",
    "LeftLittleProximal": "l_pinky1",
    "LeftLittleIntermediate": "l_pinky2",
    "LeftLittleDistal": "l_pinky3",
    "LeftRingProximal": "l_ring1",
    "LeftRingIntermediate": "l_ring2",
    "LeftRingDistal": "l_ring3",
    "LeftThumbMetacarpal": "l_thumb0",
    "LeftThumbProximal": "l_thumb1",
    "LeftThumbDistal": "l_thumb3",
    "RightIndexProximal": "r_index1",
    "RightIndexIntermediate": "r_index2",
    "RightIndexDistal": "r_index3",
    "RightMiddleProximal": "r_middle1",
    "RightMiddleIntermediate": "r_middle2",
    "RightMiddleDistal": "r_middle3",
    "RightLittleProximal": "r_pinky1",
    "RightLittleIntermediate": "r_pinky2",
    "RightLittleDistal": "r_pinky3",
    "RightRingProximal": "r_ring1",
    "RightRingIntermediate": "r_ring2",
    "RightRingDistal": "r_ring3",
    "RightThumbMetacarpal": "r_thumb0",
    "RightThumbProximal": "r_thumb1",
    "RightThumbDistal": "r_thumb3",
}

# NLF SMPL-24 segments used to correct the direction (swing) of a SAM anchor.
# Twist remains supplied by SAM 3D Body, avoiding the single-view roll ambiguity.
NLF_SEGMENTS = {
    "Hips": ("pelv", "spi1"),
    "LeftUpperLeg": ("lhip", "lkne"),
    "LeftLowerLeg": ("lkne", "lank"),
    "LeftFoot": ("lank", "ltoe"),
    "RightUpperLeg": ("rhip", "rkne"),
    "RightLowerLeg": ("rkne", "rank"),
    "RightFoot": ("rank", "rtoe"),
    "Spine": ("spi1", "spi2"),
    "Chest": ("spi2", "spi3"),
    "UpperChest": ("spi3", "neck"),
    "LeftShoulder": ("lcla", "lsho"),
    "LeftUpperArm": ("lsho", "lelb"),
    "LeftLowerArm": ("lelb", "lwri"),
    "LeftHand": ("lwri", "lhan"),
    "RightShoulder": ("rcla", "rsho"),
    "RightUpperArm": ("rsho", "relb"),
    "RightLowerArm": ("relb", "rwri"),
    "RightHand": ("rwri", "rhan"),
    "Neck": ("neck", "head"),
}

# A branching humanoid cannot infer its aiming child by choosing the longest
# offset: Hips would choose a thigh instead of Spine.  Make each observed
# segment explicit so swing fitting follows the intended anatomical chain.
TARGET_SEGMENT_CHILD = {
    "Hips": "Spine",
    "LeftUpperLeg": "LeftLowerLeg",
    "LeftLowerLeg": "LeftFoot",
    "LeftFoot": "LeftToes",
    "RightUpperLeg": "RightLowerLeg",
    "RightLowerLeg": "RightFoot",
    "RightFoot": "RightToes",
    "Spine": "Chest",
    "Chest": "UpperChest",
    "UpperChest": "Neck",
    "LeftShoulder": "LeftUpperArm",
    "LeftUpperArm": "LeftLowerArm",
    "LeftLowerArm": "LeftHand",
    "LeftHand": "LeftMiddleProximal",
    "RightShoulder": "RightUpperArm",
    "RightUpperArm": "RightLowerArm",
    "RightLowerArm": "RightHand",
    "RightHand": "RightMiddleProximal",
    "Neck": "Head",
}

# Only axial body joints benefit from SAM's single-view twist estimate. Applying
# that estimate to arms, wrists, feet, or fingers transfers MHR bone roll into a
# differently oriented Godot rig and produces corkscrew limbs. Those chains are
# instead reconstructed below with NLF's observed segment directions and a
# minimal (zero-added-twist) swing.
SAM_AXIAL_BONES = {"Hips", "Spine", "Chest", "UpperChest", "Neck", "Head"}


def _normalized(value: np.ndarray, fallback: np.ndarray | None = None) -> np.ndarray:
    norm = float(np.linalg.norm(value))
    if norm < 1e-9:
        if fallback is None:
            raise ValueError("cannot normalize a zero vector")
        return fallback.copy()
    return value / norm


def quat_normalize(q: np.ndarray) -> np.ndarray:
    return _normalized(np.asarray(q, dtype=np.float64), np.array([0.0, 0.0, 0.0, 1.0]))


def quat_conjugate(q: np.ndarray) -> np.ndarray:
    q = np.asarray(q, dtype=np.float64)
    return np.array([-q[0], -q[1], -q[2], q[3]], dtype=np.float64)


def quat_multiply(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return quat_normalize(np.array([
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    ]))


def quat_slerp(a: np.ndarray, b: np.ndarray, amount: float) -> np.ndarray:
    a = quat_normalize(a)
    b = quat_normalize(b)
    dot = float(np.dot(a, b))
    if dot < 0.0:
        b = -b
        dot = -dot
    dot = min(1.0, max(-1.0, dot))
    if dot > 0.9995:
        return quat_normalize(a + amount * (b - a))
    theta = math.acos(dot)
    sin_theta = math.sin(theta)
    return quat_normalize(
        math.sin((1.0 - amount) * theta) / sin_theta * a
        + math.sin(amount * theta) / sin_theta * b
    )


def quat_angle(a: np.ndarray, b: np.ndarray) -> float:
    dot = abs(float(np.dot(quat_normalize(a), quat_normalize(b))))
    return 2.0 * math.acos(min(1.0, max(-1.0, dot)))


def quat_to_matrix(q: Sequence[float]) -> np.ndarray:
    x, y, z, w = quat_normalize(np.asarray(q, dtype=np.float64))
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ], dtype=np.float64)


def matrix_to_quat(matrix: np.ndarray) -> np.ndarray:
    """Convert a proper 3x3 rotation matrix to an [x,y,z,w] quaternion."""
    m = np.asarray(matrix, dtype=np.float64)
    trace = float(np.trace(m))
    if trace > 0.0:
        s = math.sqrt(trace + 1.0) * 2.0
        q = np.array([(m[2, 1] - m[1, 2]) / s,
                      (m[0, 2] - m[2, 0]) / s,
                      (m[1, 0] - m[0, 1]) / s,
                      0.25 * s])
    else:
        index = int(np.argmax(np.diag(m)))
        if index == 0:
            s = math.sqrt(max(1e-12, 1.0 + m[0, 0] - m[1, 1] - m[2, 2])) * 2.0
            q = np.array([0.25 * s, (m[0, 1] + m[1, 0]) / s,
                          (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s])
        elif index == 1:
            s = math.sqrt(max(1e-12, 1.0 + m[1, 1] - m[0, 0] - m[2, 2])) * 2.0
            q = np.array([(m[0, 1] + m[1, 0]) / s, 0.25 * s,
                          (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s])
        else:
            s = math.sqrt(max(1e-12, 1.0 + m[2, 2] - m[0, 0] - m[1, 1])) * 2.0
            q = np.array([(m[0, 2] + m[2, 0]) / s,
                          (m[1, 2] + m[2, 1]) / s, 0.25 * s,
                          (m[1, 0] - m[0, 1]) / s])
    return quat_normalize(q)


def quat_from_to(source: np.ndarray, target: np.ndarray) -> np.ndarray:
    source = _normalized(source)
    target = _normalized(target)
    dot = float(np.dot(source, target))
    if dot > 1.0 - 1e-8:
        return np.array([0.0, 0.0, 0.0, 1.0])
    if dot < -1.0 + 1e-8:
        axis = np.cross(source, np.array([1.0, 0.0, 0.0]))
        if np.linalg.norm(axis) < 1e-6:
            axis = np.cross(source, np.array([0.0, 1.0, 0.0]))
        axis = _normalized(axis)
        return np.array([axis[0], axis[1], axis[2], 0.0])
    cross = np.cross(source, target)
    return quat_normalize(np.array([cross[0], cross[1], cross[2], 1.0 + dot]))


def rotate_vector(q: np.ndarray, vector: np.ndarray) -> np.ndarray:
    return quat_to_matrix(q) @ vector


def interpolate_samples(values: np.ndarray, sample_indices: Sequence[int], frame_count: int,
                        quaternion: bool = False) -> np.ndarray:
    if len(sample_indices) != len(values) or not sample_indices:
        raise ValueError("sample indices and values do not match")
    output = []
    for frame in range(frame_count):
        right = int(np.searchsorted(sample_indices, frame, side="right"))
        if right == 0:
            output.append(values[0])
            continue
        if right >= len(sample_indices):
            output.append(values[-1])
            continue
        left = right - 1
        span = sample_indices[right] - sample_indices[left]
        amount = (frame - sample_indices[left]) / max(1, span)
        if quaternion:
            output.append(quat_slerp(values[left], values[right], amount))
        else:
            output.append(values[left] * (1.0 - amount) + values[right] * amount)
    return np.asarray(output)


def temporal_quaternion_filter(values: np.ndarray, responsiveness: float) -> np.ndarray:
    """Reject isolated flips, enforce hemisphere continuity, then smooth both ways."""
    result = np.asarray([quat_normalize(q) for q in values])
    for index in range(1, len(result)):
        if np.dot(result[index - 1], result[index]) < 0.0:
            result[index] *= -1.0
    for index in range(1, len(result) - 1):
        outer = quat_angle(result[index - 1], result[index + 1])
        if (quat_angle(result[index - 1], result[index]) > math.radians(65.0)
                and outer < math.radians(28.0)):
            result[index] = quat_slerp(result[index - 1], result[index + 1], 0.5)
    forward = result.copy()
    for index in range(1, len(forward)):
        forward[index] = quat_slerp(forward[index - 1], result[index], responsiveness)
    backward = result.copy()
    for index in range(len(backward) - 2, -1, -1):
        backward[index] = quat_slerp(backward[index + 1], result[index], responsiveness)
    return np.asarray([quat_slerp(forward[i], backward[i], 0.5) for i in range(len(result))])


def median_smooth_positions(values: np.ndarray) -> np.ndarray:
    result = values.copy()
    if len(values) >= 3:
        for index in range(1, len(values) - 1):
            result[index] = np.median(values[index - 1:index + 2], axis=0)
    # A short symmetric [1,2,3,2,1] kernel suppresses detector shimmer without
    # erasing the dancer's fast hip direction changes.
    padded = np.pad(result, ((2, 2), (0, 0), (0, 0)), mode="edge")
    return sum(weight * padded[offset:offset + len(result)]
               for offset, weight in enumerate((1, 2, 3, 2, 1))) / 9.0


def _json_value(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, Mapping):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if hasattr(value, "detach"):
        return _json_value(value.detach().cpu().numpy())
    return str(value)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(_json_value(value), indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


@dataclass
class Rig:
    names: list[str]
    parents: np.ndarray
    translations: np.ndarray
    rest_local: np.ndarray
    rest_global: np.ndarray

    @property
    def index(self) -> dict[str, int]:
        return {name: idx for idx, name in enumerate(self.names)}


def load_gltf_rig(path: Path) -> Rig:
    """Read joint hierarchy/rest transforms directly from GLB without Godot."""
    data = path.read_bytes()
    if data[:4] != b"glTF":
        raise ValueError(f"not a binary glTF file: {path}")
    json_length, chunk_type = struct.unpack_from("<II", data, 12)
    if chunk_type != 0x4E4F534A:
        raise ValueError(f"first GLB chunk is not JSON: {path}")
    document = json.loads(data[20:20 + json_length].decode("utf-8"))
    skins = document.get("skins", [])
    if not skins:
        raise ValueError(f"GLB contains no skin: {path}")
    skin = max(skins, key=lambda item: len(item.get("joints", [])))
    joint_nodes = [int(item) for item in skin["joints"]]
    node_to_joint = {node: index for index, node in enumerate(joint_nodes)}
    names: list[str] = []
    parents = np.full(len(joint_nodes), -1, dtype=np.int32)
    translations = np.zeros((len(joint_nodes), 3), dtype=np.float64)
    local = np.tile(np.array([0.0, 0.0, 0.0, 1.0]), (len(joint_nodes), 1))
    node_parents: dict[int, int] = {}
    for parent_index, node in enumerate(document["nodes"]):
        for child in node.get("children", []):
            node_parents[int(child)] = parent_index
    for index, node_index in enumerate(joint_nodes):
        node = document["nodes"][node_index]
        names.append(str(node.get("name", f"Bone{index}")))
        translations[index] = np.asarray(node.get("translation", [0.0, 0.0, 0.0]), dtype=np.float64)
        local[index] = quat_normalize(np.asarray(node.get("rotation", [0.0, 0.0, 0.0, 1.0])))
        parent_node = node_parents.get(node_index)
        if parent_node in node_to_joint:
            parents[index] = node_to_joint[parent_node]
    global_rest = np.empty_like(local)
    for index in range(len(names)):
        parent = int(parents[index])
        global_rest[index] = local[index] if parent < 0 else quat_multiply(global_rest[parent], local[index])
    return Rig(names, parents, translations, local, global_rest)


def load_mhr_rig(model_path: Path) -> Rig:
    import torch  # type: ignore

    model = torch.jit.load(str(model_path), map_location="cpu")
    skeleton = model.character_torch.skeleton
    names = [str(item) for item in model.get_joint_names()]
    parents = skeleton.joint_parents.detach().cpu().numpy().astype(np.int32)
    translations = skeleton.joint_translation_offsets.detach().cpu().numpy().astype(np.float64) / 100.0
    local = skeleton.joint_prerotations.detach().cpu().numpy().astype(np.float64)
    global_rest = np.empty_like(local)
    for index in range(len(names)):
        parent = int(parents[index])
        global_rest[index] = local[index] if parent < 0 else quat_multiply(global_rest[parent], local[index])
    return Rig(names, parents, translations, local, global_rest)


def decode_video(path: Path, duration: float, output_fps: float) -> tuple[list[np.ndarray], float]:
    import cv2  # type: ignore

    capture = cv2.VideoCapture(str(path))
    if not capture.isOpened():
        raise RuntimeError(f"could not open input video: {path}")
    source_fps = float(capture.get(cv2.CAP_PROP_FPS))
    if not math.isfinite(source_fps) or source_fps <= 0.0:
        source_fps = output_fps
    wanted_count = max(1, int(round(duration * output_fps)))
    wanted_source = [int(round(index / output_fps * source_fps)) for index in range(wanted_count)]
    source_to_outputs: dict[int, list[int]] = {}
    for output_index, source_index in enumerate(wanted_source):
        source_to_outputs.setdefault(source_index, []).append(output_index)
    frames: list[np.ndarray | None] = [None] * wanted_count
    source_index = 0
    last_rgb: np.ndarray | None = None
    while source_index <= wanted_source[-1]:
        ok, bgr = capture.read()
        if not ok:
            break
        if source_index in source_to_outputs:
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            last_rgb = rgb
            for output_index in source_to_outputs[source_index]:
                frames[output_index] = rgb.copy()
        source_index += 1
    capture.release()
    if last_rgb is None:
        raise RuntimeError(f"video contains no decodable frames: {path}")
    for index, frame in enumerate(frames):
        if frame is None:
            frames[index] = last_rgb.copy()
    return [frame for frame in frames if frame is not None], source_fps


class NlfObserver:
    """Dense NLF SMPL-24 inference using the MPS-safe crop-model path."""

    def __init__(self, model_path: Path, device: str, batch_size: int = 8):
        import torch  # type: ignore
        import torchvision  # noqa: F401  # registers torchvision::nms before jit.load

        self.torch = torch
        self.device = torch.device(device)
        self.model = torch.jit.load(str(model_path), map_location=self.device).eval()
        self.batch_size = batch_size
        indices = self.model.per_skeleton_indices["smpl_24"].to(self.device).long()
        canonical = self.model.crop_model.canonical_locs().detach().index_select(0, indices)
        self.weights = self.model.get_weights_for_canonical_points(canonical)
        self.names = [str(name) for name in self.model.per_skeleton_joint_names["smpl_24"]]

    def observe(self, frames: Sequence[np.ndarray], bbox_xyxy: Sequence[float]) -> tuple[np.ndarray, np.ndarray]:
        torch = self.torch
        all_positions: list[np.ndarray] = []
        all_uncertainties: list[np.ndarray] = []
        x1, y1, x2, y2 = [float(item) for item in bbox_xyxy]
        for start in range(0, len(frames), self.batch_size):
            batch_frames = frames[start:start + self.batch_size]
            images = torch.from_numpy(np.stack(batch_frames)).permute(0, 3, 1, 2).to(self.device)
            images = images.to(torch.float16).mul_(1.0 / 255.0).pow_(2.2)
            count, _, height, width = images.shape
            focal = max(height, width) / (2.0 * math.tan(math.radians(55.0) / 2.0))
            intrinsic = torch.tensor(
                [[focal, 0.0, (width - 1) / 2.0],
                 [0.0, focal, (height - 1) / 2.0],
                 [0.0, 0.0, 1.0]], device=self.device, dtype=torch.float32,
            ).unsqueeze(0).repeat(count, 1, 1)
            boxes = torch.tensor(
                [[x1, y1, x2 - x1, y2 - y1, 1.0]] * count,
                device=self.device, dtype=torch.float32,
            )
            distortion = torch.zeros((count, 5), device=self.device)
            camera_up = torch.tensor([[0.0, -1.0, 0.0]] * count, device=self.device)
            image_ids = torch.arange(count, device=self.device, dtype=torch.int64)
            identity = torch.eye(3, device=self.device).unsqueeze(0)
            ones = torch.ones(1, device=self.device)
            with torch.inference_mode():
                crops, new_intrinsic, rotation = self.model._get_crops(
                    images, intrinsic, distortion, camera_up, boxes, image_ids,
                    identity, ones, ones, 1,
                )
                crop_resolution = int(self.model.crop_model.input_resolution)
                poses, uncertainties = self.model.crop_model.predict_multi_same_weights(
                    crops.reshape(-1, 3, crop_resolution, crop_resolution),
                    new_intrinsic.reshape(-1, 3, 3), self.weights,
                    torch.zeros(count, device=self.device, dtype=torch.bool),
                )
                poses = poses.float() @ rotation.reshape(-1, 3, 3).float()
            positions_np = poses.detach().cpu().numpy().astype(np.float64)
            uncertainties_np = uncertainties.detach().cpu().numpy().astype(np.float64)
            if not np.isfinite(positions_np).all() or not np.isfinite(uncertainties_np).all():
                raise RuntimeError("NLF returned non-finite observations")
            all_positions.append(positions_np)
            all_uncertainties.append(uncertainties_np)
            print(f"NLF observed {min(start + count, len(frames))}/{len(frames)} sampled frames", flush=True)
        return np.concatenate(all_positions), np.concatenate(all_uncertainties)


class Sam3dObserver:
    """Sparse MHR orientation anchors from SAM 3D Body."""

    def __init__(self, repository: Path, checkpoint: Path, mhr_path: Path, device: str):
        sys.path.insert(0, str(repository.resolve()))
        from sam_3d_body import SAM3DBodyEstimator, load_sam_3d_body  # type: ignore

        model, config = load_sam_3d_body(
            checkpoint_path=str(checkpoint), mhr_path=str(mhr_path), device=device,
        )
        self.estimator = SAM3DBodyEstimator(model, config)

    def observe(self, frame: np.ndarray, bbox_xyxy: Sequence[float]) -> dict[str, Any]:
        outputs = self.estimator.process_one_image(
            frame, bboxes=np.asarray([bbox_xyxy], dtype=np.float32), inference_type="body",
        )
        if not outputs:
            raise RuntimeError("SAM 3D Body returned no person")
        output = outputs[0]
        return {
            "pred_global_rots": np.asarray(output["pred_global_rots"], dtype=np.float64),
            "pred_keypoints_3d": np.asarray(output["pred_keypoints_3d"], dtype=np.float64),
            "bbox": np.asarray(output["bbox"], dtype=np.float64),
        }


def sample_indices(frame_count: int, stream_fps: float, sample_fps: float) -> list[int]:
    step = max(1, int(round(stream_fps / sample_fps)))
    result = list(range(0, frame_count, step))
    if result[-1] != frame_count - 1:
        result.append(frame_count - 1)
    return result


def resample_nlf(observations: Mapping[str, Any], frame_count: int) -> tuple[list[str], np.ndarray, np.ndarray]:
    indices = [int(item) for item in observations["sample_indices"]]
    positions = np.asarray(observations["positions"], dtype=np.float64)
    uncertainties = np.asarray(observations["uncertainties"], dtype=np.float64)
    full_positions = interpolate_samples(positions, indices, frame_count)
    full_uncertainties = interpolate_samples(uncertainties, indices, frame_count)
    full_positions = median_smooth_positions(full_positions)
    # NLF uses camera coordinates: X right, Y down, Z away.  A 180-degree X
    # basis change gives Godot's Y-up, forward +Z convention for a frontal actor.
    full_positions = full_positions @ np.diag([1.0, -1.0, -1.0])
    return [str(item) for item in observations["joint_names"]], full_positions, full_uncertainties


def retarget_sam_anchors(target: Rig, source: Rig, anchor_records: Sequence[Mapping[str, Any]],
                         anchor_indices: Sequence[int], frame_count: int) -> dict[str, np.ndarray]:
    target_index = target.index
    source_index = source.index
    output: dict[str, np.ndarray] = {}
    for target_name, source_name in MHR_TO_GODOT.items():
        if target_name not in SAM_AXIAL_BONES:
            continue
        if target_name not in target_index or source_name not in source_index:
            continue
        ti = target_index[target_name]
        si = source_index[source_name]
        anchor_quats = []
        for record in anchor_records:
            source_pose = matrix_to_quat(np.asarray(record["pred_global_rots"])[si])
            delta = quat_multiply(source_pose, quat_conjugate(source.rest_global[si]))
            anchor_quats.append(quat_multiply(delta, target.rest_global[ti]))
        output[target_name] = interpolate_samples(
            np.asarray(anchor_quats), anchor_indices, frame_count, quaternion=True,
        )
    return output


def child_offset_for_bone(rig: Rig, bone_name: str) -> np.ndarray | None:
    index = rig.index.get(bone_name)
    if index is None:
        return None
    child_name = TARGET_SEGMENT_CHILD.get(bone_name)
    child = rig.index.get(child_name, -1) if child_name else -1
    if child < 0 or int(rig.parents[child]) != index:
        return None
    return rig.translations[child]


def fit_hierarchical_pose(target: Rig, sam_globals: dict[str, np.ndarray],
                          nlf_names: list[str], positions: np.ndarray,
                          uncertainties: np.ndarray,
                          nlf_weight: float) -> tuple[dict[str, np.ndarray], set[str]]:
    """Fit target-local rotations parent-first with minimal swing corrections.

    Limbs inherit the already fitted parent orientation before aiming at their
    observed child. This is the critical difference from independently fitting
    global upper/lower-limb orientations: no child has to counter-rotate a
    parent's correction, so wrists and feet do not acquire artificial roll.
    """
    nlf_index = {name: index for index, name in enumerate(nlf_names)}
    target_index = target.index
    frame_count = len(positions)
    identity = np.array([0.0, 0.0, 0.0, 1.0])
    # Godot 4's set_bone_pose_rotation() expects the absolute local bone pose,
    # not an identity-relative animation delta. Unobserved bones must therefore
    # retain their imported GLB rest quaternion; sending identity destroys bone
    # roll on this rig (especially thighs, wrists, fingers, feet, and toes).
    local_pose = {
        name: np.tile(target.rest_local[index], (frame_count, 1))
        for index, name in enumerate(target.names)
    }
    driven = set(sam_globals).union(NLF_SEGMENTS).intersection(target.names)

    for frame in range(frame_count):
        final_globals: list[np.ndarray] = [identity.copy() for _ in target.names]
        for index, bone_name in enumerate(target.names):
            parent = int(target.parents[index])
            inherited = (target.rest_global[index] if parent < 0 else
                         quat_multiply(final_globals[parent], target.rest_local[index]))
            # SAM is deliberately present only for the axial chain. For limbs,
            # start from the target's inherited rest basis to preserve bone roll.
            fitted_global = (sam_globals[bone_name][frame].copy()
                             if bone_name in sam_globals else inherited)
            segment = NLF_SEGMENTS.get(bone_name)
            rest_offset = child_offset_for_bone(target, bone_name)
            if segment is not None and rest_offset is not None:
                start_name, end_name = segment
                if start_name in nlf_index and end_name in nlf_index:
                    start = nlf_index[start_name]
                    end = nlf_index[end_name]
                    observed = positions[frame, end] - positions[frame, start]
                    if np.linalg.norm(observed) >= 1e-6:
                        predicted = rotate_vector(fitted_global, rest_offset)
                        swing = quat_from_to(predicted, observed)
                        uncertainty = float(max(uncertainties[frame, start],
                                                uncertainties[frame, end]))
                        # Trust clear joints fully and fade only genuinely weak
                        # or occluded observations.
                        confidence = min(1.0, max(0.0, (0.35 - uncertainty) / 0.25))
                        correction = quat_slerp(identity, swing,
                                                min(1.0, nlf_weight * confidence))
                        fitted_global = quat_multiply(correction, fitted_global)
            final_globals[index] = fitted_global
            if bone_name in driven:
                desired_local = (fitted_global if parent < 0 else
                                 quat_multiply(quat_conjugate(final_globals[parent]),
                                               fitted_global))
                local_pose[bone_name][frame] = desired_local
    return local_pose, driven


def infer_foot_contacts(nlf_names: list[str], positions: np.ndarray, fps: float) -> dict[str, list[bool]]:
    names = {name: index for index, name in enumerate(nlf_names)}
    result: dict[str, list[bool]] = {}
    for side, ankle_name in (("left", "lank"), ("right", "rank")):
        ankle = positions[:, names[ankle_name]]
        velocity = np.linalg.norm(np.diff(ankle, axis=0, prepend=ankle[:1]), axis=1) * fps
        # Godot Y is up. A foot is a contact candidate near its lower-motion
        # height band; thresholds are relative so camera scale is irrelevant.
        height_limit = float(np.quantile(ankle[:, 1], 0.35))
        speed_limit = float(np.quantile(velocity, 0.45))
        contact = (ankle[:, 1] <= height_limit) & (velocity <= max(1e-6, speed_limit))
        # Close one-frame holes.
        for index in range(1, len(contact) - 1):
            if contact[index - 1] and contact[index + 1]:
                contact[index] = True
        result[side] = [bool(item) for item in contact]
    return result


def estimate_rig_height(rig: Rig) -> float:
    """Estimate the target avatar height in the GLB's scene units."""
    positions: list[np.ndarray] = []
    globals_at_rest: list[np.ndarray] = []
    for index in range(len(rig.names)):
        parent = int(rig.parents[index])
        if parent < 0:
            position = rig.translations[index].copy()
            rotation = rig.rest_local[index]
        else:
            position = positions[parent] + rotate_vector(
                globals_at_rest[parent], rig.translations[index]
            )
            rotation = quat_multiply(globals_at_rest[parent], rig.rest_local[index])
        positions.append(position)
        globals_at_rest.append(rotation)
    values = np.asarray(positions, dtype=np.float64)
    return max(1e-6, float(values[:, 1].max() - values[:, 1].min()))


def infer_root_motion(target: Rig, nlf_names: list[str], positions: np.ndarray,
                      contacts: Mapping[str, Sequence[bool]], fps: float,
                      mode: str = "foot-contact", lock_strength: float = 0.85,
                      scale_override: float | None = None) -> tuple[np.ndarray, dict[str, Any]]:
    """Infer parent-node translation while retaining pelvis wobble in the bones.

    Raw pelvis displacement supplies gait timing. During a planted-foot interval,
    the foot's relative position to the pelvis supplies a contact constraint;
    blending that constraint with raw pelvis motion removes camera/inference
    drift without flattening the Hips quaternion motion. This is root motion,
    not a second pelvis animation channel.
    """
    names = {name: index for index, name in enumerate(nlf_names)}
    required = ("lhip", "rhip", "lank", "rank")
    if any(name not in names for name in required):
        return np.zeros((len(positions), 3), dtype=np.float64), {
            "mode": "off", "reason": "NLF skeleton lacks hips or ankles", "scale": 1.0,
        }
    pelvis = (positions[:, names["lhip"]] + positions[:, names["rhip"]]) * 0.5
    head_height = positions[:, names.get("head", names["lhip"]), :][:, 1]
    ankle_heights = positions[:, [names["lank"], names["rank"]], :][:, :, 1]
    observed_height = float(np.max(head_height) - np.min(ankle_heights))
    if not math.isfinite(observed_height) or observed_height < 1e-6:
        observed_height = 1.0
    scale = float(scale_override) if scale_override is not None else estimate_rig_height(target) / observed_height
    scale = max(1e-6, scale)
    raw = (pelvis - pelvis[0]) * scale
    if mode == "off":
        return np.zeros_like(raw), {"mode": "off", "scale": scale}
    if mode == "pelvis":
        return raw, {"mode": "pelvis", "scale": scale, "contact_lock_strength": 0.0}

    strength = min(1.0, max(0.0, float(lock_strength)))
    local_feet = {
        "left": positions[:, names["lank"]] - pelvis,
        "right": positions[:, names["rank"]] - pelvis,
    }
    result = np.zeros_like(raw)
    anchors: dict[str, np.ndarray | None] = {"left": None, "right": None}
    previous_contact = {"left": False, "right": False}
    for frame in range(len(raw)):
        candidates: list[np.ndarray] = []
        for side in ("left", "right"):
            active = bool(contacts.get(side, [False] * len(raw))[frame])
            if active and not previous_contact[side]:
                anchors[side] = raw[frame] + local_feet[side][frame] * scale
            if active and anchors[side] is not None:
                candidates.append(anchors[side] - local_feet[side][frame] * scale)
            if not active:
                anchors[side] = None
            previous_contact[side] = active
        if candidates:
            locked = np.mean(np.asarray(candidates), axis=0)
            result[frame] = raw[frame] * (1.0 - strength) + locked * strength
        else:
            result[frame] = raw[frame]
    result[0] = np.zeros(3, dtype=np.float64)
    return result, {
        "mode": "foot-contact", "scale": scale,
        "contact_lock_strength": strength,
        "target_height": estimate_rig_height(target),
        "observed_height": observed_height,
    }


def _trajectory_point(value: Any) -> np.ndarray:
    point = np.asarray(value, dtype=np.float64)
    if point.shape != (3,) or not np.isfinite(point).all():
        raise ValueError("trajectory positions and handles must be finite [x, y, z] values")
    return point


def _bezier_point(p0: np.ndarray, p1: np.ndarray, p2: np.ndarray,
                  p3: np.ndarray, amount: float) -> np.ndarray:
    inverse = 1.0 - amount
    return (inverse ** 3) * p0 + 3.0 * (inverse ** 2) * amount * p1 \
        + 3.0 * inverse * (amount ** 2) * p2 + (amount ** 3) * p3


def _bezier_tangent(p0: np.ndarray, p1: np.ndarray, p2: np.ndarray,
                    p3: np.ndarray, amount: float) -> np.ndarray:
    inverse = 1.0 - amount
    return (3.0 * inverse * inverse) * (p1 - p0) \
        + (6.0 * inverse * amount) * (p2 - p1) \
        + (3.0 * amount * amount) * (p3 - p2)


def plan_bezier_trajectory(root_motion: np.ndarray, trajectory: Mapping[str, Any],
                           samples_per_segment: int = 80,
                           heading_mode: str = "tangent",
                           contacts: Mapping[str, Sequence[bool]] | None = None,
                           foot_positions: Mapping[str, np.ndarray] | None = None) -> tuple[np.ndarray, np.ndarray, dict[str, Any]]:
    """Map gait-distance progress onto a linear or cubic Bezier path.

    Each waypoint uses relative ``in_handle``/``out_handle`` vectors. The
    fitted gait's cumulative distance controls timing, so footfalls and pelvis
    wobble keep their captured pace while the parent follows the programmed
    path. ``rotation_y`` is the absolute parent-space tangent heading; the wire
    protocol also carries the tangent as a direction vector so Godot can align
    the character without assuming its authored scene yaw.
    """
    raw = np.asarray(root_motion, dtype=np.float64)
    trajectory_type = str(trajectory.get("type", "bezier")).lower()
    if trajectory_type not in {"bezier", "linear"}:
        raise ValueError("trajectory type must be 'bezier' or 'linear'")
    waypoints = trajectory.get("waypoints")
    if not isinstance(waypoints, list) or len(waypoints) < 2:
        raise ValueError("trajectory requires at least two waypoints")
    points: list[np.ndarray] = []
    ins: list[np.ndarray] = []
    outs: list[np.ndarray] = []
    for item in waypoints:
        if not isinstance(item, Mapping) or "position" not in item:
            raise ValueError("each trajectory waypoint needs a position")
        points.append(_trajectory_point(item["position"]))
        ins.append(_trajectory_point(item.get("in_handle", [0.0, 0.0, 0.0])))
        outs.append(_trajectory_point(item.get("out_handle", [0.0, 0.0, 0.0])))
    samples = max(8, int(samples_per_segment))
    path: list[np.ndarray] = []
    tangent: list[np.ndarray] = []
    for segment in range(len(points) - 1):
        for sample in range(samples + (1 if segment == len(points) - 2 else 0)):
            amount = sample / float(samples)
            p0, p3 = points[segment], points[segment + 1]
            if trajectory_type == "linear":
                path.append(p0 * (1.0 - amount) + p3 * amount)
                tangent.append(p3 - p0)
            else:
                p1, p2 = p0 + outs[segment], p3 + ins[segment + 1]
                path.append(_bezier_point(p0, p1, p2, p3, amount))
                tangent.append(_bezier_tangent(p0, p1, p2, p3, amount))
    path_array = np.asarray(path)
    tangent_array = np.asarray(tangent)
    arc = np.concatenate(([0.0], np.cumsum(np.linalg.norm(np.diff(path_array, axis=0), axis=1))))
    total_length = float(arc[-1])
    if total_length < 1e-8:
        raise ValueError("trajectory waypoints produce a zero-length path")
    # Measure directed progress, not total pelvis variation. Summing the length
    # of every frame-to-frame displacement turns lateral hip sway and planted-
    # foot corrections into fictitious forward speed, causing severe sliding.
    horizontal = raw[:, [0, 2]] - raw[0, [0, 2]]
    net = horizontal[-1]
    if np.linalg.norm(net) > 1e-6:
        travel_axis = net / np.linalg.norm(net)
    else:
        centered = horizontal - np.mean(horizontal, axis=0)
        _, _, principal = np.linalg.svd(centered, full_matrices=False)
        travel_axis = principal[0]
        if np.dot(horizontal[-1] - horizontal[0], travel_axis) < 0.0:
            travel_axis = -travel_axis
    signed_progress = horizontal @ travel_axis
    signed_progress -= signed_progress[0]
    # Keep small backward corrections: they are produced by planted-foot
    # locking and are necessary to counter the posed leg's local movement.
    # Only prevent travel before the authored start of the path.
    gait_arc = np.maximum.accumulate(np.maximum(signed_progress, 0.0))
    distance_mode = str(trajectory.get("distance_mode", "gait")).lower()
    speed_profile = str(trajectory.get("speed_profile", "captured")).lower()
    if speed_profile not in {"captured", "constant"}:
        raise ValueError("trajectory speed_profile must be 'captured' or 'constant'")
    pace_scale = float(trajectory.get("pace_scale", 1.0))
    if not math.isfinite(pace_scale) or pace_scale <= 0.0:
        raise ValueError("trajectory pace_scale must be positive")
    if distance_mode == "fit":
        progress = (
            np.linspace(0.0, 1.0, len(gait_arc), dtype=np.float64)
            if speed_profile == "constant" else
            gait_arc / max(1e-8, float(gait_arc[-1]))
        )
        path_distances = progress * total_length
    elif distance_mode == "gait":
        # Preserve captured stride distance and cadence. A longer path is only
        # traversed part-way; forcing its endpoint rescales speed and slides feet.
        path_distances = np.minimum(gait_arc * pace_scale, total_length)
    else:
        raise ValueError("trajectory distance_mode must be 'gait' or 'fit'")
    contact_correction = min(1.0, max(0.0, float(trajectory.get("contact_correction", 0.9))))
    local_forward = _trajectory_point(trajectory.get("local_forward", [0.0, 0.0, -1.0]))
    if np.linalg.norm(local_forward[[0, 2]]) <= 1e-8:
        raise ValueError("trajectory local_forward must have a horizontal component")
    local_forward_angle = math.atan2(float(local_forward[0]), float(local_forward[2]))

    def sample_path(distance: float) -> tuple[np.ndarray, np.ndarray, float]:
        right = int(np.searchsorted(arc, distance, side="right"))
        right = min(max(right, 1), len(arc) - 1)
        left = right - 1
        amount = (distance - arc[left]) / max(1e-8, arc[right] - arc[left])
        point = path_array[left] * (1.0 - amount) + path_array[right] * amount
        direction = tangent_array[left] * (1.0 - amount) + tangent_array[right] * amount
        if np.linalg.norm(direction) <= 1e-8:
            direction = tangent_array[right] if np.linalg.norm(tangent_array[right]) > 1e-8 else tangent_array[left]
        heading = math.atan2(float(direction[0]), float(direction[2])) \
            if np.linalg.norm(direction[[0, 2]]) > 1e-8 else 0.0
        return point, direction, heading

    # Solve the final avatar's own planted feet against distance on the path.
    # This happens after retargeting because NLF feet and target-rig feet do not
    # have identical lengths or bone rolls. Correction is tangent-only, keeping
    # the root on the authored curve rather than introducing a lateral offset.
    corrected_distances = path_distances.copy()
    fit_endpoint_correction = 0.0
    if contacts is not None and foot_positions is not None and contact_correction > 0.0:
        anchors: dict[str, np.ndarray | None] = {"left": None, "right": None}
        previous = {"left": False, "right": False}
        for index in range(len(corrected_distances)):
            # Carry the accumulated contact correction across support-foot
            # changes. Starting each new stance from the uncorrected camera-
            # relative pelvis distance makes a tracked subject walk in place.
            if index == 0:
                distance = float(path_distances[index])
            else:
                nominal_delta = float(path_distances[index] - path_distances[index - 1])
                distance = float(corrected_distances[index - 1]) + nominal_delta
            point, direction, heading = sample_path(distance)
            candidates: list[float] = []
            for side in ("left", "right"):
                active = bool(contacts.get(side, [False] * len(corrected_distances))[index])
                positions_for_side = foot_positions.get(side)
                if positions_for_side is None:
                    continue
                foot = np.asarray(positions_for_side[index], dtype=np.float64)
                # Match PoseStream's heading rule: rotate the avatar's declared
                # local forward axis onto the curve tangent. The female proxy
                # faces local -Z, so using heading directly would evaluate its
                # feet 180 degrees away from their actual Godot positions.
                avatar_yaw = heading - local_forward_angle
                cosine, sine = math.cos(avatar_yaw), math.sin(avatar_yaw)
                rotated = np.array([
                    cosine * foot[0] + sine * foot[2],
                    foot[1],
                    -sine * foot[0] + cosine * foot[2],
                ])
                world_foot = point + rotated
                if active and not previous[side]:
                    anchors[side] = world_foot.copy()
                if active and anchors[side] is not None:
                    tangent_xz = direction[[0, 2]]
                    tangent_length = np.linalg.norm(tangent_xz)
                    if tangent_length > 1e-8:
                        error_xz = (anchors[side] - world_foot)[[0, 2]]
                        candidates.append(float(np.dot(error_xz, tangent_xz / tangent_length)))
                if not active:
                    anchors[side] = None
                previous[side] = active
            if candidates:
                distance += contact_correction * float(np.mean(candidates))
            corrected_distances[index] = min(total_length, max(0.0, distance))
        if distance_mode == "fit" and len(corrected_distances) > 1:
            # Contact locking may shorten total travel. Restore the authored
            # endpoint mostly during swing frames; a small planted-frame weight
            # avoids abrupt bursts when contact detection has long intervals.
            fit_endpoint_correction = total_length - float(corrected_distances[-1])
            weights = np.ones(len(corrected_distances) - 1, dtype=np.float64)
            for index in range(1, len(corrected_distances)):
                planted = any(bool(contacts.get(side, [False] * len(corrected_distances))[index])
                              for side in ("left", "right"))
                weights[index - 1] = 0.15 if planted else 1.0
            cumulative = np.concatenate(([0.0], np.cumsum(weights)))
            if cumulative[-1] > 1e-8:
                corrected_distances += fit_endpoint_correction * cumulative / cumulative[-1]
                corrected_distances = np.clip(corrected_distances, 0.0, total_length)
    path_distances = corrected_distances
    planned = np.empty_like(raw)
    headings = np.zeros(len(raw), dtype=np.float64)
    for index, distance in enumerate(path_distances):
        planned[index], _, headings[index] = sample_path(float(distance))
    headings = np.unwrap(headings)
    if heading_mode == "none":
        headings.fill(0.0)
    offset = planned - planned[0]
    return offset, headings, {
        "type": trajectory_type, "waypoint_count": len(points),
        "path_length": total_length, "gait_distance": float(gait_arc[-1]),
        "progress_method": "monotonic_directed_root+target_foot_contact",
        "travel_distance": float(path_distances[-1]),
        "distance_mode": distance_mode, "pace_scale": pace_scale,
        "speed_profile": speed_profile,
        "target_foot_contact_correction": contact_correction,
        "fit_endpoint_correction": fit_endpoint_correction,
        "path_completed": bool(path_distances[-1] >= total_length - 1e-6),
        "heading_mode": heading_mode,
    }


def measure_segment_errors(target: Rig, local_pose: Mapping[str, np.ndarray],
                           nlf_names: list[str], positions: np.ndarray) -> dict[str, Any]:
    """Report angular FK-vs-NLF errors after temporal filtering."""
    nlf_index = {name: index for index, name in enumerate(nlf_names)}
    errors: dict[str, list[float]] = {name: [] for name in NLF_SEGMENTS}
    for frame in range(len(positions)):
        globals_at_frame: list[np.ndarray] = []
        for index, bone_name in enumerate(target.names):
            posed_local = local_pose[bone_name][frame]
            parent = int(target.parents[index])
            global_rotation = (posed_local if parent < 0 else
                               quat_multiply(globals_at_frame[parent], posed_local))
            globals_at_frame.append(global_rotation)
            segment = NLF_SEGMENTS.get(bone_name)
            offset = child_offset_for_bone(target, bone_name)
            if segment is None or offset is None:
                continue
            start_name, end_name = segment
            if start_name not in nlf_index or end_name not in nlf_index:
                continue
            observed = positions[frame, nlf_index[end_name]] - positions[frame, nlf_index[start_name]]
            if np.linalg.norm(observed) < 1e-6:
                continue
            predicted = rotate_vector(global_rotation, offset)
            dot = float(np.dot(_normalized(predicted), _normalized(observed)))
            errors[bone_name].append(math.degrees(math.acos(min(1.0, max(-1.0, dot)))))
    return {
        "mean_degrees": {name: round(float(np.mean(values)), 3)
                         for name, values in errors.items() if values},
        "p95_degrees": {name: round(float(np.quantile(values, 0.95)), 3)
                        for name, values in errors.items() if values},
    }


def fk_bone_positions(rig: Rig, local_pose: Mapping[str, np.ndarray],
                      bone_names: Sequence[str]) -> dict[str, np.ndarray]:
    """Evaluate selected target-rig bone origins in character-local space."""
    frame_count = len(next(iter(local_pose.values())))
    requested = {name: rig.index[name] for name in bone_names if name in rig.index}
    result = {name: np.zeros((frame_count, 3), dtype=np.float64) for name in requested}
    for frame in range(frame_count):
        positions: list[np.ndarray] = []
        rotations: list[np.ndarray] = []
        for index, name in enumerate(rig.names):
            parent = int(rig.parents[index])
            rotation = local_pose[name][frame]
            if parent < 0:
                position = rig.translations[index].copy()
                global_rotation = rotation
            else:
                position = positions[parent] + rotate_vector(rotations[parent], rig.translations[index])
                global_rotation = quat_multiply(rotations[parent], rotation)
            positions.append(position)
            rotations.append(global_rotation)
        for name, bone_index in requested.items():
            result[name][frame] = positions[bone_index]
    return result


def _fk_frame(rig: Rig, local_pose: Mapping[str, np.ndarray],
              frame: int) -> tuple[list[np.ndarray], list[np.ndarray]]:
    """Evaluate one frame of target-rig FK in character-local space."""
    positions: list[np.ndarray] = []
    rotations: list[np.ndarray] = []
    for index, name in enumerate(rig.names):
        parent = int(rig.parents[index])
        rotation = local_pose[name][frame]
        if parent < 0:
            position = rig.translations[index].copy()
            global_rotation = rotation
        else:
            position = positions[parent] + rotate_vector(
                rotations[parent], rig.translations[index]
            )
            global_rotation = quat_multiply(rotations[parent], rotation)
        positions.append(position)
        rotations.append(global_rotation)
    return positions, rotations


def _yaw_vector(vector: np.ndarray, angle: float) -> np.ndarray:
    cosine, sine = math.cos(angle), math.sin(angle)
    return np.array([
        cosine * vector[0] + sine * vector[2],
        vector[1],
        -sine * vector[0] + cosine * vector[2],
    ], dtype=np.float64)


def solve_planted_foot_ik(rig: Rig, local_pose: dict[str, np.ndarray],
                          root_motion: np.ndarray, root_yaw: np.ndarray,
                          contacts: Mapping[str, Sequence[bool]],
                          local_forward: Sequence[float] = (0.0, 0.0, -1.0),
                          strength: float = 1.0) -> dict[str, Any]:
    """Pin support ankles in XZ with target-rig analytical two-bone IK.

    Root motion must remain on the authored straight path, so it cannot cancel
    lateral ankle drift. This pass instead rotates each thigh and shin toward a
    world-space ankle anchor while retaining the current knee bend plane and the
    fitted foot's global orientation. Vertical placement is deliberately left
    to ``apply_ground_lock`` so the visible sole has one authoritative ground
    correction.
    """
    blend = min(1.0, max(0.0, float(strength)))
    frame_count = len(root_motion)
    if blend <= 0.0 or frame_count == 0:
        return {"enabled": False, "strength": blend, "solved_frames": 0,
                "before_median_error": 0.0, "after_median_error": 0.0}
    forward = _trajectory_point(local_forward)
    local_forward_angle = math.atan2(float(forward[0]), float(forward[2]))
    chains = {
        "left": ("LeftUpperLeg", "LeftLowerLeg", "LeftFoot"),
        "right": ("RightUpperLeg", "RightLowerLeg", "RightFoot"),
    }
    if any(name not in rig.index or name not in local_pose
           for chain in chains.values() for name in chain):
        return {"enabled": False, "strength": blend, "solved_frames": 0,
                "reason": "target rig lacks a required leg bone",
                "before_median_error": 0.0, "after_median_error": 0.0}

    anchors: dict[str, np.ndarray | None] = {"left": None, "right": None}
    previous = {"left": False, "right": False}
    before_errors: list[float] = []
    solved_frames = 0
    for frame in range(frame_count):
        yaw = float(root_yaw[frame]) - local_forward_angle
        positions, rotations = _fk_frame(rig, local_pose, frame)
        for side, (upper_name, lower_name, foot_name) in chains.items():
            active = bool(contacts.get(side, [False] * frame_count)[frame])
            foot_index = rig.index[foot_name]
            current_world = np.asarray(root_motion[frame], dtype=np.float64) + _yaw_vector(
                positions[foot_index], yaw
            )
            if active and not previous[side]:
                anchors[side] = current_world.copy()
            if not active:
                anchors[side] = None
                previous[side] = False
                continue
            anchor = anchors[side]
            previous[side] = True
            if anchor is None:
                continue
            before_errors.append(float(np.linalg.norm((current_world - anchor)[[0, 2]])))

            desired = _yaw_vector(anchor - np.asarray(root_motion[frame]), -yaw)
            desired[1] = positions[foot_index][1]
            upper_index = rig.index[upper_name]
            lower_index = rig.index[lower_name]
            hip = positions[upper_index]
            knee = positions[lower_index]
            ankle = positions[foot_index]
            thigh_length = float(np.linalg.norm(knee - hip))
            shin_length = float(np.linalg.norm(ankle - knee))
            max_reach = thigh_length + shin_length - 1e-6
            horizontal_distance = float(np.linalg.norm((desired - hip)[[0, 2]]))
            if horizontal_distance < max_reach:
                vertical_limit = math.sqrt(max(0.0, max_reach * max_reach
                                                - horizontal_distance * horizontal_distance))
                vertical_delta = float(desired[1] - hip[1])
                if abs(vertical_delta) > vertical_limit:
                    desired[1] = hip[1] + math.copysign(vertical_limit, vertical_delta)
            target_vector = desired - hip
            target_distance = float(np.linalg.norm(target_vector))
            if thigh_length <= 1e-8 or shin_length <= 1e-8 or target_distance <= 1e-8:
                continue
            reachable = min(max_reach,
                            max(abs(thigh_length - shin_length) + 1e-6, target_distance))
            direction = target_vector / target_distance
            target = hip + direction * reachable
            along = (thigh_length * thigh_length - shin_length * shin_length
                     + reachable * reachable) / (2.0 * reachable)
            bend_height = math.sqrt(max(0.0, thigh_length * thigh_length - along * along))
            bend = knee - hip - direction * float(np.dot(knee - hip, direction))
            if np.linalg.norm(bend) <= 1e-8:
                bend = np.cross(direction, np.array([0.0, 0.0, 1.0]))
                if np.linalg.norm(bend) <= 1e-8:
                    bend = np.cross(direction, np.array([1.0, 0.0, 0.0]))
            desired_knee = hip + direction * along + _normalized(bend) * bend_height

            original_upper = local_pose[upper_name][frame].copy()
            original_lower = local_pose[lower_name][frame].copy()
            original_foot = local_pose[foot_name][frame].copy()
            old_foot_global = rotations[foot_index].copy()
            upper_parent = int(rig.parents[upper_index])
            parent_global = (np.array([0.0, 0.0, 0.0, 1.0]) if upper_parent < 0
                             else rotations[upper_parent])
            solved_upper_global = quat_multiply(
                quat_from_to(knee - hip, desired_knee - hip), rotations[upper_index]
            )
            solved_upper_local = quat_multiply(
                quat_conjugate(parent_global), solved_upper_global
            )
            local_pose[upper_name][frame] = quat_slerp(
                original_upper, solved_upper_local, blend
            )
            positions, rotations = _fk_frame(rig, local_pose, frame)
            knee = positions[lower_index]
            ankle = positions[foot_index]
            solved_lower_global = quat_multiply(
                quat_from_to(ankle - knee, target - knee), rotations[lower_index]
            )
            solved_lower_local = quat_multiply(
                quat_conjugate(rotations[upper_index]), solved_lower_global
            )
            local_pose[lower_name][frame] = quat_slerp(
                original_lower, solved_lower_local, blend
            )
            positions, rotations = _fk_frame(rig, local_pose, frame)
            solved_foot_local = quat_multiply(
                quat_conjugate(rotations[lower_index]), old_foot_global
            )
            local_pose[foot_name][frame] = quat_slerp(
                original_foot, solved_foot_local, blend
            )
            positions, rotations = _fk_frame(rig, local_pose, frame)
            solved_frames += 1

    after_errors: list[float] = []
    anchors = {"left": None, "right": None}
    previous = {"left": False, "right": False}
    for frame in range(frame_count):
        yaw = float(root_yaw[frame]) - local_forward_angle
        positions, _ = _fk_frame(rig, local_pose, frame)
        for side, (_, _, foot_name) in chains.items():
            active = bool(contacts.get(side, [False] * frame_count)[frame])
            world = np.asarray(root_motion[frame]) + _yaw_vector(
                positions[rig.index[foot_name]], yaw
            )
            if active and not previous[side]:
                anchors[side] = world.copy()
            if active and anchors[side] is not None:
                after_errors.append(float(np.linalg.norm((world - anchors[side])[[0, 2]])))
            if not active:
                anchors[side] = None
            previous[side] = active
    return {
        "enabled": True,
        "strength": blend,
        "solved_frames": solved_frames,
        "before_median_error": float(np.median(before_errors)) if before_errors else 0.0,
        "before_max_error": max(before_errors, default=0.0),
        "after_median_error": float(np.median(after_errors)) if after_errors else 0.0,
        "after_max_error": max(after_errors, default=0.0),
    }


def stabilize_torso_upright(rig: Rig, local_pose: dict[str, np.ndarray],
                            max_tilt_degrees: float,
                            strength: float = 1.0) -> dict[str, float]:
    """Limit whole-torso lean while preserving the fitted leg orientations."""
    required = ("Hips", "UpperChest", "LeftUpperLeg", "RightUpperLeg")
    if any(name not in rig.index or name not in local_pose for name in required):
        return {"applied_frames": 0.0, "max_tilt_degrees": float(max_tilt_degrees)}
    limit = math.radians(max(0.0, float(max_tilt_degrees)))
    blend = min(1.0, max(0.0, float(strength)))
    identity = np.array([0.0, 0.0, 0.0, 1.0])
    hips_index = rig.index["Hips"]
    chest_index = rig.index["UpperChest"]
    leg_indices = [rig.index["LeftUpperLeg"], rig.index["RightUpperLeg"]]
    applied = 0
    before_values: list[float] = []
    after_values: list[float] = []
    frame_count = len(local_pose["Hips"])
    for frame in range(frame_count):
        positions: list[np.ndarray] = []
        globals_at_frame: list[np.ndarray] = []
        for index, name in enumerate(rig.names):
            parent = int(rig.parents[index])
            rotation = local_pose[name][frame]
            if parent < 0:
                position = rig.translations[index].copy()
                global_rotation = rotation
            else:
                position = positions[parent] + rotate_vector(
                    globals_at_frame[parent], rig.translations[index]
                )
                global_rotation = quat_multiply(globals_at_frame[parent], rotation)
            positions.append(position)
            globals_at_frame.append(global_rotation)
        trunk = positions[chest_index] - positions[hips_index]
        length = float(np.linalg.norm(trunk))
        if length <= 1e-8:
            continue
        direction = trunk / length
        tilt = math.acos(min(1.0, max(-1.0, float(direction[1]))))
        before_values.append(math.degrees(tilt))
        if tilt <= limit or blend <= 0.0:
            after_values.append(math.degrees(tilt))
            continue
        horizontal = direction.copy()
        horizontal[1] = 0.0
        horizontal_length = float(np.linalg.norm(horizontal))
        if horizontal_length <= 1e-8:
            after_values.append(math.degrees(tilt))
            continue
        horizontal /= horizontal_length
        desired = horizontal * math.sin(limit)
        desired[1] = math.cos(limit)
        correction = quat_slerp(identity, quat_from_to(direction, desired), blend)
        old_leg_globals = [globals_at_frame[index].copy() for index in leg_indices]
        hips_parent = int(rig.parents[hips_index])
        new_hips_global = quat_multiply(correction, globals_at_frame[hips_index])
        local_pose["Hips"][frame] = (
            new_hips_global if hips_parent < 0 else
            quat_multiply(quat_conjugate(globals_at_frame[hips_parent]), new_hips_global)
        )
        for leg_index, old_global in zip(leg_indices, old_leg_globals):
            local_pose[rig.names[leg_index]][frame] = quat_multiply(
                quat_conjugate(new_hips_global), old_global
            )
        applied += 1
        after_values.append(math.degrees(limit + (tilt - limit) * (1.0 - blend)))
    return {
        "applied_frames": float(applied),
        "max_tilt_degrees": float(max_tilt_degrees),
        "strength": blend,
        "before_median_degrees": float(np.median(before_values)) if before_values else 0.0,
        "before_max_degrees": max(before_values, default=0.0),
        "after_max_degrees": max(after_values, default=0.0),
    }


def limit_head_upward_pitch(rig: Rig, local_pose: dict[str, np.ndarray],
                            max_up_degrees: float,
                            forward_axis: Sequence[float] = (0.0, 0.0, 1.0)) -> dict[str, float]:
    """Prevent a monocular head anchor from making the avatar stare skyward."""
    if "Head" not in rig.index or "Head" not in local_pose:
        return {"applied_frames": 0.0, "max_up_degrees": float(max_up_degrees)}
    local_forward = _trajectory_point(forward_axis)
    local_forward /= max(1e-8, float(np.linalg.norm(local_forward)))
    limit = math.radians(float(max_up_degrees))
    head_index = rig.index["Head"]
    parent_index = int(rig.parents[head_index])
    applied = 0
    before: list[float] = []
    after: list[float] = []
    for frame in range(len(local_pose["Head"])):
        globals_at_frame: list[np.ndarray] = []
        for index, name in enumerate(rig.names):
            parent = int(rig.parents[index])
            rotation = local_pose[name][frame]
            globals_at_frame.append(
                rotation if parent < 0 else quat_multiply(globals_at_frame[parent], rotation)
            )
        head_global = globals_at_frame[head_index]
        forward = rotate_vector(head_global, local_forward)
        forward /= max(1e-8, float(np.linalg.norm(forward)))
        pitch = math.asin(min(1.0, max(-1.0, float(forward[1]))))
        before.append(math.degrees(pitch))
        if pitch <= limit:
            after.append(math.degrees(pitch))
            continue
        horizontal = forward.copy()
        horizontal[1] = 0.0
        horizontal /= max(1e-8, float(np.linalg.norm(horizontal)))
        desired = horizontal * math.cos(limit)
        desired[1] = math.sin(limit)
        new_global = quat_multiply(quat_from_to(forward, desired), head_global)
        local_pose["Head"][frame] = (
            new_global if parent_index < 0 else
            quat_multiply(quat_conjugate(globals_at_frame[parent_index]), new_global)
        )
        applied += 1
        after.append(float(max_up_degrees))
    return {
        "applied_frames": float(applied),
        "max_up_degrees": float(max_up_degrees),
        "before_median_degrees": float(np.median(before)) if before else 0.0,
        "before_max_degrees": max(before, default=0.0),
        "after_max_degrees": max(after, default=0.0),
    }


def apply_ground_lock(root_motion: np.ndarray,
                      foot_positions: Mapping[str, np.ndarray],
                      contacts: Mapping[str, Sequence[bool]],
                      skeleton_origin_y: float = 0.0,
                      clearance: float = 0.0) -> tuple[np.ndarray, dict[str, float]]:
    """Keep the target rig's lowest support sole on the trajectory ground."""
    result = np.asarray(root_motion, dtype=np.float64).copy()
    frame_count = len(result)
    offsets = np.zeros(frame_count, dtype=np.float64)
    for frame in range(frame_count):
        active = [side for side in ("left", "right")
                  if bool(contacts.get(side, [False] * frame_count)[frame])]
        if not active:
            active = ["left", "right"]
        sole_heights: list[float] = []
        for side in active:
            for suffix in ("foot", "toes"):
                values = foot_positions.get(f"{side}_{suffix}")
                if values is not None:
                    sole_heights.append(float(values[frame, 1]))
        offsets[frame] = (float(clearance) - float(skeleton_origin_y)
                          - min(sole_heights, default=0.0))
    # Bone rotations are already temporally filtered. A second vertical median
    # would leave the support sole visibly above ground at contact transitions.
    result[:, 1] += offsets
    return result, {
        "skeleton_origin_y": float(skeleton_origin_y),
        "clearance": float(clearance),
        "offset_min": float(offsets.min(initial=0.0)),
        "offset_max": float(offsets.max(initial=0.0)),
    }


def solve_motion(target: Rig, source: Rig, nlf_observations: Mapping[str, Any],
                 sam_observations: Mapping[str, Any], frame_count: int,
                 fps: float, nlf_weight: float, root_motion_mode: str = "foot-contact",
                 foot_lock_strength: float = 0.85, root_motion_scale: float | None = None,
                 trajectory: Mapping[str, Any] | None = None,
                 trajectory_samples: int = 80, trajectory_heading: str = "tangent") -> tuple[
                     list[dict[str, list[float]]], dict[str, Any], dict[str, Any]]:
    nlf_names, positions, uncertainties = resample_nlf(nlf_observations, frame_count)
    base_globals = retarget_sam_anchors(
        target, source, sam_observations["records"], sam_observations["anchor_indices"], frame_count,
    )
    local, driven_bones = fit_hierarchical_pose(
        target, base_globals, nlf_names, positions, uncertainties, nlf_weight,
    )
    contacts = infer_foot_contacts(nlf_names, positions, fps)
    root_motion, root_diagnostics = infer_root_motion(
        target, nlf_names, positions, contacts, fps,
        root_motion_mode, foot_lock_strength, root_motion_scale,
    )
    root_yaw = np.zeros(frame_count, dtype=np.float64)
    trajectory_diagnostics: dict[str, Any] | None = None
    filtered: dict[str, np.ndarray] = {}
    for name, quaternions in local.items():
        responsiveness = 0.44
        if name == "Hips":
            responsiveness = 0.70  # retain dance hip wobble and pace
        elif name in {"Spine", "Chest", "UpperChest", "Neck"}:
            responsiveness = 0.58
        elif "Foot" in name or "Toes" in name:
            responsiveness = 0.36
        filtered[name] = temporal_quaternion_filter(quaternions, responsiveness)
    # A planted foot should not shimmer. Blend its local rotation toward the
    # previous frame while contact is active; legs and pelvis remain responsive.
    for side, bone_name in (("left", "LeftFoot"), ("right", "RightFoot")):
        if bone_name not in filtered:
            continue
        for frame in range(1, frame_count):
            if contacts[side][frame]:
                filtered[bone_name][frame] = quat_slerp(
                    filtered[bone_name][frame - 1], filtered[bone_name][frame], 0.28,
                )
    torso_diagnostics: dict[str, float] | None = None
    if trajectory is not None and "max_torso_tilt_degrees" in trajectory:
        torso_diagnostics = stabilize_torso_upright(
            target, filtered,
            float(trajectory.get("max_torso_tilt_degrees", 8.0)),
            float(trajectory.get("torso_upright_strength", 1.0)),
        )
    head_diagnostics: dict[str, float] | None = None
    if trajectory is not None and "max_head_up_degrees" in trajectory:
        head_diagnostics = limit_head_upward_pitch(
            target, filtered,
            float(trajectory.get("max_head_up_degrees", 4.0)),
            trajectory.get("head_forward_axis", [0.0, 0.0, 1.0]),
        )
    ground_diagnostics: dict[str, float] | None = None
    foot_ik_diagnostics: dict[str, Any] | None = None
    if trajectory is not None:
        target_feet = fk_bone_positions(
            target, filtered, ("LeftFoot", "LeftToes", "RightFoot", "RightToes")
        )
        root_motion, root_yaw, trajectory_diagnostics = plan_bezier_trajectory(
            root_motion, trajectory, trajectory_samples, trajectory_heading,
            contacts,
            {"left": target_feet.get("LeftFoot"), "right": target_feet.get("RightFoot")},
        )
        if bool(trajectory.get("foot_ik", False)):
            foot_ik_diagnostics = solve_planted_foot_ik(
                target, filtered, root_motion, root_yaw, contacts,
                trajectory.get("local_forward", [0.0, 0.0, -1.0]),
                float(trajectory.get("foot_ik_strength", 1.0)),
            )
            # IK changed the target-rig leg transforms. Grounding must use the
            # corrected foot and toe locations, not the pre-IK FK snapshot.
            target_feet = fk_bone_positions(
                target, filtered, ("LeftFoot", "LeftToes", "RightFoot", "RightToes")
            )
        if bool(trajectory.get("ground_lock", False)):
            root_motion, ground_diagnostics = apply_ground_lock(
                root_motion,
                {
                    "left_foot": target_feet.get("LeftFoot"),
                    "left_toes": target_feet.get("LeftToes"),
                    "right_foot": target_feet.get("RightFoot"),
                    "right_toes": target_feet.get("RightToes"),
                },
                contacts,
                float(trajectory.get("skeleton_origin_y", 0.0)),
                float(trajectory.get("ground_clearance", 0.0)),
            )
    segment_errors = measure_segment_errors(target, filtered, nlf_names, positions)
    frames: list[dict[str, list[float]]] = []
    for frame in range(frame_count):
        frames.append({
            name: [round(float(value), 8) for value in filtered[name][frame]]
            for name in target.names
        })
    diagnostics = {
        "nlf_joint_names": nlf_names,
        "mean_nlf_uncertainty": float(np.mean(uncertainties)),
        "foot_contacts": contacts,
        "post_filter_segment_error": segment_errors,
        "driven_bones": sorted(driven_bones),
        "rest_bones": [name for name in target.names if name not in driven_bones],
        "root_motion": root_diagnostics,
        "trajectory": trajectory_diagnostics,
        "torso_upright": torso_diagnostics,
        "head_pitch_limit": head_diagnostics,
        "planted_foot_ik": foot_ik_diagnostics,
        "ground_lock": ground_diagnostics,
    }
    root_data = {
        "positions": [[round(float(value), 8) for value in root_motion[frame]]
                      for frame in range(frame_count)],
        "rotation_y": [round(float(value), 8) for value in root_yaw],
        "heading_directions": (
            [[round(float(math.sin(value)), 8), 0.0, round(float(math.cos(value)), 8)]
             for value in root_yaw]
            if trajectory is not None and trajectory_heading == "tangent" else []
        ),
        "local_forward": (
            [float(value) for value in trajectory.get("local_forward", [0.0, 0.0, -1.0])]
            if trajectory is not None else [0.0, 0.0, -1.0]
        ),
        "upright_root": bool(trajectory.get("upright_root", False)) if trajectory is not None else False,
        "scene_origin_node": (
            str(trajectory.get("scene_origin_node", "")) if trajectory is not None else ""
        ),
        "ground_y": (
            float(trajectory.get("ground_y", 0.0))
            if trajectory is not None and "ground_y" in trajectory else None
        ),
        "contacts": contacts,
    }
    return frames, diagnostics, root_data


def make_pose_frame(frame_quaternions: Mapping[str, Sequence[float]], seq: int,
                    character_path: str, skeleton_path: str, controls_path: str,
                    source_video: str, reset_to_rest: bool, ack: bool = False,
                    root_motion: Mapping[str, Any] | None = None) -> dict[str, Any]:
    message: dict[str, Any] = {
        "protocol": PROTOCOL_NAME,
        "version": PROTOCOL_VERSION,
        "type": "pose.frame",
        "seq": seq,
        "timestamp_usec": int(time.time_ns() // 1000),
        "ack": ack,
        "source": {
            "application": "video_to_pose_stream.py",
            "video": source_video,
            "solver": "nlf+sam3d-body+temporal",
        },
        "character": {
            "node_path": character_path,
            "skeleton_path": skeleton_path,
            "controls_path": controls_path,
        },
        "pose_name": "mocap-live",
        "pose": {
            "mode": "fk",
            "reset_to_rest": reset_to_rest,
            "bones": {
                name: {"rotation_quaternion": [float(item) for item in quaternion]}
                for name, quaternion in frame_quaternions.items()
            },
        },
    }
    if root_motion is not None:
        message["pose"]["root_motion"] = {
            "position": [float(item) for item in root_motion.get("position", [0.0, 0.0, 0.0])],
            "rotation_y": float(root_motion.get("rotation_y", 0.0)),
            "space": "character_parent",
        }
        if "heading_direction" in root_motion:
            message["pose"]["root_motion"]["heading_direction"] = [
                float(item) for item in root_motion["heading_direction"]
            ]
            message["pose"]["root_motion"]["local_forward"] = [
                float(item) for item in root_motion.get("local_forward", [0.0, 0.0, -1.0])
            ]
            message["pose"]["root_motion"]["upright_root"] = bool(
                root_motion.get("upright_root", False)
            )
        if root_motion.get("scene_origin_node"):
            message["pose"]["root_motion"]["scene_origin_node"] = str(
                root_motion["scene_origin_node"]
            )
        if root_motion.get("ground_y") is not None:
            message["pose"]["root_motion"]["ground_y"] = float(root_motion["ground_y"])
    return message


def _read_line(sock: socket.socket, timeout: float = 2.0) -> dict[str, Any] | None:
    sock.settimeout(timeout)
    buffer = bytearray()
    try:
        while len(buffer) < 1_000_000:
            item = sock.recv(1)
            if not item:
                break
            if item == b"\n":
                break
            buffer.extend(item)
    except TimeoutError:
        return None
    finally:
        sock.settimeout(None)
    return json.loads(buffer.decode("utf-8")) if buffer else None


def stream_motion(motion: Mapping[str, Any], host: str, port: int, loop: bool,
                  character_path: str, skeleton_path: str, controls_path: str) -> None:
    frames = motion["frames"]
    fps = float(motion["fps"])
    source_video = str(motion["source_video"])
    root_data = motion.get("root_motion", {})
    root_positions = root_data.get("positions", []) if isinstance(root_data, Mapping) else []
    root_yaw = root_data.get("rotation_y", []) if isinstance(root_data, Mapping) else []
    heading_directions = root_data.get("heading_directions", []) if isinstance(root_data, Mapping) else []
    local_forward = root_data.get("local_forward", [0.0, 0.0, -1.0]) if isinstance(root_data, Mapping) else [0.0, 0.0, -1.0]
    upright_root = bool(root_data.get("upright_root", False)) if isinstance(root_data, Mapping) else False
    scene_origin_node = str(root_data.get("scene_origin_node", "")) if isinstance(root_data, Mapping) else ""
    ground_y = root_data.get("ground_y") if isinstance(root_data, Mapping) else None
    with socket.create_connection((host, port), timeout=3.0) as sock:
        hello = _read_line(sock)
        if not hello or hello.get("type") != "hello":
            raise RuntimeError(f"{host}:{port} did not send a pose-stream hello")
        print(f"Connected to Godot {host}:{port}; streaming {len(frames)} frames at {fps:g} FPS")
        seq = 0
        while True:
            start = time.monotonic()
            for index, quaternions in enumerate(frames):
                message = make_pose_frame(
                    quaternions, seq, character_path, skeleton_path, controls_path,
                    source_video, reset_to_rest=(index == 0),
                    ack=(index == len(frames) - 1 and not loop),
                    root_motion=(
                        {
                            "position": root_positions[index],
                            "rotation_y": root_yaw[index],
                            **({
                                "heading_direction": heading_directions[index],
                                "local_forward": local_forward,
                                "upright_root": upright_root,
                            } if len(heading_directions) == len(frames) else {}),
                            **({"scene_origin_node": scene_origin_node} if scene_origin_node else {}),
                            **({"ground_y": float(ground_y)} if ground_y is not None else {}),
                        }
                        if len(root_positions) == len(frames) and len(root_yaw) == len(frames)
                        else None
                    ),
                )
                sock.sendall(json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n")
                seq += 1
                deadline = start + (index + 1) / fps
                delay = deadline - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
            if not loop:
                response = _read_line(sock, timeout=3.0)
                if response:
                    print("Godot final acknowledgement: " + json.dumps(response, separators=(",", ":")))
                break


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    project = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path, nargs="?", help="input motion video")
    parser.add_argument("--duration", type=float, default=4.0)
    parser.add_argument("--fps", type=float, default=30.0, help="solver and TCP output FPS")
    parser.add_argument("--nlf-fps", type=float, default=15.0)
    parser.add_argument("--sam3d-fps", type=float, default=1.0,
                        help="sparse orientation anchor rate; CPU inference is expensive")
    parser.add_argument("--bbox", type=float, nargs=4, metavar=("X1", "Y1", "X2", "Y2"),
                        help="fixed person box; defaults to the full video frame")
    parser.add_argument("--nlf-model", type=Path,
                        default=project / "models/nlf/nlf_l_multi_0.3.2.torchscript")
    parser.add_argument("--nlf-device", default="mps")
    parser.add_argument("--nlf-batch-size", type=int, default=8)
    parser.add_argument("--nlf-weight", type=float, default=1.0)
    parser.add_argument("--root-motion", choices=("off", "pelvis", "foot-contact"),
                        default="foot-contact",
                        help="parent translation source; foot-contact locks planted feet while preserving Hips wobble")
    parser.add_argument("--foot-lock-strength", type=float, default=0.85,
                        help="blend from raw pelvis displacement to planted-foot root correction")
    parser.add_argument("--root-motion-scale", type=float,
                        help="override automatic NLF-to-target scene-unit scale")
    parser.add_argument("--trajectory", type=Path,
                        help="JSON cubic-Bezier waypoint program; gait distance controls path timing")
    parser.add_argument("--trajectory-samples", type=int, default=80,
                        help="arc-length samples per Bezier segment")
    parser.add_argument("--trajectory-heading", choices=("tangent", "none"), default="tangent",
                        help="rotate the character by the trajectory tangent or keep its initial heading")
    parser.add_argument("--sam3d-repo", type=Path, default=project / "sam3d/sam-3d-body-repo")
    parser.add_argument("--sam3d-checkpoint", type=Path,
                        default=project / "sam3d/sam-3d-body-vith/model.ckpt")
    parser.add_argument("--mhr-model", type=Path,
                        default=project / "sam3d/sam-3d-body-vith/assets/mhr_model.pt")
    parser.add_argument("--sam3d-device", default="cpu")
    parser.add_argument("--target-glb", type=Path,
                        default=project / "assets/models/actor_1787313553107_v2_realtime_proxy.glb")
    parser.add_argument("--output-dir", type=Path,
                        default=project / "renders/mocap/girl_dance_003_first4s")
    parser.add_argument("--reuse-observations", action="store_true")
    parser.add_argument("--stream-cache", type=Path,
                        help="skip inference and stream an existing motion_pose_frames.json")
    parser.add_argument("--no-stream", action="store_true", help="fit and cache without connecting")
    parser.add_argument("--dry-run", action="store_true", help="fit/validate but do not connect")
    parser.add_argument("--loop", action="store_true")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7007)
    parser.add_argument("--character-path", default="IK_character")
    parser.add_argument("--skeleton-path", default="Skeleton3D")
    parser.add_argument("--controls-path", default="../PoseControls")
    return parser.parse_args(argv)


def validate_paths(args: argparse.Namespace) -> None:
    if args.stream_cache:
        if not args.stream_cache.is_file():
            raise RuntimeError(f"motion cache does not exist: {args.stream_cache}")
        return
    if args.video is None or not args.video.is_file():
        raise RuntimeError(f"input video does not exist: {args.video}")
    for label, path in (
        ("NLF model", args.nlf_model), ("SAM 3D Body repository", args.sam3d_repo),
        ("SAM checkpoint", args.sam3d_checkpoint), ("MHR model", args.mhr_model),
        ("target GLB", args.target_glb),
    ):
        if not path.exists():
            raise RuntimeError(f"{label} does not exist: {path}")
    if args.duration <= 0 or args.fps <= 0 or args.nlf_fps <= 0 or args.sam3d_fps <= 0:
        raise RuntimeError("duration and frame rates must be positive")
    if not 0.0 <= args.foot_lock_strength <= 1.0:
        raise RuntimeError("--foot-lock-strength must be between 0 and 1")
    if args.root_motion_scale is not None and args.root_motion_scale <= 0.0:
        raise RuntimeError("--root-motion-scale must be positive")
    if args.trajectory is not None and not args.trajectory.is_file():
        raise RuntimeError(f"trajectory file does not exist: {args.trajectory}")


def fit_motion(args: argparse.Namespace) -> dict[str, Any]:
    args.output_dir.mkdir(parents=True, exist_ok=True)
    observation_path = args.output_dir / "nlf_sam3d_observations.json"
    if args.reuse_observations and observation_path.is_file():
        observations = json.loads(observation_path.read_text(encoding="utf-8"))
        frame_count = int(observations["metadata"]["frame_count"])
        print(f"Reusing observations from {observation_path}")
    else:
        frames, source_fps = decode_video(args.video, args.duration, args.fps)
        frame_count = len(frames)
        height, width = frames[0].shape[:2]
        bbox = list(args.bbox) if args.bbox else [0.0, 0.0, float(width - 1), float(height - 1)]
        nlf_indices = sample_indices(frame_count, args.fps, args.nlf_fps)
        sam_indices = sample_indices(frame_count, args.fps, args.sam3d_fps)
        print(f"Decoded {frame_count} frames; NLF={len(nlf_indices)} samples, "
              f"SAM3D={len(sam_indices)} anchors")
        nlf = NlfObserver(args.nlf_model, args.nlf_device, args.nlf_batch_size)
        nlf_positions, nlf_uncertainties = nlf.observe([frames[i] for i in nlf_indices], bbox)
        observations = {
            "metadata": {
                "source_video": str(args.video.resolve()), "duration": args.duration,
                "source_fps": source_fps, "output_fps": args.fps, "frame_count": frame_count,
                "bbox_xyxy": bbox,
            },
            "nlf": {
                "sample_indices": nlf_indices, "joint_names": nlf.names,
                "positions": nlf_positions, "uncertainties": nlf_uncertainties,
                "model": str(args.nlf_model.resolve()), "device": args.nlf_device,
                "execution_path": "mps_safe_crop_model",
            },
            "sam3d": {"anchor_indices": sam_indices, "records": []},
        }
        write_json(observation_path, observations)
        del nlf
        try:
            import torch  # type: ignore
            if hasattr(torch, "mps"):
                torch.mps.empty_cache()
        except (ImportError, RuntimeError):
            pass
        sam = Sam3dObserver(args.sam3d_repo, args.sam3d_checkpoint, args.mhr_model,
                            args.sam3d_device)
        for ordinal, frame_index in enumerate(sam_indices, start=1):
            record = sam.observe(frames[frame_index], bbox)
            observations["sam3d"]["records"].append(record)
            write_json(observation_path, observations)
            print(f"SAM3D observed anchor {ordinal}/{len(sam_indices)} (frame {frame_index})", flush=True)
        observations["sam3d"].update({
            "model": str(args.sam3d_checkpoint.resolve()), "device": args.sam3d_device,
            "role": "sparse_orientation_and_twist_anchors",
        })
        write_json(observation_path, observations)

    target = load_gltf_rig(args.target_glb)
    source = load_mhr_rig(args.mhr_model)
    if len(target.names) != 56:
        raise RuntimeError(f"expected the female target to contain 56 bones, found {len(target.names)}")
    frame_data, diagnostics, root_motion = solve_motion(
        target, source, observations["nlf"], observations["sam3d"], frame_count,
        args.fps, args.nlf_weight, args.root_motion, args.foot_lock_strength,
        args.root_motion_scale,
        json.loads(args.trajectory.read_text(encoding="utf-8")) if args.trajectory else None,
        args.trajectory_samples, args.trajectory_heading,
    )
    motion = {
        "schema": "godot-pose-motion-cache",
        "version": 1,
        "source_video": str(args.video.resolve()),
        "duration": frame_count / args.fps,
        "fps": args.fps,
        "frame_count": frame_count,
        "bone_count": len(target.names),
        "quaternion_order": "xyzw",
        "rotation_space": "godot4_absolute_local_bone_pose",
        "target_rig": str(args.target_glb.resolve()),
        "solver": {
            "observation_layers": ["NLF SMPL-24", "SAM 3D Body MHR-127"],
            "temporal": ["median joint filter", "quaternion sign continuity",
                         "isolated outlier rejection", "bidirectional slerp",
                         "foot contact damping"],
            "nlf_weight": args.nlf_weight,
        },
        "diagnostics": diagnostics,
        "root_motion": root_motion,
        "frames": frame_data,
    }
    output_path = args.output_dir / "motion_pose_frames.json"
    write_json(output_path, motion)
    print(f"Wrote {frame_count} fitted 56-bone quaternion frames to {output_path}")
    return motion


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        validate_paths(args)
        if args.stream_cache:
            motion = json.loads(args.stream_cache.read_text(encoding="utf-8"))
        else:
            motion = fit_motion(args)
        if args.dry_run or args.no_stream:
            print("Streaming skipped; cached motion is ready for pose.frame replay.")
            return 0
        stream_motion(motion, args.host, args.port, args.loop, args.character_path,
                      args.skeleton_path, args.controls_path)
        return 0
    except (OSError, RuntimeError, ValueError, KeyError, ImportError) as error:
        print(f"video_to_pose_stream: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
