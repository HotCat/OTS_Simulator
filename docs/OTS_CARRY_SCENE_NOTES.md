# OTS carry scene notes

## Skeleton and mesh alignment

`ots_carry_clay_proxy.tscn` keeps the authored character scene as the nested
`ManualCarryBlock` instance. The previous generated version flattened the GLB
children into the new scene, which duplicated imported `Skeleton3D`/skin data
and could make the visible mesh use a different bind transform than the rig.
The builder now preserves the original `my_manual_rig_pose.tscn` instance and
only adds the clay street, carry anchors, and controller around it.

The female character remains at:

```text
OTSCarryClayProxy/ManualCarryBlock/IK_character
OTSCarryClayProxy/ManualCarryBlock/IK_character/Skeleton3D
```

The male carrier remains at:

```text
OTSCarryClayProxy/ManualCarryBlock/MaleCarrier
OTSCarryClayProxy/ManualCarryBlock/MaleCarrier/Skeleton3D
```

Do not reparent or duplicate `Avatar`/`Skeleton3D` children inside either
character instance. Pose the character through the existing `PoseControls` or
the authored FK controls, then save the nested scene state.

## Environment lighting

The active environment and key light are inherited from the manual block:

```text
OTSCarryClayProxy/ManualCarryBlock/env/WorldEnvironment
OTSCarryClayProxy/ManualCarryBlock/env/DirectionalLight3D
```

In Godot, expand `ManualCarryBlock` in the scene tree. It is marked editable in
the carry scene, so you can select these nodes directly.

- Select `WorldEnvironment` and edit its `Environment` resource for background,
  ambient light, exposure, tonemapping, fog, and glow.
- Select `DirectionalLight3D` and edit `Light > Energy`, `Light > Color`,
  `Shadow`, and the node rotation to change the sun/key-light direction.
- The clay street GLB does not own the scene lighting; its mesh materials are
  lit by these scene-level nodes.

The carry scene script hides the old manual staging geometry and disables the
old female walk controller while leaving the environment, camera, pose
controls, and character bindings intact.

## Infinite carrier gait cycle

`animations/ots_carry_walk_cycle.tres` contains the male-only loop used by the
scene. Its requested source range begins at `1.24` and searches through
`5.875` seconds. The builder compares weighted Hips, thigh, shin, and foot pose
plus angular velocity, then chooses the latest same-phase local minimum close
to the end (`5.708` seconds for the current source). It removes accumulated
Hips yaw, leaves world translation to the trajectory controller, and blends
only `0.125` seconds across the wrap. The first and last quaternion stored on
every track are identical without a long foot-sliding cross-fade.

Rebuild and verify it with:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/build_ots_walk_cycle.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/verify_ots_walk_cycle.gd
```

## Carrier trajectory and walk plane

The scene has two authoring nodes:

```text
OTSCarryClayProxy/CarrierTrajectory
OTSCarryClayProxy/CarrierWalkPlane
```

Expand `CarrierTrajectory` and drag the eight markers from `Waypoint_00`
through `Waypoint_07` in the 3D viewport. The enabled **Walk Path** editor dock
also recognizes this carrier path, so it can add, remove, select, and preview
the ordered markers. Straight segments connect the markers.

The dock's **Load/加载** button synchronizes an existing carrier path from the
JSON file shown in the path field. It updates positions, creates missing
markers, and removes surplus markers, so the scene count always matches the
JSON count. It no longer merely selects an already-existing trajectory.

Select the `OTSCarryClayProxy` root to tune `Carrier Trajectory` and
`Carrier Foot Lock` in the Inspector. Important properties are:

- `carrier_walk_plane_path`: the Node3D whose local XZ plane is walkable;
- `carrier_height_above_plane`: the carrier-root offset above that plane;
- `carrier_walk_speed_mps`: travel speed independent of the gait loop;
- `carrier_trajectory_loop`: wrap the route itself as well as the gait;
- `carrier_face_trajectory`: let the route tangent own heading;
- `carrier_local_forward`: local `+Z` for this MakeHuman male rig;
- foot-contact height, speed, and lock strength for planted-foot correction.

For a level street, either leave `carrier_walk_plane_path` assigned to the
dedicated `CarrierWalkPlane` marker and align it to the street, or assign the
level `CoffeeBarStreet_Clay_Proxy` root directly. For a sloped street, rotate
`CarrierWalkPlane` so its local green/Y axis is the surface normal. Press
**Project trajectory markers onto walk plane** after moving the markers.

The controller projects every waypoint and carrier position onto the selected
plane. It averages left and right anchor errors during double support, so one
foot is not arbitrarily preferred. The captured clip no longer controls world
heading; curved or straight travel is authored entirely by the trajectory.

Waypoint corners are sampled through a Catmull–Rom curve before the carrier is
placed on the route. Set `trajectory_corner_smoothing` to `0` for the original
piecewise-linear path, or increase it toward `1` for a broader, softer turn.
`trajectory_samples_per_segment` controls heading resolution (10 is a good
default for editor playback). The markers remain the control points, so the
JSON authoring format and waypoint positions are unchanged.

## Female pelvis attachment and lag

The calibrated pelvis contact is transported rigidly by the male carrier root.
`pelvis_position_lag_seconds` and `pelvis_rotation_lag_seconds` filter only the
shoulder's gait motion in carrier-local space. They do not lag trajectory
translation or route turns. This distinction prevents the woman from trailing
behind the shoulder while the man walks and then snapping into alignment when
he stops.

To change the authored carry alignment, pause the animation, disable
`preview_female_attachment_in_editor`, pose and place `IK_character`, then press
**Calibrate pelvis to current shoulder pose**. Re-enable the preview and save
the scene. If you also changed the female FK pose, press **Capture current
female pose as dangle baseline** before re-enabling procedural motion.

Run the attachment regression check with:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/test_ots_carry_attachment.gd
```

## Foot-driven carried-body motion

With `rhythm_source` set to **Measured foot height**, the male carrier's
`LeftFoot` and `RightFoot` bones drive the woman's alternating leg, arm, head,
and torso offsets. The female feet are never used as the gait clock. The
controller learns each male foot's planted height during the first cycle, so
starting the preview while one foot is already raised is supported.

Use `secondary_motion_lag_seconds` for the overall response delay, then tune
the individual `*_degrees` properties for legs, knees, feet, arms, forearms,
head, and torso. `preview_procedural_motion_in_editor` must be enabled to see
these offsets while playing the `OTSCarryAnimationPlayer` in the editor.

Run the secondary-motion regression check with:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/test_ots_carry_secondary_motion.gd
```
