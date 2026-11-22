# GoblinLedger

A goblin's book of profits for the World of Warcraft **Forever** client (Interface 16001). It records Auction House prices for everything you can craft, its materials, and anything else worth flipping. Then it shows where the money is, in one window.

Formerly **CraftProfit**. The old `/cp` command still works.

## Features

- **Crafting tab**: every recipe your characters know, with material cost, sale price, profit and margin after the AH cut. You can sort it, filter by profession, show only profitable recipes, and include all your characters.
- **Disenchant tab**: gear auctions seen on the AH, compared against the expected value of what they disenchant into.
- **Vendor Flips tab**: AH auctions listed below what a vendor pays for the item. Click a row to open it in the AH buy screen.
- **Vendor Recipes tab**: recipes sold by NPCs (including limited stock and reputation recipes) compared with their AH price. It shows each vendor's location, such as "Astranaar, Ashenvale" or "Ironforge", with map coordinates. Right-click a row to set a waypoint to that vendor, or Ctrl+right-click for the nearest one you can use. Tick **By zone** to group the list into collapsible zones (Ironforge, Stormwind City, Moonglade...), with each zone's recipe count and total profit. A recipe sold in several zones shows up under each of them. Right-click a zone for a waypoint to the nearest vendor there. Waypoints use TomTom if it's installed, otherwise the game's map pin.
- **Bags tab**: everything in your bags that isn't soulbound, with what it's worth at a vendor and on the AH, and which one pays more. The **Values** button switches the money columns between one item, one full stack, or everything you have, so you can sort by what's worth most per item. The tooltip shows all three.
- **Vendor recorder**: every time you open a vendor, the recipes it sells are recorded: base price (without your reputation discount), limited stock, reputation needed, and the vendor's spot, zone and subzone. What you recorded replaces the database entry for that vendor and shows as "seen by you" in the tooltip. Nothing about your character is stored.
- **Sharing in game**: GoblinLedger users in the same guild or group swap recorded vendors automatically, using addon messages. Only newer data is taken, and shared vendors show as "shared by a player".
- **Item tooltips**: AH and vendor prices on every item tooltip (`/gl tooltip` to turn off).
- **Targeted scan**: scans only the items you track, instead of the whole AH. It pauses while you're on the Sell tab or posting.

## Commands

| Command | Does |
|---|---|
| `/gl` | Toggle the window |
| `/gl bags` | What in your bags is worth selling |
| `/gl tooltip` | Prices on item tooltips on/off |
| `/gl scan` | Scan all tracked items |
| `/gl full` | Full AH scan (15-minute cooldown) |
| `/gl stop` | Stop the current scan |
| `/gl auto` | Toggle auto-scanning when the AH opens (off by default) |
| `/gl stale <min>` | Auto-scan only refreshes prices older than this |
| `/gl resetprices` | Clear all recorded prices |
| `/gl vendors` | How many vendors you recorded and got from other players |
| `/gl record` | Record vendors you visit on/off (on by default) |
| `/gl share` | Share recorded vendors with your guild / group on/off (on by default) |
| `/gl quiet` | Chat messages about recorded / shared vendors on/off |
| `/gl help` | List commands |

`/goblinledger` and the old `/cp` work too. Open each profession window once so its recipes get recorded.

## Install

Copy the `GoblinLedger` folder into `World of Warcraft\_forever_\Interface\AddOns\` and restart the game or `/reload`.

No other addons needed. Optional: Auctionator (fallback AH prices) and TomTom (waypoints).

## Vendor database

`Data/VendorDB.lua` is GoblinLedger's vendor database: recipes sold by NPCs for gold, with each vendor's zone, town, map spot, faction, price, limited stock and any reputation needed, plus vendor sell prices. It ships with the addon. Each vendor entry says where it came from:

- **ledger**: recorded in game by GoblinLedger. This is our own data and it always wins.
- **fojji**: from **FojjiCore_Professions** by Fojji, copied with Fojji's permission. Thanks, Fojji! Fojji's own sources are seemeta.com (recipe data datamined from WoW Forever), Wowhead, MetaForge and QuestieDB (vendors and NPC spots), wow-professions.com and warcraft.wiki.gg. Town names for these entries come from GoblinLedger's own table of town centres.

The aim is to replace Fojji's entries with recorded ones over time.

### Rebuilding it (maintainers)

```bash
python tools/build_vendordb.py
```

This does three things:
1. Refreshes Fojji's list into `tools/fojji_vendors.json` if FojjiCore_Professions is installed. Otherwise it uses the cached copy, so FojjiCore isn't needed.
2. Collects the vendors you recorded from your SavedVariables (`WTF\Account\*\SavedVariables\GoblinLedger.lua`) into `tools/recorded_vendors.json`. Newest wins, and only NPC data is kept.
3. Builds `Data/VendorDB.lua`, where recorded vendors replace Fojji's entries for the same NPC.

To publish automatically, run `python tools/publish_vendordb.py --repo <path to this repo>` on a schedule. It rebuilds the database and, only if it changed, commits and pushes just the database files.

Options: `-v` lists every vendor with its source and town, `--include-shared` also takes vendors other players shared with you, and `--wtf <path>` points at a different WTF folder.

## License

MIT. See [LICENSE](LICENSE).

## Contact

- Bugs and feature requests: open an issue on this repository.
- Anything else, including work enquiries: [d1verseti.gg@gmail.com](mailto:d1verseti.gg@gmail.com)
