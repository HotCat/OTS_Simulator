# IKEA sample room female comparison scene

Open `ikea_sample_room_female_compare.tscn` in Godot. `Female181/IK_character`
and `Female190/IK_character` are separate imported rigs; use each full path
when sending a pose or selecting it for Quick FK. Their `WalkAnimationPlayer`,
`WalkTrajectory`, and `WalkController` nodes are independent.

`IkeaSampleRoom` contains only the room shell and fixed accents. Select the
top-level `Bed` or `Wardrobe` node in the Scene tree and change its Position or
Rotation in the Inspector, or use the viewport transform gizmo. Both are
separate GLB instances with local floor-center pivots; changing one does not
move the other or leave furniture behind in the room shell. Their editable
Blender sources are under `assets/environments/ikea_sample_room/`.

Select `GridDoorHinge` or `SolidDoorHinge` and adjust **Opening Angle Degrees**
in the Inspector. Each leaf opens inward independently from 0° (closed) to
120°. The former bedside table and lamp/shade have been removed. `Ceiling` is
a separate top-level instance hidden by default for overhead camera freedom;
toggle its visibility on for captures where the upper room is in view. If the
ceiling stays hidden in an H3 guide video, explicitly describe a normal
enclosed 2.70 m room ceiling in the prompt and, for upward-looking shots,
provide a ceiling-on still as an additional reference. H3 may infer it, but
the prompt alone does not guarantee consistent roof reconstruction.

The root `IkeaSampleRoomFemaleCompare` is a small director that coordinates
both walk controllers during OTS Render fixed-step capture. This prevents a
slow render from advancing one character more than the other. Use its play,
pause, and restart buttons for synchronized editor previews; edit each path's
waypoints locally beneath its character.

`MaleCarrier/Character` is the male Humanizer rig from the OTS scene. The
Mixamo `Administering Cpr.fbx` drives him; `Receiving Cpr.fbx` drives
`Female190/IK_character`. Neither woman's walk library is replaced.
Select the scene root and click **Play CPR on male + Female190**, **Pause CPR**,
or **Restart CPR** for a synchronized editor preview. The two non-looping
8.63-second clips appear as `cpr/administering_cpr` on
`MaleCPRAnimationPlayer` and `cpr/receiving_cpr` on
`Female190CPRAnimationPlayer`, so each can also be scrubbed independently.
`Female181` remains hidden and unmodified. The armature motion carries the
rescuer's kneeling/compressions and the receiver's supine body orientation;
do not replace these with a constant kneeling offset. Reposition the
`MaleCarrier` and `Female190` staging roots to adjust the pair without
altering the imported motions. Leaving CPR preview restores the saved scene
transforms and bone poses before returning to walk preview.

The separate baked libraries are `animations/ikea_cpr_male.tres` and
`animations/ikea_cpr_female190.tres`. Regenerate them with
`Godot --headless --path . --script res://tools/scene_builders/bake_ikea_cpr.gd`.
The baker reads each character's own Godot-imported FBX rotation and animated
armature transform, verifies the bone hierarchy, rest axes and 100:1 import
scale, and fills unanimated bones from that target's neutral GLB pose. The
validator compares source and target bone keys and six representative joint
positions at the start and midpoint, plus editor seek and fixed-step capture.
Do not bake the Blender `--application-mode absolute` cache directly into
Godot: its local bone bases differ on arms and legs and cause severe twisting.

## CPR servo preview and hand calibration

`Female181` also has a separate retargeted `sleep/sleeping_idle` clip from
`assets/downloads/Sleeping Idle.fbx`. Select the scene root and click **Play
Female181 sleeping idle** to reveal her and preview the 6.87-second loop;
**Pause Female181 sleeping idle** holds the current frame. You can also scrub
it directly on `SleepingIdleAnimationPlayer` in the Animation panel. The clip
does not replace her three walk libraries. Its imported armature placement is
preserved relative to `Female181`; move the `Female181` staging root to place
the sleeping character on the bed.

The CPR servo is a separate nine-second editor-preview mode; it does not
overwrite either baked CPR clip or the walk animations. It uses the first
frame of `cpr/administering_cpr` and `cpr/receiving_cpr` as the saved kneeling
and supine poses. Select the scene root and use **Play 9s CPR servo**,
**Pause CPR servo**, or **Restart CPR servo**. Adjust compression rate, start
delay, stroke depth, phase timing, and receiver lags on `CPRServoController`.
Its default 108 compressions/minute and 5.2 cm wrist-target stroke are
adult-CPR reference values, not a substitute for medical training.

For a custom contact pose, stop the servo, click **Calibrate CPR palm contact
at source pose**, then click **Show CPR hand/pole handles**. Select
`CPRServoAnchors/LeftPalmTarget` and `RightPalmTarget` and move or rotate them
with the viewport gizmo to set where and how the rescuer's stacked wrists
meet the receiver's upper chest. The elbow poles are separately movable.
Click **Capture current CPR palm markers** to store the new palm transforms
relative to the receiver's `UpperChest`, then replay. This command also
rebases the servo's time-zero pose to the currently evaluated IK hands; the
next **Play 9s CPR servo** therefore does not restore or shift the hand pose
you just placed. The marker rotations drive wrist orientation as well as arm
IK. If the pair's staging changes, recalibrate at the source pose before
fine-tuning the markers. The saved marker offsets remain authoritative after
reloading the scene.

