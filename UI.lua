-- GoblinLedger: window with tabs (Crafting, Disenchant, Vendor Flips, Vendor Recipes, Bags)
local ADDON, ns = ...

local UI = {}
ns.UI = UI

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local ROW_H, NUM_ROWS = 20, 20
local PANEL_TOP = 54           -- panels start below the tab row
local HEADER_Y = 30            -- inside a panel
local ROWS_Y = 50

---------------------------------------------------------------------------
-- formatting
---------------------------------------------------------------------------
local GOLD   = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local function Money(c, short)
    if not c then return "|cff808080--|r" end
    local neg = c < 0
    c = math.floor(math.abs(c) + 0.5)
    local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = ("%d%s"):format(g, GOLD) end
    if s > 0 and not (short and g >= 100) then parts[#parts + 1] = ("%d%s"):format(s, SILVER) end
    if (cp > 0 and not (short and g >= 1)) or #parts == 0 then parts[#parts + 1] = ("%d%s"):format(cp, COPPER) end
    return (neg and "|cffff4040-|r" or "") .. table.concat(parts, " ")
end
ns.Money = Money

local function Grey(s)
    return "|cff909090" .. s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r"
end

local function Age(t)
    if not t then return "|cff808080--|r" end
    local d = time() - t
    local s
    if d < 3600 then s = ("%dm"):format(d / 60)
    elseif d < 86400 then s = ("%dh"):format(d / 3600)
    else s = ("%dd"):format(d / 86400) end
    if d > 86400 then return "|cffff6060" .. s .. "|r"
    elseif d > 3 * 3600 then return "|cffffd060" .. s .. "|r" end
    return "|cff80ff80" .. s .. "|r"
end

local function ItemName(id, fallback)
    local name, _, quality = GetItemInfo(id)
    name = name or fallback or ("item:" .. id)
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color and color.hex then return color.hex .. name .. "|r" end
    return name
end

local function Num(x)
    if x >= 10 or x % 1 == 0 then return ("%d"):format(x + 0.5) end
    return ("%.1f"):format(x)
end

local TIME_LEFT = { [0] = "|cffff4040<30m|r", [1] = "|cffffd0602h|r", [2] = "12h", [3] = "48h" }

ns.Age = Age

-- item tooltip for our own rows: the rows add their own price lines, so the
-- general price lines from Tooltip.lua are skipped here
local function SetItemTip(id)
    ns.suppressTip = true
    GameTooltip:SetItemByID(id)
    ns.suppressTip = false
end

---------------------------------------------------------------------------
-- shared bits
---------------------------------------------------------------------------
local f
local panels, tabs = {}, {}
local scanBtn, fullBtn, stopBtn, progress, statusText

local function MakeButton(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(text)
    return b
end

local function Tip(widget, text)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(type(text) == "function" and text() or text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", GameTooltip_Hide)
end

local function MakeCheck(parent, label, key, anchor, x)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("LEFT", anchor, "RIGHT", x, 0)
    local t = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("LEFT", cb, "RIGHT", 0, 0)
    t:SetText(label)
    cb.label = t
    cb.key = key
    cb:SetScript("OnClick", function(self)
        ns.db.settings[key] = self:GetChecked() and true or false
        UI.Refresh()
    end)
    return cb
end

local function MakeSearch(parent, anchor, x)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(140, 20)
    box:SetPoint("LEFT", anchor, "RIGHT", x, 0)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    local ph = box:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    ph:SetPoint("LEFT", 2, 0)
    ph:SetText("Search...")
    box:SetScript("OnTextChanged", function(self)
        ph:SetShown(self:GetText() == "")
        UI.Refresh()
    end)
    return box
end

local function SortData(data, key, desc)
    table.sort(data, function(a, b)
        local va, vb = a[key], b[key]
        if type(va) == "string" or type(vb) == "string" then
            va, vb = tostring(va or ""), tostring(vb or "")
            if va == vb then return tostring(a.name) < tostring(b.name) end
            if desc then return va > vb else return va < vb end
        end
        if va == nil and vb == nil then return tostring(a.name) < tostring(b.name) end
        if va == nil then return false end   -- unknowns always at the bottom
        if vb == nil then return true end
        if va == vb then return tostring(a.name) < tostring(b.name) end
        if desc then return va > vb else return va < vb end
    end)
end

---------------------------------------------------------------------------
-- generic table panel
-- def = { cols, sortKey, sortDesc (settings names), toolbar(p), getData(p), fill(row,d), tooltip(row,d), click(row,d), footer(p) }
---------------------------------------------------------------------------
local function BuildPanel(def)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 0, -PANEL_TOP)
    p:SetPoint("BOTTOMRIGHT", 0, 0)
    p.def, p.data = def, {}
    p:Hide()

    def.toolbar(p)

    p.headers = {}
    local x = 38
    for _, c in ipairs(def.cols) do
        local h = CreateFrame("Button", nil, p)
        h:SetSize(c.w, 18)
        h:SetPoint("TOPLEFT", x, -HEADER_Y)
        h.key, h.label = c.key, c.label
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.text:SetAllPoints()
        h.text:SetJustifyH(c.align)
        h:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight", "ADD")
        h:SetScript("OnClick", function(self)
            local s = ns.db.settings
            if s[def.sortKey] == self.key then s[def.sortDesc] = not s[def.sortDesc]
            else s[def.sortKey] = self.key; s[def.sortDesc] = not (c.align == "LEFT") end
            UI.Refresh()
        end)
        if c.tip then Tip(h, c.tip) end
        p.headers[#p.headers + 1] = h
        x = x + c.w + 4
    end

    p.scroll = CreateFrame("ScrollFrame", nil, p, "FauxScrollFrameTemplate")
    p.scroll:SetPoint("TOPLEFT", 12, -ROWS_Y)
    p.scroll:SetPoint("BOTTOMRIGHT", -32, 30)

    function p.Update()
        FauxScrollFrame_Update(p.scroll, #p.data, NUM_ROWS, ROW_H)
        local offset = FauxScrollFrame_GetOffset(p.scroll)
        for i = 1, NUM_ROWS do
            local row, d = p.rows[i], p.data[i + offset]
            row.data = d
            if d then
                if d.header then
                    row.icon:SetTexture(d.icon)
                    row.headerBg:Show()
                else
                    row.icon:SetTexture(select(10, GetItemInfo(d.item)) or d.icon or 134400)
                    row.headerBg:Hide()
                end
                def.fill(row, d)
                row:Show()
            else
                row:Hide()
            end
        end
    end
    p.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, p.Update)
    end)

    p.rows = {}
    for i = 1, NUM_ROWS do
        local row = CreateFrame("Button", nil, p)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 14, -ROWS_Y - (i - 1) * ROW_H)
        row:SetPoint("RIGHT", p.scroll, "RIGHT", 0, 0)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0.04)
        end
        row.headerBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.headerBg:SetAllPoints()
        row.headerBg:SetColorTexture(1, 0.8, 0.2, 0.12)
        row.headerBg:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ROW_H - 2, ROW_H - 2)
        row.icon:SetPoint("LEFT", 2, 0)
        row.cells = {}
        local cx = 24
        for _, c in ipairs(def.cols) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", cx, 0)
            fs:SetWidth(c.w)
            fs:SetJustifyH(c.align)
            fs:SetWordWrap(false)
            row.cells[c.key] = fs
            cx = cx + c.w + 4
        end
        row:SetScript("OnEnter", function(self) if self.data then def.tooltip(self, self.data) end end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, button)
            local d = self.data
            if not d then return end
            if d.header then
                if def.headerClick then def.headerClick(self, d, button) end
                return
            end
            if button == "RightButton" then
                if def.rightClick then def.rightClick(self, d) end
                return
            end
            if IsShiftKeyDown() then
                local _, link = GetItemInfo(d.item)
                if link then ChatEdit_InsertLink(link) end
                return
            end
            def.click(self, d)
        end)
        p.rows[i] = row
    end

    p.footer = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.footer:SetPoint("BOTTOMRIGHT", -16, 10)
    p.footer:SetJustifyH("RIGHT")

    function p.Refresh()
        p.data = def.getData(p)
        local s = ns.db.settings
        SortData(p.data, s[def.sortKey], s[def.sortDesc])
        p.flat = p.data -- before any grouping (footers count these)
        if def.postSort then p.data = def.postSort(p, p.data) end
        for _, h in ipairs(p.headers) do
            local arrow = (h.key == s[def.sortKey]) and (s[def.sortDesc] and " v" or " ^") or ""
            h.text:SetText(h.label .. arrow)
        end
        if def.onRefresh then def.onRefresh(p) end
        p.Update()
        p.footer:SetText(def.footer(p))
    end

    return p
