-- CraftProfit: disenchanting - drop tables, expected value, and gear auctions seen on the AH
local ADDON, ns = ...

local DE = {}
ns.DE = DE

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local MAX_AGE = 48 * 3600 -- auctions can't live longer than this

---------------------------------------------------------------------------
-- Drop tables (classic-era values, approximate). Edit here if your server differs.
-- Each outcome: { itemID, minQty, maxQty }. Probabilities are per disenchant.
---------------------------------------------------------------------------
local STRANGE, SOUL, VISION, DREAM, ILLUSION = 10940, 11083, 11137, 11176, 16204
local LMAGIC, GMAGIC, LASTRAL, GASTRAL = 10938, 10939, 10998, 11082
local LMYSTIC, GMYSTIC, LNETHER, GNETHER, LETERNAL, GETERNAL = 11134, 11135, 11174, 11175, 16202, 16203
local SGLIM, LGLIM, SGLOW, LGLOW, SRAD, LRAD, SBRIL, LBRIL = 10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344
local NEXUS = 20725

-- Uncommon (green): armor gets dust most of the time; weapons swap dust and essence chances.
-- p = { dust, essence, shard }
local GREEN = {
    { max = 15, p = { .80, .20, 0 },   dust = { STRANGE, 1, 2 },  ess = { LMAGIC, 1, 2 } },
    { max = 20, p = { .75, .20, .05 }, dust = { STRANGE, 2, 3 },  ess = { GMAGIC, 1, 2 },   shard = { SGLIM, 1, 1 } },
    { max = 25, p = { .75, .15, .10 }, dust = { STRANGE, 4, 6 },  ess = { LASTRAL, 1, 2 },  shard = { SGLIM, 1, 1 } },
    { max = 30, p = { .75, .20, .05 }, dust = { SOUL, 1, 2 },     ess = { GASTRAL, 1, 2 },  shard = { LGLIM, 1, 1 } },
    { max = 35, p = { .75, .20, .05 }, dust = { SOUL, 2, 5 },     ess = { LMYSTIC, 1, 2 },  shard = { SGLOW, 1, 1 } },
    { max = 40, p = { .75, .20, .05 }, dust = { VISION, 1, 2 },   ess = { GMYSTIC, 1, 2 },  shard = { LGLOW, 1, 1 } },
    { max = 45, p = { .75, .20, .05 }, dust = { VISION, 2, 5 },   ess = { LNETHER, 1, 2 },  shard = { SRAD, 1, 1 } },
    { max = 50, p = { .75, .20, .05 }, dust = { DREAM, 1, 2 },    ess = { GNETHER, 1, 2 },  shard = { LRAD, 1, 1 } },
    { max = 55, p = { .75, .20, .05 }, dust = { DREAM, 2, 5 },    ess = { LETERNAL, 1, 2 }, shard = { SBRIL, 1, 1 } },
    { max = 60, p = { .75, .20, .05 }, dust = { ILLUSION, 1, 2 }, ess = { GETERNAL, 1, 2 }, shard = { LBRIL, 1, 1 } },
    { max = 65, p = { .75, .20, .05 }, dust = { ILLUSION, 2, 5 }, ess = { GETERNAL, 2, 3 }, shard = { LBRIL, 1, 1 } },
}

-- Rare (blue): { max ilvl, { {itemID, min, max, p}, ... } }
local BLUE = {
    { max = 25, out = { { SGLIM, 1, 1, 1 } } },
    { max = 30, out = { { LGLIM, 1, 1, 1 } } },
    { max = 35, out = { { SGLOW, 1, 1, 1 } } },
    { max = 40, out = { { LGLOW, 1, 1, 1 } } },
    { max = 45, out = { { SRAD, 1, 1, 1 } } },
    { max = 50, out = { { LRAD, 1, 1, 1 } } },
    { max = 55, out = { { SBRIL, 1, 1, 1 } } },
    { max = 65, out = { { LBRIL, 1, 1, .995 }, { NEXUS, 1, 1, .005 } } },
}

