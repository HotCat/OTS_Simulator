"""Append six localized CPR soft-tissue bones to the existing Humanizer proxy.

The original GLB is never overwritten. Existing bone names, rest transforms,
and vertex weights are retained; only anterior torso vertices receive a small
weight share for the new controls. Run with Blender 4.5 in background mode:

  Blender -b --python tools/blender/build_cpr_deform_female.py -- INPUT.glb OUTPUT.glb SOURCE.blend
"""

import math
import json
import struct
import sys

import bpy


def remove_gltf_scene_name(path):
    """Avoid a second scene-name wrapper before Godot's post-import repair."""
    with open(path, "rb") as handle:
        blob = handle.read()
    if blob[:4] != b"glTF" or struct.unpack_from("<I", blob, 4)[0] != 2:
        raise RuntimeError("Blender did not export a glTF 2.0 GLB")
    chunks = []
    offset = 12
    while offset < len(blob):
        length, kind = struct.unpack_from("<II", blob, offset)
        chunks.append((kind, blob[offset + 8 : offset + 8 + length]))
        offset += 8 + length
    doc = json.loads(chunks[0][1].decode("utf-8"))
    doc.setdefault("asset", {}).setdefault("extras", {})["cpr_deform_variant"] = "humanizer_root_v3"
    for scene in doc.get("scenes", []):
        scene.pop("name", None)
    encoded = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    encoded += b" " * (-len(encoded) % 4)
    chunks[0] = (0x4E4F534A, encoded)
    payload = b"".join(struct.pack("<II", len(chunk), kind) + chunk for kind, chunk in chunks)
    with open(path, "wb") as handle:
        handle.write(b"glTF" + struct.pack("<II", 2, len(payload) + 12) + payload)


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) != 3:
        raise SystemExit("Expected input.glb output.glb source.blend")
    source_path, output_path, blend_path = args
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.gltf(filepath=source_path)
    armature = next(obj for obj in bpy.data.objects if obj.type == "ARMATURE")
    avatar = bpy.data.objects["Avatar"]
    original_names = [bone.name for bone in armature.data.bones]
    if len(original_names) != 56 or len(avatar.data.vertices) < 15000:
        raise RuntimeError("Unexpected female source rig or mesh; refusing to alter it")

    # Blender rig coordinates are metres, with -Y on the woman's front.
    # Two soft-tissue patches per breast let the upper/lower mass settle at
    # different phases; two broad front-abdomen patches carry a subtle delayed
    # recoil. They are children of the existing torso bones, not replacements.
    specs = [
        ("CPR_LeftBreastUpper", "UpperChest", (+0.105, -0.125, 1.475), (+0.105, -0.17, 1.475)),
        ("CPR_LeftBreastLower", "UpperChest", (+0.105, -0.125, 1.405), (+0.105, -0.17, 1.405)),
        ("CPR_RightBreastUpper", "UpperChest", (-0.105, -0.125, 1.475), (-0.105, -0.17, 1.475)),
        ("CPR_RightBreastLower", "UpperChest", (-0.105, -0.125, 1.405), (-0.105, -0.17, 1.405)),
        ("CPR_UpperAbdomen", "Chest", (0.0, -0.105, 1.270), (0.0, -0.155, 1.270)),
        ("CPR_LowerAbdomen", "Spine", (0.0, -0.105, 1.175), (0.0, -0.155, 1.175)),
    ]
    bpy.context.view_layer.objects.active = armature
    armature.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for name, parent_name, head, tail in specs:
        bone = armature.data.edit_bones.new(name)
        bone.head = head
        bone.tail = tail
        bone.parent = armature.data.edit_bones[parent_name]
        bone.use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")

    group_by_name = {name: avatar.vertex_groups.new(name=name) for name, *_ in specs}
    touched = {name: 0 for name in group_by_name}
    max_new_share = 0.0
    for vertex in avatar.data.vertices:
        x, y, z = vertex.co
        if y > -0.055 or abs(x) > 0.25 or z < 1.08 or z > 1.57:
            continue
        # Compact, front-only falloffs. At most two new weights are retained
        # per vertex, so the Godot skin stays within eight influences.
        proposals = []
        for name, *_ in specs:
            if "Breast" in name:
                if ("Left" in name and x < 0.005) or ("Right" in name and x > -0.005):
                    continue
                cx = 0.105 if "Left" in name else -0.105
                cz = 1.475 if "Upper" in name else 1.405
                dx = (x - cx) / 0.095
                dy = (y + 0.165) / 0.078
                dz = (z - cz) / 0.072
                share = 0.29 * math.exp(-1.5 * (dx * dx + dy * dy + dz * dz))
            else:
                cz = 1.270 if "Upper" in name else 1.175
                dx = x / 0.19
                dy = (y + 0.13) / 0.075
                dz = (z - cz) / 0.085
                share = 0.19 * math.exp(-1.5 * (dx * dx + dy * dy + dz * dz))
            if share >= 0.012:
                proposals.append((name, share))
        proposals.sort(key=lambda item: item[1], reverse=True)
        proposals = proposals[:2]
        if not proposals:
            continue
        total = min(0.42, sum(weight for _, weight in proposals))
        max_new_share = max(max_new_share, total)
        old_weights = [(item.group, item.weight) for item in vertex.groups]
        # All existing weights are scaled proportionally, maintaining their
        # relative deformation and a total skin weight of one.
        for index, old_weight in old_weights:
            avatar.vertex_groups[index].add([vertex.index], old_weight * (1.0 - total), "REPLACE")
        proposal_sum = sum(weight for _, weight in proposals)
        for name, weight in proposals:
            group_by_name[name].add([vertex.index], total * weight / proposal_sum, "REPLACE")
            touched[name] += 1

    if min(touched.values()) < 100:
        raise RuntimeError(f"Insufficient deforming vertices on a CPR control: {touched}")
    print("CPR_DEFORM_WEIGHTED", touched, "max_new_share", round(max_new_share, 4))
    print("CPR_DEFORM_BONES", len(armature.data.bones), "original_order_retained", [b.name for b in armature.data.bones[:56]] == original_names)

    # Keep an editable packed Blender source. Icosphere is a non-character
    # helper imported from the GLB; do not include it in the runtime variant.
    helper = bpy.data.objects.get("Icosphere")
    if helper is not None:
        bpy.data.objects.remove(helper, do_unlink=True)
    bpy.ops.file.pack_all()
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=blend_path)
    bpy.ops.object.select_all(action="DESELECT")
    armature.select_set(True)
    avatar.select_set(True)
    for child in armature.children:
        if child.type == "EMPTY":
            child.select_set(True)
    bpy.context.view_layer.objects.active = armature
    bpy.ops.export_scene.gltf(
        filepath=output_path,
        export_format="GLB",
        use_selection=True,
        export_animations=False,
        export_all_influences=True,
        export_skins=True,
        export_lights=False,
        export_cameras=False,
    )
    remove_gltf_scene_name(output_path)
    print("CPR_DEFORM_EXPORTED", output_path)


if __name__ == "__main__":
    main()
