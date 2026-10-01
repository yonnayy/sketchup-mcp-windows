from mcp.server.fastmcp import FastMCP, Context
import socket
import select
import json
import asyncio
import logging
from dataclasses import dataclass
from contextlib import asynccontextmanager
from typing import AsyncIterator, Dict, Any, List, Optional

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("SketchupMCPServer")

# Define version directly to avoid pkg_resources dependency
__version__ = "0.8.0"
logger.info(f"SketchupMCP Server version {__version__} starting up")

@dataclass
class SketchupConnection:
    host: str
    port: int
    sock: socket.socket = None
    # Seconds to wait for SketchUp's answer. Rendering a large model with
    # shadows to PNG takes longer than a normal call, so export raises it.
    timeout: float = 15.0
    
    def _is_alive(self) -> bool:
        """Report whether the cached socket is still usable.

        ``send(b'')`` always succeeds, so the old check never detected a
        closed peer. Ask the OS for a pending error and peek instead.
        """
        if not self.sock:
            return False
        try:
            if self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) != 0:
                return False
            readable, _, _ = select.select([self.sock], [], [], 0)
            if readable and not self.sock.recv(1, socket.MSG_PEEK):
                return False
        except OSError:
            return False
        return True

    def connect(self) -> bool:
        """Connect to the Sketchup extension socket server"""
        if self.sock:
            if self._is_alive():
                return True
            logger.info("Connection test failed, reconnecting...")
            self.disconnect()
            
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.connect((self.host, self.port))
            logger.info(f"Connected to Sketchup at {self.host}:{self.port}")
            return True
        except Exception as e:
            logger.error(f"Failed to connect to Sketchup: {str(e)}")
            self.sock = None
            return False
    
    def disconnect(self):
        """Disconnect from the Sketchup extension"""
        if self.sock:
            try:
                self.sock.close()
            except Exception as e:
                logger.error(f"Error disconnecting from Sketchup: {str(e)}")
            finally:
                self.sock = None

    def receive_full_response(self, sock, buffer_size=8192):
        """Receive the complete response, potentially in multiple chunks"""
        chunks = []
        sock.settimeout(self.timeout)
        
        try:
            while True:
                try:
                    chunk = sock.recv(buffer_size)
                    if not chunk:
                        if not chunks:
                            raise Exception("Connection closed before receiving any data")
                        break
                    
                    chunks.append(chunk)
                    
                    try:
                        data = b''.join(chunks)
                        json.loads(data.decode('utf-8'))
                        logger.info(f"Received complete response ({len(data)} bytes)")
                        return data
                    except json.JSONDecodeError:
                        continue
                except socket.timeout:
                    logger.warning("Socket timeout during chunked receive")
                    break
                except (ConnectionError, BrokenPipeError, ConnectionResetError) as e:
                    logger.error(f"Socket connection error during receive: {str(e)}")
                    raise
        except socket.timeout:
            logger.warning("Socket timeout during chunked receive")
        except Exception as e:
            logger.error(f"Error during receive: {str(e)}")
            raise
            
        if chunks:
            data = b''.join(chunks)
            logger.info(f"Returning data after receive completion ({len(data)} bytes)")
            try:
                json.loads(data.decode('utf-8'))
                return data
            except json.JSONDecodeError:
                raise Exception("Incomplete JSON response received")
        else:
            raise Exception("No data received within %d s (SketchUp may still be working on the request; check the model before repeating it)" % self.timeout)

    def send_command(self, method: str, params: Dict[str, Any] = None, request_id: Any = None) -> Dict[str, Any]:
        """Send a JSON-RPC request to Sketchup and return the response"""
        # Try to connect if not connected
        if not self.connect():
            raise ConnectionError("Not connected to Sketchup")
        
        # Ensure we're sending a proper JSON-RPC request
        if method == "tools/call" and params and "name" in params and "arguments" in params:
            # This is already in the correct format
            request = {
                "jsonrpc": "2.0",
                "method": method,
                "params": params,
                "id": request_id
            }
        else:
            # This is a direct command - convert to JSON-RPC
            command_name = method
            command_params = params or {}
            
            # Log the conversion
            logger.info(f"Converting direct command '{command_name}' to JSON-RPC format")
            
            request = {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {
                    "name": command_name,
                    "arguments": command_params
                },
                "id": request_id
            }
        
        # Maximum number of retries
        max_retries = 2
        retry_count = 0
        
        while retry_count <= max_retries:
            try:
                logger.info(f"Sending JSON-RPC request: {request}")
                
                # Log the exact bytes being sent
                request_bytes = json.dumps(request).encode('utf-8') + b'\n'
                logger.info(f"Raw bytes being sent: {request_bytes}")
                
                self.sock.sendall(request_bytes)
                logger.info(f"Request sent, waiting for response...")
                
                self.sock.settimeout(self.timeout)
                
                response_data = self.receive_full_response(self.sock)
                logger.info(f"Received {len(response_data)} bytes of data")
                
                response = json.loads(response_data.decode('utf-8'))
                logger.info(f"Response parsed: {response}")

                if not isinstance(response, dict):
                    return response

                if "error" in response:
                    logger.error(f"Sketchup error: {response['error']}")
                    raise Exception(response["error"].get("message", "Unknown error from Sketchup"))

                return response.get("result", {})
                
            except (socket.timeout, ConnectionError, BrokenPipeError, ConnectionResetError) as e:
                logger.warning(f"Connection error (attempt {retry_count+1}/{max_retries+1}): {str(e)}")
                retry_count += 1
                
                if retry_count <= max_retries:
                    logger.info(f"Retrying connection...")
                    self.disconnect()
                    if not self.connect():
                        logger.error("Failed to reconnect")
                        break
                else:
                    logger.error(f"Max retries reached, giving up")
                    self.sock = None
                    raise Exception(f"Connection to Sketchup lost after {max_retries+1} attempts: {str(e)}")
            
            except json.JSONDecodeError as e:
                logger.error(f"Invalid JSON response from Sketchup: {str(e)}")
                if 'response_data' in locals() and response_data:
                    logger.error(f"Raw response (first 200 bytes): {response_data[:200]}")
                raise Exception(f"Invalid response from Sketchup: {str(e)}")
            
            except Exception as e:
                logger.error(f"Error communicating with Sketchup: {str(e)}")
                self.sock = None
                raise Exception(f"Communication error with Sketchup: {str(e)}")

