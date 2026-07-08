-- MinimapButton.lua — minimap button via LibDBIcon (a LibDataBroker launcher),
-- so minimap-button collectors (MBB, ChocolateBar, etc.) treat it as a
-- first-class citizen. The libs are embedded in Libs/; if they were ever absent
-- we fall back to a self-contained button (no LibStub/Ace dependency). Both paths
-- share the same icon, click action, tooltip, and SavedVars-driven show/hide.

local ADDON = ...
local GA = _G.GloomsAuras

local LDB     = LibStub and LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)

-- Shared behavior ----------------------------------------------------------

local function onClick(_, mouseButton)
  if GA.Config and GA.Config.Toggle then GA.Config:Toggle() end
end

local function fillTooltip(tt)
  tt:SetText("Gloom's Auras", 0.576, 0.42, 1)  -- 936bff purple
  tt:AddLine("Left-click: open options", 0.8, 0.8, 0.8)
end

-- LibDBIcon writes hide + minimapPos into GA.global.minimap (account-wide, so the
-- button placement/visibility is shared across characters — not per profile).
local function ensureDB()
  if not GA.global then return false end
  GA.global.minimap = GA.global.minimap or {}
  return true
end

-- LibDBIcon path -----------------------------------------------------------

local dataObject

local function registerBroker()
  dataObject = LDB:NewDataObject(ADDON, {
    type = "launcher",
    label = "Gloom's Auras",
    icon = GA.MEDIA .. "minimap.png",
    OnClick = onClick,
    OnTooltipShow = fillTooltip,
  })
  LDBIcon:Register(ADDON, dataObject, GA.global.minimap)
end

-- Self-contained fallback (used only if the libs are ever missing) ----------

local btn

local function position(angle)
  local rad = math.rad(angle)
  local r = (Minimap:GetWidth() / 2) + 5
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * r, math.sin(rad) * r)
end

local function onDragUpdate()
  local mx, my = Minimap:GetCenter()
  local scale = Minimap:GetEffectiveScale()
  local px, py = GetCursorPosition()
  px, py = px / scale, py / scale
  local angle = math.deg(math.atan2(py - my, px - mx))
  position(angle)
  GA.global.minimap.minimapPos = angle
end

local function buildFallback()
  btn = CreateFrame("Button", "GloomsAurasMinimapButton", Minimap)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetSize(31, 31)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(GA.MEDIA .. "minimap.png")
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", 0, 1)

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  btn:SetScript("OnClick", onClick)
  btn:SetScript("OnDragStart", function() btn:SetScript("OnUpdate", onDragUpdate) end)
  btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)

  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    fillTooltip(GameTooltip)
    GameTooltip:AddLine("Drag: move around the minimap", 0.55, 0.55, 0.55)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  position(GA.global.minimap.minimapPos or 200)
end

-- Public API ---------------------------------------------------------------

local function useLib()
  return LDB and LDBIcon
end

-- Create the button at login unless the user has hidden it.
function GA:InitMinimapButton()
  if not ensureDB() then return end
  if useLib() then
    if not dataObject then registerBroker() end
    if GA.global.minimap.hide then LDBIcon:Hide(ADDON) else LDBIcon:Show(ADDON) end
  else
    if btn then return end
    if not GA.global.minimap.hide then buildFallback() end
  end
end

-- /ga minimap — toggle the button on/off (persisted). Returns shown state.
function GA:ToggleMinimapButton()
  if not ensureDB() then return end
  GA.global.minimap.hide = not GA.global.minimap.hide
  if useLib() then
    if not dataObject then registerBroker() end
    if GA.global.minimap.hide then LDBIcon:Hide(ADDON) else LDBIcon:Show(ADDON) end
  else
    if GA.global.minimap.hide then
      if btn then btn:Hide() end
    elseif btn then
      btn:Show()
    else
      buildFallback()
    end
  end
  return not GA.global.minimap.hide
end
