import bpy
import math
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / 'assets/environments/ikea_sample_room'
OUT.mkdir(parents=True, exist_ok=True)

def clear():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)

def mat(name, color, rough=0.7, metallic=0.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1.0)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = (*color, 1.0)
    bsdf.inputs['Roughness'].default_value = rough
    bsdf.inputs['Metallic'].default_value = metallic
    return m

WOOD = mat('warm oak', (0.30, 0.16, 0.075), .65)
DARK = mat('charcoal furniture', (0.035, 0.045, 0.055), .55)
WALL = mat('soft sage walls', (0.46, 0.52, 0.43), .88)
FLOOR = mat('light oak floor', (0.42, 0.27, 0.13), .72)
WHITE = mat('warm white fabric', (0.82, 0.80, 0.73), .92)
TEXTILE = mat('neutral bedding', (0.68, 0.66, 0.60), .96)
GLASS = mat('door glass', (0.12, 0.28, 0.31), .16)
METAL = mat('brushed metal', (0.22, 0.23, 0.22), .38, .35)
BLACK = mat('black frame', (0.018, 0.021, 0.024), .48)

def cube(name, loc, scale, material, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(location=loc)
    o = bpy.context.object
    o.name = name
    o.dimensions = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if material: o.data.materials.append(material)
    if bevel:
        mod = o.modifiers.new('soft edges', 'BEVEL'); mod.width = bevel; mod.segments = 2
    return o

def cylinder(name, loc, radius, depth, material, rot=(0,0,0), verts=24):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius, depth=depth, location=loc, rotation=rot)
    o = bpy.context.object; o.name = name
    if material: o.data.materials.append(material)
    return o

def room():
    # 5 m x 6 m = 30 m², 2.7 m clear height, 120 mm walls.
    # Blender uses Z-up: X=width, Y=depth, Z=height. The glTF importer will
    # convert this to Godot's Y-up convention automatically.
    cube('Floor_5x6m', (0,0,0), (5.0,6.0,.08), FLOOR)
    # Door is on the south wall, facing into the room; opening is 0.90 x 2.10 m.
    wall_t=.12; h=2.70; w=5.0; d=6.0
    cube('Wall_West', (-w/2, 0, h/2), (wall_t,d,h), WALL)
    # A second opening is cut into the east wall rather than hidden behind it.
    east_door_z = -1.55
    east_south_len = east_door_z - .45 - (-d/2)
    east_north_len = d - .90 - east_south_len
    cube('Wall_East_North', (w/2, -d/2 + east_south_len + .90 + east_north_len/2, h/2), (wall_t,east_north_len,h), WALL)
    cube('Wall_East_South', (w/2, -d/2 + east_south_len/2, h/2), (wall_t,east_south_len,h), WALL)
    cube('Wall_East_DoorHeader', (w/2, east_door_z, (h+2.10)/2), (wall_t,.90,h-2.10), WALL)
    cube('Wall_North', (0, d/2, h/2), (w,wall_t,h), WALL)
    door_w=.90; door_h=2.10; side=(w-door_w)/2
    cube('Wall_South_Left', (-(door_w+side)/2, -d/2, h/2), (side,wall_t,h), WALL)
    cube('Wall_South_Right', ((door_w+side)/2, -d/2, h/2), (side,wall_t,h), WALL)
    cube('Wall_South_DoorHeader', (0, -d/2, (h+door_h)/2), (door_w,wall_t,h-door_h), WALL)
    # Keep fixed jambs in the architectural shell, but export each moving leaf
    # separately. An imported room GLB must never contain a baked closed leaf.
    for jamb_x in (-door_w/2, door_w/2):
        cube('South_Door_Jamb', (jamb_x, -d/2+.07, door_h/2), (.045,.055,door_h), WHITE)
    cube('South_Door_Lintel', (0,-d/2+.07,door_h), (door_w+.045,.055,.045), WHITE)
    for jamb_y in (east_door_z-.45, east_door_z+.45):
        cube('East_Door_Jamb', (w/2-.07,jamb_y,door_h/2), (.055,.045,door_h), WHITE)
    cube('East_Door_Lintel', (w/2-.07,east_door_z,door_h), (.055,.945,.045), WHITE)
    cube('Door_Threshold_South', (0,-d/2,.025), (door_w+.12,.18,.05), WOOD, .01)
    cube('Door_Threshold_East', (w/2,east_door_z,.025), (.18,1.02,.05), WOOD, .01)

def ceiling():
    # Optional camera blocker. Kept as its own switchable scene instance.
    cube('Ceiling_5x6m', (0,0,2.70), (5.0,6.0,.08), WALL)

