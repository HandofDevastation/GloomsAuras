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
local rows = {}
-- Trigger editor state hangs on C._trig (chunk-local cap): { editID, frame, title,
-- logicBtn, rows, offset, ROWS }. See the grouped trigger editor below.

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
local LIST_ROWS = 15   -- leave room for the New/Duplicate/Delete/Group button stack
local LIST_ROW_H = 24

-- Texture blend modes (SetBlendMode) + friendly labels; frame strata choices.
local BLEND_MODES = {
  { "BLEND", "Normal" }, { "ADD", "Add (glow)" }, { "MOD", "Modulate" },
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

local STATE_ORDER = { "buff_active", "buff_inactive", "cd_ready", "cd_oncd", "charges_max", "charges_notmax" }
local STATE_LABEL = {
  buff_active    = "buff is active",
  buff_inactive  = "buff is NOT active",
  cd_ready       = "cooldown is ready",
  cd_oncd        = "cooldown is NOT ready",
  charges_max    = "at max charges",
  charges_notmax = "NOT at max charges",
}
-- Word a condition's state per the leaf's kind: cooldowns stay "cooldown …"; an aura's two
-- buff states become buff (on you) / debuff (on target) / proc, from the picked entry's kind
-- (selfAura + hasAura). Keeps the picker tags and the condition wording aligned.
local function StateLabel(state, k)
  if state == "cd_ready" or state == "cd_oncd"
     or state == "charges_max" or state == "charges_notmax" then return STATE_LABEL[state] or "?" end
  local active = (state == "buff_active")
  if k == "proc" then
    return active and "proc is active" or "proc is NOT active"
  elseif k == "debuff" then
    return active and "debuff is active (on target)" or "debuff is NOT active (on target)"
  else
    return active and "buff is active (on you)" or "buff is NOT active (on you)"
  end
end

-- Trigger state PILL wording (redesign): a bold main part + a regular "(suffix)".
-- e.g. buff_active+debuff → "ACTIVE on Target" , " (Debuff)".
local function TrigPill(state, k)
  if state == "cd_ready" then return "READY", " (Cooldown)"
  elseif state == "cd_oncd" then return "ON COOLDOWN", " (Cooldown)"
  elseif state == "charges_max" then return "AT MAX", " (Charges)"
  elseif state == "charges_notmax" then return "NOT AT MAX", " (Charges)" end
  local active = (state == "buff_active")
  local unit = (k == "debuff") and "Target" or "You"
  local kind = (k == "debuff") and "Debuff" or (k == "proc") and "Proc" or "Buff"
  return (active and "ACTIVE on " or "NOT ACTIVE on ") .. unit, " (" .. kind .. ")"
end

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

-- Flat dark fill only (Figma: solid rgb(6,7,20), no texture, no border).
local function skinPlate(f)
  local base = f:CreateTexture(nil, "BACKGROUND")
  base:SetAllPoints(); base:SetColorTexture(COLOR.dark.r, COLOR.dark.g, COLOR.dark.b, COLOR.dark.a or 1)
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

-- Two-weight inline label: a Regular-weight prefix + a Semibold value, centered as a
-- group inside `parent`. The "Profile: ‹Name›" convention (Regular label + Semibold value)
-- recurs across buttons/headers, so it lives here. :Set(prefix, value) re-lays it out.
-- swap=true puts the Semibold part first (used by the trigger state pills:
-- "ACTIVE on Target" bold + " (Debuff)" regular).
local function twoWeightLabel(parent, size, cc, swap)
  cc = cc or { r = 1, g = 1, b = 1 }
  local pre = newText(parent, swap and FONT.label or FONT.body,  size, cc, "LEFT")
  local val = newText(parent, swap and FONT.body  or FONT.label, size, cc, "LEFT")
  local h = { pre = pre, val = val }
  function h:Set(prefix, value)
    pre:SetText(prefix or ""); val:SetText(value or "")
    local total = (pre:GetStringWidth() or 0) + 4 + (val:GetStringWidth() or 0)
    pre:ClearAllPoints(); pre:SetPoint("LEFT", parent, "CENTER", -total / 2, 0)
    val:ClearAllPoints(); val:SetPoint("LEFT", pre, "RIGHT", 4, 0)
  end
  return h
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
  if cfg and cfg.spellID then
    return "|cff888888none — shows on its own spell's state|r"
  end
  return "|cff888888none — always shown (decoration)|r"
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
-- Redesign slider (Figma): [label] [− pill] [track] [+ pill] [value box], 20px row.
-- label = General Sans 12 white; −/+ = heroic-50% pills w/ Khand "−"/"+"; track =
-- heroic-20% 166×6 with a 4×20 PURPLE thumb; value box = heroic-8% fill, centred.
-- Positions match the mock at a ~360-wide parent. "Alpha %" shows a % in its box.
local function MakeSlider(parent, yOff, label, minV, maxV, step, get, set)
  local H = COLOR.heroic
  local suffix = label:find("%%") and "%" or ""

  local title = newText(parent, FONT.body, 12, TEXT, "LEFT")
  title:SetPoint("LEFT", parent, "TOPLEFT", 4, yOff - 10); title:SetText(label)

  local minus = flatButton(parent, 20, 20, H, "−", 16); minus:SetBase(0.5)
  minus:SetPoint("TOPLEFT", 70, yOff); setFont(minus.text, FONT.head, 16)

  local slider
  pcall(function() slider = CreateFrame("Slider", nil, parent) end)
  if slider then
    slider:SetOrientation("HORIZONTAL"); slider:SetSize(166, 20)
    slider:SetPoint("TOPLEFT", 100, yOff); slider:SetHitRectInsets(0, 0, -6, -6)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0); track:SetPoint("RIGHT", 0, 0); track:SetHeight(6)
    track:SetColorTexture(H.r, H.g, H.b, 0.20)
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1); thumb:SetSize(4, 20)
    slider:SetThumbTexture(thumb)
    slider:SetMinMaxValues(minV, maxV); slider:SetValueStep(step); slider:SetObeyStepOnDrag(true)
  end

  local plus = flatButton(parent, 20, 20, H, "+", 16); plus:SetBase(0.5)
  plus:SetPoint("TOPLEFT", 276, yOff); setFont(plus.text, FONT.head, 16)

  local edit = CreateFrame("EditBox", nil, parent)
  edit:SetSize(54, 20); edit:SetPoint("TOPLEFT", 306, yOff); edit:SetAutoFocus(false)
  setFont(edit, FONT.body, 11); edit:SetTextColor(1, 1, 1); edit:SetJustifyH("CENTER"); edit:SetTextInsets(2, 2, 0, 0)
  local ebg = edit:CreateTexture(nil, "BACKGROUND"); ebg:SetAllPoints(); ebg:SetColorTexture(H.r, H.g, H.b, 0.08)

  local applying = false
  local function clamp(v) return math.max(minV, math.min(maxV, math.floor(v + 0.5))) end
  local function show(v) edit:SetText(tostring(v) .. suffix); edit:SetCursorPosition(0) end
  local function apply(v)
    v = clamp(v); applying = true
    if slider then slider:SetValue(v) end
    show(v); applying = false
    set(v); ReapplySelected()
  end
  if slider then slider:SetScript("OnValueChanged", function(_, v) if not applying then apply(v) end end) end
  edit:SetScript("OnEnterPressed", function(self) local v = tonumber((self:GetText() or ""):match("%-?%d+")); if v then apply(v) end self:ClearFocus() end)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  minus:SetScript("OnClick", function() apply((get() or minV) - step) end)
  plus:SetScript("OnClick",  function() apply((get() or minV) + step) end)

  local row = {}
  function row:refresh() local v = clamp(get() or minV); applying = true; if slider then slider:SetValue(v) end; show(v); applying = false end
  function row:setEnabled(on) if slider then slider:SetEnabled(on) end edit:SetEnabled(on); minus:SetEnabled(on); plus:SetEnabled(on) end
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
  c:SetSize(20, 20)   -- Figma: 20px box, white 10% fill, orange ✓, no border
  local box = c:CreateTexture(nil, "ARTWORK"); box:SetAllPoints(); box:SetColorTexture(1, 1, 1, 0.10)
  -- Jason's checkmark_white.png fills the 20x20 box (its canvas = the Figma node), tinted orange.
  c.mark = c:CreateTexture(nil, "OVERLAY"); c.mark:SetAllPoints()
  c.mark:SetTexture(MEDIA .. "checkmark_white.png")
  c.mark:SetVertexColor(COLOR.orange.r, COLOR.orange.g, COLOR.orange.b, 1); c.mark:Hide()
  c.label = newText(c, FONT.body, 12, TEXT, "LEFT"); c.label:SetPoint("LEFT", c, "RIGHT", 8, 0); c.label:SetText(label)
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

-- Single on/off toggle (Figma): a 40x20 white-10% track + a 20x20 purple knob that
-- slides (left=off, right=on). Caller places it + adds its own label; get/set drive state.
local function makeToggle(parent, get, set)
  local t = CreateFrame("Button", nil, parent); t:SetSize(40, 20)
  local track = t:CreateTexture(nil, "BACKGROUND"); track:SetAllPoints(); track:SetColorTexture(1, 1, 1, 0.1)
  local knob = t:CreateTexture(nil, "ARTWORK"); knob:SetSize(20, 20)
  knob:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1)
  function t:refresh() knob:ClearAllPoints(); knob:SetPoint(get() and "RIGHT" or "LEFT", 0, 0) end
  t:SetScript("OnClick", function() set(not get()); t:refresh() end)
  t:refresh()
  return t
end

-- Colour control: [✓ <label>] + a swatch. Clicking either opens the game
-- ColorPickerFrame; unchecking clears the colour (set(nil)). Label defaults to
-- "Tint" (reused for the glow drawer's "Custom Color").
local function MakeColor(parent, x, yOff, get, set, label)
  local chk = flatCheck(parent, label or "Tint")
  chk:SetPoint("TOPLEFT", x, yOff)
  local swatch = CreateFrame("Button", nil, parent); swatch:SetSize(29, 20)   -- Figma: 29x20 solid
  swatch:SetPoint("LEFT", chk.label, "RIGHT", 8, 0)
  local sw = swatch:CreateTexture(nil, "ARTWORK"); sw:SetAllPoints()

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
-- Redesign dropdown (Figma): a heroic-50% pill (28px tall) with a centred two-weight
-- label — Regular "Prefix:" + Semibold value — opening a list below.
local function MakeDropdown(parent, x, yOff, w, prefix, values, get, set)
  local H = COLOR.heroic
  prefix = (prefix or ""):gsub("%s+$", "")
  local b = flatButton(parent, w, 28, H, "", 11); b:SetBase(0.5); b:SetPoint("TOPLEFT", x, yOff)
  b.text:Hide()
  local lbl = twoWeightLabel(b, 11)
  local function curLabel() local cur = get(); for _, v in ipairs(values) do if v[1] == cur then return v[2] end end return values[1][2] end
  local function refreshLabel() lbl:Set(prefix, curLabel()) end
  local menu = CreateFrame("Frame", nil, parent)
  menu:SetSize(w, #values * 22 + 8)
  menu:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
  menu:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)  -- draw above the rows below
  skinPlate(menu); addEdges(menu, COLOR.rim, 1); menu:Hide()
  for i, v in ipairs(values) do
    local item = flatButton(menu, w - 8, 20, H, v[2], 12); item:SetBase(0.12)
    item:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22)
    item:SetScript("OnClick", function()
      menu:Hide(); openDropdownMenu = nil
      set(v[1]); refreshLabel(); ReapplySelected()
    end)
  end
  b:SetScript("OnClick", function()
    if menu:IsShown() then menu:Hide(); openDropdownMenu = nil
    else
      if openDropdownMenu and openDropdownMenu ~= menu then openDropdownMenu:Hide() end
      menu:Show(); openDropdownMenu = menu
    end
  end)
  refreshLabel()
  local row = {}
  function row:refresh() refreshLabel() end
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
      -- Show what the aura LOOKS like: its own texture first (appearance-first model),
      -- else its tracked spell's icon (legacy auras with no custom texture), else a fallback.
      local icon = (cfg and cfg.texture)
        or (cfg and cfg.spellID and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(cfg.spellID))
        or 134400
      row.icon:SetTexture(icon)
      if row.eye then
        row.eye:Show()
        -- Eye = show THIS aura on screen while the panel is open (editor preview only).
        local prev = cfg and cfg.preview
        row.eye.icon:SetTexture(MEDIA .. (prev and "unhidden.png" or "hidden.png"))
      end
      row.name:ClearAllPoints(); row.name:SetPoint("LEFT", 40, 0); row.name:SetPoint("RIGHT", -24, 0)
      row.name:SetText((cfg and cfg.label) or ("Spell " .. tostring(sid)))
      local dim = cfg and cfg.enabled == false   -- disabled in-game (Visibility → Disabled) greys the row
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
  if C._trig then C._trig.editID = sid end   -- inline Trigger section edits the selected aura
  if GA.Displays then GA.Displays:SetSelectedDisplay(sid) end  -- only this one is draggable
  local cfg = Cfg()
  if editorName then
    if cfg then editorName:SetText(cfg.label or tostring(sid)); editorName:SetCursorPosition(0); editorName:Enable()
    else editorName:SetText(""); editorName:ClearFocus(); editorName:Disable() end
  end
  if triggerSummary then triggerSummary:SetText(cfg and SummaryText(cfg) or "") end
  if visibilitySummary then visibilitySummary:SetText(cfg and VisibilitySummary(cfg) or "") end
  for _, r in ipairs(rows) do r:refresh(); r:setEnabled(cfg ~= nil) end
  if C.RefreshTextEditor then C:RefreshTextEditor() end   -- text drawer follows selection (self-guards to when open)
  if C.RefreshGlowEditor then C:RefreshGlowEditor() end   -- glow drawer follows selection too
  if C.RefreshGroupButton then C:RefreshGroupButton() end -- left-pane Group button label
  if C.TrigInlineRender then C:TrigInlineRender() end     -- inline Trigger section follows selection
  if C.UpdateNameHint then C:UpdateNameHint() end          -- hide "CLICK TO RENAME" under a long name
  RefreshList()
  if GA.Displays then GA.Displays:RefreshForced() end   -- preview: show the selected + eye-on, hide the rest
