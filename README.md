# GoblinLedger

A goblin's book of profits for the World of Warcraft **Forever** client (Interface 16001). It records Auction House prices for everything you can craft, its materials, and anything else worth flipping. Then it shows where the money is, in one window.

Formerly **CraftProfit**. The old `/cp` command still works.

## Features

- **Crafting tab**: every recipe your characters know, with material cost, sale price, profit and margin after the AH cut. You can sort it, filter by profession, show only profitable recipes, and include all your characters.
- **Disenchant tab**: gear auctions seen on the AH, compared against the expected value of what they disenchant into.
- **Vendor Flips tab**: AH auctions listed below what a vendor pays for the item. Click a row to open it in the AH buy screen.
- **Vendor Recipes tab**: recipes sold by NPCs (including limited stock and reputation recipes) compared with their AH price. It shows each vendor's location, such as "Astranaar, Ashenvale" or "Ironforge", with map coordinates. Right-click a row to set a waypoint to that vendor, or Ctrl+right-click for the nearest one you can use. Tick **By zone** to group the list into collapsible zones (Ironforge, Stormwind City, Moonglade...), with each zone's recipe count and total profit. A recipe sold in several zones shows up under each of them. Right-click a zone for a waypoint to the nearest vendor there. Waypoints use TomTom if it's installed, otherwise the game's map pin. Needs the optional recipe data, see below.
- **Bags tab**: everything in your bags that isn't soulbound, with what it's worth at a vendor and on the AH, and which one pays more. The **Values** button switches the money columns between one item, one full stack, or everything you have, so you can sort by what's worth most per item. The tooltip shows all three.
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
| `/gl help` | List commands |

`/goblinledger` and the old `/cp` work too. Open each profession window once so its recipes get recorded.

## Install

Copy the `GoblinLedger` folder into `World of Warcraft\_forever_\Interface\AddOns\` and restart the game or `/reload`.

Optional dependencies: FojjiCore, FojjiCore_Professions, Auctionator, TomTom.

## Vendor recipe data

The vendor recipe list, vendor map spots and some vendor sell prices come from **FojjiCore_Professions**. That data belongs to Fojji (and the sources they credit), so it is **not included in this repository**. If you have FojjiCore installed, generate a local copy:

```bash
python tools/sync_fojji.py
```

This writes `Data/FojjiData.lua`, which is git-ignored. Add `-v` to list every vendor and the town it was placed in. Town names come from a table of approximate town centres in the script, because Fojji only stores zones. Re-run it after FojjiCore updates.

Without the file, GoblinLedger reads FojjiCore_Professions directly if it's loaded. Otherwise the vendor recipe tab is empty and everything else still works.

## License

MIT. See [LICENSE](LICENSE).

## Contact

- Bugs and feature requests: open an issue on this repository.
- Anything else, including work enquiries: [d1verseti.gg@gmail.com](mailto:d1verseti.gg@gmail.com)
