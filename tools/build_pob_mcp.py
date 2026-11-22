#!/usr/bin/env python3
"""Build pob-mcp as a standalone Windows executable and as an MCP Bundle (.mcpb).

    python tools/build_pob_mcp.py            # exe + mcpb
    python tools/build_pob_mcp.py --exe-only

Needs (build machine only, not for users):
    pip install pyinstaller
    Node.js, for `npx @anthropic-ai/mcpb` (validate + pack)

Output (in build/pob-mcp/):
    pob-mcp.exe    standalone MCP server; no Python needed.
                   claude mcp add pob -e POB_BRIDGE_DIR=C:/pob-bridge -- C:/path/to/pob-mcp.exe
    pob-mcp.mcpb   Claude Desktop extension: double-click to install, pick the bridge folder.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO = TOOLS_DIR.parent
OUT = REPO / "build" / "pob-mcp"
MCPB_CLI = "@anthropic-ai/mcpb@2.1.2"

sys.path.insert(0, str(TOOLS_DIR))
import pob_mcp  # noqa: E402


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, shell=(sys.platform == "win32" and cmd[0] == "npx"))


def build_exe() -> Path:
    run([
        sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onefile", "--console",
        "--name", "pob-mcp",
        "--paths", str(TOOLS_DIR),
        "--distpath", str(OUT),
        "--workpath", str(OUT / "work"),
        "--specpath", str(OUT / "work"),
        str(TOOLS_DIR / "pob_mcp.py"),
    ])
    exe = OUT / "pob-mcp.exe"
    print(f"built {exe} ({exe.stat().st_size / 1e6:.1f} MB)")
    return exe


def manifest() -> dict:
    return {
        "manifest_version": "0.3",
        "name": "pob-mcp",
        "display_name": "Path of Building (LiveBridge)",
        "version": pob_mcp.SERVER_VERSION,
        "description": "Read and edit the build open in Path of Building: stats, passives, items, gems, "
                       "config, with what-if previews.",
        "long_description": "Connects Claude to a running Path of Building (PoE 1) through LiveBridge. "
                            "Path of Building must be the LiveBridge fork and be running; this extension only "
                            "reads and writes files in the bridge folder and opens no network ports.",
        "author": {"name": "kkchuchu", "url": "https://github.com/kkchuchu"},
        "repository": {"type": "git", "url": "https://github.com/kkchuchu/AIPathOfBuilding"},
        "documentation": "https://github.com/kkchuchu/AIPathOfBuilding/blob/dev/docs/live-bridge.md",
        "license": "MIT",
        "keywords": ["path of exile", "path of building", "poe", "build"],
        "server": {
            "type": "binary",
            "entry_point": "server/pob-mcp.exe",
            "mcp_config": {
                "command": "${__dirname}/server/pob-mcp.exe",
                "args": [],
                "env": {"POB_BRIDGE_DIR": "${user_config.bridge_dir}"},
            },
        },
        "user_config": {
            "bridge_dir": {
                "type": "directory",
                "title": "LiveBridge folder",
                "description": "Folder Path of Building writes the bridge files to (POB_BRIDGE_DIR when you start "
                               "PoB; by default Documents/Path of Building/LiveBridge).",
                "required": True,
                "default": "${HOME}/Documents/Path of Building/LiveBridge",
            },
        },
        "tools": [{"name": t["name"], "description": t["description"].split("\n")[0]} for t in pob_mcp.TOOLS],
        "compatibility": {"platforms": ["win32"]},
    }


def build_mcpb(exe: Path) -> Path:
    stage = OUT / "bundle"
    shutil.rmtree(stage, ignore_errors=True)
    (stage / "server").mkdir(parents=True)
    shutil.copy2(exe, stage / "server" / "pob-mcp.exe")
    (stage / "manifest.json").write_text(json.dumps(manifest(), indent=2, ensure_ascii=False), encoding="utf-8")
    run(["npx", "--yes", MCPB_CLI, "validate", str(stage / "manifest.json")])
    bundle = OUT / "pob-mcp.mcpb"
    run(["npx", "--yes", MCPB_CLI, "pack", str(stage), str(bundle)])
    return bundle


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--exe-only", action="store_true")
    ns = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    exe = build_exe()
    if not ns.exe_only:
        print(f"built {build_mcpb(exe)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
