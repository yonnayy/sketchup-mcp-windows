"""Caroline's Farmhouse as a list of MCP tool calls.

Source: "Caroline's Farmhouse - The Original Starter Farmhouse Plans", a design
by Jay Osborne, FreeFarmhouse.com, licensed CC BY-SA 4.0. The numbers below
were read from the blueprint set (sheets A1.1 downstairs plan, A1.2 upstairs
plan, A2.x elevations, A3.0 section, A4.0 details); see README.md here.

Everything in this file is in INCHES, as on the drawings. The origin is the
outside south-west corner of the 24' x 16' main house, x to the east, y to the
north; the front porch is on the south side. z = 0 is the finished downstairs
floor. Running this file writes caroline.json, where every length is in
metres, ready for the tools.

    python examples/caroline/make_steps.py
"""
import json
import os

IN = 0.0254
T = 3.5          # stud walls as drawn
C = T / 2.0
B = "Caroline"

FF2 = 108.0      # upstairs floor, +9'-0"
PLATE = 205.0    # top plate, +17'-1"
WING = 100.0     # wall height of the one-storey wings
GRADE = -25.0
DECK = -4.0      # porch deck, about 6" below the floor at the door


def m(v):
    return round(v * IN, 4)


def pt(p):
    return [m(v) for v in p]


def pts(points):
    return [pt(p) for p in points]


steps = []


def step(tool, args, note, expect=None):
    steps.append({"n": len(steps) + 1, "tool": tool, "note": note, "args": args, "expect": expect or []})


class Floor:
    def __init__(self, name, base, height):
        self.spec = {"building": B, "name": name, "base_z": m(base), "wall_height": m(height),
                     "wall_thickness": m(T), "frame_width": m(1.5), "walls": [], "openings": []}

    def wall(self, wid, a, b, ref="center", **kw):
        w = {"id": wid, "from": pt(a), "to": pt(b)}
        if ref != "center":
            w["ref"] = ref
        for k, v in kw.items():
            w[k] = m(v) if k in ("thickness", "height") else v
        self.spec["walls"].append(w)

    def door(self, wid, offset, width, height=80, **kw):
        o = {"wall": wid, "type": "door", "offset": m(offset), "width": m(width), "height": m(height)}
        o.update(kw)
        self.spec["openings"].append(o)

    def window(self, wid, offset, width, sill, height):
        self.spec["openings"].append({"wall": wid, "type": "window", "offset": m(offset), "width": m(width),
                                      "sill": m(sill), "height": m(height), "fixed": True})


# Outline of everything that is heated: main house, side room (west), bath (east), kitchen (north).
FOOTPRINT = [(0, 0), (288, 0), (288, 12), (356, 12), (356, 108), (288, 108), (288, 312), (168, 312),
             (168, 192), (0, 192), (0, 180), (-68, 180), (-68, 84), (0, 84)]

# ------------------------------------------------------------------ downstairs (A1.1)
f1 = Floor("Lantai 1", 0, FF2)
f1.wall("S1", (0, 0), (288, 0), "right")
f1.wall("E1", (288, 0), (288, 192), "right")
f1.wall("N1", (288, 192), (0, 192), "right")
f1.wall("W1", (0, 192), (0, 0), "right")
f1.wall("SRs", (-68, 84), (0, 84), "right", height=WING)                   # side room
f1.wall("SRn", (0, 180), (-68, 180), "right", height=WING)
f1.wall("SRw", (-68, 180), (-68, 84), "right", height=WING)
f1.wall("Bs", (288, 12), (356, 12), "right", height=WING)                  # bath
f1.wall("Be", (356, 12), (356, 108), "right", height=WING)
f1.wall("Bn", (356, 108), (288, 108), "right", height=WING)
f1.wall("Ke", (288, 192), (288, 312), "right", height=WING)                # kitchen
f1.wall("Kn", (288, 312), (168, 312), "right", height=WING)
f1.wall("Kw", (168, 312), (168, 192), "right", height=WING)
f1.wall("Cw", (256.5 + C, 0), (256.5 + C, 28 + C), height=96)               # coat closet
f1.wall("Cn", (256.5 + C, 28 + C), (288, 28 + C), height=96)
f1.wall("R1", (230.5, 75.5 + C), (243.5 + C, 75.5 + C), height=96)           # shelving niche by the stairs
f1.wall("SW", (243.5 + C, 75.5 + C), (243.5 + C, 147.5 + C), height=96)
f1.wall("R2", (230.5 + C, 147.5 + C), (243.5 + C, 147.5 + C), height=96)
# The utility closet is under the top of the stairs: its wall stops below the last flight.
f1.wall("UW", (230.5 + C, 147.5 + C), (230.5 + C, 192), height=82.5)
# Wall under the stairs: drawn full height on plan, but it stops under the flight.
f1.wall("BK", (247, 135.75), (288, 135.75), thickness=11.5, height=34)

