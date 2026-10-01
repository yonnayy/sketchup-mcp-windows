"""End-to-end test against a REAL SketchUp (extension running, a model open).

Builds a small two-room house with build_floor_plan, adds a roof through
eval_ruby with the SU_MCP helpers, then checks that every element is a closed
solid, that the model passes the house-rules audit (docs/STANDARDS.md), and
that the audit really reports deliberate violations. Writes a PNG screenshot
and finally removes everything it created (the "MCP TEST" container).

Run:  uv run --project . python tests/live_floor_plan.py
"""
import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SPEC = {
    "building": "MCP TEST",
    "name": "Lantai 1",
    "wall_height": 3.0,
    "wall_thickness": 0.15,
    # Outline traced anticlockwise on its OUTSIDE face, partition on its centreline.
    "walls": [
        {"id": "W1", "from": [0, 0], "to": [7, 0], "ref": "right"},
        {"id": "W2", "from": [7, 0], "to": [7, 5], "ref": "right"},
        {"id": "W3", "from": [7, 5], "to": [0, 5], "ref": "right"},
        {"id": "W4", "from": [0, 5], "to": [0, 0], "ref": "right"},
        {"id": "W5", "from": [4, 0], "to": [4, 5], "thickness": 0.1},
    ],
    "openings": [
        {"wall": "W1", "type": "door", "offset": 1.0, "width": 0.9, "height": 2.1, "hinge": "start", "swing": "left"},
        {"wall": "W1", "type": "window", "offset": 4.8, "width": 1.5, "sill": 0.9, "height": 1.2},
        {"wall": "W2", "type": "window", "offset": 1.5, "width": 2.0, "sill": 0.9, "height": 1.2},
        {"wall": "W3", "type": "window", "offset": 4.5, "width": 1.2, "sill": 1.5, "height": 0.6},
        {"wall": "W5", "type": "door", "offset": 3.0, "width": 0.8, "height": 2.1, "hinge": "end", "swing": "right"},
        {"wall": "W4", "type": "window", "offset": 1.5, "width": 2.0, "sill": 0.9, "height": 1.2},
    ],
    "slab": {"outline": [[0, 0], [7, 0], [7, 5], [0, 5]], "thickness": 0.12},
}

# The test house is built 50 m east of the origin so it cannot collide with
# (or be measured against) whatever the open model already contains.
OX = 50.0
for _wall in SPEC["walls"]:
    _wall["from"] = [_wall["from"][0] + OX, _wall["from"][1]]
    _wall["to"] = [_wall["to"][0] + OX, _wall["to"][1]]
SPEC["slab"]["outline"] = [[x + OX, y] for x, y in SPEC["slab"]["outline"]]

# Outside 7 x 5 m; rooms are what is left after 0.15 m outer walls and a
# 0.10 m partition on x = 4. Both rays cross door openings on purpose.
CHECKS = [
    {"label": "Panjang luar", "overall": "x", "expected": 7.0, "building": "MCP TEST"},
    {"label": "Lebar luar", "overall": "y", "expected": 5.0, "building": "MCP TEST"},
    {"label": "Ruang barat", "at": [OX + 2, 3.4], "expected": [3.8, 4.7]},
    {"label": "Ruang timur", "at": [OX + 5.5, 3.4], "expected": [2.8, 4.7]},
]

ROOF = r'''
model = Sketchup.active_model
model.start_operation('MCP TEST: atap', true)
rumah = SU_MCP.container('MCP TEST')
SU_MCP.element('Atap Datar', :atap, rumah) do |ents|
  face = ents.add_face([49.7.m, -0.3.m, 3.m], [57.3.m, -0.3.m, 3.m], [57.3.m, 5.3.m, 3.m], [49.7.m, 5.3.m, 3.m])
  face.reverse! if face.normal.z < 0
  face.pushpull(0.12.m)
end
model.commit_operation
'ok'
'''

INSPECT = r'''
rumah = SU_MCP.container('MCP TEST')
rows = []
walk = lambda do |ents|
  ents.grep(Sketchup::Group).each do |g|
    if g.entities.grep(Sketchup::Face).empty?
      walk.call(g.entities)
    else
      rows << "%s solid=%s tag=%s material=%s" % [g.name, g.manifold?, g.layer.name, g.material ? g.material.name : 'NONE']
    end
  end
end
walk.call(rumah.entities)
rows.join("\n")
'''

# Where the two open door leaves must be (world metres, x relative to OX):
# W1: hinge at x=1.0 on the inside face (y=0.15), opened 90 degrees into the house.
# W5: hinge at y=3.8 on the east face (x=4.05), opened 90 degrees into the east room.
DOORS = r'''
rumah = SU_MCP.container('MCP TEST')
lantai = rumah.entities.grep(Sketchup::Group).find { |g| g.name == 'Lantai 1' }
lantai.entities.grep(Sketchup::Group).select { |g| g.name.start_with?('Pintu') }.map do |g|
  b = g.bounds
  "%s x=%.2f..%.2f y=%.2f..%.2f" % [g.name, b.min.x.to_m - 50, b.max.x.to_m - 50, b.min.y.to_m, b.max.y.to_m]
end.join("\n")
'''

PLAN = {
    "name": "MCP TEST Denah",
    "building": "MCP TEST",
    "set_units": False,
    "rooms": [
        {"label": "Ruang barat", "at": [OX + 2, 3.4]},
        {"label": "Ruang timur", "at": [OX + 5.5, 3.4]},
    ],
}