# Global connection management
_sketchup_connection = None

def get_sketchup_connection():
    """Get or create a persistent Sketchup connection"""
    global _sketchup_connection
    
    if _sketchup_connection is not None:
        # Never send a probe whose reply we do not read: it stays in the
        # socket buffer and is consumed as the answer to the NEXT request,
        # shifting every response by one.
        if _sketchup_connection.connect():
            return _sketchup_connection
        logger.warning("Existing connection is no longer valid")
        try:
            _sketchup_connection.disconnect()
        except Exception:
            pass
        _sketchup_connection = None
    
    if _sketchup_connection is None:
        _sketchup_connection = SketchupConnection(host="localhost", port=9876)
        if not _sketchup_connection.connect():
            logger.error("Failed to connect to Sketchup")
            _sketchup_connection = None
            raise Exception("Could not connect to Sketchup. Make sure the Sketchup extension is running.")
        logger.info("Created new persistent connection to Sketchup")
    
    return _sketchup_connection

@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[Dict[str, Any]]:
    """Manage server startup and shutdown lifecycle"""
    try:
        logger.info("SketchupMCP server starting up")
        try:
            sketchup = get_sketchup_connection()
            logger.info("Successfully connected to Sketchup on startup")
        except Exception as e:
            logger.warning(f"Could not connect to Sketchup on startup: {str(e)}")
            logger.warning("Make sure the Sketchup extension is running")
        yield {}
    finally:
        global _sketchup_connection
        if _sketchup_connection:
            logger.info("Disconnecting from Sketchup")
            _sketchup_connection.disconnect()
            _sketchup_connection = None
        logger.info("SketchupMCP server shut down")

