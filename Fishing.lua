-- GoblinLedger: fishing
--   * records everything you fish up: item, amount, zone and the spot you fished from
--   * rows for the Fishing tab: every fish (Data/FishDB.lua + anything you caught), its AH and
--     vendor value, where it lives, and your own catch numbers per zone
-- GoblinLedgerDB.fishing = {
--   zones = { [zone] = { n = catches, items = { [itemID] = amount } } },
--   spots = { [itemID] = { ["map:x:y"] = { map, x, y, zone, sub, n } } },
-- }
local ADDON, ns = ...

local Fi = {}
ns.Fishing = Fi

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local MAX_SPOTS = 25

local function DB()
    local f = ns.db.fishing
    if not f then f = { zones = {}, spots = {} }; ns.db.fishing = f end
    f.zones, f.spots = f.zones or {}, f.spots or {}
    return f
end

---------------------------------------------------------------------------
-- recording catches
---------------------------------------------------------------------------
local function Here()
    local zone = GetRealZoneText and GetRealZoneText() or "?"
    local sub = GetSubZoneText and GetSubZoneText() or ""
    if sub == "" or sub == zone then sub = nil end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    local x, y
    if pos then x, y = pos:GetXY() end
    if x and x > 0 and y and y > 0 then x, y = math.floor(x * 100 + 0.5), math.floor(y * 100 + 0.5) else map = nil end
    return zone, sub, map, x, y
end

local function AddSpot(id, zone, sub, map, x, y, amount)
    if not map then return end
    local f = DB()
    local spots = f.spots[id]
    if not spots then spots = {}; f.spots[id] = spots end
    local key = map .. ":" .. x .. ":" .. y
    local s = spots[key]
    if not s then
        -- keep the list short: drop the least used spot
        local count, worstKey, worstN = 0, nil, nil
        for k, v in pairs(spots) do
            count = count + 1
            if not worstN or v.n < worstN then worstKey, worstN = k, v.n end
        end
        if count >= MAX_SPOTS and worstKey then spots[worstKey] = nil end
        s = { map = map, x = x, y = y, zone = zone, sub = sub, n = 0 }
        spots[key] = s
    end
    s.n = s.n + amount
end

local looted = false
function Fi.RecordLoot()
    if looted or not (IsFishingLoot and IsFishingLoot()) then return end
    looted = true
    local zone, sub, map, x, y = Here()
    local f = DB()
    local z = f.zones[zone]
    if not z then z = { n = 0, items = {} }; f.zones[zone] = z end
    z.n = z.n + 1
    for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then
            local _, _, quantity = GetLootSlotInfo(slot)
            quantity = math.max(1, quantity or 1)
            z.items[id] = (z.items[id] or 0) + quantity
            AddSpot(id, zone, sub, map, x, y, quantity)
        end
    end
    ns.RequestRefresh()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("LOOT_READY")
ev:RegisterEvent("LOOT_CLOSED")
ev:SetScript("OnEvent", function(_, event)
    if not ns.db then return end
    if event == "LOOT_CLOSED" then looted = false return end
    Fi.RecordLoot()
end)

---------------------------------------------------------------------------
-- reading it back
---------------------------------------------------------------------------
-- your fishing skill, or nil when unknown
function Fi.MySkill()
    if GetProfessions and GetProfessionInfo then
        local _, _, _, fishing = GetProfessions()
        if fishing then
            local _, _, level = GetProfessionInfo(fishing)
            if level then return level end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, header, _, rank = GetSkillLineInfo(i)
            if not header and name == (PROFESSIONS_FISHING or "Fishing") then return rank end
        end
    end
end

function Fi.ZoneSkill(zone)
    return ns.FishDB and ns.FishDB.zoneSkill[zone]
end

-- what one item is worth to you: the better of AH (after cut) and vendor
local function Worth(id)
    local s = ns.SellInfo(id)
    local v = (s.vendor and s.vendor > 0) and s.vendor or 0
    local a = s.ahNet or 0
    return math.max(v, a), s
