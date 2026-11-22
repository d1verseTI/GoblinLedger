-- GoblinLedger: flips
--   * Vendor flips: AH auctions listed below what a vendor pays for the item
--   * Vendor recipes: recipes sold by NPCs (incl. limited stock) vs. their AH price
-- Recipe vendor data and extra vendor sell prices: our own database, Data/VendorDB.lua.
local ADDON, ns = ...

local F = {}
ns.Flips = F

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- [itemID] = { t, src = "full"|"search"|"browse", list = { {buy, bid, n, tl} } }   (memory only)
F.data = {}

local function RequestItem(id)
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
end

---------------------------------------------------------------------------
-- Vendor sell price: number > 0, 0 = can't be vendored, nil = not known yet
---------------------------------------------------------------------------
local sellCache = {}
function F.VendorSell(id)
    local v = sellCache[id]
    if v then return v end
    local name, _, _, _, _, _, _, _, _, _, sell = GetItemInfo(id)
    if name and type(sell) == "number" then
        sellCache[id] = sell
        return sell
    end
    local own = ns.VendorDB and ns.VendorDB.sell[id]
    if own then
        sellCache[id] = own
        return own
    end
    RequestItem(id)
    return nil
end

local function IsFlip(a, sell)
    local worth = sell * (a.n or 1)
    return (a.buy and a.buy < worth) or (a.bid and a.bid < worth)
end

