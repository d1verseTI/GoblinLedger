-- CraftProfit: core data (recipes, prices, vendor prices, profit math)
local ADDON, ns = ...
CraftProfit = ns -- global handle for /dump debugging

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

ns.tracked = {}      -- [itemID] = true for every crafted item + every material
ns.callbacks = {}

local DEFAULTS = {
    prices = {},     -- [itemID] = { buyout, bid, qty, t, lastBuyout }
    vendor = {},     -- [itemID] = copper per unit (unlimited vendor stock only)
    chars = {},      -- [char-realm] = { recipes = { [recipeID] = {...} } }
    de = {},         -- gear auctions for the Disenchant tab (see Disenchant.lua)
    lastReplicate = 0,
    settings = {
        autoScan = false,     -- scan stale tracked items when the AH opens (/cp auto)
        staleMinutes = 30,    -- auto-scan only items older than this
        ahCut = 0.05,         -- AH cut taken from sales
        sortKey = "profit",
        sortDesc = true,
        profitableOnly = false,
        profFilter = nil,
        allChars = false,
        tab = "craft",
        deSortKey = "profitBid",
        deSortDesc = true,
        deProfitableOnly = false,
        deBidsOnly = false,
        deBatch = 20,         -- "if I bought N of these" projection
        flipSortKey = "profit",
        flipSortDesc = true,
        flipNoBids = false,
        recSortKey = "profit",
        recSortDesc = true,
        recMyFaction = true,
        recLimitedOnly = false,
        recProfitableOnly = false,
    },
}

local function merge(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = type(v) == "table" and merge({}, v) or v
        elseif type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        end
    end
    return dst
end

function ns.Print(...)
    print("|cff33ff99CraftProfit|r:", ...)
end

function ns.CharKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

-- simple debounced "something changed" signal for the UI
local refreshPending = false
function ns.RequestRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.25, function()
        refreshPending = false
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    end)
end

---------------------------------------------------------------------------
-- Tracked set
---------------------------------------------------------------------------
-- Bind on Pickup crafts can't be sold, so they're left out entirely.
-- bindType (14th GetItemInfo return): 1 = Bind on Pickup. Uncached items count as sellable until info arrives.
function ns.IsBoP(id)
    local bind = select(14, GetItemInfo(id))
    if bind == nil and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    return bind == 1
end

function ns.RebuildTracked()
    wipe(ns.tracked)
    if ns.DE then
        for _, id in ipairs(ns.DE.MATS) do ns.tracked[id] = true end -- disenchant mats are always priced
    end
    for _, c in pairs(ns.db.chars) do
        for _, r in pairs(c.recipes or {}) do
          if not ns.IsBoP(r.item) then
            ns.tracked[r.item] = true
            for matID in pairs(r.mats) do ns.tracked[matID] = true end
          end
        end
    end
end

