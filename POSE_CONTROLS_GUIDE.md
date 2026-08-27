# PoseControls and IK_character

This scene uses ordinary `Node3D` markers as handles for Godot's
`SkeletonModifier3D` nodes. The names are project conventions:

- `xxx_target` usually means a body or torso goal.
- `xxx_marker` usually means an IK end-effector (hand or foot).
- A marker and a target are not different Godot types. What matters is which
  modifier reads the node and which transform components that modifier uses.

## Scene layout

```text
world
├─ PoseControls
│  ├─ pelvis_target       -> pelvis_control (CopyTransformModifier3D)
│  ├─ center_back_target  -> center_back_ik (CCDIK3D)
│  ├─ neck_target         -> neck_ik (LookAtModifier3D)
│  ├─ r/l_arm_marker      -> r/l_arm (TwoBoneIK3D)
│  ├─ r/l_feet_marker     -> r/l_leg (TwoBoneIK3D)
│  └─ r/l_*_pole          -> bend-plane hint for the matching TwoBoneIK3D
└─ IK_character
   └─ Skeleton3D
      ├─ pelvis_control
      ├─ center_back_ik
      ├─ neck_ik
      ├─ r/l_arm
      └─ r/l_leg
```

## What each handle actually does

| Handle | Consumer | Moving it | Rotating it |
|---|---|---|---|
| `pelvis_target` | `pelvis_control` | Moves `Hips` | Intentionally ignored; pelvis copies **position only** |
| `center_back_target` | `center_back_ik` | Bends `Hips -> Spine -> Chest -> UpperChest` toward the goal | Ignored by CCDIK; it solves position, not end orientation |
| `neck_target` | `neck_ik` | Aims the neck toward the goal | Marker rotation is not used by LookAt |
| `r/l_arm_marker` | `r/l_arm` | Positions the hand by solving upper/lower arm | Rotation is ignored by TwoBoneIK |
| `r/l_feet_marker` | `r/l_leg` | Positions the foot by solving upper/lower leg | Rotation is ignored by TwoBoneIK |
| `r/l_arm_pole` | matching arm IK | Changes elbow bend side | Rotation is ignored |
| `r/l_feet_pole` | matching leg IK | Changes knee bend side | Rotation is ignored |
| `head_target` | `head_look_at` | Would aim the head | Rotation is ignored; currently disabled by the manual controller |

The right-hand copy-transform helper is also disabled while manually posing.
This is deliberate: enabling it at the same time as `r_arm` would make two
modifiers compete for the same hand.

## Why a moved target can appear to do nothing

There are three common causes:

1. **The wrong mode is enabled.** `IK_character.body_ik_enabled` must be true
   for pelvis, center-back, and neck modifiers. `limb_ik_enabled` must be true
   for hand and foot modifiers.
2. **The target is out of reach.** CCDIK and TwoBoneIK can only solve within
   the chain's bone lengths. Put the target near the body first, then move it
   gradually.
3. **The manual waist pass is competing with IK.** The controller's
   `waist_bend_degrees` writes rotations directly to the waist bones. For
   target-driven torso experiments, set `waist_bend_degrees = 0` and leave
   `body_ik_enabled = true`. For slider-driven manual waist posing, set
   `body_ik_enabled = false`.

The editor gizmo itself does not know about IK. It only moves a Node3D; the
modifier must be active and point at that node.

## A reliable learning workflow

1. Stop the running game and reload `my_manual_rig_pose.tscn` from disk.
2. Expand `PoseControls` and select one handle.
3. Press **F** in the 3D viewport to frame the selected handle.
4. Use the **Move** gizmo first. Test rotation only on the parent character or
   on a bone; the IK handles in this scene are position goals.
5. Move a pole only after the hand/foot is in a useful position.
6. If you get an unexpected result, toggle the relevant modifier state on
   `IK_character`, instead of moving several targets at once.

The Inspector buttons are explicit mode switches:

| Button | Resulting mode |
|---|---|
| **Reset armature to T-pose** | Resets bones, restores the proxy handles, and disables body/limb IK so the imported rest pose is visible |
| **Apply waist bend** | Disables both IK stacks and applies the waist slider rotations directly |
| **Apply proxy forward drape** | Restores known-good handles and enables body + limb IK for target-driven OTS posing |
| **Restore proxy control markers** | Resets only the handle positions; it does not reset bone poses or modifier state |
| **Bake current IK pose to bones** | Captures the evaluated IK result into all Skeleton3D bone poses, disables every modifier, and enters FK editing mode |

After using a button in the editor, save the scene if you want that mode and
those target positions to become the next run's defaults. Reload the scene from
disk before testing if the Inspector was already open while the script changed.

### Baking IK for precise FK editing

1. Use `PoseControls` with body and limb IK enabled to make the coarse pose.
2. Select `IK_character` and click **Bake current IK pose to bones**.
3. Wait until `Pose Mode Status` reports **Baked FK mode**.
4. Expand `IK_character/Skeleton3D`, switch to bone editing, and refine local
   bone rotations. IK is now disabled, so the controls no longer overwrite FK.
5. Save the scene with **Command-S**. The editor marks the scene as modified
   when the bake completes.

To return to target posing, click **Apply proxy forward drape** (known-good OTS
targets) or enable body/limb IK and place the controls again. To discard the
baked pose and return to the imported rest pose, click **Reset armature to
T-pose**.

## Pose recipes

### Crouch start

- Keep `body_ik_enabled = true`.
- Move `pelvis_target` down and slightly back.
- Move `center_back_target` down and a small amount forward.
- Move both foot markers toward the body; move the poles forward to choose the
  knee direction.
- Move hand markers toward the intended balance point.

### Diving / horizontal fold

- Keep the pelvis near the starting position.
- Move `center_back_target` forward and down, in small increments.
- Move `neck_target` and `head_target` with the chest so the head does not stay
  upright.
- Put the foot markers near the trailing-leg positions and move their poles
  to choose knee direction.
- Do not start with a target several meters away; reachability matters.

### OTS carry / drape over the blue wall

- Use the **Apply proxy forward drape** Inspector button as a known-good
  starting point.
- Keep `body_ik_enabled = true`, `limb_ik_enabled = true`, and the waist sliders
  at zero while learning target-driven behavior.
- The useful sequence is: pelvis position, center-back position, neck target,
  then hands/feet and poles.
- In this scene, moving the center-back target toward the wall and downward
  produces forward flexion; moving it back toward the opposite side produces
  extension.

## Why rotations are not currently useful

Godot's `TwoBoneIK3D`, `CCDIK3D`, and `LookAtModifier3D` primarily solve
positions/directions. A rotated target does not automatically mean “rotate the
hand/foot/head to match.” To make orientation matter, add a separate
`CopyTransformModifier3D` (or an animation/retargeting pass) for that bone and
define its ordering relative to the positional IK modifier. That is a separate
feature from moving the existing markers.
## Saving a precise FK pose

1. Pose with the IK markers, then click **Bake current IK pose to bones**.
2. Select `IK_character/Skeleton3D` and refine individual bones.
3. Bone changes are captured automatically while all IK modifiers are off. For
   an explicit checkpoint, select `IK_character` and click **Commit current FK
   adjustments for saving**.
4. Press **Cmd+S**. The controller stores a hidden 56-bone FK snapshot and
   restores it when the scene is opened again.

If the commit button reports that IK is active, use **Bake current IK pose to
bones** first. Direct FK edits and active IK should not be used at the same time.

## Quick FK torso controls

The 3D viewport now has a **Quick FK — Torso & Head** panel. It provides direct
buttons for `Hips`, `Spine`, `Chest`, `UpperChest`, `Neck`, and `Head`, followed
by local X/Y/Z rotation fields. These controls avoid navigating the full
Skeleton3D bone tree.

The panel deliberately disables its rotation fields while IK is active. Bake
the coarse marker pose first, choose a bone in the panel, and then type or drag
the degree values. Each change supports Godot Undo/Redo and commits the hidden
FK snapshot used for saving. Press **Cmd+S** after editing.
