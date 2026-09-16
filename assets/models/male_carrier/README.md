# Male carrier proxy

`male_1785818633452_humanizer_proxy.glb` is a Humanizer-native realtime male character built from the male in the user's paired reference image. It is a separate asset and does not replace the existing female proxy.

## Scale and build assumptions

- Target anatomical height: **1.80 m**.
- The paired female is known to be 1.81 m tall. Their segmented source-image silhouette ratio is about 0.978, but both wear different footwear, so the male estimate is intentionally documented as approximately 1.79–1.80 m rather than centimetre-accurate.
- The fit uses a conservative adult East Asian male profile with moderately athletic shoulders, chest, arms, thighs, and calves. Loose source clothing was not treated as body geometry.
- The fitted short hair is a Humanizer proxy silhouette (`Hair-Short01`), not an identity-perfect reconstruction.
- No generated face texture was promoted; the asset uses the clean neutral Humanizer material.

## Runtime structure

- One combined, skinned `Avatar` mesh.
- One 53-bone skeleton.
- Eight skinned surfaces: body, two eyes, two eyebrows, two eyelashes, and hair.
- Embedded `animations_Idle` and `animations_Run` clips.
- Fresh-import body height: 1.80003 m; hair-inclusive visual height: 1.81805 m.
- No global node scale was used for height correction.

Godot can instance the GLB directly:

```gdscript
const MALE_CARRIER := preload(
    "res://assets/models/male_carrier/male_1785818633452_humanizer_proxy.glb"
)

func add_male_carrier(parent: Node3D) -> Node3D:
    var actor := MALE_CARRIER.instantiate() as Node3D
    parent.add_child(actor)
    return actor
```

The GLB's local origin is at the feet and its body height is already in Godot metres. Keep the root scale at `(1, 1, 1)` when comparing it with the 1.81 m female.

## Reproducibility and QA

- `source/fit-config.json` is the conservative MPFB fit recipe.
- `source/human.male_1785818633452.json` is the editable MPFB/MakeHuman preset and source of truth.
- `qa/mpfb_build_report.json` records the MPFB rig and height calibration.
- `qa/humanizer_proxy_report.json` records gender mapping, transferred targets, equipment, surfaces, animations, and Humanizer height calibration.
- `qa/humanizer_glb_validation.json` records the independent strict GLB validation.
- `qa/rest_front.png`, `qa/run_front.png`, and `qa/head_turn_front.png` are deformation and attachment checks.

This workspace's installed MPFB and Humanizer data both define gender as female `0.0`, male `1.0`. The build therefore uses identity gender mapping. This is intentional and overrides older pipeline notes that expected inverted semantics.
