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

-- Dock an editor flush against the main panel's right edge (parented to it so it
-- follows when the panel moves and hides when it closes). Flips to the LEFT side if
-- docking right would run off the screen. Drag is disabled (it's attached now).
local function DockRight(f)
  if not panel then return end
  f:SetParent(panel)
  f:SetMovable(false)
  f:SetClampedToScreen(false)
  f:ClearAllPoints()
  local pr, sw, fw = panel:GetRight(), UIParent:GetRight(), (f:GetWidth() or 0)
  if pr and sw and (pr + fw + 2) > sw then
    f:SetPoint("TOPRIGHT", panel, "TOPLEFT", 1, 0)    -- flip: dock on the left
  else
    f:SetPoint("TOPLEFT", panel, "TOPRIGHT", -1, 0)   -- dock on the right (flush)
  end
end

local listFrame, listRows, listData, listOffset = nil, {}, {}, 0
local LIST_ROWS = 20   -- leave room for the Add / Duplicate / Remove button stack
local LIST_ROW_H = 24

-- Texture blend modes (SetBlendMode) + friendly labels; frame strata choices.
local BLEND_MODES = {
  { "BLEND", "Blend" }, { "ADD", "Add (glow)" }, { "MOD", "Modulate" },
}
local STRATA_MODES = {
  { "LOW", "Low" }, { "MEDIUM", "Medium" }, { "HIGH", "High" },
  { "DIALOG", "Dialog" }, { "TOOLTIP", "Tooltip" },
}

-- Collapse caret for group / Ungrouped headers: Jason's bundled triangle PNG
-- (Media/caret.png), drawn pointing RIGHT when collapsed and rotated 90° to point
-- DOWN when expanded. Colors baked in → shown untinted (like the lock icons). NO
-- native Blizzard art / unicode triangles (game fonts lack ▼/▶ → tofu boxes).
local CARET_DOWN = -math.pi / 2   -- rotate a right-pointing source to point down (expanded)

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

-- --------------------------------------------------------------------------
-- Groups (Phase 1): named buckets of auras carrying one load rule (a visibility
-- table) + an on/off switch. Stored in GA.db.groups[groupID]; an aura joins via
-- cfg.group. groupID = a "gN" string (own counter, never collides with display ids).
-- --------------------------------------------------------------------------
local function Groups() return GA.db and GA.db.groups end

local function GroupList()   -- group ids sorted by order, then name
  local out = {}
  local g = Groups()
  if g then for id in pairs(g) do out[#out + 1] = id end end
  table.sort(out, function(a, b)
    local ga, gb = g[a], g[b]
    local oa, ob = ga.order or 0, gb.order or 0
    if oa ~= ob then return oa < ob end
    return tostring(ga.name or a) < tostring(gb.name or b)
  end)
  return out
end

local function NewGroupID()
  local db = GA.db
  db.groupSeq = (db.groupSeq or 0) + 1
  local id = "g" .. db.groupSeq
  while Groups() and Groups()[id] ~= nil do db.groupSeq = db.groupSeq + 1; id = "g" .. db.groupSeq end
  return id
end

local function CreateGroup(name)
  local g = Groups(); if not g then return nil end
  local id = NewGroupID()
  local maxOrder = -1
  for _, grp in pairs(g) do maxOrder = math.max(maxOrder, grp.order or 0) end
  g[id] = { id = id, name = (name and name ~= "" and name) or ("Group " .. id),
            order = maxOrder + 1, enabled = true }
  return id
end

-- Delete a group; its member auras fall back to Ungrouped (auras are never deleted —
-- approved rule). Returns the group's name for a confirmation message.
local function DeleteGroup(gid)
  local g = Groups(); if not g or not g[gid] then return nil end
  local name = g[gid].name or gid
  local db = DB()
  if db then for _, cfg in pairs(db) do if cfg.group == gid then cfg.group = nil end end end
  g[gid] = nil
  return name
end

-- Reorder groups by swapping normalized `order` values (up = -1, down = +1).
local function MoveGroup(gid, dir)
  local list = GroupList()
  local g = Groups(); if not g then return end
  for i, id in ipairs(list) do g[id].order = i - 1 end   -- normalize to 0..n-1 first
  local idx
  for i, id in ipairs(list) do if id == gid then idx = i; break end end
  local j = idx and (idx + dir)
  if not idx or not j or j < 1 or j > #list then return end
  g[list[idx]].order, g[list[j]].order = g[list[j]].order, g[list[idx]].order
end

-- Display ids assigned to a group (gid), or the Ungrouped set (gid == nil). A stale
-- group id (points at a deleted group) counts as Ungrouped. Sorted like DisplayList.
local function AurasInGroup(gid)
  local out, db = {}, DB()
  if db then
    for id, cfg in pairs(db) do
      local cg = cfg.group
      if cg ~= nil and not (Groups() and Groups()[cg]) then cg = nil end  -- stale → Ungrouped
      if cg == gid then out[#out + 1] = id end
    end
  end
  table.sort(out, function(a, b)
    local sa = (db and db[a] and db[a].spellID) or 0
    local sb = (db and db[b] and db[b].spellID) or 0
    if sa ~= sb then return sa < sb end
    return tostring(a) < tostring(b)
  end)
  return out
end

-- The left pane as a flat list of typed rows: group headers (+ their auras when
-- expanded), then an Ungrouped header (+ its auras). With NO groups defined it's just
-- a flat aura list (no headers) — identical to the pre-groups look.
local function BuildLeftPaneEntries()
  local entries = {}
  local groups = GroupList()
  for _, gid in ipairs(groups) do
    local g = Groups()[gid]
    entries[#entries + 1] = { kind = "group", gid = gid }
    if not g.collapsed then
      for _, id in ipairs(AurasInGroup(gid)) do entries[#entries + 1] = { kind = "aura", id = id } end
    end
  end
  local ung = AurasInGroup(nil)
  if #groups == 0 then
    for _, id in ipairs(ung) do entries[#entries + 1] = { kind = "aura", id = id } end
  elseif #ung > 0 then
    entries[#entries + 1] = { kind = "ungrouped" }
    if not (GA.db and GA.db.ungroupedCollapsed) then
      for _, id in ipairs(ung) do entries[#entries + 1] = { kind = "aura", id = id } end
    end
  end
  return entries
end

-- Small skinned text-entry dialog (matches the panel) for naming a group. Reused
-- for Phase 2 rename. Avoids StaticPopup (default chrome + its editBox/EditBox field
-- name shifts between clients). onAccept(name) fires on OK / Enter.
local nameDlgFrame, nameDlgBox, nameDlgTitle, nameDlgOnAccept

local function BuildNameDialog()
  local W, H = 300, 132
  local f = CreateFrame("Frame", "GloomsAurasNameDialog", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)
  nameDlgTitle = newText(f, FONT.title, 17, COLOR.purple, "CENTER")
  nameDlgTitle:SetPoint("TOP", 0, -14); nameDlgTitle:SetText("New Group")
  nameDlgBox = flatEditBox(f, W - 48, 24); nameDlgBox:SetPoint("TOP", 0, -50)
  local okB = flatButton(f, 100, 26, COLOR.purple, "OK", 13); okB:SetPoint("BOTTOMLEFT", 26, 16)
  local cancelB = flatButton(f, 100, 26, COLOR.heroic, "Cancel", 13); cancelB:SetPoint("BOTTOMRIGHT", -26, 16)
  local function accept()
    local name = nameDlgBox:GetText()
    local cb = nameDlgOnAccept; nameDlgOnAccept = nil
    f:Hide()
    if cb then cb(name) end
  end
  local function cancel() nameDlgOnAccept = nil; f:Hide() end
  okB:SetScript("OnClick", accept)
  cancelB:SetScript("OnClick", cancel)
  nameDlgBox:SetScript("OnEnterPressed", accept)
  nameDlgBox:SetScript("OnEscapePressed", cancel)
  tinsert(UISpecialFrames, "GloomsAurasNameDialog")   -- ESC closes it
  f:Hide()
  nameDlgFrame = f
  return f
end

local function OpenNameDialog(titleText, initial, onAccept)
  if not nameDlgFrame then
    local ok, err = pcall(BuildNameDialog)
    if not ok then GA.msg("|cffff5555name dialog failed to build|r: " .. tostring(err)); return end
  end
  nameDlgOnAccept = onAccept
  nameDlgTitle:SetText(titleText or "Name")
  nameDlgBox:SetText(initial or ""); nameDlgBox:SetCursorPosition(0)
  nameDlgFrame:Show(); nameDlgFrame:Raise()
  nameDlgBox:SetFocus(); nameDlgBox:HighlightText()
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
  -- (no border) + an orange vertical marker for the thumb. Best-effort: if
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
    thumb:SetColorTexture(COLOR.orange.r, COLOR.orange.g, COLOR.orange.b, 1)      -- orange marker (#FF7729)
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

-- Binary sliding switch (matches GloomsBuildBarn's makeSwitch): [leftLabel]
-- [track+knob] [rightLabel]. value=false→left, true→right; the selected label is
-- accented (purple), the other dimmed, and the knob slides to that side. onChange(v)
-- fires only on a USER toggle (not on :Set). :Set / :Refresh / :SetEnabled provided.
local function makeSwitch(parent, leftText, rightText, onChange)
  local s = CreateFrame("Frame", nil, parent)
  s:SetSize(120, 22)
  s.value = false

  s.left = CreateFrame("Button", nil, s)
  s.left.text = newText(s.left, FONT.label, 12, TEXT, "RIGHT")
  s.left.text:SetText(leftText); s.left.text:SetAllPoints()
  s.left:SetSize((s.left.text:GetStringWidth() or 20) + 2, 16)
  s.left:SetPoint("LEFT", 0, 0)

  s.track = CreateFrame("Button", nil, s)
  s.track:SetSize(46, 20)
  s.track:SetPoint("LEFT", s.left, "RIGHT", 10, 0)
  s.track.fill = s.track:CreateTexture(nil, "BACKGROUND")
  s.track.fill:SetAllPoints(); s.track.fill:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.16)
  s.track.knob = s.track:CreateTexture(nil, "ARTWORK"); s.track.knob:SetSize(18, 14)
  s.track.knob:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1)

  s.right = CreateFrame("Button", nil, s)
  s.right.text = newText(s.right, FONT.label, 12, TEXT, "LEFT")
  s.right.text:SetText(rightText); s.right.text:SetAllPoints()
  s.right:SetSize((s.right.text:GetStringWidth() or 20) + 2, 16)
  s.right:SetPoint("LEFT", s.track, "RIGHT", 10, 0)

  local function refresh()
    local k = s.track.knob
    k:ClearAllPoints()
    if s.value then k:SetPoint("RIGHT", -3, 0) else k:SetPoint("LEFT", 3, 0) end
    local on, off = COLOR.purple, MUTE
    if s.value then
      s.left.text:SetTextColor(off.r, off.g, off.b);  s.right.text:SetTextColor(on.r, on.g, on.b)
    else
      s.left.text:SetTextColor(on.r, on.g, on.b);     s.right.text:SetTextColor(off.r, off.g, off.b)
    end
  end
  local function set(v)
    v = v and true or false
    if s.value == v then return end
    s.value = v; refresh(); if onChange then onChange(v) end
  end
  s.track:SetScript("OnClick", function() set(not s.value) end)
  s.left:SetScript("OnClick", function() set(false) end)
  s.right:SetScript("OnClick", function() set(true) end)
  function s:Set(v) s.value = v and true or false; refresh() end
  function s:Refresh() refresh() end
  function s:SetEnabled(on)
    s.track:SetEnabled(on); s.left:SetEnabled(on); s.right:SetEnabled(on)
    s:SetAlpha(on and 1 or 0.4)
  end
  refresh()
  return s
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
  listData = BuildLeftPaneEntries()
  local n = #listData
  local maxOff = math.max(0, n - LIST_ROWS)
  if listOffset > maxOff then listOffset = maxOff end
  if listOffset < 0 then listOffset = 0 end
  for i = 1, LIST_ROWS do
    local row = listRows[i]
    if not row then break end
    local e = listData[i + listOffset]
    -- reset the shared sub-widgets each render (rows switch between kinds)
    row.kind, row.id, row.gid, row.spellID = nil, nil, nil, nil
    if not e then
      row:Hide()
    elseif e.kind == "aura" then
      local sid = e.id
      local cfg = DB() and DB()[sid]
      row.kind, row.id, row.spellID = "aura", sid, sid
      if row.arrow then row.arrow:Hide() end
      if row.gear then row.gear:Hide() end
      row.icon:Show()
      local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture((cfg and cfg.spellID) or sid)
      row.icon:SetTexture(icon or 134400)
      if row.eye then
        row.eye:Show()
        local shown = not (cfg and cfg.enabled == false)
        row.eye.icon:SetTexture(MEDIA .. (shown and "unhidden.png" or "hidden.png"))
      end
      row.name:ClearAllPoints(); row.name:SetPoint("LEFT", 40, 0); row.name:SetPoint("RIGHT", -24, 0)
      row.name:SetText((cfg and cfg.label) or ("Spell " .. tostring(sid)))
      local dim = cfg and cfg.enabled == false
      row.name:SetTextColor(dim and 0.5 or TEXT.r, dim and 0.5 or TEXT.g, dim and 0.5 or TEXT.b)
      row.sel:SetShown(sid == selectedID)
      row:Show()
    elseif e.kind == "group" then
      local g = Groups() and Groups()[e.gid]
      row.kind, row.gid = "group", e.gid
      row.icon:Hide(); row.sel:Hide()
      if row.eye then row.eye:Hide() end
      if row.arrow then row.arrow:Show(); row.arrow:SetRotation((g and g.collapsed) and 0 or CARET_DOWN) end
      if row.gear then row.gear:Show() end
      row.name:ClearAllPoints(); row.name:SetPoint("LEFT", 26, 0); row.name:SetPoint("RIGHT", -26, 0)
      local off = g and g.enabled == false
      row.name:SetText((g and g.name or "Group") .. (off and "  |cff888888(off)|r" or ""))
      row.name:SetTextColor(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b)
      row:Show()
    elseif e.kind == "ungrouped" then
      row.kind = "ungrouped"
      row.icon:Hide(); row.sel:Hide()
      if row.eye then row.eye:Hide() end
      if row.arrow then row.arrow:Show(); row.arrow:SetRotation((GA.db and GA.db.ungroupedCollapsed) and 0 or CARET_DOWN) end
      if row.gear then row.gear:Hide() end
      row.name:ClearAllPoints(); row.name:SetPoint("LEFT", 26, 0); row.name:SetPoint("RIGHT", -4, 0)
      row.name:SetText("Ungrouped")
      row.name:SetTextColor(MUTE.r, MUTE.g, MUTE.b)
      row:Show()
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
  if editorName then
    if cfg then editorName:SetText(cfg.label or tostring(sid)); editorName:Enable()
    else editorName:SetText(""); editorName:ClearFocus(); editorName:Disable() end
  end
  if triggerSummary then triggerSummary:SetText(cfg and SummaryText(cfg) or "") end
  if visibilitySummary then visibilitySummary:SetText(cfg and VisibilitySummary(cfg) or "") end
  for _, r in ipairs(rows) do r:refresh(); r:setEnabled(cfg ~= nil) end
  if C.RefreshTextEditor then C:RefreshTextEditor() end   -- text drawer follows selection (self-guards to when open)
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
  ptb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
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
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
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
  DockRight(texPickerFrame)
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
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
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
  DockRight(soundPickerFrame)
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
  local W, H = 380, 118 + ROWS * 26 + 28   -- extra room so the hint clears the Add button
  local f = CreateFrame("Frame", "GloomsAurasTrigger", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)

  triggerTitle = newText(f, FONT.title, 18, COLOR.purple, "CENTER"); triggerTitle:SetPoint("TOP", 0, -12); triggerTitle:SetText("Trigger")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12); close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)

  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2); tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end); tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

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
  add:SetPoint("BOTTOMLEFT", 16, 42)
  add:SetScript("OnClick", function() OpenPicker(function(sid) AddCondition(sid) end) end)
  -- Width-constrained so it wraps instead of running off the edges, and below the Add button.
  local ah = newText(f, FONT.body, 11, MUTE, "CENTER"); ah:SetWidth(W - 32); ah:SetPoint("BOTTOM", 0, 12)
  ah:SetText("No conditions = the aura shows on its own state · click a state to change it")

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
  DockRight(triggerFrame)
  triggerFrame:Show(); triggerFrame:Raise()
end

-- --------------------------------------------------------------------------
-- Visibility editor: player/game-state conditions that gate the display (they
-- AND with the Trigger). "Show only when ALL of these are true."
-- --------------------------------------------------------------------------
-- The visibility editor edits ONE of: an aura (visEditID) or a group's load rule
-- (visEditGroup). Exactly one is set at a time; VE_Vis returns the right table so
-- every control below is identical for both. (Group load rule = the same design.)
local visFrame, visEditID, visEditGroup, visTitle
local veRows = {}

local function VE_Cfg() return visEditID and DB() and DB()[visEditID] end
local function VE_Group() return visEditGroup and Groups() and Groups()[visEditGroup] end
local function VE_Vis()
  if visEditGroup then
    local g = VE_Group(); if not g then return nil end
    g.visibility = g.visibility or {}; return g.visibility
  end
  local c = VE_Cfg(); if not c then return nil end
  c.visibility = c.visibility or {}; return c.visibility
end

local function VE_Changed()
  if GA.CDM then GA.CDM:UpdateVisibilityPoll(); GA.CDM:RefreshDisplays() end
  if not visEditGroup and visibilitySummary and visEditID == selectedID then
    visibilitySummary:SetText(VisibilitySummary(VE_Cfg()))
  end
  if visEditGroup and C.RefreshGroupControl then C:RefreshGroupControl() end
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
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end); tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

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
    if not visEditGroup and visibilitySummary and visEditID == selectedID then
      visibilitySummary:SetText(VisibilitySummary(VE_Cfg()))
    end
    if visEditGroup and C.RefreshGroupControl then C:RefreshGroupControl() end
  end)
  tinsert(UISpecialFrames, "GloomsAurasVisibility")
  f:Hide()
  visFrame = f; RegisterSubWindow(f)
  return f
end

local function ShowVisibilityEditor(titleText)
  if not visFrame then
    local ok, err = pcall(BuildVisibilityEditor)
    if not ok then GA.msg("|cffff5555visibility editor failed to build|r: " .. tostring(err)); return end
  end
  if visTitle then visTitle:SetText(titleText) end
  for _, r in ipairs(veRows) do r:refresh() end
  CloseSubWindows(visFrame)
  DockRight(visFrame)
  visFrame:Show(); visFrame:Raise()
end

local function OpenVisibilityEditor(spellID)
  if not spellID then return end
  visEditID = spellID; visEditGroup = nil
  local c = VE_Cfg(); if c then c.visibility = c.visibility or {} end
  ShowVisibilityEditor("Visibility: " .. ((c and c.label) or tostring(spellID)))
end

-- Same editor, targeting a group's load rule instead of an aura's visibility.
local function OpenGroupVisibilityEditor(groupID)
  if not groupID then return end
  visEditGroup = groupID; visEditID = nil
  local g = VE_Group(); if g then g.visibility = g.visibility or {} end
  ShowVisibilityEditor("Group Rule: " .. ((g and g.name) or tostring(groupID)))
end

-- --------------------------------------------------------------------------
-- Build the main panel (two-pane: aura list | settings editor).
-- --------------------------------------------------------------------------
local PANEL_W, PANEL_H = 580, 704
local INSET, TITLEBAR_H = 14, 32
local CONTENT_TOP = -(TITLEBAR_H + 8)   -- -40
local LIST_W = 160
local EDITOR_X = INSET + LIST_W + 16     -- 190
local EDITOR_W = PANEL_W - EDITOR_X - INSET  -- 376
local PANE_H = 600

-- The aura editor's GROUP section — now JUST the "which group is this aura in"
-- assignment dropdown (a group's OWN settings live in the Manage Group drawer, opened
-- from the ⚙ on its left-pane header). Extracted from Build() to keep Build under Lua
-- 5.1's 60-upvalue limit. Registers a refresh into `rows` + sets C.RefreshGroupControl.
local function BuildGroupSection(editor)
  Header(editor, 12, -488, "Group")

  local function currentGroup()
    local c = Cfg(); local gid = c and c.group
    return gid, gid and Groups() and Groups()[gid] or nil
  end

  local groupBtn = flatButton(editor, 200, 22, COLOR.heroic, "Ungrouped", 12)
  groupBtn:SetPoint("TOPLEFT", 16, -512)
  local hint = newText(editor, FONT.body, 11, MUTE, "LEFT")
  hint:SetPoint("TOPLEFT", 16, -538)
  hint:SetText("Manage a group (rule, on/off, rename…) from the gear on its header.")

  -- Dropdown menu (rebuilt on each open from the live group list). Opens UPWARD.
  local groupMenu = CreateFrame("Frame", nil, editor)
  groupMenu:SetFrameLevel((editor:GetFrameLevel() or 1) + 40)
  skinPlate(groupMenu)
  groupMenu:SetPoint("BOTTOMLEFT", groupBtn, "TOPLEFT", 0, 2)
  groupMenu:Hide()
  local groupMenuItems = {}

  local function refreshGroupControl()
    local c = Cfg()
    local _, g = currentGroup()
    groupBtn:SetText(g and g.name or "Ungrouped")
    groupBtn:SetEnabled(c ~= nil)
  end
  C.RefreshGroupControl = function() refreshGroupControl() end

  local function assignGroup(gid)
    local c = Cfg(); if not c then return end
    c.group = gid            -- nil = ungrouped
    refreshGroupControl()
    RefreshList()            -- the aura moves under its new group in the left pane
    if GA.CDM then GA.CDM:UpdateVisibilityPoll(); GA.CDM:RefreshDisplays() end
  end

  local function rebuildGroupMenu()
    local entries = { { label = "Ungrouped", act = "clear" } }
    for _, id in ipairs(GroupList()) do
      entries[#entries + 1] = { label = Groups()[id].name or id, act = id }
    end
    entries[#entries + 1] = { label = "|cff936bff+ New Group…|r", act = "new" }
    local W = 200
    for i, e in ipairs(entries) do
      local it = groupMenuItems[i]
      if not it then
        it = flatButton(groupMenu, W - 8, 20, COLOR.heroic, "", 12); it:SetBase(0.12)
        groupMenuItems[i] = it
      end
      it:ClearAllPoints(); it:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22)
      it:SetText(e.label)
      it._act = e.act
      it:SetScript("OnClick", function(self)
        groupMenu:Hide(); openDropdownMenu = nil
        local act = self._act
        if act == "new" then
          OpenNameDialog("New Group", nil, function(name) assignGroup(CreateGroup(name)) end)
        elseif act == "clear" then
          assignGroup(nil)
        else
          assignGroup(act)
        end
      end)
      it:Show()
    end
    for i = #entries + 1, #groupMenuItems do groupMenuItems[i]:Hide() end
    groupMenu:SetSize(W, #entries * 22 + 8)
  end

  groupBtn:SetScript("OnClick", function()
    if groupMenu:IsShown() then groupMenu:Hide(); openDropdownMenu = nil
    else
      if openDropdownMenu and openDropdownMenu ~= groupMenu then openDropdownMenu:Hide() end
      rebuildGroupMenu()
      groupMenu:Show(); openDropdownMenu = groupMenu
    end
  end)

  rows[#rows + 1] = {
    refresh = refreshGroupControl,
    setEnabled = function(_, on) if not on then groupMenu:Hide() end end,  -- refresh handles enable state
  }
end

-- --------------------------------------------------------------------------
-- Manage Group drawer: a group's OWN settings (rename · load rule · on/off ·
-- reorder · delete), opened by the ⚙ on its left-pane header. Docks like the
-- other editors. Edits GA.db.groups[gmEditGID].
-- --------------------------------------------------------------------------
local gmFrame, gmEditGID, gmTitle, gmSwitch
local function GM_Group() return gmEditGID and Groups() and Groups()[gmEditGID] end

local function BuildGroupManager()
  local W, H = 250, 214
  local f = CreateFrame("Frame", "GloomsAurasGroupManager", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)
  gmTitle = newText(f, FONT.title, 16, COLOR.purple, "LEFT")
  gmTitle:SetPoint("TOPLEFT", 14, -14); gmTitle:SetPoint("RIGHT", -36, 0); gmTitle:SetText("Manage Group")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)
  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2)
  tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
  tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  -- On/off switch for the whole group.
  local onLbl = newText(f, FONT.body, 12, TEXT, "LEFT"); onLbl:SetPoint("TOPLEFT", 16, -50); onLbl:SetText("Group")
  gmSwitch = makeSwitch(f, "OFF", "ON", function(v)
    local g = GM_Group(); if not g then return end
    g.enabled = v
    RefreshList()
    if GA.CDM then GA.CDM:UpdateVisibilityPoll(); GA.CDM:RefreshDisplays() end
  end)
  gmSwitch:SetPoint("LEFT", onLbl, "RIGHT", 14, 0)

  -- Rename + Load Rule.
  local renameBtn = flatButton(f, 106, 24, COLOR.heroic, "Rename…", 12); renameBtn:SetPoint("TOPLEFT", 16, -84)
  renameBtn:SetScript("OnClick", function()
    local g = GM_Group(); if not g then return end
    OpenNameDialog("Rename Group", g.name, function(name)
      if name and name ~= "" then g.name = name end
      gmTitle:SetText("Manage: " .. (g.name or ""))
      RefreshList()
    end)
  end)
  local ruleBtn = flatButton(f, 106, 24, COLOR.heroic, "Load Rule…", 12); ruleBtn:SetPoint("LEFT", renameBtn, "RIGHT", 8, 0)
  ruleBtn:SetScript("OnClick", function() if gmEditGID then OpenGroupVisibilityEditor(gmEditGID) end end)

  -- Reorder (up / down within the group list).
  local upBtn = flatButton(f, 106, 24, COLOR.heroic, "Move Up", 12); upBtn:SetPoint("TOPLEFT", 16, -116)
  upBtn:SetScript("OnClick", function() if gmEditGID then MoveGroup(gmEditGID, -1); RefreshList() end end)
  local downBtn = flatButton(f, 106, 24, COLOR.heroic, "Move Down", 12); downBtn:SetPoint("LEFT", upBtn, "RIGHT", 8, 0)
  downBtn:SetScript("OnClick", function() if gmEditGID then MoveGroup(gmEditGID, 1); RefreshList() end end)

  -- Delete (auras fall back to Ungrouped).
  local delBtn = flatButton(f, 220, 24, COLOR.orange, "Delete Group", 12); delBtn:SetPoint("TOPLEFT", 16, -148)
  delBtn:SetScript("OnClick", function()
    local name = DeleteGroup(gmEditGID)
    if name then GA.msg(("deleted group |cffffffff%s|r — its auras moved to Ungrouped."):format(name)) end
    f:Hide(); RefreshList()
    if C.RefreshGroupControl then C:RefreshGroupControl() end
    if GA.CDM then GA.CDM:UpdateVisibilityPoll(); GA.CDM:RefreshDisplays() end
  end)

  local foot = newText(f, FONT.body, 11, MUTE, "CENTER"); foot:SetPoint("BOTTOM", 0, 12); foot:SetWidth(W - 24)
  foot:SetText("On/off + load rule gate every aura in this group.")

  tinsert(UISpecialFrames, "GloomsAurasGroupManager")
  f:Hide()
  gmFrame = f; RegisterSubWindow(f)
  return f
end

local function OpenGroupManager(gid)
  if not gid then return end
  gmEditGID = gid
  if not gmFrame then
    local ok, err = pcall(BuildGroupManager)
    if not ok then GA.msg("|cffff5555group manager failed to build|r: " .. tostring(err)); return end
  end
  local g = GM_Group()
  gmTitle:SetText("Manage: " .. ((g and g.name) or tostring(gid)))
  if gmSwitch then gmSwitch:Set(g and g.enabled ~= false) end
  CloseSubWindows(gmFrame)
  DockRight(gmFrame)
  gmFrame:Show(); gmFrame:Raise()
end

-- --------------------------------------------------------------------------
-- Profiles (Phase 3B): named, switchable configs with a per-character default.
-- A docked drawer (opened from the bottom-strip "Profile:" button) lists every
-- profile — click one to switch — plus New / Copy / Rename / Delete. The switch
-- itself lives in Core (GA:SwitchProfile repoints GA.db); the panel is refreshed
-- via C:OnProfileSwitched, called back from Core after any repoint.
-- --------------------------------------------------------------------------
-- State + UI hang on the C table (not module-level locals) — the file chunk is
-- near Lua's 200-locals-per-function cap, so new module locals would overflow it.
C._prof = { offset = 0, rows = {}, ROWS = 8 }
C._confirm = {}

-- Small skinned yes/no confirm (Delete is destructive) — modeled on OpenNameDialog.
function C:BuildConfirm()
  local W, H = 330, 144
  local f = CreateFrame("Frame", "GloomsAurasConfirm", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)
  local title = newText(f, FONT.title, 17, COLOR.orange, "CENTER")
  title:SetPoint("TOP", 0, -14); title:SetText("Are you sure?")
  C._confirm.body = newText(f, FONT.body, 12, TEXT, "CENTER")
  C._confirm.body:SetPoint("TOP", 0, -46); C._confirm.body:SetWidth(W - 36)
  local yesB = flatButton(f, 124, 26, COLOR.orange, "Delete", 13); yesB:SetPoint("BOTTOMLEFT", 26, 16)
  local noB = flatButton(f, 124, 26, COLOR.heroic, "Cancel", 13); noB:SetPoint("BOTTOMRIGHT", -26, 16)
  yesB:SetScript("OnClick", function() local cb = C._confirm.onYes; C._confirm.onYes = nil; f:Hide(); if cb then cb() end end)
  noB:SetScript("OnClick", function() C._confirm.onYes = nil; f:Hide() end)
  tinsert(UISpecialFrames, "GloomsAurasConfirm")
  f:Hide(); C._confirm.frame = f
  return f
end
function C:OpenConfirm(bodyText, onYes)
  if not C._confirm.frame then local ok = pcall(function() C:BuildConfirm() end); if not ok then return end end
  C._confirm.onYes = onYes
  C._confirm.body:SetText(bodyText or "Are you sure?")
  C._confirm.frame:Show(); C._confirm.frame:Raise()
end

function C:RefreshProfileList()
  local pr = C._prof
  if not (pr.frame and pr.frame:IsShown()) then return end
  local names = GA:ProfileNames()
  local active = GA:ActiveProfileName()
  local n = #names
  local maxOff = math.max(0, n - pr.ROWS)
  if pr.offset > maxOff then pr.offset = maxOff end
  if pr.offset < 0 then pr.offset = 0 end
  for i = 1, pr.ROWS do
    local row = pr.rows[i]
    local name = names[i + pr.offset]
    if name then
      row.pname = name
      row.text:SetText(name .. (name == active and "  |cff936bff(active)|r" or ""))
      row.sel:SetShown(name == active)
      row:Show()
    else
      row.pname = nil; row:Hide()
    end
  end
end

function C:BuildProfileManager()
  local pr = C._prof
  local W = 264
  local yList = -60
  local listH = pr.ROWS * 24
  local yBtns = yList - listH - 14          -- first button row (below the list)
  local yFoot = yBtns - 32 - 26 - 16        -- footer top: below the 2nd button row + a gap
  local H = -yFoot + 34                      -- room for a (possibly 2-line) footer + bottom pad
  local f = CreateFrame("Frame", "GloomsAurasProfileManager", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)
  local title = newText(f, FONT.title, 16, COLOR.purple, "LEFT")
  title:SetPoint("TOPLEFT", 14, -14); title:SetPoint("RIGHT", -36, 0); title:SetText("Profiles")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)
  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2)
  tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
  tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  local hint = newText(f, FONT.body, 11, MUTE, "LEFT")
  hint:SetPoint("TOPLEFT", 16, -42); hint:SetText("Click a profile to switch to it.")

  -- Scrollable list of profiles (mouse wheel; profiles are usually few).
  local list = CreateFrame("Frame", nil, f)
  list:SetPoint("TOPLEFT", 14, yList); list:SetSize(W - 28, listH)
  list:EnableMouse(true); list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, d) pr.offset = pr.offset - d; C:RefreshProfileList() end)
  for i = 1, pr.ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetSize(W - 28, 24); row:SetPoint("TOPLEFT", 0, -(i - 1) * 24)
    local sel = row:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints()
    sel:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.28); sel:Hide(); row.sel = sel
    local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
    local t = newText(row, FONT.body, 12, TEXT, "LEFT"); t:SetPoint("LEFT", 8, 0); t:SetPoint("RIGHT", -8, 0)
    t:SetWordWrap(false); row.text = t
    row:SetScript("OnClick", function(self)
      if self.pname and self.pname ~= GA:ActiveProfileName() then GA:SwitchProfile(self.pname) end
    end)
    pr.rows[i] = row
  end

  -- Action buttons (two rows of two).
  local newB = flatButton(f, 116, 26, COLOR.heroic, "New…", 12); newB:SetPoint("TOPLEFT", 16, yBtns)
  newB:SetScript("OnClick", function()
    OpenNameDialog("New Profile", "", function(name)
      local ok, why = GA:CreateProfile(name)
      if not ok then GA.msg(why == "exists" and "a profile with that name already exists." or "enter a profile name.") end
    end)
  end)
  local copyB = flatButton(f, 116, 26, COLOR.heroic, "Copy Current…", 12); copyB:SetPoint("LEFT", newB, "RIGHT", 8, 0)
  copyB:SetScript("OnClick", function()
    OpenNameDialog("Copy Profile", (GA:ActiveProfileName() or "") .. " copy", function(name)
      local ok, why = GA:CopyProfile(name)
      if not ok then GA.msg(why == "exists" and "a profile with that name already exists." or "enter a profile name.") end
    end)
  end)
  local renB = flatButton(f, 116, 26, COLOR.heroic, "Rename…", 12); renB:SetPoint("TOPLEFT", 16, yBtns - 32)
  renB:SetScript("OnClick", function()
    OpenNameDialog("Rename Profile", GA:ActiveProfileName() or "", function(name)
      local ok, why = GA:RenameActiveProfile(name)
      if not ok then GA.msg(why == "exists" and "a profile with that name already exists." or "enter a profile name.") end
    end)
  end)
  local delB = flatButton(f, 116, 26, COLOR.orange, "Delete", 12); delB:SetPoint("LEFT", renB, "RIGHT", 8, 0)
  delB:SetScript("OnClick", function()
    local active = GA:ActiveProfileName()
    if not active then return end
    if #GA:ProfileNames() <= 1 then GA.msg("can't delete your only profile."); return end
    C:OpenConfirm(("Delete profile \"%s\"?  This can't be undone."):format(active), function()
      if GA:DeleteProfile(active) then GA.msg(("deleted profile |cffffffff%s|r."):format(active)) end
    end)
  end)

  local foot = newText(f, FONT.body, 11, MUTE, "CENTER")
  foot:SetPoint("TOPLEFT", 12, yFoot); foot:SetWidth(W - 24)
  foot:SetText("Each character defaults to its own profile.")

  tinsert(UISpecialFrames, "GloomsAurasProfileManager")
  f:Hide(); pr.frame = f; RegisterSubWindow(f)
  return f
