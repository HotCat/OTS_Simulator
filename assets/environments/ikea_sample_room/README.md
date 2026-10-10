# IKEA sample room blocking asset

The editable Blender sources and Godot imports are split into six independent
assets: `ikea_sample_room.blend`/`.glb` for the architectural shell and rug,
`ikea_ceiling.blend`/`.glb` for the optional ceiling,
`ikea_grid_door_leaf.blend`/`.glb` and `ikea_solid_door_leaf.blend`/`.glb`
for the two adjustable doors, plus `ikea_bed.blend`/`.glb` and
`ikea_wardrobe.blend`/`.glb` for the furniture. The room is intentionally a
layout proxy for H3 rather than a finished interior asset:

- clear floor plan: 5.0 m × 6.0 m = 30 m²;
- wall height: 2.70 m, wall thickness: 0.12 m;
- glazed grid door on the south wall: 0.90 m × 2.10 m;
- solid interior door on the east wall: 0.90 m × 2.10 m;
- bed envelope: 2.07 m × 1.92 m, headboard height 1.01 m;
- wardrobe envelope: 0.82 m × 0.60 m × 1.94 m.

The nightstand and the object above it (bedside lamp/shade) are no longer in
the room shell. Both door leaves rotate about separate floor-level hinge nodes
in the Godot scene. The 2.70 m ceiling is a separate instance, hidden by
default so an editor camera can move above the room without obstruction.

Each furniture GLB has a local origin at the center of its floor footprint, so
the `Bed` and `Wardrobe` sibling instances in the Godot comparison scene can be
translated and rotated as complete accessories. The shell does not contain
duplicate bed or wardrobe geometry. The furniture itself is assembled from
named blocking pieces with neutral materials and only the silhouette/details
needed for camera and character staging.

The Blender source is Z-up and is exported/imported with that convention
explicitly checked. In Godot, the floor is horizontal, the walls rise on the
Y axis, and the two door openings are vertical and cut into their respective
walls rather than placed in front of solid wall meshes.
