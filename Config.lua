-- Config.lua — Gloom's Auras: options panel
--
-- A control panel (opened with /ga) skinned to match Gloom's Build Barn: a
-- near-black navy plate, bright-purple accents, bundled Khand/GeneralSans fonts,
-- flat alpha-driven buttons. Two-pane master/detail layout:
--   • LEFT  — a scrollable list of every display you've created (icon + name);
--             click one to edit it, "+ Add aura" opens the picker.
--   • RIGHT — the settings for the selected display: Texture, Position & Size,
--             Trigger. Each numeric setting is a slider + −/+ steppers + a typed
--             value box, all driving the same saved config live.
-- Displays are force-shown (and draggable) while the panel is open.

local ADDON_NAME = ...
local GA = _G.GloomsAuras

local C = {}
GA.Config = C

local issecret = _G.issecretvalue or function() return false end

local COLOR, FONT, MEDIA = GA.COLOR, GA.FONT, GA.MEDIA
local TEXT = { r = 0.90, g = 0.92, b = 0.96 }  -- body text
local MUTE = { r = 0.55, g = 0.57, b = 0.63 }  -- hints / secondary
local DEFAULT_FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local panel, selectedID, editorName, triggerSummary, visibilitySummary
local pickerFrame, pickerOnPick
local triggerFrame, triggerEditID, triggerTitle, triggerLogicBtn
local rows, triggerRows = {}, {}

-- Pop-up editors (Trigger, Visibility, Sound, Texture, aura picker) are mutually
-- exclusive so they don't stack on top of each other. Each registers here when built;
-- opening one closes the rest, except any passed as `keep` (the aura picker opened
-- from the Trigger editor keeps that editor open underneath it).
local subWindows = {}
local function RegisterSubWindow(f) subWindows[#subWindows + 1] = f end
local function CloseSubWindows(...)
  local keep = {}
  for i = 1, select("#", ...) do local f = select(i, ...); if f then keep[f] = true end end
  for _, f in ipairs(subWindows) do
    if not keep[f] and f:IsShown() then f:Hide() end
  end
end

local listFrame, listRows, listData, listOffset = nil, {}, {}, 0
local LIST_ROWS = 17   -- leave room for the Add / Duplicate / Remove button stack
local LIST_ROW_H = 24

-- Texture blend modes (SetBlendMode) + friendly labels; frame strata choices.
local BLEND_MODES = {
  { "BLEND", "Blend" }, { "ADD", "Add (glow)" }, { "MOD", "Modulate" },
}
local STRATA_MODES = {
  { "LOW", "Low" }, { "MEDIUM", "Medium" }, { "HIGH", "High" },
  { "DIALOG", "Dialog" }, { "TOOLTIP", "Tooltip" },
}

local STATE_ORDER = { "buff_active", "buff_inactive", "cd_ready", "cd_oncd" }
local STATE_LABEL = {
  buff_active   = "buff is active",
  buff_inactive = "buff is NOT active",
  cd_ready      = "cooldown is ready",
  cd_oncd       = "cooldown is NOT ready",
}

-- --------------------------------------------------------------------------
-- Skin toolkit (mirrors Gloom's Build Barn's UI helpers).
-- --------------------------------------------------------------------------
local function setFont(fs, path, size, flags)
  if not fs:SetFont(path, size, flags or "") then fs:SetFont(DEFAULT_FONT, size, flags or "") end
end

local function newText(parent, font, size, cc, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  setFont(fs, font, size)
  if cc then fs:SetTextColor(cc.r, cc.g, cc.b) end
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

-- Four 1px edge textures forming a squared border; returns a handle w/ :SetColor.
local function addEdges(f, cc, thick)
  thick = thick or 1
  local e = {}
  local function edge(p1, p2, w, h)
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(cc.r, cc.g, cc.b, cc.a or 1)
    t:SetPoint(p1); t:SetPoint(p2)
    if w then t:SetWidth(w) end
    if h then t:SetHeight(h) end
    return t
  end
  e.top    = edge("TOPLEFT", "TOPRIGHT", nil, thick)
  e.bottom = edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, thick)
  e.left   = edge("TOPLEFT", "BOTTOMLEFT", thick, nil)
  e.right  = edge("TOPRIGHT", "BOTTOMRIGHT", thick, nil)
  function e:SetColor(c, a)
    for _, t in pairs({ self.top, self.bottom, self.left, self.right }) do
      t:SetColorTexture(c.r, c.g, c.b, a or c.a or 1)
    end
  end
  return e
end

-- Flat text input — no Blizzard template (no bevel/rounded corners/shadow). Just a
-- plain box: faint purple fill + 1px rim, brightening on focus.
local function flatEditBox(parent, w, h)
  local e = CreateFrame("EditBox", nil, parent)
  e:SetSize(w, h); e:SetAutoFocus(false)
  setFont(e, FONT.body, 12); e:SetTextColor(TEXT.r, TEXT.g, TEXT.b)
  e:SetTextInsets(6, 6, 0, 0)
  local bg = e:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
  bg:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.10)
  -- No border (Jason's preference). Focus cue = brighten the fill instead.
  e:SetScript("OnEditFocusGained", function() bg:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.22) end)
  e:SetScript("OnEditFocusLost",  function() bg:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.10) end)
  return e
end

-- Navy plate + subtle flame texture + 1px rim (the Build Barn look).
local function skinPlate(f)
  local base = f:CreateTexture(nil, "BACKGROUND")
  base:SetAllPoints(); base:SetColorTexture(COLOR.dark.r, COLOR.dark.g, COLOR.dark.b, COLOR.dark.a)
  local flame = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  flame:SetAllPoints(); flame:SetTexture(MEDIA .. "bg_flame.png"); flame:SetAlpha(0.30)
  addEdges(f, COLOR.rim, 1)
end

-- Flat, alpha-driven button. Opacity is the only state: _base (default 50%) vs
-- active (100%); hover brightens. Colour stays fully opaque (never bake alpha in).
local function flatButton(parent, w, h, cc, label, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  b._base, b._active = 0.55, false
  b.fill = b:CreateTexture(nil, "BACKGROUND")
  b.fill:SetAllPoints(); b.fill:SetColorTexture(cc.r, cc.g, cc.b, 1); b.fill:SetAlpha(b._base)
  b.text = newText(b, FONT.bodyM, size or 12, { r = 1, g = 1, b = 1 }, "CENTER")  -- lighter weight (Medium)
  b.text:SetPoint("CENTER")
  b:SetFontString(b.text)  -- wire the fontstring so b:SetText() updates it
  if label then b.text:SetText(label) end
  local function level() return b._active and 1 or b._base end
  b:SetScript("OnEnter", function(self) if self:IsEnabled() and not self._active then self.fill:SetAlpha(math.min(1, self._base + 0.25)) end end)
  b:SetScript("OnLeave", function(self) self.fill:SetAlpha(level()) end)
  b:SetScript("OnDisable", function(self) self.fill:SetAlpha(0.2); self.text:SetTextColor(0.5, 0.5, 0.5) end)
  b:SetScript("OnEnable",  function(self) self.fill:SetAlpha(level()); self.text:SetTextColor(1, 1, 1) end)
  function b:SetActive(a) self._active = a and true or false; self.fill:SetAlpha(level()) end
  function b:SetBase(a) self._base = a; self.fill:SetAlpha(level()) end
  return b
end

local function Header(parent, x, yOff, text)
  local fs = newText(parent, FONT.head, 13, COLOR.purple, "LEFT")
  fs:SetPoint("TOPLEFT", x, yOff)
  fs:SetText((text or ""):upper())
  return fs
end

-- --------------------------------------------------------------------------
-- Data helpers
-- --------------------------------------------------------------------------
local function DB() return GA.db and GA.db.displays end

local function DisplayList()
  local out = {}
  local db = DB()
  if db then for id in pairs(db) do out[#out + 1] = id end end
  -- Keys are a spellID (number) for the original of a spell, or a "dN" string for a
  -- duplicate. Sort by tracked spell then by key so number/string keys never compare
  -- directly (that would error) and duplicates group under their source spell.
  table.sort(out, function(a, b)
    local sa = (db and db[a] and db[a].spellID) or 0
    local sb = (db and db[b] and db[b].spellID) or 0
    if sa ~= sb then return sa < sb end
    return tostring(a) < tostring(b)
  end)
  return out
end

local function Cfg()
  local db = DB()
  return db and selectedID and db[selectedID]
end

-- Deep-copy a display's config (nested tables: point, color, trigger, visibility, sound).
local function DeepCopy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = DeepCopy(v) end
  return o
end

-- A fresh, unique display id — a "dN" STRING so it never collides with a numeric
-- spellID key (originals stay keyed by their spellID; duplicates get these).
local function NewDisplayID()
  local db = GA.db
  db.seq = (db.seq or 0) + 1
  local id = "d" .. db.seq
  while DB() and DB()[id] ~= nil do db.seq = db.seq + 1; id = "d" .. db.seq end
  return id
end

local function ReapplySelected()
  if GA.Displays and selectedID then GA.Displays:ApplyConfig(selectedID) end
end

local function SummaryText(cfg)
  local t = cfg and cfg.trigger
  if t and t.conditions and #t.conditions > 0 then
    return ("|cffffffff%d condition(s) · %s|r"):format(#t.conditions, t.logic or "AND")
  end
  return "|cff888888none — shows on its own state|r"
end

local VIS_KEYS = { "combat", "target", "casting", "mounted", "vehicle", "instance",
  "encounter", "resting", "stealthed", "group", "raid", "warmode", "alive", "spellKnown" }
local function VisibilitySummary(cfg)
  local v = cfg and cfg.visibility
  local n = 0
  if v then
    for _, k in ipairs(VIS_KEYS) do if v[k] then n = n + 1 end end
    if v.specs and next(v.specs) then n = n + 1 end
  end
  if n > 0 then return ("|cffffffff%d condition(s)|r"):format(n) end
  return "|cff888888none — always eligible|r"
end

-- --------------------------------------------------------------------------
-- Numeric row: label + [−] + slider (best-effort) + [+] + value box.
-- --------------------------------------------------------------------------
local function MakeSlider(parent, yOff, label, minV, maxV, step, get, set)
  local title = newText(parent, FONT.body, 12, TEXT, "LEFT")
  title:SetPoint("TOPLEFT", 16, yOff); title:SetWidth(66)
  title:SetText(label)

  local minus = flatButton(parent, 22, 20, COLOR.heroic, "−", 15)
  minus:SetPoint("TOPLEFT", 86, yOff + 3)

  -- Flat slider (own look, no template): a dark track matching the input fields
  -- (no border) + a bright-purple vertical marker for the thumb. Best-effort: if
  -- it can't be built the row still works via the steppers + value box.
  local slider
  pcall(function() slider = CreateFrame("Slider", nil, parent) end)
  if slider then
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(150, 18); slider:SetPoint("TOPLEFT", 116, yOff + 1)
    slider:SetHitRectInsets(0, 0, -5, -5)  -- taller grab area than the thin track
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0); track:SetPoint("RIGHT", 0, 0); track:SetHeight(8)
    track:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.10)  -- = input-field fill
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1)      -- bright marker
    thumb:SetSize(6, 18)
    slider:SetThumbTexture(thumb)
    slider:SetMinMaxValues(minV, maxV); slider:SetValueStep(step); slider:SetObeyStepOnDrag(true)
  end

  local plus = flatButton(parent, 22, 20, COLOR.heroic, "+", 15)
  plus:SetPoint("TOPLEFT", 272, yOff + 3)

  local edit = flatEditBox(parent, 50, 20); edit:SetPoint("TOPLEFT", 306, yOff + 2)

  local applying = false
  local function clamp(v) return math.max(minV, math.min(maxV, math.floor(v + 0.5))) end
  local function apply(v)
    v = clamp(v)
    applying = true
    if slider then slider:SetValue(v) end
    edit:SetText(tostring(v)); edit:SetCursorPosition(0)
    applying = false
    set(v); ReapplySelected()
  end

  if slider then slider:SetScript("OnValueChanged", function(_, v) if not applying then apply(v) end end) end
  edit:SetScript("OnEnterPressed", function(self) local v = tonumber(self:GetText()); if v then apply(v) end self:ClearFocus() end)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  minus:SetScript("OnClick", function() apply((get() or minV) - step) end)
  plus:SetScript("OnClick",  function() apply((get() or minV) + step) end)

  local row = {}
  function row:refresh()
    local v = clamp(get() or minV)
    applying = true
    if slider then slider:SetValue(v) end
    edit:SetText(tostring(v)); edit:SetCursorPosition(0)
    applying = false
  end
  function row:setEnabled(on)
    if slider then slider:SetEnabled(on) end
    edit:SetEnabled(on); minus:SetEnabled(on); plus:SetEnabled(on)
  end
  return row
