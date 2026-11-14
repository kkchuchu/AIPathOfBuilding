#!/usr/bin/env python3
"""End-to-end self-test for the Path of Building LiveBridge.

Start Path of Building first, then run:
    python tools/bridge_selftest.py [--dir BRIDGE_DIR]

WARNING: this creates a new unsaved build ("LiveBridge selftest") in the running
instance. Save your current build first. Nothing is written to your build folder.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pob_bridge import PoBBridge  # noqa: E402

RING = """Rarity: Rare
Storm Loop
Two-Stone Ring
--------
Item Level: 84
--------
+14% to Cold and Lightning Resistances (implicit)
--------
+45% to Fire Resistance
+40% to Cold Resistance
+38% to Lightning Resistance
+65 to maximum Life
Adds 5 to 60 Lightning Damage to Spells
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir")
    ns = ap.parse_args()
    pob = PoBBridge(ns.dir)
    failures = []

    def step(cmd, expect_ok=True, check=None, **args):
        r = pob.send(cmd, args)
        ok = r["ok"] == expect_ok
        if ok and check:
            try:
                ok = bool(check(r))
            except Exception:  # noqa: BLE001
                ok = False
        detail = r.get("error") if not r["ok"] else json.dumps(r.get("result"), ensure_ascii=False)[:100]
        print(f"{'PASS' if ok else 'FAIL'}  {cmd:<16} {detail}")
        if not ok:
            failures.append(cmd)
        return r

    def dps(r):
        return r.get("keyStats", {}).get("CombinedDPS", 0)

    step("ping", check=lambda r: r["result"]["pong"])
    step("newBuild", name="LiveBridge selftest")
    step("setClass", **{"class": "Witch"})
    step("setAscendancy", ascendancy="Elementalist", check=lambda r: r["result"]["ascendancy"] == "Elementalist")
    step("setLevel", level=90, check=lambda r: r["keyStats"]["Life"] > 1000)
    step("addSkillGroup", label="Main", main=True,
         gems=[{"name": "Arc", "level": 20, "quality": 20}, "Spell Echo Support", "Added Lightning Damage Support"],
         check=lambda r: "unknownGems" not in r["result"] and dps(r) > 0)
    step("listSkills", check=lambda r: len(r["result"]["groups"]) == 1)
    step("editSkillGroup", index=1, setGems=[{"name": "Arc", "level": 21}])
    step("setMainSkill", name="Arc")
    step("findNodes", query="lightning", type="Notable", limit=3, check=lambda r: r["result"]["total"] > 0)
    step("whatIfNodes", add=["Heart of Thunder"], check=lambda r: r["result"]["diff"]["CombinedDPS"]["change"] > 0)
    step("allocNode", name="Heart of Thunder", check=lambda r: r["diff"]["CombinedDPS"]["change"] > 0)
    step("getNode", name="Lightning Mastery", check=lambda r: len(r["result"]["masteryOptions"]) > 0)
    step("allocNode", name="Lightning Mastery", mastery="Maximum Effect of Shock")
    step("deallocNode", name="Heart of Thunder", check=lambda r: len(r["result"]["deallocated"]) == 1)
    step("allocNode", nodes=["Heart of Thunder", "Elemental Equilibrium"])
    step("whatIfItem", text=RING, slot="Ring 1", check=lambda r: r["result"]["diff"]["FireResist"]["change"] == 45)
    step("addItem", text=RING, slot="Ring 1", check=lambda r: r["result"]["equippedIn"] == "Ring 1")
    step("listItems", check=lambda r: len(r["result"]["equipped"]) == 1)
    step("listConfig", query="boss", check=lambda r: len(r["result"]["options"]) > 0)
    step("setConfig", var="enemyIsBoss", value="Pinnacle")
    step("setConfig", values={"conditionShockEffect": 30}, unset=["enemyIsBoss"],
         check=lambda r: r["result"]["unset"] == ["enemyIsBoss"])
    step("exportTreeUrl", check=lambda r: r["result"]["url"])
    code = step("exportCode")["result"]["code"]
    step("setView", tab="items")
    step("focusNode", name="Elemental Equilibrium")
    step("notes", text="Created by bridge_selftest.py")
    step("getState", check=lambda r: r["result"]["ascendancy"] == "Elementalist")
    step("importBuild", code=code, name="LiveBridge selftest (re-imported)")
    step("getState", check=lambda r: r["result"]["passives"]["keystones"] == ["Elemental Equilibrium"])
    step("listBuilds")
    # Error handling
    step("noSuchCommand", expect_ok=False)
    step("allocNode", expect_ok=False, name="No Such Node")
    step("save", expect_ok=False, name="../escape")
    step("addItem", expect_ok=False, text="not an item")

    state = pob.state()
    print(f"\nstats.json: {state['buildName']} / {state['ascendancy']} / CombinedDPS {state['keyStats'].get('CombinedDPS')}")
    print(f"{'ALL PASSED' if not failures else 'FAILED: ' + ', '.join(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