f1.window("S1", 38, 32, 18, 72)
f1.window("S1", 128, 32, 18, 72)
f1.door("S1", 216, 36, 84, hinge="end", swing="left")                      # A: 36x84 front door
f1.door("E1", 42, 24, hinge="start", swing="right")                        # D: to the bath
f1.door("N1", 288 - 228, 32, style="polos", cased=True)                    # 32x80 cased opening to the kitchen
f1.window("N1", 288 - 76, 32, 30, 60)
f1.door("W1", 192 - 146, 24, hinge="end", swing="right")                   # D: to the side room
f1.window("W1", 192 - 66, 32, 18, 72)
f1.window("SRw", 180 - 144, 24, 36, 42)
f1.window("Be", 44 - 12, 24, 39, 42)
f1.window("Ke", 235.5 - 192, 24, 36, 42)
f1.window("Kw", 312 - 294, 24, 36, 42)
f1.door("Kw", 312 - 261, 36, hinge="end", swing="left")                    # B: 36x80 back door
f1.door("Cn", 262.5 - (256.5 + C), 18, style="polos")                      # E: coats
f1.door("UW", 154.5 - (147.5 + C), 30, hinge="start", swing="right")        # C: utility closet
f1.spec["slab"] = {"outline": pts(FOOTPRINT), "thickness": m(10)}

# -------------------------------------------------------------------- upstairs (A1.2)
f2 = Floor("Lantai 2", FF2, PLATE - FF2)
f2.wall("S2", (0, 0), (288, 0), "right")
f2.wall("E2", (288, 0), (288, 192), "right")
f2.wall("N2", (288, 192), (0, 192), "right")
f2.wall("W2", (0, 192), (0, 0), "right")
f2.wall("MP", (162 + C, 0), (162 + C, 147.5 + C))                           # between the bedrooms
f2.wall("BEw", (92 + C, 122.75), (92 + C, 192))                             # bath east wall
f2.wall("BS", (0, 122.75), (92 + C, 122.75), thickness=5.5)                 # insulated bath wall
f2.wall("HW", (92 + C, 147.5 + C), (243.5 + C, 147.5 + C))                  # hall
f2.wall("CWw", (133 + C, 88.5 + C), (133 + C, 147.5 + C))                   # west bedroom closet
f2.wall("CS", (133 + C, 88.5 + C), (162 + C, 88.5 + C))
f2.wall("CN", (133 + C, 129.5 + C), (162 + C, 129.5 + C))
f2.wall("EW", (243.5 + C, 88.5 + C), (243.5 + C, 147.5 + C))                # east bedroom closet
f2.wall("ES", (243.5 + C, 88.5 + C), (288, 88.5 + C))
f2.wall("EN", (243.5 + C, 127.5 + C), (288, 127.5 + C))
for x in (38, 128, 218):
    f2.window("S2", x, 32, 24, 60)
f2.window("W2", 192 - 112, 32, 24, 60)
f2.window("N2", 288 - 76, 32, 24, 60)
f2.window("N2", 288 - 226, 32, 24, 60)
f2.window("E2", 150, 24, 42, 42)
f2.door("HW", 99.5 - (92 + C), 30, hinge="start", swing="right")            # C: west bedroom
f2.door("HW", 140.5 - (92 + C), 18, style="polos")                          # E: linen
f2.door("HW", 169.5 - (92 + C), 30, hinge="end", swing="right")             # C: east bedroom
f2.door("BEw", 154.5 - 122.75, 30, hinge="end", swing="left")               # C: bath
f2.door("CWw", 97.5 - (88.5 + C), 24, hinge="start", swing="left")          # D: closet
f2.door("EW", 97.5 - (88.5 + C), 24, hinge="start", swing="right")          # D: closet

