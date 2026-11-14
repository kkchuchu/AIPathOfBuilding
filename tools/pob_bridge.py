#!/usr/bin/env python3
"""Client for the Path of Building LiveBridge.

Sends a command to a running Path of Building instance and prints the JSON response.
Standard library only; works as a CLI and as an importable module.

CLI examples:
    python pob_bridge.py ping
    python pob_bridge.py getState
    python pob_bridge.py setLevel level=90
    python pob_bridge.py allocNode name="Elemental Equilibrium"
    python pob_bridge.py whatIfNodes '{"add": ["Heart of Thunder"]}'
    python pob_bridge.py addItem --text-file ring.txt slot="Ring 1"
    python pob_bridge.py state            # print summary.txt (no round trip)

Library example:
    from pob_bridge import PoBBridge
    pob = PoBBridge()
    print(pob.call("findNodes", query="life", type="Notable", limit=5))
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from pathlib import Path


def default_bridge_dir() -> Path:
    env = os.environ.get("POB_BRIDGE_DIR")
    if env:
        return Path(env)
    candidates = [
        Path.home() / "Documents" / "Path of Building" / "LiveBridge",
        Path.home() / "OneDrive" / "Documents" / "Path of Building" / "LiveBridge",
    ]
    for c in candidates:
        if c.exists():
            return c
    return candidates[0]


class BridgeError(RuntimeError):
    pass


class PoBBridge:
    def __init__(self, bridge_dir: str | os.PathLike | None = None, timeout: float = 30.0):
        self.dir = Path(bridge_dir) if bridge_dir else default_bridge_dir()
        self.timeout = timeout

    def send(self, cmd: str, args: dict | None = None, timeout: float | None = None) -> dict:
        """Send a command and return the full response envelope."""
        commands = self.dir / "commands"
        responses = self.dir / "responses"
        if not commands.is_dir():
            raise BridgeError(
                f"Bridge folder not found: {commands}\n"
                "Is Path of Building (with LiveBridge) running? Set POB_BRIDGE_DIR or pass --dir."
            )
        # Sortable, unique id: commands are processed in file-name order
        cmd_id = f"{time.time_ns()}-{uuid.uuid4().hex[:8]}"
        payload = json.dumps({"id": cmd_id, "cmd": cmd, "args": args or {}}, ensure_ascii=False)
        tmp = commands / f"{cmd_id}.json.tmp"
        tmp.write_text(payload, encoding="utf-8")
        tmp.replace(commands / f"{cmd_id}.json")

        response_file = responses / f"{cmd_id}.json"
        deadline = time.monotonic() + (timeout or self.timeout)
        while time.monotonic() < deadline:
            if response_file.exists():
                try:
                    data = json.loads(response_file.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, OSError):
                    time.sleep(0.05)
                    continue
                try:
                    response_file.unlink()
                except OSError:
                    pass
                return data
            time.sleep(0.05)
        raise BridgeError(f"Timed out waiting for a response to '{cmd}' (is the PoB window open?)")

    def call(self, cmd: str, **args):
        """Send a command and return its result, raising BridgeError on failure."""
        response = self.send(cmd, args)
        if not response.get("ok"):
            raise BridgeError(response.get("error", "unknown error"))
        return response.get("result")

    def state(self) -> dict:
        """Read the last exported state without a round trip."""
        return json.loads((self.dir / "stats.json").read_text(encoding="utf-8"))

    def summary(self) -> str:
        return (self.dir / "summary.txt").read_text(encoding="utf-8")


def _parse_value(v: str):
    try:
        return json.loads(v)
    except json.JSONDecodeError:
        return v


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Send a command to Path of Building LiveBridge.")
    parser.add_argument("command", help="command name (e.g. ping, getState, allocNode) or 'state' / 'summary'")
    parser.add_argument("args", nargs="*", help="a JSON object, and/or key=value pairs (values parsed as JSON when possible)")
    parser.add_argument("--dir", help="bridge folder (default: $POB_BRIDGE_DIR or Documents/Path of Building/LiveBridge)")
    parser.add_argument("--text-file", help="read the 'text' argument (e.g. an item) from this file")
    parser.add_argument("--timeout", type=float, default=30.0)
    ns = parser.parse_args(argv)

    bridge = PoBBridge(ns.dir, ns.timeout)
    if ns.command == "summary":
        print(bridge.summary(), end="")
        return 0
    if ns.command == "state":
        print(json.dumps(bridge.state(), indent=2, ensure_ascii=False))
        return 0

    args: dict = {}
    for a in ns.args:
        if a.lstrip().startswith("{"):
            args.update(json.loads(a))
        elif "=" in a:
            k, v = a.split("=", 1)
            args[k] = _parse_value(v)
        else:
            parser.error(f"Cannot parse argument '{a}' (use key=value or a JSON object)")
    if ns.text_file:
        args["text"] = Path(ns.text_file).read_text(encoding="utf-8")

    try:
        response = bridge.send(ns.command, args)
    except BridgeError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(json.dumps(response, indent=2, ensure_ascii=False))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
