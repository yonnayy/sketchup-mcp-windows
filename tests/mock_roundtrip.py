"""Self-check that needs no SketchUp.

Starts a fake SketchUp socket server on 127.0.0.1:9876, launches the real
`sketchup-mcp` stdio server, and makes several tool calls in a row. Every
answer must belong to the request that asked for it (the upstream bug shifted
all answers by one after the first call).

Run:  uv run --project . python tests/mock_roundtrip.py
"""
import asyncio
import json
import socket
import sys
import threading

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

PORT = 9876


def fake_sketchup(ready: threading.Event, stop: threading.Event) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(5)
    srv.settimeout(0.2)
    ready.set()
    clients = {}
    while not stop.is_set():
        try:
            conn, _ = srv.accept()
            conn.settimeout(0.05)
            clients[conn] = b""
        except socket.timeout:
            pass
        for conn in list(clients):
            try:
                chunk = conn.recv(4096)
                if not chunk:
                    raise ConnectionError
                clients[conn] += chunk
            except socket.timeout:
                pass
            except OSError:
                clients.pop(conn, None)
                continue
            while b"\n" in clients[conn]:
                line, clients[conn] = clients[conn].split(b"\n", 1)
                if not line.strip():
                    continue
                req = json.loads(line)
                if req.get("method") == "ping":
                    continue  # same behaviour as the patched extension
                params = req.get("params", {})
                name = params.get("name")
                args = params.get("arguments", {})
                text = "echo:%s:%s" % (name, args.get("code", ""))
                resp = {
                    "jsonrpc": "2.0",
                    "id": req.get("id"),
                    "result": {
                        "content": [{"type": "text", "text": text}],
                        "isError": False,
                        "success": True,
                        "resourceId": None,
                    },
                }
                conn.sendall(json.dumps(resp).encode() + b"\n")
    srv.close()


async def run() -> int:
    params = StdioServerParameters(command=sys.executable, args=["-m", "sketchup_mcp"])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = sorted(t.name for t in (await session.list_tools()).tools)
            print("tools:", tools)
            expected = ["build_floor_plan", "check_dimension_chains", "create_component", "delete_component", "eval_ruby",
                        "export_scene", "get_selection", "set_material",
                        "transform_component", "verify_dimensions"]
            assert tools == expected, tools
            chains = await session.call_tool("check_dimension_chains", {"chains": [
                {"label": "cocok", "segments": [1.0, 0.9, 0.5, 1.5, 2.1], "total": 6.0},
                {"label": "bentrok", "segments": [3.0, 2.9], "total": 6.0},
            ]})
            report = chains.content[0].text
            print(report)
            assert report.startswith("CHAINS CONFLICT. 1 of 2"), report
            assert "OK             cocok" in report and "KONFLIK        bentrok" in report and "-100 mm" in report, report
            for i in range(5):
                code = "marker_%d" % i
                res = await session.call_tool("eval_ruby", {"code": code})
                body = json.loads(res.content[0].text)
                print("call", i, "->", body)
                assert body == {"success": True, "result": "echo:eval_ruby:" + code}, body
                sel = await session.call_tool("get_selection", {})
                assert "echo:get_selection:" in sel.content[0].text, sel.content[0].text
    print("OK: 10 calls, every response matched its request")
    return 0


def port_in_use() -> bool:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.settimeout(0.5)
    try:
        return probe.connect_ex(("127.0.0.1", PORT)) == 0
    finally:
        probe.close()


def main() -> int:
    if port_in_use():
        print("Port 9876 is already in use (SketchUp is running). "
              "Close SketchUp to run this mock test, or use tests/live_floor_plan.py instead.")
        return 2
    ready, stop = threading.Event(), threading.Event()
    t = threading.Thread(target=fake_sketchup, args=(ready, stop), daemon=True)
    t.start()
    ready.wait(5)
    try:
        return asyncio.run(run())
    finally:
        stop.set()
        t.join(2)


if __name__ == "__main__":
    sys.exit(main())
