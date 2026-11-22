-- GoblinLedger: vendor recorder
-- When you open a merchant, the recipes it sells are recorded with the vendor's NPC ID, spot,
-- zone and subzone, faction, base price, stock limit and any reputation needed.
-- Nothing about your character is stored. Own recordings live in GoblinLedgerDB.recorded,
-- recordings shared by other players (Comm.lua) in GoblinLedgerDB.shared.
local ADDON, ns = ...

local R = {}
ns.Recorder = R

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local RECIPE_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Recipe) or 9
-- recipe item subclass -> profession
local PROF_BY_SUBCLASS = {
    [1] = "Leatherworking", [2] = "Tailoring", [3] = "Engineering", [4] = "Blacksmithing",
    [5] = "Cooking", [6] = "Alchemy", [7] = "First Aid", [8] = "Enchanting", [9] = "Fishing",
    [10] = "Jewelcrafting",
}
R.PROF_BY_SUBCLASS = PROF_BY_SUBCLASS

-- reputation discount by reaction (5 friendly .. 8 exalted); prices are stored without it
local DISCOUNT = { [5] = 0.05, [6] = 0.10, [7] = 0.15, [8] = 0.20 }

function R.BasePrice(price, react)
    local d = DISCOUNT[react or 0] or 0
    if d == 0 then return price end
    return math.floor(price / (1 - d) + 0.5)
end

local function NpcID(guid)
    if type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return tonumber(id)
end

local function Clean(s)
    -- separators used by the sharing protocol are never part of names
    return (tostring(s or ""):gsub("[%^~;:,|]", ""))
end
R.Clean = Clean

-- "Requires Nightclaw Druids - Friendly" from the item's merchant tooltip
local function RepNeeded(index)
    if not (C_TooltipInfo and C_TooltipInfo.GetMerchantItem) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetMerchantItem, index)
    if not ok or not data or not data.lines then return nil end
    for _, line in ipairs(data.lines) do
        local t = line.leftText
        if type(t) == "string" then
            local faction, standing = t:match("^Requires (.+) %- (%a+)$")
            if faction and standing then return ("%s with %s"):format(standing, faction) end
        end
    end
end

local function MerchantItem(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if info then return info.price, info.stackCount, info.numAvailable, info.hasExtendedCost end
        return nil
    end
    local _, _, price, quantity, numAvailable, _, _, extendedCost = GetMerchantItemInfo(i)
    return price, quantity, numAvailable, extendedCost
end

local CITY_MAPS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }

local function Where()
    if IsInInstance and IsInInstance() then return nil end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    if not x or x <= 0 or y <= 0 then return nil end
    local info = C_Map.GetMapInfo(map)
    local zone = info and info.name or (GetRealZoneText and GetRealZoneText()) or "?"
    local sub = GetSubZoneText and GetSubZoneText() or ""
    if sub == "" or sub == zone then sub = nil end
    return map, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10, zone, sub
end

-- record the open merchant. Returns the number of recipes recorded.
function R.RecordMerchant()
    if not ns.db or not ns.db.settings.record then return 0 end
    local guid = UnitGUID("npc")
    local npcID = NpcID(guid)
    if not npcID then return 0 end
    local n = GetMerchantNumItems and GetMerchantNumItems() or 0
    if n == 0 then return 0 end
    local react = UnitReaction("npc", "player") or 4
    local items, count, pending = {}, 0, false
    for i = 1, n do
        local id = GetMerchantItemID and GetMerchantItemID(i)
        if id then
            local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(id)
            if classID == RECIPE_CLASS then
                local price, _, numAvailable, extended = MerchantItem(i)
                if price and price > 0 and not extended then
                    local name = GetItemInfo(id)
                    if not name then pending = true end
                    items[id] = {
                        price = R.BasePrice(price, react),
                        limited = (numAvailable or -1) >= 0,
                        rep = RepNeeded(i),
                        prof = PROF_BY_SUBCLASS[subclassID],
                        name = name and Clean(name) or nil,
                    }
                    count = count + 1
                end
            end
        end
    end
    if count == 0 then return 0 end
    local map, x, y, zone, sub = Where()
    local side = UnitFactionGroup("npc")
    side = (side == "Alliance" and "alliance") or (side == "Horde" and "horde") or "both"
    local old = ns.db.recorded[npcID]
    ns.db.recorded[npcID] = {
        name = Clean(UnitName("npc")), side = side, t = time(), items = items,
        map = map or (old and old.map), x = x or (old and old.x), y = y or (old and old.y),
        zone = zone and Clean(zone) or (old and old.zone), sub = sub and Clean(sub) or (old and old.sub),
    }
    if ns.Flips and ns.Flips.InvalidateRecipes then ns.Flips.InvalidateRecipes() end
    if ns.Comm and ns.Comm.Announce then ns.Comm.Announce(npcID) end
    ns.RequestRefresh()
    -- item names may still be loading: record once more shortly
    if pending and not R.retrying then
        R.retrying = true
        C_Timer.After(1, function()
            R.retrying = false
            if MerchantFrame and MerchantFrame:IsShown() and UnitGUID("npc") == guid then R.RecordMerchant() end
        end)
    end
    return count
end

-- newest record for a vendor: your own or one shared with you
function R.Get(npcID)
    local own, shared = ns.db.recorded[npcID], ns.db.shared[npcID]
    if own and shared then return (shared.t > own.t) and shared or own, (shared.t > own.t) and "shared" or "recorded" end
    if own then return own, "recorded" end
    if shared then return shared, "shared" end
end

-- every vendor we have a record for: npcID -> record, source
function R.All()
    local out = {}
    for id in pairs(ns.db.shared) do out[id] = true end
    for id in pairs(ns.db.recorded) do out[id] = true end
    local list = {}
    for id in pairs(out) do
        local rec, src = R.Get(id)
        list[id] = { rec = rec, src = src }
    end
    return list
end

function R.Stats()
    local own, shared, recipes = 0, 0, 0
    for _, r in pairs(ns.db.recorded) do
        own = own + 1
        for _ in pairs(r.items) do recipes = recipes + 1 end
    end
    for _ in pairs(ns.db.shared) do shared = shared + 1 end
    return own, shared, recipes
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("MERCHANT_SHOW")
ev:SetScript("OnEvent", function()
    C_Timer.After(0.5, function()
        if not (MerchantFrame and MerchantFrame:IsShown()) then return end
        local before = UnitGUID("npc")
        local n = R.RecordMerchant()
        if n > 0 and ns.db.settings.recordChat then
            local rec = ns.db.recorded[NpcID(before)]
            ns.Print(("Recorded %d recipe%s from %s%s."):format(n, n == 1 and "" or "s", rec.name,
                rec.sub and (" (" .. rec.sub .. ", " .. tostring(rec.zone) .. ")") or (rec.zone and (" (" .. rec.zone .. ")") or "")))
        end
    end)
end)