def grid_door_leaf():
    # Origin = left hinge at floor level. Local +X spans the 0.90 m doorway.
    # A real open grid remains legible from both sides, without an opaque slab.
    width, height = .90, 2.10
    cube('GridDoor_LeftStile', (.035,0,height/2), (.07,.045,height), WHITE, .008)
    cube('GridDoor_RightStile', (width-.035,0,height/2), (.07,.045,height), WHITE, .008)
    for z in (.035,height-.035):
        cube('GridDoor_Rail', (width/2,0,z), (width,.045,.07), WHITE, .008)
    cube('GridDoor_Glass', (width/2,0,height/2), (width-.14,.015,height-.14), GLASS)
    for x in (.225,.45,.675):
        cube('GridDoor_Vertical_Mullion', (x,-.018,height/2), (.025,.055,height-.14), WHITE)
    for z in (.525,1.05,1.575):
        cube('GridDoor_Horizontal_Mullion', (width/2,-.018,z), (width-.14,.055,.025), WHITE)
    cube('GridDoor_Handle', (width-.10,-.07,1.03), (.02,.10,.12), METAL, .005)

def solid_door_leaf():
    width, height = .90, 2.10
    cube('SolidDoor_Panel', (width/2,0,height/2), (width,.04,height), WHITE, .012)
    for z in (.24,1.05,1.88):
        cube('SolidDoor_Panel_Rail', (width/2,-.026,z), (width-.12,.015,.035), WOOD, .004)
    cube('SolidDoor_Handle', (width-.10,-.07,1.03), (.02,.10,.12), METAL, .005)

def bed():
    # Standalone local-origin model. X is 1.92 m across the headboard; Y is
    # 2.07 m head-to-foot. Rotate the parent instance in Godot, not the parts.
    cube('Bed_Frame_192x207cm', (0, 0, .39), (1.92,2.07,.39), DARK, .035)
    cube('Bed_Mattress', (0, 0, .67), (1.84,1.98,.20), WHITE, .05)
    cube('Bed_Duvet', (0, .14, .80), (1.80,1.86,.08), TEXTILE, .06)
    cube('Bed_Headboard_101cm', (0, -.975, .505), (1.92,.12,1.01), DARK, .025)
    # Four simple legs keep the design readable in blocking renders.
    for xx in (-.86,.86):
        for yy in (-.91,.91): cube('Bed_Leg', (xx,yy,.20), (.10,.10,.40), DARK, .01)
    for xx in (-.55,0,.55):
        cube('Bed_Pillow', (xx,-.65,.84), (.42,.54,.13), WHITE, .06)

def wardrobe():
    # Standalone local-origin model: outer 0.82 x 0.60 x 1.94 m.
    x, depth = 0.0, 0.0
    w,d,h=.82,.60,1.94; t=.055
    cube('Wardrobe_LeftSide', (x-w/2+t/2,depth,h/2), (t,d,h), DARK, .01)
    cube('Wardrobe_RightSide', (x+w/2-t/2,depth,h/2), (t,d,h), DARK, .01)
    cube('Wardrobe_Top', (x,depth,h-t/2), (w,d,t), DARK, .01)
    cube('Wardrobe_Bottom', (x,depth,t/2), (w,d,t), DARK, .01)
    cube('Wardrobe_Back', (x,depth+d/2-t/2,h/2), (w,t,h), DARK, .01)
    cube('Wardrobe_Rod', (x,depth-.06,h-.22), (.68,.035,.035), METAL)
    cube('Wardrobe_Shelf', (x,depth,.97), (.70,.48,.045), DARK, .01)
    cube('Wardrobe_Shelf2', (x,depth,.48), (.70,.48,.045), DARK, .01)
    # Two doors shown open slightly, preserving the 82 x 194 cm envelope.
    for side, ang in [(-1,-math.radians(18)), (1,math.radians(18))]:
        px=x+side*(w/2+.12); py=depth-d/2-.02
        o=cube('Wardrobe_OpenDoor', (px, py, h/2), (w/2-.015,.045,h), DARK, .015)
        o.rotation_euler[2]=ang

def accents():
    # Only the rug remains fixed in the room. The old bedside table and the
    # lamp/shade above it have deliberately been removed.
    cube('Rug_240x160cm', (-.45,.8,.045), (2.4,1.6,.025), TEXTILE, .01)

def main():
    # Export independent, local-origin assets. The shell contains no bed,
    # wardrobe, movable door leaves, or ceiling, so Godot scene instances and
    # angle controls are the single source of truth for shot layout.
    bpy.context.preferences.filepaths.save_version = 0
    for basename, builder in (
        ('ikea_sample_room', lambda: (room(), accents())),
        ('ikea_ceiling', ceiling),
        ('ikea_grid_door_leaf', grid_door_leaf),
        ('ikea_solid_door_leaf', solid_door_leaf),
        ('ikea_bed', bed),
        ('ikea_wardrobe', wardrobe),
    ):
        clear()
        builder()
        bpy.ops.wm.save_as_mainfile(filepath=str(OUT / f'{basename}.blend'))
        bpy.ops.object.select_all(action='SELECT')
        bpy.ops.export_scene.gltf(
            filepath=str(OUT / f'{basename}.glb'),
            export_format='GLB',
            use_selection=True,
            export_apply=True,
        )

if __name__ == '__main__': main()
