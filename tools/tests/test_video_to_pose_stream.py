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
TARGET_GLB = PROJECT / "assets/models/actor_1787313553107_v2_realtime_proxy.glb"
sys.path.insert(0, str(PROJECT / "tools"))

import video_to_pose_stream as mocap  # noqa: E402
import extract_motion_cycle as cycle_tools  # noqa: E402


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


class CycleExtractionTests(unittest.TestCase):
    def test_cycle_is_in_place_and_records_controller_speed(self) -> None:
        source = {
            "fps": 10.0,
            "frames": [
                {"Hips": [0.0, 0.0, 0.0, 1.0]},
                {"Hips": [0.0, 0.0, 0.0, 1.0]},
                {"Hips": [0.0, 0.0, 0.0, 1.0]},
                {"Hips": [0.0, 0.0, 0.1, 0.99498744]},
                {"Hips": [0.0, 0.0, 0.0, 1.0]},
            ],
            "root_motion": {
                "positions": [[0.1 * i, -0.02 + 0.01 * i, 0.0] for i in range(5)],
                "contacts": {"left": [True] * 5, "right": [False] * 5},
                "local_forward": [0.0, 0.0, -1.0],
            },
            "diagnostics": {},
        }
        result = cycle_tools.extract_cycle(source, 1, 4, "walk")
        self.assertEqual(result["frame_count"], 3)
        self.assertEqual(result["root_motion"]["bake_mode"], "in_place_cycle")
        self.assertTrue(all(position[0] == 0.0 and position[2] == 0.0
                            for position in result["root_motion"]["positions"]))
        self.assertAlmostEqual(result["clip"]["recommended_speed_mps"], 1.0)
        self.assertEqual(result["clip"]["animation_name"], "walk")
        self.assertEqual(
            result["root_motion"]["captured_pace_distances_m"], [0.0, 0.1, 0.2]
        )
        self.assertAlmostEqual(
            result["root_motion"]["captured_pace_cycle_distance_m"], 0.3
        )

    def test_full_capture_cycle_uses_a_smooth_shared_seam(self) -> None:
        source = {
            "fps": 10.0,
            "frames": [
                {"Hips": [0.0, 0.0, math.sin(angle / 2.0), math.cos(angle / 2.0)]}
                for angle in (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
            ],
            "root_motion": {
                "positions": [[0.1 * i, 0.02 * i, 0.0] for i in range(6)],
                "contacts": {"left": [True] * 6, "right": [False] * 6},
                "local_forward": [0.0, 0.0, -1.0],
            },
            "diagnostics": {},
        }
        result = cycle_tools.extract_cycle(source, 0, 6, "long_walk", 2)
        self.assertEqual(result["frame_count"], 6)
        self.assertEqual(result["clip"]["seam_blend_frames"], 2)
        first = np.asarray(result["frames"][0]["Hips"])
        last = np.asarray(result["frames"][-1]["Hips"])
        self.assertAlmostEqual(abs(float(np.dot(first, last))), 1.0, places=7)
        self.assertAlmostEqual(
            result["root_motion"]["positions"][0][1],
            result["root_motion"]["positions"][-1][1], places=7,
        )


class RigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not TARGET_GLB.is_file():
            raise unittest.SkipTest("project target GLB is not bundled with the portable skill")
        cls.rig = mocap.load_gltf_rig(TARGET_GLB)

    def test_project_female_has_expected_56_bones(self) -> None:
        self.assertEqual(len(self.rig.names), 56)
        self.assertIn("Hips", self.rig.names)
        self.assertIn("Ponytail_Bone3", self.rig.names)

    def test_hips_observation_aims_at_spine_not_thigh(self) -> None:
        offset = mocap.child_offset_for_bone(self.rig, "Hips")
        expected = self.rig.translations[self.rig.index["Spine"]]
        np.testing.assert_allclose(offset, expected)

    def test_rig_height_is_in_scene_units(self) -> None:
        self.assertGreater(mocap.estimate_rig_height(self.rig), 1.7)
        self.assertLess(mocap.estimate_rig_height(self.rig), 1.8)

    def test_torso_upright_preserves_upper_leg_global_rotation(self) -> None:
        frame_count = 2
        pose = {
            name: np.tile(self.rig.rest_local[index], (frame_count, 1))
            for index, name in enumerate(self.rig.names)
        }
        half = math.radians(25.0) * 0.5
        tilt = np.array([math.sin(half), 0.0, 0.0, math.cos(half)])
        hips = self.rig.index["Hips"]
        pose["Hips"][:] = mocap.quat_multiply(tilt, self.rig.rest_local[hips])
        def global_rotation(name: str) -> np.ndarray:
            result = np.array([0.0, 0.0, 0.0, 1.0])
            chain = []
            index = self.rig.index[name]
            while index >= 0:
                chain.append(index)
                index = int(self.rig.parents[index])
            for index in reversed(chain):
                result = mocap.quat_multiply(result, pose[self.rig.names[index]][0])
            return result
        before_legs = {name: global_rotation(name)
                       for name in ("LeftUpperLeg", "RightUpperLeg")}
        diagnostics = mocap.stabilize_torso_upright(self.rig, pose, 8.0, 1.0)
        self.assertEqual(diagnostics["applied_frames"], 2.0)
        for name in ("LeftUpperLeg", "RightUpperLeg"):
            self.assertAlmostEqual(abs(float(np.dot(global_rotation(name), before_legs[name]))),
                                   1.0, places=6)

    def test_head_upward_pitch_is_limited(self) -> None:
        pose = {name: np.asarray([self.rig.rest_local[index].copy()])
                for index, name in enumerate(self.rig.names)}
        half = math.radians(20.0) * 0.5
        upward = np.array([-math.sin(half), 0.0, 0.0, math.cos(half)])
        head = self.rig.index["Head"]
        pose["Head"][0] = mocap.quat_multiply(upward, self.rig.rest_local[head])
        diagnostics = mocap.limit_head_upward_pitch(self.rig, pose, 4.0)
        global_rotation = np.array([0.0, 0.0, 0.0, 1.0])
        chain = []
        index = head
        while index >= 0:
            chain.append(index)
            index = int(self.rig.parents[index])
        for index in reversed(chain):
            global_rotation = mocap.quat_multiply(
                global_rotation, pose[self.rig.names[index]][0]
            )
        forward = mocap.rotate_vector(global_rotation, np.array([0.0, 0.0, 1.0]))
        pitch = math.degrees(math.asin(float(forward[1] / np.linalg.norm(forward))))
        self.assertLessEqual(pitch, 4.000001)
        self.assertEqual(diagnostics["applied_frames"], 1.0)

    def test_target_rig_foot_ik_pins_horizontal_support_ankle(self) -> None:
        frame_count = 4
        pose = {
            name: np.tile(self.rig.rest_local[index], (frame_count, 1))
            for index, name in enumerate(self.rig.names)
        }
        root = np.zeros((frame_count, 3), dtype=np.float64)
        root[:, 2] = [0.0, 0.04, 0.08, 0.12]
        diagnostics = mocap.solve_planted_foot_ik(
            self.rig, pose, root, np.zeros(frame_count),
            {"left": [True] * frame_count, "right": [False] * frame_count},
            local_forward=[0.0, 0.0, 1.0], strength=1.0,
        )
        self.assertTrue(diagnostics["enabled"])
        self.assertLess(diagnostics["after_max_error"], 0.001)
        self.assertLess(diagnostics["after_max_error"],
                        diagnostics["before_max_error"] * 0.01)
        self.assertGreater(diagnostics["before_max_error"], 0.1)

    def test_generated_bilateral_pace_locks_both_stance_feet(self) -> None:
        cache_path = (PROJECT / "renders/mocap/6aaba7_walk_bezier"
                      / "female_walk_cycle.json")
        if not cache_path.is_file():
            self.skipTest("generated walk-cycle cache is not present")
        cycle = json.loads(cache_path.read_text(encoding="utf-8"))
        root = cycle["root_motion"]
        local_pose = {
            name: np.asarray([frame[name] for frame in cycle["frames"]], dtype=float)
            for name in self.rig.names
        }
        feet = mocap.fk_bone_positions(
            self.rig, local_pose, ("LeftFoot", "RightFoot")
        )
        forward = np.asarray(root["foot_contact_local_forward"], dtype=float)[[0, 2]]
        side = np.array([-forward[1], forward[0]], dtype=float)
        root_xz = (
            np.asarray(root["foot_contact_pace_distances_m"], dtype=float)[:, None]
            * forward
            + np.asarray(root["foot_contact_lateral_offsets_m"], dtype=float)[:, None]
            * side
        )
        for side_name, bone_name in (("left", "LeftFoot"), ("right", "RightFoot")):
            contacts = np.asarray(root["contacts"][side_name], dtype=bool)
            world_foot = root_xz + feet[bone_name][:, [0, 2]]
            continuing = contacts[1:] & contacts[:-1]
            stance_speed = np.linalg.norm(np.diff(world_foot, axis=0), axis=1)
            stance_speed *= float(cycle["fps"])
            self.assertTrue(np.any(continuing), f"{side_name} foot has no stance interval")
            self.assertLess(float(np.max(stance_speed[continuing])), 1e-4)


class RootMotionTests(unittest.TestCase):
    def test_ground_lock_places_support_toe_on_ground(self) -> None:
        root = np.zeros((3, 3), dtype=np.float64)
        left_foot = np.array([[0, 0.12, 0], [0, 0.13, 0], [0, 0.14, 0]], dtype=float)
        left_toes = np.array([[0, 0.02, 0], [0, 0.03, 0], [0, 0.04, 0]], dtype=float)
        corrected, diagnostics = mocap.apply_ground_lock(
            root,
            {"left_foot": left_foot, "left_toes": left_toes},
            {"left": [True] * 3, "right": [False] * 3},
            skeleton_origin_y=0.1,
        )
        np.testing.assert_allclose(corrected[:, 1], [-0.12, -0.13, -0.14], atol=1e-8)
        np.testing.assert_allclose(corrected[:, 1] + 0.1 + left_toes[:, 1], 0.0, atol=1e-8)
        self.assertAlmostEqual(diagnostics["skeleton_origin_y"], 0.1)
    def test_linear_trajectory_ignores_bezier_handles(self) -> None:
        root = np.zeros((3, 3), dtype=np.float64)
        root[:, 2] = [0.0, 0.5, 1.0]
        trajectory = {
            "type": "linear",
            "distance_mode": "fit",
            "waypoints": [
                {"position": [0, 0, 0], "out_handle": [20, 0, 20]},
                {"position": [2, 0, 0], "in_handle": [-20, 0, 20]},
            ],
        }
        positions, _, diagnostics = mocap.plan_bezier_trajectory(root, trajectory)
        np.testing.assert_allclose(positions[:, 2], 0.0, atol=1e-8)
        np.testing.assert_allclose(positions[-1], [2.0, 0.0, 0.0], atol=1e-5)
        self.assertEqual(diagnostics["type"], "linear")

    def test_linear_fit_constant_speed_has_uniform_root_steps(self) -> None:
        root = np.zeros((7, 3), dtype=np.float64)
        root[:, 2] = [0.0, 0.02, 0.31, 0.35, 0.78, 0.81, 1.0]
        trajectory = {
            "type": "linear", "distance_mode": "fit", "speed_profile": "constant",
            "waypoints": [{"position": [0, 0, 0]}, {"position": [0, 0, 3]}],
        }
        positions, _, _ = mocap.plan_bezier_trajectory(root, trajectory)
        steps = np.linalg.norm(np.diff(positions[:, [0, 2]], axis=0), axis=1)
        np.testing.assert_allclose(steps, np.full_like(steps, 0.5), atol=1e-7)

    def test_bezier_trajectory_preserves_gait_distance(self) -> None:
        root = np.zeros((5, 3), dtype=np.float64)
        root[:, 2] = [0.0, 0.2, 0.5, 0.7, 1.0]
        trajectory = {"waypoints": [
            {"position": [0, 0, 0], "out_handle": [0, 0, 1]},
            {"position": [2, 0, 2], "in_handle": [-1, 0, 0]},
        ]}
        positions, heading, diagnostics = mocap.plan_bezier_trajectory(root, trajectory)
        np.testing.assert_allclose(positions[0], [0, 0, 0], atol=1e-7)
        travelled = np.linalg.norm(np.diff(positions[:, [0, 2]], axis=0), axis=1).sum()
        self.assertAlmostEqual(float(travelled), 1.0, places=2)
        self.assertFalse(diagnostics["path_completed"])
        self.assertEqual(diagnostics["distance_mode"], "gait")
        self.assertTrue(np.all(np.diff(np.linalg.norm(positions, axis=1)) >= -0.2))
        self.assertEqual(len(heading), len(root))
        self.assertAlmostEqual(float(heading[0]), 0.0, places=6)
        self.assertEqual(diagnostics["waypoint_count"], 2)

    def test_bezier_fit_mode_reaches_authored_endpoint(self) -> None:
        root = np.zeros((3, 3), dtype=np.float64)
        root[:, 2] = [0.0, 0.5, 1.0]
        trajectory = {
            "distance_mode": "fit",
            "waypoints": [
                {"position": [0, 0, 0], "out_handle": [0, 0, 1]},
                {"position": [2, 0, 2], "in_handle": [-1, 0, 0]},
            ],
        }
        positions, _, diagnostics = mocap.plan_bezier_trajectory(root, trajectory)
        np.testing.assert_allclose(positions[-1], [2, 0, 2], atol=1e-5)
        self.assertTrue(diagnostics["path_completed"])

    def test_lateral_wobble_does_not_become_forward_distance(self) -> None:
        root = np.array([
            [0.0, 0.0, 0.0], [0.4, 0.0, 0.25], [-0.4, 0.0, 0.5],
            [0.4, 0.0, 0.75], [0.0, 0.0, 1.0],
        ])
        trajectory = {"waypoints": [
            {"position": [0, 0, 0], "out_handle": [0, 0, 1]},
            {"position": [0, 0, 3], "in_handle": [0, 0, -1]},
        ]}
        positions, _, diagnostics = mocap.plan_bezier_trajectory(root, trajectory)
        self.assertAlmostEqual(diagnostics["gait_distance"], 1.0, places=6)
        self.assertAlmostEqual(float(positions[-1, 2]), 1.0, places=3)

    def test_bezier_heading_uses_absolute_parent_space_tangent(self) -> None:
        root = np.zeros((3, 3), dtype=np.float64)
        root[:, 2] = [0.0, 0.5, 1.0]
        trajectory = {"waypoints": [
            {"position": [0, 0, 0], "out_handle": [1, 0, 0]},
            {"position": [2, 0, 0], "in_handle": [-1, 0, 0]},
        ]}
        _, heading, _ = mocap.plan_bezier_trajectory(root, trajectory)
        self.assertAlmostEqual(float(heading[0]), math.pi / 2.0, places=6)

    def test_target_foot_contact_corrects_distance_for_minus_z_avatar(self) -> None:
        # Nominal root travel is too fast: the planted foot moves only 0.2 m
        # backward in avatar space for every 0.5 m of requested root travel.
        # With local -Z facing curve +Z, the target-rig contact solve must reduce
        # path travel to 0.2 m/frame so the resulting world foot remains fixed.
        root = np.zeros((3, 3), dtype=np.float64)
        root[:, 2] = [0.0, 0.5, 1.0]
        left_foot = np.zeros((3, 3), dtype=np.float64)
        left_foot[:, 2] = [0.0, 0.2, 0.4]
        trajectory = {
            "contact_correction": 1.0,
            "local_forward": [0.0, 0.0, -1.0],
            "waypoints": [
                {"position": [0, 0, 0], "out_handle": [0, 0, 1]},
                {"position": [0, 0, 3], "in_handle": [0, 0, -1]},
            ],
        }
        positions, _, diagnostics = mocap.plan_bezier_trajectory(
            root, trajectory,
            contacts={"left": [True, True, True], "right": [False, False, False]},
            foot_positions={"left": left_foot},
        )
        np.testing.assert_allclose(positions[:, 2], [0.0, 0.2, 0.4], atol=1e-3)
        self.assertEqual(diagnostics["target_foot_contact_correction"], 1.0)

    def test_contact_distance_persists_across_support_foot_change(self) -> None:
        root = np.zeros((4, 3), dtype=np.float64)
        left_foot = np.zeros((4, 3), dtype=np.float64)
        right_foot = np.zeros((4, 3), dtype=np.float64)
        left_foot[:, 2] = [0.0, 0.2, 0.2, 0.2]
        right_foot[:, 2] = [0.0, 0.0, 0.0, 0.2]
        trajectory = {
            "contact_correction": 1.0,
            "local_forward": [0.0, 0.0, -1.0],
            "waypoints": [
                {"position": [0, 0, 0], "out_handle": [0, 0, 1]},
                {"position": [0, 0, 3], "in_handle": [0, 0, -1]},
            ],
        }
        positions, _, _ = mocap.plan_bezier_trajectory(
            root, trajectory,
            contacts={
                "left": [True, True, False, False],
                "right": [False, False, True, True],
            },
            foot_positions={"left": left_foot, "right": right_foot},
        )
        np.testing.assert_allclose(positions[:, 2], [0.0, 0.2, 0.2, 0.4], atol=1e-3)

    def test_fit_mode_restores_endpoint_after_target_foot_lock(self) -> None:
        root = np.zeros((4, 3), dtype=np.float64)
        root[:, 2] = [0.0, 0.3, 0.7, 1.0]
        left_foot = np.zeros((4, 3), dtype=np.float64)
        left_foot[:, 2] = [0.0, 0.2, 0.4, 0.6]
        trajectory = {
            "distance_mode": "fit",
            "contact_correction": 1.0,
            "local_forward": [0.0, 0.0, -1.0],
            "waypoints": [
                {"position": [0, 0, 0], "out_handle": [0, 0, 1]},
                {"position": [0, 0, 3], "in_handle": [0, 0, -1]},
            ],
        }
        positions, _, diagnostics = mocap.plan_bezier_trajectory(
            root, trajectory,
            contacts={"left": [True] * 4, "right": [False] * 4},
            foot_positions={"left": left_foot},
        )
        np.testing.assert_allclose(positions[-1], [0.0, 0.0, 3.0], atol=1e-5)
        self.assertTrue(diagnostics["path_completed"])

    def test_foot_contact_root_motion_starts_at_zero(self) -> None:
        identity = np.array([0.0, 0.0, 0.0, 1.0])
        rig = mocap.Rig(
            ["Root", "Hips", "Head"], np.array([-1, 0, 1]),
            np.array([[0, 0, 0], [0, 0.9, 0], [0, 0.8, 0]], dtype=np.float64),
            np.tile(identity, (3, 1)), np.tile(identity, (3, 1)),
        )
        names = ["head", "lhip", "rhip", "lank", "rank"]
        positions = np.zeros((4, 5, 3), dtype=np.float64)
        positions[:, 0, 1] = 1.7
        positions[:, 1, 1] = positions[:, 2, 1] = 0.9
        positions[:, 3, 1] = positions[:, 4, 1] = 0.0
        positions[:, 1:3, 2] = np.arange(4)[:, None] * 0.1
        contacts = {"left": [True] * 4, "right": [False] * 4}
        root, diagnostics = mocap.infer_root_motion(
            rig, names, positions, contacts, 30.0, "foot-contact", 1.0, 1.0,
        )
        np.testing.assert_allclose(root[0], [0, 0, 0])
        self.assertEqual(diagnostics["mode"], "foot-contact")


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

    def test_pose_frame_carries_parent_space_root_motion(self) -> None:
        message = mocap.make_pose_frame(
            {"Hips": [0.0, 0.0, 0.0, 1.0]}, 2, "IK_character", "Skeleton3D",
            "../PoseControls", "/tmp/input.mp4", False,
            root_motion={
                "position": [1.0, 0.0, 2.0], "rotation_y": 0.4,
                "heading_direction": [1.0, 0.0, 0.0],
                "local_forward": [0.0, 0.0, -1.0],
                "upright_root": True,
                "ground_y": 0.0,
                "scene_origin_node": "FemaleWalkTrajectory/Waypoint_00",
            },
        )
        self.assertEqual(message["pose"]["root_motion"]["space"], "character_parent")
        self.assertEqual(message["pose"]["root_motion"]["position"], [1.0, 0.0, 2.0])
        self.assertEqual(message["pose"]["root_motion"]["heading_direction"], [1.0, 0.0, 0.0])
        self.assertTrue(message["pose"]["root_motion"]["upright_root"])
        self.assertEqual(message["pose"]["root_motion"]["ground_y"], 0.0)
        self.assertEqual(
            message["pose"]["root_motion"]["scene_origin_node"],
            "FemaleWalkTrajectory/Waypoint_00",
        )

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
        if not TARGET_GLB.is_file():
            self.skipTest("project target GLB is not bundled with the portable skill")
        rig = mocap.load_gltf_rig(TARGET_GLB)
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
