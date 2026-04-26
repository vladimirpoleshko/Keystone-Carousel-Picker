-- KeystoneRoulette / UI.lua
-- Horizontal "CS:GO case"-style scrolling roulette strip.
-- Minimap button, combat lockdown.

local ADDON_NAME, ns = ...
local KSR = ns.KSR
local UI  = {}
KSR.UI = UI

local TILE_W, TILE_H = 120, 150
local VISIBLE_TILES  = 5
local VIEWPORT_W     = TILE_W * VISIBLE_TILES    -- 600
local VIEWPORT_H     = TILE_H
local REPEATS        = 6
local FRAME_W        = VIEWPORT_W + 40
local FRAME_H        = VIEWPORT_H + 130

-- Sound kit IDs
local SOUND_TICK   = 856      -- igMainMenuOptionCheckBoxOn (short click)
local SOUND_LAND   = 8959     -- RaidWarning ding
local SOUND_REVEAL = 1210     -- Legendary flourish

-- Minimap button config
local MINIMAP_RADIUS  = 100    -- distance from minimap center
local MINIMAP_SIZE    = 32

local frame

local function GetDungeonInfo(mapID)
    if not mapID or mapID == 0 then return nil, nil end
    if not (C_ChallengeMode and C_ChallengeMode.GetMapUIInfo) then return nil, nil end
    local name, _, _, texture, bgTexture = C_ChallengeMode.GetMapUIInfo(mapID)
    return (texture or bgTexture), name
end

-- ====================================================================
-- MINIMAP BUTTON (orbits Minimap, drag to reposition, angle is saved)
-- ====================================================================
local minimapBtn

