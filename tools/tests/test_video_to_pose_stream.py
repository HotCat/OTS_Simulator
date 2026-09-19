#!/usr/bin/env python3
"""Pure solver/protocol regression tests; model checkpoints are not loaded."""

from __future__ import annotations

import json
import math
import sys
import unittest
from pathlib import Path

import numpy as np


PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / "tools"))

import video_to_pose_stream as mocap  # noqa: E402


class QuaternionTests(unittest.TestCase):
    def test_matrix_round_trip_and_slerp_are_normalized(self) -> None:
        source = mocap.quat_normalize(np.array([0.2, -0.3, 0.1, 0.9]))
        rebuilt = mocap.matrix_to_quat(mocap.quat_to_matrix(source))
        self.assertAlmostEqual(abs(float(np.dot(source, rebuilt))), 1.0, places=7)
        halfway = mocap.quat_slerp(np.array([0.0, 0.0, 0.0, 1.0]), source, 0.5)
        self.assertAlmostEqual(float(np.linalg.norm(halfway)), 1.0, places=7)

    def test_hemisphere_continuity_removes_equivalent_sign_flip(self) -> None:
        value = mocap.quat_normalize(np.array([0.1, 0.2, 0.3, 0.9]))
        filtered = mocap.temporal_quaternion_filter(
            np.asarray([value, -value, value]), responsiveness=1.0,
        )
        self.assertGreater(float(np.dot(filtered[0], filtered[1])), 0.999999)
        self.assertGreater(float(np.dot(filtered[1], filtered[2])), 0.999999)


class RigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rig = mocap.load_gltf_rig(
            PROJECT / "assets/models/actor_1787313553107_v2_realtime_proxy.glb"
        )

    def test_project_female_has_expected_56_bones(self) -> None:
        self.assertEqual(len(self.rig.names), 56)
        self.assertIn("Hips", self.rig.names)
        self.assertIn("Ponytail_Bone3", self.rig.names)

    def test_hips_observation_aims_at_spine_not_thigh(self) -> None:
        offset = mocap.child_offset_for_bone(self.rig, "Hips")
        expected = self.rig.translations[self.rig.index["Spine"]]
        np.testing.assert_allclose(offset, expected)


class ProtocolTests(unittest.TestCase):
    def test_pose_frame_is_ndjson_serializable_and_xyzw(self) -> None:
        message = mocap.make_pose_frame(
            {"Hips": [0.0, 0.0, 0.0, 1.0]}, 7, "IK_character", "Skeleton3D",
            "../PoseControls", "/tmp/input.mp4", True,
        )
        encoded = json.dumps(message, separators=(",", ":")) + "\n"
        decoded = json.loads(encoded)
        self.assertEqual(decoded["type"], "pose.frame")
        self.assertEqual(decoded["seq"], 7)
        self.assertEqual(
            decoded["pose"]["bones"]["Hips"]["rotation_quaternion"],
            [0.0, 0.0, 0.0, 1.0],
        )
        self.assertTrue(decoded["pose"]["reset_to_rest"])

    def test_generated_cache_has_normalized_frames_when_present(self) -> None:
        cache = PROJECT / "renders/mocap/girl_dance_003_first4s/motion_pose_frames.json"
        if not cache.is_file():
            self.skipTest("generated motion cache is intentionally not required by the source test")
        motion = json.loads(cache.read_text(encoding="utf-8"))
        self.assertEqual(motion["frame_count"], 120)
        for frame in motion["frames"]:
            self.assertEqual(len(frame), 56)
            for quaternion in frame.values():
                self.assertAlmostEqual(math.sqrt(sum(item * item for item in quaternion)), 1.0,
                                       places=6)
        # Unobserved fingers/toes must inherit their parent, not counter-rotate
        # a fitted hand/foot with stale SAM global transforms.
        rig = mocap.load_gltf_rig(
            PROJECT / "assets/models/actor_1787313553107_v2_realtime_proxy.glb"
        )
        for bone_name in ("LeftToes", "RightToes", "LeftIndexProximal",
                          "RightIndexProximal"):
            expected = rig.rest_local[rig.index[bone_name]]
            for frame in motion["frames"]:
                actual = np.asarray(frame[bone_name])
                self.assertAlmostEqual(abs(float(np.dot(actual, expected))), 1.0, places=6)
        p95 = motion["diagnostics"]["post_filter_segment_error"]["p95_degrees"]
        self.assertLess(max(p95.values()), 15.0)


if __name__ == "__main__":
    unittest.main()
