# OTS editor-camera render capture

The `OTS Render Capture` editor plugin turns the camera currently used by a
Godot 3D editor viewport into reusable image-generation inputs. It does not
require adding or positioning a `Camera3D` node in the scene.

## Capture a view

1. Open `res://demos/my_manual_rig_pose.tscn`.
2. Use the normal editor orbit, pan, and zoom controls to frame both actors.
3. Open the **OTS Render** dock at the lower right.
4. Choose **Viewport 1** for the normal single-view layout. When the 3D editor
   is split, choose the numbered viewport that contains the desired camera.
5. Choose an output resolution and click **Capture current editor camera**.

If another editor plugin intercepts a dock click, run **Project → Tools →
Capture OTS Render Passes**. Both entry points execute the same capture and the
Godot Output panel immediately prints `OTS_CAPTURE requested` when the request
has been accepted.

Every click creates a timestamped directory under
`res://renders/ots_quickview/`. The entire `renders/` directory is Git-ignored.

## Output passes

- `beauty.png` — the ordinary Godot render, without editor gizmos or selection
  outlines.
- `character_color_reference.png` — the complete shaded 3D scene in one image,
  with the female rendered vivid magenta, the male carrier cyan-blue, and
  non-character geometry neutral gray. Unlike a segmentation mask, this pass
  preserves lighting, body volume, scene context, occlusion, and camera
  perspective. It is the preferred single reference for image generation when
  overlapping limbs make the ordinary beauty render ambiguous.
- `depth_near_white.png` — linear camera-space depth normalized to the actual
  scene geometry; nearer surfaces are white and the far/background region is
  black.
- `mask_female.png` — visible pixels belonging to `IK_character`.
- `mask_male_carrier.png` — visible pixels belonging to `MaleCarrier`.
- `mask_character_ids.png` — one segmentation image: female is red, male is
  green, and props/background are black.
- `camera.json` — camera transform, projection, FOV, clip planes, adaptive
  depth range, actor paths, and pass filenames.

The masks preserve occlusion. If the male carrier is in front of part of the
female, that hidden female region is absent from `mask_female.png`; it is not an
X-ray silhouette. This makes the masks suitable for regional prompting,
ControlNet-style workflows, and later ComfyUI automation.

For a one-image generation workflow, start with
`character_color_reference.png`. Tell the image model that magenta is the
female, cyan-blue is the male carrier, and gray is environment geometry. The
flat actor colors disambiguate contact and overlapping limbs, while the shaded
surfaces still communicate the 3D form that a binary mask cannot provide.

The capture runs in a temporary isolated copy of the currently edited scene,
so material overrides used for depth and segmentation never alter the scene or
create Undo history. The copy is a direct script-free snapshot of the evaluated
editor nodes. Imported character scenes are not re-instantiated during capture;
this avoids tool scripts changing their child lists in the middle of Godot's
duplication pass.

## Record a camera-motion guide for H3

The same dock can record a short H.264 MP4 while you navigate the selected 3D
editor viewport or stream character motion into the editor. This is intended
as a render-to-real guide for video models: before every frame, the recorder
copies live scene-node transforms, evaluated skeleton poses, and blend-shape
values into its clean off-screen scene while its camera follows every orbit,
pan, and zoom made in the editor.

1. Frame the initial view and select the correct **Editor view** and
   **Resolution**.
2. Under **H3 camera-motion guide**, set **Duration**, **Capture FPS**, and
   **Start delay**. The defaults—5 seconds, 12 FPS, and a 2-second delay—keep
   editor navigation responsive on a laptop.
3. Click **Record editor camera motion**.
4. During the countdown, move the pointer into the 3D viewport. Orbit, pan, or
   zoom and/or start the `pose.frame` stream. Keep the stream running until
   recording finishes. The same button can stop the capture early.

The plugin writes a new `*-camera-motion` directory containing:

- `editor_camera_motion.mp4` — H.264 (`libx264`), `yuv420p`, CRF 17, with
  fast-start metadata for broad upload compatibility.
- `camera_motion.json` — resolution, requested duration, captured frame count,
  FPS, exact editor-camera samples, and live-scene binding counts. Version 2
  identifies that skeleton data came from evaluated global bone poses.
- `camera_motion_frames/` — temporary high-quality JPEG frames, retained only
  when **Keep source JPEG frames** is enabled or when FFmpeg reports an error.

The recorder looks for FFmpeg in Homebrew's Apple Silicon and Intel locations,
`/usr/bin`, and the editor process's `PATH`. On macOS, install it with
`brew install ffmpeg` if the dock reports that no encoder is available.

The capture loop yields to the editor between samples, so navigation and the
localhost pose receiver remain active. The isolated render copy disables its
own AnimationPlayers, AnimationTrees, and SkeletonModifier3D nodes; the edited
scene is the single source of truth, preventing the copy from overwriting a
streamed pose. PNG-quality still passes and high-resolution 24/30 FPS video are
more expensive to capture; start with 1280×720 at 12 FPS for an H3 composition
test, then increase quality only after camera and character motion work.
