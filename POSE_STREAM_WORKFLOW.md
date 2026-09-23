# Emacs-first Godot pose workflow

The pose document is the source of truth. Godot does not need to bake an IK
result into an inherited scene before you can compare poses, and switching a
runtime preview does not modify the `.tscn` file.

The actor documents are:

- `res://poses/female-poses.gdpose` — the 56-bone female plus IK controls;
- `res://poses/male-carrier-poses.gdpose` — the 53-bone male carrier;
- `res://poses/shots/ots-shot-01.gdshot` — a shot selecting one pose per actor.

Each `.gdpose` owns one character path, rig, active pose, and named pose
library. The `.gdshot` stores references only, keeping character poses reusable.

## Load the Emacs mode

Add this to your Emacs configuration:

```elisp
(add-to-list
 'load-path
 "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/tools/emacs")
(require 'godot-pose-mode)
```

Open either actor `.gdpose` file to activate `godot-pose-mode`, or open the
`.gdshot` file to activate `godot-shot-mode`.

To test without changing your Emacs configuration:

```bash
cd '/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6'

emacs -Q \
  -L tools/emacs \
  -l godot-pose-mode.el \
  poses/shots/ots-shot-01.gdshot
```

## Main keys

| Key | Command | Effect |
| --- | --- | --- |
| `C-c C-r` | `godot-pose-run-preview` | Start the optional Godot game preview. |
| `C-c C-a` | `godot-pose-select-active` | Choose a named pose in the minibuffer. |
| `C-c C-e` | `godot-pose-send-active` | Evaluate in the currently edited Godot scene. |
| `C-u C-c C-e` | same | Choose a pose, then send it. |
| `C-c C-d` | `godot-pose-dump-editor-pose` | Dump the current editor pose into this buffer. |
| `C-c C-x` | `godot-pose-delete-profile` | Choose and delete a pose profile from this buffer. |
| `C-c C-t` | `godot-pose-send-active-to-runtime` | Send to the optional game runtime. |
| `C-c C-s` | `godot-pose-save-to-project` | Save under the Godot project for Git tracking. |
| `C-c C-v` | `godot-pose-validate` | Validate the document without sending. |
| `C-c C-k` | `godot-pose-disconnect` | Close the current buffer's stream connection. |

Keep the Godot editor open with `my_manual_rig_pose.tscn` as its edited scene.
Change `active_pose` directly or use `C-c C-a`, then press `C-c C-e`. The
editor viewport changes without running the game and Godot replies with
`pose.applied` in the Emacs minibuffer.

`C-c C-r` and `C-c C-t` are the separate game-preview path. They are not
required for editor evaluation.

## Place the character and start the collapse from Emacs

Load `godot-camera-control.el` alongside the camera controls:

```elisp
(add-to-list
 'load-path
 "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/tools/emacs")
(require 'godot-camera-control)
```

`M-x godot-character-set-initial-position` sends one `pose.apply` reset with
the character's scene-parent position and rotation. For a setup copied from
the OTS Render gizmo, use one XYZ position vector and the displayed quaternion
in XYZW order:

```elisp
(godot-character-set-initial-position
 :position '(-0.60 0.055 3.25)
 :quaternion '(0.0 0.7071068 0.0 0.7071068))
```

The quaternion is the canonical form: paste the four values exactly as shown
by OTS Render. The older `:x`, `:y`, `:z`, and `:rotation-degrees` keywords
remain available for hand-authored Euler shots:

```elisp
(godot-character-set-initial-position
 :x -0.60 :y 0.055 :z 3.25
 :rotation-degrees '(0.0 180.0 0.0))
```

`M-x godot-character-start-collapse` first selects `external_pose`, resets the
character to the requested initial transform, and launches the configured
`video_to_pose_stream.py` process with the collapse cache. With a prefix
argument, the interactive command asks for an XYZ position and optional XYZW
quaternion; without one it uses `godot-collapse-cache` and the default scene
position:

```elisp
(godot-character-start-collapse
 :cache "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/renders/mocap/girl_collapse_lean_wall_6s_final/motion_pose_frames_vertical.json"
 :position '(-0.60 0.055 3.25)
 :quaternion '(0.0 1.0 0.0 0.0))
```

`godot-character-start-collapse` accepts the same `:position` and
`:quaternion` keywords. A quaternion takes precedence over
`:rotation-degrees`, so the transform can be copied from the dragged
`IK_character` gizmo without converting angles manually.

Use `M-x godot-character-stop-collapse` to stop the Emacs-launched stream.
The initial transform is applied only once; the cache's `root_motion.positions`
then supplies the subsequent pelvic/vertical movement relative to that start.

## Multi-actor shot documents

A shot selects named poses from separate actor documents:

```json
{
  "schema": "godot-shot-document",
  "version": 1,
  "actors": {
    "female": {
      "document": "../female-poses.gdpose",
      "pose": "ots_female_20260917_093318"
    },
    "male_carrier": {
      "document": "../male-carrier-poses.gdpose",
      "pose": "rest_standing"
    }
  }
}
```

From a `.gdshot` buffer:

- `C-c C-e` validates both documents and applies both poses to the editor;
- `C-c C-t` applies both poses to the runtime;
- `C-c C-v` verifies every document path and selected pose;
- `C-c C-r` starts the shared preview scene.

Edit or capture poses from the individual `.gdpose` buffers. The shot is for
blocking and synchronized preview, not a second copy of bone transforms.

The normal `C-x C-s` still behaves normally. `C-c C-s` adds one useful rule:
if the buffer is outside the project, it offers the project's `poses/`
directory as the save destination.

## Dump the current editor pose first

With `my_manual_rig_pose.tscn` open in Godot, press `C-c C-d` in the `.gdpose`
buffer. Enter a new pose name such as `my_manual_start`.

Godot sends back:

- all 56 local bone positions, quaternion rotations, and scales;
- all 12 IK control transforms;
- every SkeletonModifier3D active/inactive state;
- the character root transform and capture metadata.

Emacs appends the result to the `poses` object, changes `active_pose` to the new
name, and leaves the buffer modified. Nothing is baked and the `.tscn` is not
saved. Press `C-c C-s` to save the `.gdpose` revision, then `C-c C-e` to verify
that the captured pose reproduces correctly.

Capture names must be new. This avoids silently overwriting an earlier pose in
Git history.

## Delete a pose profile

Press `C-c C-x`, choose a profile using the same minibuffer completion used by
`C-c C-a`, and confirm. The command removes only that profile's JSON block. It
does not contact Godot and does not save immediately.

Use `C-/` to undo, or `C-c C-s` to commit the deletion to disk. The command
refuses to delete the last remaining profile. If the deleted profile was
active, the first remaining profile becomes active automatically.

## Pose document model

Each named pose is deterministic by default:

```json
"example": {
  "mode": "hybrid",
  "reset_to_rest": true,
  "euler_order": "YXZ",
  "modifiers": {
    "center_back_ik": true,
    "r_arm": true
  },
  "ik": {
    "center_back_target": {
      "position": [-0.04, 1.26, 0.38]
    }
  },
  "bones": {
    "Chest": {
      "rotation_degrees": [12.0, 3.0, -4.0],
      "weight": 1.0
    }
  }
}
```

Modes:

- `fk`: disable all skeleton modifiers and apply local bone transforms.
- `ik`: reset the skeleton, move IK controls, and enable named modifiers.
- `hybrid`: apply a local FK base first, then evaluate the named IK modifiers.

An `ik` or `hybrid` profile remains modifier-driven after it is sent to the
editor. Therefore direct `Skeleton3D` bone gizmos are expected to be
overwritten by the active solvers. Select `IK_character` and use **Freeze
evaluated pose for FK gizmos** to keep the displayed SAM3D result while
temporarily disabling those solvers for precise bone edits. Re-sending the
profile from Emacs restores its original IK behavior; the `.gdpose` file is
never changed by the freeze operation.

Bone transforms support `position`, `scale`, `rotation_degrees`, or the more
precise `rotation_quaternion` in `[x, y, z, w]` order. The optional `weight`
blends an individual bone from its current/rest value.

Godot 4 bone pose rotations are **absolute local rotations**, not deltas from
identity or `inverse(rest) * desired`. A producer that sends all bones must send
the imported rest quaternion for every unobserved bone. Sending identity for a
bone whose GLB rest rotation is non-identity destroys its bone-roll basis and
causes twisted arms, hands, legs, feet, and fingers.

## Runtime stream protocol

The Godot editor listens only on `127.0.0.1:7007`. The optional game runtime
listens on `127.0.0.1:7008`, so editor and game can be open simultaneously.
The transport is persistent TCP containing one UTF-8 JSON object per line
(NDJSON). This is deliberately independent of Emacs.

The editor listener belongs to the **Quick FK Bone Controls** plugin. Its
startup line in Godot's Output is:

```text
POSE_STREAM listening on 127.0.0.1:7007 protocol=godot-pose-stream/1
```

If that line is absent after upgrading the plugin, open **Project → Project
Settings → Plugins**, disable and re-enable **Quick FK Bone Controls** once.
This reloads the editor endpoint without closing or saving the edited scene.

Interactive pose evaluation uses `pose.apply`. The inverse `pose.capture`
request returns a `pose.captured` message containing the complete editable pose.
An apply message looks like:

```json
{
  "protocol": "godot-pose-stream",
  "version": 1,
  "type": "pose.apply",
  "request_id": "client-defined-id",
  "character": {
    "node_path": "IK_character",
    "skeleton_path": "Skeleton3D",
    "controls_path": "../PoseControls"
  },
  "pose_name": "example",
  "pose": {
    "mode": "fk",
    "reset_to_rest": true,
    "bones": {
      "Chest": {
        "rotation_quaternion": [0.0, 0.0, 0.0, 1.0]
      }
    }
  }
}
```

Godot answers `pose.applied` with counts and missing bone/control/modifier
names, making retargeting mistakes visible to clients.

## Motion capture and ComfyUI

A realtime producer sends the same envelope with `type: "pose.frame"`, plus
`seq`, a producer timestamp, and optionally `ack: true`:

```json
{
  "protocol": "godot-pose-stream",
  "version": 1,
  "type": "pose.frame",
  "seq": 1842,
  "source": {
    "application": "comfyui",
    "camera": "input-0"
  },
  "character": {
    "node_path": "IK_character",
    "skeleton_path": "Skeleton3D",
    "controls_path": "../PoseControls"
  },
  "pose_name": "mocap-live",
  "pose": {
    "mode": "fk",
    "reset_to_rest": false,
    "bones": {
      "Hips": {
        "rotation_quaternion": [0.02, -0.01, 0.04, 0.9989]
      }
    }
  }
}
```

The Godot receiver coalesces `pose.frame` traffic per character every engine
frame. If a producer sends faster than Godot renders, stale intermediate frames
are dropped and the newest pose wins. This keeps latency bounded. Routine
streaming frames do not generate acknowledgements unless `ack` is true.

The localhost binding is intentional. Do not expose the raw pose port to a
network; use an authenticated relay if remote capture is added later.

## Camera capture motion ownership

Camera recording is no longer coupled to the female walk evaluator. The
`FemaleWalkController` exposes a motion-source API:

- `walk_cycle` (default) seeks the authored gait and follows the trajectory;
- `stationary` advances the capture clock but preserves the current character
  transform and pose;
- `external_pose` leaves pose and root ownership to `pose.apply` / `pose.frame`,
  which is suitable for retargeted bone motion.

From Emacs, use a self-contained stationary take:

```elisp
(godot-walk-record-camera-motion
 :motion-source 'stationary
 :auto-clip-to-camera-program t
 :program-end-padding 0.0
 :fps 24
 :resolution '(1280 720)
 :start-delay 0.1
 :viewport 1)
```

For a retargeted stream, select `external-pose` before or as part of the
recording request. The transport endpoints are `walk.motion_source.set` and
`walk.motion_source.status`; status responses include the normalized source
name under `motion_source`.

## Video motion fitting: NLF + SAM 3D Body

`tools/video_to_pose_stream.py` is the external motion-capture path. It does
not create an `Animation`, modify a `.tscn`, or bake IK. Instead it:

1. samples NLF SMPL-24 geometry densely (15 FPS by default);
2. samples SAM 3D Body MHR-127 orientations sparsely on CPU;
3. uses SAM twist only on the axial torso chain, while arms, hands, legs, and
   feet use NLF minimal-swing fitting in the target rig's own bone-roll basis;
4. applies quaternion sign continuity, robust temporal smoothing, and simple
   left/right foot-contact damping;
5. infers parent-node root displacement from the pelvis and stabilizes it with
   planted-foot constraints, without removing the Hips bone's captured wobble;
6. optionally maps gait-distance progress onto a linear or cubic Bézier waypoint path;
7. retargets against the actual rest hierarchy in the female proxy GLB; and
8. streams 56 local `[x, y, z, w]` quaternions plus optional parent-space root
   motion as `pose.frame` at 30 FPS.

On Apple Silicon, use the project's SAM environment. The tool bypasses NLF's
public float64 wrapper (unsupported by MPS) but uses the same official scripted
crop network. SAM 3D Body remains on CPU because its MHR TorchScript forward
also requires float64.

Fit the first four seconds and send them to the open Godot editor:

```bash
cd '/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6'

/Users/hotcat/miniconda3/envs/sam_3d_body/bin/python \
  tools/video_to_pose_stream.py \
  '/Users/hotcat/zhouyu/windowSize/girl_dance_sequence_transfer3/003.mp4' \
  --duration 4 \
  --bbox 0 45 511 895
```

Inference writes two reproducible sidecars under
`renders/mocap/girl_dance_003_first4s/`:

- `nlf_sam3d_observations.json` contains sampled model observations;
- `motion_pose_frames.json` contains the solved 120 × 56 quaternion frames.

Replay the result instantly without loading either model:

```bash
/Users/hotcat/miniconda3/envs/sam_3d_body/bin/python \
  tools/video_to_pose_stream.py \
  --stream-cache renders/mocap/girl_dance_003_first4s/motion_pose_frames.json
```

Add `--loop` for continuous editor preview. Add `--no-stream` to fit/cache only,
or `--reuse-observations` after changing temporal/retargeting code so the
expensive observations are not recomputed. The default editor port is 7007;
use `--port 7008` only for the running game receiver.

### Root motion and LinuxCNC-style trajectories

Root motion is separate from the 56-bone FK stream. `--root-motion
foot-contact` uses pelvis displacement for gait timing and foot contacts to
reduce drift. `--root-motion pelvis` disables contact correction, while
`--root-motion off` retains the old stationary-character preview. The receiver
applies this displacement to `IK_character` relative to its starting transform,
so local pelvis wobble remains present in the `Hips` quaternion.

The current walk experiment uses straight-line waypoints:

```json
{
  "type": "linear",
  "distance_mode": "gait",
  "pace_scale": 1.0,
  "contact_correction": 1.0,
  "local_forward": [0, 0, -1],
  "waypoints": [
    {"position": [0, 0, 0], "out_handle": [0, 0, 1.2]},
    {"position": [1.5, 0, 2.8], "in_handle": [-0.8, 0, -0.9], "out_handle": [0.8, 0, 0.9]},
    {"position": [3, 0, 1], "in_handle": [-0.8, 0, 0.3]}
  ]
}
```

Run a walk along that programmed path:

```bash
/Users/hotcat/miniconda3/envs/sam_3d_body/bin/python \
  tools/video_to_pose_stream.py /absolute/path/walk.mp4 \
  --duration 10 --root-motion foot-contact --foot-lock-strength 0.85 \
  --trajectory trajectories/female_walk_bezier.json \
  --trajectory-heading tangent --output-dir renders/mocap/walk_bezier
```

The planner maps captured gait progress onto path arc length. `type: "linear"`
connects waypoints with true straight segments and ignores Bézier handles. Use
`type: "bezier"` only when a curved path is explicitly needed. Use
`distance_mode: "gait"` to preserve captured stride distance and cadence; a
longer curve is then only partly traversed. Use `distance_mode: "fit"` for a
planned shot in which this clip must reach the last waypoint. The target rig's
actual foot origins supply a second contact solve after FK retargeting. Its
accumulated correction persists when support changes between feet, which is
important when a tracking camera under-reports pelvis travel. In `fit` mode,
remaining endpoint distance is distributed primarily through swing frames to
limit planted-foot sliding. `contact_correction: 1.0` enables the full lock.
`pace_scale` is a feed override for `gait` mode and should normally remain
`1.0`.

The waypoint program controls where the character walks. With
`--trajectory-heading tangent`, each frame carries an explicit parent-space
tangent direction. Godot aligns the configured `local_forward` axis, normally
the character's local `-Z`, to it while preserving the Node3D's authored pitch
and roll; the initial scene yaw cannot leave the character walking sideways.

For walking clips, `upright_root: true` discards pitch and roll inherited from
an earlier posed scene and retains only trajectory yaw. `ground_lock: true`
evaluates the retargeted proxy's Foot and Toes origins after FK filtering and
adds vertical root motion so its lowest support sole stays at `ground_y`.
`skeleton_origin_y` accounts for the Skeleton3D child transform inside the
character scene. Torso and head safeguards are independently configurable with
`max_torso_tilt_degrees` and `max_head_up_degrees`; neither changes the fitted
upper-leg global rotations.

Vertical grounding is essential for convincing contact, but it does not by
itself remove horizontal slide. Set `foot_ik: true` to run the target rig's
two-bone leg solve after root planning. Each contact interval anchors the ankle
in world XZ, adjusts UpperLeg and LowerLeg while retaining the fitted knee bend
plane, then preserves the Foot's fitted global orientation. Ground lock is
evaluated again from the corrected Foot and Toes transforms. This removes both
tangent and lateral support-foot drift without moving the root away from the
authored straight line.

`speed_profile: "constant"` gives equal horizontal root distance to every
frame. This is useful for shot planning because camera-relative pelvis noise no
longer becomes acceleration. Use `"captured"` when the original clip's speed
changes are intentional. For a traversing clip, native playback is deliberately
one-shot: looping would teleport the root from the last waypoint to the first.

#### Extract and bake a reusable walk cycle

Do not bake the full traversing clip's horizontal root track: it would teleport
from the path end back to its start. Horizontal movement stays in the scene
controller. The short experimental cycle uses frames 125 and 160, the closest
matching leg phases in the clean original interval (`4.17s..5.33s`). Contact is
inferred from target-avatar foot height and backward stance velocity to measure
travel speed, but the default `--ik-strength 0` deliberately preserves every
captured leg quaternion. A second leg IK pass looks mathematically planted but
distorts knee motion and creates a visible loop seam:

```bash
/Users/hotcat/miniconda3/envs/sam_3d_body/bin/python3.11 \
  tools/extract_motion_cycle.py \
  renders/mocap/6aaba7_walk_raw/motion_pose_frames.json \
  renders/mocap/6aaba7_walk_bezier/female_walk_leg_wounded.json \
  --start-frame 125 --end-frame 160 \
  --animation-name female_walk_leg_wounded \
  --fit-planted-feet \
  --skeleton-origin-y 0.0944922 \
  --ground-clearance 0.045
```

Convert that cycle to a native Godot `AnimationLibrary`; TCP is not involved
during playback:

```bash
'/Applications/Godot.app/Contents/MacOS/Godot' \
  --headless --path . \
  --script res://tools/bake_motion_cache.gd -- \
  res://renders/mocap/6aaba7_walk_bezier/female_walk_cycle.json \
  res://animations/female_walk_cycle.tres
```

That short sample remains useful as the `Leg Wounded` style, but it is not
labelled normal. `Normal Human` instead retains the complete 314-frame,
`10.467s` performance from `6aaba7_walk_raw`, before trajectory leg IK changed
the pelvis/upper-leg relationship:

```bash
/Users/hotcat/miniconda3/envs/sam_3d_body/bin/python3.11 \
  tools/extract_motion_cycle.py \
  renders/mocap/6aaba7_walk_raw/motion_pose_frames.json \
  renders/mocap/6aaba7_walk_bezier/female_walk_cycle.json \
  --start-frame 0 --end-frame 314 --seam-blend-frames 30 \
  --animation-name female_walk_cycle \
  --fit-planted-feet \
  --skeleton-origin-y 0.0944922 \
  --ground-clearance 0.045
```

The one-second seam window is necessary because the first and last observed
poses are different gait phases. It changes only the two ends toward a shared
pose; all 314 source frames remain in the cycle, and the middle 8.47 seconds are
untouched. The support-foot pass measures speed and vertical clearance only;
it does not rewrite either leg.

The former post-IK result is intentionally preserved as a second character
performance rather than discarded:

```bash
/Users/hotcat/miniconda3/envs/sam_3d_body/bin/python3.11 \
  tools/extract_motion_cycle.py \
  renders/mocap/6aaba7_walk_bezier/motion_pose_frames.json \
  renders/mocap/6aaba7_walk_bezier/female_walk_wounded_terminator.json \
  --start-frame 125 --end-frame 160 \
  --animation-name female_walk_wounded_terminator \
  --fit-planted-feet \
  --skeleton-origin-y 0.0944922 \
  --ground-clearance 0.045
```

The baker writes 56 absolute-local bone
rotation tracks and one Skeleton3D vertical-grounding track. Horizontal root
travel is intentionally excluded from the loop. `walk_cycle_controller.gd`
moves the character along `FemaleWalkTrajectory`, while
`FemaleWalkAnimationPlayer` samples the chosen style. In the Inspector choose
`Normal Human` (`10.467s`, measured `0.751099 m/s`), `Leg Wounded` (`1.167s`,
measured `0.978234 m/s`), or `Wounded Terminator` (`1.167s`, measured
`0.990985 m/s`). **Apply selected gait natural speed** is explicit so style
switching never overwrites the director's tuned speed or height offset. This
separation preserves pelvis wobble without root wrap, speed bursts, or
dependence on the Python process.

The scene editor is the primary transport. Select `FemaleWalkController` and
use **Play walk preview**, **Pause walk preview**, or **Restart walk preview**.
Change `preview_time_seconds` to scrub the gait and scene position together.
`preview_in_editor` shows whether editor playback is active. After moving a
waypoint, press **Refresh trajectory markers**. `character_height_offset_m`
raises or lowers the complete character without modifying the captured gait;
use it to reconcile the trajectory marker plane with the visible floor surface.
The **Gait Shaping → Thigh Closure Degrees** control narrows the airborne leg
toward the body's center plane (`4°` by default). Contact frames always receive
zero correction, so both planted-foot anchors and the captured stance geometry
remain unchanged; set it to `0°` to recover the unmodified captured gait.
The adjacent **Heel Contact Lead Frames** control compensates for a source
performer wearing raised heels. Positive values advance the proxy's sampled
heel-strike phase by that many capture frames; the periodic root/contact pace is
advanced by the same amount and re-zeroed at restart, so the character does not
jump forward at time zero. Start with `2–4` frames for a high-heel source, then
compare the first visible sole contact in the editor. Use `0` for a barefoot or
flat-shoe source.
**Record editor camera motion** starts (or stops) the OTS Render plugin's video
capture directly from the same Editor Transport group, without pausing the
walk. `editor_preview_fps` defaults to 30 FPS so high-refresh displays do not
force redundant AnimationPlayer seeks and complete 56-bone skinning at 60 or
120 FPS; runtime playback is unaffected. The cyan `CurvePreview` trajectory
line is an editor-only authoring aid and is automatically hidden from the
off-screen beauty and camera-motion video captures.