PLAN_STATE = r'''
m = Sketchup.active_model
page = m.pages['MCP TEST Denah']
plane = m.entities.active_section_plane
view = m.active_view
# The whole test house (x 50..57, y 0..5) must be inside the picture even
# though the model may hold other buildings far away.
framed = [[50, 0], [57, 0], [57, 5], [50, 5]].all? do |x, y|
  s = view.screen_coords([x.m, y.m, 1.2.m])
  s.x > 0 && s.x < view.vpwidth && s.y > 0 && s.y < view.vpheight
end
"scene=%s selected=%s perspective=%s cut=%s annotations=%d framed=%s" % [
  !page.nil?, m.pages.selected_page == page, view.camera.perspective?,
  plane ? plane.name : 'none',
  m.entities.grep(Sketchup::Group).count { |g| g.name == 'Anotasi MCP TEST Denah' }, framed]
'''

PAGES_BEFORE = "Sketchup.active_model.pages.count.to_s"

VIOLATIONS = r'''
model = Sketchup.active_model
model.start_operation('MCP TEST: pelanggaran', true)
g = model.entities.add_group
g.entities.add_face([70.m, 0, 0], [71.m, 0, 0], [71.m, 1.m, 0], [70.m, 1.m, 0])
report = SU_MCP.audit_model
model.abort_operation
report
'''

CLEANUP = r'''
model = Sketchup.active_model
had_pages = %d
model.start_operation('MCP TEST: bersihkan', true)
found = model.entities.grep(Sketchup::Group).select { |g| ['MCP TEST', 'Anotasi MCP TEST Denah'].include?(g.name) }
found += model.entities.grep(Sketchup::SectionPlane).select { |s| s.name == 'MCP TEST Denah' }
count = found.length
found.each(&:erase!)
page = model.pages['MCP TEST Denah']
model.pages.erase(page) if page
tag = model.layers['10-Anotasi MCP TEST Denah']
model.layers.remove(tag) if tag
if had_pages == 0
  # The plan view added the "3D" scene itself; put the model back as it was.
  three_d = model.pages['3D']
  model.pages.selected_page = three_d if three_d
  model.pages.erase(three_d) if three_d
elsif model.pages['3D']
  model.pages.selected_page = model.pages['3D']
end
model.commit_operation
"removed #{count} objects, scenes left: #{model.pages.count}"
'''


def text(result) -> str:
    return result.content[0].text


async def ruby(session, code: str) -> str:
    reply = json.loads(text(await session.call_tool("eval_ruby", {"code": code})))
    assert reply.get("success"), reply
    return reply["result"]


async def run() -> int:
    params = StdioServerParameters(command=sys.executable, args=["-m", "sketchup_mcp"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            print("version :", await ruby(session, "Sketchup.version"))
            pages_before = int(await ruby(session, PAGES_BEFORE))
            try:
                built = text(await session.call_tool("build_floor_plan", {"spec": SPEC}))
                print("build   :", built)
                assert "5 walls, 2 doors, 4 windows, 1 slab" in built, built
                assert "Warnings" not in built, built
                assert "Size 7.0 x 5.0 x 3.12 m" in built, built

                measured = json.loads(text(await session.call_tool("verify_dimensions", {"checks": CHECKS})))
                verdict = measured["content"][0]["text"]
                print(verdict)
                assert verdict.startswith("VERIFY OK. 6 of 6"), verdict
                wrong = json.loads(text(await session.call_tool("verify_dimensions", {"checks": [
                    {"label": "sengaja salah", "at": [OX + 2, 3.4], "axis": "x", "expected": 4.0}]})))
                assert "SELISIH" in wrong["content"][0]["text"] and "-200 mm" in wrong["content"][0]["text"], wrong
                print("verify catches a wrong dimension: yes")

                await ruby(session, ROOF)
                report = await ruby(session, INSPECT)
                print(report)
                assert report.count("\n") + 1 == 13, "expected 13 elements (5 walls, 2 doors, 4 windows, slab, roof)"
                assert "solid=false" not in report, "an element is not a closed solid"
                assert "tag=Layer0" not in report and "material=NONE" not in report, "an element lacks tag or material"

                audit = await ruby(session, "SU_MCP.audit_model")
                print("audit   :", audit.splitlines()[0])
                assert "MCP TEST" not in audit, audit

                bad = await ruby(session, VIOLATIONS)
                assert bad.startswith("AUDIT FAILED") and "has no tag" in bad and "has no name" in bad, bad
                print("audit catches violations: yes")

                doors = await ruby(session, DOORS)
                print(doors)
                assert "Pintu W1-1 x=1.00..1.04 y=0.15..1.05" in doors, doors
                assert "Pintu W5-1 x=4.05..4.85 y=3.76..3.80" in doors, doors

                plan = json.loads(text(await session.call_tool("add_plan_view", {"spec": PLAN})))
                made = plan["content"][0]["text"]
                print("plan    :", made)
                assert "6 dimensions" in made and "Outside size 7.000 x 5.000 m" in made, made
                assert "Warnings" not in made, made
                state = await ruby(session, PLAN_STATE)
                print("scene   :", state)
                assert state == "scene=true selected=true perspective=false cut=MCP TEST Denah annotations=1 framed=true", state
                audit = await ruby(session, "SU_MCP.audit_model")
                assert "MCP TEST" not in audit, audit
                shot = json.loads(text(await session.call_tool("export_scene", {"format": "png"})))
                print("png     :", shot["content"][0]["text"])
            finally:
                print("cleanup :", await ruby(session, CLEANUP % pages_before))
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
