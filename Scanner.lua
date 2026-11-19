-- GoblinLedger: Auction House scanning (modern C_AuctionHouse API)
local ADDON, ns = ...

local S = {
    open = false,
    queue = {},
    total = 0,
    pending = nil,       -- itemID we're waiting on
    pendingSince = 0,
    pausedUntil = 0,
    sendingSelf = false,
    replicating = false,
}
ns.Scanner = S

local AH = C_AuctionHouse
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local TIMEOUT = 4
local MIN_GAP = 1.0      -- seconds between our own queries (leave room for the player)
local USER_PAUSE = 8     -- seconds to back off after the player searches / posts

-- true while the Blizzard AH is on a Sell tab (posting needs the query slot)
local function OnSellTab()
    local f = AuctionHouseFrame
    local modes = AuctionHouseFrameDisplayMode
    if not f or not modes or not f.GetDisplayMode then return false end
    local m = f:GetDisplayMode()
    return m ~= nil and (m == modes.ItemSell or m == modes.CommoditiesSell or m == modes.WoWTokenSell)
end

local function Status(text)
    S.status = text
    if ns.UI and ns.UI.SetStatus then ns.UI.SetStatus(text) end
end

---------------------------------------------------------------------------
-- Result readers (run for OUR queries and for anything the player searches)
---------------------------------------------------------------------------
-- Every item we see gets its price recorded, so the Bags tab and item tooltips
-- know about anything that has been on the AH (not just crafting items).
local function WantsPrice(id)
    return id ~= nil
end