Video capture uses a fixed-step evaluator clock. When the avatar is expensive
to skin, the recorder pauses the editor walk controller and advances it by
exactly one `1 / FPS` step only after the corresponding off-screen frame has
finished rendering. The same rule applies to a playing camera program. This
prevents GPU latency from advancing the live scene several seconds while only
one image is being written, which previously made the encoded MP4 appear to
play in fast-forward. The output `camera_motion.json` records
`timing.mode = fixed_step_after_render`.

Transport commands that arrive during the preparation/start-delay window are
also captured by that fixed clock. In particular, a late `walk.restart` no
longer re-enables the controller's normal `_process(delta)` clock, and a camera
program loaded with `:play t` after the record request is adopted by the same
fixed-step recorder. Each `camera_samples` entry now records
`walk_time_seconds`, `camera_program_time_seconds`, and the character's global
position, making camera/actor synchronization directly auditable.

The fixed-step lock begins as soon as the record request is accepted, not
after scene duplication. This makes the common Emacs sequence “request record,
restart walk, confirm follow, load/play camera program” deterministic. After
each fixed step, the editor camera's global transform is also updated
immediately from the newly sampled character transform and camera-relative
program transform, avoiding a one-output-frame camera lag.

For a tracking shot, first orbit/pan/zoom the 3D editor camera until the female
has the intended framing, then press **Editor Camera Tracking → Confirm current
camera follow**. The plugin stores the complete camera transform relative to
`IK_character`, so distance, height, pitch, yaw, and composition remain fixed
as the walk controller translates or turns her. **Stop camera follow** releases
the lock while leaving the camera at its current transform. Camera-motion
recording samples this tracked editor camera directly.

#### Program the tracked editor camera from Emacs

`tools/emacs/godot-camera-control.el` exposes the same follow mechanism plus a
LinuxCNC-style motion program over the existing editor TCP port. It is a normal
Emacs Lisp library, independent of `.gdpose` buffers:

```elisp
(add-to-list
 'load-path
 "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/tools/emacs")
(require 'godot-camera-control)
```

The complete working example is
`tools/emacs/examples/female-walk-camera-program.el`. Open it, use `M-x
eval-buffer` (or `C-M-x` after its function), frame the female in Godot, and run
`M-x ots-female-walk-camera-shot`. Editing and evaluating the function again
immediately replaces the loaded program.

The moving coordinate has two layers:

1. `godot-camera-confirm-follow` captures the current editor camera as work
   zero relative to `IK_character`. Character translation and heading are
   inherited on every editor frame.
2. G-code-like commands add motion to that work zero in the character's local
   axes: `X` is right, `Y` is up, and `Z` is back, so negative `Z` moves toward
   the character's front. G1/G5 destinations and G5 controls are absolute
   offsets from the confirmed work zero.

The principal functions are:

| Emacs Lisp function | Camera action |
| --- | --- |
| `godot-camera-confirm-follow` | Capture the current framing as work zero. `:viewport` is 1-based. |
| `godot-camera-program-begin` | Clear the builder and set name, target, viewport, and looping. |
| `godot-camera-set-initial-view` | Store an exact character-relative setup pose. Prefer `:position` plus quaternion XYZW. |
| `godot-camera-restore-initial-view` | Restore the stored setup pose immediately in Godot. |
| `godot-camera-g0` | Jump instantly to an absolute work offset. |
| `godot-camera-g1` | Linear dolly/truck/pedestal move using `:duration` or `:feed-mps`. |
| `godot-camera-g5` | Cubic Bezier move with two absolute character-local controls. |
| `godot-camera-g2-orbit` / `godot-camera-g3-orbit` | Clockwise/counter-clockwise orbit about a character-local pivot. |
| `godot-camera-g4` | Dwell while continuing to inherit the character's movement. |
| `godot-camera-send-program` | Load the builder and optionally play it immediately. |
| `godot-camera-play`, `godot-camera-pause`, `godot-camera-reset` | Control the loaded timeline. |
| `godot-camera-clear-remote-program` | Remove offsets but retain fixed character follow. |
| `godot-camera-release-follow` | Release the moving coordinate and leave the editor camera where it is. |
| `godot-camera-status` | Ask Godot for the current follow/program state. |