function ns.TrackedList(onlyStale)
    local list, now = {}, time()
    local staleSec = (ns.db.settings.staleMinutes or 30) * 60
    for id in pairs(ns.tracked) do
        local p = ns.db.prices[id]
        if not onlyStale or not p or not p.t or (now - p.t) > staleSec then
            list[#list + 1] = id
        end
    end
    return list
end

---------------------------------------------------------------------------
-- Recipe capture (when a profession window is open)
---------------------------------------------------------------------------
local function ProfessionName()
    local T = C_TradeSkillUI
    if T.GetBaseProfessionInfo then
        local b = T.GetBaseProfessionInfo()
        if b and b.professionName and b.professionName ~= "" then return b.professionName end
    end
    if ProfessionsFrame and ProfessionsFrame.GetProfessionInfo then
        local p = ProfessionsFrame:GetProfessionInfo()
        if p then
            if p.parentProfessionName and p.parentProfessionName ~= "" then return p.parentProfessionName end
            if p.professionName and p.professionName ~= "" then return p.professionName end
        end
    end
    if T.GetTradeSkillLine then
        local _, name = T.GetTradeSkillLine()
        if type(name) == "string" and name ~= "" then return name end
    end
    return "Unknown"
end

function ns.ScanRecipes()
    local T = C_TradeSkillUI
    if not T or not T.IsTradeSkillReady or not T.IsTradeSkillReady() then return end
    if T.IsTradeSkillLinked and T.IsTradeSkillLinked() then return end
    if T.IsTradeSkillGuild and T.IsTradeSkillGuild() then return end
    if T.IsNPCCrafting and T.IsNPCCrafting() then return end

    local ids = T.GetAllRecipeIDs and T.GetAllRecipeIDs()
    if not ids or #ids == 0 then return end

    local prof = ProfessionName()
    local recipes = ns.char.recipes
    local found = {}

    for _, id in ipairs(ids) do
        local info = T.GetRecipeInfo(id)
        if info and info.learned and not info.isDummyRecipe and not info.isRecraft then
            local sch = T.GetRecipeSchematic(id, false)
            local outID = sch and sch.outputItemID
            if not outID and T.GetRecipeItemLink then
                local link = T.GetRecipeItemLink(id)
                outID = link and tonumber(link:match("|Hitem:(%d+)"))
            end
            if outID and sch then
                local mats, any = {}, false
                for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
                    local r = slot.reagents and slot.reagents[1]
                    local q = slot.quantityRequired or 0
                    if r and r.itemID and q > 0 and slot.required ~= false then
                        mats[r.itemID] = (mats[r.itemID] or 0) + q
                        any = true
                    end
                end
                if any then
                    local qmin = sch.quantityMin or 1
                    local qmax = sch.quantityMax or qmin
                    if qmin < 1 then qmin = 1 end
                    if qmax < qmin then qmax = qmin end
                    found[id] = {
                        name = info.name, prof = prof, item = outID,
                        qty = (qmin + qmax) / 2, mats = mats, icon = info.icon,
                    }
                end
            end
        end
    end

    -- replace this profession's recipes with what we just found (handles unlearning)
    if next(found) then
        for id, r in pairs(recipes) do
            if r.prof == prof then recipes[id] = nil end
        end
        local n = 0
        for id, r in pairs(found) do recipes[id] = r; n = n + 1 end
        local was = ns.lastRecipeCount and ns.lastRecipeCount[prof]
        ns.lastRecipeCount = ns.lastRecipeCount or {}
        ns.lastRecipeCount[prof] = n
        if was ~= n then ns.Print(("Recorded %d %s recipes."):format(n, prof)) end
        ns.RebuildTracked()
        ns.RequestRefresh()
    end
end

local recipeToken = 0
local function QueueRecipeScan()
    recipeToken = recipeToken + 1
    local my = recipeToken
    C_Timer.After(1, function()
        if my == recipeToken then ns.ScanRecipes() end
    end)
end

---------------------------------------------------------------------------
-- Prices
---------------------------------------------------------------------------
-- full info for an item (targeted search / full scan). buyout=nil means none listed
function ns.SetPrice(id, buyout, bid, qty)
    local p = ns.db.prices[id] or {}
    if p.buyout then p.lastBuyout = p.buyout end
    p.buyout, p.bid, p.qty, p.t = buyout, bid, qty or 0, time()
    if buyout then p.lastBuyout = nil end
    ns.db.prices[id] = p
    ns.RequestRefresh()
end

-- buyout only (browse list); keep the last known bid
function ns.SetBuyout(id, buyout, qty)
    local p = ns.db.prices[id] or {}
    p.buyout, p.qty, p.t, p.lastBuyout = buyout, qty or p.qty, time(), nil
    ns.db.prices[id] = p
    ns.RequestRefresh()
end

-- price used for maths: live buyout, else last seen buyout
function ns.AHPrice(id)
    local p = ns.db.prices[id]
    if not p then return nil end
    if p.buyout then return p.buyout, false end
    if p.lastBuyout then return p.lastBuyout, true end
    return nil
end

function ns.MatUnitCost(id)
    local v = ns.db.vendor[id]
    local ah, old = ns.AHPrice(id)
    if v and (not ah or v <= ah) then return v, "vendor" end
    if ah then return ah, old and "ah-old" or "ah" end
    return nil, "none"
end

-- Build one table row for a recipe
function ns.Compute(recipeID, r)
    local cut = ns.db.settings.ahCut or 0.05
    local p = ns.db.prices[r.item]
    local row = {
        id = recipeID, recipe = r, item = r.item, prof = r.prof,
        name = (GetItemInfo(r.item)) or r.name,
        bid = p and p.bid, qtyAH = p and p.qty, t = p and p.t,
        mats = {},
    }
    row.buyout, row.buyoutOld = ns.AHPrice(r.item)

    local cost, missing = 0, 0
    for matID, count in pairs(r.mats) do
        local unit, src = ns.MatUnitCost(matID)
        row.mats[#row.mats + 1] = { id = matID, count = count, unit = unit, src = src,
                                    total = unit and unit * count }
        if unit then cost = cost + unit * count else missing = missing + 1 end
        local mp = ns.db.prices[matID]
        if mp and mp.t and (not row.matT or mp.t < row.matT) then row.matT = mp.t end
    end
    table.sort(row.mats, function(a, b) return (a.total or 0) > (b.total or 0) end)
    row.matCost, row.missing = cost, missing

    local qty = r.qty or 1
    if row.buyout then
        row.value = row.buyout * qty
        if missing == 0 then
            row.profit = math.floor(row.value * (1 - cut) - cost)
            row.margin = cost > 0 and (row.profit / cost) or nil
        end
    end
    if row.bid and missing == 0 then
        row.bidProfit = math.floor(row.bid * qty * (1 - cut) - cost)
    end
    return row
end

function ns.Rows()
    local rows = {}
    local list = {}
    if ns.db.settings.allChars then
        local seen = {}
        for _, c in pairs(ns.db.chars) do
            for id, r in pairs(c.recipes or {}) do
                if not seen[id] then seen[id] = true; list[id] = r end
            end
        end
    else
        list = ns.char.recipes
    end
    for id, r in pairs(list) do
        if not ns.IsBoP(r.item) then rows[#rows + 1] = ns.Compute(id, r) end
    end
    return rows
end

function ns.Professions()
    local set, out = {}, {}
    local src = ns.db.settings.allChars and ns.db.chars or { x = ns.char }
    for _, c in pairs(src) do
        for _, r in pairs(c.recipes or {}) do
            if not set[r.prof] then set[r.prof] = true; out[#out + 1] = r.prof end
        end
    end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------
-- Vendor prices (recorded when you open any merchant)
---------------------------------------------------------------------------
local function ScanMerchant()
    local n = GetMerchantNumItems and GetMerchantNumItems() or 0
    for i = 1, n do
        local price, quantity, numAvailable, extendedCost
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local info = C_MerchantFrame.GetItemInfo(i)
            if info then
                price, quantity, numAvailable, extendedCost = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost
            end
        else
            local _
            _, _, price, quantity, numAvailable, _, _, extendedCost = GetMerchantItemInfo(i)
        end
        local id = GetMerchantItemID and GetMerchantItemID(i)
        if id and price and price > 0 and not extendedCost and numAvailable == -1 then
            ns.db.vendor[id] = price / math.max(1, quantity or 1)
        end
    end
    ns.RequestRefresh()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("TRADE_SKILL_SHOW")
ev:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
ev:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
ev:RegisterEvent("NEW_RECIPE_LEARNED")
ev:RegisterEvent("MERCHANT_SHOW")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "GET_ITEM_INFO_RECEIVED" then
        if ns.char then ns.RequestRefresh() end
        return
    end
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        CraftProfitDB = merge(CraftProfitDB or {}, DEFAULTS)
        ns.db = CraftProfitDB
        -- one-time: auto-scan used to default ON; turn it off for existing saves
        if not ns.db.settings.autoScanOffMigrated then
            ns.db.settings.autoScan = false
            ns.db.settings.autoScanOffMigrated = true
        end
    elseif event == "PLAYER_LOGIN" then
        local key = ns.CharKey()
        ns.db.chars[key] = ns.db.chars[key] or { recipes = {} }
        ns.char = ns.db.chars[key]
        ns.char.recipes = ns.char.recipes or {}
        ns.RebuildTracked()
    elseif event == "MERCHANT_SHOW" then
        C_Timer.After(0.3, ScanMerchant)
    elseif ns.char then
        QueueRecipeScan()
    end
end)

---------------------------------------------------------------------------
-- Slash
---------------------------------------------------------------------------
SLASH_CRAFTPROFIT1 = "/cp"
SLASH_CRAFTPROFIT2 = "/craftprofit"
SlashCmdList.CRAFTPROFIT = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "scan" then
        ns.Scanner.StartTargeted(false)
    elseif msg == "full" then
        ns.Scanner.FullScan()
    elseif msg == "stop" then
        ns.Scanner.Stop()
    elseif msg == "auto" then
        ns.db.settings.autoScan = not ns.db.settings.autoScan
        ns.Print("Auto-scan on AH open:", ns.db.settings.autoScan and "ON" or "OFF")
    elseif msg:match("^stale %d+") then
        ns.db.settings.staleMinutes = tonumber(msg:match("%d+"))
        ns.Print("Auto-scan refreshes prices older than", ns.db.settings.staleMinutes, "min.")
    elseif msg == "resetprices" then
        wipe(ns.db.prices)
        ns.Print("All recorded prices cleared.")
        ns.RequestRefresh()
    elseif msg == "help" then
        ns.Print("/cp - toggle window | /cp scan - scan all tracked items | /cp full - full AH scan (15 min cooldown)")
        ns.Print("/cp stop | /cp auto - toggle auto-scan on AH open | /cp stale <min> | /cp resetprices")
        ns.Print("Open each profession window once so its recipes get recorded.")
    else
        ns.UI.Toggle()
    end
end
