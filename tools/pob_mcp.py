#!/usr/bin/env python3
"""pob-mcp: an MCP server for Path of Building (LiveBridge).

Exposes the LiveBridge commands of a running Path of Building as MCP tools, and the
exported build (summary.txt, stats.json, build.xml) as MCP resources, so that Claude
Desktop, Claude Code and other MCP clients can read and edit the open build.

Standard library only. Speaks MCP over stdio (newline-delimited JSON-RPC 2.0).

Claude Code:
    claude mcp add pob -e POB_BRIDGE_DIR=C:/pob-bridge -- python C:/path/to/tools/pob_mcp.py

Claude Desktop (claude_desktop_config.json):
    "mcpServers": {
      "pob": {
        "command": "python",
        "args": ["C:/path/to/tools/pob_mcp.py"],
        "env": {"POB_BRIDGE_DIR": "C:/pob-bridge"}
      }
    }
"""
from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pob_bridge import BridgeError, PoBBridge  # noqa: E402

SERVER_NAME = "pob-mcp"
SERVER_VERSION = "1.0.0"
SUPPORTED_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")

INSTRUCTIONS = """\
pob-mcp controls the build that is open in a running Path of Building (PoB 1, Path of Exile 1).
- Start with the pob://build/summary resource or getState to see the build.
- Before changing anything, preview it with whatIfNodes / whatIfItem / whatIfJewel and report the
  expected DPS / life / EHP difference. These never change the build.
- Never call openBuild, newBuild, importBuild, importCharacter (with newBuild=false), resetTree or
  setClass unless the user asked for it: they replace or wipe the open build.
- Commands that change the build return `diff` (before/after of the key stats that changed) and
  `keyStats`. Changes are not saved to disk until `save` is called.
- `ref` arguments take a passive node's numeric id or its name. Use findNodes to get exact ids,
  because many small passives share a name.
- Ascendancy nodes appear in findNodes / whatIfNodes results too; they spend ascendancy points,
  not regular passive points (check for an `ascendancy` field with getNode).
"""

# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------

STR = {"type": "string"}
INT = {"type": "integer"}
NUM = {"type": "number"}
BOOL = {"type": "boolean"}
REF = {"type": ["integer", "string"], "description": "Passive node id or name"}
REFS = {"type": "array", "items": {"type": ["integer", "string"]}, "description": "Passive node ids or names"}
STAT_NAMES = {"type": "array", "items": STR,
              "description": "Stat names to include in the diff (e.g. CombinedDPS, Life, TotalEHP). Default: key stats."}
SOCKET = {"type": ["integer", "string"],
          "description": "Jewel socket node id, slot name ('Jewel 26725') or the start of the socketed jewel's name"}
GEM = {
    "anyOf": [
        STR,
        {"type": "object", "properties": {
            "name": STR, "level": INT, "quality": INT, "enabled": BOOL,
            "skillPart": {"type": "integer", "description": "Skill part index, e.g. 2 for Tornado Shot's Combined Average Projectiles"},
        }, "required": ["name"]},
    ]
}


def d(text, **extra):
    return dict(extra, description=text)


def tool(name, description, props=None, required=None, *, read_only=False, destructive=False,
         open_world=False, title=None):
    schema = {"type": "object", "properties": props or {}}
    if required:
        schema["required"] = list(required)
    return {
        "name": name,
        "title": title or name,
        "description": description,
        "inputSchema": schema,
        "annotations": {
            "readOnlyHint": read_only,
            "destructiveHint": destructive,
            "openWorldHint": open_world,
        },
    }