-- keep only auctions that are flips; drop items that can't be vendored.
-- Returns false when the entry was removed.
local function Prune(id, e)
    local sell = F.VendorSell(id)
    if sell == nil then return true end -- unknown yet, keep raw
    if sell <= 0 then F.data[id] = nil; return false end
    local keep = {}
    for _, a in ipairs(e.list) do
        if IsFlip(a, sell) then keep[#keep + 1] = a end
    end
    if #keep == 0 then F.data[id] = nil; return false end
    e.list = keep
    return true
end

---------------------------------------------------------------------------
-- Feeding auctions in (from Scanner.lua)
---------------------------------------------------------------------------
function F.SetAuctions(id, list, src)
    if #list == 0 then
        F.data[id] = nil
    else
        local e = { t = time(), src = src, list = list }
        F.data[id] = e
        Prune(id, e)
    end
    ns.RequestRefresh()
end

function F.FromBrowse(id, minPrice)
    local e = F.data[id]
    if e and e.src ~= "browse" and time() - e.t < 600 then return end -- recent real search wins
    local sell = F.VendorSell(id)
    if sell ~= nil and (sell <= 0 or minPrice >= sell) then
        if e and e.src == "browse" then F.data[id] = nil end
        return
    end
    F.SetAuctions(id, { { buy = minPrice, n = 1 } }, "browse")
end

local fullNew
function F.BeginFull() fullNew = {} end
function F.AddFull(id, count, buyout, nextBid, mine)
    if not fullNew or mine then return end
    local a = { n = math.max(1, count or 1),
                buy = (buyout and buyout > 0) and buyout or nil,
                bid = (nextBid and nextBid > 0) and nextBid or nil }
    if not a.buy and not a.bid then return end
    local sell = F.VendorSell(id)
    if sell ~= nil and (sell <= 0 or not IsFlip(a, sell)) then return end -- known: only keep flips
    local e = fullNew[id]
    if not e then e = { t = time(), src = "full", list = {} }; fullNew[id] = e end
    e.list[#e.list + 1] = a
end
function F.EndFull()
    if not fullNew then return end
    F.data = fullNew
    fullNew = nil
    ns.RequestRefresh()
end

---------------------------------------------------------------------------
-- Vendor flip rows: one "Buyout" row per item (all cheap units together),
-- plus one "Bid" row per auction whose next bid (but not buyout) is a flip
---------------------------------------------------------------------------
function F.FlipRows()
    local rows = {}
    for id, e in pairs(F.data) do
        if Prune(id, e) then
            local sell = F.VendorSell(id)
            if sell and sell > 0 then
                local name = (GetItemInfo(id)) or ("item:" .. id)
                local units, cost, buys = 0, 0, {}
                for _, a in ipairs(e.list) do
                    local n = a.n or 1
                    if a.buy and a.buy < sell * n then
                        units, cost = units + n, cost + a.buy
                        buys[#buys + 1] = a
                    elseif a.bid and a.bid < sell * n then
                        local value = sell * n
                        rows[#rows + 1] = {
                            item = id, name = name, kind = "Bid", n = n, cost = a.bid, value = value,
                            profit = value - a.bid, margin = (value - a.bid) / a.bid,
                            tl = a.tl, t = e.t, src = e.src, sell = sell, auctions = { a },
                        }
                    end
                end
                if units > 0 then
                    local value = sell * units
                    rows[#rows + 1] = {
                        item = id, name = name, kind = "Buyout", n = units, cost = cost, value = value,
                        profit = value - cost, margin = (value - cost) / cost,
                        t = e.t, src = e.src, sell = sell, auctions = buys,
                    }
                end
            end
        end
    end
    return rows
end

---------------------------------------------------------------------------
-- Vendor-sold recipes (Data/VendorDB.lua)
---------------------------------------------------------------------------
local recipeList, recipeSet

function F.HasRecipeData()
    return (ns.VendorDB ~= nil and ns.VendorDB.recipes ~= nil) or (ns.db ~= nil and next(ns.db.recorded or {}) ~= nil)
end

-- VendorDB.recipes: { recipeItemID, spellName, profession, skill,
--   { {npc, zone, price, side, limited, rep|false, mapID|false, x|false, y|false, town|false,
--      npcID|false, src, t}, ... } }      src: "fojji" (Fojji's list) or "ledger" (recorded in game)
-- On top of that come live recordings: your own (Recorder.lua) and ones shared by other players
-- (Comm.lua). A live record replaces everything the database has for that vendor when it is newer.
local function VendorKey(v) return v.npcID or ("name:" .. tostring(v.npc)) end

local function SpellFromItemName(name)
    if not name then return nil end
    return (name:gsub("^[%a ]+: ", ""))
end

function F.InvalidateRecipes()
    recipeList, recipeSet = nil, nil
    ns.RequestRefresh()
end

function F.RecipeList()
    if recipeList then return recipeList end
    local db = ns.VendorDB and ns.VendorDB.recipes or {}
    local byItem, order = {}, {}
    local shippedT = {} -- vendor key -> newest database time
    for _, r in ipairs(db) do
        local e = { item = r[1], spell = r[2], prof = r[3], skill = r[4], vendors = {} }
        for _, v in ipairs(r[5]) do
            local vend = {
                npc = v[1], zone = v[2], price = v[3], side = v[4] or "both", limited = v[5] == true,
                rep = v[6] or nil, map = v[7] or nil, x = v[8] or nil, y = v[9] or nil, town = v[10] or nil,
                npcID = v[11] or nil, src = v[12] or "fojji", t = v[13] or 0,
            }
            e.vendors[#e.vendors + 1] = vend
            local k = VendorKey(vend)
            if vend.t > (shippedT[k] or -1) then shippedT[k] = vend.t end
        end
        byItem[e.item] = e
        order[#order + 1] = e
    end
    -- live records that are newer than the database replace that vendor
    local live = ns.Recorder and ns.db and ns.Recorder.All() or {}
    local override = {}
    for npcID, l in pairs(live) do
        local t = l.rec.t or 0
        if t > (shippedT[npcID] or -1) and t > (shippedT["name:" .. tostring(l.rec.name)] or -1) then
            override[npcID] = l
        end
    end
    if next(override) then
        local byName = {}
        for npcID, l in pairs(override) do byName[l.rec.name] = true end
        for _, e in ipairs(order) do
            local keep = {}
            for _, v in ipairs(e.vendors) do
                local gone = (v.npcID and override[v.npcID]) or (not v.npcID and byName[v.npc])
                if not gone then keep[#keep + 1] = v end
            end
            e.vendors = keep
        end
        for npcID, l in pairs(override) do
            local rec = l.rec
            for id, it in pairs(rec.items) do
                local e = byItem[id]
                if not e then
                    e = { item = id, spell = SpellFromItemName(it.name) or ("item:" .. id), prof = it.prof or "?", vendors = {} }
                    byItem[id] = e
                    order[#order + 1] = e
                end
                e.vendors[#e.vendors + 1] = {
                    npc = rec.name, zone = rec.zone or "?", price = it.price, side = rec.side or "both",
                    limited = it.limited == true, rep = it.rep, map = rec.map, x = rec.x, y = rec.y,
                    town = rec.sub, npcID = npcID, src = l.src, t = rec.t,
                }
            end
        end
    end
    recipeList, recipeSet = {}, {}
    for _, e in ipairs(order) do
        if #e.vendors > 0 then
            table.sort(e.vendors, function(a, b) return a.price < b.price end)
            recipeSet[e.item] = true
            recipeList[#recipeList + 1] = e
        end
    end
    return recipeList
end

function F.RecipeIDs()
    if not recipeSet then F.RecipeList() end
    return recipeSet or {}
end

local function MyFaction()
    local f = UnitFactionGroup and UnitFactionGroup("player")
    return f and f:lower() or "both"
end

local function CanUse(v, faction)
    return v.side == "both" or v.side == faction
end

function F.CanUse(v)
    return CanUse(v, MyFaction())
end

-- Auctionator's last price for an item, and when (its public API)
local function AuctionatorPrice(id)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionPriceByItemID) then return nil end
    local ok, p = pcall(api.GetAuctionPriceByItemID, ADDON, id)
    if not ok or type(p) ~= "number" or p <= 0 then return nil end
    local t
    if api.GetAuctionAgeByItemID then
        local ok2, days = pcall(api.GetAuctionAgeByItemID, ADDON, id)
        if ok2 and type(days) == "number" then t = time() - days * 86400 end
    end
    return p, t
end

-- AH price for a recipe: our own scan, else Auctionator
local function RecipeAH(id)
    local p = ns.db.prices[id]
    local price, old = ns.AHPrice(id)
    if price then return price, old and "old" or "cp", p and p.qty, p and p.t end
    if p and p.t and p.qty == 0 then return nil, "none", 0, p.t end -- we looked, none listed
    local ap, at = AuctionatorPrice(id)
    if ap then return ap, "auctionator", nil, at end
end

function F.RecipeRows(myFactionOnly)
    local list = F.RecipeList()
    if not list then return {} end
    local faction = MyFaction()
    local cut = ns.db.settings.ahCut or 0.05
    local rows = {}
    for _, r in ipairs(list) do
        local best, other
        for _, v in ipairs(r.vendors) do -- sorted cheapest first
            if CanUse(v, faction) then
                best = best or v
            else
                other = other or v
            end
        end
        local pick = best or (not myFactionOnly and other)
        if pick then
            local ah, src, qty, t = RecipeAH(r.item)
            local row = {
                item = r.item, recipe = r, vendor = pick, otherSide = not best,
                name = (GetItemInfo(r.item)) or ("Recipe: " .. tostring(r.spell)),
                prof = r.prof, npc = pick.npc, cost = pick.price, loc = F.Where(pick),
                lim = pick.limited and 1 or 0,
                ah = ah, src = src, qtyAH = qty, t = t,
            }
            if ah then
                row.profit = math.floor(ah * (1 - cut) - pick.price)
                row.margin = row.profit / pick.price
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

---------------------------------------------------------------------------
-- Open an item in the Blizzard AH buy view
---------------------------------------------------------------------------
function F.ShowOnAH(id, unitPrice)
    local AHF = AuctionHouseFrame
    if not ns.Scanner.open or not AHF then ns.Print("Open the Auction House first.") return end
    local key = ns.Scanner.MakeKey(id)
    local info = C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.GetItemKeyInfo(key)
    if info and AHF.SelectBrowseResult then
        local ok = pcall(AHF.SelectBrowseResult, AHF, { itemKey = key, minPrice = unitPrice or 0 })
        if ok then return end
    end
    -- fallback: type the name into the AH search box
    local name = GetItemInfo(id)
    local bar = AHF.SearchBar
    if name and bar and bar.SearchBox then
        if AHF.SetDisplayMode and AuctionHouseFrameDisplayMode then
            pcall(AHF.SetDisplayMode, AHF, AuctionHouseFrameDisplayMode.Buy)
        end
        bar.SearchBox:SetText(name)
        if bar.StartSearch then pcall(bar.StartSearch, bar) end
    else
        RequestItem(id)
        ns.Print("Item info not loaded yet - try again in a moment.")
    end
end

---------------------------------------------------------------------------
-- Vendor locations and waypoints
---------------------------------------------------------------------------
-- "Astranaar, Ashenvale", "Ironforge", or just the zone when the spot isn't in a town
function F.Where(v)
    if v.town and v.town ~= v.zone then return v.town .. ", " .. v.zone end
    return v.zone or "?"
end

function F.WhereLong(v)
    local w = F.Where(v)
    if v.x and v.y then w = ("%s (%.1f, %.1f)"):format(w, v.x, v.y) end
    return w
end

local function WorldPos(map, x, y) -- x, y as 0-1
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if ok and cont and pos then return cont, pos end
end

-- some maps (cities on some clients) refuse user waypoints: move the spot onto the zone around it
local function Pinnable(map, x, y)
    if not (C_Map and C_Map.CanSetUserWaypointOnMap) then return map, x, y end
    local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, map)
    if ok and can then return map, x, y end
    local cont, world = WorldPos(map, x, y)
    if not cont or not C_Map.GetMapPosFromWorldPos then return nil end
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    local p, guard = info and info.parentMapID, 0
    while p and p > 0 and guard < 6 do
        guard = guard + 1
        local okC, canP = pcall(C_Map.CanSetUserWaypointOnMap, p)
        if okC and canP then
            local okP, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, p)
            if okP and pos then
                local px, py = pos:GetXY()
                if px and px > 0 and px < 1 and py > 0 and py < 1 then return p, px, py end
            end
        end
        local up = C_Map.GetMapInfo(p)
        p = up and up.parentMapID
    end
end

-- waypoint to a vendor: TomTom when installed, else the game's own map pin
function F.Waypoint(v, what)
    if not v or not v.map then
        ns.Print(("No map spot known for %s (%s)."):format(v and v.npc or "?", v and v.zone or "?"))
        return
    end
    local title = v.npc .. (what and (" - " .. what) or "")
    local x, y = v.x / 100, v.y / 100
    if TomTom and TomTom.AddWaypoint then
        local ok = pcall(TomTom.AddWaypoint, TomTom, v.map, x, y,
            { title = title, persistent = false, minimap = true, world = true, crazy = true })
        if ok then ns.Print(("Waypoint (TomTom): %s - %s"):format(v.npc, F.WhereLong(v))) return end
    end
    local m, px, py = Pinnable(v.map, x, y)
    if m and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        local ok = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(m, px, py))
        if ok then
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
            end
            ns.Print(("Waypoint: %s - %s"):format(v.npc, F.WhereLong(v)))
            return
        end
    end
    ns.Print(("Can't place a map pin there. %s is at %s."):format(v.npc, F.WhereLong(v)))
end

-- the vendor you can use that is closest to you (same continent), or nil
function F.Nearest(vendors)
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local pmap = C_Map.GetBestMapForUnit("player")
    local ppos = pmap and C_Map.GetPlayerMapPosition(pmap, "player")
    if not ppos then return nil end
    local pcont, pworld = WorldPos(pmap, ppos:GetXY())
    if not pcont then return nil end
    local px, py = pworld:GetXY()
    local faction = MyFaction()
    local best, bestD
    for _, v in ipairs(vendors) do
        if v.map and CanUse(v, faction) then
            local cont, w = WorldPos(v.map, v.x / 100, v.y / 100)
            if cont == pcont then
                local wx, wy = w:GetXY()
                local d = (wx - px) ^ 2 + (wy - py) ^ 2
                if not bestD or d < bestD then best, bestD = v, d end
            end
        end
    end
    return best, bestD and math.sqrt(bestD)
end
