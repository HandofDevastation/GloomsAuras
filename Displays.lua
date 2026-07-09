-- Displays.lua — Gloom's Auras: display objects
--
-- A "display" is one custom on-screen texture (+ label) bound to a tracked spell.
-- Config lives in GloomsAurasDB.displays[<id>], keyed by an opaque DISPLAY ID (a
-- spellID for the original of each spell, a unique "dN" string for duplicates);
-- the tracked spell is always cfg.spellID. Every function here takes that display
-- id (param named `spellID` for history) and reads the real spell from cfg.spellID.
-- This module turns config into a frame and owns HOW it looks + WHERE it sits. CDM
-- decides WHEN. Position and size are set with
-- numeric /ga commands (reliable on every client — no mouse dragging). CDM.lua
-- decides WHEN each display is shown.

local ADDON_NAME = ...
local GA = _G.GloomsAuras

local issecret = _G.issecretvalue or function() return false end

local D = {}
GA.Displays = D

D.frames = {}       -- display id -> frame
D.forced = false    -- true while previewing/testing: ignore CDM show/hide
D.selectedID = nil  -- the aura selected in the panel; only it is draggable (nil = all)

-- On-screen text anchor → { labelPoint, framePoint, baseX, baseY }. The text's
-- labelPoint attaches to the aura frame's framePoint, with a small base gap; the
-- user's cfg.text.x/y offsets add on top. Default = BOTTOM (text under the aura).
local LABEL_ANCHOR = {
  BOTTOM = { "TOP", "BOTTOM", 0, -4 },
  TOP    = { "BOTTOM", "TOP", 0, 4 },
  CENTER = { "CENTER", "CENTER", 0, 0 },
  LEFT   = { "RIGHT", "LEFT", -4, 0 },
  RIGHT  = { "LEFT", "RIGHT", 4, 0 },
}

local function DB()
  return GA.db and GA.db.displays
end

function D:Config(spellID)
  local db = DB()
  return db and db[spellID]
end

-- --------------------------------------------------------------------------
-- Glow effects (LibCustomGlow). Pure rendering — never touches aura data. A glow
-- is active while the aura FRAME is shown AND cfg.glow.type is set: started on the
-- frame's OnShow, stopped on OnHide, re-applied on any config change. All calls are
-- pcall-guarded so a bad arg combo degrades to "no glow", never a Lua error.
-- --------------------------------------------------------------------------
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)   -- bar (statusbar) textures
local GLOW_KEY = "GloomsAuras"   -- our key, so we start/stop only our own glow

local function StopGlow(f)
  if not LCG then return end
  pcall(LCG.PixelGlow_Stop, f, GLOW_KEY)
  pcall(LCG.AutoCastGlow_Stop, f, GLOW_KEY)
  pcall(LCG.ButtonGlow_Stop, f)
  pcall(LCG.ProcGlow_Stop, f, GLOW_KEY)
end

local function StartGlow(f, gtype, color)
  if not LCG then return end
  local col = color and { color[1] or 1, color[2] or 1, color[3] or 1, 1 } or nil
  if gtype == "pixel" then
    pcall(LCG.PixelGlow_Start, f, col, nil, nil, nil, nil, nil, nil, nil, GLOW_KEY)
  elseif gtype == "autocast" then
    pcall(LCG.AutoCastGlow_Start, f, col, nil, nil, nil, nil, nil, GLOW_KEY)
  elseif gtype == "button" then
    pcall(LCG.ButtonGlow_Start, f, col)
  elseif gtype == "proc" then
    pcall(LCG.ProcGlow_Start, f, { color = col, key = GLOW_KEY, startAnim = false })
  end
end