# ------------------------------------------------------------------------ walls
step("build_floor_plan", {"spec": f1.spec}, "Downstairs walls, openings and floor (sheet A1.1).",
     ["20 walls, 7 doors, 8 windows, 1 slab"])
step("build_floor_plan", {"spec": f2.spec}, "Upstairs walls and openings (sheet A1.2). Its floor comes next, with the stairwell left open.",
     ["14 walls, 6 doors, 7 windows"])
# Upstairs floor between the walls, open over the stairs (their footprint is in the build_stairs reply).
step("add_slab", {"spec": {"building": B, "floor": "Lantai 2", "name": "Lantai", "top_z": m(FF2), "thickness": m(12),
                           "outline": pts([(3.5, 3.5), (284.5, 3.5), (284.5, 92), (247, 92), (247, 151), (228, 151),
                                           (228, 188.5), (3.5, 188.5)]),
                           "material": "Lantai - Kayu", "color": [176, 132, 88]}},
     "Upstairs floor with the stairwell cut out.", ["Slab 'Lantai' (lantai) built in 'Lantai 2'"])

step("verify_dimensions", {"tolerance": 0.005, "checks": [
    {"label": "Lebar total lt.1 35'-4\" (A1.1)", "overall": "x", "building": B, "floor": "Lantai 1", "expected": m(424)},
    {"label": "Panjang total lt.1 26'-0\" (A1.1)", "overall": "y", "building": B, "floor": "Lantai 1", "expected": m(312)},
    {"label": "Badan utama lebar 24'-0\" (A1.2)", "overall": "x", "building": B, "floor": "Lantai 2", "expected": m(288)},
    {"label": "Badan utama dalam 16'-0\" (A1.2)", "overall": "y", "building": B, "floor": "Lantai 2", "expected": m(192)},
    {"label": "Living Room lebar (24'-0\" luar - dinding barat - rak 13\" dan dinding tangga)", "at": [3.556, 2.286], "axis": "x", "expected": m(240)},
    {"label": "Living Room dalam (16'-0\" luar - 2 dinding 3,5\")", "at": [3.556, 2.286], "axis": "y", "expected": m(185)},
    {"label": "Kitchen bersih (10'-0\" luar - 2 dinding 3,5\")", "at": [5.79, 6.35], "expected": [m(113), m(116.5)]},
    {"label": "Bath lt.1 (5'-8\" x 8'-0\" luar - dinding)", "at": [8.128, 1.524], "expected": [m(64.5), m(89)]},
    {"label": "Side Room lebar (gambar: 5'-3\" CLEAR)", "at": [-0.85, 3.3], "axis": "x", "expected": m(63)},
    {"label": "Side Room dalam (gambar: 7'-4\" CLEAR)", "at": [-0.85, 3.3], "axis": "y", "expected": m(88)},
    {"label": "Bedroom timur lebar 6'-6\" + 3'-5\"", "at": [5.6, 1], "z": m(FF2), "axis": "x", "expected": m(119)},
    {"label": "Bedroom barat lebar (7'-8\" + 3'-5\" + 2'-5\" dari muka luar)", "at": [2, 1], "z": m(FF2), "axis": "x", "expected": m(158.5)},
    {"label": "Bedroom barat dalam 7'-1\" (ke dinding closet)", "at": [3.8, 1], "z": m(FF2), "axis": "y", "expected": m(85)},
    {"label": "Hall lt.2 dalam (3'-5\" ke muka luar - dinding 3,5\")", "at": [4.318, 4.318], "z": m(FF2), "axis": "y", "expected": m(37.5)},
    {"label": "Bath lt.2 lebar (7'-8\" dari muka luar - dinding)", "at": [1.143, 3.937], "z": m(FF2), "axis": "x", "expected": m(88.5)},
]}, "Accuracy report against the plan dimensions. The two side room lines differ by 1 to 1.5 in: the drawing gives "
    "finished clear sizes there, the model has bare 3.5 in stud walls.", ["15 of 17 dimensions match"])

# ------------------------------------------------------------------------ roofs
SEAM = 16
ROOF = {"material": "Atap - Seng Abu", "color": [74, 80, 86], "seams": m(SEAM)}
# Main roof 7.5:12. The slab thickness stands for the raised-heel truss, so that the
# eave comes out at +17'-6" and the ridge at +23'-0" as on the elevations.
step("build_roof", {"spec": dict(ROOF, building=B, name="Atap Utama", type="gable", ridge="x", base_z=m(PLATE),
                                 pitch="7.5:12", overhang=m(9), rake=m(6), thickness=m(9.328),
                                 gable_walls={"thickness": m(T)}, **{"from": pt((0, 0)), "to": pt((288, 192))})},
     "Main roof 7.5:12 with both gable walls (A2.x). Top of ridge must be +23'-0\" = 7.010 m.",
     ["top of ridge at +7.010 m", "2 gable walls"])
