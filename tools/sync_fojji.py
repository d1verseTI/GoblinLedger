#!/usr/bin/env python3
"""
Build GoblinLedger's own vendor database (Data/VendorDB.lua) from FojjiCore_Professions.

    python tools/sync_fojji.py            (run from the GoblinLedger folder, or anywhere)

Re-run after FojjiCore updates to refresh it. Copies:
  * every recipe item sold by an NPC for gold: vendor name, zone, town, map spot, price, faction,
    limited stock, rep needed
  (add -v to list every vendor and the town it was placed in)
  * vendor sell prices of profession items (used when the game hasn't cached the item yet)
Fojji gave permission to copy this data into GoblinLedger; keep the credits in the generated file and README.
The generated Data/VendorDB.lua is committed, so players don't need FojjiCore - only maintainers run this.
"""
import datetime
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ADDON = HERE.parent                                    # .../AddOns/GoblinLedger
SRC = ADDON.parent / "FojjiCore_Professions" / "Data"  # .../AddOns/FojjiCore_Professions/Data
OUT = ADDON / "Data" / "VendorDB.lua"


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
# Towns: Fojji only stores the zone, so a vendor spot gets the name of the town it sits in.
# { mapID: [ (town, x, y, radius), ... ] }  (map coordinates 0-100; radius in the same units)
# Approximate centres - a spot only gets a town when it is within the radius, otherwise just the zone.
# --------------------------------------------------------------------------
TOWNS = {
    1411: [("Razor Hill", 52.5, 42.5, 5), ("Sen'jin Village", 55.5, 74.5, 4), ("Valley of Trials", 43.5, 67.5, 7)],
    1412: [("Bloodhoof Village", 47.0, 58.5, 5), ("Camp Narache", 45.0, 77.0, 6)],
    1413: [("The Crossroads", 51.8, 30.0, 4), ("Ratchet", 62.5, 37.5, 4), ("Camp Taurajo", 45.0, 58.5, 4)],
    1416: [("Ravenholdt Manor", 86.0, 79.0, 5)],
    1417: [("Refuge Pointe", 45.8, 47.0, 4), ("Hammerfall", 73.5, 33.5, 4), ("Stromgarde Keep", 27.0, 59.0, 5)],
    1418: [("Kargath", 3.5, 47.0, 5)],
    1419: [("Nethergarde Keep", 65.5, 19.5, 6)],
    1420: [("Brill", 61.0, 52.0, 5), ("Deathknell", 31.5, 65.5, 6), ("The Bulwark", 83.0, 69.0, 4)],
    1421: [("The Sepulcher", 43.5, 41.5, 5)],
    1422: [("Chillwind Camp", 43.0, 84.5, 4), ("Caer Darrow", 69.0, 78.0, 4)],
    1423: [("Light's Hope Chapel", 75.0, 53.0, 6)],
    1424: [("Southshore", 50.5, 56.0, 6), ("Tarren Mill", 62.0, 20.5, 5)],
    1425: [("Aerie Peak", 14.0, 46.0, 5), ("Revantusk Village", 78.5, 79.5, 5)],
    1426: [("Kharanos", 47.0, 52.5, 5), ("Anvilmar", 29.0, 70.5, 6), ("Brewnall Village", 30.5, 45.5, 4)],
    1427: [("Thorium Point", 38.0, 27.5, 4)],
    1428: [("Morgan's Vigil", 84.5, 68.5, 4), ("Flame Crest", 65.5, 24.0, 4)],
    1429: [("Goldshire", 42.5, 65.5, 4), ("Northshire", 48.5, 41.0, 7), ("Eastvale Logging Camp", 83.0, 67.0, 4)],
    1431: [("Darkshire", 74.5, 47.0, 6), ("Raven Hill", 18.5, 56.5, 4)],
    1432: [("Thelsamar", 35.0, 47.5, 5), ("Farstrider Lodge", 82.0, 63.0, 4)],
    1433: [("Lakeshire", 26.0, 46.0, 7)],
    1434: [("Booty Bay", 27.5, 76.5, 4), ("Grom'gol", 32.5, 28.5, 4), ("Nesingwary's Expedition", 35.5, 10.5, 4),
           ("Rebel Camp", 38.0, 3.5, 3), ("Yojamba Isle", 15.0, 16.0, 4)],
    1435: [("Stonard", 46.0, 55.0, 5)],
    1436: [("Sentinel Hill", 56.0, 49.0, 7), ("Moonbrook", 43.0, 69.0, 5)],
    1437: [("Menethil Harbor", 10.0, 59.0, 5)],
    1438: [("Dolanaar", 56.0, 59.5, 4), ("Shadowglen", 58.5, 40.5, 6), ("Rut'theran Village", 55.5, 91.5, 5)],
    1439: [("Auberdine", 37.0, 44.0, 5)],
    1440: [("Astranaar", 36.5, 50.0, 4), ("Splintertree Post", 73.0, 61.0, 4), ("Zoram'gar Outpost", 12.0, 34.5, 4),
           ("Silverwind Refuge", 50.5, 67.0, 4)],
    1441: [("Freewind Post", 46.0, 51.0, 5), ("Mirage Raceway", 80.5, 77.0, 5)],
    1442: [("Stonetalon Peak", 37.0, 8.5, 5), ("Sun Rock Retreat", 47.0, 61.5, 5)],
    1443: [("Nijel's Point", 66.0, 8.5, 5), ("Shadowprey Village", 24.5, 70.5, 5), ("Ghost Walker Post", 53.5, 55.0, 5)],
    1444: [("Feathermoon Stronghold", 30.5, 44.5, 4), ("Camp Mojache", 75.0, 44.0, 4)],
    1445: [("Theramore Isle", 67.0, 48.5, 5), ("Brackenwall Village", 36.5, 31.0, 4)],
    1446: [("Gadgetzan", 51.5, 28.0, 4), ("Steamwheedle Port", 67.0, 23.0, 4)],
    1447: [("Talrendis Point", 21.5, 52.0, 4), ("Valormok", 21.5, 62.0, 4)],
    1448: [("Talonbranch Glade", 62.5, 25.0, 4), ("Bloodvenom Post", 34.5, 53.0, 4), ("Emerald Sanctuary", 51.0, 82.0, 4),
           ("Timbermaw Hold", 65.0, 3.0, 5)],
    1449: [("Marshal's Refuge", 43.5, 8.5, 5)],
    1450: [("Nighthaven", 51.0, 40.0, 10)],
    1451: [("Cenarion Hold", 50.5, 37.0, 5), ("Valor's Rest", 82.0, 17.5, 4)],
    1452: [("Everlook", 61.0, 38.0, 4)],
}


