#!/usr/bin/env python3
"""
Build GoblinLedger's vendor database, Data/VendorDB.lua.

    python tools/build_vendordb.py               refresh from every source it can find, then build
    python tools/build_vendordb.py -v            also list every vendor and where it was placed
    python tools/build_vendordb.py --include-shared   also take vendors other players shared with you
    python tools/build_vendordb.py --wtf <path>  where WoW's WTF folder is (default: found from the game folder)

Sources, best first:
  1. Vendors recorded in game (GoblinLedger records every vendor you open). Collected from your
     SavedVariables into tools/recorded_vendors.json - GoblinLedger's own data, newest wins.
  2. Fojji's list (FojjiCore_Professions, copied with Fojji's permission), cached in
     tools/fojji_vendors.json so FojjiCore doesn't need to be installed to build.
A recorded vendor replaces everything Fojji's list says about that vendor.
No character names are ever written: only NPC data.
"""
import datetime
import glob
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ADDON = HERE.parent                                    # .../AddOns/GoblinLedger
SRC = ADDON.parent / "FojjiCore_Professions" / "Data"  # .../AddOns/FojjiCore_Professions/Data
OUT = ADDON / "Data" / "VendorDB.lua"
FOJJI_JSON = HERE / "fojji_vendors.json"
RECORDED_JSON = HERE / "recorded_vendors.json"


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


def extract_fojji():
    """Fojji's vendor recipes and sell prices -> dict (None when FojjiCore_Professions isn't installed)"""
    recipes_file, items_file = SRC / "Recipes.lua", SRC / "Items.lua"
    if not (recipes_file.exists() and items_file.exists()):
        return None
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

    out, seen = [], set()
    for slug, lst in recipes.items():
        for r in lst:
            b = r.get("b")
            if not b or b in seen:
                continue
            vendors, vseen = [], set()
            for s in r.get("src") or []:
                s = list(s) + [None] * (10 - len(s))
                # {"vendor", npcID, npcName, zone, _, priceCopper, side, limited, currencyText, reputation}
                if s[0] != "vendor" or not isinstance(s[5], (int, float)) or s[5] <= 0 or s[8]:
                    continue
                name = s[2] or "?"
                side = s[6] or "both"
                if side == "both":
                    side = vendor_side.get(name, side)
                npc = s[1] or by_name.get(name)
                spot = spots.get(npc) if npc else None
                v = {"npc": name, "npcID": npc, "zone": s[3] or "?", "price": int(s[5]), "side": side,
                     "limited": s[7] == 1, "rep": s[9] or None, "map": None, "x": None, "y": None, "town": None}
                if spot and len(spot) >= 3:
                    v["map"], v["x"], v["y"] = int(spot[0]), float(spot[1]), float(spot[2])
                    v["town"] = town_at(v["map"], v["x"], v["y"])
                    v["zone"] = MAP_NAMES.get(v["map"], v["zone"])
                key = (name, v["zone"], v["price"])
                if key in vseen:  # Fojji lists some NPCs twice
                    continue
                vseen.add(key)
                vendors.append(v)
            if vendors:
                seen.add(b)
                k = r.get("k") or [None]
                out.append({"item": b, "spell": r.get("n") or "?", "prof": prof_name.get(slug, slug),
                            "skill": k[0], "vendors": vendors})
    sell = {str(iid): v[2] for iid, v in items.items()
            if isinstance(v, list) and len(v) >= 3 and isinstance(v[2], int)}
    return {"build": build, "synced": datetime.date.today().isoformat(), "recipes": out, "sell": sell}


def find_savedvariables(wtf):
    if wtf:
        root = pathlib.Path(wtf)
    else:
        root = ADDON.parents[2] / "WTF"  # .../_forever_/WTF
    return sorted(glob.glob(str(root / "Account" / "*" / "SavedVariables" / "GoblinLedger.lua")))


