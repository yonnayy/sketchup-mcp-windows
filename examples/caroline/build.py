"""Build Caroline's Farmhouse in the model that is open in SketchUp, by calling
the MCP tools listed in caroline.json one after the other, exactly as an AI
client would. Prints every reply and checks it against the step's "expect".

Open a NEW, EMPTY model in SketchUp first (the build does not clear anything).

    uv run --project . python examples/caroline/build.py            # all steps
    uv run --project . python examples/caroline/build.py --to 8     # stop after step 8
"""
import argparse
import asyncio
import json
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

HERE = os.path.dirname(os.path.abspath(__file__))


def reply_text(result) -> str:
    raw = result.content[0].text
    try:
        data = json.loads(raw)
    except ValueError:
        return raw
    if isinstance(data, dict):
        if isinstance(data.get("content"), list) and data["content"]:
            return data["content"][0].get("text", raw)
        if "result" in data:
            return str(data["result"])
        if "error" in data:
            return "ERROR: %s" % data["error"]
    return raw


async def run(first: int, last: int) -> int:
    with open(os.path.join(HERE, "caroline.json"), encoding="utf-8") as f:
        plan = json.load(f)
    failed = []
    params = StdioServerParameters(command=sys.executable, args=["-m", "sketchup_mcp"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            for step in plan["steps"]:
                if not first <= step["n"] <= last:
                    continue
                answer = reply_text(await session.call_tool(step["tool"], step["args"]))
                missing = [text for text in step["expect"] if text not in answer]
                print("%2d %-17s %s" % (step["n"], step["tool"], step["note"]))
                print("   " + answer.replace("\n", "\n   "))
                if missing or answer.startswith("Error") or answer.startswith("ERROR"):
                    failed.append(step["n"])
                    print("   !! expected: %s" % "; ".join(missing or ["no error"]))
    print()
    print("FAILED steps: %s" % failed if failed else "ALL STEPS AS EXPECTED")
    return 1 if failed else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="first", type=int, default=1)
    parser.add_argument("--to", dest="last", type=int, default=10 ** 6)
    args = parser.parse_args()
    sys.exit(asyncio.run(run(args.first, args.last)))
