# Emacs-first Godot pose workflow

The pose document is the source of truth. Godot does not need to bake an IK
result into an inherited scene before you can compare poses, and switching a
runtime preview does not modify the `.tscn` file.

The initial document is:

`res://poses/ots-carry.gdpose`

It includes the complete 56-bone hierarchy, IK control names, modifier names,
and four editable named poses.

## Load the Emacs mode

Add this to your Emacs configuration:

```elisp
(add-to-list
 'load-path
 "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/tools/emacs")
(require 'godot-pose-mode)
```

Then open `poses/ots-carry.gdpose`. The `.gdpose` extension automatically
activates `godot-pose-mode`.

To test without changing your Emacs configuration:

```bash
cd '/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6'

emacs -Q \
  -L tools/emacs \
  -l godot-pose-mode.el \
  poses/ots-carry.gdpose
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

Bone transforms support `position`, `scale`, `rotation_degrees`, or the more
precise `rotation_quaternion` in `[x, y, z, w]` order. The optional `weight`
blends an individual bone from its current/rest value.

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