-- (Re)apply the glow for one display id, honoring the frame's current shown state.
function D:ApplyGlow(displayID)
  local f = self.frames[displayID]; if not f then return end
  StopGlow(f)   -- clear any current glow (type/color may have changed, or we're hiding)
  local cfg = self:Config(displayID)
  local g = cfg and cfg.glow
  if f:IsShown() and g and g.type and g.type ~= "none" then
    StartGlow(f, g.type, g.customColor and g.color or nil)
  end
end

-- --------------------------------------------------------------------------
-- Frame creation + config application
-- --------------------------------------------------------------------------
function D:GetOrCreate(spellID)
  local cfg = self:Config(spellID)
  if not cfg then return nil end

  local f = self.frames[spellID]
  if not f then
    f = CreateFrame("Frame", "GloomsAurasDisplay" .. spellID, UIParent)
    f:SetFrameStrata("HIGH")
    f.spellID = cfg.spellID or spellID   -- the tracked spell (the key may be a duplicate id)

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    f.tex = tex

    local label = f:CreateFontString(nil, "OVERLAY")
    f.label = label   -- font/size/outline/color/anchor all set in ApplyConfig (cfg.text)

    -- Native cooldown swipe (used for cooldown-type displays). The game draws
    -- the sweep + countdown from a (possibly secret) duration — we never read it.
    local ok, cd = pcall(CreateFrame, "Cooldown", nil, f, "CooldownFrameTemplate")
    if ok and cd then
      cd:SetAllPoints()
      cd:SetDrawSwipe(true); cd:SetDrawEdge(true)
      if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(false) end
      cd:Hide()
      f.cd = cd
    end

    -- Drag-to-position (active only while the options panel is open = forced).
    -- NOT clamped to screen: auras may be positioned/dragged partially (or fully)
    -- off-screen on purpose (e.g. a huge texture bleeding past the edges). Recover a
    -- lost one via the X/Y boxes or the list (force-shown while the panel is open).
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self2)
      -- Only the selected aura drags (nil selection = preview back-door: any drags).
      if not D.forced then return end
      if D.selectedID and D.frames[D.selectedID] ~= self2 then return end
      self2.__dragging = true; self2:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self2)
      self2:StopMovingOrSizing(); self2.__dragging = false
      D:SavePositionFromFrame(spellID)
      if GA.Config and GA.Config.RefreshCurrent then GA.Config:RefreshCurrent() end
    end)

    -- Glow follows the frame's shown state (OnShow starts it, OnHide stops it).
    f.displayID = spellID   -- the frames key, so the hooks can look up cfg
    f:SetScript("OnShow", function(self2) D:ApplyGlow(self2.displayID) end)
    f:SetScript("OnHide", function(self2)
      StopGlow(self2)
      -- A bar keeps its last fill while hidden; flag it so the next feed SNAPS to the correct
      -- value (Immediate) instead of easing from the stale one — kills the target-swap catch-up.
      if self2.bar then self2.bar.__needSnap = true end
    end)

    f:Hide()
    self.frames[spellID] = f
  end

  self:ApplyConfig(spellID)
  f:EnableMouse((self.forced and (self.selectedID == nil or spellID == self.selectedID)) and true or false)
  return f
end

-- The charge-count string for a count-mode text overlay: the exact number when it's secret-safely
-- known (the endpoints max/0 always are; the middle only for 2-charge spells), else "" (a 3+
-- charge spell mid-recharge is genuinely unreadable). Resolves the spell via DisplayChargeSpell.
function D:CountString(cfg)
  if not (GA.CDM and GA.CDM.DisplayChargeSpell) then return "" end
  local sid = GA.CDM:DisplayChargeSpell(cfg)
  if not sid then return "" end
  local n = GA.CDM:ChargeCount(sid)
  return (n ~= nil) and tostring(n) or ""
end

-- Live-refresh a count-mode overlay's number without redoing font/anchor — called from
-- RefreshDisplays on charge transitions. No-op unless the display is shown + in count mode.
function D:RefreshCountText(spellID)
  local f = self.frames[spellID]
  if not f or not f.label then return end
  local cfg = self:Config(spellID); local t = cfg and cfg.text
  if not (t and t.show ~= false and t.showCount) then return end
  f.label:SetText(self:CountString(cfg))
end

