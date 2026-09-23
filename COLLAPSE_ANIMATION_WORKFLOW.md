# Native collapse animation workflow

The collapse mocap cache is available as a native Godot `AnimationLibrary`:

```text
res://animations/female_collapse_motion.tres
```

The current CoffeeBar scene mounts that library on
`FemaleWalkAnimationPlayer` under the `collapse` namespace, so the clip name
in the Animation panel is:

```text
collapse/female_collapse_motion
```

## Scrub and inspect

1. Open `demos/coffebar_female_walk_scene.tscn` in the Godot editor.
2. Select `FemaleWalkAnimationPlayer` in the scene tree.
3. Open the Animation panel and select `collapse/female_collapse_motion`.
4. Drag the timeline at 24 fps. The clip is 145 frames (6.042 seconds).
5. Inspect the root `IK_character` track and the per-bone rotation tracks. The
   root position track preserves the cached vertical descent; X/Z remain
   fixed. Bone translation keys are intentionally omitted because the rich
   cache positions are absolute GLB-local coordinates; importing them as
   Godot bone tracks double-applies importer/rest transforms and tears the
   mesh. The source positions remain in JSON for diagnostics, but are not
   baked into this native clip.

The animation is not looped. Playing it from the Animation panel is useful for
checking the whole collapse, while scrubbing to a frame is the preferred way
to report a correction (for example, “frame 73: lower the pelvis 6 cm”).

## Re-bake after cache edits

The third baker argument selects the scene whose initial `IK_character`
position is used for absolute root-motion keys. Use the active CoffeeBar scene
for this clip:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path . \
  --script res://tools/bake_motion_cache.gd -- \
  renders/mocap/girl_collapse_lean_wall_6s_final/motion_pose_frames_vertical.json \
  animations/female_collapse_motion.tres \
  res://demos/coffebar_female_walk_scene.tscn
```

The cache stores absolute-local GLB-basis rotations. The baker preserves those
final parent-local quaternions for AnimationPlayer/Skeleton3D. Legacy caches
labelled `godot4_rest_relative_local_pose` are composed with the target bone's
imported rest quaternion during baking. Absolute bone-position entries are
ignored by the native baker; root motion is represented by the `IK_character`
track, which keeps the character placement portable and avoids mesh
deformation.

The same `rotation_space` metadata is carried by pose-stream messages. Absolute
local caches are applied directly; only legacy rest-relative caches are
composed with the imported rest quaternion. Both the native-animation and
live-stream paths therefore use the same bone basis.

## Recapture provenance

The current clip was recaptured from
`/Users/hotcat/zhouyu/mathexam/grandcherokee/girl_collapse_lean_wall.mp4` with
the `capture-sam3d-godot-pose` video workflow. It uses a full-frame subject box
`20 20 700 1265`, NLF at 24 FPS, SAM3D orientation anchors at 4 FPS, pelvis
root motion, and an NLF confidence floor of `0.6`. The confidence floor is
important for the final floor-contact frames: without it, low-confidence leg
observations fall back to the standing rest pose.