end

---------------------------------------------------------------------------
-- Crafting tab
---------------------------------------------------------------------------
local craftDef = {
    sortKey = "sortKey", sortDesc = "sortDesc",
    cols = {
        { key = "name",    label = "Item",       w = 230, align = "LEFT" },
        { key = "prof",    label = "Profession", w = 95,  align = "LEFT" },
        { key = "bid",     label = "AH Bid",     w = 85,  align = "RIGHT" },
        { key = "buyout",  label = "AH Buyout",  w = 85,  align = "RIGHT" },
        { key = "matCost", label = "Mats Total", w = 85,  align = "RIGHT" },
        { key = "profit",  label = "Profit",     w = 90,  align = "RIGHT" },
        { key = "margin",  label = "Margin",     w = 60,  align = "RIGHT" },
        { key = "qtyAH",   label = "On AH",      w = 50,  align = "RIGHT" },
        { key = "t",       label = "Age",        w = 45,  align = "RIGHT" },
    },
}

function craftDef.toolbar(p)
    local profBtn = MakeButton(p, "All professions", 130)
    profBtn:SetPoint("TOPLEFT", 14, -2)
    profBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    profBtn:SetScript("OnClick", function(_, button)
        local list = ns.Professions()
        local cur = ns.db.settings.profFilter
        local nextP
        if button == "RightButton" then nextP = nil
        elseif not cur then nextP = list[1]
        else for i, pr in ipairs(list) do if pr == cur then nextP = list[i + 1] end end end
        ns.db.settings.profFilter = nextP
        UI.Refresh()
    end)
    Tip(profBtn, "Left-click: next profession. Right-click: show all.")
    p.profBtn = profBtn
    p.search = MakeSearch(p, profBtn, 14)
    p.checks = {}
    p.checks[1] = MakeCheck(p, "Profitable only", "profitableOnly", p.search, 10)
    p.checks[2] = MakeCheck(p, "All characters", "allChars", p.checks[1].label, 8)
end