end

-- Text row: label + wide entry box (used for the texture path).
local function MakeText(parent, yOff, label, get, set, w)
  local title = newText(parent, FONT.body, 12, TEXT, "LEFT")
  title:SetPoint("TOPLEFT", 16, yOff); title:SetText(label)

  local edit = flatEditBox(parent, w or 330, 20); edit:SetPoint("TOPLEFT", 22, yOff - 18)
  edit:SetScript("OnEnterPressed", function(self)
    local t = self:GetText(); if t == "" then t = nil end
    set(t); ReapplySelected(); self:ClearFocus()
  end)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  local row = {}
  function row:refresh() local v = get(); edit:SetText(v ~= nil and tostring(v) or ""); edit:SetCursorPosition(0) end
  function row:setEnabled(on) edit:SetEnabled(on) end
  return row
end

-- Small flat checkbox: a 16px box + label. :Set/:Get + OnClick callback.
local function flatCheck(parent, label)
  local c = CreateFrame("Button", nil, parent)
  c:SetSize(16, 16)
  local box = c:CreateTexture(nil, "ARTWORK"); box:SetAllPoints(); box:SetColorTexture(1, 1, 1, 0.08)
  addEdges(c, COLOR.rim, 1)
  c.mark = c:CreateTexture(nil, "OVERLAY"); c.mark:SetPoint("CENTER"); c.mark:SetSize(10, 10)
  c.mark:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1); c.mark:Hide()
  c.label = newText(c, FONT.body, 12, TEXT, "LEFT"); c.label:SetPoint("LEFT", c, "RIGHT", 6, 0); c.label:SetText(label)
  c._on = false
  function c:Get() return self._on end
  function c:Set(v) self._on = v and true or false; self.mark:SetShown(self._on) end
  return c
end

-- Colour-tint control: [✓ Tint] + a swatch. Clicking either opens the game
-- ColorPickerFrame; unchecking clears the tint (cfg.color = nil ⇒ white).
local function MakeColor(parent, x, yOff, get, set)
  local chk = flatCheck(parent, "Tint")
  chk:SetPoint("TOPLEFT", x, yOff)
  local swatch = CreateFrame("Button", nil, parent); swatch:SetSize(16, 16)
  swatch:SetPoint("LEFT", chk.label, "RIGHT", 6, 0)
  local sw = swatch:CreateTexture(nil, "ARTWORK"); sw:SetAllPoints(); addEdges(swatch, COLOR.rim, 1)

  local function updateSwatch()
    local col = get()
    if col then sw:SetColorTexture(col[1] or 1, col[2] or 1, col[3] or 1, 1)
    else sw:SetColorTexture(0.28, 0.28, 0.32, 1) end
  end
  local function openPicker()
    local col = get() or { 1, 1, 1 }
    local function apply()
      local r, g, b = ColorPickerFrame:GetColorRGB()
      set({ r, g, b }); chk:Set(true); updateSwatch(); ReapplySelected()
    end
    local info = { hasOpacity = false, r = col[1], g = col[2], b = col[3], swatchFunc = apply }
    if ColorPickerFrame.SetupColorPickerAndShow then
      ColorPickerFrame:SetupColorPickerAndShow(info)
    else  -- pre-10.2.5 fallback
      ColorPickerFrame.func = apply
      ColorPickerFrame:SetColorRGB(col[1], col[2], col[3]); ColorPickerFrame:Show()
    end
  end
  swatch:SetScript("OnClick", openPicker)
  chk:SetScript("OnClick", function()
    if get() then set(nil); chk:Set(false); updateSwatch(); ReapplySelected() else openPicker() end
  end)

  local row = {}
  function row:refresh() chk:Set(get() ~= nil); updateSwatch() end
  function row:setEnabled(on) chk:SetEnabled(on); swatch:SetEnabled(on) end
  return row
end