-- --------------------------------------------------------------------------
-- Bar displays (cfg.kind == "bar"): a StatusBar child instead of the icon texture.
-- The FILL is driven by a secret-safe duration OBJECT fed via SetTimerDuration (the bar
-- animates itself; we never read the time — see CDM:UpdateBar / BarDurationObject). Styling
-- (texture/colour/orientation) is pure rendering. See docs/BARS-DESIGN.md.
-- --------------------------------------------------------------------------
local function EnsureBar(f)
  if f.bar then return f.bar end
  local bar = CreateFrame("StatusBar", nil, f)
  bar:SetAllPoints(f)
  -- A self-contained white fill (SetStatusBarColor tints it) — no Blizzard chrome. An LSM
  -- statusbar texture can replace it per-bar (cfg.bar.texture).
  local fill = bar:CreateTexture(nil, "ARTWORK")
  fill:SetColorTexture(1, 1, 1, 1)
  bar:SetStatusBarTexture(fill)
  bar.fill = fill
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(bar)
  bar.bg = bg
  -- Value text (stacks count). Its own FontString (NOT the shared name label) centred on the bar;
  -- fed the raw applications via SetText, which accepts a SECRET value (renders it in combat).
  local vt = bar:CreateFontString(nil, "OVERLAY")
  vt:SetPoint("CENTER", bar, "CENTER", 0, 0)
  vt:Hide()
  bar.valueText = vt
  f.bar = bar
  return bar
end