TOOLS = [
    # Reading state
    tool("ping", "Check that Path of Building is running with LiveBridge. Returns mode, bridge version and PoB version.",
         read_only=True),
    tool("getState", "Summary of the open build: class, ascendancy, level, main skill, socket groups and gems, "
         "equipped items, passive point counts, keystones, notables and ~30 key stats.",
         {"allStats": d("Also include every calculated stat (several hundred)", **BOOL)}, read_only=True),
    tool("getStats", "Read calculated stats of the open build.",
         {"stats": d("Stat names to return; omit for all", type="array", items=STR)}, read_only=True),

    # Builds
    tool("listBuilds", "List the .xml build files in PoB's build folder (top level only).", read_only=True),
    tool("openBuild", "Open a saved build, replacing the open one in PoB. PoB auto-saves the outgoing build. "
         "Only when the user asks.", {"name": d("Build file name without .xml", **STR)}, ["name"], destructive=True),
    tool("newBuild", "Start a new empty build, replacing the open one. Only when the user asks.",
         {"name": STR}, destructive=True),
    tool("importBuild", "Replace the open build with a PoB build code or build XML, without confirmation. "
         "Only when the user asks. Use exportCode first to keep a way back.",
         {"code": d("PoB build code (Import/Export -> Generate)", **STR), "xml": d("Build XML", **STR), "name": STR},
         destructive=True),
    tool("importCharacter",
         "Import a character's passive tree, jewels, items and skills from its PUBLIC pathofexile.com profile. "
         "By default it goes into a new build (the open build is untouched); newBuild=false imports into the open "
         "build. Takes a few seconds.",
         {"account": d("Account name with discriminator, e.g. name#1234", **STR),
          "character": STR,
          "realm": d("pc (default), xbox, sony", **STR),
          "newBuild": d("Import into a new build (default true)", **BOOL),
          "name": d("Also save the result under this build file name", **STR),
          "deleteJewels": d("default true", **BOOL),
          "clearItems": d("default true", **BOOL),
          "clearSkills": d("default true", **BOOL),
          "ignoreWeaponSwap": d("default false", **BOOL)},
         ["account", "character"], destructive=True, open_world=True),
    tool("exportCode", "Get a shareable PoB build code for the open build (useful as a backup before experiments).",
         read_only=True),
    tool("save", "Save the open build to disk. `name` saves under a new file name in the build folder.",
         {"name": STR}),

    # Character
    tool("setLevel", "Set the character level (1-100). Turns off automatic level mode.",
         {"level": d("1-100", **INT)}, ["level"]),
    tool("setClass", "Change class, e.g. 'Witch'. RESETS THE PASSIVE TREE when the new class start is not connected.",
         {"class": STR}, ["class"], destructive=True),
    tool("setAscendancy", "Set the ascendancy, e.g. 'Elementalist' or 'None'. Switches class if needed.",
         {"ascendancy": STR}, ["ascendancy"]),

    # Passive tree
    tool("findNodes", "Search passive nodes by name and stat text. Sorted allocated first, then by distance; "
         "includes pointsToReach. Results can include ascendancy nodes.",
         {"query": STR,
          "type": d("Node type", type="string", enum=["Normal", "Notable", "Keystone", "Mastery", "Socket"]),
          "allocated": d("Only allocated (true) or unallocated (false) nodes", **BOOL),
          "limit": d("Max results (default 30)", **INT),
          "searchStats": d("Also search stat text (default true)", **BOOL)},
         read_only=True),
    tool("getNode", "Details of a passive node. For a mastery, also the available masteryOptions.",
         {"id": INT, "name": STR}, read_only=True),
    tool("whatIfNodes", "PREVIEW ONLY, does not change the build: before/after diff of allocating nodes "
         "(with their paths) and/or removing them.",
         {"add": REFS, "remove": REFS, "stats": STAT_NAMES}, read_only=True),
    tool("allocNode", "Allocate a passive node and the shortest path to it. A mastery needs `mastery` "
         "(effect id or text to match, e.g. 'Effect of Shock').",
         {"id": INT, "name": STR, "nodes": REFS, "mastery": {"type": ["integer", "string"]}}),
    tool("deallocNode", "Unallocate a node and every node that depends on it (like right-click).",
         {"id": INT, "name": STR, "nodes": REFS}),
    tool("resetTree", "Unallocate the whole passive tree. Only when the user asks.", destructive=True),
    tool("importTreeUrl", "Replace the passive tree with a pathofexile.com passive tree link.",
         {"url": STR}, ["url"], destructive=True),
    tool("exportTreeUrl", "Get a pathofexile.com passive tree link for the current tree.", read_only=True),

    # Items
    tool("listItems", "Equipped items by slot and every item in the build.",
         {"text": d("Also return the raw item text", **BOOL)}, read_only=True),
    tool("whatIfItem", "PREVIEW ONLY, does not change the build: diff for swapping an item into a slot. "
         "Returns an empty diff for cluster jewels; use whatIfJewel for those.",
         {"text": d("Item text as copied in-game with Ctrl+C or from a trade site", **STR),
          "slot": STR, "stats": STAT_NAMES}, ["text"], read_only=True),
    tool("addItem", "Add an item (in-game Ctrl+C text) to the build and, by default, equip it. Slot is auto-detected. "
         "Slots: Weapon 1, Weapon 2, Helmet, Body Armour, Gloves, Boots, Amulet, Ring 1, Ring 2, Belt, Flask 1-5.",
         {"text": STR, "slot": STR, "equip": d("default true", **BOOL)}, ["text"]),
    tool("equipItem", "Equip an item already in the build into a slot. itemId 0 empties the slot.",
         {"slot": STR, "itemId": INT}, ["slot", "itemId"]),
    tool("removeItem", "Delete an item from the build.", {"itemId": INT}, ["itemId"], destructive=True),

    # Jewels
    tool("listJewelSockets", "Allocated jewel sockets with their jewel and cluster passive counts.",
         {"all": d("Include unallocated sockets", **BOOL)}, read_only=True),
    tool("clusterNodes", "Passives a cluster jewel added (id, name, stats, allocated), with nested clusters.",
         {"socket": SOCKET}, ["socket"], read_only=True),
    tool("whatIfJewel", "PREVIEW ONLY, does not change the build: swap a jewel into a socket on a copy of the tree, "
         "allocate its passives and return the diff, pointsUsed and added passives.",
         {"socket": SOCKET, "text": STR, "itemId": INT,
          "allocate": d("'all' (default), 'none' or a list of passive names/ids",
                        anyOf=[STR, {"type": "array", "items": {"type": ["integer", "string"]}}]),
          "stats": STAT_NAMES}, ["socket"], read_only=True),
    tool("socketJewel", "Put a jewel in a socket (`text` adds it to the build first; itemId 0 empties it). "
         "Cluster passives that no longer line up are dropped; use allocClusterNodes to put them back.",
         {"socket": SOCKET, "text": STR, "itemId": INT}, ["socket"]),
    tool("allocClusterNodes", "Allocate every passive a cluster jewel added, or only the listed names/ids.",
         {"socket": SOCKET, "nodes": REFS}, ["socket"]),

    # Skills
    tool("listSkills", "Socket groups: index, label, slot, enabled, isMain, activeSkills, gems.", read_only=True),
    tool("addSkillGroup", "Add a socket group. Unknown gem names are returned in unknownGems.",
         {"gems": {"type": "array", "items": GEM}, "label": STR, "slot": STR, "main": BOOL}, ["gems"]),
    tool("editSkillGroup",
         "Edit a socket group. `gems` replaces all gems (each keeps the old same-named gem's skill part); "
         "`setGems` changes gems already in the group by name and fails without changes if a name is not found.",
         {"index": INT, "label": STR, "enabled": BOOL, "slot": STR,
          "gems": {"type": "array", "items": GEM},
          "setGems": {"type": "array", "items": GEM}},
         ["index"]),
    tool("removeSkillGroup", "Delete a socket group.", {"index": INT}, ["index"], destructive=True),
    tool("setMainSkill", "Set the main skill used for DPS (by group index or active skill name).",
         {"index": INT, "name": STR, "activeSkill": {"type": ["integer", "string"]}}),

    # Configuration
    tool("listConfig", "Configuration tab options with var, label, type, value and allowed options.",
         {"query": STR, "changedOnly": BOOL}, read_only=True),
    tool("setConfig", "Set Configuration options (checkboxes true/false, counts numbers, lists one of the options). "
         "`unset` restores defaults.",
         {"var": STR, "value": {"type": ["boolean", "number", "string"]},
          "values": {"type": "object", "additionalProperties": {"type": ["boolean", "number", "string"]}},
          "unset": {"type": "array", "items": STR}}),

    # UI
    tool("setView", "Switch PoB's visible tab.",
         {"tab": {"type": "string", "enum": ["tree", "skills", "items", "calcs", "config", "notes", "party", "import"]}},
         ["tab"]),
    tool("focusNode", "Show a passive node in the tree tab, centred and highlighted.",
         {"id": INT, "name": STR, "highlight": BOOL}),
    tool("notes", "Read the Notes tab, or replace its text when `text` is given.", {"text": STR}),
]
TOOL_NAMES = {t["name"] for t in TOOLS}