Example body:

```elisp
(godot-camera-confirm-follow :target-node "IK_character" :viewport 1)
(godot-camera-program-begin :name "walk-shot-01" :loop nil)
(godot-camera-set-initial-view
 :position '(3.9850 1.3960 -2.8390)
 :quaternion '(0.015482 0.904271 -0.012063 0.426473))
(godot-camera-g4 :seconds 0.5)
(godot-camera-g1 :x 0.30 :y 0.08 :z -0.20
                 :duration 2.0 :easing 'smooth)
(godot-camera-g5 :x 0.60 :y 0.15 :z -0.40
                 :control1 '(0.35 0.08 -0.22)
                 :control2 '(0.55 0.14 -0.35)
                 :duration 2.0 :easing 'smoother)
(godot-camera-g2-orbit :degrees 25 :pivot '(0 1.2 0)
                       :duration 2.5 :easing 'smooth)
(godot-camera-send-program :play t)
```

`initial_view` is a reproducible camera setup block, analogous to a CNC work
offset/setup block. It is measured relative to the selected character, so the
same source file restores the shot even when the editor camera was left at a
different position. The quaternion `(x y z w)` is the canonical orientation;
it avoids the gimbal-lock and non-unique-angle problems of storing Euler
pitch/roll/yaw. The panel still displays Euler degrees for human inspection,
and accepts them as a legacy fallback when hand-authoring a message.

The OTS recorder samples the resulting editor camera directly. Start the walk,
start the camera program, and press **Record editor camera motion**; no manual
viewport navigation is required during the take. When the program reaches its
end, fixed follow remains active at the final programmed offset so the last
composition does not snap back.

#### Calibrate numeric camera commands visually

The OTS Render dock now includes **Camera Work Coordinates**. It continuously
prints the active editor viewport's camera transform in `IK_character` local
space, including the current local X/Y/Z position and the G1 target offset from
work zero. Frame the starting composition and press **Set work zero**. This
records the framing without enabling follow, so the editor camera remains free
to orbit, pan, and zoom. Navigate to the desired endpoint, then press **Copy
current G1 target** to place a ready-to-
evaluate form such as:

```elisp
(godot-camera-g1 :x 0.2841 :y 0.0710 :z -0.1935)
```

The panel is intentionally live before work zero is set. In that state the
local camera coordinates are valid for inspection, but the G1 offset is not
yet authoritative. **Confirm current camera follow** also establishes the same
work zero, but locks the view for playback; **Set work zero** is the convenient
unlocked calibration path.

After framing a shot, **Copy initial view API** copies a complete
`godot-camera-set-initial-view` form containing the measured position and
quaternion. **Restore initial view** applies the last captured setup without
starting a program. When a program includes `initial_view`, Godot applies it
before enabling follow and sampling G-code, so playback does not depend on the
camera's current transient editor location.

For orbit authoring, press **Create / select pivot**. Godot adds a saved
`CameraOrbitReference` `Marker3D` under `IK_character` and selects it, exposing a
normal 3D translation gizmo. Drag the marker to the desired character-local
orbit pivot. The panel then derives the signed yaw, pitch, radius delta,
height delta, and pivot X/Y/Z from the marker-to-character and
marker-to-camera relationships. **Copy G2** writes an executable
`godot-camera-g2-orbit` or `godot-camera-g3-orbit` form to the system clipboard.
The marker is an authoring aid only; it has no mesh and does not appear in OTS
beauty, mask, depth, or video captures.

#### Direct the female walk transport from Emacs

The five `FemaleWalkController → Editor Transport` buttons are also explicit
commands in `godot-camera-control.el`. They use the same persistent localhost
connection as camera G-code and call the controller API directly; no Inspector
click is synthesized:

| Emacs command | Inspector-equivalent action |
| --- | --- |
| `godot-female-walk-play` | Play walk preview |
| `godot-female-walk-pause` | Pause walk preview |
| `godot-female-walk-restart` | Restart walk preview |
| `godot-female-walk-refresh-trajectory` | Refresh trajectory markers |
| `godot-female-walk-record-camera-motion` | Start/stop recording; accepts manual or camera-program duration, FPS, resolution, delay, frame retention, and viewport options |

For a scripted H3 guide take, the recording command can carry its video
parameters directly instead of depending on the dock's last values:

```elisp
(godot-female-walk-record-camera-motion
 :duration 8.0
 :fps 24
 :resolution '(1280 720)
 :start-delay 1.5
 :keep-frames t
 :viewport 1)
```

Calling it again while a take is active stops that take; supplied options are
used only when starting a new recording.

