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

Every click creates a timestamped directory under
`res://renders/ots_quickview/`. The entire `renders/` directory is Git-ignored.

## Output passes

- `beauty.png` — the ordinary Godot render, without editor gizmos or selection
  outlines.
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

The capture runs in a temporary isolated copy of the currently edited scene,
so material overrides used for depth and segmentation never alter the scene or
create Undo history.