local function ReadCommodity(itemID)
    if not itemID then return end
    if ns.Flips then
        local n = AH.GetNumCommoditySearchResults(itemID) or 0
        if n > 0 or AH.HasFullCommoditySearchResults(itemID) then
            local list = {}
            for i = 1, n do
                local r = AH.GetCommoditySearchResultInfo(itemID, i)
                if r and r.unitPrice and r.quantity and not r.containsOwnerItem then
                    list[#list + 1] = { buy = r.unitPrice * r.quantity, n = r.quantity }
                end
            end
            ns.Flips.SetAuctions(itemID, list, "search")
        end
    end
    if WantsPrice(itemID) then
        local n = AH.GetNumCommoditySearchResults(itemID) or 0
        if n == 0 then
            if AH.HasFullCommoditySearchResults(itemID) then ns.SetPrice(itemID, nil, nil, 0) end
        else
            local first = AH.GetCommoditySearchResultInfo(itemID, 1)
            local qty = AH.GetCommoditySearchResultsQuantity and AH.GetCommoditySearchResultsQuantity(itemID) or (first and first.quantity)
            if first and first.unitPrice then
                ns.SetPrice(itemID, first.unitPrice, nil, qty)  -- commodities have no bids
            end
        end
    end
    if S.pending == itemID then S.pending = nil end
end

local function ReadItem(itemKey)
    if not itemKey or not itemKey.itemID then return end
    local itemID = itemKey.itemID
    local deable = ns.DE and ns.DE.IsDEable(itemID)
    local priced = WantsPrice(itemID)
    if priced or deable or ns.Flips then
        local n = AH.GetNumItemSearchResults(itemKey) or 0
        local minBuy, minBid, qty = nil, nil, 0
        local deList, flipList = {}, {}
        local myGUID = UnitGUID("player")
        for i = 1, n do
            local d = AH.GetItemSearchResultInfo(itemKey, i)
            if d then
                local q = math.max(1, d.quantity or 1)
                qty = qty + q
                if d.buyoutAmount and d.buyoutAmount > 0 then
                    local u = d.buyoutAmount / q
                    if not minBuy or u < minBuy then minBuy = u end
                end
                local b = (d.bidAmount and d.bidAmount > 0 and d.bidAmount) or d.minBid
                if b and b > 0 then
                    local u = b / q
                    if not minBid or u < minBid then minBid = u end
                end
                if not d.containsOwnerItem then
                    -- bid you'd have to place to win it right now
                    local nextBid = (d.minBid and d.minBid > 0 and d.minBid) or (d.bidAmount and d.bidAmount > 0 and d.bidAmount) or nil
                    local buy = (d.buyoutAmount and d.buyoutAmount > 0) and d.buyoutAmount or nil
                    if deable and (nextBid or buy) then
                        deList[#deList + 1] = { bid = nextBid, buy = buy, n = q, tl = d.timeLeft }
                    end
                    if d.bidder and myGUID and d.bidder == myGUID then nextBid = nil end -- already my bid
                    if nextBid or buy then
                        flipList[#flipList + 1] = { bid = nextBid, buy = buy, n = q, tl = d.timeLeft }
                    end
                end
            end
        end
        local complete = n > 0 or AH.HasFullItemSearchResults(itemKey)
        if complete and priced then ns.SetPrice(itemID, minBuy, minBid, qty) end
        if complete and deable then
            ns.DE.SetItemAuctions(itemID, deList, "search", itemKey.itemLevel)
        end
        if complete and ns.Flips then ns.Flips.SetAuctions(itemID, flipList, "search") end
    end
    if S.pending == itemID then S.pending = nil end
end

local function ReadBrowse()
    local results = AH.GetBrowseResults and AH.GetBrowseResults()
    if not results then return end
    for _, r in ipairs(results) do
        local id = r.itemKey and r.itemKey.itemID
        if id and r.minPrice and r.minPrice > 0 then
            if WantsPrice(id) then ns.SetBuyout(id, r.minPrice, r.totalQuantity) end
            if ns.DE and ns.DE.IsDEable(id) then ns.DE.FromBrowse(r.itemKey, r.minPrice) end
            if ns.Flips and not r.containsOwnerItem then ns.Flips.FromBrowse(id, r.minPrice) end
        end
    end
end

---------------------------------------------------------------------------
-- Targeted scan: one search per tracked item
---------------------------------------------------------------------------
local function MakeKey(itemID)
    local level = 0
    local equip = (C_Item and C_Item.IsEquippableItem and C_Item.IsEquippableItem(itemID))
                  or (IsEquippableItem and IsEquippableItem(itemID))
    if equip then
        level = (GetDetailedItemLevelInfo and GetDetailedItemLevelInfo(itemID)) or select(4, GetItemInfo(itemID)) or 0
    end
    return AH.MakeItemKey(itemID, level)
end
S.MakeKey = MakeKey

local function SendNext()
    if not S.open then return end
    if S.pending then
        if GetTime() - S.pendingSince < TIMEOUT then return end
        S.pending = nil -- timed out, move on
    end
    if #S.queue == 0 then
        if S.total > 0 then
            Status(("Scan done: %d items."):format(S.total))
            ns.Print(("Scan complete (%d items)."):format(S.total))
            S.total = 0
            if S.ticker then S.ticker:Cancel(); S.ticker = nil end
        end
        return
    end
    if GetTime() < S.pausedUntil then
        Status("Paused while you search / post...")
        return
    end
    if OnSellTab() then
        Status("Paused while on the Sell tab...")
        return
    end
    if GetTime() - (S.lastSent or 0) < MIN_GAP then return end
    if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then return end

    local id = table.remove(S.queue, 1)
    S.pending, S.pendingSince = id, GetTime()
    S.lastSent = GetTime()
    S.sendingSelf = true
    local ok = pcall(AH.SendSearchQuery, MakeKey(id),
        { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, false)
    S.sendingSelf = false
    if not ok then S.pending = nil end
    Status(("Scanning %d / %d"):format(S.total - #S.queue, S.total))
end

function S.StartTargeted(onlyStale, ids)
    if not S.open then ns.Print("Open the Auction House first.") return end
    if not ids then ns.RebuildTracked() end -- item info is cached by now, so BoP items drop out
    local list = ids or ns.TrackedList(onlyStale)
    if #list == 0 then
        if not ids then
            if next(ns.tracked) then Status("All prices are fresh.")
            else ns.Print("No recipes recorded yet - open your profession windows once.") end
        end
        return
    end
    -- add to queue (dedupe)
    local inQ = {}
    for _, id in ipairs(S.queue) do inQ[id] = true end
    for _, id in ipairs(list) do
        if not inQ[id] then S.queue[#S.queue + 1] = id; S.total = S.total + 1 end
    end
    for _, id in ipairs(list) do -- warm item cache (names / item levels)
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    end
    if not S.ticker then S.ticker = C_Timer.NewTicker(0.25, SendNext) end
end

function S.IsBusy()
    return S.replicating or #S.queue > 0 or S.pending ~= nil
end

-- 0..1 for targeted scans, nil when unknown (full scan)
function S.Progress()
    if S.total > 0 then return (S.total - #S.queue) / S.total end
end

function S.FullScanCooldown()
    return math.max(0, 900 - (time() - (ns.db.lastReplicate or 0)))
end

function S.Stop()
    wipe(S.queue)
    S.total, S.pending, S.replicating = 0, nil, false
    if S.ticker then S.ticker:Cancel(); S.ticker = nil end
    Status("Stopped.")
end

---------------------------------------------------------------------------
-- Full scan (ReplicateItems: every auction at once, 15 min server cooldown)
---------------------------------------------------------------------------
local function ProcessReplicate()
    if not S.replicating then return end
    S.replicating = false
    local n = AH.GetNumReplicateItems() or 0
    if n == 0 then Status("Full scan returned nothing (not supported here?).") return end
    local agg = {}
    local me = UnitName("player")
    if ns.DE then ns.DE.BeginFull() end
    if ns.Flips then ns.Flips.BeginFull() end
    for i = 0, n - 1 do
        local _, _, count, quality, _, _, _, minBid, minInc, buyout, bidAmount, highBidder, _, owner, _, _, itemID = AH.GetReplicateItemInfo(i)
        if itemID and ns.Flips then
            local nextBid = (bidAmount and bidAmount > 0) and (bidAmount + (minInc or 0)) or minBid
            ns.Flips.AddFull(itemID, count, buyout, nextBid, owner == me or highBidder)
        end
        if itemID and WantsPrice(itemID) then
            local q = math.max(1, count or 1)
            local a = agg[itemID]
            if not a then a = { qty = 0 }; agg[itemID] = a end
            a.qty = a.qty + q
            if buyout and buyout > 0 then
                local u = buyout / q
                if not a.buy or u < a.buy then a.buy = u end
            end
            local b = (bidAmount and bidAmount > 0 and bidAmount) or minBid
            if b and b > 0 then
                local u = b / q
                if not a.bid or u < a.bid then a.bid = u end
            end
        end
        if itemID and ns.DE and quality and quality >= 2 and quality <= 4 and owner ~= me and not highBidder then
            local nextBid = (bidAmount and bidAmount > 0) and (bidAmount + (minInc or 0)) or minBid
            ns.DE.AddFull(itemID, quality, (nextBid and nextBid > 0) and nextBid or nil,
                          (buyout and buyout > 0) and buyout or nil, math.max(1, count or 1))
        end
    end
    if ns.DE then ns.DE.EndFull() end
    if ns.Flips then ns.Flips.EndFull() end
    -- every listed item gets a fresh price; anything we track or knew a price for
    -- that isn't listed now is marked "none listed" (keeps its last seen buyout)
    local c, items = 0, 0
    for id, a in pairs(agg) do
        ns.SetPrice(id, a.buy, a.bid, a.qty)
        items = items + 1
        if ns.tracked[id] then c = c + 1 end
    end
    local gone = {}
    for id in pairs(ns.db.prices) do gone[id] = true end
    for id in pairs(ns.tracked) do gone[id] = true end
    if ns.Flips then for id in pairs(ns.Flips.RecipeIDs()) do gone[id] = true end end
    if ns.Bags then for id in pairs(ns.Bags.ItemIDs()) do gone[id] = true end end
    for id in pairs(gone) do
        if not agg[id] then ns.SetPrice(id, nil, nil, 0) end
    end
    Status(("Full scan: %d auctions, %d items priced, %d tracked items listed."):format(n, items, c))
    ns.Print(("Full scan done: %d auctions read, %d different items priced, %d of your crafting items are listed."):format(n, items, c))
end

local replToken = 0
local function OnReplicateUpdate()
    if not S.replicating then return end
    replToken = replToken + 1
    local my = replToken
    Status("Full scan: receiving data...")
    C_Timer.After(2, function() if my == replToken then ProcessReplicate() end end)
end

function S.FullScan()
    if not S.open then ns.Print("Open the Auction House first.") return end
    if not AH.ReplicateItems then ns.Print("Full scan not available on this client.") return end
    local wait = 900 - (time() - (ns.db.lastReplicate or 0))
    if wait > 0 then
        ns.Print(("Full scan is on cooldown for %d:%02d. Use 'Scan' for a targeted scan."):format(wait / 60, wait % 60))
        return
    end
    ns.db.lastReplicate = time()
    S.replicating = true
    Status("Full scan requested...")
    AH.ReplicateItems()
    C_Timer.After(60, function()
        if S.replicating then S.replicating = false; Status("Full scan timed out.") end
    end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_ADDED")
ev:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("ITEM_SEARCH_RESULTS_ADDED")
ev:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
ev:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
ev:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
ev:SetScript("OnEvent", function(_, event, arg1)
    if not AH or not ns.db then return end
    if event == "AUCTION_HOUSE_SHOW" then
        S.open = true
        if ns.UI and ns.UI.OnAHShow then ns.UI.OnAHShow() end
        if ns.db.settings.autoScan then
            C_Timer.After(1.5, function() if S.open then S.StartTargeted(true) end end)
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        S.open = false
        S.replicating = false
        if #S.queue > 0 then ns.Print(("AH closed, %d items left unscanned."):format(#S.queue)) end
        S.Stop()
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED" then
        ReadCommodity(arg1)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
        ReadItem(arg1)
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        ReadBrowse()
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        OnReplicateUpdate()
    end
end)

-- When the player searches manually, give their query room and pause our queue briefly
if AH then
    local function userQuery()
        if not S.sendingSelf then S.pausedUntil = GetTime() + USER_PAUSE end
    end
    for _, fn in ipairs({ "SendBrowseQuery", "SendSearchQuery", "SendSellSearchQuery",
                          "PostItem", "PostCommodity", "StartCommoditiesPurchase",
                          "PlaceBid", "CancelAuction" }) do
        if AH[fn] then hooksecurefunc(AH, fn, userQuery) end
    end
end