PORCH = dict(ROOF, building=B, type="shed", top_z=m(119), pitch="3:12", overhang=m(12), thickness=m(4.85))
step("build_roof", {"spec": dict(PORCH, name="Atap Teras Depan", high_side="north", miter={"start": True, "end": True},
                                 **{"from": pt((-68, -68)), "to": pt((356, 0))})},
     "Front porch roof 3:12, mitred at both ends where it turns the corners.", ["(shed)"])
step("build_roof", {"spec": dict(PORCH, name="Atap Teras Barat", high_side="east", miter={"start": True}, rake=[0, m(6)],
                                 infill=[{"from": pt((-68, 84 + C)), "to": pt((0, 84 + C)), "thickness": m(T), "base_z": m(WING)},
                                         {"from": pt((-68, 180 - C)), "to": pt((0, 180 - C)), "thickness": m(T), "base_z": m(WING)},
                                         {"from": pt((-68 + C, 84)), "to": pt((-68 + C, 180)), "thickness": m(T), "base_z": m(WING)}],
                                 **{"from": pt((-68, -68)), "to": pt((0, 180))})},
     "West roof: one 3:12 plane over the porch return and the side room, with the wall tops filled up to it.",
     ["3 infill walls"])
step("build_roof", {"spec": dict(PORCH, name="Atap Teras Timur", high_side="west", miter={"start": True}, rake=[0, m(6)],
                                 infill=[{"from": pt((288, 12 + C)), "to": pt((356, 12 + C)), "thickness": m(T), "base_z": m(WING)},
                                         {"from": pt((288, 108 - C)), "to": pt((356, 108 - C)), "thickness": m(T), "base_z": m(WING)},
                                         {"from": pt((356 - C, 12)), "to": pt((356 - C, 108)), "thickness": m(T), "base_z": m(WING)}],
                                 **{"from": pt((288, -68)), "to": pt((356, 108))})},
     "East roof: the same over the porch end and the bath.", ["3 infill walls"])
step("build_roof", {"spec": dict(ROOF, building=B, name="Atap Belakang", type="gable", ridge="y", base_z=m(WING),
                                 pitch="3:12", overhang=m(9), rake=[0, m(9)], thickness=m(4.85),
                                 gable_walls={"thickness": m(T), "ends": "end"},
                                 infill=[{"from": pt((168 + C, 192)), "to": pt((168 + C, 312 - T)), "thickness": m(T), "base_z": m(WING)}],
                                 **{"from": pt((96, 192)), "to": pt((288, 312))})},
     "Rear roof 3:12 over the kitchen and the screen porch, gable wall at the back only.",
     ["1 gable walls", "1 infill walls"])

# ---------------------------------------------------------- porch, foundation, steps
WHITE = {"material": "Struktur - Kayu Putih", "color": [245, 245, 240]}
BRICK = {"material": "Struktur - Bata", "color": [156, 91, 75]}
step("add_slab", {"spec": dict(BRICK, building=B, name="Kaki Bata", kind="struktur", top_z=m(-10), thickness=m(15),
                               outline=pts(FOOTPRINT))},
     "Brick foundation under the house, down to grade.", ["Slab 'Kaki Bata' (struktur)"])
step("add_slab", {"spec": {"building": B, "group": "Teras", "name": "Dek Teras", "top_z": m(DECK), "thickness": m(8),
                           "outline": pts([(-68, -68), (356, -68), (356, 12), (288, 12), (288, 0), (0, 0), (0, 84), (-68, 84)]),
                           "material": "Lantai - Papan Teras", "color": [166, 170, 168]}},
     "Porch deck 5'-8\" deep, wrapping the south-west corner.", ["Slab 'Dek Teras' (lantai) built in 'Teras'"])