end

function C:OpenProfileManager()
  local pr = C._prof
  if not pr.frame then
    local ok, err = pcall(function() C:BuildProfileManager() end)
    if not ok then GA.msg("|cffff5555profile manager failed to build|r: " .. tostring(err)); return end
  end
  CloseSubWindows(pr.frame)
  DockRight(pr.frame)
  pr.frame:Show(); pr.frame:Raise()
  C:RefreshProfileList()
end

-- Keep the bottom-strip button label ("Profile: <name>") in sync.
function C:UpdateProfileButton()
  if self._profileBtn then
    self._profileBtn:SetText("Profile: " .. (GA:ActiveProfileName() or "?"))
  end
end

-- Called by Core (RefreshForProfile) after GA.db is repointed. Rebuilds the left
-- pane + editor for the new profile and re-shows its auras (while the panel is open).
function C:OnProfileSwitched()
  if not panel then return end
  C._prof.offset = 0
  listOffset = 0
  selectedID = nil
  if panel:IsShown() and GA.Displays then
    GA.Displays.forced = true
    local db = DB()
    if db then for sid, cfg in pairs(db) do if cfg.enabled ~= false then local fr = GA.Displays:GetOrCreate(sid); if fr then fr:Show() end end end end
    GA.Displays:SetInteractive(true)
  end
  SetSelected(DisplayList()[1])   -- also refreshes the left list + editor
  if C.RefreshGroupControl then C:RefreshGroupControl() end
  if self._hideCDM then self._hideCDM:Set(GA.db and GA.db.hideBlizzardCDM) end
  self:UpdateProfileButton()
  C:RefreshProfileList()
