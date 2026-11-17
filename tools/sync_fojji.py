#!/usr/bin/env python3
"""
Copy the data CraftProfit needs out of FojjiCore_Professions into CraftProfit/Data/FojjiData.lua.

    python tools/sync_fojji.py            (run from the CraftProfit folder, or anywhere)

Re-run after FojjiCore updates. Copies:
  * every recipe item sold by an NPC for gold: vendor name, zone, price, faction, limited stock, rep needed
  * vendor sell prices of profession items (used when the game hasn't cached the item yet)
The data stays on your PC - it's Fojji's (and seemeta / Wowhead / MetaForge's) work, don't redistribute it.
"""
import datetime
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ADDON = HERE.parent                                    # .../AddOns/CraftProfit
SRC = ADDON.parent / "FojjiCore_Professions" / "Data"  # .../AddOns/FojjiCore_Professions/Data
OUT = ADDON / "Data" / "FojjiData.lua"


# --------------------------------------------------------------------------
# tiny Lua table-literal parser (strings, numbers, nil/true/false, tables)
# --------------------------------------------------------------------------
TOKEN = re.compile(r"""
    \s+ | --[^\n]* |                                  # whitespace, comments (skipped)
    (?P<str>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*') |
    (?P<num>-?0x[0-9a-fA-F]+|-?\d+\.?\d*(?:[eE][-+]?\d+)?) |
    (?P<name>[A-Za-z_][A-Za-z_0-9]*) |
    (?P<sym>[{}\[\]=,;])
""", re.X)


def tokenize(text):
    """tokens of the first complete value only (stops when the outer table closes)"""
    pos, out, depth = 0, [], 0
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise SyntaxError(f"bad character at {pos}: {text[pos:pos+30]!r}")
        pos = m.end()
        kind = m.lastgroup
        if kind:
            out.append((kind, m.group(kind)))
            if m.group(kind) == "{":
                depth += 1
            elif m.group(kind) == "}":
                depth -= 1
            if depth == 0:
                break
    return out


def unquote(s):
    body = s[1:-1]
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


class Parser:
    def __init__(self, tokens):
        self.t, self.i = tokens, 0

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else (None, None)

    def take(self, val=None):
        tok = self.t[self.i]
        if val is not None and tok[1] != val:
            raise SyntaxError(f"expected {val!r}, got {tok!r}")
        self.i += 1
        return tok

    def value(self):
        kind, v = self.peek()
        if kind == "str":
            self.take(); return unquote(v)
        if kind == "num":
            self.take(); return float(v) if any(c in v for c in ".eE") and not v.startswith(("0x", "-0x")) else int(v, 0)
        if kind == "name":
            self.take(); return {"nil": None, "true": True, "false": False}.get(v, v)
        if v == "{":
            return self.table()
        raise SyntaxError(f"unexpected {v!r}")

    def table(self):
        self.take("{")
        arr, hsh = [], {}
        while self.peek()[1] != "}":
            k1, v1 = self.peek()
            if v1 == "[":
                self.take(); key = self.value(); self.take("]"); self.take("="); hsh[key] = self.value()
            elif k1 == "name" and self.peek(1)[1] == "=":
                self.take(); self.take("="); hsh[v1] = self.value()
            else:
                arr.append(self.value())
            if self.peek()[1] in (",", ";"):
                self.take()
        self.take("}")
        if hsh and arr:
            for n, v in enumerate(arr, 1):
                hsh[n] = v
            return hsh
        return hsh if hsh else arr


def read_assign(path, name):
    """value of `name = <table>` in a Lua file"""
    text = path.read_text(encoding="utf-8")
    m = re.search(r"^" + re.escape(name) + r"\s*=\s*", text, re.M)
    if not m:
        raise SystemExit(f"{name} not found in {path}")
    p = Parser(tokenize(text[m.end():]))
    return p.value()


def read_string(path, name):
    m = re.search(r"^" + re.escape(name) + r'\s*=\s*"([^"]*)"', path.read_text(encoding="utf-8"), re.M)
    return m.group(1) if m else "?"


# --------------------------------------------------------------------------
def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    recipes_file, items_file = SRC / "Recipes.lua", SRC / "Items.lua"
    for f in (recipes_file, items_file):
        if not f.exists():
            raise SystemExit(f"Not found: {f}\nIs FojjiCore_Professions installed next to CraftProfit?")

    build = read_string(recipes_file, "D.build")
    profs = read_assign(recipes_file, "D.profs")
    recipes = read_assign(recipes_file, "D.recipes")
    items = read_assign(items_file, "D.items")
    prof_name = {p["slug"]: p["name"] for p in profs}

    out_recipes, seen = [], set()
    for slug, lst in recipes.items():
        for r in lst:
            b = r.get("b")
            if not b or b in seen:
                continue
            vendors = []
            for s in r.get("src") or []:
                s = list(s) + [None] * (10 - len(s))
                # {"vendor", npcID, npcName, zone, _, priceCopper, side, limited, currencyText, reputation}
                if s[0] == "vendor" and isinstance(s[5], (int, float)) and s[5] > 0 and not s[8]:
                    vendors.append((s[2] or "?", s[3] or "?", int(s[5]), s[6] or "both", s[7] == 1, s[9] or ""))
            if not vendors:
                continue
            # same NPC listed twice (Fojji has dupes): keep one
            vendors = sorted(set(vendors), key=lambda v: (v[2], v[0]))
            seen.add(b)
            k = r.get("k") or [None]
            out_recipes.append((b, r.get("n") or "?", prof_name.get(slug, slug), k[0], vendors))
    out_recipes.sort(key=lambda x: (x[2], x[3] or 0, x[0]))

    sell = {iid: v[2] for iid, v in items.items()
            if isinstance(v, list) and len(v) >= 3 and isinstance(v[2], int)}

    lines = [
        "-- GENERATED by tools/sync_fojji.py from FojjiCore_Professions - do not edit, re-run the script.",
        f"-- Fojji data build {build}, synced {datetime.date.today().isoformat()}",
        "local _, ns = ...",
        "ns.FojjiData = {",
        f"    build = {lua_str(build)},",
        f"    synced = {lua_str(datetime.date.today().isoformat())},",
        "    -- { recipeItemID, spellName, profession, skill, { {npc, zone, priceCopper, side, limited, reputation?}, ... } }",
        "    recipes = {",
    ]
    for b, n, prof, skill, vendors in out_recipes:
        vs = ", ".join("{%s, %s, %d, %s, %s%s}" % (lua_str(v[0]), lua_str(v[1]), v[2], lua_str(v[3]),
                                                   "true" if v[4] else "false",
                                                   (", " + lua_str(v[5])) if v[5] else "") for v in vendors)
        lines.append("        { %d, %s, %s, %s, { %s } }," % (b, lua_str(n), lua_str(prof),
                                                          skill if skill is not None else "nil", vs))
    lines.append("    },")
    lines.append("    -- [itemID] = vendor sell price (copper)")
    lines.append("    sell = {")
    for iid in sorted(sell):
        lines.append("        [%d] = %d," % (iid, sell[iid]))
    lines.append("    },")
    lines.append("}")

    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    limited = sum(1 for r in out_recipes if any(v[4] for v in r[4]))
    print(f"Wrote {OUT}")
    print(f"  Fojji build {build}: {len(out_recipes)} vendor recipes ({limited} limited stock), {len(sell)} sell prices")


if __name__ == "__main__":
    sys.exit(main())