-- Cycle button: click to advance through `values` = { {stored, label}, ... }.
local function MakeCycle(parent, x, yOff, w, prefix, values, get, set)
  local b = flatButton(parent, w, 20, COLOR.heroic, "", 12)
  b:SetPoint("TOPLEFT", x, yOff)
  local function label()
    local cur = get()
    for _, v in ipairs(values) do if v[1] == cur then return prefix .. v[2] end end
    return prefix .. values[1][2]
  end
  b:SetScript("OnClick", function()
    local cur, idx = get(), 1
    for i, v in ipairs(values) do if v[1] == cur then idx = i; break end end
    set(values[(idx % #values) + 1][1]); b:SetText(label()); ReapplySelected()
  end)
  local row = {}
  function row:refresh() b:SetText(label()) end
  function row:setEnabled(on) b:SetEnabled(on) end
  return row
end

-- Proper dropdown menu (same signature as MakeCycle): a button showing the current
-- value that opens a list of options below it. Only one dropdown menu is open at a
-- time. values = { {storedValue, label}, ... }.
local openDropdownMenu
local function MakeDropdown(parent, x, yOff, w, prefix, values, get, set)
  local b = flatButton(parent, w, 20, COLOR.heroic, "", 12)
  b:SetPoint("TOPLEFT", x, yOff)
  local function label()
    local cur = get()
    for _, v in ipairs(values) do if v[1] == cur then return prefix .. v[2] end end
    return prefix .. values[1][2]
  end
  local menu = CreateFrame("Frame", nil, parent)
  menu:SetSize(w, #values * 22 + 8)
  menu:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
  menu:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)  -- draw above the rows below
  skinPlate(menu); menu:Hide()
  for i, v in ipairs(values) do
    local item = flatButton(menu, w - 8, 20, COLOR.heroic, v[2], 12); item:SetBase(0.12)
    item:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22)
    item:SetScript("OnClick", function()
      menu:Hide(); openDropdownMenu = nil
      set(v[1]); b:SetText(label()); ReapplySelected()
    end)
  end
  b:SetScript("OnClick", function()
    if menu:IsShown() then menu:Hide(); openDropdownMenu = nil
    else
      if openDropdownMenu and openDropdownMenu ~= menu then openDropdownMenu:Hide() end
      menu:Show(); openDropdownMenu = menu
    end
  end)
  local row = {}
  function row:refresh() b:SetText(label()) end
  function row:setEnabled(on) b:SetEnabled(on); if not on then menu:Hide() end end
  return row
end

-- --------------------------------------------------------------------------
-- Left pane: the list of created displays.
-- --------------------------------------------------------------------------
local function RefreshList()
  listData = DisplayList()
  local n = #listData
  local maxOff = math.max(0, n - LIST_ROWS)
  if listOffset > maxOff then listOffset = maxOff end
  if listOffset < 0 then listOffset = 0 end
  for i = 1, LIST_ROWS do
    local row = listRows[i]
    if not row then break end
    local sid = listData[i + listOffset]
    if sid then
      local cfg = DB() and DB()[sid]
      row.spellID = sid   -- the display id (what SetSelected + the frame are keyed by)
      local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture((cfg and cfg.spellID) or sid)
      row.icon:SetTexture(icon or 134400)
      row.name:SetText((cfg and cfg.label) or ("Spell " .. sid))
      local dim = cfg and cfg.enabled == false
      row.name:SetTextColor(dim and 0.5 or TEXT.r, dim and 0.5 or TEXT.g, dim and 0.5 or TEXT.b)
      row.sel:SetShown(sid == selectedID)
      row:Show()
    else
      row.spellID = nil
      row:Hide()
    end
  end
end

-- --------------------------------------------------------------------------
-- Selection
-- --------------------------------------------------------------------------
local function SetSelected(sid)
  selectedID = sid
  if GA.Displays then GA.Displays:SetSelectedDisplay(sid) end  -- only this one is draggable
  local cfg = Cfg()
  if editorName then editorName:SetText(cfg and (cfg.label or tostring(sid)) or "|cff888888No aura selected — add one on the left|r") end
  if triggerSummary then triggerSummary:SetText(cfg and SummaryText(cfg) or "") end
  if visibilitySummary then visibilitySummary:SetText(cfg and VisibilitySummary(cfg) or "") end
  for _, r in ipairs(rows) do r:refresh(); r:setEnabled(cfg ~= nil) end
  RefreshList()
  if GA.Displays and cfg then local f = GA.Displays:GetOrCreate(sid); if f then f:Show() end end
end

-- --------------------------------------------------------------------------
-- Aura picker: a scrollable list of the CDM registry (icon + name); click to
-- add a display. Scrolls with the mouse wheel (no scrollbar thumb to drag).
-- --------------------------------------------------------------------------
local PICK_ROWS = 12
local PICK_TRACK_TOP, PICK_TRACK_H = -40, PICK_ROWS * 24
local pickerRows, pickerData, pickerOffset = {}, {}, 0
local pickerThumb

local function BuildAuraList()
  local list = {}
  local E = Enum and Enum.CooldownViewerCategory
  if not (E and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then return list end
  local cats = { { "Essential", E.Essential }, { "Utility", E.Utility }, { "Buff", E.TrackedBuff }, { "Bar", E.TrackedBar } }
  for _, c in ipairs(cats) do
    local ids = C_CooldownViewer.GetCooldownViewerCategorySet(c[2])
    if type(ids) == "table" then
      for _, id in ipairs(ids) do
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(id)
        local sid = info and info.spellID
        if sid and not issecret(sid) then
          local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)) or ("Spell " .. sid)
          local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
          list[#list + 1] = { spellID = sid, name = name, icon = icon, cat = c[1] }
        end
      end
    end
  end
  return list
end

local function RefreshPicker()
  local n = #pickerData
  local maxOff = math.max(0, n - PICK_ROWS)
  if pickerOffset > maxOff then pickerOffset = maxOff end
  if pickerOffset < 0 then pickerOffset = 0 end
  for i = 1, PICK_ROWS do
    local row, item = pickerRows[i], pickerData[i + pickerOffset]
    if item then
      row.spellID = item.spellID
      row.icon:SetTexture(item.icon or 134400)
      local have = DB() and DB()[item.spellID]
      row.text:SetText(("%s  |cff888888(%s)|r%s"):format(item.name, item.cat, have and "  |cff55ff55✓|r" or ""))
      row:Show()
    else
      row:Hide()
    end
  end
  if pickerThumb then
    if n <= PICK_ROWS then
      pickerThumb:Hide()
    else
      pickerThumb:Show()
      local thumbH = math.max(24, PICK_TRACK_H * (PICK_ROWS / n))
      pickerThumb:SetHeight(thumbH)
      local y = PICK_TRACK_TOP - (PICK_TRACK_H - thumbH) * (pickerOffset / maxOff)
      pickerThumb:ClearAllPoints()
      pickerThumb:SetPoint("TOPRIGHT", pickerFrame, "TOPRIGHT", -6, y)
    end
  end
end

local function BuildPicker()
  local W, H = 370, PICK_ROWS * 24 + 64
  local f = CreateFrame("Frame", "GloomsAurasPicker", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(true); f:EnableMouseWheel(true)
  skinPlate(f)

  local title = newText(f, FONT.title, 18, COLOR.purple, "CENTER")
  title:SetPoint("TOP", 0, -12); title:SetText("Choose an aura to track")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)

  -- Movable title bar (standard hold-drag).
  f:SetMovable(true); f:SetClampedToScreen(true)
  local ptb = CreateFrame("Frame", nil, f)
  ptb:SetPoint("TOPLEFT", 2, -2); ptb:SetPoint("TOPRIGHT", -34, -2); ptb:SetHeight(28)
  ptb:EnableMouse(true); ptb:RegisterForDrag("LeftButton")
  ptb:SetScript("OnDragStart", function() f:StartMoving() end)
  ptb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  for i = 1, PICK_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetSize(348, 22); row:SetPoint("TOPLEFT", 10, -40 - (i - 1) * 24)
    local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.20)
    local icon = row:CreateTexture(nil, "ARTWORK"); icon:SetSize(20, 20); icon:SetPoint("LEFT", 2, 0); row.icon = icon
    local text = newText(row, FONT.body, 12, TEXT, "LEFT"); text:SetPoint("LEFT", 28, 0); text:SetPoint("RIGHT", -4, 0); row.text = text
    row:SetScript("OnClick", function(self)
      if not self.spellID then return end
      if pickerOnPick then                 -- picking for a trigger condition
        local cb = pickerOnPick; pickerOnPick = nil
        f:Hide()
        cb(self.spellID)
        return
      end
      if DB() and not DB()[self.spellID] then
        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(self.spellID)
        DB()[self.spellID] = { spellID = self.spellID, label = name or ("Spell " .. self.spellID),
          enabled = true, width = 64, height = 64, point = { "CENTER", 0, 120 }, alpha = 1, showLabel = true }
      end
      if GA.CDM then GA.CDM:Discover() end
      RefreshPicker()      -- show the ✓
      SetSelected(self.spellID)
    end)
    pickerRows[i] = row
  end

  -- Visual scrollbar (position indicator; the mouse wheel does the scrolling).
  local track = f:CreateTexture(nil, "ARTWORK"); track:SetColorTexture(1, 1, 1, 0.08)
  track:SetPoint("TOPRIGHT", -6, PICK_TRACK_TOP); track:SetSize(6, PICK_TRACK_H)
  pickerThumb = f:CreateTexture(nil, "OVERLAY"); pickerThumb:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1); pickerThumb:SetWidth(6)

  local footer = newText(f, FONT.body, 11, MUTE, "CENTER")
  footer:SetPoint("BOTTOM", 0, 8); footer:SetText("mouse-wheel to scroll")

  f:SetScript("OnMouseWheel", function(_, delta) pickerOffset = pickerOffset - delta; RefreshPicker() end)
  f:SetScript("OnShow", function() pickerData = BuildAuraList(); pickerOffset = 0; RefreshPicker() end)
  tinsert(UISpecialFrames, "GloomsAurasPicker")
  f:Hide()  -- created hidden so the first OpenPicker transitions + fires OnShow
  pickerFrame = f; RegisterSubWindow(f)
  return f
end

local function OpenPicker(onPick)
  pickerOnPick = onPick  -- nil = default (add a display); set = return spellID to caller
  if not pickerFrame then
    local ok, err = pcall(BuildPicker)
    if not ok then GA.msg("|cffff5555aura picker failed to build|r: " .. tostring(err)); return end
  end
  -- Picked FROM the Trigger editor (onPick set) → keep it open underneath.
  CloseSubWindows(pickerFrame, onPick and triggerFrame or nil)
  pickerFrame:Show(); pickerFrame:Raise()
end