function craftDef.getData(p)
    local out = {}
    local q = p.search:GetText():lower()
    local prof = ns.db.settings.profFilter
    for _, r in ipairs(ns.Rows()) do
        if (not prof or r.prof == prof)
            and (q == "" or tostring(r.name):lower():find(q, 1, true))
            and (not ns.db.settings.profitableOnly or (r.profit and r.profit > 0)) then
            r.icon = r.recipe.icon
            out[#out + 1] = r
        end
    end
    return out
end

function craftDef.onRefresh(p)
    p.profBtn:SetText(ns.db.settings.profFilter or "All professions")
end

function craftDef.fill(row, d)
    local c = row.cells
    local qty = d.recipe.qty or 1
    local nm = ItemName(d.item, d.name)
    if qty ~= 1 then nm = nm .. " |cffaaaaaax" .. Num(qty) .. "|r" end
    c.name:SetText(nm)
    c.prof:SetText(d.prof)
    c.bid:SetText(Money(d.bid, true))
    c.buyout:SetText(d.buyoutOld and Grey("(" .. Money(d.buyout, true) .. ")") or Money(d.buyout, true))
    c.matCost:SetText(d.missing > 0 and ("|cffff8080? |r" .. Money(d.matCost, true)) or Money(d.matCost, true))
    if d.profit then
        c.profit:SetText(Money(d.profit, true))
        local pct = d.margin and (d.margin * 100)
        local col = (not pct and "ffffff") or (pct >= 30 and "40ff40") or (pct > 0 and "ffff40") or "ff4040"
        c.margin:SetText(pct and ("|cff%s%d%%|r"):format(col, pct) or "--")
    else
        c.profit:SetText("|cff808080--|r")
        c.margin:SetText("|cff808080--|r")
    end
    if d.qtyAH == 0 and not d.buyout then c.qtyAH:SetText("|cff40ff40none|r")
    else c.qtyAH:SetText(d.qtyAH and tostring(d.qtyAH) or "|cff808080--|r") end
    c.t:SetText(Age(d.t))
end

function craftDef.tooltip(row, d)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    SetItemTip(d.item)
    GameTooltip:AddLine(" ")
    local qty = d.recipe.qty or 1
    GameTooltip:AddLine(("|cffffcc33GoblinLedger|r - %s (makes %s)"):format(d.prof, Num(qty)))
    GameTooltip:AddLine("Materials:", 1, 0.82, 0)
    for _, m in ipairs(d.mats) do
        local src = (m.src == "vendor" and " |cff80c0ffvendor|r") or (m.src == "ah-old" and " |cff909090old|r") or ""
        local right = m.unit and (Money(m.unit) .. " = " .. Money(m.total) .. src) or "|cffff8080no price|r"
        GameTooltip:AddDoubleLine(("%dx %s"):format(m.count, ItemName(m.id)), right, 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Materials total", Money(d.matCost) .. (d.missing > 0 and " |cffff8080(incomplete)|r" or ""), 1, 0.82, 0, 1, 1, 1)
    if d.value then
        local cut = ns.db.settings.ahCut or 0.05
        GameTooltip:AddDoubleLine(("Sell (buyout x%s, -%d%% cut)"):format(Num(qty), cut * 100), Money(d.value * (1 - cut)), 1, 0.82, 0, 1, 1, 1)
    end
    if d.profit then GameTooltip:AddDoubleLine("Profit at buyout", Money(d.profit), 1, 0.82, 0, 1, 1, 1) end
    if d.bidProfit then GameTooltip:AddDoubleLine("Profit at bid", Money(d.bidProfit), 1, 0.82, 0, 1, 1, 1) end
    if d.qtyAH == 0 and not d.buyout then
        GameTooltip:AddLine("None on the AH right now - you set the price!", 0.25, 1, 0.25)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: rescan this item + mats (AH open)   Shift-click: link", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function craftDef.click(row, d)
    local ids = { d.item }
    for _, m in ipairs(d.mats) do ids[#ids + 1] = m.id end
    ns.Scanner.StartTargeted(false, ids)
end

function craftDef.footer(p)
    local n = 0
    for _, d in ipairs(p.data) do if d.profit and d.profit > 0 then n = n + 1 end end
    return ("%d recipes  |  %d profitable"):format(#p.data, n)
end

---------------------------------------------------------------------------
-- Disenchant tab
---------------------------------------------------------------------------
local Z90 = 1.645 -- 90% two-sided range

local deDef = {
    sortKey = "deSortKey", sortDesc = "deSortDesc",
    cols = {
        { key = "name",      label = "Item",        w = 220, align = "LEFT" },
        { key = "ilvl",      label = "iLvl",        w = 35,  align = "RIGHT" },
        { key = "kind",      label = "Type",        w = 55,  align = "LEFT" },
        { key = "bid",       label = "Bid to win",  w = 85,  align = "RIGHT", tip = "The bid you need to place to become the high bidder." },
        { key = "buyout",    label = "Buyout",      w = 85,  align = "RIGHT" },
        { key = "ev",        label = "DE Value",    w = 85,  align = "RIGHT", tip = "Average sale value of the mats from one disenchant, after the AH cut, using drop chances and current mat prices." },
        { key = "profitBid", label = "Profit (bid)", w = 90, align = "RIGHT" },
        { key = "profitBuy", label = "Profit (buy)", w = 90, align = "RIGHT" },
        { key = "tl",        label = "Time",        w = 40,  align = "RIGHT", tip = "Time left on the auction (only known from item searches)." },
        { key = "t",         label = "Seen",        w = 40,  align = "RIGHT" },
    },
}

function deDef.toolbar(p)
    p.search = MakeSearch(p, p, 0)
    p.search:ClearAllPoints()
    p.search:SetPoint("TOPLEFT", 20, -3)
    p.checks = {}
    p.checks[1] = MakeCheck(p, "Profitable only", "deProfitableOnly", p.search, 10)
    p.checks[2] = MakeCheck(p, "Bids only", "deBidsOnly", p.checks[1].label, 8)

    local lbl = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", p.checks[2].label, "RIGHT", 18, 0)
    lbl:SetText("Batch size:")
    local box = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    box:SetSize(36, 20)
    box:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(3)
    box:SetScript("OnShow", function(self) self:SetText(tostring(ns.db.settings.deBatch or 20)) end)
    local function apply(self)
        local n = tonumber(self:GetText())
        if n and n > 0 then ns.db.settings.deBatch = n end
        self:SetText(tostring(ns.db.settings.deBatch))
        self:ClearFocus()
        UI.Refresh()
    end
    box:SetScript("OnEnterPressed", apply)
    box:SetScript("OnEditFocusLost", function(self)
        local n = tonumber(self:GetText())
        if n and n > 0 and n ~= ns.db.settings.deBatch then ns.db.settings.deBatch = n; UI.Refresh() end
    end)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    Tip(box, "Hover any row to see what buying this many of that item and disenchanting them would give you on average.")

    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", box, "RIGHT", 12, 0)
    hint:SetText("Data comes from Full Scan and from items you click into on the AH.")
end

function deDef.getData(p)
    local out = {}
    local q = p.search:GetText():lower()
    local s = ns.db.settings
    for _, r in ipairs(ns.DE.Rows()) do
        if (q == "" or tostring(r.name):lower():find(q, 1, true))
            and (not s.deBidsOnly or r.bid)
            and (not s.deProfitableOnly or (r.profitBid and r.profitBid > 0) or (r.profitBuy and r.profitBuy > 0)) then
            out[#out + 1] = r
        end
    end
    return out
end

local function ProfitText(v)
    if not v then return "|cff808080--|r" end
    return Money(v, true)
end

function deDef.fill(row, d)
    local c = row.cells
    c.name:SetText(ItemName(d.item, d.name) .. (d.n > 1 and (" |cffaaaaaax" .. d.n .. "|r") or ""))
    c.ilvl:SetText(d.ilvl and tostring(d.ilvl) or "|cff808080...|r")
    c.kind:SetText(d.kind)
    c.bid:SetText(Money(d.bid, true))
    c.buyout:SetText(Money(d.buyout, true))
    if d.ev then
        c.ev:SetText((d.missing and "|cffff8080? |r" or "") .. Money(d.ev, true))
    else
        c.ev:SetText("|cff808080...|r")
    end
    c.profitBid:SetText(ProfitText(d.profitBid))
    c.profitBuy:SetText(ProfitText(d.profitBuy))
    c.tl:SetText(d.tl and TIME_LEFT[d.tl] or "|cff808080--|r")
    c.t:SetText(Age(d.t))
end

function deDef.tooltip(row, d)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    SetItemTip(d.item)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffcc33GoblinLedger|r - Disenchant")
    if not d.outs then
        GameTooltip:AddLine("Waiting for item info (quality / item level)...", 0.7, 0.7, 0.7)
        GameTooltip:Show()
        return
    end
    if d.beyond then GameTooltip:AddLine("Item level is above the drop table - estimate only.", 1, 0.5, 0.2) end
    GameTooltip:AddLine("Per disenchant:", 1, 0.82, 0)
    for _, o in ipairs(d.outs) do
        local qty = o.a == o.b and tostring(o.a) or (o.a .. "-" .. o.b)
        local left = ("%s%%  %sx %s"):format(Num(o.p * 100), qty, ItemName(o.id))
        local right
        if o.price > 0 then
            right = Money(o.price) .. " ea" .. (o.old and " |cff909090old|r" or "") .. "  -> " .. Money(o.ev)
        else
            right = "|cffff8080no price - scan the AH|r"
        end
        GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Expected value (after cut)", Money(d.ev), 1, 0.82, 0, 1, 1, 1)
    if d.bid then GameTooltip:AddDoubleLine("Profit if you win at bid", Money(d.profitBid), 1, 0.82, 0, 1, 1, 1) end
    if d.buyout then GameTooltip:AddDoubleLine("Profit at buyout", Money(d.profitBuy), 1, 0.82, 0, 1, 1, 1) end

    -- batch projection
    local N = ns.db.settings.deBatch or 20
    local price = d.bid or d.buyout
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("If you bought %d like this and disenchanted them:"):format(N), 1, 0.82, 0)
    for _, o in ipairs(d.outs) do
        local expect = o.p * o.eq * N * (d.n or 1)
        if expect >= 0.05 then
            GameTooltip:AddLine(("  ~%s %s"):format(Num(expect), ItemName(o.id)), 1, 1, 1)
        end
    end
    local evN = d.ev * N
    local sd = math.sqrt(d.var * N)
    GameTooltip:AddDoubleLine("  Mats worth (average)", Money(evN), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("  90% of the time between", Money(math.max(0, evN - Z90 * sd)) .. " - " .. Money(evN + Z90 * sd), 1, 1, 1, 1, 1, 1)
    if price then
        local cost = price * N
        GameTooltip:AddDoubleLine(("  Cost (%s)"):format(d.bid and "at bid" or "at buyout"), Money(cost), 1, 1, 1, 1, 1, 1)
        local profit = evN - cost
        GameTooltip:AddDoubleLine("  Expected profit", Money(profit), 1, 0.82, 0, profit >= 0 and 0.3 or 1, profit >= 0 and 1 or 0.3, 0.3)
        -- chance the batch ends up profitable (normal approximation)
        if sd > 0 then
            local z = (evN - cost) / sd
            local pWin = 0.5 * (1 + (z >= 0 and 1 or -1) * math.sqrt(1 - math.exp(-2 * z * z / math.pi)))
            GameTooltip:AddDoubleLine("  Chance the batch makes money", ("%d%%"):format(pWin * 100 + 0.5), 1, 1, 1, 1, 1, 1)
        end
    end
    if d.missing then GameTooltip:AddLine("Some mats have no price yet, value is too low.", 1, 0.5, 0.5) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: rescan this item (AH open)   Shift-click: link", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function deDef.click(row, d)
    ns.Scanner.StartTargeted(false, { d.item })
end

-- "if I won every profitable bid in this list"
function deDef.footer(p)
    local n, cost, ev, var = 0, 0, 0, 0
    for _, d in ipairs(p.data) do
        if d.profitBid and d.profitBid > 0 then
            n, cost, ev, var = n + 1, cost + d.bid, ev + d.ev, var + (d.var or 0)
        end
    end
    if n == 0 then return ("%d auctions  |  no profitable bids right now"):format(#p.data) end
    local sd = math.sqrt(var)
    return ("Win all %d profitable bids: cost %s, mats ~%s (90%%: %s - %s), profit ~%s"):format(
        n, Money(cost, true), Money(ev, true), Money(math.max(0, ev - Z90 * sd), true), Money(ev + Z90 * sd, true), Money(ev - cost, true))
end

---------------------------------------------------------------------------
-- Vendor Flips tab: AH auctions cheaper than what a vendor pays
---------------------------------------------------------------------------
local flipDef = {
    sortKey = "flipSortKey", sortDesc = "flipSortDesc",
    cols = {
        { key = "name",   label = "Item",        w = 240, align = "LEFT" },
        { key = "kind",   label = "Type",        w = 60,  align = "LEFT", tip = "Buyout: buy now (all cheap listings of this item together). Bid: you only get it if nobody outbids you." },
        { key = "n",      label = "Qty",         w = 45,  align = "RIGHT" },
        { key = "cost",   label = "Cost",        w = 90,  align = "RIGHT" },
        { key = "value",  label = "Vendor pays", w = 90,  align = "RIGHT" },
        { key = "profit", label = "Profit",      w = 90,  align = "RIGHT" },
        { key = "margin", label = "Margin",      w = 60,  align = "RIGHT" },
        { key = "tl",     label = "Time",        w = 45,  align = "RIGHT", tip = "Time left on the auction (only known from item searches)." },
        { key = "t",      label = "Seen",        w = 45,  align = "RIGHT" },
    },
}

function flipDef.toolbar(p)
    p.search = MakeSearch(p, p, 0)
    p.search:ClearAllPoints()
    p.search:SetPoint("TOPLEFT", 20, -3)
    p.checks = {}
    p.checks[1] = MakeCheck(p, "Hide bids", "flipNoBids", p.search, 10)
    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", p.checks[1].label, "RIGHT", 16, 0)
    hint:SetText("Found by Full Scan and by whatever you browse on the AH. Buy, then sell to any vendor.")
end

function flipDef.getData(p)
    local out = {}
    local q = p.search:GetText():lower()
    local s = ns.db.settings
    for _, r in ipairs(ns.Flips.FlipRows()) do
        if (q == "" or tostring(r.name):lower():find(q, 1, true))
            and not (s.flipNoBids and r.kind == "Bid") then
            out[#out + 1] = r
        end
    end
    return out
end

local function MarginText(m)
    if not m then return "|cff808080--|r" end
    local pct = m * 100
    local col = (pct >= 30 and "40ff40") or (pct > 0 and "ffff40") or "ff4040"
    if pct >= 1000 then return ("|cff%s>999%%|r"):format(col) end
    return ("|cff%s%d%%|r"):format(col, pct)
end

function flipDef.fill(row, d)
    local c = row.cells
    c.name:SetText(ItemName(d.item, d.name))
    c.kind:SetText(d.kind == "Bid" and "|cffffd060Bid|r" or "Buyout")
    c.n:SetText(tostring(d.n))
    c.cost:SetText(Money(d.cost, true))
    c.value:SetText(Money(d.value, true))
    c.profit:SetText(Money(d.profit, true))
    c.margin:SetText(MarginText(d.margin))
    c.tl:SetText(d.tl and TIME_LEFT[d.tl] or "|cff808080--|r")
    c.t:SetText(Age(d.t))
end

function flipDef.tooltip(row, d)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    SetItemTip(d.item)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffcc33GoblinLedger|r - Vendor flip")
    GameTooltip:AddDoubleLine("Vendor pays (each)", Money(d.sell), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine(d.kind == "Bid" and "Auction:" or "Listings under vendor price:", 1, 0.82, 0)
    for i, a in ipairs(d.auctions) do
        if i > 10 then GameTooltip:AddLine(("  ...and %d more"):format(#d.auctions - 10), 0.7, 0.7, 0.7) break end
        local price = d.kind == "Bid" and a.bid or a.buy
        GameTooltip:AddDoubleLine(("  %dx  (%s each)"):format(a.n or 1, Money(price / (a.n or 1))), Money(price), 1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Profit", Money(d.profit), 1, 0.82, 0, 0.3, 1, 0.3)
    if d.src == "browse" then
        GameTooltip:AddLine("From the browse list (cheapest only) - click to see every listing.", 0.7, 0.7, 0.7, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: open on the AH to buy   Shift-click: link", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function flipDef.click(row, d)
    local a = d.auctions and d.auctions[1]
    ns.Flips.ShowOnAH(d.item, a and a.buy and math.floor(a.buy / (a.n or 1)))
end

function flipDef.footer(p)
    local n, cost, value = 0, 0, 0
    for _, d in ipairs(p.data) do
        if d.kind == "Buyout" then n, cost, value = n + 1, cost + d.cost, value + d.value end
    end
    if n == 0 then return ("%d flips"):format(#p.data) end
    return ("Buy out all %d items: cost %s, vendor pays %s, profit %s"):format(n, Money(cost, true), Money(value, true), Money(value - cost, true))
end

---------------------------------------------------------------------------
-- Vendor Recipes tab: recipes sold by NPCs vs. their AH price (Data/VendorDB.lua)
---------------------------------------------------------------------------
local recDef = {
    sortKey = "recSortKey", sortDesc = "recSortDesc",
    cols = {
        { key = "name",   label = "Recipe",      w = 190, align = "LEFT" },
        { key = "prof",   label = "Profession",  w = 80,  align = "LEFT" },
        { key = "npc",    label = "Vendor",      w = 105, align = "LEFT" },
        { key = "loc",    label = "Location",    w = 150, align = "LEFT", tip = "Where the vendor stands. Right-click a row to set a waypoint there." },
        { key = "lim",    label = "Stock",       w = 45,  align = "LEFT", tip = "Limited: the vendor only has a few and restocks over time - these sell best on the AH." },
        { key = "cost",   label = "Vendor cost", w = 70,  align = "RIGHT" },
        { key = "ah",     label = "AH Buyout",   w = 75,  align = "RIGHT" },
        { key = "profit", label = "Profit",      w = 75,  align = "RIGHT", tip = "AH buyout minus the AH cut minus the vendor price (before any reputation discount)." },
        { key = "margin", label = "Margin",      w = 50,  align = "RIGHT" },
        { key = "qtyAH",  label = "On AH",       w = 40,  align = "RIGHT" },
        { key = "t",      label = "Age",         w = 35,  align = "RIGHT" },
    },
}

function recDef.toolbar(p)
    p.search = MakeSearch(p, p, 0)
    p.search:ClearAllPoints()
    p.search:SetPoint("TOPLEFT", 20, -3)
    p.checks = {}
    p.checks[1] = MakeCheck(p, "My faction", "recMyFaction", p.search, 10)
    p.checks[2] = MakeCheck(p, "Limited only", "recLimitedOnly", p.checks[1].label, 8)
    p.checks[3] = MakeCheck(p, "Profitable only", "recProfitableOnly", p.checks[2].label, 8)
    p.checks[4] = MakeCheck(p, "By zone", "recGroup", p.checks[3].label, 8)
    Tip(p.checks[4], "Group the recipes by the zone you buy them in. Click a zone to open or close it, right-click it for a waypoint to the nearest vendor there.")
    local btn = MakeButton(p, "Scan list", 90)
    btn:SetPoint("LEFT", p.checks[4].label, "RIGHT", 16, 0)
    btn:SetScript("OnClick", function()
        local ids, seen = {}, {}
        for _, d in ipairs(p.flat or p.data) do
            if d.item and not seen[d.item] then seen[d.item] = true; ids[#ids + 1] = d.item end
        end
        if #ids > 0 then ns.Scanner.StartTargeted(false, ids) end
    end)
    Tip(btn, function()
        return ("Search the AH for the %d recipes in this list (about 1 per second). A Full Scan prices all of them at once."):format(#(p.flat or p.data))
    end)
    p.noData = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.noData:SetPoint("CENTER", 0, 20)
    p.noData:SetText("Recipe vendor database missing - reinstall GoblinLedger (Data/VendorDB.lua).")
end

-- search text in any vendor's name, zone or town
local function VendorMatches(r, q, mineOnly)
    for _, v in ipairs(r.recipe.vendors) do
        if not mineOnly or ns.Flips.CanUse(v) then
            if v.npc:lower():find(q, 1, true) or tostring(v.zone):lower():find(q, 1, true)
                or (v.town and v.town:lower():find(q, 1, true)) then
                return true
            end
        end
    end
    return false
end

-- some vendor (one you can use, when "My faction" is on) has it in limited stock
local function AnyLimited(r, mineOnly)
    for _, v in ipairs(r.recipe.vendors) do
        if v.limited and (not mineOnly or ns.Flips.CanUse(v)) then return true end
    end
    return false
end

function recDef.getData(p)
    local out = {}
    p.noData:SetShown(not ns.Flips.HasRecipeData())
    local q = p.search:GetText():lower()
    local s = ns.db.settings
    for _, r in ipairs(ns.Flips.RecipeRows(s.recMyFaction)) do
        if (q == "" or tostring(r.name):lower():find(q, 1, true) or VendorMatches(r, q, s.recMyFaction))
            and (not s.recLimitedOnly or r.lim == 1 or (s.recGroup and AnyLimited(r, s.recMyFaction)))
            and (not s.recProfitableOnly or (r.profit and r.profit > 0)) then
            out[#out + 1] = r
        end
    end
    return out
end

local SIDE_COLOR = { alliance = "|cff4090ff", horde = "|cffff4040", both = "|cffffffff" }

local function FillZoneHeader(row, g)
    local c = row.cells
    for _, fs in pairs(c) do fs:SetText("") end
    c.name:SetText(("%s|cffffd100%s|r |cff909090(%d)|r"):format(g.here and "|cff40ff40>|r " or "", g.zone, g.n))
    c.npc:SetText(g.prof > 0 and ("|cff40ff40%d profitable|r"):format(g.prof) or "|cff808080none profitable|r")
    c.loc:SetText(g.towns)
    if g.lim > 0 then c.lim:SetText(("|cffff9030%d|r"):format(g.lim)) end
    if g.profit > 0 then c.profit:SetText(Money(g.profit, true)) end
end

function recDef.fill(row, d)
    if d.header then return FillZoneHeader(row, d) end
    local c = row.cells
    c.name:SetText(ItemName(d.item, d.name))
    c.prof:SetText(d.prof)
    c.npc:SetText(d.otherSide and Grey(d.npc) or d.npc)
    local loc = d.loc or "?"
    if not d.vendor.map then loc = loc .. " |cff808080(?)|r" end
    c.loc:SetText(d.otherSide and Grey(loc) or loc)
    c.lim:SetText(d.lim == 1 and "|cffff9030Limited|r" or "|cff909090-|r")
    c.cost:SetText(Money(d.cost, true))
    if d.ah then
        local txt = Money(d.ah, true)
        if d.src ~= "cp" then txt = Grey("(" .. txt .. ")") end
        c.ah:SetText(txt)
    elseif d.src == "none" then
        c.ah:SetText("|cff40ff40none|r")
    else
        c.ah:SetText("|cff808080--|r")
    end
    c.profit:SetText(d.profit and Money(d.profit, true) or "|cff808080--|r")
    c.margin:SetText(MarginText(d.margin))
    c.qtyAH:SetText(d.qtyAH and tostring(d.qtyAH) or "|cff808080--|r")
    c.t:SetText(Age(d.t))
end

-- where a vendor entry comes from
local SRC_TAG = {
    recorded = "  |cff40ff40(seen by you)|r",
    shared = "  |cff80c0ff(shared by a player)|r",
    ledger = "  |cff40ff40(verified)|r",
}

local SRC_NAME = { cp = "GoblinLedger scan", old = "last seen (none listed now)", auctionator = "Auctionator" }

function recDef.tooltip(row, d)
    if d.header then return recDef.headerTooltip(row, d) end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    SetItemTip(d.item)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("|cffffcc33GoblinLedger|r - %s%s"):format(d.prof, d.recipe.skill and (" (" .. d.recipe.skill .. ")") or ""))
    GameTooltip:AddLine("Sold by:", 1, 0.82, 0)
    for _, v in ipairs(d.recipe.vendors) do
        local left = ("  %s%s|r - %s"):format(SIDE_COLOR[v.side] or "|cffffffff", v.npc, ns.Flips.WhereLong(v))
        if v.limited then left = left .. "  |cffff9030limited|r" end
        left = left .. (SRC_TAG[v.src] or "")
        GameTooltip:AddDoubleLine(left, Money(v.price), 1, 1, 1, 1, 1, 1)
        if v.rep then GameTooltip:AddLine("      needs " .. v.rep, 0.6, 0.8, 1) end
    end
    if d.otherSide then GameTooltip:AddLine("Only sold to the other faction.", 1, 0.5, 0.3) end
    if d.ah then
        GameTooltip:AddDoubleLine("AH buyout", Money(d.ah) .. " |cff909090" .. (SRC_NAME[d.src] or d.src or "") .. "|r", 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Profit (after AH cut)", Money(d.profit), 1, 0.82, 0, 1, 1, 1)
    elseif d.src == "none" then
        GameTooltip:AddLine("None on the AH right now - you set the price!", 0.25, 1, 0.25)
    else
        GameTooltip:AddLine("No AH price yet - Full Scan or click to search.", 1, 0.5, 0.5)
    end
    GameTooltip:AddLine(" ")
    local near, dist = ns.Flips.Nearest(d.recipe.vendors)
    if near and #d.recipe.vendors > 1 then
        GameTooltip:AddLine(("Nearest to you: %s - %s (%d yd)"):format(near.npc, ns.Flips.Where(near), math.floor(dist)), 0.6, 1, 0.6)
    end
    GameTooltip:AddLine("Click: open on the AH   Shift-click: link", 0.6, 0.6, 0.6)
    GameTooltip:AddLine(("Right-click: waypoint to %s   Ctrl-right-click: nearest vendor"):format(d.npc), 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function recDef.click(row, d)
    ns.Flips.ShowOnAH(d.item, d.ah)
end

function recDef.rightClick(row, d)
    local what = d.name
    if IsControlKeyDown() then
        local near = ns.Flips.Nearest(d.recipe.vendors)
        if near then ns.Flips.Waypoint(near, what) return end
        ns.Print("No vendor for this recipe on your continent - using the one in the list.")
    end
    ns.Flips.Waypoint(d.vendor, what)
end

function recDef.footer(p)
    local list = p.flat or p.data
    local n, lim = 0, 0
    for _, d in ipairs(list) do
        if d.profit and d.profit > 0 then
            n = n + 1
            if d.lim == 1 then lim = lim + 1 end
        end
    end
    local txt = ("%d recipes  |  %d profitable (%d limited stock)"):format(#list, n, lim)
    if p.zoneCount then txt = ("%d zones  |  "):format(p.zoneCount) .. txt end
    return txt
end

---------------------------------------------------------------------------
-- Vendor Recipes grouped by zone
---------------------------------------------------------------------------
-- the same recipe row, but bought from vendor v
local function RowForVendor(d, v, cut)
    local r = {}
    for k, val in pairs(d) do r[k] = val end
    r.vendor, r.npc, r.cost, r.loc = v, v.npc, v.price, ns.Flips.Where(v)
    r.lim = v.limited and 1 or 0
    r.otherSide = not ns.Flips.CanUse(v)
    r.profit, r.margin = nil, nil
    if d.ah then
        r.profit = math.floor(d.ah * (1 - cut) - v.price)
        r.margin = r.profit / v.price
    end
    return r
end

function recDef.postSort(p, data)
    p.zoneCount = nil
    local s = ns.db.settings
    if not s.recGroup then return data end
    local cut = s.ahCut or 0.05
    local groups, order = {}, {}
    for _, d in ipairs(data) do
        -- every zone this recipe is sold in (cheapest vendor there; vendors are sorted by price)
        local perZone, zones = {}, {}
        for _, v in ipairs(d.recipe.vendors) do
            local usable = ns.Flips.CanUse(v)
            if usable or not s.recMyFaction then
                local z = v.zone or "?"
                local cur = perZone[z]
                if not cur then zones[#zones + 1] = z end
                -- prefer one your faction can use
                if not cur or (usable and not ns.Flips.CanUse(cur)) then perZone[z] = v end
            end
        end
        for _, z in ipairs(zones) do
            local r = (perZone[z] == d.vendor) and d or RowForVendor(d, perZone[z], cut)
            if (not s.recLimitedOnly or r.lim == 1) and (not s.recProfitableOnly or (r.profit and r.profit > 0)) then
                local g = groups[z]
                if not g then
                    g = { header = true, zone = z, rows = {}, n = 0, prof = 0, lim = 0, profit = 0, townSet = {}, towns = "" }
                    groups[z] = g
                    order[#order + 1] = g
                end
                g.rows[#g.rows + 1] = r
                g.n = g.n + 1
                if r.lim == 1 then g.lim = g.lim + 1 end
                if r.profit and r.profit > 0 then g.prof, g.profit = g.prof + 1, g.profit + r.profit end
                local t = r.vendor.town
                if t and t ~= z and not g.townSet[t] then
                    g.townSet[t] = true
                    g.towns = g.towns == "" and t or (g.towns .. ", " .. t)
                end
            end
        end
    end
    local here = GetRealZoneText and GetRealZoneText()
    table.sort(order, function(a, b)
        if (a.zone == here) ~= (b.zone == here) then return a.zone == here end
        return a.zone < b.zone
    end)
    local openAll = p.search:GetText() ~= "" -- searching: show the matches
    local out = {}
    for _, g in ipairs(order) do
        g.here = g.zone == here
        g.open = openAll or s.recOpen[g.zone] == true
        g.icon = g.open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up"
        out[#out + 1] = g
        if g.open then
            for _, r in ipairs(g.rows) do out[#out + 1] = r end
        end
    end
    p.zoneCount = #order
    return out
end

-- distinct vendors in a zone group
local function GroupVendors(g)
    local list, seen = {}, {}
    for _, r in ipairs(g.rows) do
        local v = r.vendor
        if not seen[v] then seen[v] = true; list[#list + 1] = v end
    end
    return list
end

function recDef.headerClick(row, g, button)
    if button == "RightButton" then
        local vendors = GroupVendors(g)
        local near = ns.Flips.Nearest(vendors)
        if not near then
            for _, v in ipairs(vendors) do if v.map and ns.Flips.CanUse(v) then near = v break end end
        end
        ns.Flips.Waypoint(near or vendors[1], g.zone .. " recipes")
        return
    end
    local open = ns.db.settings.recOpen
    open[g.zone] = not open[g.zone] or nil
    UI.Refresh()
end

function recDef.headerTooltip(row, g)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(g.zone, 1, 0.82, 0)
    GameTooltip:AddLine(("%d recipes, %d profitable, %d limited stock"):format(g.n, g.prof, g.lim), 1, 1, 1)
    if g.profit > 0 then
        GameTooltip:AddDoubleLine("Buy every profitable one", "~" .. Money(g.profit) .. " profit", 1, 0.82, 0, 0.3, 1, 0.3)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Vendors:", 1, 0.82, 0)
    local count = {}
    for _, r in ipairs(g.rows) do count[r.vendor] = (count[r.vendor] or 0) + 1 end
    local vendors = GroupVendors(g)
    table.sort(vendors, function(a, b) return (count[a] or 0) > (count[b] or 0) end)
    for i, v in ipairs(vendors) do
        if i > 12 then GameTooltip:AddLine(("  ...and %d more"):format(#vendors - 12), 0.7, 0.7, 0.7) break end
        local where = ns.Flips.WhereLong(v)
        GameTooltip:AddDoubleLine(("  %s - %s"):format(v.npc, where), ("%d"):format(count[v]), 1, 1, 1, 0.7, 0.7, 0.7)
    end
    local near, dist = ns.Flips.Nearest(vendors)
    if near then GameTooltip:AddLine(("Nearest: %s (%d yd)"):format(near.npc, math.floor(dist)), 0.6, 1, 0.6) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: open / close   Right-click: waypoint to the nearest vendor here", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Bags tab: what in your bags is worth selling, and where
---------------------------------------------------------------------------
local bagDef = {
    sortKey = "bagSortKey", sortDesc = "bagSortDesc",
    cols = {
        { key = "name",    label = "Item",         w = 205, align = "LEFT" },
        { key = "n",       label = "Qty",          w = 40,  align = "RIGHT" },
        { key = "vendor",  label = "Vendor pays",  w = 85,  align = "RIGHT", tip = "What a vendor pays (each / per stack / for all, see the Values button)." },
        { key = "ah",      label = "AH Buyout",    w = 85,  align = "RIGHT", tip = "Cheapest buyout per item. Grey (in brackets) = none listed right now, last price seen." },
        { key = "ahTotal", label = "AH net",       w = 90,  align = "RIGHT", tip = "At the cheapest buyout, after the AH cut (each / per stack / for all)." },
        { key = "where",   label = "Sell at",      w = 55,  align = "LEFT" },
        { key = "best",    label = "Best value",   w = 85,  align = "RIGHT" },
        { key = "gain",    label = "AH vs vendor", w = 85,  align = "RIGHT", tip = "How much more (or less) the AH pays than a vendor (each / per stack / for all)." },
        { key = "qtyAH",   label = "On AH",        w = 50,  align = "RIGHT" },
        { key = "t",       label = "Age",          w = 45,  align = "RIGHT" },
    },
}

function bagDef.toolbar(p)
    p.search = MakeSearch(p, p, 0)
    p.search:ClearAllPoints()
    p.search:SetPoint("TOPLEFT", 20, -3)
    p.checks = {}
    local VIEWS = { "each", "stack", "all" }
    local VIEW_TEXT = { each = "Values: Each", stack = "Values: Stack", all = "Values: All" }
    local viewBtn = MakeButton(p, VIEW_TEXT.each, 110)
    viewBtn:SetPoint("LEFT", p.search, "RIGHT", 10, 0)
    viewBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    viewBtn:SetScript("OnClick", function(_, button)
        local cur = ns.db.settings.bagView or "each"
        local i = 1
        for k, v in ipairs(VIEWS) do if v == cur then i = k end end
        i = button == "RightButton" and ((i - 2) % #VIEWS + 1) or (i % #VIEWS + 1)
        ns.db.settings.bagView = VIEWS[i]
        UI.Refresh()
    end)
    Tip(viewBtn, "What the money columns show: one item (Each), one full stack (Stack), or everything you have (All). Click to switch.")
    p.viewBtn, p.viewText = viewBtn, VIEW_TEXT
    p.checks[1] = MakeCheck(p, "AH pays more", "bagAHOnly", viewBtn, 10)
    local btn = MakeButton(p, "Scan bag items", 120)
    btn:SetPoint("LEFT", p.checks[1].label, "RIGHT", 16, 0)
    btn:SetScript("OnClick", function()
        local ids = {}
        for _, d in ipairs(p.data) do ids[#ids + 1] = d.item end
        if #ids > 0 then ns.Scanner.StartTargeted(false, ids) end
    end)
    btn:SetMotionScriptsWhileDisabled(true)
    Tip(btn, function()
        if not ns.Scanner.open then return "Open the Auction House first." end
        return ("Search the AH for the %d items in this list (about 1 per second). A Full Scan prices all of them at once."):format(#p.data)
    end)
    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", btn, "RIGHT", 12, 0)
    hint:SetText("Soulbound items are left out.")
end

-- header labels say what the money columns are for
local BAG_SUFFIX = { each = " (each)", stack = " (stack)", all = " (all)" }
local BAG_MONEY = { vendor = "Vendor", ahTotal = "AH net", best = "Best", gain = "AH vs vend." }
function bagDef.onRefresh(p)
    local s = ns.db.settings
    local view = s.bagView or "each"
    p.viewBtn:SetText(p.viewText[view] or p.viewText.each)
    for _, h in ipairs(p.headers) do
        local base = BAG_MONEY[h.key]
        if base then
            h.label = base .. BAG_SUFFIX[view]
            local arrow = (h.key == s[bagDef.sortKey]) and (s[bagDef.sortDesc] and " v" or " ^") or ""
            h.text:SetText(h.label .. arrow)
        end
    end
end

function bagDef.getData(p)
    local out = {}
    local q = p.search:GetText():lower()
    local ahOnly = ns.db.settings.bagAHOnly
    for _, r in ipairs(ns.Bags.Rows(ns.db.settings.bagView or "each")) do
        if (q == "" or tostring(r.name):lower():find(q, 1, true))
            and (not ahOnly or r.where == "AH") then
            out[#out + 1] = r
        end
    end
    return out
end

function bagDef.fill(row, d)
    local c = row.cells
    c.name:SetText(ItemName(d.item, d.name))
    local qty = tostring(d.n)
    if (ns.db.settings.bagView or "each") == "stack" and d.stackMax > 1 then qty = qty .. " |cff909090/" .. d.stackMax .. "|r" end
    c.n:SetText(qty)
    if d.vendorEach == 0 then c.vendor:SetText("|cff808080can't|r")
    else c.vendor:SetText(Money(d.vendor, true)) end
    if d.ah then
        c.ah:SetText(d.ahOld and Grey("(" .. Money(d.ah, true) .. ")") or Money(d.ah, true))
        c.ahTotal:SetText(d.ahOld and Grey(Money(d.ahTotal, true)) or Money(d.ahTotal, true))
    elseif d.qtyAH == 0 then
        c.ah:SetText("|cff40ff40none|r")
        c.ahTotal:SetText("|cff808080--|r")
    else
        c.ah:SetText("|cff808080--|r")
        c.ahTotal:SetText("|cff808080--|r")
    end
    c.where:SetText((d.where == "AH" and "|cffffcc33AH|r") or (d.where == "Vendor" and "|cff80c0ffVendor|r") or "|cff808080?|r")
    c.best:SetText(Money(d.best, true))
    if d.gain then
        c.gain:SetText(d.gain > 0 and ("|cff40ff40+|r" .. Money(d.gain, true)) or Money(d.gain, true))
    else
        c.gain:SetText("|cff808080--|r")
    end
    c.qtyAH:SetText(d.qtyAH and tostring(d.qtyAH) or "|cff808080--|r")
    c.t:SetText(Age(d.t))
end

function bagDef.tooltip(row, d)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    SetItemTip(d.item)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("|cffffcc33GoblinLedger|r - in your bags: %d"):format(d.n))
    local cut = ns.db.settings.ahCut or 0.05
    if d.vendorEach == 0 then
        GameTooltip:AddLine("Vendors won't buy this.", 0.7, 0.7, 0.7)
    end
    if d.ah then
        GameTooltip:AddDoubleLine("AH buyout (each)", Money(d.ah) .. (d.ahOld and " |cff909090(last seen)|r" or ""), 1, 0.82, 0, 1, 1, 1)
    end
    -- the same money for one item, one stack and everything you have
    local groups = { { "Each", 1 } }
    if d.stackMax > 1 then groups[#groups + 1] = { ("Stack of %d"):format(d.stackMax), d.stackMax } end
    if d.n > 1 and d.n ~= d.stackMax then groups[#groups + 1] = { ("All %d"):format(d.n), d.n } end
    if d.vendorEach ~= 0 and (d.vendorEach or d.ahNet) then
        GameTooltip:AddDoubleLine(" ", ("|cff80c0ffVendor|r   |cffffcc33AH net (-%d%%)|r"):format(cut * 100), 1, 1, 1, 1, 1, 1)
        for _, g in ipairs(groups) do
            local v, a, where = ns.Bags.Values(d.vendorEach, d.ahNet, g[2])
            local vt = v and Money(v, true) or "|cff808080--|r"
            local at = a and Money(a, true) or "|cff808080--|r"
            if where == "AH" then at = "|cff40ff40>|r " .. at elseif where == "Vendor" and a then vt = "|cff40ff40>|r " .. vt end
            GameTooltip:AddDoubleLine("  " .. g[1], vt .. "   " .. at, 1, 1, 1, 1, 1, 1)
        end
    end
    if d.ah then
        if d.bid and d.bid < d.ah then GameTooltip:AddDoubleLine("Lowest bid", Money(d.bid) .. " each", 1, 0.82, 0, 1, 1, 1) end
        if d.qtyAH and d.qtyAH > 0 then GameTooltip:AddDoubleLine("Listed on the AH", tostring(d.qtyAH), 1, 0.82, 0, 1, 1, 1) end
    elseif d.qtyAH == 0 then
        GameTooltip:AddLine("None on the AH right now - you set the price!", 0.25, 1, 0.25)
    else
        GameTooltip:AddLine("No AH price yet - scan your bag items or do a Full Scan.", 1, 0.5, 0.5)
    end
    if d.where == "AH" and d.gain and d.vendor and d.vendor > 0 then
        local per = (d.count == 1 and "each") or (d.count == d.n and "for all") or ("per stack of " .. d.count)
        GameTooltip:AddLine(("Selling on the AH pays %s more than a vendor (%s)."):format(Money(d.gain), per), 0.25, 1, 0.25)
    elseif d.where == "Vendor" and d.ah then
        GameTooltip:AddLine("A vendor pays more than the AH - just vendor it.", 0.5, 0.75, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: rescan this item (AH open)   Shift-click: link", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

function bagDef.click(row, d)
    ns.Scanner.StartTargeted(false, { d.item })
end

function bagDef.footer(p)
    local vendor, best, ahN, ahV = 0, 0, 0, 0
    for _, d in ipairs(p.data) do -- always totals for everything you have
        vendor = vendor + (d.totVendor or 0)
        best = best + (d.totBest or 0)
        if d.totWhere == "AH" then ahN, ahV = ahN + 1, ahV + d.totBest end
    end
    return ("%d items  |  vendor all: %s  |  best of both: %s  (%d to the AH for %s)"):format(
        #p.data, Money(vendor, true), Money(best, true), ahN, Money(ahV, true))
end

---------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------
local function SelectTab(name)
    ns.db.settings.tab = name
    for k, p in pairs(panels) do p:SetShown(k == name) end
    for k, t in pairs(tabs) do
        if k == name then t:LockHighlight(); t:Disable() else t:UnlockHighlight(); t:Enable() end
    end
    UI.Refresh()
end

local dots = 0
local function UpdateScanState()
    if not f or not f:IsShown() then return end
    local S = ns.Scanner
    local busy, open = S.IsBusy(), S.open
    if busy then
        dots = (dots % 3) + 1
        scanBtn:SetText("Scanning" .. ("."):rep(dots))
        scanBtn:Disable()
        fullBtn:Disable()
        stopBtn:Enable()
        local pr = S.Progress()
        progress:Show()
        if pr then
            progress:SetValue(pr)
            progress:SetAlpha(1)
        else -- full scan: unknown length, pulse
            progress:SetValue(1)
            progress:SetAlpha(0.45 + 0.35 * math.sin(GetTime() * 4))
        end
    else
        scanBtn:SetText("Scan")
        scanBtn:SetEnabled(open)
        local cd = S.FullScanCooldown()
        fullBtn:SetText(cd > 0 and ("Full %d:%02d"):format(cd / 60, cd % 60) or "Full Scan")
        fullBtn:SetEnabled(open and cd == 0)
        stopBtn:Disable()
        progress:Hide()
    end
end

local function Build()
    f = CreateFrame("Frame", "GoblinLedgerFrame", UIParent, "BasicFrameTemplateWithInset")
    -- wide enough for the widest tab
    local widest = 0
    for _, def in ipairs({ craftDef, deDef, flipDef, recDef, bagDef }) do
        local w = 0
        for _, c in ipairs(def.cols) do w = w + c.w + 4 end
        if w > widest then widest = w end
    end
    local width = 80 + widest
    f:SetSize(width, PANEL_TOP + ROWS_Y + NUM_ROWS * ROW_H + 34)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()
    tinsert(UISpecialFrames, "GoblinLedgerFrame")

    local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not f.TitleText then title:SetPoint("TOP", 0, -5) end
    title:SetText("|cffffcc33GoblinLedger|r")

    -- tabs
    tabs.craft = MakeButton(f, "Crafting", 100)
    tabs.craft:SetPoint("TOPLEFT", 14, -28)
    tabs.craft:SetScript("OnClick", function() SelectTab("craft") end)
    tabs.de = MakeButton(f, "Disenchant", 100)
    tabs.de:SetPoint("LEFT", tabs.craft, "RIGHT", 4, 0)
    tabs.de:SetScript("OnClick", function() SelectTab("de") end)
    tabs.flip = MakeButton(f, "Vendor Flips", 100)
    tabs.flip:SetPoint("LEFT", tabs.de, "RIGHT", 4, 0)
    tabs.flip:SetScript("OnClick", function() SelectTab("flip") end)
    tabs.rec = MakeButton(f, "Vendor Recipes", 110)
    tabs.rec:SetPoint("LEFT", tabs.flip, "RIGHT", 4, 0)
    tabs.rec:SetScript("OnClick", function() SelectTab("rec") end)
    tabs.bags = MakeButton(f, "Bags", 80)
    tabs.bags:SetPoint("LEFT", tabs.rec, "RIGHT", 4, 0)
    tabs.bags:SetScript("OnClick", function() SelectTab("bags") end)

    -- scan controls (shared)
    stopBtn = MakeButton(f, "Stop", 50)
    stopBtn:SetPoint("TOPRIGHT", -14, -28)
    stopBtn:SetScript("OnClick", function() ns.Scanner.Stop() end)
    fullBtn = MakeButton(f, "Full Scan", 90)
    fullBtn:SetPoint("RIGHT", stopBtn, "LEFT", -4, 0)
    fullBtn:SetScript("OnClick", function() ns.Scanner.FullScan() end)
    fullBtn:SetMotionScriptsWhileDisabled(true)
    Tip(fullBtn, function()
        if not ns.Scanner.open then return "Open the Auction House first." end
        return "Download every auction at once - needed for the Disenchant tab. The server allows this once per 15 minutes."
    end)
    scanBtn = MakeButton(f, "Scan", 100)
    scanBtn:SetPoint("RIGHT", fullBtn, "LEFT", -4, 0)
    scanBtn:SetScript("OnClick", function() ns.Scanner.StartTargeted(false) end)
    scanBtn:SetMotionScriptsWhileDisabled(true)
    Tip(scanBtn, function()
        if not ns.Scanner.open then return "Open the Auction House first." end
        return "Search the AH for every crafted item, material and enchanting mat."
    end)

    panels.craft = BuildPanel(craftDef)
    panels.de = BuildPanel(deDef)
    panels.flip = BuildPanel(flipDef)
    panels.rec = BuildPanel(recDef)
    panels.bags = BuildPanel(bagDef)

    -- bottom: progress bar + status
    progress = CreateFrame("StatusBar", nil, f)
    progress:SetSize(120, 10)
    progress:SetPoint("BOTTOMLEFT", 16, 12)
    progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    progress:SetStatusBarColor(0.2, 0.8, 0.3)
    progress:SetMinMaxValues(0, 1)
    local pbg = progress:CreateTexture(nil, "BACKGROUND")
    pbg:SetAllPoints()
    pbg:SetColorTexture(0, 0, 0, 0.5)
    progress:Hide()

    statusText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("LEFT", progress, "RIGHT", 8, 0)
    statusText:SetText(ns.Scanner.status or "Open the AH to scan. Hover a row for details.")

    f:SetScript("OnShow", function()
        for _, p in pairs(panels) do
            for _, cb in ipairs(p.checks or {}) do cb:SetChecked(ns.db.settings[cb.key]) end
        end
        SelectTab(panels[ns.db.settings.tab] and ns.db.settings.tab or "craft")
        UpdateScanState()
    end)

    C_Timer.NewTicker(0.35, UpdateScanState)
    C_Timer.NewTicker(30, function()
        if f:IsShown() then for _, p in pairs(panels) do if p:IsShown() then p.Update() end end end
    end)
end

function UI.Refresh()
    if not f or not f:IsShown() then return end
    for _, p in pairs(panels) do
        if p:IsShown() then p.Refresh() end
    end
end

function UI.SetStatus(text)
    if statusText then statusText:SetText(text or "") end
end

function UI.Toggle()
    if not f then Build() end
    f:SetShown(not f:IsShown())
end

function UI.Show()
    if not f then Build() end
    f:Show()
end

function UI.ShowTab(name)
    if not f then Build() end
    if f:IsShown() then SelectTab(name)
    else ns.db.settings.tab = name; f:Show() end -- OnShow selects the saved tab
end

-- button on the Auction House window (shows scan activity too)
local ahBtn
function UI.OnAHShow()
    local ah = AuctionHouseFrame or AuctionFrame
    if not ah then return end
    if not ahBtn then
        ahBtn = CreateFrame("Button", nil, ah, "UIPanelButtonTemplate")
        ahBtn:SetSize(120, 22)
        ahBtn:SetText("GoblinLedger")
        ahBtn:SetPoint("TOPRIGHT", ah, "TOPRIGHT", -30, -1)
        ahBtn:SetFrameStrata("HIGH")
        ahBtn:SetScript("OnClick", function()
            if not f then Build() end
            if not f:IsShown() then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", ah, "TOPRIGHT", 4, 0)
            end
            UI.Toggle()
        end)
        local n = 0
        C_Timer.NewTicker(0.35, function()
            if not ahBtn:IsVisible() then return end
            if ns.Scanner.IsBusy() then
                n = (n % 3) + 1
                ahBtn:SetText("|cff40ff40Scanning" .. ("."):rep(n) .. "|r")
            else
                ahBtn:SetText("GoblinLedger")
            end
        end)
    end
    ahBtn:Show()
end
