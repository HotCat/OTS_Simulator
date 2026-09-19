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

## Video motion fitting: NLF + SAM 3D Body

`tools/video_to_pose_stream.py` is the external motion-capture path. It does
not create an `Animation`, modify a `.tscn`, or bake IK. Instead it:

1. samples NLF SMPL-24 geometry densely (15 FPS by default);
2. samples SAM 3D Body MHR-127 orientations sparsely on CPU;
3. uses SAM twist only on the axial torso chain, while arms, hands, legs, and
   feet use NLF minimal-swing fitting in the target rig's own bone-roll basis;
4. applies quaternion sign continuity, robust temporal smoothing, and simple
   left/right foot-contact damping;
5. retargets against the actual rest hierarchy in the female proxy GLB; and
6. streams 56 local `[x, y, z, w]` quaternions as `pose.frame` at 30 FPS.

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
