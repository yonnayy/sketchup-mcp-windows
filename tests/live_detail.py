"""End-to-end test of the detail tools against a REAL SketchUp (extension
running, a model open).

Builds a one-room-and-a-half house 60 m away from the origin, then gives it a
gable roof with gable walls, a porch (posts and a shed roof), cladding boards
with corner boards, window trim with shutters, a staircase with a winder and
some furniture, checking every reply. One piece is put in front of a door on
purpose. Writes a PNG screenshot and removes everything it created.

Run:  uv run --project . python tests/live_detail.py
"""
import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

B = "MCP TEST DETAIL"
OX = 60.0

PLAN = {
    "building": B, "name": "Lantai 1", "wall_height": 3.0, "wall_thickness": 0.15,
    "walls": [
        {"id": "W1", "from": [OX, 0], "to": [OX + 8, 0], "ref": "right"},
        {"id": "W2", "from": [OX + 8, 0], "to": [OX + 8, 6], "ref": "right"},
        {"id": "W3", "from": [OX + 8, 6], "to": [OX, 6], "ref": "right"},
        {"id": "W4", "from": [OX, 6], "to": [OX, 0], "ref": "right"},
        {"id": "W5", "from": [OX + 4, 0], "to": [OX + 4, 6], "thickness": 0.1},
    ],
    "openings": [
        {"wall": "W1", "type": "door", "offset": 1.5, "width": 0.9, "height": 2.1, "hinge": "start", "swing": "left"},
        {"wall": "W1", "type": "window", "offset": 5.2, "width": 1.2, "sill": 0.9, "height": 1.2},
        {"wall": "W2", "type": "window", "offset": 2.4, "width": 1.2, "sill": 0.9, "height": 1.2},
        {"wall": "W3", "type": "window", "offset": 1.5, "width": 1.2, "sill": 0.9, "height": 1.2},
        {"wall": "W4", "type": "window", "offset": 2.4, "width": 1.2, "sill": 0.9, "height": 1.2},
        {"wall": "W5", "type": "door", "offset": 4.5, "width": 0.8, "height": 2.1, "hinge": "end", "swing": "right"},
    ],
    "slab": {"outline": [[OX, 0], [OX + 8, 0], [OX + 8, 6], [OX, 6]], "thickness": 0.12},
}
ROOF = {"building": B, "name": "Atap Utama", "type": "gable", "from": [OX, 0], "to": [OX + 8, 6], "base_z": 3.0,
        "pitch": "7.5:12", "overhang": 0.3, "rake": 0.25, "seams": 0.4, "gable_walls": True,
        "material": "Atap - Seng Abu", "color": [74, 80, 86]}
PORCH = {"building": B, "group": "Teras", "name": "Atap Teras", "type": "shed", "from": [OX, -2], "to": [OX + 8, 0],
         "high_side": "north", "top_z": 2.7, "pitch": "3:12", "overhang": 0.2, "rake": 0.2, "thickness": 0.08,
         "seams": 0.4, "material": "Atap - Seng Abu"}
POSTS = {"building": B, "points": [[OX + 0.1, -1.9], [OX + 2.7, -1.9], [OX + 5.3, -1.9], [OX + 7.9, -1.9]],
         "base_z": 0, "height": 2.2, "size": 0.14}
STAIRS = {"building": B, "start": [OX + 6.5, 1.0], "direction": 90, "rise": 3.0, "risers": 16, "width": 0.9,
          "tread": 0.25, "material": "Tangga - Kayu", "color": [168, 124, 82],
          "segments": [{"type": "flight", "treads": 9}, {"type": "winder", "turn": "left", "steps": 3},
                       {"type": "flight", "treads": 3}]}
FURNITURE = {"building": B, "floor": "Lantai 1", "items": [
    {"type": "bed", "at": [OX + 1.2, 4.8]},
    {"type": "wardrobe", "at": [OX + 3.55, 1.0], "rotation": -90},
    {"type": "table", "at": [OX + 5.2, 2.2], "name": "Meja Makan"},
    # On purpose: right behind the front door.
    {"type": "cabinet", "at": [OX + 1.9, 0.6], "rotation": 180},
]}

INSPECT = """
rumah = SU_MCP.container('%s')
count = lambda do |ents, test|
  ents.grep(Sketchup::Group).inject(0) { |sum, g| sum + (test.call(g) ? 1 : 0) + count.call(g.entities, test) }
end
solid = lambda do |name|
  found = []
  walk = lambda { |ents| ents.grep(Sketchup::Group).each { |g| found << g if g.name == name; walk.call(g.entities) } }
  walk.call(rumah.entities)
  found.first && found.first.manifold?
end
edges = rumah.entities.grep(Sketchup::Group).find { |g| g.name == 'Lantai 1' }.entities.grep(Sketchup::Group)
  .find { |g| g.name == 'Dinding W5' }.entities.grep(Sketchup::Edge).length
gable = rumah.entities.grep(Sketchup::Group).find { |g| g.name == 'Atap' }.entities.grep(Sketchup::Group)
  .find { |g| g.name == 'Atap Utama Ampig 1' }.entities.grep(Sketchup::Edge).length
"roof=#{solid.call('Atap Utama')} porch=#{solid.call('Atap Teras')} post=#{solid.call('Tiang 1')} flight=#{solid.call('Tangga 1 Lurus')} " \\
"winder=#{solid.call('Tangga 2 Putar 2')} board=#{solid.call('Papan Sudut 1')} shutters=#{count.call(rumah.entities, lambda { |g| g.name.start_with?('Shutter') })} " \\
"heads=#{count.call(rumah.entities, lambda { |g| g.name == 'Lis Atas' })} gable_edges=#{gable} inner_wall_edges=#{edges}"
""" % B