function D:ApplyBarStyle(f, cfg)
  local bar = EnsureBar(f)
  local b = cfg.bar or {}
  -- Fill texture: an LSM statusbar name if set + resolvable, else our white fill.
  if LSM and type(b.texture) == "string" and b.texture ~= "" and LSM.Fetch then
    local path = LSM:Fetch("statusbar", b.texture, true)
    bar:SetStatusBarTexture(path or bar.fill)
  else
    bar:SetStatusBarTexture(bar.fill)
  end
  bar:SetOrientation((b.orientation == "VERTICAL") and "VERTICAL" or "HORIZONTAL")
  bar:SetReverseFill(b.reverse and true or false)
  local oc = GA.COLOR and GA.COLOR.orange
  local col = b.color or (oc and { oc.r, oc.g, oc.b }) or { 1, 0.47, 0.16 }
  bar:SetStatusBarColor(col[1] or 1, col[2] or 1, col[3] or 1)
  local bgc = b.bg or { 0, 0, 0, 0.55 }
  bar.bg:SetColorTexture(bgc[1] or 0, bgc[2] or 0, bgc[3] or 0, bgc[4] or 0.55)
  -- Initial state depends on mode: a stacks bar spans 0..max and starts empty; a duration bar
  -- spans 0..1 and starts full — both are corrected by the first CDM:UpdateBar feed.
  if b.mode == "stacks" then
    bar:SetMinMaxValues(0, b.max or 10)
    bar:SetValue(0)
  else
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
  end
  bar.__needSnap = true            -- first duration feed snaps to actual remaining (/reload mid-fight)
  -- Value text (stacks count) — its own font, shown only when the bar asks for it.
  local vt = bar.valueText
  if vt then
    if b.showValue then
      local font = (GA.FONT and GA.FONT.body) or (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
      if not vt:SetFont(font, b.valueSize or 14, "OUTLINE") then
        vt:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", b.valueSize or 14, "OUTLINE")
      end
      vt:SetTextColor(1, 1, 1)
      vt:Show()
    else
      vt:Hide()
    end
  end
  bar:SetAlpha(cfg.alpha or 1)
  bar:Show()
end

-- Feed the source aura's live duration OBJECT so the bar drains itself (no polling). Resolved
-- + validated secret-safely in CDM:BarDurationObject. No-op if the object isn't resolvable yet
-- (e.g. a secret auraInstanceID in instances) — the bar just stays full rather than erroring.
function D:UpdateBar(spellID)
  local f = self.frames[spellID]; if not f or not f.bar then return end
  local cfg = self:Config(spellID); if not cfg or cfg.kind ~= "bar" then return end
  if not GA.CDM then return end
  local b = cfg.bar or {}

  if b.mode == "stacks" then
    -- Stacks: feed the (possibly SECRET) applications count straight to SetValue + SetText.
    -- We never operate on it; both sinks are AllowedWhenTainted so they render a secret in combat.
    if not GA.CDM.BarStackValue then return end
    local v = GA.CDM:BarStackValue(cfg)
    if v == nil then return end
    pcall(function()
      f.bar:SetMinMaxValues(0, b.max or 10)
      f.bar:SetValue(v)
      local vt = f.bar.valueText
      if vt and b.showValue then
        if issecret(v) then vt:SetText(v)              -- SetText accepts the secret directly
        else vt:SetText(tostring(v)) end               -- plain (out of combat)
      end
    end)
    return
  end

  -- Duration modes (aura_dur / cd_dur): feed a duration OBJECT so the bar self-drains. Same feed
  -- code — only the object's source differs (the source aura's remaining vs the spell's cooldown).
  local durObj
  if b.mode == "cd_dur" then
    durObj = GA.CDM.CdDurationObject and GA.CDM:CdDurationObject(cfg.spellID)
  else
    durObj = GA.CDM.BarDurationObject and GA.CDM:BarDurationObject(cfg)
  end
  if not durObj then return end
  if not (Enum and Enum.StatusBarInterpolation and Enum.StatusBarTimerDirection and f.bar.SetTimerDuration) then return end
  local dir = (b.fill == "fill") and Enum.StatusBarTimerDirection.ElapsedTime
                                 or  Enum.StatusBarTimerDirection.RemainingTime
  -- Snap (Immediate) on the first feed after a (re)show so a stale fill doesn't visibly catch up;
  -- ease (ExponentialEaseOut) on live re-feeds (a DoT refresh grows smoothly). Either way the
  -- StatusBar self-animates the drain from the duration object — the interp only affects jumps.
  local snap = f.bar.__needSnap
  f.bar.__needSnap = nil
  local interp = snap and Enum.StatusBarInterpolation.Immediate or Enum.StatusBarInterpolation.ExponentialEaseOut
  pcall(function()
    f.bar:SetMinMaxValues(0, 1)
    f.bar:SetTimerDuration(durObj, interp, dir)
  end)
end

function D:ApplyConfig(spellID)
  local f = self.frames[spellID]
  local cfg = self:Config(spellID)
  if not f or not cfg then return end

  local w = cfg.width or cfg.size or 64
  local h = cfg.height or cfg.size or 64
  f:SetSize(w, h)

  -- point = { "CENTER", x, y } ; x/y are offsets from screen centre (up/right +).
  local p = cfg.point or { "CENTER", 0, 0 }
  if not f.__dragging then  -- don't snap it back mid-drag
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", p[2] or 0, p[3] or 0)
  end

  if cfg.kind == "bar" then
    -- Bar display: a StatusBar drives the visual; hide the icon texture + cooldown swipe.
    f.tex:Hide()
    if f.cd then f.cd:Hide() end
    self:ApplyBarStyle(f, cfg)
  else
    -- Icon/texture display (default). Hide any bar child a kind-switch left behind.
    if f.bar then f.bar:Hide() end
    f.tex:Show()

    -- Texture: a custom file path / fileID if set, else the spell's own icon.
    local custom = cfg.texture
    if type(custom) == "string" and custom:match("^%d+$") then custom = tonumber(custom) end  -- a typed/stored fileID
    if custom and custom ~= "" then
      f.tex:SetTexture(custom)
      f.tex:SetTexCoord(0, 1, 0, 1)
    else
      local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(cfg.spellID or spellID)
      if icon then
        f.tex:SetTexture(icon)
        f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- trim the default icon border
      else
        f.tex:SetColorTexture(0.9, 0.2, 0.6)  -- fallback: unmistakable magenta panel
        f.tex:SetTexCoord(0, 1, 0, 1)
      end
    end
    f.tex:SetAlpha(cfg.alpha or 1.0)

    -- Recolour / blend / desaturate — pure rendering, no combat data involved.
    f.tex:SetBlendMode((cfg.blend and cfg.blend ~= "" and cfg.blend) or "BLEND")
    f.tex:SetDesaturated(cfg.desaturate and true or false)
    if cfg.color then
      f.tex:SetVertexColor(cfg.color[1] or 1, cfg.color[2] or 1, cfg.color[3] or 1)
    else
      f.tex:SetVertexColor(1, 1, 1)
    end
  end

  -- Frame strata (how the aura layers against other UI).
  f:SetFrameStrata((cfg.strata and cfg.strata ~= "" and cfg.strata) or "HIGH")

  -- On-screen text overlay. cfg.text = { show, str, font, size, color, outline, anchor, x, y }.
  -- Backward-compat: no cfg.text ⇒ legacy behavior (show the aura's name via cfg.showLabel).
  local t = cfg.text
  local show
  if t then show = (t.show ~= false) else show = (cfg.showLabel ~= false) end
  if show then
    local str
    if t and t.showCount then
      str = self:CountString(cfg)                 -- live charge count (Pass 2), overrides custom text
    else
      str = (t and t.str and t.str ~= "" and t.str) or cfg.label or tostring(cfg.spellID or spellID)
    end
    local font = (t and t.font) or (GA.FONT and GA.FONT.body) or (STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF")
    local fallbackFont = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    local size = (t and t.size) or 14
    local flags = (t and t.outline == "NONE") and "" or (t and t.outline) or "OUTLINE"
    local col = t and t.color
    local a = LABEL_ANCHOR[(t and t.anchor) or "BOTTOM"] or LABEL_ANCHOR.BOTTOM
    local ux, uy = (t and t.x) or 0, (t and t.y) or 0

    if not f.label:SetFont(font, size, flags) then f.label:SetFont(fallbackFont, size, flags) end
    f.label:SetTextColor(col and col[1] or 1, col and col[2] or 1, col and col[3] or 1)
    f.label:SetText(str)
    f.label:ClearAllPoints()
    f.label:SetPoint(a[1], f, a[2], a[3] + ux, a[4] + uy)
    f.label:Show()
  else
    f.label:Hide()
  end

  self:ApplyGlow(spellID)   -- (re)apply the glow effect for this display's current config
end

-- Create/refresh every enabled display frame (starts hidden; CDM decides shown).
function D:RefreshAll()
  local db = DB()
  if not db then return end
  for spellID, cfg in pairs(db) do
    if cfg.enabled ~= false then
      self:GetOrCreate(spellID)
    else
      local f = self.frames[spellID]
      if f then f:Hide() end
    end
  end
end

-- --------------------------------------------------------------------------
-- Show/hide (called by CDM). No-op while forced (preview/test).
-- --------------------------------------------------------------------------
function D:SetShown(spellID, value)
  if self.forced then return end
  local f = self.frames[spellID] or self:GetOrCreate(spellID)
  if f then pcall(f.SetShown, f, value) end
end
function D:Show(spellID) self:SetShown(spellID, true) end
function D:Hide(spellID) self:SetShown(spellID, false) end

-- Save position from the frame's current (dragged) location; re-anchor cleanly.
function D:SavePositionFromFrame(spellID)
  local f, cfg = self.frames[spellID], self:Config(spellID)
  if not f or not cfg then return end
  local fx, fy = f:GetCenter()
  local ux, uy = UIParent:GetCenter()
  if not (fx and ux) then return end
  cfg.point = { "CENTER", math.floor(fx - ux + 0.5), math.floor(fy - uy + 0.5) }
  f:ClearAllPoints()
  f:SetPoint("CENTER", UIParent, "CENTER", cfg.point[2], cfg.point[3])
end

-- Enable/disable mouse on all display frames (draggable while the panel is open).
-- Enable mouse (= draggable) only on the selected display while forced; the rest
-- stay visible but click-through so overlapping auras don't fight for the cursor.
-- With no selection (e.g. the /ga preview back-door) every display is draggable.
function D:ApplyInteractivity()
  local sel = self.selectedID
  local haveSel = sel ~= nil and self.frames[sel] ~= nil
  for id, f in pairs(self.frames) do
    f:EnableMouse((self.forced and (not haveSel or id == sel)) and true or false)
  end
end

function D:SetInteractive(on)
  self:ApplyInteractivity()
end

-- Panel selection changed → re-apply which single display is draggable.
function D:SetSelectedDisplay(id)
  self.selectedID = id
  self:ApplyInteractivity()
end

-- While the panel is open (forced) the on-screen preview shows ONLY the selected
-- aura + any aura the user has 'eyed' on (cfg.preview) — so editing isn't buried
-- under every aura at once. Purely an editor convenience; in-game (not forced) is
-- unaffected, and cfg.preview has nothing to do with whether the aura runs.
function D:RefreshForced()
  if not self.forced then return end
  local db = DB(); if not db then return end
  local sel = self.selectedID
  for id, cfg in pairs(db) do
    if (id == sel) or cfg.preview then
      local f = self:GetOrCreate(id); if f then f:Show() end
    else
      local f = self.frames[id]; if f then f:Hide() end
    end
  end
end

-- Cooldown swipe (for cooldown-type displays). The game draws the sweep +
-- countdown from a possibly-secret duration; we never read the number.
function D:SetCooldownEnabled(spellID, on)
  local f = self.frames[spellID]
  if f and f.cd then f.cd:SetShown(on and true or false) end
end

function D:UpdateCooldown(spellID)
  local f = self.frames[spellID]
  if not f or not f.cd then return end
  local cfg = self:Config(spellID)
  local sid = (cfg and cfg.spellID) or spellID
  pcall(function()
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(sid)
    if not info then return end
    -- Cooldown setters are "AllowedWhenUntainted": an addon may pass PLAIN values
    -- (out of combat) but NOT secret ones (in combat) — that throws. So only draw
    -- the sweep when the values are readable; otherwise leave the icon bare.
    if issecret(info.startTime) or issecret(info.duration) then
      if f.cd.Clear then f.cd:Clear() end
      return
    end
    f.cd:SetCooldown(info.startTime, info.duration, info.modRate)
  end)
end

-- --------------------------------------------------------------------------
-- Position / size (numeric, live). Return true on success.
-- --------------------------------------------------------------------------
function D:SetPosition(spellID, x, y)
  local cfg = self:Config(spellID)
  if not cfg then return false end
  cfg.point = { "CENTER", x, y }
  self:ApplyConfig(spellID)
  return true
end

function D:SetDisplaySize(spellID, size)
  local cfg = self:Config(spellID)
  if not cfg then return false end
  cfg.size = size
  self:ApplyConfig(spellID)
  return true
end

-- --------------------------------------------------------------------------
-- Preview (toggle force-show so you can see displays while positioning them)
-- and test (force-show for a few seconds).
-- --------------------------------------------------------------------------
function D:Preview()
  self.forced = not self.forced
  self:SetInteractive(self.forced)
  if self.forced then
    local db = DB()
    if db then
      for spellID, cfg in pairs(db) do
        if cfg.enabled ~= false then
          local f = self:GetOrCreate(spellID)
          if f then f:Show() end
        end
      end
    end
    GA.msg("preview |cff55ff55ON|r — all displays shown so you can position them. |cffffd200/ga preview|r again to turn off.")
  else
    GA.msg("preview |cffff5555OFF|r.")
    if GA.CDM and GA.CDM.Discover then GA.CDM:Discover() end
  end
  return self.forced
end

function D:Test(seconds)
  seconds = seconds or 5
  self.forced = true
  local db, n = DB(), 0
  if db then
    for spellID, cfg in pairs(db) do
      if cfg.enabled ~= false then
        local f = self:GetOrCreate(spellID)
        if f then f:Show(); n = n + 1 end
      end
    end
  end
  GA.msg(("test: showing %d display(s) for %ds."):format(n, seconds))
  C_Timer.After(seconds, function()
    D.forced = false
    if GA.CDM and GA.CDM.Discover then GA.CDM:Discover() end
  end)
end