POSTS = [(-65.25, -65.25), (18, -65.25), (102, -65.25), (186, -65.25), (270, -65.25), (353.5, -65.25), (-65.25, 15)]
step("add_posts", {"spec": dict(BRICK, building=B, group="Teras", name="Umpak Bata", style="square", size=m(16),
                                base_z=m(GRADE), height=m(13), points=pts(POSTS))},
     "Brick piers under the porch posts.", ["7 posts 'Umpak Bata 1..7' (square"])
step("add_posts", {"spec": dict(WHITE, building=B, group="Teras", name="Tiang Teras", style="turned", size=m(6.5),
                                base_z=m(DECK), height=m(99), foot=m(30), cap=m(8), points=pts(POSTS))},
     "Seven turned porch posts (detail 8/A4.0: about 6x6, 8'-0\" approx).", ["7 posts 'Tiang Teras 1..7' (turned"])
for name, a, b in (("Balok Teras Depan", (-68.5, -68.5), (356.5, -62)), ("Balok Teras Barat", (-68.5, -62), (-62, 84)),
                   ("Balok Teras Timur", (350, -62), (356.5, 12))):
    step("add_slab", {"spec": dict(WHITE, building=B, group="Teras", name=name, kind="struktur", top_z=m(102.5),
                                   thickness=m(7.5), **{"from": pt(a), "to": pt(b)})}, "Porch beam on the posts.", ["(struktur)"])
step("add_slab", {"spec": {"building": B, "group": "Teras", "name": "Pelat Screen Porch", "top_z": m(-12), "thickness": m(4),
                           "from": pt((96, 192)), "to": pt((168, 312)), "material": "Lantai - Beton", "color": [170, 170, 170]}},
     "Screen porch floor beside the kitchen.", ["Slab 'Pelat Screen Porch'"])
step("add_posts", {"spec": dict(WHITE, building=B, group="Teras", name="Tiang Screen Porch", style="square", size=m(5.5),
                                base_z=m(-12), height=m(104),
                                points=pts([(98.75, 194.75), (98.75, 224), (98.75, 263), (98.75, 309.25), (133, 309.25)]))},
     "Screen porch posts.", ["5 posts"])
for name, a, b in (("Balok Screen Porch Barat", (96, 192), (101.5, 312)), ("Balok Screen Porch Utara", (101.5, 306.5), (168, 312))):
    step("add_slab", {"spec": dict(WHITE, building=B, group="Teras", name=name, kind="struktur", top_z=m(WING),
                                   thickness=m(8), **{"from": pt(a), "to": pt(b)})}, "Screen porch beam.", ["(struktur)"])
STEPS = {"building": B, "group": "Teras", "base_z": m(GRADE), "rise": m(DECK - GRADE), "risers": 3, "width": m(48),
         "tread": m(11), "material": "Tangga - Bata", "color": [156, 91, 75]}
step("build_stairs", {"spec": dict(STEPS, name="Tangga Depan", start=pt((234, -90)), direction=90)},
     "Brick steps up to the porch at the front door (3 risers of 7 in).", ["3 risers of 0.1778 m, 2 treads"])
step("build_stairs", {"spec": dict(STEPS, name="Tangga Samping", start=pt((-90, 60)), direction=0)},
     "Brick steps at the west end of the porch.", ["3 risers of 0.1778 m, 2 treads"])

# ----------------------------------------------------------------- inside stairs
# A1.2: "14 R @ 7.7 in", up along the east wall, three winders in the north-east
# corner, two more treads west into the hall.
step("build_stairs", {"spec": {"building": B, "name": "Tangga", "start": pt((266.25, 71)), "direction": 90, "base_z": 0,
                               "rise": m(FF2), "risers": 14, "width": m(36.5), "tread": m(10), "waist": m(2),
                               "segments": [{"type": "flight", "treads": 8}, {"type": "winder", "turn": "left", "steps": 3},
                                            {"type": "flight", "treads": 2}],
                               "material": "Tangga - Kayu", "color": [168, 124, 82]}},
     "Winder stairs (A1.2, details 5-7/A4.0).", ["14 risers of 0.1959 m, 13 treads in 3 parts", "on +2.743 m"])
step("add_slab", {"spec": {"building": B, "floor": "Lantai 2", "name": "Platform Lemari", "top_z": m(FF2 + 36), "thickness": m(12),
                           "from": pt((247, 92)), "to": pt((284.5, 129)), "material": "Lantai - Kayu"}},
     "East bedroom closet on a 36 in raised platform over the stairs (detail 4/A4.0).", ["Slab 'Platform Lemari'"])