def collect_recorded(paths, include_shared):
    """vendor records from SavedVariables: {npcID: record} (newest wins)"""
    found = {}
    for p in paths:
        try:
            db = read_assign(pathlib.Path(p), "GoblinLedgerDB")
        except (SyntaxError, SystemExit) as e:
            print(f"  skipped {p}: {e}")
            continue
        if not isinstance(db, dict):
            continue
        sources = [db.get("recorded") or {}]
        if include_shared:
            sources.append(db.get("shared") or {})
        for src in sources:
            if not isinstance(src, dict):
                continue
            for npc, rec in src.items():
                if not isinstance(npc, int) or not isinstance(rec, dict) or not rec.get("name"):
                    continue
                items = {}
                for iid, it in (rec.get("items") or {}).items():
                    if isinstance(iid, int) and isinstance(it, dict) and isinstance(it.get("price"), (int, float)):
                        items[str(iid)] = {"price": int(it["price"]), "limited": bool(it.get("limited")),
                                           "rep": it.get("rep") or None, "prof": it.get("prof") or None,
                                           "name": it.get("name") or None}
                if not items:
                    continue
                clean = {"name": rec["name"], "zone": rec.get("zone"), "sub": rec.get("sub"),
                         "map": rec.get("map"), "x": rec.get("x"), "y": rec.get("y"),
                         "side": rec.get("side") or "both", "t": int(rec.get("t") or 0), "items": items}
                if str(npc) not in found or found[str(npc)]["t"] < clean["t"]:
                    found[str(npc)] = clean
    return found


def load_json(path, default):
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return default


