-- GoblinLedger: bags - everything in your bags that isn't soulbound, with what
-- it's worth at a vendor and on the AH, and which one pays more.
local ADDON, ns = ...

local B = {}
ns.Bags = B

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local C = C_Container

local FIRST_BAG = 0
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

-- one slot -> itemID, stack count, bound?, link, icon, noValue
local function SlotInfo(bag, slot)
    if C and C.GetContainerItemInfo then
        local i = C.GetContainerItemInfo(bag, slot)
        if i then return i.itemID, i.stackCount, i.isBound, i.hyperlink, i.iconFileID, i.hasNoValue end
        return nil
    end
    if GetContainerItemInfo then -- old API
        local icon, count, _, _, _, _, link, _, noValue, id, bound = GetContainerItemInfo(bag, slot)
        return id, count, bound, link, icon, noValue
    end
end

local function NumSlots(bag)
    if C and C.GetContainerNumSlots then return C.GetContainerNumSlots(bag) or 0 end
    return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

-- bag contents, rebuilt only after the bags change
-- items[itemID] = { n = total count, link, icon, noValue }
local items, dirty = {}, true

local function Rescan()
    dirty = false
    wipe(items)
    for bag = FIRST_BAG, LAST_BAG do
        for slot = 1, NumSlots(bag) do
            local id, count, bound, link, icon, noValue = SlotInfo(bag, slot)
            if id and not bound then
                local e = items[id]
                if not e then
                    e = { n = 0, link = link, icon = icon, noValue = noValue }
                    items[id] = e
                end
                e.n = e.n + (count or 1)
            end
        end
    end
end

function B.Items()
    if dirty then Rescan() end
    return items
end

-- set of itemIDs in the bags (full scan uses it to mark unlisted items)
function B.ItemIDs()
    local set = {}
    for id in pairs(B.Items()) do set[id] = true end
    return set
end

-- vendor money, AH money (after cut), best of the two and AH-minus-vendor for `count` items
local function Values(vendorEach, ahNet, count)
    local v = vendorEach and vendorEach * count
    local a = ahNet and math.floor(ahNet * count)
    local where, best
    -- vendor money is certain, AH money is a listing price
    if a and a > (v or 0) then
        where, best = "AH", a
    elseif v and v > 0 then
        where, best = "Vendor", v
    elseif a then
        where, best = "AH", a
    end
    return v, a, where, best, a and (a - (v or 0))
end
B.Values = Values

-- One row per item. view = "each" | "stack" | "all": what the money columns are for.
-- The tot* fields are always for everything you have (footer totals).
function B.Rows(view)
    local rows = {}
    for id, e in pairs(B.Items()) do
        local s = ns.SellInfo(id)
        local n = e.n
        local name, _, _, _, _, _, _, stackMax = GetItemInfo(id)
        if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        stackMax = (type(stackMax) == "number" and stackMax > 0) and stackMax or 1
        local vendorEach = e.noValue and 0 or s.vendor
        local count = (view == "each" and 1) or (view == "stack" and stackMax) or n
        local r = {
            item = id, name = name or ("item:" .. id), icon = e.icon, n = n, stackMax = stackMax, count = count,
            vendorEach = vendorEach, ahNet = s.ahNet,
            ah = s.ah, ahOld = s.ahOld, bid = s.bid, qtyAH = s.qty, t = s.t,
        }
        r.vendor, r.ahTotal, r.where, r.best, r.gain = Values(vendorEach, s.ahNet, count)
        r.totVendor, _, r.totWhere, r.totBest = Values(vendorEach, s.ahNet, n)
        rows[#rows + 1] = r
    end
    return rows
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    dirty = true
    if ns.db then ns.RequestRefresh() end
end)