-- --------------------------------------------------------------------------
-- Texture picker: browse game icons + textures other addons registered into
-- LibSharedMedia (StoneTweaks' custom textures, etc.); click one to set the
-- selected display's art. Category via a dropdown; search filters by name where
-- names exist (LSM). Scrolls with the mouse wheel.
-- --------------------------------------------------------------------------
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local texPickerFrame, texPickerOnPick, texCatButton, texCatMenu, texSearchBox, texSearchLabel
local texCells, texData, texOffset, texCurrentCat, texCurrentTex = {}, {}, 0, nil, nil
local TEX_COLS, TEX_ROWS, TEX_CELL = 6, 5, 58
local TEX_PER = TEX_COLS * TEX_ROWS

-- Category providers: each returns an array of { tex = fileID|path, name = str }.
local function CatGameIcons()
  local out, raw = {}, {}
  if GetLooseMacroIcons then GetLooseMacroIcons(raw) end
  if GetMacroIcons then GetMacroIcons(raw) end
  if GetLooseMacroItemIcons then GetLooseMacroItemIcons(raw) end
  if GetMacroItemIcons then GetMacroItemIcons(raw) end
  for _, v in ipairs(raw) do
    local n = tonumber(v)
    if n then out[#out + 1] = { tex = n, name = "" }
    else out[#out + 1] = { tex = "Interface\\ICONS\\" .. v, name = tostring(v) } end
  end
  return out
end

local function CatLSM()
  local out = {}
  if LSM then
    for _, mt in ipairs({ "statusbar", "background", "border" }) do
      local tbl = LSM.HashTable and LSM:HashTable(mt)
      if tbl then for name, path in pairs(tbl) do out[#out + 1] = { tex = path, name = name } end end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
  end
  return out
end

-- StoneTweaks' custom Graphics + Textures are NOT in LibSharedMedia; they live as
-- files listed in StoneTweaksDB. Read that table and reference them by path.
local function CatStoneTweaks()
  local out = {}
  local db = _G.StoneTweaksDB
  if type(db) == "table" then
    if type(db.graphics) == "table" then
      for _, g in ipairs(db.graphics) do
        if g.file then out[#out + 1] = { tex = "Interface\\AddOns\\StoneTweaks\\Graphics\\" .. g.file, name = g.name or g.file } end
      end
    end
    if type(db.textures) == "table" then
      for _, t in ipairs(db.textures) do
        if t.file then out[#out + 1] = { tex = "Interface\\AddOns\\StoneTweaks\\Textures\\" .. t.file, name = t.name or t.file } end
      end
    end
  end
  return out
end

-- Category order: bundled aura shapes first (Shapes, PowerAuras, Beams…), then
-- game icons, your StoneTweaks graphics, and LSM bar textures.
local TEX_CATS = {}
if GA.TextureShapes then
  for _, group in ipairs(GA.TextureShapes) do
    local items = group.items
    TEX_CATS[#TEX_CATS + 1] = { key = "shape:" .. group.cat, label = group.cat,
      searchable = true, cache = true, provider = function() return items end }
  end
end
-- Game icons come from the client as fileIDs with NO names, so a name search can't
-- work. Instead the search box becomes a "Spell ID" lookup: type a spell ID to show
-- that spell's icon. Empty box = browse the full grid.
TEX_CATS[#TEX_CATS + 1] = { key = "icons",       label = "Game Icons",           provider = CatGameIcons,   searchMode = "spellid", cache = true }
TEX_CATS[#TEX_CATS + 1] = { key = "stonetweaks", label = "StoneTweaks Graphics",  provider = CatStoneTweaks, searchable = true }
TEX_CATS[#TEX_CATS + 1] = { key = "lsm",         label = "Shared Media (bars)",   provider = CatLSM,         searchable = true }

local DEFAULT_TEX_CAT = TEX_CATS[1] and TEX_CATS[1].key or "icons"

local function TexCat(key)
  for _, c in ipairs(TEX_CATS) do if c.key == key then return c end end
  return TEX_CATS[1]
end

local function catItems(cat)
  if cat.cache then
    if not cat._cache then cat._cache = cat.provider() or {} end
    return cat._cache
  end
  return cat.provider() or {}
end

local function RefreshTexGrid()
  local n = #texData
  local maxOff = math.max(0, n - TEX_PER)
  if texOffset > maxOff then texOffset = maxOff end
  if texOffset < 0 then texOffset = 0 end
  local cur = texCurrentTex and tostring(texCurrentTex)
  for i = 1, TEX_PER do
    local cell, item = texCells[i], texData[i + texOffset]
    if item then
      cell.item = item
      cell.tex:SetTexture(item.tex)
      cell.sel:SetShown(cur ~= nil and tostring(item.tex) == cur)
      cell:Show()
    else
      cell.item = nil; cell:Hide()
    end
  end
end

local function RebuildTexData()
  local cat = TexCat(texCurrentCat)
  local all = catItems(cat)
  local q = texSearchBox and texSearchBox:GetText()
  q = (q and q ~= "") and q or nil
  if cat.searchMode == "spellid" then
    -- Type a spell ID → show that spell's icon; empty = browse all game icons.
    if q then
      local id = tonumber(q)
      local tx = id and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)
      texData = tx and { { tex = tx, name = "" } } or {}
    else
      texData = all
    end
  elseif cat.searchable and q then
    local ql = q:lower()
    texData = {}
    for _, it in ipairs(all) do
      if it.name and it.name:lower():find(ql, 1, true) then texData[#texData + 1] = it end
    end
  else
    texData = all
  end
  texOffset = 0
  RefreshTexGrid()
end

local function SetTexCat(key)
  texCurrentCat = key
  local cat = TexCat(key)
  if texCatButton then texCatButton:SetText(cat.label) end
  if texSearchBox then texSearchBox:SetText("") end
  if texSearchLabel then texSearchLabel:SetText(cat.searchMode == "spellid" and "Spell ID" or "Search") end
  RebuildTexData()
end

local function BuildTexturePicker()
  local GX = 26
  local W = GX * 2 + TEX_COLS * TEX_CELL
  local H = 96 + TEX_ROWS * TEX_CELL + 20
  local f = CreateFrame("Frame", "GloomsAurasTexPicker", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(true); f:EnableMouseWheel(true)
  skinPlate(f)

  local title = newText(f, FONT.title, 18, COLOR.purple, "CENTER"); title:SetPoint("TOP", 0, -12)
  title:SetText("Choose a texture")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)

  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2)
  tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() f:StartMoving() end)
  tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  -- Category dropdown (button + drop-down menu).
  texCatButton = flatButton(f, 168, 20, COLOR.heroic, "Shapes", 12)
  texCatButton:SetPoint("TOPLEFT", GX, -40)
  texCatMenu = CreateFrame("Frame", nil, f); texCatMenu:SetFrameStrata("FULLSCREEN_DIALOG")
  texCatMenu:SetSize(200, #TEX_CATS * 22 + 8)
  texCatMenu:SetPoint("TOPLEFT", texCatButton, "BOTTOMLEFT", 0, -2)
  texCatMenu:SetFrameLevel((f:GetFrameLevel() or 1) + 20)  -- render above the grid cells
  skinPlate(texCatMenu); texCatMenu:Hide()
  for i, cat in ipairs(TEX_CATS) do
    local item = flatButton(texCatMenu, 192, 20, COLOR.heroic, cat.label, 12); item:SetBase(0.12)
    item:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22)
    item:SetScript("OnClick", function() texCatMenu:Hide(); SetTexCat(cat.key) end)
  end
  texCatButton:SetScript("OnClick", function() texCatMenu:SetShown(not texCatMenu:IsShown()) end)

  -- Search box (filters the current category by name, where names exist).
  texSearchBox = flatEditBox(f, 110, 20)
  texSearchBox:SetPoint("TOPRIGHT", -20, -40)
  texSearchBox:SetScript("OnTextChanged", function() RebuildTexData() end)
  texSearchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local sl = newText(f, FONT.body, 11, MUTE, "RIGHT"); sl:SetPoint("RIGHT", texSearchBox, "LEFT", -8, 0)
  sl:SetText("Search")

  -- Grid of texture cells.
  for i = 1, TEX_PER do
    local col, rown = (i - 1) % TEX_COLS, math.floor((i - 1) / TEX_COLS)
    local cell = CreateFrame("Button", nil, f)
    cell:SetSize(TEX_CELL - 6, TEX_CELL - 6)
    cell:SetPoint("TOPLEFT", GX + col * TEX_CELL, -70 - rown * TEX_CELL)
    local sel = cell:CreateTexture(nil, "BACKGROUND")
    sel:SetPoint("TOPLEFT", -2, 2); sel:SetPoint("BOTTOMRIGHT", 2, -2)
    sel:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1); sel:Hide(); cell.sel = sel
    local t = cell:CreateTexture(nil, "ARTWORK"); t:SetAllPoints(); cell.tex = t
    local hl = cell:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.25)
    cell:SetScript("OnClick", function(self)
      if not self.item then return end
      texCurrentTex = self.item.tex
      if texPickerOnPick then texPickerOnPick(self.item.tex) end
      RefreshTexGrid()
    end)
    cell:SetScript("OnEnter", function(self)
      if self.item and self.item.name and self.item.name ~= "" then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.item.name); GameTooltip:Show()
      end
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    texCells[i] = cell
  end

  local footer = newText(f, FONT.body, 11, MUTE, "CENTER")
  footer:SetPoint("BOTTOM", 0, 8); footer:SetText("mouse-wheel to scroll · click to apply")

  f:SetScript("OnMouseWheel", function(_, d) texOffset = texOffset - d * TEX_COLS; RefreshTexGrid() end)
  tinsert(UISpecialFrames, "GloomsAurasTexPicker")
  f:Hide()
  texPickerFrame = f; RegisterSubWindow(f)
  return f
end

local function OpenTexturePicker(onPick, current)
  texPickerOnPick = onPick
  texCurrentTex = current
  if not texPickerFrame then
    local ok, err = pcall(BuildTexturePicker)
    if not ok then GA.msg("|cffff5555texture picker failed to build|r: " .. tostring(err)); return end
  end
  if texCatMenu then texCatMenu:Hide() end
  SetTexCat(texCurrentCat or DEFAULT_TEX_CAT)
  CloseSubWindows(texPickerFrame)
  texPickerFrame:Show(); texPickerFrame:Raise()
end

-- --------------------------------------------------------------------------
-- Sound picker: browse sounds registered into LibSharedMedia (BigWigs packs,
-- etc.) plus "None". Click to apply + preview. Stored per display as
-- cfg.sound = { file, name, channel }; CDM:PlaySound fires it on hidden→shown.
-- --------------------------------------------------------------------------
local SND_ROWS = 12
local soundPickerFrame, soundPickerOnPick, soundSearchBox
local soundRows, soundData, soundAll, soundOffset, soundCurrent = {}, {}, nil, 0, nil

local function BuildSoundList()
  local out = { { name = "None", file = nil } }
  if LSM and LSM.HashTable then
    local t = LSM:HashTable("sound")
    if t then
      local names = {}
      for name in pairs(t) do names[#names + 1] = name end
      table.sort(names, function(a, b) return a:lower() < b:lower() end)
      for _, name in ipairs(names) do out[#out + 1] = { name = name, file = t[name] } end
    end
  end
  return out
end

local function RefreshSoundList()
  local n = #soundData
  local maxOff = math.max(0, n - SND_ROWS)
  if soundOffset > maxOff then soundOffset = maxOff end
  if soundOffset < 0 then soundOffset = 0 end
  for i = 1, SND_ROWS do
    local row, item = soundRows[i], soundData[i + soundOffset]
    if item then
      row.item = item
      row.name:SetText(item.name)
      local isCur = (item.file == nil and soundCurrent == nil)
                 or (item.file ~= nil and tostring(item.file) == tostring(soundCurrent))
      row.sel:SetShown(isCur)
      row:Show()
    else
      row.item = nil; row:Hide()
    end
  end
  -- Reposition the scrollbar thumb.
  local sb = soundPickerFrame and soundPickerFrame.sb
  if sb then
    if n <= SND_ROWS then
      sb.thumb:Hide()
    else
      sb.thumb:Show()
      local thumbH = math.max(20, sb.h * SND_ROWS / n)
      sb.thumb:SetHeight(thumbH)
      local frac = maxOff > 0 and (soundOffset / maxOff) or 0
      sb.thumb:ClearAllPoints()
      sb.thumb:SetPoint("TOPRIGHT", soundPickerFrame, "TOPRIGHT", sb.x, sb.top - (sb.h - thumbH) * frac)
    end
  end
end

local function RebuildSoundData()
  if not soundAll then soundAll = BuildSoundList() end
  local q = soundSearchBox and soundSearchBox:GetText()
  q = (q and q ~= "") and q:lower() or nil
  if q then
    soundData = {}
    for _, it in ipairs(soundAll) do if it.name:lower():find(q, 1, true) then soundData[#soundData + 1] = it end end
  else
    soundData = soundAll
  end
  soundOffset = 0
  RefreshSoundList()
end

local function BuildSoundPicker()
  local W, H = 320, 68 + SND_ROWS * 24 + 30
  local f = CreateFrame("Frame", "GloomsAurasSoundPicker", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(true); f:EnableMouseWheel(true)
  skinPlate(f)

  local title = newText(f, FONT.title, 18, COLOR.purple, "CENTER"); title:SetPoint("TOP", 0, -12)
  title:SetText("Choose a sound")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)

  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2)
  tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() f:StartMoving() end)
  tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  soundSearchBox = flatEditBox(f, 150, 20); soundSearchBox:SetPoint("TOPRIGHT", -14, -38)
  soundSearchBox:SetScript("OnTextChanged", function() RebuildSoundData() end)
  soundSearchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local sl = newText(f, FONT.body, 11, MUTE, "LEFT"); sl:SetPoint("TOPLEFT", 14, -42); sl:SetText("Search")

  for i = 1, SND_ROWS do
    local row = CreateFrame("Button", nil, f); row:SetSize(W - 28, 22)
    row:SetPoint("TOPLEFT", 14, -66 - (i - 1) * 24)
    local sel = row:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints()
    sel:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.28); sel:Hide(); row.sel = sel
    local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.10)
    local name = newText(row, FONT.body, 12, TEXT, "LEFT"); name:SetPoint("LEFT", 8, 0); name:SetPoint("RIGHT", -8, 0); row.name = name
    row:SetScript("OnClick", function(self)
      if not self.item then return end
      soundCurrent = self.item.file
      if soundPickerOnPick then soundPickerOnPick(self.item) end
      if self.item.file then pcall(PlaySoundFile, self.item.file, "Master") end
      RefreshSoundList()
    end)
    soundRows[i] = row
  end

  -- Scrollbar: a draggable purple thumb on the right (the wheel also scrolls).
  local SB_X, SB_TOP, SB_H = -6, -66, SND_ROWS * 24 - 2
  local track = f:CreateTexture(nil, "ARTWORK"); track:SetColorTexture(1, 1, 1, 0.06)
  track:SetPoint("TOPRIGHT", SB_X, SB_TOP); track:SetSize(6, SB_H)
  local thumb = CreateFrame("Button", nil, f); thumb:SetWidth(6); thumb:EnableMouse(true)
  local tt = thumb:CreateTexture(nil, "OVERLAY"); tt:SetAllPoints()
  tt:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1)
  thumb:SetPoint("TOPRIGHT", SB_X, SB_TOP)
  f.sb = { thumb = thumb, top = SB_TOP, h = SB_H, x = SB_X }

  local dragging, startCursorY, startOffset = false, 0, 0
  thumb:SetScript("OnMouseDown", function()
    dragging = true; startOffset = soundOffset
    local _, cy = GetCursorPosition(); startCursorY = cy / f:GetEffectiveScale()
  end)
  thumb:SetScript("OnMouseUp", function() dragging = false end)
  thumb:SetScript("OnUpdate", function()
    if not dragging then return end
    local n = #soundData; local maxOff = math.max(0, n - SND_ROWS)
    local range = SB_H - thumb:GetHeight()
    if maxOff <= 0 or range <= 0 then return end
    local _, cyRaw = GetCursorPosition()
    local movedDown = startCursorY - (cyRaw / f:GetEffectiveScale())  -- cursor down = scroll down
    soundOffset = math.max(0, math.min(maxOff, math.floor(startOffset + (movedDown / range) * maxOff + 0.5)))
    RefreshSoundList()
  end)

  local footer = newText(f, FONT.body, 11, MUTE, "CENTER"); footer:SetPoint("BOTTOM", 0, 8)
  footer:SetText("click to apply + preview · drag the bar or use the wheel")
  f:SetScript("OnMouseWheel", function(_, d) soundOffset = soundOffset - d; RefreshSoundList() end)
  tinsert(UISpecialFrames, "GloomsAurasSoundPicker")
  f:Hide()
  soundPickerFrame = f; RegisterSubWindow(f)
  return f
end

local function OpenSoundPicker(onPick, current)
  soundPickerOnPick = onPick
  soundCurrent = current
  soundAll = nil  -- re-read the LSM sound list each open
  if not soundPickerFrame then
    local ok, err = pcall(BuildSoundPicker)
    if not ok then GA.msg("|cffff5555sound picker failed to build|r: " .. tostring(err)); return end
  end
  if soundSearchBox then soundSearchBox:SetText("") end
  RebuildSoundData()
  CloseSubWindows(soundPickerFrame)
  soundPickerFrame:Show(); soundPickerFrame:Raise()
end

-- --------------------------------------------------------------------------
-- Trigger editor: define the conditions under which a display shows.
-- --------------------------------------------------------------------------
local function TE_Cfg()
  return triggerEditID and DB() and DB()[triggerEditID]
end

local function RefreshTrigger()
  if not triggerFrame then return end
  local cfg = TE_Cfg(); if not cfg then return end
  cfg.trigger = cfg.trigger or { logic = "AND", conditions = {} }
  local t = cfg.trigger
  triggerTitle:SetText("Trigger: " .. (cfg.label or tostring(triggerEditID)))
  triggerLogicBtn:SetText(t.logic == "OR" and "Match Any (OR)" or "Match All (AND)")
  for i, row in ipairs(triggerRows) do
    local c = t.conditions[i]
    if c then
      local icon = c.spellID and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(c.spellID)
      row.icon:SetTexture(icon or 134400)
      row.name:SetText(c.name or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(c.spellID)) or tostring(c.spellID))
      row.state:SetText(STATE_LABEL[c.state] or "?")
      row:Show()
    else
      row:Hide()
    end
  end
  if triggerSummary and triggerEditID == selectedID then triggerSummary:SetText(SummaryText(cfg)) end
end

local function TE_Rebind()  -- watch-set changed → rebind, then re-render
  if GA.CDM then GA.CDM:Discover() end
  RefreshTrigger()
end

local function AddCondition(spellID)
  local cfg = TE_Cfg(); if not cfg then return end
  cfg.trigger = cfg.trigger or { logic = "AND", conditions = {} }
  if #cfg.trigger.conditions >= #triggerRows then GA.msg("condition limit reached."); return end
  local kind = GA.CDM and GA.CDM.kind and GA.CDM.kind[spellID]
  local state = (kind == "cooldown") and "cd_ready" or "buff_active"
  local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
  table.insert(cfg.trigger.conditions, { spellID = spellID, state = state, name = name })
  TE_Rebind()
end

local function BuildTriggerEditor()
  local ROWS = 8
  local W, H = 380, 118 + ROWS * 26
  local f = CreateFrame("Frame", "GloomsAurasTrigger", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)

  triggerTitle = newText(f, FONT.title, 18, COLOR.purple, "CENTER"); triggerTitle:SetPoint("TOP", 0, -12); triggerTitle:SetText("Trigger")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12); close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)

  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2); tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() f:StartMoving() end); tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  triggerLogicBtn = flatButton(f, 150, 22, COLOR.purple, "Match All (AND)", 12)
  triggerLogicBtn:SetPoint("TOPLEFT", 16, -40)
  triggerLogicBtn:SetScript("OnClick", function()
    local cfg = TE_Cfg(); if not cfg or not cfg.trigger then return end
    cfg.trigger.logic = (cfg.trigger.logic == "OR") and "AND" or "OR"
    if GA.CDM then GA.CDM:RefreshDisplays() end
    RefreshTrigger()
  end)
  local lh = newText(f, FONT.body, 11, MUTE, "LEFT"); lh:SetPoint("LEFT", triggerLogicBtn, "RIGHT", 8, 0); lh:SetText("how the conditions below combine")

  for i = 1, ROWS do
    local row = CreateFrame("Frame", nil, f); row:SetSize(348, 24); row:SetPoint("TOPLEFT", 16, -70 - (i - 1) * 26)
    local icon = row:CreateTexture(nil, "ARTWORK"); icon:SetSize(20, 20); icon:SetPoint("LEFT", 0, 0); row.icon = icon
    local name = newText(row, FONT.body, 12, TEXT, "LEFT"); name:SetPoint("LEFT", 26, 0); name:SetWidth(118); row.name = name
    local state = flatButton(row, 148, 20, COLOR.heroic, "", 11); state:SetPoint("LEFT", 148, 0); row.state = state
    state:SetScript("OnClick", function()
      local cfg = TE_Cfg(); if not cfg or not cfg.trigger then return end
      local c = cfg.trigger.conditions[i]; if not c then return end
      local idx = 1; for j, s in ipairs(STATE_ORDER) do if s == c.state then idx = j break end end
      c.state = STATE_ORDER[(idx % #STATE_ORDER) + 1]
      if GA.CDM then GA.CDM:RefreshDisplays() end
      RefreshTrigger()
    end)
    local rem = flatButton(row, 22, 20, COLOR.orange, "X", 12); rem:SetPoint("RIGHT", 0, 0)
    rem:SetScript("OnClick", function()
      local cfg = TE_Cfg(); if not cfg or not cfg.trigger then return end
      table.remove(cfg.trigger.conditions, i)
      TE_Rebind()
    end)
    row:Hide()
    triggerRows[i] = row
  end

  local add = flatButton(f, 150, 24, COLOR.purple, "+ Add Condition", 12)
  add:SetPoint("BOTTOMLEFT", 16, 16)
  add:SetScript("OnClick", function() OpenPicker(function(sid) AddCondition(sid) end) end)
  local ah = newText(f, FONT.body, 11, MUTE, "CENTER"); ah:SetPoint("BOTTOM", 0, 20); ah:SetText("no conditions = the aura shows on its own state · click a state to change it")

  f:SetScript("OnShow", RefreshTrigger)
  tinsert(UISpecialFrames, "GloomsAurasTrigger")
  f:Hide()
  triggerFrame = f; RegisterSubWindow(f)
  return f
end

local function OpenTriggerEditor(spellID)
  if not spellID then return end
  triggerEditID = spellID
  if not triggerFrame then
    local ok, err = pcall(BuildTriggerEditor)
    if not ok then GA.msg("|cffff5555trigger editor failed to build|r: " .. tostring(err)); return end
  end
  RefreshTrigger()
  CloseSubWindows(triggerFrame)
  triggerFrame:Show(); triggerFrame:Raise()
end

-- --------------------------------------------------------------------------
-- Visibility editor: player/game-state conditions that gate the display (they
-- AND with the Trigger). "Show only when ALL of these are true."
-- --------------------------------------------------------------------------
local visFrame, visEditID, visTitle
local veRows = {}

local function VE_Cfg() return visEditID and DB() and DB()[visEditID] end
local function VE_Vis() local c = VE_Cfg(); if not c then return nil end; c.visibility = c.visibility or {}; return c.visibility end

local function VE_Changed()
  if GA.CDM then GA.CDM:UpdateVisibilityPoll(); GA.CDM:RefreshDisplays() end
  if visibilitySummary and visEditID == selectedID then visibilitySummary:SetText(VisibilitySummary(VE_Cfg())) end
end

local function PlayerSpecs()
  local out = {}
  local n = (GetNumSpecializations and GetNumSpecializations()) or 0
  for i = 1, n do
    local id, name, _, icon = GetSpecializationInfo(i)
    if id then out[#out + 1] = { id = id, name = name, icon = icon } end
  end
  return out
end

-- 3-way cycle (Any / A / B), stored as nil / valA / valB.
local function veCycle(parent, x, y, w, label, states, key)
  local b = flatButton(parent, w, 22, COLOR.heroic, "", 12); b:SetPoint("TOPLEFT", x, y)
  local function cur() local v = VE_Vis(); return (v and v[key]) or "any" end
  local function txt()
    local c = cur()
    for _, s in ipairs(states) do if s[1] == c then return label .. ": " .. s[2] end end
    return label .. ": " .. states[1][2]
  end
  b:SetScript("OnClick", function()
    local v = VE_Vis(); if not v then return end
    local c, idx = cur(), 1
    for i, s in ipairs(states) do if s[1] == c then idx = i break end end
    local nv = states[(idx % #states) + 1][1]
    v[key] = (nv ~= "any") and nv or nil
    b:SetText(txt()); VE_Changed()
  end)
  veRows[#veRows + 1] = { refresh = function() b:SetText(txt()) end }
end

-- On/off toggle (require this state to be true).
local function veToggle(parent, x, y, key, label)
  local c = flatCheck(parent, label); c:SetPoint("TOPLEFT", x, y)
  c:SetScript("OnClick", function()
    local v = VE_Vis(); if not v then return end
    c:Set(not c:Get()); v[key] = c:Get() or nil; VE_Changed()
  end)
  veRows[#veRows + 1] = { refresh = function() local v = VE_Vis(); c:Set(v and v[key]) end }
end

local function BuildVisibilityEditor()
  local W, H = 420, 428
  local f = CreateFrame("Frame", "GloomsAurasVisibility", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)
  visTitle = newText(f, FONT.title, 18, COLOR.purple, "CENTER"); visTitle:SetPoint("TOP", 0, -12); visTitle:SetText("Visibility")
  local sub = newText(f, FONT.body, 11, MUTE, "CENTER"); sub:SetPoint("TOP", 0, -34); sub:SetText("show only when ALL of these are true")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12); close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)
  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2); tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() f:StartMoving() end); tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  veCycle(f, 16, -56, 185, "Combat", { { "any", "Any" }, { "in", "In Combat" }, { "out", "Out of Combat" } }, "combat")
  veCycle(f, 219, -56, 185, "Target", { { "any", "Any" }, { "has", "Has Target" }, { "none", "No Target" } }, "target")

  local L, R, y0, dy = 20, 220, -90, 26
  veToggle(f, L, y0,        "casting",   "While casting")
  veToggle(f, L, y0 - dy,   "mounted",   "Mounted")
  veToggle(f, L, y0 - dy*2, "vehicle",   "In vehicle")
  veToggle(f, L, y0 - dy*3, "instance",  "In instance")
  veToggle(f, L, y0 - dy*4, "encounter", "In boss encounter")
  veToggle(f, L, y0 - dy*5, "resting",   "Resting")
  veToggle(f, R, y0,        "stealthed", "Stealthed")
  veToggle(f, R, y0 - dy,   "group",     "In a group")
  veToggle(f, R, y0 - dy*2, "raid",      "In a raid")
  veToggle(f, R, y0 - dy*3, "warmode",   "War Mode")
  veToggle(f, R, y0 - dy*4, "alive",     "Alive (not dead)")

  local specHdr = newText(f, FONT.head, 13, COLOR.purple, "LEFT"); specHdr:SetPoint("TOPLEFT", 12, -252); specHdr:SetText("SPECIALIZATION")
  local specHint = newText(f, FONT.body, 11, MUTE, "LEFT"); specHint:SetPoint("LEFT", specHdr, "RIGHT", 8, 0); specHint:SetText("(none = all specs)")
  for i, sp in ipairs(PlayerSpecs()) do
    local c = flatCheck(f, sp.name); c:SetPoint("TOPLEFT", 20 + (i - 1) * 130, -276)
    c:SetScript("OnClick", function()
      local v = VE_Vis(); if not v then return end
      v.specs = v.specs or {}
      c:Set(not c:Get())
      v.specs[sp.id] = c:Get() or nil
      if not next(v.specs) then v.specs = nil end
      VE_Changed()
    end)
    veRows[#veRows + 1] = { refresh = function() local v = VE_Vis(); c:Set(v and v.specs and v.specs[sp.id]) end }
  end

  local skHdr = newText(f, FONT.head, 13, COLOR.purple, "LEFT"); skHdr:SetPoint("TOPLEFT", 12, -312); skHdr:SetText("SPELL / TALENT KNOWN")
  local skBox = flatEditBox(f, 80, 20); skBox:SetPoint("TOPLEFT", 20, -334); skBox:SetNumeric(true)
  local skName = newText(f, FONT.body, 12, TEXT, "LEFT"); skName:SetPoint("LEFT", skBox, "RIGHT", 8, 0); skName:SetWidth(290)
  local function skRefreshName()
    local v = VE_Vis(); local id = v and v.spellKnown
    if id then
      local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
      skName:SetText(nm and ("|cffffffff" .. nm .. "|r — shows only if known") or ("spell " .. id))
    else
      skName:SetText("|cff888888enter a spell ID (talents count as known spells)|r")
    end
  end
  skBox:SetScript("OnEnterPressed", function(self)
    local v = VE_Vis(); if not v then return end
    v.spellKnown = tonumber(self:GetText()); skRefreshName(); self:ClearFocus(); VE_Changed()
  end)
  skBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  veRows[#veRows + 1] = { refresh = function()
    local v = VE_Vis(); skBox:SetText(v and v.spellKnown and tostring(v.spellKnown) or ""); skRefreshName()
  end }

  local footer = newText(f, FONT.body, 11, MUTE, "CENTER"); footer:SetPoint("BOTTOM", 0, 10)
  footer:SetText("these AND with the display's Trigger")
  f:SetScript("OnHide", function()
    if visibilitySummary and visEditID == selectedID then visibilitySummary:SetText(VisibilitySummary(VE_Cfg())) end
  end)
  tinsert(UISpecialFrames, "GloomsAurasVisibility")
  f:Hide()
  visFrame = f; RegisterSubWindow(f)
  return f
end

local function OpenVisibilityEditor(spellID)
  if not spellID then return end
  visEditID = spellID
  if not visFrame then
    local ok, err = pcall(BuildVisibilityEditor)
    if not ok then GA.msg("|cffff5555visibility editor failed to build|r: " .. tostring(err)); return end
  end
  local c = VE_Cfg(); if c then c.visibility = c.visibility or {} end
  if visTitle then visTitle:SetText("Visibility: " .. ((c and c.label) or tostring(spellID))) end
  for _, r in ipairs(veRows) do r:refresh() end
  CloseSubWindows(visFrame)
  visFrame:Show(); visFrame:Raise()
end

-- --------------------------------------------------------------------------
-- Build the main panel (two-pane: aura list | settings editor).
-- --------------------------------------------------------------------------
local PANEL_W, PANEL_H = 580, 628
local INSET, TITLEBAR_H = 14, 32
local CONTENT_TOP = -(TITLEBAR_H + 8)   -- -40
local LIST_W = 160
local EDITOR_X = INSET + LIST_W + 16     -- 190
local EDITOR_W = PANEL_W - EDITOR_X - INSET  -- 376
local PANE_H = 524

local function Build()
  local p = CreateFrame("Frame", "GloomsAurasConfig", UIParent)
  p:SetSize(PANEL_W, PANEL_H); p:SetPoint("CENTER"); p:SetFrameStrata("DIALOG"); p:EnableMouse(true)
  skinPlate(p)

  local title = newText(p, FONT.title, 20, COLOR.purple, "LEFT")
  title:SetPoint("TOPLEFT", INSET, -8); title:SetText("Gloom's Auras")

  local close = flatButton(p, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() p:Hide() end)

  -- Movable title bar (grab the title strip, drag, release).
  p:SetMovable(true); p:SetClampedToScreen(true)
  local titlebar = CreateFrame("Frame", nil, p)
  titlebar:SetPoint("TOPLEFT", 2, -2); titlebar:SetPoint("TOPRIGHT", -34, -2); titlebar:SetHeight(TITLEBAR_H - 4)
  titlebar:EnableMouse(true); titlebar:RegisterForDrag("LeftButton")
  local tbbg = titlebar:CreateTexture(nil, "BACKGROUND"); tbbg:SetAllPoints(); tbbg:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.14)
  titlebar:SetScript("OnDragStart", function() p:StartMoving() end)
  titlebar:SetScript("OnDragStop", function() p:StopMovingOrSizing(); C:SavePanelPos() end)

  -- Vertical divider between the list and the editor.
  local divider = p:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(COLOR.rim.r, COLOR.rim.g, COLOR.rim.b, COLOR.rim.a)
  divider:SetPoint("TOPLEFT", INSET + LIST_W + 7, CONTENT_TOP + 2)
  divider:SetPoint("BOTTOMLEFT", INSET + LIST_W + 7, PANEL_H - PANE_H - (TITLEBAR_H + 8) + 2)
  divider:SetWidth(1)

  -- ---- LEFT PANE: the aura list ----
  listFrame = CreateFrame("Frame", nil, p)
  listFrame:SetPoint("TOPLEFT", INSET, CONTENT_TOP); listFrame:SetSize(LIST_W, PANE_H)
  listFrame:EnableMouse(true); listFrame:EnableMouseWheel(true)
  listFrame:SetScript("OnMouseWheel", function(_, delta) listOffset = listOffset - delta; RefreshList() end)

  local listHead = newText(listFrame, FONT.head, 12, COLOR.purple, "LEFT")
  listHead:SetPoint("TOPLEFT", 2, -2); listHead:SetText("YOUR AURAS")

  for i = 1, LIST_ROWS do
    local row = CreateFrame("Button", nil, listFrame)
    row:SetSize(LIST_W, LIST_ROW_H); row:SetPoint("TOPLEFT", 0, -24 - (i - 1) * LIST_ROW_H)
    local sel = row:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints(); sel:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.28); sel:Hide(); row.sel = sel
    local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
    local icon = row:CreateTexture(nil, "ARTWORK"); icon:SetSize(18, 18); icon:SetPoint("LEFT", 2, 0); icon:SetTexCoord(0.08, 0.92, 0.08, 0.92); row.icon = icon
    local name = newText(row, FONT.body, 12, TEXT, "LEFT"); name:SetPoint("LEFT", 26, 0); name:SetPoint("RIGHT", -4, 0); row.name = name
    row:SetScript("OnClick", function(self) if self.spellID then SetSelected(self.spellID) end end)
    listRows[i] = row
  end

  -- Button stack at the bottom of the left pane: Add / Duplicate / Remove.
  local addBtn = flatButton(listFrame, LIST_W, 26, COLOR.purple, "+ Add Aura", 13)
  addBtn:SetPoint("BOTTOMLEFT", 0, 56)
  addBtn:SetScript("OnClick", function() OpenPicker() end)

  -- Duplicate: an exact copy of the selected aura (same tracked spell), nudged so
  -- it doesn't sit exactly on top of the original. New display gets a unique id.
  local dupBtn = flatButton(listFrame, LIST_W, 26, COLOR.heroic, "Duplicate Aura", 13)
  dupBtn:SetPoint("BOTTOMLEFT", 0, 28)
  dupBtn:SetScript("OnClick", function()
    if not (selectedID and DB() and DB()[selectedID]) then return end
    local copy = DeepCopy(DB()[selectedID])
    copy.label = (copy.label or "Aura") .. " (copy)"
    local p = copy.point or { "CENTER", 0, 0 }
    copy.point = { "CENTER", (p[2] or 0) + 24, (p[3] or 0) - 24 }
    local id = NewDisplayID()
    DB()[id] = copy
    if GA.CDM then GA.CDM:Discover() end
    SetSelected(id)
  end)

  local removeBtn = flatButton(listFrame, LIST_W, 26, COLOR.orange, "Remove Aura", 13)
  removeBtn:SetPoint("BOTTOMLEFT", 0, 0)
  removeBtn:SetScript("OnClick", function()
    if selectedID and DB() then
      local gone = selectedID
      DB()[gone] = nil
      if GA.Displays and GA.Displays.frames[gone] then GA.Displays.frames[gone]:Hide() end
      if GA.CDM then GA.CDM:Discover() end
      SetSelected(DisplayList()[1])
    end
  end)

  -- ---- RIGHT PANE: the settings editor ----
  local editor = CreateFrame("Frame", nil, p)
  editor:SetPoint("TOPLEFT", EDITOR_X, CONTENT_TOP); editor:SetSize(EDITOR_W, PANE_H)

  editorName = newText(editor, FONT.title, 17, TEXT, "LEFT")
  editorName:SetPoint("TOPLEFT", 12, -2); editorName:SetPoint("RIGHT", -8, 0); editorName:SetHeight(22)

  Header(editor, 12, -30, "Texture")
  -- Path field is narrowed so the "Choose…" button sits inline to its right (same
  -- row, matching height). No preview swatch — the aura itself is visible in-game.
  rows[#rows + 1] = MakeText(editor, -52, "Texture",
    function() local c = Cfg(); return c and c.texture end,
    function(v) local c = Cfg(); if c then c.texture = v end end, 248)

  local chooseBtn = flatButton(editor, 82, 20, COLOR.heroic, "Choose…", 12)
  chooseBtn:SetPoint("TOPLEFT", 276, -70)   -- inline with the path field (its row = yOff-18)
  chooseBtn:SetScript("OnClick", function()
    local c = Cfg(); if not c then return end
    OpenTexturePicker(function(tex)
      c.texture = tex
      ReapplySelected()
      C:RefreshCurrent()   -- refresh the path box
    end, c.texture)
  end)
  rows[#rows + 1] = { refresh = function() end, setEnabled = function(_, on) chooseBtn:SetEnabled(on) end }

  -- Tint + Desaturate row.
  rows[#rows + 1] = MakeColor(editor, 16, -96,
    function() local c = Cfg(); return c and c.color end,
    function(v) local c = Cfg(); if c then c.color = v end end)
  local desat = flatCheck(editor, "Desaturate"); desat:SetPoint("TOPLEFT", 190, -96)
  desat:SetScript("OnClick", function()
    local c = Cfg(); if not c then return end
    desat:Set(not desat:Get()); c.desaturate = desat:Get() or nil; ReapplySelected()
  end)
  rows[#rows + 1] = { refresh = function() local c = Cfg(); desat:Set(c and c.desaturate) end,
                      setEnabled = function(_, on) desat:SetEnabled(on) end }

  -- Blend mode + Frame strata row (dropdown menus).
  rows[#rows + 1] = MakeDropdown(editor, 16, -122, 150, "Blend: ", BLEND_MODES,
    function() local c = Cfg(); return (c and c.blend) or "BLEND" end,
    function(v) local c = Cfg(); if c then c.blend = (v ~= "BLEND") and v or nil end end)
  rows[#rows + 1] = MakeDropdown(editor, 190, -122, 150, "Strata: ", STRATA_MODES,
    function() local c = Cfg(); return (c and c.strata) or "HIGH" end,
    function(v) local c = Cfg(); if c then c.strata = (v ~= "HIGH") and v or nil end end)

  rows[#rows + 1] = MakeSlider(editor, -150, "Alpha %", 0, 100, 5,
    function() local c = Cfg(); return c and ((c.alpha or 1) * 100) end,
    function(v) local c = Cfg(); if c then c.alpha = v / 100 end end)

  Header(editor, 12, -186, "Position and Size")
  -- Width/Height are cross-linked when the aspect lock is engaged: changing one
  -- scales the other by cfg.aspect (the w/h ratio captured when the lock was set).
  local widthRow, heightRow
  local function clampDim(n) return math.max(8, math.min(8192, math.floor(n + 0.5))) end
  widthRow = MakeSlider(editor, -212, "Width", 8, 8192, 2,
    function() local c = Cfg(); return c and (c.width or c.size) end,
    function(v)
      local c = Cfg(); if not c then return end
      c.width = v
      if c.lockAspect then
        c.height = clampDim(v / (c.aspect or 1))
        if heightRow then heightRow:refresh() end
      end
    end)
  rows[#rows + 1] = widthRow
  heightRow = MakeSlider(editor, -244, "Height", 8, 8192, 2,
    function() local c = Cfg(); return c and (c.height or c.size) end,
    function(v)
      local c = Cfg(); if not c then return end
      c.height = v
      if c.lockAspect then
        c.width = clampDim(v * (c.aspect or 1))
        if widthRow then widthRow:refresh() end
      end
    end)
  rows[#rows + 1] = heightRow

  -- Aspect-ratio lock: a thin 1px bracket in the right margin whose two arms point
  -- at the Width & Height boxes (starting past their edge so they don't overlap),
  -- joined by a short spine with the padlock sitting on it.
  local BRP, BRA = COLOR.purple, 0.6
  local brTop = editor:CreateTexture(nil, "ARTWORK"); brTop:SetColorTexture(BRP.r, BRP.g, BRP.b, BRA)
  brTop:SetPoint("TOPLEFT", 357, -220); brTop:SetSize(5, 1)     -- arm at the Width box centerline
  local brBot = editor:CreateTexture(nil, "ARTWORK"); brBot:SetColorTexture(BRP.r, BRP.g, BRP.b, BRA)
  brBot:SetPoint("TOPLEFT", 357, -252); brBot:SetSize(5, 1)     -- arm at the Height box centerline
  local brSpine = editor:CreateTexture(nil, "ARTWORK"); brSpine:SetColorTexture(BRP.r, BRP.g, BRP.b, BRA)
  brSpine:SetPoint("TOPLEFT", 361, -220); brSpine:SetSize(1, 33)  -- joins the two arms

  local aspectBtn = CreateFrame("Button", nil, editor)
  aspectBtn:SetSize(14, 14); aspectBtn:SetPoint("LEFT", brSpine, "RIGHT", 0, 0)
  local alock = aspectBtn:CreateTexture(nil, "ARTWORK"); alock:SetAllPoints()
  -- Jason's custom lock icons (Media/lock_locked.png / lock_unlocked.png) with colors
  -- baked in — no tint, just swap the texture by state (white vertex = show as-authored).
  local LOCK_ON, LOCK_OFF = MEDIA .. "lock_locked.png", MEDIA .. "lock_unlocked.png"
  local function alockRefresh()
    local c = Cfg(); local on = c and c.lockAspect
    alock:SetTexture(on and LOCK_ON or LOCK_OFF)
    alock:SetVertexColor(1, 1, 1, 1)
  end
  aspectBtn:SetScript("OnClick", function()
    local c = Cfg(); if not c then return end
    local on = not c.lockAspect
    c.lockAspect = on or nil
    if on then
      local w, h = (c.width or c.size or 64), (c.height or c.size or 64)
      c.aspect = (h > 0) and (w / h) or 1
    end
    alockRefresh()
  end)
  rows[#rows + 1] = {
    refresh = alockRefresh,
    setEnabled = function(_, on) aspectBtn:SetEnabled(on); alock:SetDesaturated(not on) end,
  }
  rows[#rows + 1] = MakeSlider(editor, -276, "X Offset", -2000, 2000, 5,
    function() local c = Cfg(); return c and c.point and c.point[2] end,
    function(v) local c = Cfg(); if c then c.point = { "CENTER", v, (c.point and c.point[3]) or 0 } end end)
  rows[#rows + 1] = MakeSlider(editor, -308, "Y Offset", -2000, 2000, 5,
    function() local c = Cfg(); return c and c.point and c.point[3] end,
    function(v) local c = Cfg(); if c then c.point = { "CENTER", (c.point and c.point[2]) or 0, v } end end)

  Header(editor, 12, -344, "Trigger & Visibility")
  local trigBtn = flatButton(editor, 110, 24, COLOR.heroic, "Edit Trigger…", 12)
  trigBtn:SetPoint("TOPLEFT", 16, -368)
  trigBtn:SetScript("OnClick", function() if selectedID then OpenTriggerEditor(selectedID) end end)
  triggerSummary = newText(editor, FONT.body, 12, TEXT, "LEFT")
  triggerSummary:SetPoint("LEFT", trigBtn, "RIGHT", 10, 0); triggerSummary:SetWidth(EDITOR_W - 150); triggerSummary:SetJustifyH("LEFT")

  local visBtn = flatButton(editor, 110, 24, COLOR.heroic, "Visibility…", 12)
  visBtn:SetPoint("TOPLEFT", 16, -400)
  visBtn:SetScript("OnClick", function() if selectedID then OpenVisibilityEditor(selectedID) end end)
  visibilitySummary = newText(editor, FONT.body, 12, TEXT, "LEFT")
  visibilitySummary:SetPoint("LEFT", visBtn, "RIGHT", 10, 0); visibilitySummary:SetWidth(EDITOR_W - 150); visibilitySummary:SetJustifyH("LEFT")

  Header(editor, 12, -434, "Sound")
  local soundBtn = flatButton(editor, 200, 22, COLOR.heroic, "None", 12)
  soundBtn:SetPoint("TOPLEFT", 16, -458)
  local function soundLabel() local c = Cfg(); return (c and c.sound and c.sound.name) or "None" end
  soundBtn:SetScript("OnClick", function()
    local c = Cfg(); if not c then return end
    OpenSoundPicker(function(item)
      if item.file then c.sound = { file = item.file, name = item.name, channel = "Master" }
      else c.sound = nil end
      soundBtn:SetText(soundLabel())
    end, c.sound and c.sound.file)
  end)
  local testBtn = flatButton(editor, 60, 22, COLOR.heroic, "Test", 12)
  testBtn:SetPoint("LEFT", soundBtn, "RIGHT", 8, 0)
  testBtn:SetScript("OnClick", function()
    local c = Cfg(); if c and c.sound and c.sound.file then pcall(PlaySoundFile, c.sound.file, c.sound.channel or "Master") end
  end)
  rows[#rows + 1] = {
    refresh = function() soundBtn:SetText(soundLabel()) end,
    setEnabled = function(_, on) soundBtn:SetEnabled(on); testBtn:SetEnabled(on) end,
  }

  -- (Remove button lives under "+ Add aura" in the left pane — see below.)

  -- ---- Global option (bottom strip): hide Blizzard's own Cooldown Manager ----
  -- Drives viewer alpha only (not Hide()), so our state mirror keeps working.
  local hideCDM = flatCheck(p, "Hide Blizzard's Cooldown Manager (tracking stays active)")
  hideCDM:SetPoint("BOTTOMLEFT", INSET, 34)
  hideCDM:SetScript("OnClick", function()
    local on = not hideCDM:Get()
    hideCDM:Set(on)
    if GA.CDM and GA.CDM.ToggleBlizzardHide then GA.CDM:ToggleBlizzardHide(on) end
  end)

  local hint = newText(p, FONT.body, 11, MUTE, "CENTER")
  hint:SetPoint("BOTTOM", 0, 12)
  hint:SetText("Drag the title bar to move · drag an aura on screen to place it · blank texture = spell icon")

  p:SetScript("OnShow", function()
    hideCDM:Set(GA.db and GA.db.hideBlizzardCDM)
    local pos = GA.db and GA.db.panelPos
    if pos then p:ClearAllPoints(); p:SetPoint("CENTER", UIParent, "CENTER", pos[1] or 0, pos[2] or 0) end
    if GA.Displays then
      GA.Displays.forced = true
      local db = DB()
      if db then for sid, cfg in pairs(db) do if cfg.enabled ~= false then local f = GA.Displays:GetOrCreate(sid); if f then f:Show() end end end end
      GA.Displays:SetInteractive(true)
    end
    SetSelected(selectedID or DisplayList()[1])
  end)
  p:SetScript("OnHide", function()
    if GA.Displays then GA.Displays.forced = false; GA.Displays:SetSelectedDisplay(nil) end
    if GA.CDM and GA.CDM.Discover then GA.CDM:Discover() end
  end)

  tinsert(UISpecialFrames, "GloomsAurasConfig")  -- ESC closes it
  p:Hide()  -- created hidden so the first /ga transitions + fires OnShow
  panel = p
  return p
end

function C:RefreshCurrent()
  for _, r in ipairs(rows) do r:refresh() end
end

function C:SavePanelPos()
  if not panel or not GA.db then return end
  local px, py = panel:GetCenter()
  local ucx, ucy = UIParent:GetCenter()
  if px and ucx then
    GA.db.panelPos = { math.floor(px - ucx + 0.5), math.floor(py - ucy + 0.5) }
  end
end

function C:Toggle()
  if not panel then
    local ok, err = pcall(Build)
    if not ok then GA.msg("|cffff5555config panel failed to build|r: " .. tostring(err)); return end
  end
  if panel:IsShown() then panel:Hide() else panel:Show() end
end