end

-- --------------------------------------------------------------------------
-- Text editor drawer: the aura's on-screen text overlay (show · content · size ·
-- outline · anchor · color · offset). Edits the SELECTED aura's cfg.text, applied
-- live via ReapplySelected → Displays:ApplyConfig. Docks like the other editors.
-- (Font picker comes next.)
-- --------------------------------------------------------------------------
local textFrame, teTitle
local teRows = {}
local TE_ANCHOR = { { "BOTTOM", "Below" }, { "TOP", "Above" }, { "CENTER", "On aura" }, { "LEFT", "Left" }, { "RIGHT", "Right" } }
local TE_OUTLINE = { { "NONE", "None" }, { "OUTLINE", "Outline" }, { "THICKOUTLINE", "Thick" } }

local function TE_Text()
  local c = Cfg(); if not c then return nil end
  if not c.text then c.text = { show = (c.showLabel ~= false) } end   -- seed from legacy showLabel
  return c.text
end

local function RefreshTextEditor()
  if not (textFrame and textFrame:IsShown()) then return end   -- only when open (avoids seeding cfg.text on every select)
  local c = Cfg()
  if teTitle then teTitle:SetText("Text: " .. ((c and c.label) or "")) end
  for _, r in ipairs(teRows) do r:refresh() end
