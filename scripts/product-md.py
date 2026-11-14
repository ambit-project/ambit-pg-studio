#!/usr/bin/env python3
"""Regenerates PRODUCT.md, PRODUCT-2.0.md and PRODUCT-3.0.md (projects "ambit.pg-studio.app", "... 2.0", "... 3.0") from
the SDD projects in the local wiki (MCP at 127.0.0.1:9494/mcp). The wiki is the source of truth; the files mirror it.
Usage: scripts/product-md.py"""
import json
import pathlib
import urllib.request

PROJECTS = {
    "ambit.pg-studio.app": "PRODUCT.md",
    "ambit.pg-studio.app 2.0": "PRODUCT-2.0.md",
    "ambit.pg-studio.app 3.0": "PRODUCT-3.0.md",
}
URL = "http://127.0.0.1:9494/mcp"


def call(name, args):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}})
    req = urllib.request.Request(URL, body.encode(), {"Content-Type": "application/json",
                                                     "Accept": "application/json, text/event-stream"})
    out = urllib.request.urlopen(req).read().decode()
    data = json.loads(next(line[6:] for line in out.splitlines() if line.startswith("data: ")))
    result = data["result"]
    text = "".join(c.get("text", "") for c in result.get("content", []))
    if result.get("isError"):
        raise SystemExit(f"{name}: {text}")
    return json.loads(text)


for PROJECT, FILE in PROJECTS.items():
    product = call("sdd_read_product", {"project": PROJECT})
    specs = call("sdd_list_specs", {"project": PROJECT})
    p, items = product["project"], product["product"]

    lines = [f"# {p['name']} - PRODUCT", "",
             f"Mirror of the SDD project \"{p['name']}\" (http://127.0.0.1:9494/wiki/sdd) - the wiki is the source of truth;",
             "regenerate with `scripts/product-md.py`. Content in Polish (the wiki's language).", "",
             f"Stage: **{p['stage']}**", ""]


    def section(title, key, fmt):
        rows = items.get(key) or []
        if rows:
            lines.extend([f"## {title}", ""])
            lines.extend(fmt(r) for r in rows)
            lines.append("")


    section("Cele (co ma udowodnić)", "whatItProves", lambda r: f"- {r['text']}\n  - Done when: {r['doneWhen']}")
    section("Nigdy", "nonGoalsNotEver", lambda r: f"- {r['text']}")
    section("Jeszcze nie", "nonGoalsNotYet", lambda r: f"- {r['text']}")
    section("Decyzje", "decisions", lambda r: f"- {r['text']}\n  - Dlaczego: {r['rationale']}"
            + (f"\n  - Wrócić, gdy: {r['revisitWhen']}" if r.get("revisitWhen") else ""))
    section("Stop", "stops", lambda r: f"- {r['text']}")
    section("Działa dziś", "worksToday", lambda r: f"- {r['text']}")
    section("W toku", "inProgress", lambda r: f"- {r['text']}")
    section("Dalej", "next", lambda r: f"- {r['text']}")

    lines.extend(["## Specyfikacje", "", "| Nr | Tytuł | Status | Kryteria Passed |", "|---|---|---|---|"])
    for s in specs:
        lines.append(f"| {s['number']:03d} | {s['title']} | {s['status']} | {s['criteriaPassed']}/{s['criteriaCount']} |")
    lines.append("")

    path = pathlib.Path(__file__).resolve().parent.parent / FILE
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"written {path}")