# ---------------------------------------------------------------------- outside
step("add_siding", {"spec": {"building": B, "style": "clapboard", "spacing": m(5), "corner_boards": m(4.5)}},
     "6 in clapboard on every outside face, corner boards (detail 3/A4.0). Inside walls must be listed as such.",
     ["corner boards"])
step("add_window_trim", {"spec": {"building": B, "shutter_material": "Jendela - Shutter Hijau", "shutter_color": [40, 66, 50]}},
     "Head trim, sill and operable shutters on all 15 windows.", ["added to 15 of 15 windows"])

# -------------------------------------------------------------------- furniture
# Not on the drawings except the bath fixtures (A1.1, A1.2): placed from the room walls.
step("place_furniture", {"spec": {"building": B, "floor": "Lantai 1", "base_z": 0, "items": [
    {"type": "toilet", "name": "Kloset Bawah", "at": pt((306, 89)), "size": pt((18, 28, 30)), "rotation": 90},
    {"type": "shower", "name": "Shower", "at": pt((336, 88)), "size": pt((32, 32, 4))},
    {"type": "sink", "name": "Wastafel Bawah", "at": pt((336, 26)), "size": pt((28, 20, 32)), "rotation": 180},
    {"type": "cabinet", "name": "Kabinet Dapur Utara", "at": pt((242, 296)), "size": pt((84, 24, 36))},
    {"type": "cabinet", "name": "Kabinet Dapur Timur", "at": pt((272, 258)), "size": pt((52, 24, 36)), "rotation": -90},
    {"type": "stove", "name": "Kompor", "at": pt((186, 295)), "size": pt((28, 26, 36))},
    {"type": "fridge", "name": "Kulkas", "at": pt((268, 212)), "size": pt((32, 32, 68))},
    {"type": "sofa", "name": "Sofa", "at": pt((70, 26)), "size": pt((80, 36, 34)), "rotation": 180},
    {"type": "table", "name": "Meja Kopi", "at": pt((70, 69)), "size": pt((40, 22, 16))},
    {"type": "table", "name": "Meja Makan", "at": pt((96, 136)), "size": pt((72, 36, 30))},
    {"type": "chair", "name": "Kursi Makan 1", "at": pt((80, 108)), "size": pt((16, 16, 36)), "rotation": 180},
    {"type": "chair", "name": "Kursi Makan 2", "at": pt((112, 108)), "size": pt((16, 16, 36)), "rotation": 180},
    {"type": "chair", "name": "Kursi Makan 3", "at": pt((80, 164)), "size": pt((16, 16, 36))},
    {"type": "chair", "name": "Kursi Makan 4", "at": pt((112, 164)), "size": pt((16, 16, 36))},
    {"type": "desk", "name": "Meja Side Room", "at": pt((-50, 116)), "size": pt((48, 24, 30)), "rotation": 90},
]}}, "Downstairs furniture and fixtures.", ["15 pieces placed in 'Lantai 1'"])
step("place_furniture", {"spec": {"building": B, "floor": "Lantai 2", "base_z": m(FF2), "items": [
    {"type": "bed", "name": "Kasur Barat", "at": pt((102, 46)), "size": pt((60, 80, 22)), "rotation": 180},
    {"type": "bed", "name": "Kasur Timur", "at": pt((206, 46)), "size": pt((60, 80, 22)), "rotation": 180},
    {"type": "bathtub", "name": "Bathtub", "at": pt((20, 157)), "size": pt((30, 60, 20))},
    {"type": "sink", "name": "Wastafel Atas", "at": pt((76, 138)), "size": pt((28, 20, 32)), "rotation": 180},
    {"type": "toilet", "name": "Kloset Atas", "at": pt((51, 141)), "size": pt((18, 28, 30)), "rotation": 180},
]}}, "Upstairs furniture and fixtures.", ["5 pieces placed in 'Lantai 2'"])
step("check_placement", {"building": B, "accept": ["Pintu UW-1"]},
     "Stairs and furniture against doors and walls. Pintu UW-1 is the closet under the stairs, accepted as designed.",
     ["PLACEMENT OK"])

# ------------------------------------------------------------------------- site
step("add_slab", {"spec": {"kind": "tapak", "name": "Halaman Rumput", "top_z": m(GRADE), "thickness": m(4),
                           "from": pt((-3000, -3000)), "to": pt((3300, 3300)), "material": "Tapak - Rumput", "color": [91, 121, 61]}},
     "Lawn at grade.", ["Slab 'Halaman Rumput' (tapak) built in 'Tapak'"])