local function UpdateMinimapPosition(angle)
    if not minimapBtn then return end
    local rad = math.rad(angle)
    local x = math.cos(rad) * MINIMAP_RADIUS
    local y = math.sin(rad) * MINIMAP_RADIUS
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if minimapBtn then return end

    minimapBtn = CreateFrame("Button", "KeystoneRouletteMinimapBtn", Minimap)
    minimapBtn:SetSize(MINIMAP_SIZE, MINIMAP_SIZE)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetFrameLevel(8)
    minimapBtn:SetMovable(true)
    minimapBtn:SetClampedToScreen(true)

    -- Circle border overlay (standard minimap button look)
    local overlay = minimapBtn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(54, 54)
    overlay:SetPoint("TOPLEFT")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Icon
    local icon = minimapBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(15, 15)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\INV_Relics_Hourglass")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    minimapBtn.icon = icon

    -- Background circle
    local bg = minimapBtn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(18, 18)
    bg:SetPoint("CENTER")
    bg:SetColorTexture(0, 0, 0, 0.6)

    -- Highlight
    local hl = minimapBtn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetSize(15, 15)
    hl:SetPoint("CENTER")
    hl:SetColorTexture(1, 1, 1, 0.15)

    -- Left click = open/close, left drag = reposition
    -- Uses the exact same StartMoving/StopMovingOrSizing pattern as the
    -- reference addon. WoW automatically distinguishes click vs drag:
    -- if you drag, OnDragStart fires and OnClick does NOT.
    -- If you just click, OnClick fires and OnDragStart does NOT.
    minimapBtn:SetMovable(true)
    minimapBtn:EnableMouse(true)
    minimapBtn:RegisterForClicks("LeftButtonUp")
    minimapBtn:RegisterForDrag("LeftButton")

    minimapBtn:SetScript("OnClick", function() UI:Toggle() end)

    minimapBtn:SetScript("OnDragStart", function(self)
        print("|cff33ff99[KSR]|r DragStart - calling StartMoving")
        self:StartMoving()
    end)
    minimapBtn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local mx, my = Minimap:GetCenter()
        local bx, by = self:GetCenter()
        local angle = math.deg(math.atan2(by - my, bx - mx))
        print("|cff33ff99[KSR]|r DragStop - snapping to angle:", string.format("%.1f", angle))
        KSR_DB.minimapAngle = angle
        UpdateMinimapPosition(angle)
    end)

    -- Tooltip
    minimapBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Keystone Roulette")
        GameTooltip:AddLine("Click to open / close", 1, 1, 1)
        GameTooltip:AddLine("Drag to reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdateMinimapPosition(KSR_DB and KSR_DB.minimapAngle or 225)
end

-- --------------------------------------------------------------------
-- Tile factory
-- --------------------------------------------------------------------
local function CreateTile(parent)
    local t = CreateFrame("Frame", nil, parent)
    t:SetSize(TILE_W, TILE_H)

    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    t.bg:SetColorTexture(0.08, 0.08, 0.1, 1)

    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetPoint("TOPLEFT", 3, -3)
    t.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    t.icon:SetTexCoord(0.15, 0.85, 0.05, 0.95)

    t.shade = t:CreateTexture(nil, "OVERLAY", nil, 1)
    t.shade:SetPoint("TOPLEFT",     t.icon, "TOPLEFT",     0, 0)
    t.shade:SetPoint("BOTTOMRIGHT", t.icon, "BOTTOMRIGHT", 0, 0)
    t.shade:SetColorTexture(0, 0, 0, 0.35)

    t.level = t:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    t.level:SetPoint("TOP", t, "TOP", 0, -10)
    t.level:SetTextColor(1, 0.82, 0)

    t.player = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t.player:SetPoint("BOTTOM", t, "BOTTOM", 0, 8)
    t.player:SetTextColor(1, 1, 1)
    t.player:SetWidth(TILE_W - 8)
    t.player:SetWordWrap(false)
    t.player:SetJustifyH("CENTER")

    t.edge = CreateFrame("Frame", nil, t, "BackdropTemplate")
    t.edge:SetAllPoints()
    if t.edge.SetBackdrop then
        t.edge:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        t.edge:SetBackdropBorderColor(0, 0, 0, 0.8)
    end

    function t:SetData(data)
        if not data then
            self.icon:SetTexture(nil)
            self.icon:SetColorTexture(0.1, 0.1, 0.1)
            self.level:SetText("")
            self.player:SetText("")
            return
        end
        local tex = GetDungeonInfo(data.mapID)
        if tex then
            self.icon:SetTexture(tex)
        else
            self.icon:SetColorTexture(0.2, 0.2, 0.35)
        end
        self.level:SetText(tostring(data.level or ""))
        self.player:SetText(data.name or "")
    end

    return t
end

-- --------------------------------------------------------------------
-- Frame creation
-- --------------------------------------------------------------------
function UI:Create()
    if frame then return frame end

    frame = CreateFrame("Frame", "KeystoneRouletteFrame", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop",  frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, 16)
    title:SetText("Keystone Roulette")

    -- Close
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    -- Viewport
    local viewport = CreateFrame("Frame", nil, frame)
    viewport:SetSize(VIEWPORT_W, VIEWPORT_H)
    viewport:SetPoint("TOP", 0, -42)
    if viewport.SetClipsChildren then viewport:SetClipsChildren(true) end
    self.viewport = viewport

    local vpBg = viewport:CreateTexture(nil, "BACKGROUND")
    vpBg:SetAllPoints()
    vpBg:SetColorTexture(0, 0, 0, 0.8)

    -- Strip
    local strip = CreateFrame("Frame", nil, viewport)
    strip:SetSize(TILE_W, VIEWPORT_H)
    strip:SetPoint("LEFT", viewport, "LEFT", 0, 0)
    self.strip = strip

    -- Center guideline
    local guide = viewport:CreateTexture(nil, "OVERLAY")
    guide:SetColorTexture(1, 0.82, 0, 0.8)
    guide:SetSize(2, VIEWPORT_H)
    guide:SetPoint("CENTER", viewport, "CENTER", 0, 0)

    -- Pointer arrow
    local pointer = frame:CreateTexture(nil, "OVERLAY")
    pointer:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    pointer:SetSize(28, 28)
    pointer:SetPoint("BOTTOM", viewport, "TOP", 3, -4)
    pointer:SetVertexColor(1, 0.82, 0)

    -- Spin button
    local spin = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    spin:SetSize(140, 30)
    spin:SetPoint("BOTTOM", 0, 16)
    spin:SetText("SPIN!")
    spin:SetScript("OnClick", function() KSR:InitiateSpin() end)
    self.spinButton = spin

    -- Status text
    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    status:SetPoint("BOTTOM", spin, "TOP", 0, 6)
    self.statusText = status

    self.tiles = {}
    return frame
end

-- --------------------------------------------------------------------
-- Show / hide / toggle with combat guard
-- --------------------------------------------------------------------
function UI:Toggle()
    if KSR:IsBlocked() then return end

    self:Create()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:OnKeysUpdated()
        if IsInGroup() then
            KSR:BroadcastKey()
            KSR:RequestKeys()
        else
            KSR:UpdateOwnKey()
        end
    end
end

-- --------------------------------------------------------------------
-- Combat callbacks
-- --------------------------------------------------------------------
function UI:OnCombatEnter()
    -- Immediately close the window and cancel any running spin.
    if self.animTicker then
        self.animTicker:Cancel()
        self.animTicker = nil
    end
    self.isSpinning = false
    if self.spinButton then self.spinButton:Enable() end
    if frame and frame:IsShown() then frame:Hide() end
end

function UI:OnCombatLeave()
    -- Nothing automatic; player re-opens manually.
end

-- --------------------------------------------------------------------
-- Keys updated callback
-- --------------------------------------------------------------------
function UI:OnKeysUpdated()
    if not frame or not frame:IsShown() or self.isSpinning then return end
    local keys = KSR:GetPartyKeys()
    self.statusText:SetText(string.format("|cffffd100%d|r keystone(s) ready", #keys))
end

-- --------------------------------------------------------------------
-- Build strip
-- --------------------------------------------------------------------
function UI:BuildStrip(pool)
    for _, t in ipairs(self.tiles) do
        t:Hide()
        t:SetParent(nil)
        t:ClearAllPoints()
    end
    self.tiles = {}
    if self.winnerGlow then
        self.winnerGlow:Hide()
        self.winnerGlow = nil
    end

    local long = {}
    for _ = 1, REPEATS do
        for _, p in ipairs(pool) do
            table.insert(long, p)
        end
    end

    for i, data in ipairs(long) do
        local t = CreateTile(self.strip)
        t:SetPoint("LEFT", self.strip, "LEFT", (i - 1) * TILE_W, 0)
        t:SetData(data)
        self.tiles[i] = t
    end

    self.strip:SetWidth(#long * TILE_W)
    self.longLen = #long
end

-- --------------------------------------------------------------------
-- Spin animation
-- --------------------------------------------------------------------
function UI:StartSpin(pool, winIdx, duration, isInitiator)
    -- Block if in combat
    if KSR.inCombat then return end

    self:Create()
    if not frame:IsShown() then frame:Show() end
    if self.isSpinning then return end

    self.isSpinning    = true
    self.isInitiator   = isInitiator
    self.currentPool   = pool
    self.currentWinIdx = winIdx
    self.spinButton:Disable()

    self:BuildStrip(pool)

    local poolLen       = #pool
    local targetTileIdx = ((REPEATS - 2) * poolLen) + winIdx

    local tileCenterX     = (targetTileIdx - 1) * TILE_W + TILE_W * 0.5
    local viewportCenterX = VIEWPORT_W * 0.5
    local targetOffset    = viewportCenterX - tileCenterX

    local jitter = (math.random() - 0.5) * TILE_W * 0.55
    targetOffset = targetOffset + jitter

    self.strip:ClearAllPoints()
    self.strip:SetPoint("LEFT", self.viewport, "LEFT", 0, 0)

    local startTime = GetTime()
    local fromX, toX = 0, targetOffset
    local lastCenterIdx
    local viewportCenter = VIEWPORT_W * 0.5

    if self.animTicker then self.animTicker:Cancel() end

    self.animTicker = C_Timer.NewTicker(0.016, function(ticker)
        -- If combat started mid-spin, abort gracefully
        if KSR.inCombat then
            ticker:Cancel()
            self.animTicker = nil
            self.isSpinning = false
            if self.spinButton then self.spinButton:Enable() end
            if frame and frame:IsShown() then frame:Hide() end
            return
        end

        local elapsed = GetTime() - startTime
        local t = elapsed / duration
        if t > 1 then t = 1 end

        local eased = 1 - (1 - t) ^ 4
        local x = fromX + (toX - fromX) * eased

        self.strip:ClearAllPoints()
        self.strip:SetPoint("LEFT", self.viewport, "LEFT", x, 0)

        local stripCenterPos = viewportCenter - x
        local centerIdx = math.floor(stripCenterPos / TILE_W) + 1
        if centerIdx ~= lastCenterIdx then
            lastCenterIdx = centerIdx
            if t < 0.985 then
                PlaySound(SOUND_TICK, "Master")
            end
        end

        if t >= 1 then
            ticker:Cancel()
            self.animTicker = nil
            self:OnSpinComplete(targetTileIdx)
        end
    end)
end

-- --------------------------------------------------------------------
-- Completion
-- --------------------------------------------------------------------
function UI:OnSpinComplete(targetTileIdx)
    local pool   = self.currentPool
    local winIdx = self.currentWinIdx
    local winner = pool[winIdx]

    PlaySound(SOUND_LAND,   "Master")
    PlaySound(SOUND_REVEAL, "Master")

    local tile = self.tiles[targetTileIdx]
    if tile then
        local glow = tile:CreateTexture(nil, "OVERLAY")
        glow:SetAllPoints()
        glow:SetColorTexture(1, 0.82, 0, 0.35)
        local ag = glow:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0.15)
        a:SetToAlpha(0.55)
        a:SetDuration(0.7)
        ag:Play()
        self.winnerGlow = glow

        if tile.edge and tile.edge.SetBackdropBorderColor then
            tile.edge:SetBackdropBorderColor(1, 0.82, 0, 1)
        end
    end

    local dname = (C_ChallengeMode and C_ChallengeMode.GetMapUIInfo
                   and (C_ChallengeMode.GetMapUIInfo(winner.mapID))) or "Unknown"
    self.statusText:SetText(string.format(
        "|cffffd100Winner:|r %s's |cff00ff00%s +%d|r",
        winner.name, dname, winner.level))

    if self.isInitiator and IsInGroup() then
        SendChatMessage(
            string.format("[Keystone Roulette] %s's %s +%d — let's run it!",
                winner.name, dname, winner.level),
            "PARTY")
    end

    C_Timer.After(2, function()
        self.isSpinning = false
        if self.spinButton then self.spinButton:Enable() end
    end)
end

-- --------------------------------------------------------------------
-- Bootstrap minimap button after saved variables are loaded
-- --------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    C_Timer.After(0.5, function()
        CreateMinimapButton()
    end)
end)