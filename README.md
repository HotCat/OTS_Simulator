# OTS Simulator

OTS Simulator is a Godot 4 humanoid posing sandbox built on
[`lukky-nl/ik-demo-4.6`](https://github.com/lukky-nl/ik-demo-4.6). It extends the
original IK demonstration with torso controls, a replacement 56-bone humanoid,
an over-the-shoulder carry staging scene, runtime orbit-camera controls, and an
Emacs-first pose-authoring workflow.

The pose workflow keeps reusable IK/FK poses in readable `.gdpose` JSON files.
Emacs can capture the evaluated pose from the Godot editor, switch named pose
profiles, and stream changes back to the editor or a running game without
depending on a fragile one-time scene bake.

## Requirements

- Godot 4.7 (the project metadata and imported assets were last generated with
  Godot 4.7)
- Emacs 27 or newer for the optional `godot-pose-mode`
- macOS commands below assume Godot is installed at `/Applications/Godot.app`

## Open and run

Open the project manager/editor:

```sh
cd '/path/to/OTS_Simulator'
'/Applications/Godot.app/Contents/MacOS/Godot' --editor --path .
```

Run the configured OTS posing scene directly:

```sh
cd '/path/to/OTS_Simulator'
'/Applications/Godot.app/Contents/MacOS/Godot' \
  --path . \
  --scene res://demos/ots_waist_pose_demo.tscn
```

The project starts with `demos/ots_waist_pose_demo.tscn`. The manually posed
character scene is `demos/my_manual_rig_pose.tscn`.

## Emacs pose workflow

Load the major mode once in Emacs:

```elisp
(add-to-list 'load-path "/absolute/path/to/OTS_Simulator/tools/emacs")
(require 'godot-pose-mode)
```

Then open `poses/ots-carry.gdpose`. Important commands are:

| Key | Action |
| --- | --- |
| `C-c C-a` | Select the active named pose profile. |
| `C-c C-e` | Send the active pose to the open Godot editor scene. |
| `C-c C-d` | Capture the editor's currently evaluated pose into the document. |
| `C-c C-x` | Select and delete a pose profile, with confirmation and undo support. |
| `C-c C-t` | Send the active pose to the running game preview. |
| `C-c C-r` | Start the configured Godot preview scene. |
| `C-c C-s` | Save the pose document inside the project for Git tracking. |
| `C-c C-v` | Validate the pose document. |
| `C-c C-k` | Close the pose stream connection. |

The editor receiver listens on `127.0.0.1:7007`; the optional runtime receiver
uses `127.0.0.1:7008`. Keeping the ports separate allows the editor and game
preview to run at the same time. Both listeners bind only to localhost.

## Documentation

- [Getting started](GETTING_STARTED.md) covers scene startup, camera navigation,
  and the primary demo controls.
- [Pose controls guide](POSE_CONTROLS_GUIDE.md) explains targets, markers,
  torso controls, IK/FK behavior, baking, and the Quick FK panel.
- [Pose stream workflow](POSE_STREAM_WORKFLOW.md) documents the `.gdpose` format,
  editor/runtime protocol, capture workflow, Emacs commands, and troubleshooting.

## Project structure

- `addons/quick_fk_bones/` — editor dock for quickly selecting and rotating the
  hips, spine, chest, upper chest, neck, and head bones.
- `scripts/pose_stream_server.gd` — localhost NDJSON receiver used by the editor
  and runtime pose workflow.
- `scripts/ots_pose_controller.gd` — IK/FK controls, torso posing, marker reset,
  and editor capture/apply support.
- `tools/emacs/godot-pose-mode.el` — Emacs major mode for versioned pose profiles.
- `poses/` — reusable, Git-friendly pose documents.
- `demos/` — original examples plus the OTS and manual-pose scenes.

## Attribution and license

This repository derives from the Godot 4.6 IK demo by
[`lukky-nl`](https://github.com/lukky-nl/ik-demo-4.6) and retains its MIT
license. See [LICENSE](LICENSE).