step("add_slab", {"spec": {"kind": "tapak", "name": "Setapak Depan", "top_z": m(GRADE + 1), "thickness": m(1),
                           "from": pt((216, -520)), "to": pt((252, -90)), "material": "Tapak - Batu Setapak", "color": [225, 220, 205]}},
     "Front path to the steps.", ["Slab 'Setapak Depan'"])
SHRUBS = [(-39, -100, 47), (41, -96, 54), (120, -97, 53), (300, -95, 52), (380, -100, 43), (-109, 30, 52), (-110, 129, 51),
          (401, 60, 52), (331, 250, 52)]
TREES = [(-331, 261, 180, 300), (-685, 90, 160, 260), (820, 750, 200, 320), (615, -266, 170, 280), (124, 621, 200, 340),
         (-519, 641, 190, 300)]
step("add_plants", {"spec": {"base_z": m(GRADE), "items":
                             [{"type": "shrub", "at": pt((x, y)), "size": m(d)} for x, y, d in SHRUBS] +
                             [{"type": "tree", "at": pt((x, y)), "size": m(d), "height": m(h)} for x, y, d, h in TREES]}},
     "Shrubs around the porch and a few trees (free placement, not on the drawings).", ["15 plants placed in 'Tapak'"])

# ----------------------------------------------------------------------- scenes
step("eval_ruby", {"code": "SU_MCP.audit_model"}, "House rules audit.", ["AUDIT OK"])
step("add_plan_view", {"spec": {"name": "Denah Lantai 1", "building": B, "floor": "Lantai 1", "set_units": False, "rooms": [
    {"label": "Living Room", "at": [3.556, 2.286]}, {"label": "Kitchen", "at": [5.79, 6.35]},
    {"label": "Side Room", "at": [-0.864, 3.302]}, {"label": "Bath", "at": [8.128, 1.524]}]}},
     "Dimensioned downstairs plan.", ["Plan view 'Denah Lantai 1' created"])
step("add_plan_view", {"spec": {"name": "Denah Lantai 2", "building": B, "floor": "Lantai 2", "base_z": m(FF2), "set_units": False,
                                "rooms": [{"label": "Bedroom", "at": [1.778, 1.524]}, {"label": "Bedroom", "at": [5.588, 1.143]},
                                          {"label": "Bath", "at": [1.143, 3.937]}, {"label": "Hall", "at": [4.318, 4.318]}]}},
     "Dimensioned upstairs plan.", ["Plan view 'Denah Lantai 2' created"])
for name, eye, target, extra in (
        ("Depan", (-330, -470, 210), (130, 60, 100), {}),
        ("Belakang", (560, 760, 230), (140, 160, 100), {}),
        ("Potongan Lantai 1", (40, -260, 560), (150, 120, 0), {"cut_z": m(96)}),
        ("Potongan Lantai 2", (60, -230, 640), (150, 90, 108), {"cut_z": m(196)}),
        ("Tampak Selatan", (144, -900, 110), (144, 0, 110), {"height": m(420), "hide": ["tapak"]}),
        ("Tampak Utara", (144, 1300, 110), (144, 0, 110), {"height": m(420), "hide": ["tapak"]})):
    step("add_scene", {"spec": dict({"name": name, "eye": pt(eye), "target": pt(target)}, **extra)},
         "Scene for the picture set.", ["Scene '%s' saved" % name])
step("export_views", {}, "All pictures, last of all. Look at every one of them.", ["VIEWS EXPORTED. 9 scene(s)"])

out = {
    "title": "Caroline's Farmhouse",
    "source": "Caroline's Farmhouse - The Original Starter Farmhouse Plans, a design by Jay Osborne, "
              "FreeFarmhouse.com. Licensed CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). "
              "This file is derived from those drawings and carries the same licence.",
    "units": "metres (converted from the inches on the drawings by make_steps.py)",
    "origin": "outside south-west corner of the 24 ft x 16 ft main house; x east, y north; z = 0 at the downstairs floor",
    "how": "Call the tools in order, each with its args, and read every reply; 'expect' lists text the reply must contain.",
    "steps": steps,
}
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "caroline.json")
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
    f.write("\n")
print("%d steps written to %s" % (len(steps), path))