end

-- Back-door for building/QAing Bar displays before the type-aware editor exists (the polished
-- bar UI is coming from Jason's Figma pass — see docs/BARS-DESIGN.md). `/ga bar <spellID>` makes
-- a new Aura-Duration bar bound to a spell that's placed in the Cooldown Manager (Tracked Bars /
-- Buffs). Reuses the whole display pipeline: cfg.spellID drives show/hide via the normal auto-path;
-- kind="bar" only swaps the rendering + adds the duration feed.
function C:AddBar(arg)
  local db = DB()
  if not db then GA.msg("no active profile yet — open the panel first."); return end
  -- Parse: "[stacks] <spellID> [max]".  No keyword ⇒ aura_dur (a duration timer).
  local tokens = {}
  for t in tostring(arg or ""):gmatch("%S+") do tokens[#tokens + 1] = t end
  local mode, sidTok, maxTok = "aura_dur", tokens[1], nil
  if tokens[1] == "stacks" then mode, sidTok, maxTok = "stacks", tokens[2], tokens[3]
  elseif tokens[1] == "cd" or tokens[1] == "cooldown" then mode, sidTok = "cd_dur", tokens[2] end
  local sid = tonumber(sidTok and sidTok:match("%d+"))
  if not sid then
    GA.msg("usage: |cffffd200/ga bar <spellID>|r (aura duration)  •  |cffffd200/ga bar cd <spellID>|r (cooldown)  •  |cffffd200/ga bar stacks <spellID> [max]|r (stacks)")
    return
  end
  local nm = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)) or ("Bar " .. sid)
  local barcfg = { mode = mode }
  if mode == "stacks" then
    barcfg.max = tonumber(maxTok and maxTok:match("%d+")) or 10
    barcfg.showValue = true                          -- show the live count number on the bar
  end
  local id = NewDisplayID()
  db[id] = {
    kind = "bar", spellID = sid, label = nm, enabled = true,
    width = 220, height = 24, point = { "CENTER", 0, -120 }, alpha = 1, showLabel = true,
    bar = barcfg,
  }
  if GA.CDM then GA.CDM:Discover() end
  if panel then SetSelected(id) end
  if mode == "stacks" then
    GA.msg(("created a STACKS Bar for |cffffd200%s|r (%d, max %d). It fills with the aura's stack count. Move it with the panel or |cffffd200/ga pos %s x y|r.")
      :format(tostring(nm), sid, barcfg.max, id))
  elseif mode == "cd_dur" then
    GA.msg(("created a COOLDOWN Bar for |cffffd200%s|r (%d). It shows while the spell is on cooldown and drains as it comes back up. Move it with the panel or |cffffd200/ga pos %s x y|r.")
      :format(tostring(nm), sid, id))
  else
    GA.msg(("created a Bar for |cffffd200%s|r (%d). It shows while that aura is on you/your target and drains with its duration. Move it with the panel or |cffffd200/ga pos %s x y|r.")
      :format(tostring(nm), sid, id))
  end
end

-- --------------------------------------------------------------------------
-- Aura picker: a scrollable list of the CDM registry (icon + name); click to
-- add a display. Scrolls with the mouse wheel (no scrollbar thumb to drag).
-- --------------------------------------------------------------------------
local PICK_ROWS = 12
local PICK_ROW_H = 24
local PICK_COL_W = 208               -- width of each of the two columns
-- Two-panel picker state, hung on C to stay under Config.lua's chunk-local cap: a Cooldowns
-- column + a Buffs/Debuffs column, each filtered by the shared search and scrolled on its own.
C._pick = { cd = { rows = {}, data = {}, offset = 0 }, au = { rows = {}, data = {}, offset = 0 },
            allCd = {}, allAu = {}, search = "" }