To pose the man's hands with Quick FK, use the scene-tree path
`MaleCarrier -> Character -> Skeleton3D` (the node is named `Character`, not
`MaleCharrier`). Select that `Skeleton3D`, choose the male character binding
in Quick FK, and edit `LeftHand`/`RightHand` together with their upper/lower
arm bones while the CPR clip is held at its source frame. Do not select
`Female190/IK_character/Skeleton3D`: that is the receiver and contains the
breast/abdomen CPR bones.

1. Hold the CPR source pose, select `MaleCarrier/Character/Skeleton3D`, click
   Quick FK's **Edit source pose**, and pose the left/right arm and hand chains.
   Click **Restore IK**, then **Capture male hand pose as CPR contacts**. This
   captures the current male wrists without seeking the baked CPR clips.
2. On the scene root, click **Enable CPR IK / edit markers**. Its Inspector
   `CPR IK State` reads `ON - marker controls active`, and all four handles are shown.
   Move/rotate
   `CPRServoAnchors/LeftPalmTarget` and `RightPalmTarget` for the exact chest
   contact surface. Move the matching elbow pole if an elbow flips.
3. Click **Capture current CPR palm markers** after the markers look correct,
   then **Play 9s CPR servo**. You should see the same hand placement at
   time zero; only the configured compression stroke moves it afterward.

If you edit the receiver with Quick FK, use the scene-root **Capture current
female CPR pose** button before enabling the servo. This captures the visible
`Female190/IK_character/Skeleton3D` pose without sampling the baked receiving
clip, so playback starts from the edited pose. The same operation is available
as `godot-ikea-cpr-servo-capture-female-pose` in Emacs. Save the scene after
capturing so the edited bone pose and the calibration flag survive reopening.

`Prevent Hand-Chest Penetration` and `Hand Surface Clearance` on
`CPRServoController` provide a proxy-level guard against palm targets entering
the chest center. `Max Hand Surface Depression` caps the additional inward
motion to 1.2 cm by default because this clay receiver's localized chest
deformation is much smaller than the requested wrist stroke. These are not
mesh collision; keep the palm markers on the visible chest surface and tune
the clearance/depression to the actual proxy skin. Increasing `Press Depth`
alone cannot create more non-penetrating chest deformation.

To return to source-pose editing, click **Disable CPR IK / restore source
pose**. `godot-ikea-cpr-servo-status` reports `ik_enabled`,
`markers_visible`, and `editor_mode`; the mode is distinct from playback.
The Emacs equivalents are `godot-ikea-cpr-servo-enable-marker-edit` and
`godot-ikea-cpr-servo-disable-marker-edit`.

During playback the markers are authoritative: Quick FK edits the source
pose, while the two `TwoBoneIK3D` modifiers below the male `Skeleton3D` keep
both hands on those markers through every compression.

`Female190` uses a CPR-only, **62-bone** variant of the 56-bone Humanizer
proxy. The original 56 names, indices, and rest transforms remain unchanged;
four small breast deformation bones and two front-abdomen bones were appended
with localized skin weights. The upper/lower breast response, lateral spread,
and upper/lower abdomen rise have independent amplitudes and lags on the
servo. These are subtle visual secondary controls, not a full soft-body or
anatomical simulation. The servo clamps every downward receiver-bone translation
against the configured world floor plane and clearance. Because this lying CPR
pose starts with the rib cage almost at floor height, the rib-cage bones move
only through their remaining measured clearance; the rest of the visible press
is carried by localized breast controls instead of translating the whole chest
through the floor. Tune `Floor Plane World Y`, `Receiver Floor Clearance`, and
`Receiver Floor Constraint Enabled` on `CPRServoController` if the room floor
changes. The original GLB is untouched; regenerate the variant
with `tools/blender/build_cpr_deform_female.py` and import it through
`tools/scene_builders/import_cpr_female_root.gd`, which preserves the existing
`Female190/IK_character/Skeleton3D` scene and animation paths. The editable
Blender source is `assets/models/female_1791377232602/source/female_1791377232602_cpr_deform.blend`.

OTS Render's fixed-step capture advances the active CPR servo at video FPS,
so a nine-second proxy can be recorded without realtime frame-rate drift.
The servo stops after nine seconds; no ventilation motion is generated. To
return to walking, use the root's normal transport controls, which disable
the CPR hand IK before the walk animation resumes.

### Emacs transport

With `tools/emacs/godot-camera-control.el` loaded, run
`M-x godot-ikea-cpr-servo-play` (or call
`(godot-ikea-cpr-servo-play)`). The default target is
`IkeaSampleRoomFemaleCompare`; customize
`godot-camera-cpr-servo-node` if the scene is instanced below another root.
Related commands are `godot-ikea-cpr-servo-pause`,
`godot-ikea-cpr-servo-restart`, and `godot-ikea-cpr-servo-status`.
`godot-ikea-cpr-servo-calibrate-hands` restores/calibrates the baked source
pose, while `godot-ikea-cpr-servo-capture-male-hand-pose` captures the current
Quick FK pose without resetting it. Finally,
`godot-ikea-cpr-servo-capture-hand-markers` stores any final marker edits.

The camera starts just inside the 0.90 m grid-glazed door. `OrbitPivot` is a
stable pivot for OTS Render camera orbit shots. The scene contains no shared
carry/IK state between the two women, so additional characters can be added by
duplicating the same character/animation/trajectory/controller block and adding
its controller path to the root director.