# zone names by map ID (Fojji's zone text is sometimes the neighbouring zone)
MAP_NAMES = {
    1411: "Durotar", 1412: "Mulgore", 1413: "The Barrens", 1416: "Alterac Mountains", 1417: "Arathi Highlands",
    1418: "Badlands", 1419: "Blasted Lands", 1420: "Tirisfal Glades", 1421: "Silverpine Forest",
    1422: "Western Plaguelands", 1423: "Eastern Plaguelands", 1424: "Hillsbrad Foothills", 1425: "The Hinterlands",
    1426: "Dun Morogh", 1427: "Searing Gorge", 1428: "Burning Steppes", 1429: "Elwynn Forest", 1430: "Deadwind Pass",
    1431: "Duskwood", 1432: "Loch Modan", 1433: "Redridge Mountains", 1434: "Stranglethorn Vale",
    1435: "Swamp of Sorrows", 1436: "Westfall", 1437: "Wetlands", 1438: "Teldrassil", 1439: "Darkshore",
    1440: "Ashenvale", 1441: "Thousand Needles", 1442: "Stonetalon Mountains", 1443: "Desolace", 1444: "Feralas",
    1445: "Dustwallow Marsh", 1446: "Tanaris", 1447: "Azshara", 1448: "Felwood", 1449: "Un'Goro Crater",
    1450: "Moonglade", 1451: "Silithus", 1452: "Winterspring", 1453: "Stormwind City", 1454: "Orgrimmar",
    1455: "Ironforge", 1456: "Thunder Bluff", 1457: "Darnassus", 1458: "Undercity", 2521: "Zephras Isle",
}


