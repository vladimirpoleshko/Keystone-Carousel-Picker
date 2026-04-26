-- KeystoneCarouselPicker / Core.lua
-- Handles keystone tracking, party sync over addon channel, and spin coordination.

local ADDON_NAME, ns = ...
local KSR = {}
ns.KSR = KSR
_G.KeystoneCarouselPicker = KSR

local ADDON_PREFIX    = "KSRoulette"   -- must be <= 16 chars
local TARGET_SECTIONS = 35             -- 5 keys x 7

-- --------------------------------------------------------------------
-- State
-- --------------------------------------------------------------------
KSR.partyKeys = {}                     -- [shortName] = { mapID, level }
KSR.myKey     = { mapID = 0, level = 0 }
KSR.inCombat  = false

local function Debug(...)
    print("|cff33ff99[KSR]|r", ...)
end

local function ShortName(name)
    if not name then return nil end
    return Ambiguate(name, "short")
end

-- --------------------------------------------------------------------
-- Party roster helpers
-- --------------------------------------------------------------------
-- Returns a set { shortName = true } for every player currently in the group.
local function GetCurrentRosterSet()
    local roster = {}
    local me = UnitName("player")
    if me then roster[me] = true end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = UnitName("raid" .. i)
            if name then roster[name] = true end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            local name = UnitName("party" .. i)
            if name then roster[name] = true end
        end
    end
    return roster
end

-- Remove stored keys for players who left the group.
function KSR:PruneStaleKeys()
    local roster = GetCurrentRosterSet()
    for name in pairs(self.partyKeys) do
        if not roster[name] then
            self.partyKeys[name] = nil
        end
    end
end

-- --------------------------------------------------------------------
-- Combat check
-- --------------------------------------------------------------------
function KSR:IsBlocked()
    if self.inCombat then
        Debug("Not available during combat.")
        return true
    end
    return false
end

-- --------------------------------------------------------------------
-- Own keystone
-- --------------------------------------------------------------------
function KSR:UpdateOwnKey()
    local mapID = (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID
                   and C_MythicPlus.GetOwnedKeystoneChallengeMapID()) or 0
    local level = (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel
                   and C_MythicPlus.GetOwnedKeystoneLevel()) or 0

    local changed = (self.myKey.mapID ~= mapID) or (self.myKey.level ~= level)
    self.myKey.mapID = mapID
    self.myKey.level = level

    local me = UnitName("player")
    self.partyKeys[me] = { mapID = mapID, level = level }

    if changed and IsInGroup() then
        self:BroadcastKey()
    end

    if KSR.UI and KSR.UI.OnKeysUpdated then
        KSR.UI:OnKeysUpdated()
    end
end

function KSR:BroadcastKey()
    if not IsInGroup() then return end
    local msg = string.format("KEY:%d:%d", self.myKey.mapID or 0, self.myKey.level or 0)
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg, "PARTY")
end

function KSR:RequestKeys()
    if not IsInGroup() then return end
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "REQ", "PARTY")
end

-- --------------------------------------------------------------------
-- Party key collection
-- --------------------------------------------------------------------
function KSR:GetPartyKeys()
    -- Prune first so we never return stale entries.
    self:PruneStaleKeys()

    local result = {}
    for name, info in pairs(self.partyKeys) do
        if info.mapID and info.mapID > 0 and info.level and info.level > 0 then
            table.insert(result, { name = name, mapID = info.mapID, level = info.level })
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

-- --------------------------------------------------------------------
-- Message handling
-- --------------------------------------------------------------------
function KSR:HandleMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then return end

    local shortSender = ShortName(sender)

    if message == "REQ" then
        self:BroadcastKey()
        return
    end

    local cmd = strsplit(":", message)

    if cmd == "KEY" then
        local _, a, b = strsplit(":", message)
        local mapID = tonumber(a) or 0
        local level = tonumber(b) or 0
        self.partyKeys[shortSender] = { mapID = mapID, level = level }
        if KSR.UI and KSR.UI.OnKeysUpdated then
            KSR.UI:OnKeysUpdated()
        end

    elseif cmd == "SPIN" then
        -- Silently ignore spins during combat
        if self.inCombat then return end

        local _, winIdxStr, durStr, keysStr, orderStr = strsplit(":", message)
        local winIdx   = tonumber(winIdxStr)
        local duration = tonumber(durStr)
        if not (winIdx and duration and keysStr and orderStr) then return end

        local keys = {}
        for entry in string.gmatch(keysStr, "[^|]+") do
            local n, m, l = strsplit(",", entry)
            table.insert(keys, {
                name  = n,
                mapID = tonumber(m),
                level = tonumber(l),
            })
        end

        local pool = {}
        for i = 1, #orderStr do
            local idx = tonumber(orderStr:sub(i, i))
            if idx and keys[idx] then
                table.insert(pool, keys[idx])
            end
        end

        if #pool == 0 or not pool[winIdx] then return end

        local isInitiator = (shortSender == UnitName("player"))
        if KSR.UI and KSR.UI.StartSpin then
            KSR.UI:StartSpin(pool, winIdx, duration, isInitiator)
        end
    end
