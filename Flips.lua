-- CraftProfit: flips
--   * Vendor flips: AH auctions listed below what a vendor pays for the item
--   * Vendor recipes: recipes sold by NPCs (incl. limited stock) vs. their AH price
-- Recipe vendor data: our own copy in Data/FojjiData.lua (tools/sync_fojji.py),
-- falling back to a live FojjiCore_Professions if that file is missing.
local ADDON, ns = ...

local F = {}
ns.Flips = F

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- [itemID] = { t, src = "full"|"search"|"browse", list = { {buy, bid, n, tl} } }   (memory only)
F.data = {}

local function RequestItem(id)
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
end

local function Fojji()
    local A = FojjiCoreNS
    return A, A and A.ProfessionData
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
    local own = ns.FojjiData and ns.FojjiData.sell[id]
    if own then
        sellCache[id] = own
        return own
    end
    local _, D = Fojji()
    local it = D and D.items and D.items[id]
    if it and type(it[3]) == "number" then
        sellCache[id] = it[3]
        return it[3]
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
-- Vendor-sold recipes (FojjiCore_Professions data)
-- vendor source entry: {"vendor", npcID, npcName, zone, _, priceCopper, side, limited(1), currencyText, _}
---------------------------------------------------------------------------
local recipeList, recipeSet

function F.HasRecipeData()
    if ns.FojjiData and ns.FojjiData.recipes then return true end
    local _, D = Fojji()
    return D ~= nil and D.recipes ~= nil
end

-- our synced copy: { recipeItemID, spellName, profession, skill, { {npc, zone, price, side, limited, rep}, ... } }
local function ListFromOwnData(src)
    local list, set = {}, {}
    for _, r in ipairs(src) do
        local vendors = {}
        for _, v in ipairs(r[5]) do
            vendors[#vendors + 1] = { npc = v[1], zone = v[2], price = v[3], side = v[4] or "both", limited = v[5] == true, rep = v[6] }
        end
        table.sort(vendors, function(a, b) return a.price < b.price end)
        set[r[1]] = true
        list[#list + 1] = { item = r[1], spell = r[2], prof = r[3], skill = r[4], vendors = vendors }
    end
    return list, set
end

function F.RecipeList()
    if recipeList then return recipeList end
    if ns.FojjiData and ns.FojjiData.recipes then
        recipeList, recipeSet = ListFromOwnData(ns.FojjiData.recipes)
        return recipeList
    end
    local _, D = Fojji()
    if not D or not D.recipes then return nil end
    local profName = {}
    for _, p in ipairs(D.profs or {}) do profName[p.slug] = p.name end
    recipeList, recipeSet = {}, {}
    for slug, list in pairs(D.recipes) do
        for _, r in ipairs(list) do
            if r.b and r.src and not recipeSet[r.b] then
                local vendors = {}
                for _, s in ipairs(r.src) do
                    -- gold price only (skip Merchant's Favor and other currencies)
                    if s[1] == "vendor" and type(s[6]) == "number" and s[6] > 0 and not s[9] then
                        vendors[#vendors + 1] = {
                            npc = s[3] or "?", zone = s[4] or "?", price = s[6],
                            side = s[7] or "both", limited = s[8] == 1, rep = s[10],
                        }
                    end
                end
                if #vendors > 0 then
                    table.sort(vendors, function(a, b) return a.price < b.price end)
                    recipeSet[r.b] = true
                    recipeList[#recipeList + 1] = {
                        item = r.b, spell = r.n, prof = profName[slug] or slug,
                        skill = r.k and r.k[1], vendors = vendors,
                    }
                end
            end
        end
    end
    return recipeList
end

-- recipe items get AH prices recorded like tracked items
function F.WantsPrice(id)
    if not recipeSet then F.RecipeList() end
    return recipeSet ~= nil and recipeSet[id] == true
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

-- AH price for a recipe: our own scan, else Auctionator, else a live FojjiCore
local function RecipeAH(id)
    local p = ns.db.prices[id]
    local price, old = ns.AHPrice(id)
    if price then return price, old and "old" or "cp", p and p.qty, p and p.t end
    if p and p.t and p.qty == 0 then return nil, "none", 0, p.t end -- we looked, none listed
    local ap, at = AuctionatorPrice(id)
    if ap then return ap, "auctionator", nil, at end
    local A = FojjiCoreNS
    local FA = A and A.Auctions
    if FA and FA.Price then
        local ok, fp, fn, ft, fsrc = pcall(FA.Price, id)
        if ok and type(fp) == "number" and fp > 0 then
            return fp, fsrc or "fojji", fn, ft
        end
    end
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
                prof = r.prof, npc = pick.npc, cost = pick.price,
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
