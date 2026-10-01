"""End-to-end test against a REAL SketchUp (extension running, a model open).

Builds a small two-room house with build_floor_plan, checks the geometry with
eval_ruby and writes a PNG screenshot. Everything lands in one group named
"MCP TEST" - delete it (or press Ctrl+Z) afterwards.

Run:  uv run --project . python tests/live_floor_plan.py
"""
import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SPEC = {
    "name": "MCP TEST",
    "wall_height": 3.0,
    "wall_thickness": 0.15,
    "walls": [
        {"id": "W1", "from": [0, 0], "to": [7, 0]},
        {"id": "W2", "from": [7, 0], "to": [7, 5]},
        {"id": "W3", "from": [7, 5], "to": [0, 5]},
        {"id": "W4", "from": [0, 5], "to": [0, 0]},
        {"id": "W5", "from": [4, 0], "to": [4, 5], "thickness": 0.1, "extend": False},
    ],
    "openings": [
        {"wall": "W1", "type": "door", "offset": 1.0, "width": 0.9, "height": 2.1},
        {"wall": "W1", "type": "window", "offset": 4.8, "width": 1.5, "sill": 0.9, "height": 1.2},
        {"wall": "W2", "type": "window", "offset": 1.5, "width": 2.0, "sill": 0.9, "height": 1.2},
        {"wall": "W3", "type": "window", "offset": 4.5, "width": 1.2, "sill": 1.5, "height": 0.6},
        {"wall": "W5", "type": "door", "offset": 3.0, "width": 0.8, "height": 2.1},
        {"wall": "W4", "type": "window", "offset": 1.5, "width": 2.0, "sill": 0.9, "height": 1.2},
    ],
    "slab": {"outline": [[0, 0], [7, 0], [7, 5], [0, 5]], "thickness": 0.12},
}

INSPECT = r'''
root = Sketchup.active_model.entities.grep(Sketchup::Group).select { |g| g.name == "MCP TEST" }.last
rows = root.entities.grep(Sketchup::Group).map do |g|
  b = g.bounds
  "%s solid=%s x=%.2f..%.2f y=%.2f..%.2f z=%.2f..%.2f faces=%d" % [
    g.name, g.manifold?, b.min.x.to_m, b.max.x.to_m, b.min.y.to_m, b.max.y.to_m,
    b.min.z.to_m, b.max.z.to_m, g.entities.grep(Sketchup::Face).length]
end
rows.join("\n")
'''


def text(result) -> str:
    return result.content[0].text


async def run() -> int:
    params = StdioServerParameters(command=sys.executable, args=["-m", "sketchup_mcp"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            print("version :", text(await session.call_tool("eval_ruby", {"code": "Sketchup.version"})))
            built = text(await session.call_tool("build_floor_plan", {"spec": SPEC}))
            print("build   :", built)
            assert "5 walls, 6 openings" in built, built
            report = json.loads(text(await session.call_tool("eval_ruby", {"code": INSPECT})))["result"]
            print(report)
            assert "solid=false" not in report, "a wall or the slab is not a closed solid"
            await session.call_tool("eval_ruby", {"code": "Sketchup.send_action('viewIso:'); Sketchup.active_model.active_view.zoom_extents; 'ok'"})
            shot = text(await session.call_tool("export_scene", {"format": "png"}))
            print("png     :", shot)
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(run()))