# Create MCP server with lifespan support
mcp = FastMCP(
    "SketchupMCP",
    instructions=(
        "Controls a running SketchUp instance on this machine. "
        "To model a building from a floor plan use build_floor_plan (metres). "
        "For anything else beyond a primitive box, use eval_ruby with the SketchUp Ruby API. "
        "SketchUp's internal unit is the INCH: always write lengths as 3.m, 150.mm, 15.cm. "
        "Wrap edits in model.start_operation(name, true) / model.commit_operation so the user can undo in one step. "
        "A face drawn at z=0 gets a downward normal: call face.reverse! if face.normal.z < 0 before pushpull. "
        "House rules (docs/STANDARDS.md): one named group per building element, raw geometry untagged, "
        "a standard tag and an 'Elemen - Bahan' material on the group. build_floor_plan follows them; "
        "in eval_ruby create elements with SU_MCP.element(name, kind, parent) { |ents| ... } where kind is "
        "dinding, lantai, pintu, jendela, atap, struktur, tangga, furnitur, tapak or referensi, "
        "get the building container with SU_MCP.container(name), and finish with SU_MCP.audit_model "
        "(it must answer AUDIT OK). "
        "Accuracy workflow for a dimensioned plan: 1) check_dimension_chains on every dimension string and "
        "settle conflicts with the user BEFORE modelling; 2) build_floor_plan, giving each wall the reference "
        "the plan dimensions are measured to (ref center/left/right); 3) verify_dimensions against the plan "
        "and report the result to the user; 4) add_plan_view for a dimensioned plan drawing the user can "
        "compare with the original. "
        "Roofs and details have tools of their own (docs/DETAIL.md), in this order: build_roof, add_posts, "
        "add_siding, add_window_trim, build_stairs, place_furniture; use eval_ruby only for what they cannot do. "
        "Never guess coordinates for stairs or furniture: read them from the drawings, then run "
        "check_placement (it must answer PLACEMENT OK). "
        "While working, check yourself with export_scene(format='png') and look at the image. "
        "Pictures for the user come from export_views, run as the last step after the final change, "
        "and you look at every one of them before passing them on (docs/WORKFLOW.md)."
    ),
    lifespan=server_lifespan
)

# Tool endpoints
@mcp.tool()
def create_component(
    ctx: Context,
    type: str = "cube",
    position: List[float] = None,
    dimensions: List[float] = None
) -> str:
    """Create a primitive (type: cube, cylinder, sphere, cone) as a group.

    position and dimensions are in INCHES (SketchUp's internal unit).
    For a cylinder, position is the corner of its bounding box (not the
    centre) and dimensions are [diameter, ignored, height].
    A cube placed at z=0 extrudes DOWNWARD (z from -height to 0).
    For real modelling work prefer eval_ruby.
    """
    try:
        logger.info(f"create_component called with type={type}, position={position}, dimensions={dimensions}, request_id={ctx.request_id}")
        
        sketchup = get_sketchup_connection()
        
        params = {
            "name": "create_component",
            "arguments": {
                "type": type,
                "position": position or [0,0,0],
                "dimensions": dimensions or [1,1,1]
            }
        }
        
        logger.info(f"Calling send_command with method='tools/call', params={params}, request_id={ctx.request_id}")
        
        result = sketchup.send_command(
            method="tools/call",
            params=params,
            request_id=ctx.request_id
        )
        
        logger.info(f"create_component result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_component: {str(e)}")
        return f"Error creating component: {str(e)}"