-- Epic (purple)
local EPIC = {
    { max = 45, out = { { SRAD, 2, 4, 1 } } },
    { max = 50, out = { { LRAD, 2, 4, 1 } } },
    { max = 55, out = { { SBRIL, 2, 4, 1 } } },
    { max = 60, out = { { NEXUS, 1, 1, 1 } } },
    { max = 99, out = { { NEXUS, 1, 2, 1 } } },
}

DE.MATS = {
    STRANGE, SOUL, VISION, DREAM, ILLUSION,
    LMAGIC, GMAGIC, LASTRAL, GASTRAL, LMYSTIC, GMYSTIC, LNETHER, GNETHER, LETERNAL, GETERNAL,
    SGLIM, LGLIM, SGLOW, LGLOW, SRAD, LRAD, SBRIL, LBRIL, NEXUS,
}

local function Pick(bands, ilvl)
    for _, b in ipairs(bands) do
        if ilvl <= b.max then return b, false end
    end
    return bands[#bands], true -- above the table: best guess
end

-- list of outcomes { id, a, b, p } for an item
function DE.Outcomes(ilvl, quality, isWeapon)
    if not ilvl or not quality then return nil end
    if quality == 2 then
        local b, beyond = Pick(GREEN, ilvl)
        local pd, pe, ps = b.p[1], b.p[2], b.p[3]
        if isWeapon then pd, pe = pe, pd end
        local out = {
            { id = b.dust[1], a = b.dust[2], b = b.dust[3], p = pd },
            { id = b.ess[1],  a = b.ess[2],  b = b.ess[3],  p = pe },
        }
        if b.shard and ps > 0 then out[3] = { id = b.shard[1], a = b.shard[2], b = b.shard[3], p = ps } end
        return out, beyond
    elseif quality == 3 or quality == 4 then
        local b, beyond = Pick(quality == 3 and BLUE or EPIC, ilvl)
        local out = {}
        for i, o in ipairs(b.out) do out[i] = { id = o[1], a = o[2], b = o[3], p = o[4] } end
        return out, beyond
    end
end

-- Expected sale value (after AH cut) of the mats from ONE disenchant, plus its variance.
-- Each outcome gets .price (net, per mat), .eq (expected count), .ev (contribution).
function DE.Value(ilvl, quality, isWeapon)
    local outs, beyond = DE.Outcomes(ilvl, quality, isWeapon)
    if not outs then return nil end
    local net = 1 - (ns.db.settings.ahCut or 0.05)
    local ev, ex2, missing = 0, 0, false
    for _, o in ipairs(outs) do
        local price, old = ns.AHPrice(o.id)
        if not price then missing = true end
        o.old = old
        o.price = (price or 0) * net
        local eq, eq2 = 0, 0
        for k = o.a, o.b do eq = eq + k; eq2 = eq2 + k * k end
        eq, eq2 = eq / (o.b - o.a + 1), eq2 / (o.b - o.a + 1)
        o.eq = eq
        o.ev = o.p * eq * o.price
        ev = ev + o.ev
        ex2 = ex2 + o.p * eq2 * o.price * o.price
    end
    return ev, math.max(0, ex2 - ev * ev), outs, missing, beyond
end

---------------------------------------------------------------------------
-- Which items can be disenchanted
---------------------------------------------------------------------------
local deCache = {}
function DE.IsDEable(id)
    local c = deCache[id]
    if c ~= nil then return c end
    local _, _, _, equipLoc, _, classID = GetItemInfoInstant(id)
    if not classID then return false end -- unknown, try later
    c = (classID == 2 or classID == 4)
        and equipLoc ~= nil and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP"
        and equipLoc ~= "INVTYPE_BODY" and equipLoc ~= "INVTYPE_TABARD"
        and equipLoc ~= "INVTYPE_AMMO" and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_QUIVER"
    deCache[id] = c
    return c
end

local function IsWeapon(id)
    return select(6, GetItemInfoInstant(id)) == 2
end

local function Quality(id)
    if C_Item and C_Item.GetItemQualityByID then
        local q = C_Item.GetItemQualityByID(id)
        if q then return q end
    end
    return (select(3, GetItemInfo(id)))
end

local function ItemLevel(id)
    local l = GetDetailedItemLevelInfo and GetDetailedItemLevelInfo(id)
    if l and l > 0 then return l end
    l = select(4, GetItemInfo(id))
    if l and l > 0 then return l end
end

---------------------------------------------------------------------------
-- Recording gear auctions
-- db.de[itemID] = { t, src = "full"|"search"|"browse", l = ilvl, q = quality, list = { {bid, buy, n, tl} } }
---------------------------------------------------------------------------
function DE.SetItemAuctions(itemID, list, src, ilvl, quality)
    if #list == 0 then
        ns.db.de[itemID] = nil
    else
        ns.db.de[itemID] = { t = time(), src = src, l = (ilvl and ilvl > 0) and ilvl or nil, q = quality, list = list }
    end
    ns.RequestRefresh()
end

function DE.FromBrowse(itemKey, minPrice)
    local id = itemKey.itemID
    local e = ns.db.de[id]
    -- a recent real search (with bids) beats a buyout-only browse line
    if e and e.src ~= "browse" and time() - e.t < 600 then return end
    DE.SetItemAuctions(id, { { buy = minPrice, n = 1 } }, "browse", itemKey.itemLevel)
end

local fullNew
function DE.BeginFull() fullNew = {} end
function DE.AddFull(itemID, quality, bid, buy, n)
    if not fullNew or (not bid and not buy) or not DE.IsDEable(itemID) then return end
    local e = fullNew[itemID]
    if not e then e = { t = time(), src = "full", q = quality, list = {} }; fullNew[itemID] = e end
    e.list[#e.list + 1] = { bid = bid, buy = buy, n = n }
end
function DE.EndFull()
    if not fullNew then return end
    ns.db.de = fullNew
    fullNew = nil
    ns.RequestRefresh()
end

---------------------------------------------------------------------------
-- Rows for the Disenchant tab: one per auction
---------------------------------------------------------------------------
function DE.Rows()
    local rows, now = {}, time()
    local valueCache = {}
    for id, e in pairs(ns.db.de) do
        if now - e.t > MAX_AGE then
            ns.db.de[id] = nil
        else
            local q = e.q or Quality(id)
            local l = e.l or ItemLevel(id)
            if not q or not l then
                if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
            end
            if not q or (q >= 2 and q <= 4) then
                local weapon = IsWeapon(id)
                local v = valueCache[id]
                if not v and q and l then
                    local ev, var, outs, missing, beyond = DE.Value(l, q, weapon)
                    v = { ev = ev, var = var, outs = outs, missing = missing, beyond = beyond }
                    valueCache[id] = v
                end
                for _, a in ipairs(e.list) do
                    local n = a.n or 1
                    local r = {
                        item = id, q = q, ilvl = l, weapon = weapon,
                        kind = weapon and "Weapon" or "Armor",
                        bid = a.bid, buyout = a.buy, n = n, tl = a.tl, t = e.t, src = e.src,
                        name = (GetItemInfo(id)) or ("item:" .. id),
                    }
                    if v and v.ev then
                        r.ev, r.var, r.outs, r.missing, r.beyond = v.ev * n, v.var * n, v.outs, v.missing, v.beyond
                        if a.bid then r.profitBid = math.floor(r.ev - a.bid) end
                        if a.buy then r.profitBuy = math.floor(r.ev - a.buy) end
                    end
                    rows[#rows + 1] = r
                end
            end
        end
    end
    return rows
end