RESOURCES = [
    {"uri": "pob://build/summary", "name": "summary", "title": "Build summary",
     "description": "Seven-line summary of the open build", "mimeType": "text/plain", "file": "summary.txt"},
    {"uri": "pob://build/stats", "name": "stats", "title": "Build stats",
     "description": "Every calculated stat of the open build (stats.json)", "mimeType": "application/json",
     "file": "stats.json"},
    {"uri": "pob://build/xml", "name": "build-xml", "title": "Build XML",
     "description": "The open build in PoB's save format", "mimeType": "application/xml", "file": "build.xml"},
]


# ---------------------------------------------------------------------------
# JSON-RPC / MCP plumbing
# ---------------------------------------------------------------------------

class RpcError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


class Server:
    def __init__(self, bridge: PoBBridge):
        self.bridge = bridge

    # -- handlers --
    def initialize(self, params):
        requested = params.get("protocolVersion")
        version = requested if requested in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
        return {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}, "resources": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "title": "Path of Building", "version": SERVER_VERSION},
            "instructions": INSTRUCTIONS,
        }

    def tools_list(self, params):
        return {"tools": TOOLS}

    def tools_call(self, params):
        name = params.get("name")
        args = params.get("arguments") or {}
        if name not in TOOL_NAMES:
            raise RpcError(-32602, f"Unknown tool: {name}")
        try:
            response = self.bridge.send(name, args)
        except BridgeError as e:
            return {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True}
        if not response.get("ok"):
            return {"content": [{"type": "text", "text": f"error: {response.get('error', 'unknown error')}"}],
                    "isError": True}
        out = {k: response[k] for k in ("result", "diff", "keyStats") if k in response}
        return {"content": [{"type": "text", "text": json.dumps(out, ensure_ascii=False, indent=1)}]}

    def resources_list(self, params):
        return {"resources": [{k: v for k, v in r.items() if k != "file"} for r in RESOURCES]}

    def resources_read(self, params):
        uri = params.get("uri")
        res = next((r for r in RESOURCES if r["uri"] == uri), None)
        if res is None:
            raise RpcError(-32002, f"Resource not found: {uri}")
        path = self.bridge.dir / res["file"]
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as e:
            raise RpcError(-32603, f"Cannot read {path}: {e}. Is PoB running with LiveBridge?")
        return {"contents": [{"uri": uri, "mimeType": res["mimeType"], "text": text}]}

    METHODS = {
        "initialize": initialize,
        "ping": lambda self, p: {},
        "tools/list": tools_list,
        "tools/call": tools_call,
        "resources/list": resources_list,
        "resources/read": resources_read,
        "resources/templates/list": lambda self, p: {"resourceTemplates": []},
        "prompts/list": lambda self, p: {"prompts": []},
    }

    def handle(self, msg):
        """Return a response dict, or None for notifications / responses."""
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
            return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid request"}}
        method = msg.get("method")
        msg_id = msg.get("id")
        if method is None or "id" not in msg:
            return None  # a notification (e.g. notifications/initialized) or a response to us
        handler = self.METHODS.get(method)
        if handler is None:
            return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": f"Method not found: {method}"}}
        try:
            result = handler(self, msg.get("params") or {})
        except RpcError as e:
            return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": e.code, "message": str(e)}}
        except Exception as e:  # keep the server alive
            traceback.print_exc(file=sys.stderr)
            return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32603, "message": f"Internal error: {e}"}}
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}

    def serve(self, stdin, stdout):
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                reply = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
            else:
                if isinstance(msg, list):  # JSON-RPC batch (protocol 2025-03-26)
                    reply = [r for r in (self.handle(m) for m in msg) if r is not None] or None
                else:
                    reply = self.handle(msg)
            if reply is not None:
                stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
                stdout.flush()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="MCP server for Path of Building LiveBridge (stdio).")
    parser.add_argument("--dir", help="bridge folder (default: $POB_BRIDGE_DIR or Documents/Path of Building/LiveBridge)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for PoB per command")
    ns = parser.parse_args(argv)

    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    print(f"{SERVER_NAME} {SERVER_VERSION}: bridge folder {PoBBridge(ns.dir).dir}", file=sys.stderr)
    Server(PoBBridge(ns.dir, ns.timeout)).serve(sys.stdin, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
