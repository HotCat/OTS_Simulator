# Female 1791377232602 — neutral realtime proxy

`female_1791377232602_humanizer_proxy.glb` is a **new, separate** Humanizer-native character. Open `female_1791377232602.tscn` in Godot for a side-by-side comparison. It does not replace `IK_character` or modify the OTS carry scene.

## Side-by-side comparison

The scene instances the exact `actor_1787313553107_v2_realtime_proxy.glb` used by `IK_character` in `demos/ots_carry_clay_proxy.tscn` on the left and the new proxy on the right. Both are shown in their neutral pose, at root scale `(1, 1, 1)`, on the same floor, 2 m apart. The carried OTS pose is intentionally not copied: rotation and limb folding obscure stature and body-proportion comparisons. Labels and 1.0/1.8/1.9 m horizontal guides help evaluate scale.

The current OTS female measures about **1.80 m** on fresh GLB import; the new proxy's body measures **1.90005 m**. Thus the new body should appear roughly 10 cm taller. `qa/verify_comparison.gd` checks that both characters load, have skeletons, and retain unit scale.

## Source and fit

- Source: the user's multiview A-pose and identity sheets, `1791377232602.png` and `1791376176067.png`.
- Confirmed **barefoot** anatomical height: 1.90 m. Thick-soled shoes in the sheet were excluded.
- Adult East Asian female body fit, with conservative shoulder, waist, hip, limb, and head adjustments. The clothing silhouette was not treated as bare anatomy.
- This installed MPFB version produced the female body at gender `0.0`, confirmed by a rendered gender comparison. The Humanizer export consequently used `identity` gender mapping, not the older skill documentation's `invert` convention. Both the source and Humanizer reports say female `0.0`.
- The accepted front and back sheet crops guided width and proportions. Side crops contained adjacent figures, so depth fitting remains approximate.

## Runtime asset

- One combined, skinned `Avatar` mesh; one 56-bone skeleton; eight surfaces for body, eyes, brows, lashes, and rigged ponytail.
- Idle and Run clips are included. Godot 4.7.2 imported the GLB and played Run successfully; `qa/verify_import.gd` reproduces the structural/runtime check.
- Fresh-import body height: **1.90005 m**; hair-inclusive visual height: 1.90842 m. Root scale is `(1, 1, 1)`.
- All 12 requested custom body/head targets transferred to Humanizer; none were rejected.
- The rest, Run, and 40-degree head-turn images in `qa/` show attached facial parts and ponytail, without obvious joint collapse. Fine facial fit and more demanding external retargets are not yet validated.

## Important limits

This is a **neutral unclothed proxy**, not a photorealistic likeness or a reproduction of the sheet's white top, dark leggings, shoes, jewelry, or exact hairstyle. Its face and ponytail are stock parametric approximations; no identity texture was baked. Add fitted garments and perform OTS-specific pose/animation retarget QA before substituting it into the carry scene.

`source/fit-config.json` and `source/human.female_1791377232602.json` preserve the editable fit. `qa/` contains the MPFB/Humanizer reports, independent strict GLB validation, deformation renders, and the Godot import test.

Run the Godot test from the project root:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://assets/models/female_1791377232602/qa/verify_import.gd
```