end

-- --------------------------------------------------------------------
-- Spin initiation
-- --------------------------------------------------------------------
function KSR:InitiateSpin()
    if self:IsBlocked() then return end

    if KSR.UI and KSR.UI.isSpinning then
        Debug("Already spinning.")
        return
    end

    local keys = self:GetPartyKeys()
    if #keys == 0 then
        Debug("No keystones found yet. Try again in a moment.")
        return
    end
    if #keys > 9 then
        while #keys > 9 do table.remove(keys) end
    end

    local copies    = math.floor(TARGET_SECTIONS / #keys)
    local remainder = TARGET_SECTIONS - (copies * #keys)

    local order = {}
    for i = 1, #keys do
        for _ = 1, copies do table.insert(order, i) end
    end
    for i = 1, remainder do table.insert(order, i) end

    -- Shuffle (Fisher-Yates)
    for i = #order, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end

    local winIdx   = math.random(#order)
    local duration = 6.5

    local keyParts = {}
    for _, k in ipairs(keys) do
        table.insert(keyParts, string.format("%s,%d,%d", k.name, k.mapID, k.level))
    end
    local msg = string.format("SPIN:%d:%.2f:%s:%s",
        winIdx, duration, table.concat(keyParts, "|"), table.concat(order, ""))

    if IsInGroup() then
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg, "PARTY")
    else
        local pool = {}
        for _, idx in ipairs(order) do table.insert(pool, keys[idx]) end
        if KSR.UI and KSR.UI.StartSpin then
            KSR.UI:StartSpin(pool, winIdx, duration, true)
        end
    end
end

-- --------------------------------------------------------------------
-- Events
-- --------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
frame:RegisterEvent("ITEM_CHANGED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
            if C_MythicPlus and C_MythicPlus.RequestMapInfo then
                C_MythicPlus.RequestMapInfo()
            end
            -- Defaults for saved variables
            if not KSR_DB then KSR_DB = {} end
            if KSR_DB.minimapAngle == nil then KSR_DB.minimapAngle = 225 end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if C_MythicPlus and C_MythicPlus.RequestMapInfo then
            C_MythicPlus.RequestMapInfo()
        end
        C_Timer.After(2, function()
            KSR:UpdateOwnKey()
            if IsInGroup() then
                KSR:BroadcastKey()
                KSR:RequestKeys()
            end
        end)

    elseif event == "GROUP_ROSTER_UPDATE" then
        KSR:PruneStaleKeys()

        if IsInGroup() then
            C_Timer.After(1, function()
                KSR:PruneStaleKeys()
                KSR:BroadcastKey()
                KSR:RequestKeys()
            end)
        else
            -- Left group: keep only own key.
            local me = UnitName("player")
            local myKey = KSR.partyKeys[me]
            KSR.partyKeys = {}
            if myKey then KSR.partyKeys[me] = myKey end
        end
        if KSR.UI and KSR.UI.OnKeysUpdated then
            KSR.UI:OnKeysUpdated()
        end

    elseif event == "BAG_UPDATE_DELAYED"
        or event == "CHALLENGE_MODE_MAPS_UPDATE"
        or event == "ITEM_CHANGED" then
        KSR:UpdateOwnKey()

    elseif event == "CHAT_MSG_ADDON" then
        KSR:HandleMessage(...)

    elseif event == "PLAYER_REGEN_DISABLED" then
        KSR.inCombat = true
        if KSR.UI and KSR.UI.OnCombatEnter then
            KSR.UI:OnCombatEnter()
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        KSR.inCombat = false
        if KSR.UI and KSR.UI.OnCombatLeave then
            KSR.UI:OnCombatLeave()
        end
    end
end)

-- --------------------------------------------------------------------
-- Slash command
-- --------------------------------------------------------------------
SLASH_KSROULETTE1 = "/ksr"
SLASH_KSROULETTE2 = "/KeystoneCarouselPicker"
SlashCmdList["KSROULETTE"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "spin" then
        KSR:InitiateSpin()
    elseif msg == "refresh" then
        if KSR:IsBlocked() then return end
        KSR:UpdateOwnKey()
        KSR:BroadcastKey()
        KSR:RequestKeys()
        Debug("Refreshed keystones.")
    elseif msg == "list" then
        for _, k in ipairs(KSR:GetPartyKeys()) do
            local dname = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo
                and (C_ChallengeMode.GetMapUIInfo(k.mapID)) or tostring(k.mapID)
            Debug(k.name, "-", dname, "+" .. k.level)
        end
    else
        if KSR.UI and KSR.UI.Toggle then KSR.UI:Toggle() end
    end
end
