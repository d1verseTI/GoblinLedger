# CraftProfit

A World of Warcraft addon for the **Forever** client (Interface 16001). It records Auction House bid and buyout prices for everything you can craft and for its materials. It then shows profit and margin per recipe in one table.

## Features

- **Crafting tab**: every recipe your characters know, with material cost, sale price, profit and margin after the AH cut. You can sort it, filter by profession, show only profitable recipes, and include all your characters.
- **Disenchant tab**: gear auctions seen on the AH, compared against the expected value of what they disenchant into.
- **Vendor Flips tab**: AH auctions listed below what a vendor pays for the item.
- **Vendor Recipes tab**: recipes sold by NPCs (including limited stock) compared with their AH price. Needs the optional recipe data, see below.
- **Targeted scan**: scans only the items you track, instead of the whole AH.

## Commands

| Command | Does |
|---|---|
| `/cp` | Toggle the window |
| `/cp scan` | Scan all tracked items |
| `/cp full` | Full AH scan (15-minute cooldown) |
| `/cp stop` | Stop the current scan |
| `/cp auto` | Toggle auto-scanning when the AH opens |
| `/cp stale <min>` | Auto-scan only refreshes prices older than this |
| `/cp resetprices` | Clear all recorded prices |
| `/cp help` | List commands |

Open each profession window once so its recipes get recorded.

## Install

Copy the `CraftProfit` folder into `World of Warcraft\_forever_\Interface\AddOns\` and restart the game or `/reload`.

Optional dependencies: FojjiCore, FojjiCore_Professions, Auctionator.

## Vendor recipe data

The vendor recipe list and some vendor sell prices come from **FojjiCore_Professions**. That data belongs to Fojji (and the sources they credit), so it is **not included in this repository**. If you have FojjiCore installed, generate a local copy:

```bash
python tools/sync_fojji.py
```

This writes `Data/FojjiData.lua`, which is git-ignored. Without it, CraftProfit reads FojjiCore_Professions directly if it's loaded. Otherwise the vendor recipe tab is empty and everything else still works.

## License

MIT. See [LICENSE](LICENSE).

## Contact

- Bugs and feature requests: open an issue on this repository.
- Anything else, including work enquiries: [d1verseti.gg@gmail.com](mailto:d1verseti.gg@gmail.com)