To end the MP4 on the camera program's final authored frame, load the program
first with `:play nil`, then use either of these equivalent forms:

```elisp
(godot-walk-record-camera-motion
 :duration 'camera-program
 :fps 24
 :resolution '(1280 720))

;; Explicit spelling, with an optional quarter-second final hold:
(godot-walk-record-camera-motion
 :auto-clip-to-camera-program t
 :program-end-padding 0.25
 :fps 24)
```

Zero padding ends exactly at the camera program duration. Positive padding
holds the final camera coordinate; negative padding clips before the program's
end. In the dock, the same controls are **Auto-clip to camera program** and
**Program end padding**. Metadata records `duration_source`,
`camera_program_duration_seconds`, and `program_end_padding_seconds`.

The shorter aliases `godot-walk-play`, `godot-walk-pause`,
`godot-walk-restart`, `godot-walk-refresh-trajectory`, and
`godot-walk-record-camera-motion` are convenient inside shot functions. A
sixth read-only helper, `godot-walk-status`, requests the observed play state,
preview time, trajectory point count/length, and camera-recording status.

For example, a complete repeatable take can coordinate walking and the camera
from one evaluated Emacs function:

```elisp
(defun ots-walking-take-01 ()
  (interactive)
  (godot-walk-restart)
  (godot-camera-send-program :play t)
  (godot-walk-record-camera-motion))
```

Godot acknowledges every operation with the controller's actual state rather
than merely reporting that a GUI event was sent. The default controller path is
`FemaleWalkController`; customize `godot-camera-walk-controller` if a later
scene uses a different node name.

`Travel Mode` separates bone playback from parent-node translation:

- `Foot Contact Sync` is the default. It evaluates the final target rig's left
  and right foot positions, creates a world-space anchor when either foot
  plants, and solves the complete horizontal XZ root offset from every
  continuing stance. During double support it uses both anchors; a newly
  planted foot inherits the accumulated offset instead of resetting travel to
  that side. The solved motion is decomposed into forward progress plus lateral
  root sway, and its measured local travel axis is aligned to the scene path.
  Both feet therefore constrain movement even when the capture travels a few
  degrees away from the proxy's nominal local `-Z`. This profile is always
  applied at `1.0×`, because scaling root movement independently would recreate
  foot sliding.
- `Captured Root Pace` is retained as a diagnostic mode. It projects
  the observed horizontal root displacement onto its travel direction, removes
  lateral pelvis sway, and smooths tracking plateaus over 15 frames. The long
  cycle advances `1.872377m` per `10.467s`; `Captured Pace Scale` is a feed
  override for this legacy mode only.
- `Constant Speed` retains the director-authored `Walk Speed` transport. Use
  **Apply selected constant gait speed** to load the measured support-foot
  estimate for the chosen gait.
- `In Place` keeps the character on the first waypoint while playing every
  captured bone frame. This intentionally reproduces the natural motion seen
  when the earlier controller reached the path endpoint.

The current stage floor top is `Y=0.13909m`, while the baked sole clearance is
`0.045m`, so this scene uses `+0.09409m`. The same controller also runs
at game runtime, but no compiled game is required for directing the shot:

```bash
'/Applications/Godot.app/Contents/MacOS/Godot' \
  --path . --scene res://demos/my_manual_rig_pose.tscn
```

#### Author the path with scene markers

The enabled **Walk Trajectory** editor dock removes the need to calculate JSON
coordinates manually:

1. Open `my_manual_rig_pose.tscn` and click **Load** in the Walk Trajectory
   dock. This creates `FemaleWalkTrajectory` at the female character's current
   starting position.
2. Use the `W` buttons to select a waypoint. Press
   `F` over the 3D viewport to frame it, then use the normal move gizmo.
3. Add or remove waypoints as needed. The cyan preview joins them with straight
   segments; no curve handles affect this mode.
4. Click **Export JSON**. The dock writes the marker values to
   `res://trajectories/female_walk_bezier.json` and shows the selected values.

The export also records `scene_origin_node` as
`FemaleWalkTrajectory/Waypoint_00`. Each playback therefore starts exactly on
the visible first marker instead of accumulating an offset from the character's
previous endpoint.

Gait progress uses displacement along the inferred horizontal travel axis. It
excludes vertical pelvis bob and lateral hip sway while retaining the small
backward root corrections produced by planted-foot locking. Accumulating every
pelvis variation as forward path distance would move the character several
times faster than her captured stride.

For the current `linear` path, keep consecutive waypoint segments collinear if
you want one uninterrupted heading. A corner is an intentional instantaneous
heading change, so add a Bézier path later if the character must turn smoothly.
The existing `female_walk_bezier.json` filename is retained for command and
Emacs compatibility even though its `type` now selects linear interpolation.