def town_at(m, x, y):
    best = None
    for name, tx, ty, r in TOWNS.get(m, []):
        d = ((x - tx) ** 2 + (y - ty) ** 2) ** 0.5
        if d <= r and (best is None or d < best[0]):
            best = (d, name)
    return best[1] if best else None


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    recipes_file, items_file = SRC / "Recipes.lua", SRC / "Items.lua"
    for f in (recipes_file, items_file):
        if not f.exists():
            raise SystemExit(f"Not found: {f}\nIs FojjiCore_Professions installed next to GoblinLedger?")

    build = read_string(recipes_file, "D.build")
    profs = read_assign(recipes_file, "D.profs")
    recipes = read_assign(recipes_file, "D.recipes")
    items = read_assign(items_file, "D.items")
    prof_name = {p["slug"]: p["name"] for p in profs}
    trainers_file, guide_file = SRC / "Trainers.lua", SRC.parent / "Guide.lua"
    spots = read_assign(trainers_file, "D.npcSpots") if trainers_file.exists() else {}
    by_name = read_assign(trainers_file, "D.npcByName") if trainers_file.exists() else {}
    # Fojji's corrections for vendors its source marks "both" but that serve one faction
    vendor_side = read_assign(guide_file, "local VENDOR_SIDE") if guide_file.exists() else {}

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
                    name = s[2] or "?"
                    side = s[6] or "both"
                    if side == "both":
                        side = vendor_side.get(name, side)
                    npc = s[1] or by_name.get(name)
                    spot = spots.get(npc) if npc else None
                    m = x = y = None
                    town = ""
                    if spot and len(spot) >= 3:
                        m, x, y = int(spot[0]), float(spot[1]), float(spot[2])
                        town = town_at(m, x, y) or ""
                    zone = MAP_NAMES.get(m) if m else None
                    vendors.append((name, zone or s[3] or "?", int(s[5]), side, s[7] == 1, s[9] or "", m, x, y, town))
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
        "-- GoblinLedger vendor database. GENERATED by tools/sync_fojji.py - edit the script, not this file.",
        "-- Source: FojjiCore_Professions by Fojji, copied with permission. Fojji credits: seemeta.com (recipes),",
        "-- Wowhead, MetaForge and QuestieDB (vendors, NPC spots), wow-professions.com, warcraft.wiki.gg.",
        f"-- Fojji data build {build}, synced {datetime.date.today().isoformat()}",
        "local _, ns = ...",
        "ns.VendorDB = {",
        f"    build = {lua_str(build)},",
        f"    synced = {lua_str(datetime.date.today().isoformat())},",
        "    -- { recipeItemID, spellName, profession, skill,",
        "    --   { {npc, zone, priceCopper, side, limited, reputation|false, mapID, x, y, town|false}, ... } }",
        "    recipes = {",
    ]

    def vendor_lua(v):
        parts = [lua_str(v[0]), lua_str(v[1]), str(v[2]), lua_str(v[3]), "true" if v[4] else "false",
                 lua_str(v[5]) if v[5] else "false"]
        if v[6]:
            parts += [str(v[6]), "%g" % v[7], "%g" % v[8], lua_str(v[9]) if v[9] else "false"]
        return "{" + ", ".join(parts) + "}"

    for b, n, prof, skill, vendors in out_recipes:
        vs = ", ".join(vendor_lua(v) for v in vendors)
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
    allv = {(v[0], v[1]): v for r in out_recipes for v in r[4]}.values()
    located = [v for v in allv if v[6]]
    in_town = [v for v in located if v[9]]
    print(f"Wrote {OUT}")
    print(f"  Fojji build {build}: {len(out_recipes)} vendor recipes ({limited} limited stock), {len(sell)} sell prices")
    print(f"  {len(allv)} vendors: {len(located)} with map spots, {len(in_town)} of them placed in a town")
    if "-v" in sys.argv:
        for v in sorted(allv, key=lambda v: (v[1], v[0])):
            where = f"{v[9] or '-'} ({v[6]} {v[7]:.1f},{v[8]:.1f})" if v[6] else "NO SPOT"
            print(f"    {v[1]:<22} {v[0]:<28} {where}")


if __name__ == "__main__":
    sys.exit(main())