def save_json(path, data):
    path.write_text(json.dumps(data, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


def spell_from_item(name):
    return re.sub(r"^[A-Za-z ]+: ", "", name) if name else None


def main():
    verbose = "-v" in sys.argv
    include_shared = "--include-shared" in sys.argv
    wtf = sys.argv[sys.argv.index("--wtf") + 1] if "--wtf" in sys.argv else None

    # 1. Fojji's list (cached)
    fojji = extract_fojji()
    if fojji:
        cached = load_json(FOJJI_JSON, None)
        same = cached and {k: v for k, v in cached.items() if k != "synced"} == \
            {k: v for k, v in fojji.items() if k != "synced"}
        if same:
            fojji = cached  # same data: keep the file (and its date) as it is
        else:
            save_json(FOJJI_JSON, fojji)
        print(f"Fojji's list refreshed from FojjiCore_Professions (build {fojji['build']}).")
    else:
        fojji = load_json(FOJJI_JSON, None)
        if fojji:
            print(f"FojjiCore_Professions not found - using the cached list from {fojji.get('synced', '?')}.")
        else:
            fojji = {"build": "none", "recipes": [], "sell": {}}
            print("No Fojji list available - building from recorded vendors only.")

    # 2. recorded vendors (ours), merged into the committed json
    recorded = load_json(RECORDED_JSON, {})
    paths = find_savedvariables(wtf)
    new = collect_recorded(paths, include_shared)
    added = updated = 0
    for npc, rec in new.items():
        if npc not in recorded:
            added += 1
            recorded[npc] = rec
        elif recorded[npc]["t"] < rec["t"]:
            updated += 1
            recorded[npc] = rec
    save_json(RECORDED_JSON, recorded)
    print(f"Recorded vendors: {len(recorded)} ({added} new, {updated} updated) from {len(paths)} SavedVariables file(s).")

    # 3. merge: a recorded vendor replaces Fojji's entries for that NPC
    rec_ids = {int(n) for n in recorded}
    rec_names = {r["name"] for r in recorded.values()}
    by_item, order = {}, []
    for r in fojji["recipes"]:
        vendors = []
        for v in r["vendors"]:
            if (v.get("npcID") and v["npcID"] in rec_ids) or (not v.get("npcID") and v["npc"] in rec_names):
                continue
            vendors.append(dict(v, src="fojji", t=0))
        e = {"item": r["item"], "spell": r["spell"], "prof": r["prof"], "skill": r["skill"], "vendors": vendors}
        by_item[r["item"]] = e
        order.append(e)
    for npc, rec in recorded.items():
        for iid, it in rec["items"].items():
            iid = int(iid)
            e = by_item.get(iid)
            if not e:
                e = {"item": iid, "spell": spell_from_item(it.get("name")) or f"item:{iid}",
                     "prof": it.get("prof") or "?", "skill": None, "vendors": []}
                by_item[iid] = e
                order.append(e)
            sub = rec.get("sub")
            e["vendors"].append({
                "npc": rec["name"], "npcID": int(npc), "zone": rec.get("zone") or "?", "price": it["price"],
                "side": rec["side"], "limited": it["limited"], "rep": it.get("rep"),
                "map": rec.get("map"), "x": rec.get("x"), "y": rec.get("y"),
                "town": sub if sub and sub != rec.get("zone") else None, "src": "ledger", "t": rec["t"]})
    out_recipes = [e for e in order if e["vendors"]]
    for e in out_recipes:
        e["vendors"].sort(key=lambda v: (v["price"], v["npc"]))
    out_recipes.sort(key=lambda e: (e["prof"], e["skill"] or 0, e["item"]))

    # 4. write Data/VendorDB.lua
    def opt(v, fmt=None):
        if v is None or v == "":
            return "false"
        if isinstance(v, str):
            return lua_str(v)
        return (fmt % v) if fmt else str(v)

    def vendor_lua(v):
        return "{" + ", ".join([
            lua_str(v["npc"]), lua_str(v["zone"]), str(v["price"]), lua_str(v["side"]),
            "true" if v["limited"] else "false", opt(v.get("rep")), opt(v.get("map")),
            opt(v.get("x"), "%g"), opt(v.get("y"), "%g"), opt(v.get("town")), opt(v.get("npcID")),
            lua_str(v["src"]), str(v.get("t") or 0)]) + "}"

    today = datetime.date.today().isoformat()
    n_ledger = sum(1 for e in out_recipes for v in e["vendors"] if v["src"] == "ledger")
    n_fojji = sum(1 for e in out_recipes for v in e["vendors"] if v["src"] == "fojji")
    lines = [
        "-- GoblinLedger vendor database. GENERATED by tools/build_vendordb.py - edit the sources, not this file.",
        "-- Vendors marked \"ledger\" were recorded in game by GoblinLedger (our own data).",
        "-- Vendors marked \"fojji\" come from FojjiCore_Professions by Fojji, copied with permission. Fojji credits:",
        "-- seemeta.com (recipes), Wowhead, MetaForge and QuestieDB (vendors, NPC spots), wow-professions.com, warcraft.wiki.gg.",
        f"-- Fojji data build {fojji.get('build', '?')}; built {today}: {n_ledger} recorded vendor entries, {n_fojji} from Fojji's list.",
        "local _, ns = ...",
        "ns.VendorDB = {",
        f"    built = {lua_str(today)},",
        "    -- { recipeItemID, spellName, profession, skill,",
        "    --   { {npc, zone, price, side, limited, rep, mapID, x, y, town, npcID, src, t}, ... } }   (false = unknown)",
        "    recipes = {",
    ]
    for e in out_recipes:
        lines.append("        { %d, %s, %s, %s, { %s } }," % (
            e["item"], lua_str(e["spell"]), lua_str(e["prof"]),
            e["skill"] if e["skill"] is not None else "nil", ", ".join(vendor_lua(v) for v in e["vendors"])))
    lines.append("    },")
    lines.append("    -- [itemID] = vendor sell price (copper), used until the game has loaded the item")
    lines.append("    sell = {")
    for iid in sorted(fojji.get("sell", {}), key=int):
        lines.append("        [%s] = %d," % (iid, fojji["sell"][iid]))
    lines.append("    },")
    lines.append("}")
    OUT.parent.mkdir(exist_ok=True)
    text = "\n".join(lines) + "\n"

    def without_dates(t):  # the build date alone isn't a change
        return re.sub(r'built( = "|\s)\d{4}-\d\d-\d\d"?', "", t)

    old = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
    if without_dates(old) == without_dates(text):
        print(f"{OUT.name} unchanged.")
    else:
        OUT.write_text(text, encoding="utf-8", newline="\n")

    allv = {(v["npc"], v["zone"], v["src"]): v for e in out_recipes for v in e["vendors"]}.values()
    limited = sum(1 for e in out_recipes if any(v["limited"] for v in e["vendors"]))
    print(f"Built {OUT}")
    print(f"  {len(out_recipes)} vendor recipes ({limited} limited stock), {len(fojji.get('sell', {}))} sell prices")
    print(f"  {len(allv)} vendors: {sum(1 for v in allv if v['src'] == 'ledger')} recorded by GoblinLedger, "
          f"{sum(1 for v in allv if v['src'] == 'fojji')} from Fojji's list")
    if verbose:
        for v in sorted(allv, key=lambda v: (v["zone"], v["npc"])):
            where = f"{v.get('town') or '-'} ({v['map']} {v['x']:.1f},{v['y']:.1f})" if v.get("map") else "NO SPOT"
            print(f"    [{v['src']:<6}] {v['zone']:<22} {v['npc']:<30} {where}")


if __name__ == "__main__":
    sys.exit(main())