@mcp.tool()
def delete_component(
    ctx: Context,
    id: str
) -> str:
    """Delete a component by ID"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "delete_component",
                "arguments": {"id": id}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error deleting component: {str(e)}"

@mcp.tool()
def transform_component(
    ctx: Context,
    id: str,
    position: List[float] = None,
    rotation: List[float] = None,
    scale: List[float] = None
) -> str:
    """Move, rotate or scale an entity by ID.

    position is a RELATIVE translation in inches (it is added to the
    current position, it is not an absolute target). rotation is in degrees.
    """
    try:
        sketchup = get_sketchup_connection()
        arguments = {"id": id}
        if position is not None:
            arguments["position"] = position
        if rotation is not None:
            arguments["rotation"] = rotation
        if scale is not None:
            arguments["scale"] = scale
            
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "transform_component",
                "arguments": arguments
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error transforming component: {str(e)}"

@mcp.tool()
def get_selection(ctx: Context) -> str:
    """List the entities the user currently has selected in SketchUp (id, type, bounds)."""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "get_selection",
                "arguments": {}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error getting selection: {str(e)}"

@mcp.tool()
def set_material(
    ctx: Context,
    id: str,
    material: str
) -> str:
    """Paint an entity with a named colour.

    Supported names: red, green, blue, yellow, cyan, magenta, white, black,
    brown, orange, gray. For any other colour use eval_ruby with
    Sketchup::Color.new(r, g, b).
    """
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "set_material",
                "arguments": {
                    "id": id,
                    "material": material
                }
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error setting material: {str(e)}"

@mcp.tool()
def export_scene(
    ctx: Context,
    format: str = "skp"
) -> str:
    """Export the current model. format: png, jpg, skp, obj, dae, stl.

    The file is written to the sketchup_exports folder inside %TEMP% and its full path is
    returned in content[0].text. Use format='png' to get a screenshot of the
    current view so you can check the model visually.
    """
    try:
        sketchup = get_sketchup_connection()
        sketchup.timeout = 120.0
        try:
            result = sketchup.send_command(
                method="tools/call",
                params={
                    "name": "export",
                    "arguments": {
                        "format": format
                    }
                },
                request_id=ctx.request_id
            )
        finally:
            sketchup.timeout = 15.0
        return json.dumps(result)
    except Exception as e:
        return f"Error exporting scene: {str(e)}"

@mcp.tool()
def build_floor_plan(
    ctx: Context,
    spec: Dict[str, Any]
) -> str:
    """Turn a floor plan into 3D walls, doors, windows and a floor slab, already
    tagged and given materials according to the house rules.

    All numbers are METRES. Coordinates are [x, y] on the ground plane.
    spec = {
      "building": "Rumah A",         # container group for the whole building
      "name": "Lantai 1",            # name of this floor's group
      "wall_height": 3.0,            # default height
      "wall_thickness": 0.15,        # default thickness
      "base_z": 0,                   # floor level (use 3.2 etc. for upper floors)
      "wall_ref": "center",          # default for "ref" below
      "walls": [                     # from/to line of each wall, see "ref"
        {"id": "W1", "from": [0, 0], "to": [6, 0]},
        {"id": "W2", "from": [6, 0], "to": [6, 4], "thickness": 0.1, "height": 2.8}
      ],
      "openings": [                  # offset = distance from the wall's "from"
        {"wall": "W1", "type": "door",   "offset": 1.0, "width": 0.9, "height": 2.1},
        {"wall": "W2", "type": "window", "offset": 1.2, "width": 1.5, "sill": 0.9, "height": 1.2}
      ],
      "slab": {"outline": [[0, 0], [6, 0], [6, 4], [0, 4]], "thickness": 0.12}
    }
    An opening with no "sill" (or sill 0) is a door; with a sill it is a window.
    Every opening becomes one unit (a container group "Pintu W1-1" or
    "Jendela W1-1"): doors get a 6/12 cm frame (Kusen) and a 3.5 cm leaf
    (Daun, "style": "panel" or "polos"); windows get a frame, sashes with
    glass ("leaves": n) or fixed glass ("fixed": true). The opening size is
    the hole in the wall, i.e. the OUTSIDE of the frame, so a 0.90 m door
    has a 0.78 m leaf. "frame_width"/"frame_depth" change the frame,
    "frame": false drops it, "infill": false leaves plain holes.
    Walls and slab accept "material": "Dinding - Bata Ekspos".
    Door swing: add "hinge": "start" | "end" (the jamb nearer the wall's
    `from` or `to`) and "swing": "left" | "right" (the side of the wall it
    opens into, as seen walking from `from` to `to`). The leaf is then drawn
    open ("open": degrees, default 90) with its swing arc on the floor.
    Without hinge/swing the leaf is drawn closed.
    "ref" on a wall says what its from/to line is: "center" (centreline,
    the default), "left" or "right" (that face of the wall, as seen walking
    from `from` to `to`; the wall body lies on the other side). Use the one
    the plan is dimensioned to, or the error equals the wall thickness:
    - outside dimensions of the building: trace the outline anticlockwise
      with "ref": "right";
    - clear (inside) dimensions of a room: trace the room anticlockwise
      with "ref": "left";
    - grid/axis dimensions: "center".
    Where walls meet, their ends are lengthened or trimmed automatically so
    corners close and walls do not overlap ("extend": false, a number, or
    [start, end] in metres overrides that for one wall).
    The whole plan is one undo step. The reply reports the built size and any
    opening that was skipped (for example because it does not fit the wall):
    read it, then call verify_dimensions and look at export_scene(format="png").
    """
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "build_floor_plan",
                "arguments": {"spec": spec}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error building floor plan: {str(e)}"

@mcp.tool()
def check_dimension_chains(
    chains: List[Dict[str, Any]],
    tolerance: float = 0.005
) -> str:
    """Check that the dimension strings on a plan add up, BEFORE modelling.

    chains = [
      {"label": "Sisi depan", "segments": [1.0, 0.9, 0.5, 1.5, 2.1], "total": 6.0},
      {"label": "Sisi kiri",  "segments": [3.0, 3.0], "total": 6.0}
    ]
    All numbers in metres. For every chain the segments are summed and compared
    with the overall dimension. Does not need SketchUp. If any chain is in
    conflict, show the user which one and ask which number wins; do not guess.
    """
    lines = []
    conflicts = 0
    for i, chain in enumerate(chains or []):
        label = str(chain.get("label") or f"chain {i + 1}")
        try:
            segments = [float(v) for v in chain.get("segments") or []]
            total = float(chain["total"])
        except (KeyError, TypeError, ValueError):
            conflicts += 1
            lines.append(f"TIDAK LENGKAP  {label}: needs \"segments\" (list of numbers) and \"total\"")
            continue
        added = sum(segments)
        diff = added - total
        parts = " + ".join(f"{v:g}" for v in segments)
        if abs(diff) <= tolerance:
            lines.append(f"OK             {label}: {parts} = {added:.3f} m, overall {total:.3f} m")
        else:
            conflicts += 1
            lines.append(
                f"KONFLIK        {label}: {parts} = {added:.3f} m, but overall says {total:.3f} m "
                f"({diff * 1000:+.0f} mm)"
            )
    if not lines:
        return "CHAINS FAILED. No chains given."
    if conflicts:
        head = (f"CHAINS CONFLICT. {conflicts} of {len(lines)} dimension strings do not add up. "
                "Ask the user which number is right before modelling.")
    else:
        head = f"CHAINS OK. All {len(lines)} dimension strings add up within {tolerance * 1000:.0f} mm."
    return head + "\n" + "\n".join(lines)

@mcp.tool()
def verify_dimensions(
    ctx: Context,
    checks: List[Dict[str, Any]],
    tolerance: float = 0.005
) -> str:
    """Measure the model in SketchUp and compare it with the plan (accuracy report).

    checks (metres) can mix three kinds:
      {"label": "Panjang luar", "overall": "x", "expected": 6.0}
          outside size of all walls along x or y; optional "building" and
          "floor" (group names) limit which walls are counted
      {"label": "Kamar tidur 1", "at": [1.5, 4.5], "expected": [2.8, 2.8]}
          clear room size through that point: [along x, along y]
      {"label": "Lebar koridor", "at": [3, 2], "axis": "y", "expected": 1.2}
          one clear distance; axis is "x", "y" or an angle in degrees
    "at" is any point inside the room, away from the walls. Clear distances
    are measured between wall faces (doors, glass and furniture are ignored;
    openings do not fool it). Add "z" (floor level) for upper floors. Leave
    "expected" out to just read a dimension.
    Every line is OK or SELISIH with the difference in mm. Run this after
    build_floor_plan with the key dimensions from the plan, fix what differs,
    and pass the report on to the user.
    """
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "verify_dimensions",
                "arguments": {"checks": checks, "tolerance": tolerance}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error verifying dimensions: {str(e)}"

@mcp.tool()
def add_plan_view(
    ctx: Context,
    spec: Dict[str, Any]
) -> str:
    """Create a dimensioned plan drawing of the built floor as a SketchUp scene.

    spec = {
      "name": "Denah Lantai 1",        # scene name
      "building": "Rumah A",           # optional: only this building's walls
      "floor": "Lantai 1",             # optional: only this floor's walls
      "base_z": 0,                     # floor level
      "cut_height": 1.2,               # horizontal cut above the floor
      "rooms": [                       # one point inside each room
        {"label": "Kamar Tidur 1", "at": [1.5, 4.5]},
        {"label": "Ruang Tamu", "at": [2.0, 2.5]}
      ]
    }
    Result: a top view in parallel projection, cut through the walls, with the
    two outside dimensions, the clear width and depth of every room (measured
    from the model, like verify_dimensions) and the room names. Annotations go
    on a tag of their own ("10-Anotasi <name>") and show only in this scene;
    the picture is framed on the requested building. A scene "3D" is added to
    go back. Model units are switched to metres with 2 decimals ("set_units":
    false keeps them). Calling it again with the same name replaces it.
    Follow with export_scene(format="png") and show the drawing to the user so
    they can compare it with the original plan.
    """
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "add_plan_view",
                "arguments": {"spec": spec}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error creating plan view: {str(e)}"

@mcp.tool()
def check_placement(
    ctx: Context,
    building: Optional[str] = None,
    clearance: float = 0.6,
    accept: Optional[List[str]] = None
) -> str:
    """Check stairs and furniture against doors and walls. Run it after placing
    anything inside a building, before showing the result.

    Every element on the tags 07-Tangga and 08-Furnitur is tested, by its real
    geometry, against:
      MENGHALANGI PINTU  it stands in the clear passage in front of or behind
                         a door (`clearance` metres either side of the frame)
      DI AYUNAN PINTU    it stands where the door leaf swings
      MENEMBUS DINDING   it goes into a wall by more than 1 cm
      PERIKSA            two placed elements share space (a note, not a failure)
    Each line names both elements and the point [x, y, z] in metres.
    `building` limits the check to one building container. `accept` is a list
    of texts (for example ["Pintu UW-1"]): findings containing one of them are
    listed as DITERIMA and do not fail the check. Use it only for a finding the
    user has agreed is intended, such as a closet door under the stairs.
    The reply starts with PLACEMENT OK or PLACEMENT CONFLICT. A conflict means
    the coordinates were wrong: go back to the drawing, move the element, run
    it again. Do not guess coordinates for stairs or furniture; read them from
    the plan first.
    """
    try:
        sketchup = get_sketchup_connection()
        arguments: Dict[str, Any] = {"clearance": clearance}
        if building:
            arguments["building"] = building
        if accept:
            arguments["accept"] = accept
        result = sketchup.send_command(
            method="tools/call",
            params={"name": "check_placement", "arguments": arguments},
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error checking placement: {str(e)}"

@mcp.tool()
def export_views(
    ctx: Context,
    scenes: Optional[List[str]] = None,
    folder: Optional[str] = None,
    width: int = 1920,
    height: int = 1080,
    check_only: bool = False
) -> str:
    """Export every scene of the model to PNG files in one folder, in one step.
    Make this the LAST step, after the final change to the model, so that no
    picture shows an older state than the model.

    Files are named "<scene number>-<scene name>.png" and overwrite the
    previous export, so the folder always holds one current set. Default
    folder: "<model name>-gambar" next to the saved .skp (a folder in %TEMP%
    when the model has never been saved). `scenes` limits the export to those
    scene names. Pictures are opaque; scenes in parallel projection (plans,
    elevations) are drawn on a white background without sky or ground.
    The model needs scenes first: add_plan_view makes plan scenes; for others
    set the camera in eval_ruby and call model.pages.add("Depan").
    check_only=True exports nothing and answers whether the last export still
    matches the model: VIEWS CURRENT, VIEWS STALE (the model changed since) or
    VIEWS UNKNOWN (never exported in this SketchUp session). Call it before
    showing pictures that were exported earlier. After exporting, open every
    picture and look at it before passing it on.
    """
    try:
        sketchup = get_sketchup_connection()
        arguments: Dict[str, Any] = {"width": width, "height": height, "check_only": check_only}
        if scenes:
            arguments["scenes"] = scenes
        if folder:
            arguments["folder"] = folder
        sketchup.timeout = 300.0
        try:
            result = sketchup.send_command(
                method="tools/call",
                params={"name": "export_views", "arguments": arguments},
                request_id=ctx.request_id
            )
        finally:
            sketchup.timeout = 15.0
        return json.dumps(result)
    except Exception as e:
        return f"Error exporting views: {str(e)}"

def _detail(ctx: Context, name: str, spec: Dict[str, Any], timeout: float = 120.0) -> str:
    """Send one of the detail tools (docs/DETAIL.md) to SketchUp."""
    try:
        sketchup = get_sketchup_connection()
        sketchup.timeout = timeout
        try:
            result = sketchup.send_command(
                method="tools/call",
                params={"name": name, "arguments": {"spec": spec}},
                request_id=ctx.request_id
            )
        finally:
            sketchup.timeout = 15.0
        return json.dumps(result)
    except Exception as e:
        return f"Error in {name}: {str(e)}"

@mcp.tool()
def build_roof(ctx: Context, spec: Dict[str, Any]) -> str:
    """Build a roof over a rectangular wall outline. All numbers are METRES.

    spec = {
      "building": "Rumah A",          # building container
      "type": "gable",                # gable | hip | shed | flat
      "from": [0, 0], "to": [8, 6],   # opposite corners of the OUTSIDE of the walls
      "base_z": 3.0,                  # top of the walls (underside of the roof at the wall line)
      "pitch": "7.5:12",              # rise:run, or a number (0.625), or "pitch_deg": 32
      "overhang": 0.3,                # eaves; "rake": overhang at the gable ends
      "thickness": 0.15,
      "ridge": "x",                   # gable: ridge direction (default: the longer side)
      "seams": 0.4,                   # standing-seam lines down the slope every 0.4 m (0 = none)
      "gable_walls": true,            # gable: fill the two triangles with walls (Ampig)
      "material": "Atap - Seng Abu", "color": [74, 80, 86],
      "name": "Atap Utama", "group": "Atap"   # element name, container inside the building
    }
    shed: "high_side": "north" | "south" | "east" | "west" is the side that
    meets the wall; give either "base_z" (underside at the low wall line) or
    "top_z" (underside at the high edge). "miter": {"start": true} cuts that
    end at 45 degrees so two shed roofs meet in a hip at an outside corner
    (wrap-around porch): give both the rectangle that runs out to the corner.
    The roof edge is painted white (fascia; "fascia": false to leave it).
    Calling it again with the same name replaces the roof. The reply gives the
    height of the top of the ridge: compare it with the drawing.
    L-shaped or cross-gabled roofs are several build_roof calls, one per wing.
    """
    return _detail(ctx, "build_roof", spec)

@mcp.tool()
def add_siding(ctx: Context, spec: Dict[str, Any]) -> str:
    """Draw cladding boards on the OUTSIDE faces of a building's walls, and
    corner boards where two outside faces meet. Metres.

    spec = {
      "building": "Rumah A",
      "floor": "Lantai 1",        # optional: only this floor's walls
      "style": "clapboard",       # clapboard (horizontal boards) | batten (vertical)
      "spacing": 0.125,           # board height; battens default to 0.4
      "corner_boards": 0.09,      # board width; false for none
      "only": ["W1"], "skip": ["W5"],   # wall ids, optional
      "force": ["W3"]             # clad every face of these walls, whatever the test says
    }
    Which faces are outside is found by looking out from each stretch of wall:
    a stretch that faces a room (or another wing built against it) gets no
    boards. Boards stop at door and window openings. The lines are drawn on
    the wall itself, so tags and materials stay as they are; set the wall
    colour with the wall's material in build_floor_plan. Run it BEFORE
    add_window_trim, and after all walls (and gable walls) exist. Running it
    again adds nothing twice. The reply lists the walls that were clad and
    those found to be inside walls: read it.
    """
    return _detail(ctx, "add_siding", spec)

@mcp.tool()
def add_window_trim(ctx: Context, spec: Dict[str, Any]) -> str:
    """Add a head trim, a sill and louvred shutters on the outside of every
    window made by build_floor_plan. Metres.

    spec = {
      "building": "Rumah A", "floor": "Lantai 1",   # floor optional
      "head": true, "sill": true, "shutters": true,
      "shutter_material": "Jendela - Shutter Hijau", "shutter_color": [38, 62, 48],
      "louvre": 0.035            # spacing of the louvre lines; 0 for plain panels
    }
    The parts go inside the window unit (Lis Atas, Lis Bawah, Shutter Kiri,
    Shutter Kanan), each shutter half the window wide. The outside is found by
    the same test as add_siding; a window with both sides open or both sides
    enclosed is skipped and named in the reply. Calling it again replaces the
    earlier trim.
    """
    return _detail(ctx, "add_window_trim", spec)

@mcp.tool()
def add_posts(ctx: Context, spec: Dict[str, Any]) -> str:
    """Stand posts (porch, veranda, carport) at the given points. Metres.

    spec = {
      "building": "Rumah A", "group": "Teras",   # container inside the building
      "points": [[0.1, -1.9], [2.7, -1.9]],      # centre of each post
      "base_z": 0, "height": 2.4, "size": 0.14,
      "style": "turned",                         # turned | square | round
      "foot": 0.75, "cap": 0.25,                 # turned: square parts at bottom and top
      "material": "Struktur - Kayu Putih", "color": [245, 245, 240],
      "name": "Tiang"                            # posts are named "Tiang 1", "Tiang 2", ...
    }
    Each post is one solid. Read the post positions and height from the
    drawings (elevation, porch plan). Calling it again with the same name
    replaces the posts.
    """
    return _detail(ctx, "add_posts", spec)

@mcp.tool()
def build_stairs(ctx: Context, spec: Dict[str, Any]) -> str:
    """Build a staircase from flights, winders and landings. Metres.

    spec = {
      "building": "Rumah A",
      "start": [6.5, 1.0],        # middle of the FIRST riser
      "direction": 90,            # walking direction in degrees: 0 = +x, 90 = +y
      "base_z": 0, "rise": 3.0,   # floor to floor
      "risers": 16,               # riser height = rise / risers
      "width": 0.9, "tread": 0.25,
      "segments": [               # walked in order, from the bottom
        {"type": "flight", "treads": 9},
        {"type": "winder", "turn": "left", "steps": 3},   # 90-degree turn in wedge steps
        {"type": "flight", "treads": 3}
      ],
      "material": "Tangga - Kayu", "color": [168, 124, 82], "name": "Tangga"
    }
    {"type": "landing", "turn": "left" | "right"} is a square quarter landing;
    {"type": "landing", "length": 1.0} a straight one. Each winder step and
    each landing counts as one tread. The treads of all segments must add up
    to risers - 1 (the floor above is the last tread); the reply warns if they
    do not. Without "segments" it is one straight flight.
    Take every number from the drawings (for example "14 R @ 7.7 in" and the
    stair plan); do not invent a staircase. The reply gives where the stair
    arrives and its footprint: the slab of the floor above must be open there,
    so leave that area out of its "slab" outline in build_floor_plan. Then run
    check_placement. Calling it again with the same name replaces the stairs.
    """
    return _detail(ctx, "build_stairs", spec)

@mcp.tool()
def place_furniture(ctx: Context, spec: Dict[str, Any]) -> str:
    """Place simple furniture and fixtures, then check them against doors and walls. Metres.

    spec = {
      "building": "Rumah A", "floor": "Lantai 1",   # container the pieces go into
      "base_z": 0,                                  # floor level
      "items": [
        {"type": "bed", "at": [1.2, 4.8]},                      # "at" = middle of the piece
        {"type": "sofa", "at": [5.2, 0.65], "rotation": 180},
        {"type": "table", "at": [5.2, 4.4], "size": [1.4, 0.8, 0.75], "name": "Meja Makan"}
      ]
    }
    Types (width x depth x height): bed 1.6x2.0x0.5, sofa 2.0x0.9x0.8, table
    1.6x0.9x0.75, chair 0.45x0.45x0.9, desk 1.2x0.6x0.75, cabinet 1.2x0.6x0.9,
    wardrobe 1.2x0.6x2.0, fridge 0.7x0.7x1.8, stove 0.6x0.6x0.9, toilet
    0.4x0.7x0.8, sink 0.6x0.5x0.85, bathtub 0.75x1.7x0.55, shower 0.9x0.9x0.08.
    Width runs along x and the BACK of the piece (headboard, sofa back, toilet
    tank) faces north (+y) at rotation 0; rotation is in degrees anticlockwise,
    so 180 puts the back to the south wall, 90 to the west, -90 to the east.
    "size", "name", "material" and "color" can be set per item. These are
    massing pieces for plans and cut-away views, not detailed models.
    Work the positions out from the room's walls, doors and windows (use
    verify_dimensions without "expected" to read a room), never from memory.
    The reply ends with the check_placement report: fix every conflict.
    A piece with the same name in the same container is replaced.
    """
    return _detail(ctx, "place_furniture", spec)

@mcp.tool()
def eval_ruby(
    ctx: Context,
    code: str
) -> str:
    """Run Ruby code inside SketchUp (full SketchUp Ruby API) and return the
    value of the last expression as a string.

    This is the main modelling tool. Rules that avoid the usual mistakes:
    - Lengths are inches internally. Write 3.m, 150.mm, 15.cm, never bare numbers.
    - model = Sketchup.active_model; wrap edits in
      model.start_operation('name', true) ... model.commit_operation.
    - A face on the ground plane (z=0) has its normal pointing down, so
      pushpull(+h) would go underground: face.reverse! if face.normal.z < 0.
    - Create each element with SU_MCP.element(name, kind, parent) { |ents| ... }
      so it gets the standard tag and material; parent = SU_MCP.container('Rumah A').
    - End with SU_MCP.audit_model; the work is done only when it says AUDIT OK.
    - Make the last expression a short summary string (counts, bounds) so you
      can verify the result. Calls time out after about 15 seconds, so split
      very large jobs into several calls.
    """
    try:
        logger.info(f"eval_ruby called with code length: {len(code)}")
        
        sketchup = get_sketchup_connection()
        
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "eval_ruby",
                "arguments": {
                    "code": code
                }
            },
            request_id=ctx.request_id
        )
        
        logger.info(f"eval_ruby result: {result}")
        
        # Format the response to include the result
        response = {
            "success": True,
            "result": result.get("content", [{"text": "Success"}])[0].get("text", "Success") if isinstance(result.get("content"), list) and len(result.get("content", [])) > 0 else "Success"
        }
        
        return json.dumps(response)
    except Exception as e:
        logger.error(f"Error in eval_ruby: {str(e)}")
        return json.dumps({
            "success": False,
            "error": str(e)
        })

def main():
    mcp.run()

if __name__ == "__main__":
    main()