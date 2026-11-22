-- GoblinLedger: share recorded vendors with other GoblinLedger users in your guild and group.
--
-- Protocol v1 (addon messages, prefix "GoblinLedger", each message <= 255 bytes):
--   1~I~npc:t,npc:t,...           index: vendors I have and when they were recorded
--   1~Q~npc,npc,...               request (whisper): send me these
--   1~D~npc~seq~total~chunk       data (whisper): one vendor record, split in chunks
-- A record is only taken when it is newer than what we have. Records hold NPC data only
-- (no character names); who sent it is never stored.
local ADDON, ns = ...

local C = {}
ns.Comm = C

local PREFIX, VERSION = "GoblinLedger", "1"
local MAX_MSG = 245
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
elseif RegisterAddonMessagePrefix then
    RegisterAddonMessagePrefix(PREFIX)
end

local function Enabled() return ns.db and ns.db.settings.share end

---------------------------------------------------------------------------
-- throttled send queue
---------------------------------------------------------------------------
local queue, ticker = {}, nil
local function Pump()
    local m = table.remove(queue, 1)
    if not m then
        if ticker then ticker:Cancel(); ticker = nil end
        return
    end
    pcall(SendAddon, PREFIX, m[1], m[2], m[3])
end

local function Send(msg, chan, target)
    if #queue >= 400 then return end
    queue[#queue + 1] = { msg, chan, target }
    if not ticker then ticker = C_Timer.NewTicker(0.3, Pump) end
end

local function Broadcast(msg)
    if IsInGuild and IsInGuild() then Send(msg, "GUILD") end
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        Send(msg, "INSTANCE_CHAT")
    elseif IsInRaid and IsInRaid() then
        Send(msg, "RAID")
    elseif IsInGroup and IsInGroup() then
        Send(msg, "PARTY")
    end
end

-- send "head .. item1,item2,..." in as few messages as fit
local function SendList(head, items, sendFn)
    local buf = {}
    local len = #head
    for _, it in ipairs(items) do
        if len + #it + 1 > MAX_MSG and #buf > 0 then
            sendFn(head .. table.concat(buf, ","))
            buf, len = {}, #head
        end
        buf[#buf + 1] = it
        len = len + #it + 1
    end
    if #buf > 0 then sendFn(head .. table.concat(buf, ",")) end
end

---------------------------------------------------------------------------
-- (de)serialising a vendor record
--   name^zone^map^x^y^sub^side^t^items      items: id:price:lim:prof:rep:name;...
---------------------------------------------------------------------------
local PROF_INDEX, PROF_NAME = {}, {}
for i, name in pairs(ns.Recorder.PROF_BY_SUBCLASS) do PROF_INDEX[name] = i; PROF_NAME[i] = name end

local Clean = ns.Recorder.Clean

local function Serialize(rec)
    local items = {}
    for id, it in pairs(rec.items) do
        items[#items + 1] = table.concat({ id, it.price, it.limited and 1 or 0, PROF_INDEX[it.prof] or 0,
            Clean(it.rep), Clean(it.name) }, ":")
    end
    return table.concat({ Clean(rec.name), Clean(rec.zone), rec.map or "", rec.x or "", rec.y or "",
        Clean(rec.sub), rec.side or "both", rec.t or 0, table.concat(items, ";") }, "^")
end

local function num(s) return tonumber(s) end
local function str(s, max) if s and s ~= "" and #s <= (max or 60) then return s end end

local function Deserialize(data)
    local f = { strsplit("^", data) }
    if #f ~= 9 then return nil end
    local rec = {
        name = str(f[1]), zone = str(f[2]), map = num(f[3]), x = num(f[4]), y = num(f[5]),
        sub = str(f[6]), side = f[7], t = num(f[8]), items = {},
    }
    if not rec.name or not rec.t then return nil end
    if rec.t <= 0 or rec.t > time() + 2 * 86400 then return nil end
    if rec.side ~= "alliance" and rec.side ~= "horde" and rec.side ~= "both" then return nil end
    if rec.x and (rec.x <= 0 or rec.x >= 100) then rec.x = nil end
    if rec.y and (rec.y <= 0 or rec.y >= 100) then rec.y = nil end
    if not (rec.map and rec.x and rec.y) then rec.map, rec.x, rec.y = nil, nil, nil end
    local n = 0
    for entry in (f[9] or ""):gmatch("[^;]+") do
        local id, price, lim, prof, rep, name = strsplit(":", entry)
        id, price = num(id), num(price)
        if id and id > 0 and id < 10000000 and price and price > 0 and price <= 100000000 then
            rec.items[id] = { price = price, limited = lim == "1", prof = PROF_NAME[num(prof) or 0],
                              rep = str(rep, 80), name = str(name, 80) }
            n = n + 1
            if n >= 150 then break end
        end
    end
    if n == 0 then return nil end
    return rec
end

---------------------------------------------------------------------------
-- announcing what we have
---------------------------------------------------------------------------
local function IndexEntries(only)
    local list = {}
    if only then
        local rec = ns.Recorder.Get(only)
        if rec then list[1] = only .. ":" .. rec.t end
        return list
    end
    for id, l in pairs(ns.Recorder.All()) do list[#list + 1] = id .. ":" .. (l.rec.t or 0) end
    return list
end

local lastFull = 0
function C.AnnounceAll(force)
    if not Enabled() then return end
    if not force and GetTime() - lastFull < 300 then return end
    lastFull = GetTime()
    local list = IndexEntries()
    if #list == 0 then return end
    SendList(VERSION .. "~I~", list, Broadcast)
end

-- after recording a vendor: tell others it's there
function C.Announce(npcID)
    if not Enabled() then return end
    local list = IndexEntries(npcID)
    if #list > 0 then Broadcast(VERSION .. "~I~" .. list[1]) end
end

---------------------------------------------------------------------------
-- receiving
---------------------------------------------------------------------------
local requested = {}   -- [npcID] = GetTime() we last asked for it
local servedTo = {}    -- [sender] = { t = window start, n = vendors sent }
local greeted = {}     -- [sender] = true once we sent them our index
local parts = {}       -- [sender .. npc] = { total, got, chunks = {} }
local received, noteTimer = 0, nil

local function Me(sender)
    local name = Ambiguate and Ambiguate(sender, "none") or sender
    return name == UnitName("player")
end

local function OnIndex(sender, body)
    local want = {}
    for entry in body:gmatch("[^,]+") do
        local id, t = entry:match("^(%d+):(%d+)$")
        id, t = tonumber(id), tonumber(t)
        if id and t then
            local mine = ns.Recorder.Get(id)
            if (not mine or (mine.t or 0) < t) and GetTime() - (requested[id] or -999) > 120 then
                requested[id] = GetTime()
                want[#want + 1] = tostring(id)
                if #want >= 60 then break end
            end
        end
    end
    if #want > 0 then
        SendList(VERSION .. "~Q~", want, function(msg) Send(msg, "WHISPER", sender) end)
    end
    -- someone new: let them know what we have too (once per session)
    if not greeted[sender] then
        greeted[sender] = true
        local mine = IndexEntries()
        if #mine > 0 then
            SendList(VERSION .. "~I~", mine, function(msg) Send(msg, "WHISPER", sender) end)
        end
    end
end

local function OnRequest(sender, body)
    local s = servedTo[sender]
    if not s or GetTime() - s.t > 300 then s = { t = GetTime(), n = 0 }; servedTo[sender] = s end
    for idText in body:gmatch("[^,]+") do
        local id = tonumber(idText)
        local rec = id and ns.Recorder.Get(id)
        if rec and s.n < 80 then
            s.n = s.n + 1
            local data = Serialize(rec)
            local head = ("%s~D~%d~"):format(VERSION, id)
            local room = MAX_MSG - #head - 8
            local total = math.max(1, math.ceil(#data / room))
            for seq = 1, total do
                local chunk = data:sub((seq - 1) * room + 1, seq * room)
                Send(("%s%d~%d~%s"):format(head, seq, total, chunk), "WHISPER", sender)
            end
        end
    end
end

local function OnData(sender, body)
    local id, seq, total, chunk = body:match("^(%d+)~(%d+)~(%d+)~(.*)$")
    id, seq, total = tonumber(id), tonumber(seq), tonumber(total)
    if not (id and seq and total) or total > 40 or seq < 1 or seq > total then return end
    local key = sender .. ":" .. id
    local p = parts[key]
    if not p or p.total ~= total then p = { total = total, got = 0, chunks = {}, t = GetTime() }; parts[key] = p end
    if not p.chunks[seq] then p.chunks[seq] = chunk; p.got = p.got + 1 end
    if p.got < total then return end
    parts[key] = nil
    local rec = Deserialize(table.concat(p.chunks))
    if not rec then return end
    local mine = ns.Recorder.Get(id)
    if mine and (mine.t or 0) >= rec.t then return end
    ns.db.shared[id] = rec
    ns.Flips.InvalidateRecipes()
    received = received + 1
    if not noteTimer then
        noteTimer = C_Timer.NewTimer(5, function()
            noteTimer = nil
            if ns.db.settings.recordChat and received > 0 then
                ns.Print(("Got %d vendor%s from other GoblinLedger users."):format(received, received == 1 and "" or "s"))
            end
            received = 0
        end)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("GROUP_JOINED")
ev:SetScript("OnEvent", function(_, event, prefix, msg, channel, sender)
    if event == "PLAYER_ENTERING_WORLD" then
        if not C.loggedIn then
            C.loggedIn = true
            C_Timer.After(30, function() C.AnnounceAll(true) end)
        end
        return
    elseif event == "GROUP_JOINED" then
        C_Timer.After(10, function() C.AnnounceAll() end)
        return
    end
    if prefix ~= PREFIX or not Enabled() or not sender or Me(sender) then return end
    local ver, kind, body = msg:match("^(%d+)~(%a)~(.*)$")
    if ver ~= VERSION then return end
    if kind == "I" then OnIndex(sender, body)
    elseif kind == "Q" then OnRequest(sender, body)
    elseif kind == "D" then OnData(sender, body) end
end)

-- forget half-received records now and then
C_Timer.NewTicker(60, function()
    local now = GetTime()
    for k, p in pairs(parts) do if now - p.t > 120 then parts[k] = nil end end
end)