end
C.RefreshTextEditor = RefreshTextEditor

-- Font picker: bundled fonts (GeneralSans / Khand) + LSM "font" media, each row
-- previewed in its own typeface. Opened from the Text drawer (which stays open).
local FONT_ROWS = 12
local fontPickerFrame, fontPickerOnPick, fontData, fontOffset, fontCurrent
local fontRows = {}

local function BuildFontData()
  local out = { { name = "Default", path = nil } }
  if GA.FONT then
    out[#out + 1] = { name = "GeneralSans", path = GA.FONT.body }
    out[#out + 1] = { name = "GeneralSans Medium", path = GA.FONT.bodyM }
    out[#out + 1] = { name = "GeneralSans Semibold", path = GA.FONT.label }
    out[#out + 1] = { name = "Khand Medium", path = GA.FONT.head }
    out[#out + 1] = { name = "Khand SemiBold", path = GA.FONT.title }
  end
  if LSM and LSM.HashTable then
    local t = LSM:HashTable("font")
    if t then
      local names = {}
      for n in pairs(t) do names[#names + 1] = n end
      table.sort(names, function(a, b) return a:lower() < b:lower() end)
      for _, n in ipairs(names) do out[#out + 1] = { name = n, path = t[n] } end
    end
  end
  return out
end

local function fontNameFor(path)
  if not path then return "Default" end
  for _, it in ipairs(BuildFontData()) do
    if it.path and tostring(it.path) == tostring(path) then return it.name end
  end
  return "Custom"
end

local function RefreshFontList()
  local n = #fontData
  local maxOff = math.max(0, n - FONT_ROWS)
  if fontOffset > maxOff then fontOffset = maxOff end
  if fontOffset < 0 then fontOffset = 0 end
  for i = 1, FONT_ROWS do
    local row, item = fontRows[i], fontData[i + fontOffset]
    if item then
      row.item = item
      setFont(row.text, item.path or (GA.FONT and GA.FONT.body) or DEFAULT_FONT, 14)
      row.text:SetText(item.name)
      local isCur = (item.path == nil and fontCurrent == nil)
                 or (item.path ~= nil and tostring(item.path) == tostring(fontCurrent))
      row.sel:SetShown(isCur)
      row:Show()
    else
      row.item = nil; row:Hide()
    end
  end
end

local function BuildFontPicker()
  local W, H = 300, 56 + FONT_ROWS * 24 + 24
  local f = CreateFrame("Frame", "GloomsAurasFontPicker", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true); f:EnableMouseWheel(true)
  skinPlate(f)
  local title = newText(f, FONT.title, 18, COLOR.purple, "CENTER"); title:SetPoint("TOP", 0, -12); title:SetText("Choose a font")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12); close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)
  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2)
  tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
  tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  for i = 1, FONT_ROWS do
    local row = CreateFrame("Button", nil, f); row:SetSize(W - 28, 22); row:SetPoint("TOPLEFT", 14, -40 - (i - 1) * 24)
    local sel = row:CreateTexture(nil, "BACKGROUND"); sel:SetAllPoints(); sel:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.28); sel:Hide(); row.sel = sel
    local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.10)
    local text = row:CreateFontString(nil, "OVERLAY"); text:SetPoint("LEFT", 8, 0); text:SetPoint("RIGHT", -8, 0); text:SetJustifyH("LEFT"); text:SetTextColor(TEXT.r, TEXT.g, TEXT.b); row.text = text
    row:SetScript("OnClick", function(self)
      if not self.item then return end
      fontCurrent = self.item.path
      if fontPickerOnPick then fontPickerOnPick(self.item.path) end
      RefreshFontList()
    end)
    fontRows[i] = row
  end
  local footer = newText(f, FONT.body, 11, MUTE, "CENTER"); footer:SetPoint("BOTTOM", 0, 8); footer:SetText("mouse-wheel to scroll · click to apply")
  f:SetScript("OnMouseWheel", function(_, d) fontOffset = fontOffset - d; RefreshFontList() end)
  tinsert(UISpecialFrames, "GloomsAurasFontPicker")
  f:Hide()
  fontPickerFrame = f; RegisterSubWindow(f)
  return f
end

local function OpenFontPicker(onPick, current)
  fontPickerOnPick = onPick; fontCurrent = current
  if not fontPickerFrame then
    local ok, err = pcall(BuildFontPicker)
    if not ok then GA.msg("|cffff5555font picker failed to build|r: " .. tostring(err)); return end
  end
  fontData = BuildFontData(); fontOffset = 0
  CloseSubWindows(fontPickerFrame, textFrame)   -- keep the Text drawer open underneath
  fontPickerFrame:Show(); fontPickerFrame:Raise()
  RefreshFontList()
end

local function BuildTextEditor()
  local W, H = 380, 316
  local f = CreateFrame("Frame", "GloomsAurasText", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)
  teTitle = newText(f, FONT.title, 17, COLOR.purple, "LEFT")
  teTitle:SetPoint("TOPLEFT", 14, -12); teTitle:SetPoint("RIGHT", -36, 0); teTitle:SetText("Text")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)
  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2)
  tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
  tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  -- Show text switch.
  local showLbl = newText(f, FONT.body, 12, TEXT, "LEFT"); showLbl:SetPoint("TOPLEFT", 16, -44); showLbl:SetText("Show text")
  local showSw = makeSwitch(f, "OFF", "ON", function(v)
    local t = TE_Text(); if t then t.show = v; ReapplySelected() end
  end)
  showSw:SetPoint("LEFT", showLbl, "RIGHT", 14, 0)
  teRows[#teRows + 1] = { refresh = function() local t = TE_Text(); showSw:Set(not t or t.show ~= false) end }

  -- Content box (blank = the aura's name).
  local cLbl = newText(f, FONT.body, 11, MUTE, "LEFT"); cLbl:SetPoint("TOPLEFT", 16, -70); cLbl:SetText("Text  (blank = the aura's name)")
  local cBox = flatEditBox(f, W - 32, 22); cBox:SetPoint("TOPLEFT", 16, -88)
  cBox:SetScript("OnEnterPressed", function(self)
    local t = TE_Text(); if t then local s = self:GetText(); t.str = (s ~= "" and s) or nil; ReapplySelected() end
    self:ClearFocus()
  end)
  cBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  teRows[#teRows + 1] = { refresh = function() local t = TE_Text(); cBox:SetText((t and t.str) or ""); cBox:SetCursorPosition(0) end }

  -- Font (opens the font picker; keeps this drawer open underneath).
  local fontBtn = flatButton(f, W - 32, 22, COLOR.heroic, "Font: Default", 12)
  fontBtn:SetPoint("TOPLEFT", 16, -118)
  fontBtn:SetScript("OnClick", function()
    local t = TE_Text()
    OpenFontPicker(function(path)
      local t2 = TE_Text(); if t2 then t2.font = path; ReapplySelected(); fontBtn:SetText("Font: " .. fontNameFor(path)) end
    end, t and t.font)
  end)
  teRows[#teRows + 1] = { refresh = function() local c = Cfg(); local t = c and c.text; fontBtn:SetText("Font: " .. fontNameFor(t and t.font)) end }

  -- Size slider.
  teRows[#teRows + 1] = MakeSlider(f, -150, "Size", 6, 48, 1,
    function() local t = TE_Text(); return t and (t.size or 14) end,
    function(v) local t = TE_Text(); if t then t.size = v end end)

  -- Outline + Anchor dropdowns.
  teRows[#teRows + 1] = MakeDropdown(f, 16, -182, 160, "Outline: ", TE_OUTLINE,
    function() local t = TE_Text(); return (t and t.outline) or "OUTLINE" end,
    function(v) local t = TE_Text(); if t then t.outline = (v ~= "OUTLINE") and v or nil end end)
  teRows[#teRows + 1] = MakeDropdown(f, 200, -182, 164, "Anchor: ", TE_ANCHOR,
    function() local t = TE_Text(); return (t and t.anchor) or "BOTTOM" end,
    function(v) local t = TE_Text(); if t then t.anchor = (v ~= "BOTTOM") and v or nil end end)

  -- Colour.
  teRows[#teRows + 1] = MakeColor(f, 16, -214,
    function() local t = TE_Text(); return t and t.color end,
    function(v) local t = TE_Text(); if t then t.color = v end end)

  -- X / Y offset (added on top of the anchor's base position).
  teRows[#teRows + 1] = MakeSlider(f, -244, "X Offset", -400, 400, 2,
    function() local t = TE_Text(); return t and (t.x or 0) end,
    function(v) local t = TE_Text(); if t then t.x = (v ~= 0) and v or nil end end)
  teRows[#teRows + 1] = MakeSlider(f, -276, "Y Offset", -400, 400, 2,
    function() local t = TE_Text(); return t and (t.y or 0) end,
    function(v) local t = TE_Text(); if t then t.y = (v ~= 0) and v or nil end end)

  tinsert(UISpecialFrames, "GloomsAurasText")
  f:Hide()
  textFrame = f; RegisterSubWindow(f)
  return f
end

local function OpenTextEditor(id)
  if not id then return end
  if not textFrame then
    local ok, err = pcall(BuildTextEditor)
    if not ok then GA.msg("|cffff5555text editor failed to build|r: " .. tostring(err)); return end
  end
  CloseSubWindows(textFrame)
  DockRight(textFrame)
  textFrame:Show(); textFrame:Raise()
  RefreshTextEditor()   -- after Show so its "only when open" guard passes
end

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
    -- Collapse caret — Jason's bundled triangle PNG (points right = collapsed; rotated
    -- to point down = expanded). Colors baked in → untinted. Shown on header rows only.
    local arrow = row:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(6, 7); arrow:SetPoint("LEFT", 7, 0)   -- small; aspect ~172:193
    arrow:SetTexture(MEDIA .. "triangle.png"); arrow:SetVertexColor(1, 1, 1, 1)
    arrow:Hide(); row.arrow = arrow
    local icon = row:CreateTexture(nil, "ARTWORK"); icon:SetSize(18, 18); icon:SetPoint("LEFT", 18, 0); icon:SetTexCoord(0.08, 0.92, 0.08, 0.92); row.icon = icon
    local name = newText(row, FONT.body, 12, TEXT, "LEFT"); name:SetPoint("LEFT", 40, 0); name:SetPoint("RIGHT", -4, 0); row.name = name
    name:SetWordWrap(false)   -- long names truncate on one line (bounded width), never wrap
    -- Manage gear (group headers only) → Manage Group drawer. Jason's icon (Media/gear.png)
    -- on a faint flat button so it's visible + clickable even before the icon file exists.
    local gear = flatButton(row, 20, 18, COLOR.purple, "", 12); gear:SetBase(0.0)
    gear:SetPoint("RIGHT", -3, 0)
    local gicon = gear:CreateTexture(nil, "OVERLAY"); gicon:SetSize(13, 13); gicon:SetPoint("CENTER")
    gicon:SetTexture(MEDIA .. "settings.png"); gicon:SetVertexColor(1, 1, 1, 1)
    gear:SetScript("OnClick", function() if row.gid then OpenGroupManager(row.gid) end end)
    gear:Hide(); row.gear = gear
    -- Per-aura visibility toggle (aura rows only): Jason's eye icons — unhidden = shown,
    -- hidden = disabled. Toggles cfg.enabled. Right edge of the aura row.
    local eye = flatButton(row, 18, 18, COLOR.purple, "", 12); eye:SetBase(0.0)
    eye:SetPoint("RIGHT", -3, 0)
    local eicon = eye:CreateTexture(nil, "OVERLAY"); eicon:SetSize(14, 14); eicon:SetPoint("CENTER")
    eicon:SetVertexColor(1, 1, 1, 1); eye.icon = eicon
    eye:SetScript("OnClick", function()
      if row.kind ~= "aura" or not row.id then return end
      local id = row.id
      local cfg = DB() and DB()[id]; if not cfg then return end
      cfg.enabled = (cfg.enabled == false)     -- toggle: hidden→shown, shown→hidden
      if GA.CDM then GA.CDM:Discover() end      -- rebind watch set + hide disabled frames
      if GA.Displays and cfg.enabled ~= false and GA.Displays.forced then
        local f = GA.Displays:GetOrCreate(id); if f then f:Show() end  -- re-show while panel open
      end
      RefreshList()
    end)
    eye:Hide(); row.eye = eye
    row:SetScript("OnClick", function(self)
      if self.kind == "aura" then
        SetSelected(self.id)
      elseif self.kind == "group" then
        local g = Groups() and Groups()[self.gid]
        if g then g.collapsed = (not g.collapsed) or nil; RefreshList() end
      elseif self.kind == "ungrouped" then
        GA.db.ungroupedCollapsed = (not GA.db.ungroupedCollapsed) or nil; RefreshList()
      end
    end)
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

  -- Editable aura name (click the title, type, Enter to rename). A plain EditBox
  -- styled like the title; a faint fill on focus signals it's editable. Renaming
  -- updates the left-pane list + the on-screen label (when the label uses the name).
  editorName = CreateFrame("EditBox", nil, editor)
  editorName:SetPoint("TOPLEFT", 10, -2); editorName:SetPoint("RIGHT", -8, 0); editorName:SetHeight(26)
  editorName:SetAutoFocus(false); editorName:SetTextInsets(4, 4, 0, 0)
  setFont(editorName, FONT.title, 18); editorName:SetTextColor(TEXT.r, TEXT.g, TEXT.b)
  -- Always-faint fill so it reads as an editable field (like the Texture path box);
  -- brightens on focus. A small pencil hint on the right reinforces "click to rename".
  local nameBG = editorName:CreateTexture(nil, "BACKGROUND"); nameBG:SetAllPoints()
  nameBG:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.08)
  editorName:SetScript("OnEditFocusGained", function() nameBG:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.18) end)
  editorName:SetScript("OnEditFocusLost", function() nameBG:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.08) end)
  local nameHint = newText(editorName, FONT.body, 11, MUTE, "RIGHT")
  nameHint:SetPoint("RIGHT", -6, 0); nameHint:SetText("click to rename")
  editorName:SetScript("OnEnterPressed", function(self)
    local c = Cfg()
    if c then local txt = self:GetText(); if txt and txt:gsub("%s", "") ~= "" then c.label = txt end end
    self:ClearFocus()
    local c2 = Cfg(); self:SetText((c2 and c2.label) or "")
    RefreshList(); ReapplySelected()
  end)
  editorName:SetScript("OnEscapePressed", function(self) local c = Cfg(); self:SetText((c and c.label) or ""); self:ClearFocus() end)

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

  Header(editor, 12, -434, "Sound & Text")
  local soundBtn = flatButton(editor, 150, 22, COLOR.heroic, "None", 12)
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
  local testBtn = flatButton(editor, 52, 22, COLOR.heroic, "Test", 12)
  testBtn:SetPoint("LEFT", soundBtn, "RIGHT", 8, 0)
  testBtn:SetScript("OnClick", function()
    local c = Cfg(); if c and c.sound and c.sound.file then pcall(PlaySoundFile, c.sound.file, c.sound.channel or "Master") end
  end)
  local textBtn = flatButton(editor, 74, 22, COLOR.heroic, "Text…", 12)
  textBtn:SetPoint("LEFT", testBtn, "RIGHT", 8, 0)
  textBtn:SetScript("OnClick", function() if selectedID then OpenTextEditor(selectedID) end end)
  rows[#rows + 1] = {
    refresh = function() soundBtn:SetText(soundLabel()) end,
    setEnabled = function(_, on) soundBtn:SetEnabled(on); testBtn:SetEnabled(on); textBtn:SetEnabled(on) end,
  }

  -- GROUP section (assign dropdown + on/off switch + load rule + delete) — built in
  -- its own function to keep Build under Lua 5.1's 60-upvalue limit.
  BuildGroupSection(editor)

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
  C._hideCDM = hideCDM   -- so C:OnProfileSwitched can re-sync it (hideBlizzardCDM is per-profile)

  -- Profiles: the active-profile button (bottom-right) opens the Profiles drawer
  -- (switch / new / copy / rename / delete). Label tracks the active profile.
  local profileBtn = flatButton(p, 190, 24, COLOR.purple, "Profile: …", 12)
  profileBtn:SetPoint("BOTTOMRIGHT", -INSET, 31)
  profileBtn:SetScript("OnClick", function() C:OpenProfileManager() end)
  C._profileBtn = profileBtn
  C:UpdateProfileButton()

  local hint = newText(p, FONT.body, 11, MUTE, "CENTER")
  hint:SetPoint("BOTTOM", 0, 12)
  hint:SetText("Drag the title bar to move · drag an aura on screen to place it · blank texture = spell icon")

  p:SetScript("OnShow", function()
    hideCDM:Set(GA.db and GA.db.hideBlizzardCDM)
    C:UpdateProfileButton()
    local pos = GA.global and GA.global.panelPos
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
    CloseSubWindows()   -- close any docked drawer so it doesn't linger/reappear
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
  if not panel or not GA.global then return end
  local px, py = panel:GetCenter()
  local ucx, ucy = UIParent:GetCenter()
  if px and ucx then
    GA.global.panelPos = { math.floor(px - ucx + 0.5), math.floor(py - ucy + 0.5) }
  end
end

function C:Toggle()
  if not panel then
    local ok, err = pcall(Build)
    if not ok then GA.msg("|cffff5555config panel failed to build|r: " .. tostring(err)); return end
  end
  if panel:IsShown() then panel:Hide() else panel:Show() end
end