CAMERA = """
m = Sketchup.active_model
m.entities.active_section_plane = nil
m.active_view.camera = Sketchup::Camera.new([%f.m, -9.m, 6.m], [%f.m, 2.m, 1.8.m], [0, 0, 1], true, 38)
'ok'
""" % (OX - 6, OX + 4)

CLEANUP = """
model = Sketchup.active_model
model.start_operation('MCP TEST: bersihkan', true)
found = model.entities.grep(Sketchup::Group).select { |g| g.name == '%s' }
found.each(&:erase!)
model.commit_operation
model.materials.purge_unused
"removed #{found.length} building(s)"
""" % B


def text(result) -> str:
    return result.content[0].text


async def ruby(session, code: str) -> str:
    reply = json.loads(text(await session.call_tool("eval_ruby", {"code": code})))
    assert reply.get("success"), reply
    return reply["result"]


async def tool(session, name: str, spec: dict) -> str:
    reply = json.loads(text(await session.call_tool(name, {"spec": spec})))
    answer = reply["content"][0]["text"]
    print("%-16s: %s" % (name, answer))
    return answer


async def run() -> int:
    params = StdioServerParameters(command=sys.executable, args=["-m", "sketchup_mcp"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            names = [t.name for t in (await session.list_tools()).tools]
            for name in ("build_roof", "add_siding", "add_window_trim", "add_posts", "build_stairs", "place_furniture"):
                assert name in names, "tool %s is not offered" % name
            try:
                built = await tool(session, "build_floor_plan", PLAN)
                assert "5 walls, 2 doors, 4 windows, 1 slab" in built and "Warnings" not in built, built

                roof = await tool(session, "build_roof", ROOF)
                # 3.0 + 3.0 * 0.625 = 4.875 under the ridge, plus 0.15 * sqrt(1 + 0.625^2) of roof.
                assert "top of ridge at +5.052 m" in roof and "44 seam lines" in roof and "2 gable walls" in roof, roof
                again = await tool(session, "build_roof", ROOF)
                assert again.split("Group entityID")[0] == roof.split("Group entityID")[0], "rebuilding the roof changed it"

                posts = await tool(session, "add_posts", POSTS)
                assert posts.startswith("4 posts"), posts
                porch = await tool(session, "build_roof", PORCH)
                assert "(shed)" in porch and "underside of eave at +2.150 m" in porch, porch

                siding = await tool(session, "add_siding", {"building": B})
                assert "W1, W2, W3, W4, Atap Utama Ampig 1, Atap Utama Ampig 2" in siding, siding
                assert "4 corner boards" in siding and "No outside face found on: W5" in siding, siding
                again = await tool(session, "add_siding", {"building": B})
                assert " 0 lines" in again and "4 corner boards" in again, again

                trim = await tool(session, "add_window_trim", {"building": B})
                assert trim.startswith("Window trim (head, sill, shutters) added to 4 of 4 windows") and "Warnings" not in trim, trim

                stairs = await tool(session, "build_stairs", STAIRS)
                assert "16 risers of 0.1875 m, 15 treads in 3 parts" in stairs and "WARNING" not in stairs, stairs
                assert "lands at [%.3f, 3.700] on +3.000 m" % (OX + 5.3) in stairs, stairs
                short = await tool(session, "build_stairs", dict(STAIRS, segments=[{"type": "flight", "treads": 9}]))
                assert "WARNING: 9 treads were drawn but 16 risers need 15" in short, short
                await tool(session, "build_stairs", STAIRS)

                placed = await tool(session, "place_furniture", FURNITURE)
                assert "4 pieces placed in 'Lantai 1': Kasur 1, Lemari 1, Meja Makan, Kabinet 1." in placed, placed
                assert "PLACEMENT CONFLICT" in placed and "Kabinet 1 is inside the 0.60 m clear passage" in placed, placed
                assert placed.count("MENGHALANGI PINTU") == 1 and "MENEMBUS DINDING" not in placed, placed
                moved = await tool(session, "place_furniture", dict(FURNITURE, items=[
                    {"type": "cabinet", "at": [OX + 3.55, 3.0], "rotation": -90}]))
                assert "PLACEMENT OK" in moved, moved

                state = await ruby(session, INSPECT)
                print("inspect         :", state)
                assert state.startswith("roof=true porch=true post=true flight=true winder=true board=true shutters=8 heads=4"), state
                # The inside wall keeps its 12 box edges plus the door opening: no boards on it.
                assert int(state.rsplit("=", 1)[1]) < 40, state
                # A gable wall is a 9-edge prism; the boards across its outside face add many more.
                assert int(state.split("gable_edges=")[1].split()[0]) > 30, state

                audit = await ruby(session, "SU_MCP.audit_model")
                print("audit           :", audit.splitlines()[0])
                assert B not in audit, audit

                await ruby(session, CAMERA)
                shot = json.loads(text(await session.call_tool("export_scene", {"format": "png"})))
                print("png             :", shot["content"][0]["text"])
            finally:
                print("cleanup         :", await ruby(session, CLEANUP))
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