end
Fi.Worth = Worth

-- your catch numbers in a zone: catches, value per catch, and per-item share
function Fi.ZoneStats(zone)
    local z = DB().zones[zone]
    if not z or z.n == 0 then return nil end
    local total = 0
    for id, amount in pairs(z.items) do total = total + Worth(id) * amount end
    return { n = z.n, perCatch = total / z.n, items = z.items }
end

-- the spot you caught most of this item at (optionally only in one zone)
function Fi.BestSpot(id, zone)
    local best
    for _, s in pairs(DB().spots[id] or {}) do
        if (not zone or s.zone == zone) and (not best or s.n > best.n) then best = s end
    end
    return best
end

-- the spot you fished most from in a zone (any catch)
function Fi.ZoneSpot(zone)
    local sum = {}
    local best, bestN
    for _, spots in pairs(DB().spots) do
        for k, s in pairs(spots) do
            if s.zone == zone then
                sum[k] = (sum[k] or 0) + s.n
                if not bestN or sum[k] > bestN then best, bestN = s, sum[k] end
            end
        end
    end
    return best
end

function Fi.Waypoint(spot, what)
    if not spot then
        ns.Print("No fishing spot recorded there yet - catch something there first.")
        return
    end
    ns.Flips.Waypoint({ npc = what or "Fishing spot", map = spot.map, x = spot.x, y = spot.y,
                        zone = spot.zone, town = spot.sub }, spot.sub or spot.zone)
end

local function CaughtTotal(id)
    local n = 0
    for _, z in pairs(DB().zones) do n = n + (z.items[id] or 0) end
    return n
end

-- One row per fish. Fish you caught that aren't in the database are added (no junk).
function Fi.Rows()
    local rows, seen = {}, {}
    local skill = Fi.MySkill()
    local function add(id, info)
        if seen[id] then return end
        seen[id] = true
        local name, _, quality, _, _, _, _, stackMax = GetItemInfo(id)
        if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        local worth, s = Worth(id)
        stackMax = (type(stackMax) == "number" and stackMax > 0) and stackMax or 20
        -- zones: the database's plus every zone you caught it in
        local zones, zset = {}, {}
        for _, z in ipairs(info and info[5] or {}) do
            if not zset[z] then zset[z] = true; zones[#zones + 1] = z end
        end
        local caughtIn = {}
        for z, zs in pairs(DB().zones) do
            if zs.items[id] then
                caughtIn[z] = zs.items[id]
                if not zset[z] then zset[z] = true; zones[#zones + 1] = z end
            end
        end
        table.sort(zones, function(a, b)
            local ca, cb = caughtIn[a] or 0, caughtIn[b] or 0
            if ca ~= cb then return ca > cb end
            return a < b
        end)
        local r = {
            item = id, name = name or (info and info[2]) or ("item:" .. id), quality = quality,
            water = info and info[3] or "?", skill = info and info[4], note = info and info[6],
            zones = zones, caughtIn = caughtIn, where = table.concat(zones, ", "),
            ah = s.ah, ahOld = s.ahOld, ahNet = s.ahNet and math.floor(s.ahNet), vendor = s.vendor,
            qtyAH = s.qty, t = s.t, worth = worth, stackMax = stackMax,
            stack = worth > 0 and worth * stackMax or nil,
            caught = CaughtTotal(id), inDB = info ~= nil,
        }
        if r.caught == 0 then r.caught = nil end
        r.tooHigh = skill and r.skill and skill < r.skill or false
        rows[#rows + 1] = r
    end
    for _, info in ipairs(ns.FishDB and ns.FishDB.fish or {}) do add(info[1], info) end
    for _, z in pairs(DB().zones) do
        for id in pairs(z.items) do
            local _, _, quality = GetItemInfo(id)
            if quality and quality >= 1 then add(id, nil) end -- skip grey junk
        end
    end
    return rows, skill
end

function Fi.FishIDs()
    local ids = {}
    for _, r in ipairs(Fi.Rows()) do ids[#ids + 1] = r.item end
    return ids
end
