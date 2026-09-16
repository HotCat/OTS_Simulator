# Image to `.gdpose`

`tools/image_to_gdpose.py` estimates one person's pose from a still image and
turns it into the IK controls used by `demos/my_manual_rig_pose.tscn`. The
result is deliberately a coarse pose: inspect it in Godot, correct depth and
occluded limbs, then use Quick FK or the Skeleton3D bone controls for detail.
MediaPipe remains the simple-image backend; SAM 3D Body/MHR JSON is supported
for difficult poses with stronger 3D body reconstruction.

## Install the optional image backend

Use a virtual environment so the computer-vision packages do not modify
Godot's or Emacs's Python environment:

```sh
cd '/path/to/OTS_Simulator'
python3 -m venv .venv-image-pose
source .venv-image-pose/bin/activate
python3 -m pip install -r tools/requirements-image-pose.txt
```

## Convert an image

```sh
python3 tools/image_to_gdpose.py '/absolute/path/reference.png' \
  --template poses/ots-carry.gdpose \
  --output poses/reference-coarse.gdpose \
  --pose-name reference_coarse
```

When a template is supplied, its existing `active_pose` is preserved. Add
`--activate` when you want the new profile selected automatically by Emacs or
another document reader:

```sh
python3 tools/image_to_gdpose.py '/absolute/path/reference.png' \
  --template poses/ots-carry.gdpose \
  --output poses/reference-coarse.gdpose \
  --pose-name reference_coarse --activate
```

Open the generated file in Emacs and press `C-c C-e`, or apply it immediately
to an editor that is already listening on port 7007:

```sh
python3 tools/image_to_gdpose.py '/absolute/path/reference.png' \
  --template poses/ots-carry.gdpose \
  --output poses/reference-coarse.gdpose \
  --pose-name reference_coarse \
  --send 127.0.0.1:7007
```

Use `--send 127.0.0.1:7008` for the running game. If left and right appear
reversed, repeat with `--mirror-x`. `--height`, `--floor-y`, and
`--pole-distance` tune the estimate for the current character and rig.

For repeatable pipelines, `--landmarks-json PATH` saves the normalized
landmarks used by the converter. `--debug-overlay PATH` writes an annotated
copy of the input image (green dots meet the confidence threshold; red dots
are uncertain). Both are optional and do not alter the Godot scene.

If a landmark is below `--confidence` and the template's active profile has a
value for the corresponding IK control, that generated control is omitted so
the template value is retained. The output pose records these names in
`retained_template_controls`.

## SAM 3D Body / MHR output

Install the official [SAM 3D Body repository](https://github.com/facebookresearch/sam-3d-body)
and its model dependencies separately. This project does not vendor Meta's
large checkpoints. For CPU/MPS device selection, apply the included two-line
upstream compatibility patch after cloning:

```sh
git clone https://github.com/facebookresearch/sam-3d-body.git sam3d/sam-3d-body-repo
git -C sam3d/sam-3d-body-repo apply ../../tools/sam3d_device.patch
```

The included wrapper converts SAM's NumPy output to JSON:

```sh
python3 tools/sam3d_export_json.py \
  '/absolute/path/23DE54524189455FA8FE22F1CB37F6D5.jpg' \
  --sam3d-repo sam3d/sam-3d-body-repo \
  --checkpoint-path sam3d/sam-3d-body-vith/model.ckpt \
  --mhr-path sam3d/sam-3d-body-vith/assets/mhr_model.pt \
  --bbox 250 220 1110 1540 \
  --inference-type body \
  --output poses/reverse_ots_female_sam3d.mhr70.json \
  --device cpu
```

`--bbox X1 Y1 X2 Y2` bypasses person detection and is recommended for an
overlapping carry image. `--inference-type body` avoids the upstream
CUDA-specific hand-refinement path. On current Apple Silicon, use `--device
cpu`: Meta's bundled MHR TorchScript forces float64 internally, which MPS does
not support. The wrapper writes compact pose data and omits the large vertex
mesh unless `--include-vertices` is requested. Use `--person-index N` to keep
one record when inference produces multiple people.

The official SAM 3D Body estimator returns a list of records containing
`pred_keypoints_3d` (70 MHR keypoints). Save that list as JSON and pass it to
the same converter:

```sh
python3 tools/image_to_gdpose.py poses/reverse_ots_female_sam3d.mhr70.json \
  --format sam3d-mhr \
  --template poses/ots-carry.gdpose \
  --output poses/ots-carry.gdpose \
  --pose-name reverse_ots_female_sam3d \
  --mhr-axis camera \
  --torso-roll-degrees 180
```

`--format auto` also detects the SAM keys automatically. The adapter maps MHR70
body points to pelvis, torso, neck, head, arm, and leg IK controls. It treats
MHR coordinates as Y-up body/world coordinates by default. If an exporter has
already converted them to camera coordinates, use `--mhr-axis camera`.

Joint positions alone cannot distinguish a horizontal belly-up body from a
belly-down body. For a reverse OTS pose where the face/chest point toward the
ground and the back faces the camera, add `--torso-roll-degrees 180`. This
creates a hybrid profile with a readable `Hips` local Euler rotation while the
IK targets continue to place the torso and limbs.

For a multi-person SAM result, choose the carried person (or carrier) by
zero-based index:

```sh
python3 tools/image_to_gdpose.py sam3d_output.json --format sam3d-mhr \
  --person-index 1 --template poses/ots-carry.gdpose \
  --output poses/reverse-ots-carried.gdpose \
  --pose-name reverse_ots_carried
```

The adapter intentionally uses `pred_keypoints_3d`, not the private MHR 308
joint ordering. This keeps the input stable across SAM 3D Body releases while
still producing a profile compatible with the project's 56-bone humanoid rig.

## External pose estimators

The input may instead be JSON. This is the stable interface for a future
ComfyUI, local vision model, or motion-capture process. Supply either a mapping
of MediaPipe landmark names to values:

```json
{
  "landmarks": {
    "nose": {"x": 0.0, "y": -0.7, "z": 0.1, "confidence": 0.9},
    "left_shoulder": [-0.2, -0.4, 0.0, 0.9]
  }
}
```

or all 33 MediaPipe landmarks as an ordered array. The required landmarks are
nose, shoulders, elbows, wrists, hips, knees, and ankles. Foot-index landmarks
are optional. The JSON path uses only Python's standard library and therefore
does not require MediaPipe or OpenCV.

## Single-image limitations

A single view cannot recover hidden joints or exact distance from the camera.
Loose clothing can also hide the body silhouette. Prefer a full-body image
with visible elbows, hands, knees, and feet. Side-view OTS references usually
need manual depth correction after conversion; this is expected and is why the
tool emits editable IK controls instead of pretending to produce final FK.
