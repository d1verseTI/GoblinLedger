-- GoblinLedger: AH and vendor prices on item tooltips (/gl tooltip to turn off)
local ADDON, ns = ...

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local function ItemID(tooltip, data)
    local id = data and data.id
    if type(id) == "number" and not Secret(id) then return id end
    if not tooltip.GetItem then return nil end
    local _, link = tooltip:GetItem()
    if type(link) ~= "string" or Secret(link) then return nil end
    return tonumber(link:match("item:(%d+)"))
end

-- stack size when hovering a bag slot (default bags and ElvUI), else 1
local function StackCount(tooltip)
    local owner = tooltip.GetOwner and tooltip:GetOwner()
    if not owner then return 1 end
    local bag, slot
    if owner.GetBagID then
        local ok, b = pcall(owner.GetBagID, owner)
        if ok then bag, slot = b, owner:GetID() end
    end
    if bag == nil and owner.BagID and owner.SlotID then bag, slot = owner.BagID, owner.SlotID end -- ElvUI
    if bag ~= nil and slot and C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.stackCount and not Secret(info.stackCount) then return info.stackCount end
    end
    return 1
end

local function Each(price, n)
    local s = ns.Money(price)
    if n > 1 then s = s .. (" |cffaaaaaax%d = |r%s"):format(n, ns.Money(price * n)) end
    return s
end

local LABEL = { 1, 0.8, 0.2 } -- goblin gold

local function AddLines(tooltip, data)
    if ns.suppressTip or not ns.db or not ns.db.settings.tooltip then return end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    local id = ItemID(tooltip, data)
    if not id then return end
    local s = ns.SellInfo(id)
    local n = StackCount(tooltip)
    local r, g, b = LABEL[1], LABEL[2], LABEL[3]

    if s.ah then
        local right = Each(s.ah, n)
        if s.ahOld then right = right .. " |cff909090(none listed now)|r"
        elseif s.t then right = right .. " " .. ns.Age(s.t) end
        tooltip:AddDoubleLine("AH buyout", right, r, g, b, 1, 1, 1)
        if s.bid and s.bid < s.ah then tooltip:AddDoubleLine("AH bid", Each(s.bid, n), r, g, b, 1, 1, 1) end
    elseif s.qty == 0 then
        tooltip:AddDoubleLine("AH", "|cff40ff40none listed - name your price|r", r, g, b, 1, 1, 1)
    else
        tooltip:AddDoubleLine("AH", "|cff808080not scanned yet|r", r, g, b, 1, 1, 1)
    end

    if s.vendor == 0 then
        tooltip:AddDoubleLine("Vendor", "|cff808080won't buy it|r", r, g, b, 1, 1, 1)
    elseif s.vendor then
        tooltip:AddDoubleLine("Vendor", Each(s.vendor, n), r, g, b, 1, 1, 1)
        if s.ahNet and s.ahNet > s.vendor * 1.1 then
            tooltip:AddLine(("AH pays %s more after the cut"):format(ns.Money((s.ahNet - s.vendor) * n)), 0.25, 1, 0.25)
        end
    end
    tooltip:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        pcall(AddLines, tooltip, data)
    end)
else
    for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
        if tip and tip.HookScript then
            tip:HookScript("OnTooltipSetItem", function(tooltip) pcall(AddLines, tooltip) end)
        end
    end
end
