# IK Demo 4.6 — Getting Started

This is the official Godot 4.6 IK demo by lukky-nl. The project is configured
to start with `demos/ots_waist_pose_demo.tscn`, a manual OTS posing scene built
on top of the full humanoid IK example.

## Start here

For the Emacs-first, non-baking workflow, open
`poses/ots-carry.gdpose` and follow `POSE_STREAM_WORKFLOW.md`. The pose document
contains the 56-bone rig map, IK controls, and several named runtime poses.

1. Open `project.godot` with Godot 4.6 or newer.
2. Open `demos/ots_waist_pose_demo.tscn` if it is not already selected.
3. Select `IK_character`. Under **Manual OTS Pose** you can:
   - Click **Reset armature to T-pose**.
   - Adjust **Waist Bend Degrees** for forward/back bend.
   - Adjust **Waist Side Bend Degrees** and **Waist Twist Degrees**.
   - Use **Apply waist bend** without resetting your later limb edits.
4. The OTS scene disables body and limb modifiers so they cannot fight direct
   bone posing. Re-enable only the limb IK you want after the waist is placed.
5. Expand `IK_character > Armature > Skeleton3D` in the Scene dock.
6. Select a modifier such as `r_arm` or `l_leg` and inspect its settings.
7. Select and move its matching `Marker3D` target in the 3D viewport:
   - `pelvis_target` moves and rotates the hips/pelvis.
   - `center_back_target` drives the four-joint Hips → Spine2 CCD chain.
   - `neck_target` aims the neck independently from the head.
   - `r_arm_marker` / `l_arm_marker` control the hands.
   - `r_feet_marker` / `l_feet_marker` control the feet.
   - The `*_pole` markers control the elbow or knee bend direction.
   - `head_target` controls the head look direction.
8. Press **F6** to run the current scene, or **F5** to run the default demo.

## Demo map

- `character_demo.tscn`: full humanoid with two-arm and two-leg IK.
- `ots_waist_pose_demo.tscn`: T-pose reset and direct distributed waist bend.
- `animation_demo.tscn`: combines keyframed animation with IK overrides.
- `first_person_demo.tscn`: first-person arm/view-model IK.
- `spine_demo.tscn`: compares CCD, FABRIK, Jacobian, and spline solvers.
- `beast_demo.tscn`: multi-limb procedural creature setup.

## Good first experiments

- Move one hand target, then move its pole marker and observe the elbow.
- Move `pelvis_target` first, then pull `center_back_target` down and forward
  to build the folded torso silhouette used by an over-the-shoulder carry.
- Move `neck_target` to relax the neck, then fine-tune gaze with `head_target`.
- Disable a `TwoBoneIK3D` node to compare the solved and unsolved pose.
- Change the IK influence/weight if available in the Inspector.
- Duplicate `character_demo.tscn` before making large pose experiments.

The mannequin source is `assets/models/IK_character.glb`. All examples use
Godot's built-in Skeleton3D modifier stack introduced in Godot 4.6.