-- Build the two source lists from the CDM's SETTINGS DATA PROVIDER — the exact ORDERED,
-- displayed cooldownID set each viewer lays out (CooldownViewer.lua RefreshLayout calls
-- `CooldownViewerSettings:GetDataProvider():GetOrderedCooldownIDsForCategory(cat)`). This is the
-- authoritative "trackable" set and the right source for THREE reasons the alternatives got wrong:
--   1. FRAME-INDEPENDENT — a frame clears its cooldownID the instant it's released/hidden
--      (Blizzard's itemFramePool reset callback → ClearCooldownID → cooldownInfo=nil), and the
--      Essential viewer hides items while inactive (`hideWhenInactive`); so a frame-scan dropped
--      every ready-out-of-combat Essential cooldown (Rapid Fire, Aimed Shot, …).
--   2. Respects the SAVED LAYOUT + Blizzard's HideByDefault→Hidden remap + isKnown — so it lists
--      exactly what's displayed. The raw `GetCooldownViewerCategorySet` does NONE of that: it
--      returns raw pre-remap IDs, which under-returned the tracked buffs, and pairing it with a
--      manual HideByDefault filter then dropped known buffs the user DOES display (Lock and Load,
--      Trueshot, Aspects — anything HideByDefault-by-default but placed into a tracked category).
-- Essential/Utility → Cooldowns column; TrackedBuff/TrackedBar → Buffs/Debuffs (tagged Buff vs
-- Debuff via `selfAura`: true = on you, false/nil = on target). Each item carries its default
-- trigger `state` + semantic `k`, so the column you pick from sets the right condition + wording.
-- Rebuilt on every open. Falls back to the raw category set (with our own isKnown + HideByDefault
-- filtering) only if the data provider is somehow unavailable.
local function BuildAuraLists()
  wipe(C._pick.allCd); wipe(C._pick.allAu)
  local E = Enum and Enum.CooldownViewerCategory
  if not E then return end
  local dp = CooldownViewerSettings and CooldownViewerSettings.GetDataProvider
             and CooldownViewerSettings:GetDataProvider()
  local HIDE = Enum.CooldownSetSpellFlags and Enum.CooldownSetSpellFlags.HideByDefault
  local seen = {}
  local cats = {
    { E.Essential, "cd" }, { E.Utility, "cd" },
    { E.TrackedBuff, "au" }, { E.TrackedBar, "au" },
  }
  for _, c in ipairs(cats) do
    local cat, bucket = c[1], c[2]
    -- Primary: the viewer's own ordered/displayed list (already isKnown- + HideByDefault-filtered).
    local ids, viaDP = nil, false
    if dp and dp.GetOrderedCooldownIDsForCategory then
      pcall(function() ids = dp:GetOrderedCooldownIDsForCategory(cat, false); viaDP = true end)
    end
    -- Fallback: raw category set (we filter unlearned + HideByDefault ourselves below).
    if type(ids) ~= "table" and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
      viaDP = false
      pcall(function() ids = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true) end)
    end
    if type(ids) == "table" then
      for _, id in ipairs(ids) do
        if id ~= nil and not issecret(id) then
          local info
          if dp and dp.GetCooldownInfoForID then pcall(function() info = dp:GetCooldownInfoForID(id) end) end
          if not info and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
            pcall(function() info = C_CooldownViewer.GetCooldownViewerCooldownInfo(id) end)
          end
          local sid = info and info.spellID
          -- Only the fallback (raw set) path needs manual filtering; the DP list is pre-filtered.
          local skip = false
          if not viaDP and info then
            if info.isKnown == false then skip = true end
            local fl = info.flags
            if HIDE and fl ~= nil and not issecret(fl) and FlagsUtil and FlagsUtil.IsSet
               and FlagsUtil.IsSet(fl, HIDE) then skip = true end
          end
          if sid and not issecret(sid) and not skip then
            local k, tag = "cooldown", nil
            if bucket == "au" then
              -- selfAura is the reliable axis: true = on you (buff), false/nil = on target (debuff).
              -- (hasAura is NOT a reliable proc signal — it also flags cooldown-granted buffs like
              -- Aspect of the Turtle — so we don't tag procs separately.)
              local sa = info.selfAura
              local isBuff = (sa ~= nil and not issecret(sa) and sa == true)
              k   = isBuff and "buff" or "debuff"
              tag = isBuff and "Buff" or "Debuff"
            end
            local key = bucket .. ":" .. sid .. ":" .. k
            if not seen[key] then
              seen[key] = true
              local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)) or ("Spell " .. sid)
              local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
              local item = { spellID = sid, name = name, icon = icon,
                state = (bucket == "cd") and "cd_ready" or "buff_active", k = k, tag = tag }
              if bucket == "cd" then C._pick.allCd[#C._pick.allCd + 1] = item
              else C._pick.allAu[#C._pick.allAu + 1] = item end
            end
          end
        end
      end
    end
  end
end

local function RefreshPicker()
  local q = (C._pick.search or ""):lower()
  local trackH = PICK_ROWS * PICK_ROW_H
  for _, key in ipairs({ "cd", "au" }) do
    local p = C._pick[key]
    wipe(p.data)
    for _, it in ipairs((key == "cd") and C._pick.allCd or C._pick.allAu) do
      if q == "" or (it.name and it.name:lower():find(q, 1, true)) then p.data[#p.data + 1] = it end
    end
    local n = #p.data
    local maxOff = math.max(0, n - PICK_ROWS)
    if p.offset > maxOff then p.offset = maxOff end
    if p.offset < 0 then p.offset = 0 end
    for i = 1, PICK_ROWS do
      local row, item = p.rows[i], p.data[i + p.offset]
      if row then
        if item then
          row.item = item
          row.icon:SetTexture(item.icon or 134400)
          row.text:SetText(item.tag and ("%s  |cff888888(%s)|r"):format(item.name, item.tag) or item.name)
          row:Show()
        else
          row.item = nil; row:Hide()
        end
      end
    end
    if p.thumb and p.track then
      if n <= PICK_ROWS then
        p.thumb:Hide()
      else
        p.thumb:Show()
        local thumbH = math.max(24, trackH * (PICK_ROWS / n))
        p.thumb:SetHeight(thumbH)
        p.thumb:ClearAllPoints()
        p.thumb:SetPoint("TOP", p.track, "TOP", 0, -(trackH - thumbH) * (p.offset / maxOff))
      end
    end
  end
end

local function BuildPicker()
  local GAP = 14
  local colX = { cd = GAP, au = GAP + PICK_COL_W + GAP }
  local ROWS_TOP = -104
  local W = GAP + PICK_COL_W + GAP + PICK_COL_W + GAP
  local H = -ROWS_TOP + PICK_ROWS * PICK_ROW_H + 28
  local f = CreateFrame("Frame", "GloomsAurasPicker", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(true)
  skinPlate(f)

  local title = newText(f, FONT.title, 18, COLOR.purple, "CENTER")
  title:SetPoint("TOP", 0, -12); title:SetText("Choose a spell to track")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)

  -- Movable title bar (standard hold-drag).
  f:SetMovable(true); f:SetClampedToScreen(true)
  local ptb = CreateFrame("Frame", nil, f)
  ptb:SetPoint("TOPLEFT", 2, -2); ptb:SetPoint("TOPRIGHT", -34, -2); ptb:SetHeight(28)
  ptb:EnableMouse(true); ptb:RegisterForDrag("LeftButton")
  ptb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
  ptb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  -- Search box (filters BOTH columns by name).
  local sb = flatEditBox(f, W - 2 * GAP, 22); sb:SetPoint("TOPLEFT", GAP, -46)
  sb:SetScript("OnTextChanged", function(self) C._pick.search = self:GetText() or ""; RefreshPicker() end)
  sb:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
  local sl = newText(f, FONT.body, 11, MUTE, "LEFT"); sl:SetPoint("BOTTOMLEFT", sb, "TOPLEFT", 2, 3); sl:SetText("Search")

  -- Two columns: Cooldowns (cd) + Buffs & Debuffs (au). Each is a mouse-wheel container
  -- whose child rows propagate the wheel up to it, so each column scrolls independently.
  local headers = { cd = "Cooldowns", au = "Buffs & Debuffs" }
  for _, key in ipairs({ "cd", "au" }) do
    local p, x = C._pick[key], colX[key]
    local hdr = newText(f, FONT.title, 13, COLOR.purple, "LEFT")
    hdr:SetPoint("TOPLEFT", x, -84); hdr:SetText(headers[key])

    local col = CreateFrame("Frame", nil, f)
    col:SetPoint("TOPLEFT", x, ROWS_TOP); col:SetSize(PICK_COL_W, PICK_ROWS * PICK_ROW_H)
    col:EnableMouseWheel(true)
    col:SetScript("OnMouseWheel", function(_, delta) p.offset = p.offset - delta; RefreshPicker() end)

    local track = col:CreateTexture(nil, "ARTWORK"); track:SetColorTexture(1, 1, 1, 0.08)
    track:SetPoint("TOPRIGHT", 0, 0); track:SetSize(6, PICK_ROWS * PICK_ROW_H); p.track = track
    p.thumb = col:CreateTexture(nil, "OVERLAY"); p.thumb:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 1)
    p.thumb:SetWidth(6); p.thumb:SetPoint("TOP", track, "TOP")

    for i = 1, PICK_ROWS do
      local row = CreateFrame("Button", nil, col)
      row:SetSize(PICK_COL_W - 12, 22); row:SetPoint("TOPLEFT", 0, -(i - 1) * PICK_ROW_H)
      local hl = row:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.20)
      local icon = row:CreateTexture(nil, "ARTWORK"); icon:SetSize(18, 18); icon:SetPoint("LEFT", 2, 0); row.icon = icon
      local text = newText(row, FONT.body, 12, TEXT, "LEFT"); text:SetPoint("LEFT", 24, 0); text:SetPoint("RIGHT", -4, 0); row.text = text
      row:SetScript("OnClick", function(self)
        local item = self.item; if not item then return end
        if pickerOnPick then                 -- picking for a trigger condition
          local cb = pickerOnPick; pickerOnPick = nil
          f:Hide(); cb(item)
        end
      end)
      p.rows[i] = row
    end
  end

  local footer = newText(f, FONT.body, 11, MUTE, "CENTER")
  footer:SetPoint("BOTTOM", 0, 8); footer:SetText("mouse-wheel a column to scroll")

  f:SetScript("OnShow", function()
    BuildAuraLists()
    C._pick.search = ""; if sb then sb:SetText("") end
    C._pick.cd.offset = 0; C._pick.au.offset = 0
    RefreshPicker()
  end)
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
  CloseSubWindows(pickerFrame, onPick and C._trig.frame or nil)
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
-- Trigger editor: one-level GROUPED boolean logic. cfg.trigger =
--   { logic, conditions = { <leaf> | <group>, ... } }
-- leaf  = { spellID, state, name };  group = { logic, conditions = { <leaf>, ... } }.
-- logic ∈ AND (all) / OR (any) / NONE (nor = NOT any). Groups nest ONE level in the
-- UI (the engine recurses regardless). State/functions hang on C._trig to keep
-- Config.lua under Lua's 200-locals-per-chunk cap.
-- --------------------------------------------------------------------------
C._trig = { rows = {}, offset = 0, ROWS = 9 }

function C:LogicLabel(l)
  if l == "OR" then return "Match Any (OR)"
  elseif l == "NONE" then return "Match None (NOR)"
  else return "Match All (AND)" end
end
function C:LogicNext(l)
  if l == "OR" then return "NONE" elseif l == "NONE" then return "AND" else return "OR" end
end

function C:TrigCfg() return C._trig.editID and DB() and DB()[C._trig.editID] end
function C:TrigTree()
  local cfg = self:TrigCfg(); if not cfg then return nil end
  cfg.trigger = cfg.trigger or { logic = "AND", conditions = {} }
  return cfg.trigger
end
-- The node at a path: (ti) = top item (leaf or group); (ti, ci) = a group's child leaf.
function C:TrigNode(ti, ci)
  local t = self:TrigTree(); if not t then return nil end
  local top = t.conditions[ti]; if not top then return nil end
  if ci then return top.conditions and top.conditions[ci] end
  return top
end

function C:TrigRebind()   -- watch set changed → rebind spells, then re-render
  if GA.CDM then GA.CDM:Discover() end
  self:TrigRender()
end

function C:TrigAddLeaf(item, ti)
  local t = self:TrigTree(); if not t then return end
  if type(item) == "number" then item = { spellID = item } end   -- back-compat / safety
  local spellID = item.spellID; if not spellID then return end
  local list = (ti and t.conditions[ti] and t.conditions[ti].conditions) or t.conditions
  local state = item.state
  if not state then                                              -- fell through without a picked column
    local kind = GA.CDM and GA.CDM.kind and GA.CDM.kind[spellID]
    state = (kind == "cooldown") and "cd_ready" or "buff_active"
  end
  local name = item.name or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
  local leaf = { spellID = spellID, state = state, name = name }
  if item.k then leaf.k = item.k end                             -- buff/debuff/proc → wording
  table.insert(list, leaf)
  self:TrigRebind()
end
function C:TrigAddGroup()
  local t = self:TrigTree(); if not t then return end
  table.insert(t.conditions, { logic = "OR", conditions = {} })   -- OR is the usual reason to group
  self:TrigRender()   -- empty group: no watch-set change yet
end
function C:TrigRemove(ti, ci)
  local t = self:TrigTree(); if not t then return end
  if ci then
    local grp = t.conditions[ti]
    if grp and grp.conditions then table.remove(grp.conditions, ci) end
  else
    table.remove(t.conditions, ti)   -- a group removes with its conditions
  end
  self:TrigRebind()
end
function C:TrigCycleState(ti, ci)
  local leaf = self:TrigNode(ti, ci); if not leaf or not leaf.state then return end
  -- Cycle within the leaf's own FAMILY (never let a debuff become a nonsensical "cooldown ready"):
  --  • aura     → active <-> inactive
  --  • cooldown → ready <-> on-cd, and for a CHARGE spell also at-max <-> not-at-max charges
  --    (the charge states are only reachable on a spell that actually uses charges).
  local cdStates = (leaf.state == "cd_ready" or leaf.state == "cd_oncd"
                    or leaf.state == "charges_max" or leaf.state == "charges_notmax")
  local list
  if cdStates then
    local isCharge = GA.CDM and GA.CDM.isCharge and GA.CDM.isCharge[leaf.spellID]
    list = isCharge and { "cd_ready", "cd_oncd", "charges_max", "charges_notmax" }
                     or { "cd_ready", "cd_oncd" }
  else
    list = { "buff_active", "buff_inactive" }
  end
  local idx = 1
  for i, s in ipairs(list) do if s == leaf.state then idx = i; break end end
  leaf.state = list[(idx % #list) + 1]   -- advance, wrapping
  if GA.CDM then GA.CDM:RefreshDisplays() end
  self:TrigRender()
end
function C:TrigCycleLogic(ti)
  local t = self:TrigTree(); if not t then return end
  local node = ti and t.conditions[ti] or t
  node.logic = self:LogicNext(node.logic)
  if GA.CDM then GA.CDM:RefreshDisplays() end
  self:TrigRender()
end

-- Flatten the tree into render descriptors: leaf | ghead | gleaf | gadd.
function C:TrigEntries()
  local out, t = {}, self:TrigTree()
  if not t then return out end
  for ti, node in ipairs(t.conditions) do
    if node.conditions then
      out[#out + 1] = { kind = "ghead", ti = ti }
      for ci in ipairs(node.conditions) do out[#out + 1] = { kind = "gleaf", ti = ti, ci = ci } end
      out[#out + 1] = { kind = "gadd", ti = ti }
    else
      out[#out + 1] = { kind = "leaf", ti = ti }
    end
  end
  return out
end

function C:RenderTrigRow(row, e)
  row.kind, row.ti, row.ci = nil, nil, nil
  if not e then row:Hide(); return end
  row.kind, row.ti, row.ci = e.kind, e.ti, e.ci
  row.bracket:SetShown(e.kind ~= "leaf")   -- bracket on group rows only
  if e.kind == "leaf" or e.kind == "gleaf" then
    local indented = (e.kind == "gleaf")
    local leaf = self:TrigNode(e.ti, e.ci)
    row.icon:ClearAllPoints(); row.icon:SetPoint("LEFT", indented and 20 or 2, 0); row.icon:Show()
    local ic = leaf and leaf.spellID and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(leaf.spellID)
    row.icon:SetTexture(ic or 134400)
    row.name:ClearAllPoints(); row.name:SetPoint("LEFT", indented and 46 or 28, 0); row.name:SetWidth(indented and 96 or 114)
    row.name:SetText((leaf and (leaf.name or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(leaf.spellID)))) or tostring(leaf and leaf.spellID or "?"))
    row.name:SetTextColor(TEXT.r, TEXT.g, TEXT.b); row.name:Show()
    row.mid:SetText(StateLabel(leaf and leaf.state, leaf and leaf.k)); row.mid:Show()
    row.rem:Show(); row.add:Hide()
  elseif e.kind == "ghead" then
    local grp = self:TrigNode(e.ti)
    row.icon:Hide()
    row.name:ClearAllPoints(); row.name:SetPoint("LEFT", 20, 0); row.name:SetWidth(120)
    row.name:SetText("GROUP"); row.name:SetTextColor(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b); row.name:Show()
    row.mid:SetText(self:LogicLabel(grp and grp.logic)); row.mid:Show()
    row.rem:Show(); row.add:Hide()
  else  -- gadd
    row.icon:Hide(); row.name:Hide(); row.mid:Hide(); row.rem:Hide()
    row.addText:SetTextColor(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b)
    row.add:Show()
  end
  row:Show()
end

function C:TrigRender()
  if C.TrigInlineRender then C:TrigInlineRender() end   -- inline accordion section (redesign)
  if not C._trig.frame then return end
  local cfg = self:TrigCfg(); if not cfg then return end
  local t = self:TrigTree()
  C._trig.title:SetText("Trigger: " .. (cfg.label or tostring(C._trig.editID)))
  C._trig.logicBtn:SetText(self:LogicLabel(t.logic))
  local entries = self:TrigEntries()
  local maxOff = math.max(0, #entries - C._trig.ROWS)
  if C._trig.offset > maxOff then C._trig.offset = maxOff end
  if C._trig.offset < 0 then C._trig.offset = 0 end
  for i = 1, C._trig.ROWS do
    self:RenderTrigRow(C._trig.rows[i], entries[i + C._trig.offset])
  end
  if triggerSummary and C._trig.editID == selectedID then triggerSummary:SetText(SummaryText(cfg)) end
end

function C:BuildTriggerEditor()
  local W, H = 388, 384
  local f = CreateFrame("Frame", "GloomsAurasTrigger", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true); f:EnableMouseWheel(true)
  skinPlate(f)
  C._trig.title = newText(f, FONT.title, 18, COLOR.purple, "CENTER"); C._trig.title:SetPoint("TOP", 0, -12); C._trig.title:SetText("Trigger")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12); close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)
  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2); tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end); tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  C._trig.logicBtn = flatButton(f, 150, 22, COLOR.purple, "Match All (AND)", 12)
  C._trig.logicBtn:SetPoint("TOPLEFT", 16, -40)
  C._trig.logicBtn:SetScript("OnClick", function() C:TrigCycleLogic(nil) end)
  local lh = newText(f, FONT.body, 11, MUTE, "LEFT"); lh:SetPoint("LEFT", C._trig.logicBtn, "RIGHT", 8, 0); lh:SetText("how the rows below combine")

  f:SetScript("OnMouseWheel", function(_, d) C._trig.offset = C._trig.offset - d; C:TrigRender() end)

  for i = 1, C._trig.ROWS do
    local row = CreateFrame("Frame", nil, f); row:SetSize(354, 24); row:SetPoint("TOPLEFT", 16, -70 - (i - 1) * 26)
    local bracket = row:CreateTexture(nil, "ARTWORK"); bracket:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.5)
    bracket:SetPoint("TOPLEFT", 4, 3); bracket:SetSize(2, 26); row.bracket = bracket
    local icon = row:CreateTexture(nil, "ARTWORK"); icon:SetSize(20, 20); icon:SetPoint("LEFT", 2, 0); row.icon = icon
    local name = newText(row, FONT.body, 12, TEXT, "LEFT"); name:SetPoint("LEFT", 28, 0); name:SetWidth(114); name:SetWordWrap(false); row.name = name
    local mid = flatButton(row, 152, 20, COLOR.heroic, "", 11); mid:SetPoint("LEFT", 154, 0); row.mid = mid
    mid:SetScript("OnClick", function()
      if row.kind == "ghead" then C:TrigCycleLogic(row.ti)
      elseif row.kind == "leaf" or row.kind == "gleaf" then C:TrigCycleState(row.ti, row.ci) end
    end)
    local rem = flatButton(row, 22, 20, COLOR.orange, "X", 12); rem:SetPoint("RIGHT", 0, 0); row.rem = rem
    rem:SetScript("OnClick", function()
      if row.kind == "leaf" or row.kind == "ghead" then C:TrigRemove(row.ti, nil)
      elseif row.kind == "gleaf" then C:TrigRemove(row.ti, row.ci) end
    end)
    -- "+ Add to group" is a purple TEXT LINK (not a full button) so the grouped
    -- rows don't read as a wall of buttons; it brightens to white on hover.
    local add = CreateFrame("Button", nil, row); add:SetSize(120, 18); add:SetPoint("LEFT", 46, 0); row.add = add
    row.addText = newText(add, FONT.bodyM, 12, COLOR.purple, "LEFT"); row.addText:SetPoint("LEFT", 0, 0); row.addText:SetText("+ Add to group")
    add:SetFontString(row.addText)
    add:SetScript("OnEnter", function() row.addText:SetTextColor(1, 1, 1) end)
    add:SetScript("OnLeave", function() row.addText:SetTextColor(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b) end)
    add:SetScript("OnClick", function() local ti = row.ti; OpenPicker(function(item) C:TrigAddLeaf(item, ti) end) end)
    row:Hide()
    C._trig.rows[i] = row
  end

  local addC = flatButton(f, 140, 24, COLOR.purple, "+ Add Condition", 12)
  addC:SetPoint("BOTTOMLEFT", 16, 44)
  addC:SetScript("OnClick", function() OpenPicker(function(item) C:TrigAddLeaf(item, nil) end) end)
  local addG = flatButton(f, 120, 24, COLOR.heroic, "+ Add Group", 12)
  addG:SetPoint("LEFT", addC, "RIGHT", 8, 0)
  addG:SetScript("OnClick", function() C:TrigAddGroup() end)

  local ah = newText(f, FONT.body, 11, MUTE, "CENTER"); ah:SetWidth(W - 32); ah:SetPoint("BOTTOM", 0, 14)
  ah:SetText("No conditions = shows on its own state · click a state or logic label to change it")

  f:SetScript("OnShow", function() C:TrigRender() end)
  tinsert(UISpecialFrames, "GloomsAurasTrigger")
  f:Hide()
  C._trig.frame = f; RegisterSubWindow(f)
  return f
end

function C:OpenTriggerEditor(id)
  if not id then return end
  C._trig.editID = id
  C._trig.offset = 0
  if not C._trig.frame then
    local ok, err = pcall(function() C:BuildTriggerEditor() end)
    if not ok then GA.msg("|cffff5555trigger editor failed to build|r: " .. tostring(err)); return end
  end
  CloseSubWindows(C._trig.frame)
  DockRight(C._trig.frame)
  C._trig.frame:Show(); C._trig.frame:Raise()
  C:TrigRender()
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

  -- Master off-switch: DISABLE the aura in gameplay entirely (NOT a "show when"
  -- condition, so it sits apart at the bottom). Auras only — groups have their own
  -- on/off switch. ON = disabled (cfg.enabled=false → dropped from tracking, greyed).
  local disDiv = f:CreateTexture(nil, "ARTWORK"); disDiv:SetColorTexture(COLOR.rim.r, COLOR.rim.g, COLOR.rim.b, COLOR.rim.a)
  disDiv:SetPoint("TOPLEFT", 12, -368); disDiv:SetPoint("TOPRIGHT", -12, -368); disDiv:SetHeight(1)
  local disLbl = newText(f, FONT.bodyM, 13, TEXT, "LEFT"); disLbl:SetPoint("TOPLEFT", 16, -384); disLbl:SetText("This aura in the game:")
  -- Toggle: Disabled (left) | Enabled (right). Drives the AURA (cfg.enabled) or, when
  -- editing a group's load rule, the GROUP (group.enabled). value true = right = Enabled.
  local disSwitch = makeSwitch(f, "Disabled", "Enabled", function(v)
    if visEditGroup then
      local g = VE_Group(); if not g then return end
      if v then g.enabled = nil else g.enabled = false end
      if GA.CDM then GA.CDM:UpdateVisibilityPoll(); GA.CDM:RefreshDisplays() end
      if C.RefreshGroupControl then C:RefreshGroupControl() end
    else
      local c = VE_Cfg(); if not c then return end
      if v then c.enabled = nil else c.enabled = false end
      if GA.CDM then GA.CDM:Discover() end     -- rebind the watch set
    end
    RefreshList()                              -- grey / ungrey the row(s)
  end)
  disSwitch:SetPoint("TOPLEFT", 236, -382)
  veRows[#veRows + 1] = { refresh = function()
    disDiv:Show(); disLbl:Show(); disSwitch:Show()
    local t = visEditGroup and VE_Group() or VE_Cfg()
    disLbl:SetText(visEditGroup and "This group in the game:" or "This aura in the game:")
    disSwitch:Set(not (t and t.enabled == false))   -- Enabled unless explicitly disabled
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
local PANEL_W, PANEL_H = 620, 740
local INSET, TITLEBAR_H = 14, 32
local CONTENT_TOP = -(TITLEBAR_H + 8)   -- -40
local PAD_L = 30                          -- left-content margin (matches the Figma mock)
local LIST_W = 160
local DIVIDER_X = 220                     -- vertical divider between the list and the editor
local EDITOR_X = 240                      -- editor content x (20px right of the divider)
local EDITOR_W = PANEL_W - EDITOR_X - 20  -- 360 (20px right margin, matches the mock)
local PANE_H = 614   -- list pane ends at the footer divider (PANEL_H - FOOTER_H - CONTENT_TOP margin)
local FOOTER_H = 86                       -- footer strip: the divider sits FOOTER_H above the bottom

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
  if self._profileLabel then
    self._profileLabel:Set("Profile:", GA:ActiveProfileName() or "?")
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
    GA.Displays:SetInteractive(true)
  end
  SetSelected(DisplayList()[1])   -- also refreshes the left list + editor (+ preview via RefreshForced)
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
  local W, H = 380, 346
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

  -- Charge-count switch: show a charge spell's LIVE count (resolved from the aura's own spell,
  -- else the first charge condition in its trigger) instead of the custom text. Exact for 2-charge
  -- spells (2/1/0); blank while a 3+ charge spell is mid-recharge. Turning it on also ensures the
  -- text is shown so the number actually appears.
  local ccLbl = newText(f, FONT.body, 12, TEXT, "LEFT"); ccLbl:SetPoint("TOPLEFT", 16, -74); ccLbl:SetText("Charge count")
  local ccSw = makeSwitch(f, "OFF", "ON", function(v)
    local t = TE_Text(); if t then t.showCount = v or nil; if v then t.show = true; showSw:Set(true) end; ReapplySelected() end
  end)
  ccSw:SetPoint("LEFT", ccLbl, "RIGHT", 14, 0)
  teRows[#teRows + 1] = { refresh = function() local t = TE_Text(); ccSw:Set(t and t.showCount == true) end }

  -- Content box (blank = the aura's name).
  local cLbl = newText(f, FONT.body, 11, MUTE, "LEFT"); cLbl:SetPoint("TOPLEFT", 16, -100); cLbl:SetText("Text  (blank = the aura's name)")
  local cBox = flatEditBox(f, W - 32, 22); cBox:SetPoint("TOPLEFT", 16, -118)
  cBox:SetScript("OnEnterPressed", function(self)
    local t = TE_Text(); if t then local s = self:GetText(); t.str = (s ~= "" and s) or nil; ReapplySelected() end
    self:ClearFocus()
  end)
  cBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  teRows[#teRows + 1] = { refresh = function() local t = TE_Text(); cBox:SetText((t and t.str) or ""); cBox:SetCursorPosition(0) end }

  -- Font (opens the font picker; keeps this drawer open underneath).
  local fontBtn = flatButton(f, W - 32, 22, COLOR.heroic, "Font: Default", 12)
  fontBtn:SetPoint("TOPLEFT", 16, -148)
  fontBtn:SetScript("OnClick", function()
    local t = TE_Text()
    OpenFontPicker(function(path)
      local t2 = TE_Text(); if t2 then t2.font = path; ReapplySelected(); fontBtn:SetText("Font: " .. fontNameFor(path)) end
    end, t and t.font)
  end)
  teRows[#teRows + 1] = { refresh = function() local c = Cfg(); local t = c and c.text; fontBtn:SetText("Font: " .. fontNameFor(t and t.font)) end }

  -- Size slider.
  teRows[#teRows + 1] = MakeSlider(f, -180, "Size", 6, 48, 1,
    function() local t = TE_Text(); return t and (t.size or 14) end,
    function(v) local t = TE_Text(); if t then t.size = v end end)

  -- Outline + Anchor dropdowns.
  teRows[#teRows + 1] = MakeDropdown(f, 16, -212, 160, "Outline: ", TE_OUTLINE,
    function() local t = TE_Text(); return (t and t.outline) or "OUTLINE" end,
    function(v) local t = TE_Text(); if t then t.outline = (v ~= "OUTLINE") and v or nil end end)
  teRows[#teRows + 1] = MakeDropdown(f, 200, -212, 164, "Anchor: ", TE_ANCHOR,
    function() local t = TE_Text(); return (t and t.anchor) or "BOTTOM" end,
    function(v) local t = TE_Text(); if t then t.anchor = (v ~= "BOTTOM") and v or nil end end)

  -- Colour.
  teRows[#teRows + 1] = MakeColor(f, 16, -244,
    function() local t = TE_Text(); return t and t.color end,
    function(v) local t = TE_Text(); if t then t.color = v end end)

  -- X / Y offset (added on top of the anchor's base position).
  teRows[#teRows + 1] = MakeSlider(f, -274, "X Offset", -400, 400, 2,
    function() local t = TE_Text(); return t and (t.x or 0) end,
    function(v) local t = TE_Text(); if t then t.x = (v ~= 0) and v or nil end end)
  teRows[#teRows + 1] = MakeSlider(f, -306, "Y Offset", -400, 400, 2,
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

-- --------------------------------------------------------------------------
-- Glow drawer (Effects): LibCustomGlow effect on the SELECTED aura. Type (None /
-- Autocast Shine / Pixel Glow / Proc Glow / Action Button Glow) + optional custom
-- color. cfg.glow = { type, customColor, color }. Applied live via ReapplySelected
-- → Displays:ApplyConfig → ApplyGlow. State/functions hang on C (chunk locals full).
-- --------------------------------------------------------------------------
C._glow = { rows = {} }

function C:BuildGlowEditor()
  local W, H = 300, 150
  local f = CreateFrame("Frame", "GloomsAurasGlowEditor", UIParent)
  f:SetSize(W, H); f:SetPoint("CENTER"); f:SetFrameStrata("FULLSCREEN_DIALOG"); f:EnableMouse(true)
  skinPlate(f)
  C._glow.title = newText(f, FONT.title, 16, COLOR.purple, "LEFT")
  C._glow.title:SetPoint("TOPLEFT", 14, -14); C._glow.title:SetPoint("RIGHT", -36, 0); C._glow.title:SetText("Glow")
  local close = flatButton(f, 22, 20, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -8, -8); close:SetScript("OnClick", function() f:Hide() end)
  f:SetMovable(true); f:SetClampedToScreen(true)
  local tb = CreateFrame("Frame", nil, f); tb:SetPoint("TOPLEFT", 2, -2); tb:SetPoint("TOPRIGHT", -34, -2)
  tb:SetHeight(28); tb:EnableMouse(true); tb:RegisterForDrag("LeftButton")
  tb:SetScript("OnDragStart", function() if f:IsMovable() then f:StartMoving() end end)
  tb:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  local typeLbl = newText(f, FONT.body, 12, TEXT, "LEFT"); typeLbl:SetPoint("TOPLEFT", 16, -46); typeLbl:SetText("Type")
  C._glow.rows[#C._glow.rows + 1] = MakeDropdown(f, 58, -44, 216, "",
    { { "none", "None" }, { "autocast", "Autocast Shine" }, { "pixel", "Pixel Glow" },
      { "proc", "Proc Glow" }, { "button", "Action Button Glow" } },
    function() local c = Cfg(); return (c and c.glow and c.glow.type) or "none" end,
    function(v) local c = Cfg(); if not c then return end; c.glow = c.glow or {}; c.glow.type = (v ~= "none") and v or nil end)

  C._glow.rows[#C._glow.rows + 1] = MakeColor(f, 16, -84,
    function() local c = Cfg(); return c and c.glow and c.glow.customColor and c.glow.color end,
    function(v) local c = Cfg(); if not c then return end; c.glow = c.glow or {}; c.glow.color = v; c.glow.customColor = (v ~= nil) or nil end,
    "Custom Color")

  local hint = newText(f, FONT.body, 11, MUTE, "LEFT")
  hint:SetPoint("TOPLEFT", 16, -112); hint:SetPoint("RIGHT", -14, 0); hint:SetJustifyH("LEFT")
  hint:SetText("The glow shows while the aura is on screen. Custom Color off = the glow's own default color.")

  tinsert(UISpecialFrames, "GloomsAurasGlowEditor")
  f:Hide(); C._glow.frame = f; RegisterSubWindow(f)
  return f
end

function C:OpenGlowEditor(id)
  if not id then return end
  if not C._glow.frame then
    local ok, err = pcall(function() C:BuildGlowEditor() end)
    if not ok then GA.msg("|cffff5555glow editor failed to build|r: " .. tostring(err)); return end
  end
  CloseSubWindows(C._glow.frame)
  DockRight(C._glow.frame)
  C._glow.frame:Show(); C._glow.frame:Raise()
  C:RefreshGlowEditor()
end

function C:RefreshGlowEditor()
  if not (C._glow.frame and C._glow.frame:IsShown()) then return end
  local c = Cfg()
  if C._glow.title then C._glow.title:SetText("Glow: " .. ((c and c.label) or "")) end
  for _, r in ipairs(C._glow.rows) do r:refresh() end
end

-- ---------------------------------------------------------------------------
-- Landing (Default State) + panel mode switch. The panel opens to the landing:
-- a big logo + three "Add ‹type› Aura" create buttons + "View All Auras". Picking
-- a type (or View All) swaps to the editor; the left pane's "New Aura" swaps back.
-- The list + editor panes and the landing overlay share one content area (toggled);
-- the footer (Hide-CDM + Profile) and the dividers stay visible in both states.
-- These live on the C table (methods, not chunk locals) to stay under the Lua caps.
-- ---------------------------------------------------------------------------
function C:ShowLanding()
  C.mode = "landing"
  if listFrame then listFrame:Hide() end
  if C._editor then C._editor:Hide() end
  if C._landing then C._landing:Show() end
  selectedID = nil
  if GA.Displays then
    GA.Displays:SetSelectedDisplay(nil)   -- nothing selected → nothing forced-draggable
    GA.Displays:RefreshForced()           -- preview shows only eye-on auras
  end
end

function C:ShowEditor()
  C.mode = "editor"
  if C._landing then C._landing:Hide() end
  if listFrame then listFrame:Show() end
  if C._editor then C._editor:Show() end
end

-- Create a blank aura of the chosen type and open it in the editor. Icon + Texture are
-- both texture-kind displays (they differ only in which editor sections lead); Bar is a
-- StatusBar display. Spells/sources are added later, inside the editor.
function C:CreateAura(uiType)
  local db = DB(); if not db then return end
  local id = NewDisplayID()
  if uiType == "bar" then
    db[id] = {
      kind = "bar", uiType = "bar", label = "New Bar Aura", enabled = true,
      width = 220, height = 24, point = { "CENTER", 0, -120 }, alpha = 1, showLabel = false,
      bar = { mode = "aura_dur" },
    }
  else
    db[id] = {
      uiType = uiType, label = (uiType == "texture") and "New Texture Aura" or "New Icon Aura",
      enabled = true, width = 64, height = 64, point = { "CENTER", 0, 120 }, alpha = 1,
      showLabel = false, texture = MEDIA .. "Textures\\Circle_Smooth",   -- neutral placeholder
    }
  end
  if GA.CDM then GA.CDM:Discover() end
  C:ShowEditor()
  SetSelected(id)
end

-- The landing overlay: a transparent, mouse-transparent frame filling the panel so the
-- footer + X below stay clickable. Holds the logo and the create / View All buttons.
function C:BuildLanding(p)
  local L = CreateFrame("Frame", nil, p)
  L:SetAllPoints(p)
  C._landing = L

  -- Logo (monogram + wordmark) — transparent PNG at the Figma position (197x248 @ 317,187).
  local logo = L:CreateTexture(nil, "ARTWORK")
  logo:SetTexture(MEDIA .. "ga_logo_full.png")
  logo:SetSize(197, 248)
  logo:SetPoint("TOPLEFT", 317, -187)

  -- Three create buttons (bright purple), stacked in the left pane.
  local defs = { { "Add Icon Aura", "icon", 216 }, { "Add Texture Aura", "texture", 264 }, { "Add Bar Aura", "bar", 312 } }
  for _, d in ipairs(defs) do
    local uiType = d[2]
    local b = flatButton(L, LIST_W, 28, COLOR.heroic, d[1], 12)   -- Figma: #8031ff @ 0.2 fill
    setFont(b.text, FONT.label, 12)   -- General Sans Semibold 12
    b:SetBase(0.2); b:SetPoint("TOPLEFT", PAD_L, -d[3])
    b:SetScript("OnClick", function() C:CreateAura(uiType) end)
  end

  -- View All Auras — de-emphasised (orange @ 0.2), lower in the left pane.
  local viewAll = flatButton(L, LIST_W, 28, COLOR.orange, "View All Auras", 11)
  setFont(viewAll.text, FONT.body, 11)   -- General Sans Regular 11
  viewAll:SetBase(0.2); viewAll:SetPoint("TOPLEFT", PAD_L, -592)
  viewAll:SetScript("OnClick", function() C:ShowEditor(); SetSelected(DisplayList()[1]) end)
end

-- ===========================================================================
-- ACCORDION EDITOR (redesign). The right pane is the aura NAME field followed by a
-- one-open-at-a-time accordion of collapsible sections. Each section = an orange
-- caret + Khand-uppercase header (click to expand) + a content frame; expanding one
-- collapses the others and the stack reflows. Built as C-methods (own upvalue budgets)
-- so Build() stays under Lua 5.1's 60-upvalue cap.  [Slice 2: Appearance is inline;
-- the other sections open their existing drawers for now — inlined in Slice 3.]
-- ===========================================================================
local ACC_HDR_H, ACC_GAP, ACC_NAME_H = 20, 10, 32

-- Add a section under the name field. builder(content) populates it; height = its
-- fixed content height. Sections live on C._acc.sections in insertion order.
function C:AccordionAddSection(key, title, height, builder)
  local editor = C._acc.editor
  local hdr = CreateFrame("Button", nil, editor); hdr:SetSize(EDITOR_W, ACC_HDR_H)
  local caret = hdr:CreateTexture(nil, "OVERLAY"); caret:SetSize(8, 9); caret:SetPoint("LEFT", 2, 0)
  caret:SetTexture(MEDIA .. "triangle.png"); caret:SetVertexColor(1, 1, 1, 1)  -- triangle.png is already orange
  local lbl = newText(hdr, FONT.head, 16, COLOR.purple, "LEFT")   -- Khand Medium 16, purple
  lbl:SetPoint("LEFT", 17, 0); lbl:SetText((title or ""):upper())
  local content = CreateFrame("Frame", nil, editor); content:SetSize(EDITOR_W, height); content:Hide()
  local s = { key = key, header = hdr, caret = caret, content = content, height = height, expanded = false }
  hdr:SetScript("OnClick", function() C:AccordionToggle(key) end)
  if builder then builder(content) end
  C._acc.sections[#C._acc.sections + 1] = s
  return s
end

-- Click a header: toggle it, collapse the rest (one open at a time), reflow.
function C:AccordionToggle(key)
  local secs = C._acc.sections
  local wasOpen
  for _, s in ipairs(secs) do if s.key == key then wasOpen = s.expanded end end
  for _, s in ipairs(secs) do s.expanded = (s.key == key) and (not wasOpen) or false end
  C:AccordionLayout()
end

function C:AccordionOpen(key)   -- force exactly one section open
  for _, s in ipairs(C._acc.sections) do s.expanded = (s.key == key) end
  C:AccordionLayout()
end

-- Reflow: stack headers top-to-bottom; an expanded section inserts its content.
function C:AccordionLayout()
  local y = C._acc.top
  for _, s in ipairs(C._acc.sections) do
    s.header:ClearAllPoints(); s.header:SetPoint("TOPLEFT", 0, y)
    s.caret:SetRotation(s.expanded and CARET_DOWN or 0)
    y = y - ACC_HDR_H
    if s.expanded then
      s.content:ClearAllPoints(); s.content:SetPoint("TOPLEFT", 0, y - 13); s.content:Show()
      y = y - 13 - s.height
    else
      s.content:Hide()
    end
    y = y - ACC_GAP
  end
end

-- Update a section's content height (used by the Trigger section, which grows/shrinks
-- with its conditions) and reflow.
function C:AccordionSetHeight(key, h)
  for _, s in ipairs(C._acc.sections) do
    if s.key == key then s.height = h; s.content:SetHeight(h); break end
  end
  C:AccordionLayout()
end

-- The Appearance, Position & Size section — texture + recolor/desaturate + blend/strata
-- + alpha + width/height (aspect-linked) + X/Y. Reuses the shipped controls; laid out
-- to the mock's vertical rhythm (internal pixel polish is an iteration item).
function C:BuildAppearanceSection(ct)
  local H = COLOR.heroic

  -- Texture field (heroic-8% fill, placeholder when empty) + Choose pill.
  local tfield = CreateFrame("EditBox", nil, ct); tfield:SetSize(270, 28); tfield:SetPoint("TOPLEFT", 0, 0)
  tfield:SetAutoFocus(false); setFont(tfield, FONT.body, 11); tfield:SetTextColor(1, 1, 1); tfield:SetTextInsets(10, 10, 0, 0)
  local tbg = tfield:CreateTexture(nil, "BACKGROUND"); tbg:SetAllPoints(); tbg:SetColorTexture(H.r, H.g, H.b, 0.08)
  local tph = newText(tfield, FONT.body, 11, TEXT, "LEFT"); tph:SetPoint("LEFT", 10, 0); tph:SetAlpha(0.3)
  tph:SetText("Leave blank to adopt the first trigger's icon")
  local function tUpdPH() tph:SetShown((tfield:GetText() or "") == "") end
  tfield:SetScript("OnTextChanged", tUpdPH)
  tfield:SetScript("OnEnterPressed", function(self)
    local c = Cfg(); if c then local t = self:GetText(); if t == "" then t = nil end; c.texture = t; ReapplySelected(); RefreshList() end
    self:ClearFocus()
  end)
  tfield:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  rows[#rows + 1] = {
    refresh = function() local c = Cfg(); local v = c and c.texture; tfield:SetText(v ~= nil and tostring(v) or ""); tfield:SetCursorPosition(0); tUpdPH() end,
    setEnabled = function(_, on) tfield:SetEnabled(on) end }

  local choose = flatButton(ct, 80, 28, H, "Choose", 11); choose:SetBase(0.5); choose:SetPoint("TOPLEFT", 280, 0)
  setFont(choose.text, FONT.body, 11)
  choose:SetScript("OnClick", function()
    local c = Cfg(); if not c then return end
    OpenTexturePicker(function(tex) c.texture = tex; ReapplySelected(); C:RefreshCurrent(); RefreshList() end, c.texture)
  end)
  rows[#rows + 1] = { refresh = function() end, setEnabled = function(_, on) choose:SetEnabled(on) end }

  -- Recolor (check + swatch) + Desaturate (check).
  rows[#rows + 1] = MakeColor(ct, 0, -48,
    function() local c = Cfg(); return c and c.color end,
    function(v) local c = Cfg(); if c then c.color = v end end, "Recolor")
  local desat = flatCheck(ct, "Desaturate"); desat:SetPoint("TOPLEFT", 156, -48)
  desat:SetScript("OnClick", function()
    local c = Cfg(); if not c then return end
    desat:Set(not desat:Get()); c.desaturate = desat:Get() or nil; ReapplySelected()
  end)
  rows[#rows + 1] = { refresh = function() local c = Cfg(); desat:Set(c and c.desaturate) end,
                      setEnabled = function(_, on) desat:SetEnabled(on) end }

  -- Blend / Strata pills.
  rows[#rows + 1] = MakeDropdown(ct, 0, -88, 175, "Blend Mode:", BLEND_MODES,
    function() local c = Cfg(); return (c and c.blend) or "BLEND" end,
    function(v) local c = Cfg(); if c then c.blend = (v ~= "BLEND") and v or nil end end)
  rows[#rows + 1] = MakeDropdown(ct, 185, -88, 175, "Strata:", STRATA_MODES,
    function() local c = Cfg(); return (c and c.strata) or "HIGH" end,
    function(v) local c = Cfg(); if c then c.strata = (v ~= "HIGH") and v or nil end end)

  -- Alpha.
  rows[#rows + 1] = MakeSlider(ct, -136, "Alpha %", 0, 100, 5,
    function() local c = Cfg(); return c and ((c.alpha or 1) * 100) end,
    function(v) local c = Cfg(); if c then c.alpha = v / 100 end end)

  -- Width / Height (aspect-linked) + a link toggle sitting between the two rows.
  local widthRow, heightRow
  local function clampDim(n) return math.max(8, math.min(8192, math.floor(n + 0.5))) end
  widthRow = MakeSlider(ct, -189, "Width", 8, 8192, 2,
    function() local c = Cfg(); return c and (c.width or c.size) end,
    function(v) local c = Cfg(); if not c then return end c.width = v; if c.lockAspect then c.height = clampDim(v / (c.aspect or 1)); if heightRow then heightRow:refresh() end end end)
  rows[#rows + 1] = widthRow
  heightRow = MakeSlider(ct, -222, "Height", 8, 8192, 2,
    function() local c = Cfg(); return c and (c.height or c.size) end,
    function(v) local c = Cfg(); if not c then return end c.height = v; if c.lockAspect then c.width = clampDim(v * (c.aspect or 1)); if widthRow then widthRow:refresh() end end end)
  rows[#rows + 1] = heightRow

  local aspectBtn = CreateFrame("Button", nil, ct); aspectBtn:SetSize(16, 16); aspectBtn:SetPoint("TOPLEFT", 48, -199)
  local alock = aspectBtn:CreateTexture(nil, "ARTWORK"); alock:SetAllPoints()
  local LOCK_ON, LOCK_OFF = MEDIA .. "lock_locked.png", MEDIA .. "lock_unlocked.png"
  local function alockRefresh() local c = Cfg(); alock:SetTexture((c and c.lockAspect) and LOCK_ON or LOCK_OFF); alock:SetVertexColor(1, 1, 1, 1) end
  aspectBtn:SetScript("OnClick", function()
    local c = Cfg(); if not c then return end
    local on = not c.lockAspect; c.lockAspect = on or nil
    if on then local w, h = (c.width or c.size or 64), (c.height or c.size or 64); c.aspect = (h > 0) and (w / h) or 1 end
    alockRefresh()
  end)
  rows[#rows + 1] = { refresh = alockRefresh, setEnabled = function(_, on) aspectBtn:SetEnabled(on); alock:SetDesaturated(not on) end }

  -- X / Y offset.
  rows[#rows + 1] = MakeSlider(ct, -255, "X Offset", -2000, 2000, 5,
    function() local c = Cfg(); return c and c.point and c.point[2] end,
    function(v) local c = Cfg(); if c then c.point = { "CENTER", v, (c.point and c.point[3]) or 0 } end end)
  rows[#rows + 1] = MakeSlider(ct, -288, "Y Offset", -2000, 2000, 5,
    function() local c = Cfg(); return c and c.point and c.point[3] end,
    function(v) local c = Cfg(); if c then c.point = { "CENTER", (c.point and c.point[2]) or 0, v } end end)
end

-- Show "CLICK TO RENAME" only when the current name is short enough not to run under it.
function C:UpdateNameHint()
  if not (C._nameHint and C._nameMeasure) then return end
  local c = Cfg(); C._nameMeasure:SetText((c and c.label) or "")
  C._nameHint:SetShown((C._nameMeasure:GetStringWidth() or 0) <= (EDITOR_W - 120))
end

-- Build the editor: the name field + the icon-section accordion.
function C:BuildEditor(editor)
  C._acc = { editor = editor, sections = {}, top = -54 }   -- top = first header y (below the name)

  -- Aura NAME field — prominent + editable. Khand SemiBold 20 white on a heroic-8%
  -- fill; "CLICK TO RENAME" in orange @ 30% on the right. (Renames cfg.label.)
  editorName = CreateFrame("EditBox", nil, editor)
  editorName:SetPoint("TOPLEFT", 0, -2); editorName:SetSize(EDITOR_W, ACC_NAME_H)
  editorName:SetAutoFocus(false); editorName:SetTextInsets(10, 92, 0, 0)
  setFont(editorName, FONT.title, 20); editorName:SetTextColor(1, 1, 1)
  local nameBG = editorName:CreateTexture(nil, "BACKGROUND"); nameBG:SetAllPoints()
  nameBG:SetColorTexture(COLOR.heroic.r, COLOR.heroic.g, COLOR.heroic.b, 0.08)
  local nameHint = newText(editorName, FONT.body, 11, COLOR.orange, "RIGHT")
  nameHint:SetPoint("RIGHT", -10, 0); nameHint:SetText("CLICK TO RENAME"); nameHint:SetAlpha(0.3)
  C._nameHint = nameHint
  -- Hidden string to measure the name width (so the hint hides when a long name would collide).
  C._nameMeasure = editor:CreateFontString(nil, "OVERLAY"); setFont(C._nameMeasure, FONT.title, 20); C._nameMeasure:Hide()
  editorName:SetScript("OnEditFocusGained", function() nameBG:SetColorTexture(COLOR.heroic.r, COLOR.heroic.g, COLOR.heroic.b, 0.18); nameHint:Hide() end)
  editorName:SetScript("OnEditFocusLost",  function() nameBG:SetColorTexture(COLOR.heroic.r, COLOR.heroic.g, COLOR.heroic.b, 0.08); C:UpdateNameHint() end)
  editorName:SetScript("OnEnterPressed", function(self)
    local c = Cfg(); if c then local txt = self:GetText(); if txt and txt:gsub("%s", "") ~= "" then c.label = txt end end
    self:ClearFocus(); local c2 = Cfg(); self:SetText((c2 and c2.label) or ""); RefreshList(); ReapplySelected()
  end)
  editorName:SetScript("OnEscapePressed", function(self) local c = Cfg(); self:SetText((c and c.label) or ""); self:ClearFocus() end)

  -- Icon-aura sections. Appearance is inline; the rest bridge to their drawers for now.
  C:AccordionAddSection("trigger", "Aura Trigger(s)", 120, function(ct) C:BuildTriggerSection(ct) end)
  C:AccordionAddSection("appearance", "Appearance, Position & Size", 310, function(ct) C:BuildAppearanceSection(ct) end)
  C:AccordionAddSection("text", "Text", 285, function(ct) C:BuildTextSection(ct) end)
  C:AccordionAddSection("effects", "Effects & Motion", 92, function(ct) C:BuildEffectsSection(ct) end)
  C:AccordionAddSection("sounds", "Sounds", 110, function(ct) C:BuildSoundSection(ct) end)
  C:AccordionAddSection("load", "Aura Load Conditions", 40, function(ct)
    local b = flatButton(ct, 130, 24, COLOR.heroic, "Visibility…", 12); b:SetBase(0.4); b:SetPoint("TOPLEFT", 2, -6)
    b:SetScript("OnClick", function() if selectedID then OpenVisibilityEditor(selectedID) end end)
    visibilitySummary = newText(ct, FONT.body, 12, TEXT, "LEFT")
    visibilitySummary:SetPoint("LEFT", b, "RIGHT", 10, 0); visibilitySummary:SetWidth(210); visibilitySummary:SetJustifyH("LEFT")
  end)

  C:AccordionOpen("trigger")   -- icon aura default-opens its Trigger section (matches the mock)
end

-- Left-pane button stack (Figma): New / Duplicate / Delete (dark red) / Group (dark
-- green, two-weight label). 28px tall, 10px gaps, anchored above the footer divider.
-- Fills: heroic@0.5 / heroic@0.5 / red@0.3 / green@0.3; labels General Sans Semibold 11.
function C:BuildLeftButtons(listFrame)
  local H = COLOR.heroic
  local function mk(label, cc, base, yBot, onClick)
    local b = flatButton(listFrame, LIST_W, 28, cc, label, 11); b:SetBase(base)
    setFont(b.text, FONT.label, 11); b:SetPoint("BOTTOMLEFT", 0, yBot); b:SetScript("OnClick", onClick)
    return b
  end
  mk("NEW AURA", H, 0.5, 148, function() C:ShowLanding() end)
  mk("DUPLICATE AURA", H, 0.5, 110, function()
    if not (selectedID and DB() and DB()[selectedID]) then return end
    local copy = DeepCopy(DB()[selectedID]); copy.label = (copy.label or "Aura") .. " (copy)"
    local p = copy.point or { "CENTER", 0, 0 }; copy.point = { "CENTER", (p[2] or 0) + 24, (p[3] or 0) - 24 }
    local id = NewDisplayID(); DB()[id] = copy
    if GA.CDM then GA.CDM:Discover() end
    SetSelected(id)
  end)
  mk("DELETE AURA", COLOR.red, 0.3, 72, function()
    if selectedID and DB() then
      local gone = selectedID; DB()[gone] = nil
      if GA.Displays and GA.Displays.frames[gone] then GA.Displays.frames[gone]:Hide() end
      if GA.CDM then GA.CDM:Discover() end
      SetSelected(DisplayList()[1])
    end
  end)

  local gb = flatButton(listFrame, LIST_W, 28, COLOR.green, "", 11); gb:SetBase(0.3)
  gb:SetPoint("BOTTOMLEFT", 0, 34); gb.text:Hide()
  C._groupBtn, C._groupLabel = gb, twoWeightLabel(gb, 11)
  gb:SetScript("OnClick", function() C:OpenGroupAssignMenu(gb) end)
  C:RefreshGroupButton()
end

-- Group button label = the selected aura's group (Ungrouped if none). Hidden with no selection.
function C:RefreshGroupButton()
  if not C._groupLabel then return end
  local c = Cfg()
  local name = (c and c.group and Groups() and Groups()[c.group] and Groups()[c.group].name) or "Ungrouped"
  C._groupLabel:Set("Group:", name)
  if C._groupBtn then C._groupBtn:SetShown(c ~= nil) end
end

-- Pop-up (opens upward from the Group button) to assign the selected aura to a group:
-- Ungrouped + each group + "+ New Group…".
function C:OpenGroupAssignMenu(anchor)
  local c = Cfg(); if not c then return end
  local menu = C._grpMenu
  if menu and menu:IsShown() then menu:Hide(); return end
  if not menu then
    menu = CreateFrame("Frame", nil, panel); C._grpMenu = menu
    menu:SetFrameStrata("FULLSCREEN_DIALOG"); skinPlate(menu); addEdges(menu, COLOR.rim, 1)
    menu._rows = {}
  end
  local items = { { nil, "Ungrouped" } }
  for _, gid in ipairs(GroupList()) do items[#items + 1] = { gid, Groups()[gid].name or "Group" } end
  items[#items + 1] = { "__new", "+ New Group…" }
  menu:SetSize(LIST_W, #items * 24 + 8)
  menu:ClearAllPoints(); menu:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
  for _, r in ipairs(menu._rows) do r:Hide() end
  for i, it in ipairs(items) do
    local r = menu._rows[i]
    if not r then r = flatButton(menu, LIST_W - 8, 20, COLOR.heroic, "", 11); r:SetBase(0.15); menu._rows[i] = r end
    r:SetText(it[2]); r:ClearAllPoints(); r:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 24); r:Show()
    local val = it[1]
    r:SetScript("OnClick", function()
      menu:Hide(); local cur = Cfg(); if not cur then return end
      if val == "__new" then
        OpenNameDialog("New Group", "", function(nm) local gid = CreateGroup(nm); if gid then cur.group = gid; RefreshList(); C:RefreshGroupButton() end end)
      else
        cur.group = val; RefreshList(); C:RefreshGroupButton()
      end
    end)
  end
  menu:Show()
end

-- ===========================================================================
-- Inline AURA TRIGGER(S) section (redesign). Match ALL/ANY/NONE segmented control +
-- a bordered box of condition rows + an "Add a Trigger" bar. Reuses the trigger engine
-- (C:TrigTree / TrigAddLeaf / TrigRemove / TrigCycleState); this is just the inline UI.
-- The box grows/shrinks with the conditions, so it drives C:AccordionSetHeight to reflow.
-- [Slice 3a-i: flat conditions. Nested TRIGGER GROUP rendering comes in 3a-ii.]
-- ===========================================================================
local TRIG_LOGICS = { { "AND", "ALL" }, { "OR", "ANY" }, { "NONE", "NONE" } }

-- One condition row: right-aligned [name] [icon] = [STATE pill] [X]. Works at the top
-- level (ci=nil) and inside a group (ci set). Shift-clicking a TOP-LEVEL row selects it
-- (→ "Add to Trigger Group" moves the selection into a new group).
function C:MakeTrigRow(parent)
  local H = COLOR.heroic
  local row = CreateFrame("Button", nil, parent); row:SetSize(340, 20); row:RegisterForClicks("LeftButtonUp")
  local selTex = row:CreateTexture(nil, "BACKGROUND"); selTex:SetPoint("TOPLEFT", -2, 2); selTex:SetPoint("BOTTOMRIGHT", 2, -2)
  selTex:SetColorTexture(COLOR.purple.r, COLOR.purple.g, COLOR.purple.b, 0.25); selTex:Hide(); row.selTex = selTex
  local x = flatButton(row, 20, 20, H, "X", 11); x:SetBase(0.5); x:SetPoint("TOPRIGHT", 0, 0); row.x = x
  local pill = flatButton(row, 170, 20, H, "", 11); pill:SetBase(0.5); pill:SetPoint("RIGHT", x, "LEFT", -8, 0); pill.text:Hide()
  row.pillLbl = twoWeightLabel(pill, 11, nil, true); row.pill = pill
  local eq = newText(row, FONT.body, 11, TEXT, "LEFT"); eq:SetPoint("RIGHT", pill, "LEFT", -4, 0); eq:SetText("="); row.eq = eq
  local icon = row:CreateTexture(nil, "ARTWORK"); icon:SetSize(20, 19); icon:SetPoint("RIGHT", eq, "LEFT", -4, 0)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92); row.icon = icon
  local name = newText(row, FONT.body, 11, TEXT, "RIGHT"); name:SetPoint("RIGHT", icon, "LEFT", -4, 0); name:SetWordWrap(false); row.name = name
  x:SetScript("OnClick", function() C:TrigRemove(row._ti, row._ci) end)
  pill:SetScript("OnClick", function() C:TrigCycleState(row._ti, row._ci) end)
  row:SetScript("OnClick", function()
    if row._ci or not row._leaf then return end        -- only top-level leaves are groupable
    if IsShiftKeyDown() then
      local sel = C._trigUI.selected
      sel[row._leaf] = (not sel[row._leaf]) or nil
      C:TrigInlineRender()
    end
  end)
  return row
end

function C:FillTrigRow(row, ti, ci, leaf)
  row._ti, row._ci, row._leaf = ti, ci, leaf
  local ic = leaf.spellID and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(leaf.spellID)
  row.icon:SetTexture(ic or 134400)
  row.name:SetText(leaf.name or (leaf.spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(leaf.spellID)) or "?")
  local main, suf = TrigPill(leaf.state, leaf.k)
  row.pillLbl:Set(main, suf)
  row.selTex:SetShown(ci == nil and C._trigUI.selected[leaf] and true or false)
end

-- A nested TRIGGER GROUP box (orange): "TRIGGER GROUP N" + Match: ALL/ANY/NONE + its own
-- condition rows + a remove-group X. Its own row pool lives on g._rows.
function C:MakeTrigGroupBox(parent)
  local O = COLOR.orange
  local g = CreateFrame("Frame", nil, parent)
  local bg = g:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(O.r, O.g, O.b, 0.1)
  g.label = newText(g, FONT.label, 11, O, "LEFT"); g.label:SetPoint("TOPLEFT", 12, -12)
  g.rem = flatButton(g, 20, 20, O, "X", 11); g.rem:SetBase(0.5); g.rem:SetPoint("TOPRIGHT", -8, -8)
  g.rem:SetScript("OnClick", function() C:TrigRemove(g._ti, nil) end)
  local ml = newText(g, FONT.label, 11, { r = 1, g = 1, b = 1 }, "LEFT"); ml:SetPoint("TOPLEFT", 150, -13); ml:SetText("Match:")
  g.mpills = {}
  local mx = 194
  for _, lg in ipairs(TRIG_LOGICS) do
    local logic, w = lg[1], ({ ALL = 34, ANY = 37, NONE = 48 })[lg[2]] or 40
    local mp = CreateFrame("Button", nil, g); mp:SetSize(w, 20); mp:SetPoint("TOPLEFT", mx, -11); mx = mx + w + 6
    mp.fill = mp:CreateTexture(nil, "BACKGROUND"); mp.fill:SetAllPoints(); mp.fill:SetColorTexture(O.r, O.g, O.b, 0.8)
    mp.edges = addEdges(mp, { r = O.r, g = O.g, b = O.b, a = 1 }, 1)
    local ll = newText(mp, FONT.label, 11, { r = 1, g = 1, b = 1 }, "CENTER"); ll:SetPoint("CENTER"); ll:SetText(lg[2])
    mp._logic = logic
    mp:SetScript("OnClick", function()
      local grp = C:TrigNode(g._ti); if not grp then return end
      grp.logic = logic
      if GA.CDM then GA.CDM:RefreshDisplays() end
      C:TrigRender()
    end)
    g.mpills[#g.mpills + 1] = mp
  end
  g.add = flatButton(g, 100, 22, O, "+ Add to Group", 11); g.add:SetBase(0.35)
  g.add:SetScript("OnClick", function() C:TrigAddToExistingGroup(g._ti) end)
  g._rows = {}
  return g
end

function C:FillTrigGroupBox(g, ti, n, group)
  g._ti = ti
  g.label:SetText("TRIGGER GROUP " .. n)
  for _, mp in ipairs(g.mpills) do
    local sel = (mp._logic == (group.logic or "OR"))
    mp.fill:SetShown(sel); mp:SetAlpha(sel and 1 or 0.5)
    for _, key in ipairs({ "top", "bottom", "left", "right" }) do mp.edges[key]:SetShown(not sel) end
  end
  local pitch, headerH = 30, 36
  local leaves = group.conditions or {}
  for i, leaf in ipairs(leaves) do
    local row = g._rows[i]; if not row then row = C:MakeTrigRow(g); g._rows[i] = row end
    C:FillTrigRow(row, ti, i, leaf)
    row:ClearAllPoints(); row:SetPoint("TOPRIGHT", -8, -(headerH + (i - 1) * pitch)); row:Show()
  end
  for i = #leaves + 1, #g._rows do g._rows[i]:Hide() end
  local h = headerH + #leaves * pitch + 6 + 22 + 6   -- rows + gap + "+ Add to Group" bar
  g:SetHeight(h)
  g.add:ClearAllPoints(); g.add:SetPoint("BOTTOMLEFT", 8, 6); g.add:SetPoint("BOTTOMRIGHT", -8, 6)
  return h
end

function C:BuildTriggerSection(ct)
  local H = COLOR.heroic
  C._trigUI = { pills = {}, rows = {}, groups = {}, selected = {} }

  -- Match ALL / ANY / NONE segmented control (sets the top-level logic).
  for i, lg in ipairs(TRIG_LOGICS) do
    local logic = lg[1]
    local pill = flatButton(ct, 113, 28, H, "", 11); pill:SetBase(0.5); pill.text:Hide()
    pill:SetPoint("TOPLEFT", (i - 1) * 123, 0)
    pill._logic = logic; pill._lbl = twoWeightLabel(pill, 11); pill._lbl:Set("Match", lg[2])
    pill:SetScript("OnClick", function()
      local t = C:TrigTree(); if not t then return end
      t.logic = logic
      if GA.CDM then GA.CDM:RefreshDisplays() end
      C:TrigRender()
    end)
    C._trigUI.pills[i] = pill
  end

  -- Bordered trigger box (heroic@0.05 fill + purple@0.2 border), dynamic height.
  local box = CreateFrame("Frame", nil, ct); box:SetPoint("TOPLEFT", 0, -48); box:SetSize(360, 66)
  local bbg = box:CreateTexture(nil, "BACKGROUND"); bbg:SetAllPoints(); bbg:SetColorTexture(H.r, H.g, H.b, 0.05)
  addEdges(box, { r = COLOR.purple.r, g = COLOR.purple.g, b = COLOR.purple.b, a = 0.2 }, 1)
  C._trigUI.box = box

  -- "Add a Trigger" bar (bottom of the box).
  local addBar = flatButton(box, 360, 28, H, "Add a TRIGGER", 11); addBar:SetBase(0.5)
  setFont(addBar.text, FONT.label, 11)
  addBar:SetPoint("BOTTOMLEFT", 0, 0); addBar:SetPoint("BOTTOMRIGHT", 0, 0)
  addBar:SetScript("OnClick", function() OpenPicker(function(item) C:TrigAddLeaf(item, nil) end) end)
  C._trigUI.addBar = addBar

  -- "Add to Trigger Group" bar (below the box) + shift-click hint.
  local addG = flatButton(ct, 360, 28, H, "", 11); addG:SetBase(0.5); addG.text:Hide()
  addG._lbl = twoWeightLabel(addG, 11); addG._lbl:Set("Add to", "TRIGGER GROUP")
  addG:SetScript("OnClick", function() C:TrigAddToGroup() end)
  C._trigUI.addGroup = addG
  local hint = newText(ct, FONT.body, 11, MUTE, "CENTER"); hint:SetWidth(360)
  hint:SetText("Shift-click multiple condition names above to add to a group")
  C._trigUI.hint = hint
end

-- "Add to Trigger Group": move shift-selected TOP-LEVEL conditions into a new group;
-- with nothing selected, create an empty group and pick its first condition.
function C:TrigAddToGroup()
  local cfg = C:TrigCfg(); if not cfg then return end
  local t = C:TrigTree(); if not t then return end
  local sel = C._trigUI.selected
  local moving, keep = {}, {}
  for _, node in ipairs(t.conditions) do
    if (not node.conditions) and sel[node] then moving[#moving + 1] = node else keep[#keep + 1] = node end
  end
  if #moving == 0 then
    C:TrigAddGroup()
    local gi = #C:TrigTree().conditions
    OpenPicker(function(item) C:TrigAddLeaf(item, gi) end)
    return
  end
  keep[#keep + 1] = { logic = "OR", conditions = moving }
  t.conditions = keep
  wipe(C._trigUI.selected)
  self:TrigRebind()
end

-- Add to an EXISTING group (its "+ Add to Group" button): move the shift-selection into
-- this group, or — with nothing selected — pick a new condition straight into it.
function C:TrigAddToExistingGroup(ti)
  local t = C:TrigTree(); if not t then return end
  local group = t.conditions[ti]; if not (group and group.conditions) then return end
  local sel = C._trigUI.selected
  local moving = {}
  for _, node in ipairs(t.conditions) do
    if (not node.conditions) and sel[node] then moving[#moving + 1] = node end
  end
  if #moving == 0 then
    OpenPicker(function(item) C:TrigAddLeaf(item, ti) end)   -- add a fresh condition to this group
    return
  end
  local keep = {}
  for _, node in ipairs(t.conditions) do
    if not ((not node.conditions) and sel[node]) then keep[#keep + 1] = node end
  end
  for _, node in ipairs(moving) do table.insert(group.conditions, node) end   -- group is a live ref
  t.conditions = keep
  wipe(C._trigUI.selected)
  self:TrigRebind()
end

-- Render the current aura's trigger tree (top-level leaves + nested group boxes) + size.
function C:TrigInlineRender()
  local ui = C._trigUI; if not ui then return end
  local cfg = C:TrigCfg()
  if not cfg then C:AccordionSetHeight("trigger", 40); return end
  local t = cfg.trigger                          -- may be nil — DON'T auto-create by viewing
  local logic = (t and t.logic) or "AND"
  local conditions = (t and t.conditions) or {}

  for _, pill in ipairs(ui.pills) do
    local sel = (pill._logic == logic)
    pill:SetBase(sel and 0.8 or 0.5); pill:SetAlpha(sel and 1 or 0.5)
  end

  local topPad, pitch, gap = 12, 30, 8
  local y, nr, ng = topPad, 0, 0
  for ti, node in ipairs(conditions) do
    if node.conditions then
      ng = ng + 1
      local gbox = ui.groups[ng]; if not gbox then gbox = C:MakeTrigGroupBox(ui.box); ui.groups[ng] = gbox end
      local gh = C:FillTrigGroupBox(gbox, ti, ng, node)
      gbox:ClearAllPoints(); gbox:SetPoint("TOPLEFT", 0, -y); gbox:SetPoint("TOPRIGHT", 0, -y); gbox:Show()
      y = y + gh + gap
    else
      nr = nr + 1
      local row = ui.rows[nr]; if not row then row = C:MakeTrigRow(ui.box); ui.rows[nr] = row end
      C:FillTrigRow(row, ti, nil, node)
      row:ClearAllPoints(); row:SetPoint("TOPRIGHT", -8, -y); row:Show()
      y = y + pitch
    end
  end
  for i = nr + 1, #ui.rows do ui.rows[i]:Hide() end
  for i = ng + 1, #ui.groups do ui.groups[i]:Hide() end

  local boxH = y + gap + 28   -- content + gap + Add-a-Trigger bar
  ui.box:SetHeight(boxH)
  ui.addGroup:ClearAllPoints()
  ui.addGroup:SetPoint("TOPLEFT", 0, -(48 + boxH + 10)); ui.addGroup:SetPoint("TOPRIGHT", 0, -(48 + boxH + 10))
  ui.hint:ClearAllPoints(); ui.hint:SetPoint("TOP", 0, -(48 + boxH + 10 + 28 + 8))

  C:AccordionSetHeight("trigger", 48 + boxH + 10 + 28 + 8 + 15)   -- box + AddToGroup + hint
end

-- Inline TEXT section (redesign). Content field + Show/Charge toggles + Font pill +
-- Text Color + Size + Outline/Anchor + X/Y. Reuses the shipped text engine (cfg.text,
-- OpenFontPicker, TE_OUTLINE/TE_ANCHOR); reads are NON-seeding (so merely viewing the
-- section never creates cfg.text) while writes seed it.
function C:BuildTextSection(ct)
  local H = COLOR.heroic
  local function txt() local c = Cfg(); return c and c.text end                          -- read, no seed
  local function ensure() local c = Cfg(); if not c then return nil end
    if not c.text then c.text = { show = (c.showLabel ~= false) } end; return c.text end  -- write, seeds

  -- Content field (heroic-8%, placeholder = the aura's name).
  local cf = CreateFrame("EditBox", nil, ct); cf:SetSize(360, 28); cf:SetPoint("TOPLEFT", 0, 0)
  cf:SetAutoFocus(false); setFont(cf, FONT.body, 13); cf:SetTextColor(1, 1, 1); cf:SetTextInsets(10, 10, 0, 0)
  local cbg = cf:CreateTexture(nil, "BACKGROUND"); cbg:SetAllPoints(); cbg:SetColorTexture(H.r, H.g, H.b, 0.08)
  local cph = newText(cf, FONT.body, 13, TEXT, "LEFT"); cph:SetPoint("LEFT", 10, 0); cph:SetAlpha(0.3); cph:SetText("Text (blank = the aura's name)")
  local function cUpd() cph:SetShown((cf:GetText() or "") == "") end
  cf:SetScript("OnTextChanged", cUpd)
  cf:SetScript("OnEnterPressed", function(self) local t = ensure(); if t then local s = self:GetText(); t.str = (s ~= "" and s) or nil; ReapplySelected() end; self:ClearFocus() end)
  cf:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  rows[#rows + 1] = { refresh = function() local t = txt(); cf:SetText((t and t.str) or ""); cf:SetCursorPosition(0); cUpd() end,
                      setEnabled = function(_, on) cf:SetEnabled(on) end }

  -- Show Text + Show Charge Count toggles (one row).
  local sLbl = newText(ct, FONT.body, 11, { r = 1, g = 1, b = 1 }, "LEFT"); sLbl:SetPoint("TOPLEFT", 0, -50); sLbl:SetText("Show Text Above")
  local sTog = makeToggle(ct,
    function() local c = Cfg(); if not c then return false end; local t = c.text; if t then return t.show ~= false end; return c.showLabel ~= false end,
    function(v) local t = ensure(); if t then t.show = v; ReapplySelected() end end)
  sTog:SetPoint("TOPLEFT", 94, -48)
  rows[#rows + 1] = { refresh = function() sTog:refresh() end, setEnabled = function() end }

  local cLbl = newText(ct, FONT.body, 11, { r = 1, g = 1, b = 1 }, "LEFT"); cLbl:SetPoint("TOPLEFT", 150, -50); cLbl:SetText("Show Charge Count")
  local cTog = makeToggle(ct,
    function() local t = txt(); return t and t.showCount == true end,
    function(v) local t = ensure(); if t then t.showCount = v or nil; if v then t.show = true; sTog:refresh() end; ReapplySelected() end end)
  cTog:SetPoint("TOPLEFT", 258, -48)
  rows[#rows + 1] = { refresh = function() cTog:refresh() end, setEnabled = function() end }

  -- Font pill + Text Color.
  local fb = flatButton(ct, 220, 28, H, "", 11); fb:SetBase(0.5); fb.text:Hide(); fb:SetPoint("TOPLEFT", 0, -88)
  local fLbl = twoWeightLabel(fb, 11)
  fb:SetScript("OnClick", function()
    local t = txt()
    OpenFontPicker(function(path) local t2 = ensure(); if t2 then t2.font = path; ReapplySelected(); fLbl:Set("Font:", fontNameFor(path)) end end, t and t.font)
  end)
  rows[#rows + 1] = { refresh = function() local t = txt(); fLbl:Set("Font:", fontNameFor(t and t.font)) end, setEnabled = function(_, on) fb:SetEnabled(on) end }

  rows[#rows + 1] = MakeColor(ct, 239, -91,
    function() local t = txt(); return t and t.color end,
    function(v) local t = ensure(); if t then t.color = v end end, "Text Color")

  -- Size (max well above the old 48 so big display text is possible; type an exact value too).
  rows[#rows + 1] = MakeSlider(ct, -136, "Size", 6, 300, 1,
    function() local t = txt(); return t and t.size or 14 end,
    function(v) local t = ensure(); if t then t.size = v end end)

  -- Outline + Anchor.
  rows[#rows + 1] = MakeDropdown(ct, 0, -176, 175, "Outline:", TE_OUTLINE,
    function() local t = txt(); return (t and t.outline) or "OUTLINE" end,
    function(v) local t = ensure(); if t then t.outline = (v ~= "OUTLINE") and v or nil end end)
  rows[#rows + 1] = MakeDropdown(ct, 185, -176, 175, "Anchor:", TE_ANCHOR,
    function() local t = txt(); return (t and t.anchor) or "BOTTOM" end,
    function(v) local t = ensure(); if t then t.anchor = (v ~= "BOTTOM") and v or nil end end)

  -- X / Y offset.
  rows[#rows + 1] = MakeSlider(ct, -224, "X Offset", -400, 400, 2,
    function() local t = txt(); return t and t.x or 0 end,
    function(v) local t = ensure(); if t then t.x = (v ~= 0) and v or nil end end)
  rows[#rows + 1] = MakeSlider(ct, -257, "Y Offset", -400, 400, 2,
    function() local t = txt(); return t and t.y or 0 end,
    function(v) local t = ensure(); if t then t.y = (v ~= 0) and v or nil end end)
end

-- Inline EFFECTS & MOTION section (redesign). Glow only for now (Motion parked — low
-- priority). Reuses the shipped glow engine (cfg.glow + Displays ApplyGlow via ReapplySelected).
function C:BuildEffectsSection(ct)
  local GLOW = { { "none", "None" }, { "autocast", "Autocast Shine" }, { "pixel", "Pixel Glow" },
                 { "proc", "Proc Glow" }, { "button", "Action Button Glow" } }
  rows[#rows + 1] = MakeDropdown(ct, 0, 0, 220, "Glow:", GLOW,
    function() local c = Cfg(); return (c and c.glow and c.glow.type) or "none" end,
    function(v) local c = Cfg(); if not c then return end; c.glow = c.glow or {}; c.glow.type = (v ~= "none") and v or nil end)
  rows[#rows + 1] = MakeColor(ct, 239, -4,
    function() local c = Cfg(); return c and c.glow and c.glow.customColor and c.glow.color end,
    function(v) local c = Cfg(); if not c then return end; c.glow = c.glow or {}; c.glow.color = v; c.glow.customColor = (v ~= nil) or nil end,
    "Custom Color")
  local hint = newText(ct, FONT.body, 11, MUTE, "LEFT"); hint:SetPoint("TOPLEFT", 0, -44); hint:SetWidth(360); hint:SetJustifyH("LEFT")
  hint:SetText("Glow shows while the aura is on screen. Custom Color off = the glow's own colour.")
end

-- The Sounds section — a sound pick + Test, plus WHEN it plays: on trigger (aura
-- applied / cooldown ready), on wear-off, or on entering the pandemic window. The
-- timing writes cfg.sound.on; CDM fires it from the matching Blizzard alert event
-- (auto-path displays) or the shown/hidden edge (compound-trigger / decoration).
function C:BuildSoundSection(ct)
  local sb = flatButton(ct, 150, 22, COLOR.heroic, "None", 12); sb:SetBase(0.4); sb:SetPoint("TOPLEFT", 2, -6)
  local function soundLabel() local c = Cfg(); return (c and c.sound and c.sound.name) or "None" end

  -- The "Play:" timing dropdown — only meaningful with a sound set, so its enabled state
  -- follows both the selection AND whether a sound is chosen.
  local ON = { { "trigger", "When it triggers" }, { "untrigger", "When it wears off" }, { "pandemic", "Pandemic window" } }
  local onRow = MakeDropdown(ct, 2, -36, 220, "Play:", ON,
    function() local c = Cfg(); return (c and c.sound and c.sound.on) or "trigger" end,
    function(v) local c = Cfg(); if c and c.sound then c.sound.on = v end end)
  local function refreshOnEnabled() local c = Cfg(); onRow:setEnabled((c and c.sound) and true or false) end

  sb:SetScript("OnClick", function()
    local c = Cfg(); if not c then return end
    OpenSoundPicker(function(item)
      if item.file then c.sound = c.sound or {}; c.sound.file = item.file; c.sound.name = item.name; c.sound.channel = "Master"
      else c.sound = nil end
      sb:SetText(soundLabel()); onRow:refresh(); refreshOnEnabled()
    end, c.sound and c.sound.file)
  end)
  local tb = flatButton(ct, 52, 22, COLOR.heroic, "Test", 12); tb:SetBase(0.4); tb:SetPoint("LEFT", sb, "RIGHT", 8, 0)
  tb:SetScript("OnClick", function() local c = Cfg(); if c and c.sound and c.sound.file then pcall(PlaySoundFile, c.sound.file, c.sound.channel or "Master") end end)

  local hint = newText(ct, FONT.body, 11, MUTE, "LEFT"); hint:SetPoint("TOPLEFT", 2, -72); hint:SetWidth(356); hint:SetJustifyH("LEFT")
  hint:SetText("Triggers = when the aura is applied (no re-fire on target swap). Pandemic works for DoT/debuff auras.")

  rows[#rows + 1] = {
    refresh = function() sb:SetText(soundLabel()); onRow:refresh(); refreshOnEnabled() end,
    setEnabled = function(_, on) sb:SetEnabled(on); tb:SetEnabled(on); if on then refreshOnEnabled() else onRow:setEnabled(false) end end,
  }
end

local function Build()
  local p = CreateFrame("Frame", "GloomsAurasConfig", UIParent)
  p:SetSize(PANEL_W, PANEL_H); p:SetPoint("CENTER"); p:SetFrameStrata("DIALOG"); p:EnableMouse(true)
  skinPlate(p)
  -- Warm bottom glow — Figma: linear-gradient(transparent 40% → rgba(255,119,41,0.12) 100%).
  -- A white texture over the bottom 60%, vertex-gradient tinted orange, fading in downward.
  local glow = p:CreateTexture(nil, "BACKGROUND", nil, 1)
  glow:SetColorTexture(1, 1, 1, 1)
  glow:SetPoint("TOPLEFT", 0, -PANEL_H * 0.4); glow:SetPoint("BOTTOMRIGHT", 0, 0)
  local go = COLOR.orange
  glow:SetGradient("VERTICAL", CreateColor(go.r, go.g, go.b, 0.12), CreateColor(go.r, go.g, go.b, 0))

  -- No window-title text in the redesign (the editor's aura-name bar is its heading).
  -- Keep a small X close in the top-right corner, lifted above the landing layer so
  -- it stays clickable in both states.
  local close = flatButton(p, 20, 18, COLOR.heroic, "X", 12)
  close:SetPoint("TOPRIGHT", -6, -6); close:SetScript("OnClick", function() p:Hide() end)
  close:SetFrameLevel(p:GetFrameLevel() + 20)

  -- Movable via an invisible strip across the top (no visible title bar now).
  p:SetMovable(true); p:SetClampedToScreen(true)
  local titlebar = CreateFrame("Frame", nil, p)
  titlebar:SetPoint("TOPLEFT", 2, -2); titlebar:SetPoint("TOPRIGHT", -34, -2); titlebar:SetHeight(TITLEBAR_H - 4)
  titlebar:EnableMouse(true); titlebar:RegisterForDrag("LeftButton")
  titlebar:SetScript("OnDragStart", function() p:StartMoving() end)
  titlebar:SetScript("OnDragStop", function() p:StopMovingOrSizing(); C:SavePanelPos() end)

  -- Vertical divider between the list and the editor — runs from the top down to the
  -- footer divider (Figma: x=220, full content height).
  local divider = p:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(COLOR.rim.r, COLOR.rim.g, COLOR.rim.b, COLOR.rim.a)
  divider:SetPoint("TOPLEFT", DIVIDER_X, -2)
  divider:SetPoint("BOTTOMLEFT", DIVIDER_X, FOOTER_H)
  divider:SetWidth(1)

  -- ---- LEFT PANE: the aura list ----
  listFrame = CreateFrame("Frame", nil, p)
  listFrame:SetPoint("TOPLEFT", PAD_L, CONTENT_TOP); listFrame:SetSize(LIST_W, PANE_H)
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
    -- Per-aura EYE (aura rows only): Jason's eye icons — unhidden = previewed on
    -- screen while the panel is open, hidden = not. Editor-only (cfg.preview); it does
    -- NOT affect whether the aura runs in gameplay (that's Visibility → Disabled).
    local eye = flatButton(row, 18, 18, COLOR.purple, "", 12); eye:SetBase(0.0)
    eye:SetPoint("RIGHT", -3, 0)
    local eicon = eye:CreateTexture(nil, "OVERLAY"); eicon:SetSize(14, 14); eicon:SetPoint("CENTER")
    eicon:SetVertexColor(1, 1, 1, 1); eye.icon = eicon
    eye:SetScript("OnClick", function()
      if row.kind ~= "aura" or not row.id then return end
      local cfg = DB() and DB()[row.id]; if not cfg then return end
      cfg.preview = (not cfg.preview) or nil     -- toggle on-screen editor preview
      if GA.Displays then GA.Displays:RefreshForced() end
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

  -- Left-pane button stack (New / Duplicate / Delete / Group) — see C:BuildLeftButtons.
  C:BuildLeftButtons(listFrame)

  -- ---- RIGHT PANE: the settings editor (redesign accordion — see C:BuildEditor) ----
  local editor = CreateFrame("Frame", nil, p)
  editor:SetPoint("TOPLEFT", EDITOR_X, CONTENT_TOP); editor:SetSize(EDITOR_W, PANE_H)
  C._editor = editor   -- so the landing/editor mode switch can toggle it
  C:BuildEditor(editor)

  -- ---- Footer strip (shared by the landing + the editor) ----
  -- Horizontal divider above the footer controls (Figma).
  local footDiv = p:CreateTexture(nil, "ARTWORK")
  footDiv:SetColorTexture(COLOR.rim.r, COLOR.rim.g, COLOR.rim.b, COLOR.rim.a)
  footDiv:SetPoint("BOTTOMLEFT", 0, FOOTER_H); footDiv:SetPoint("BOTTOMRIGHT", 0, FOOTER_H); footDiv:SetHeight(1)

  -- Hide Blizzard's own Cooldown Manager (drives viewer alpha only, not Hide(), so our
  -- state mirror keeps working). A checkbox, bottom-left.
  local hideCDM = flatCheck(p, "Hide Blizzard's Cooldown Manager")
  hideCDM:SetPoint("BOTTOMLEFT", PAD_L, 30)
  hideCDM:SetScript("OnClick", function()
    local on = not hideCDM:Get()
    hideCDM:Set(on)
    if GA.CDM and GA.CDM.ToggleBlizzardHide then GA.CDM:ToggleBlizzardHide(on) end
  end)
  C._hideCDM = hideCDM   -- so C:OnProfileSwitched can re-sync it (hideBlizzardCDM is per-profile)

  -- Profiles: the active-profile button (bottom-right) opens the Profiles drawer
  -- (switch / new / copy / rename / delete). Label tracks the active profile.
  local profileBtn = flatButton(p, 191, 28, COLOR.heroic, "", 11)   -- Figma: #8031ff @ 0.2
  profileBtn:SetBase(0.2)
  profileBtn.text:Hide()   -- replaced by a two-weight label: "Profile:" (Regular) + name (Semibold)
  C._profileLabel = twoWeightLabel(profileBtn, 11)
  profileBtn:SetPoint("BOTTOMRIGHT", -PAD_L, 28)
  profileBtn:SetScript("OnClick", function() C:OpenProfileManager() end)
  C._profileBtn = profileBtn
  C:UpdateProfileButton()

  C:BuildLanding(p)   -- the landing overlay (logo + create buttons + View All)

  p:SetScript("OnShow", function()
    hideCDM:Set(GA.db and GA.db.hideBlizzardCDM)
    C:UpdateProfileButton()
    local pos = GA.global and GA.global.panelPos
    if pos then p:ClearAllPoints(); p:SetPoint("CENTER", UIParent, "CENTER", pos[1] or 0, pos[2] or 0) end
    if GA.Displays then
      GA.Displays.forced = true
      GA.Displays:SetInteractive(true)
    end
    C:ShowLanding()   -- the panel opens to the landing (Default State): pick a type or View All
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
