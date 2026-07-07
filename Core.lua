-- Core.lua — Gloom's Auras
--
-- Bespoke buff/cooldown display addon for WoW Midnight (12.0+). Routes AROUND
-- Midnight's secret combat-data restrictions by MIRRORING the Blizzard Cooldown
-- Manager's own state rather than reading aura data (see docs/API-NOTES.md).
--   • namespace (_G.GloomsAuras = GA) + saved variables
--   • /ga slash router
-- Displays.lua (GA.Displays) owns the on-screen frames; CDM.lua (GA.CDM) owns
-- the Cooldown Manager mirror. Both are loaded after this file.

local ADDON_NAME = ...

local GA = {}
_G.GloomsAuras = GA
GA.ADDON_NAME = ADDON_NAME

local PREFIX = "|cff936bffGloom's Auras|r"   -- bright purple, matches Build Barn
GA.PREFIX = PREFIX

local function msg(text)
  print(PREFIX .. ": " .. tostring(text))
end
GA.msg = msg

-- ---------------------------------------------------------------------------
-- Design tokens — shared skin, matched to Gloom's Build Barn (same author).
-- Bright-purple accent on a near-black navy plate, condensed Khand titles +
-- GeneralSans body. Fonts/plate are bundled in Media/ (see Config.lua toolkit,
-- which falls back to the default game font if a file is ever missing).
-- ---------------------------------------------------------------------------
local function color(hex)
  local r = tonumber(hex:sub(1, 2), 16) / 255
  local g = tonumber(hex:sub(3, 4), 16) / 255
  local b = tonumber(hex:sub(5, 6), 16) / 255
  return { r = r, g = g, b = b, hex = hex }
end
GA.COLOR = {
  purple = color("936bff"),  -- bright purple — accents, selection, buttons
  heroic = color("8031ff"),  -- deep purple
  green  = color("20ba56"),  -- confirm / "added" green
  orange = color("ff7729"),  -- warning / remove
  dark   = { r = 0.04, g = 0.055, b = 0.10, a = 0.96 },  -- panel base (navy-black)
  rim    = { r = 1, g = 1, b = 1, a = 0.10 },            -- 1px frame rim
}

GA.MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
local FONT_DIR = GA.MEDIA .. "fonts\\"
GA.FONT = {
  title = FONT_DIR .. "Khand-SemiBold.ttf",        -- window/section titles
  head  = FONT_DIR .. "Khand-Medium.ttf",          -- section headers
  body  = FONT_DIR .. "GeneralSans-Regular.ttf",   -- body text
  bodyM = FONT_DIR .. "GeneralSans-Medium.ttf",    -- emphasised body
  label = FONT_DIR .. "GeneralSans-Semibold.ttf",  -- uppercase labels / buttons
}

function GA:Version()
  local v = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
  if type(v) ~= "string" or v == "" or v:find("@") then return "dev" end
  return v
end

-- ---------------------------------------------------------------------------
-- Saved variables. Plain table, schema-versioned, never wiped on upgrade.
-- ---------------------------------------------------------------------------
local DB_SCHEMA = 1
local function InitDB()
  if type(GloomsAurasDB) ~= "table" then GloomsAurasDB = {} end
  local db = GloomsAurasDB
  db.schema   = db.schema or DB_SCHEMA
  db.displays = db.displays or {}   -- [spellID] = { spellID,label,enabled,size,point,... }
  db.media    = db.media or {}      -- reserved: custom media
  db.minimap  = db.minimap or {}    -- LibDBIcon: { hide, minimapPos }

  -- Seed the Trick Shots proof display on a fresh DB so nothing regresses.
  if next(db.displays) == nil then
    db.displays[257621] = {
      spellID = 257621, label = "Trick Shots", enabled = true,
      size = 64, point = { "CENTER", 0, 180 }, showLabel = true,
    }
  end

  GA.db = db
end

-- ---------------------------------------------------------------------------
-- Command helpers
-- ---------------------------------------------------------------------------
local function AddDisplay(arg)
  local spellID = tonumber(arg)
  if not spellID then
    msg("usage: |cffffd200/ga add <spellID>|r  (spellIDs are listed by |cffffd200/ga debug|r)")
    return
  end
  local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
  if not GA.db.displays[spellID] then
    GA.db.displays[spellID] = {
      spellID = spellID, label = name or ("Spell " .. spellID), enabled = true,
      size = 64, point = { "CENTER", 0, 120 }, showLabel = true,
    }
  end
  msg(("added display for %s (%s). Use |cffffd200/ga pos %s <x> <y>|r to place it."):format(
    tostring(spellID), name or "?", tostring(spellID)))
  if GA.CDM then GA.CDM:Discover() end
end

local function RemoveDisplay(arg)
  local spellID = tonumber(arg)
  if not spellID or not GA.db.displays[spellID] then
    msg("no display for that spellID. |cffffd200/ga list|r to see them.")
    return
  end
  GA.db.displays[spellID] = nil
  if GA.Displays and GA.Displays.frames[spellID] then GA.Displays.frames[spellID]:Hide() end
  msg("removed display " .. spellID .. ".")
end

local function ListDisplays()
  msg("displays:")
  local any = false
  for spellID, cfg in pairs(GA.db.displays) do
    any = true
    local p = cfg.point or { "CENTER", 0, 0 }
    print(("  |cffffd200%s|r — %s  [x=%d y=%d size=%d]%s"):format(
      tostring(spellID), cfg.label or "?", p[2] or 0, p[3] or 0, cfg.size or 64,
      (cfg.enabled == false) and " |cff999999(disabled)|r" or ""))
  end
  if not any then print("  (none — |cffffd200/ga add <spellID>|r)") end
end

-- /ga pos <spellID> <x> <y>  — x/y are offsets from screen centre (up/right +).
local function PosDisplay(rest)
  local sid, x, y = rest:match("^(%d+)%s+(%-?%d+)%s+(%-?%d+)$")
  sid, x, y = tonumber(sid), tonumber(x), tonumber(y)
  if not (sid and x and y) then
    msg("usage: |cffffd200/ga pos <spellID> <x> <y>|r   (e.g. |cffffd200/ga pos 257621 0 180|r — centre is 0 0, up/right positive)")
    return
  end
  if not GA.db.displays[sid] then msg("no display for " .. sid .. ". |cffffd200/ga list|r"); return end
  GA.Displays:SetPosition(sid, x, y)
  msg(("%s → x=%d, y=%d."):format(sid, x, y))
end

-- /ga size <spellID> <pixels>
local function SizeDisplay(rest)
  local sid, n = rest:match("^(%d+)%s+(%d+)$")
  sid, n = tonumber(sid), tonumber(n)
  if not (sid and n) then
    msg("usage: |cffffd200/ga size <spellID> <pixels>|r   (e.g. |cffffd200/ga size 257621 64|r)")
    return
  end
  if not GA.db.displays[sid] then msg("no display for " .. sid .. ". |cffffd200/ga list|r"); return end
  n = math.max(8, math.min(512, n))
  GA.Displays:SetDisplaySize(sid, n)
  msg(("%s → %dpx."):format(sid, n))
end

-- ---------------------------------------------------------------------------
-- Slash router: /ga
-- ---------------------------------------------------------------------------
local function SlashHandler(input)
  local cmd, rest = (input or ""):match("^(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()

  if cmd == "" or cmd == "config" or cmd == "options" then
    if GA.Config then GA.Config:Toggle() else msg("options panel not ready.") end
  elseif cmd == "help" then
    msg("commands:")
    print("  |cffffd200/ga|r                    — open the options panel")
    print("  |cffffd200/ga add <spellID>|r      — track a new buff/cooldown")
    print("  |cffffd200/ga remove <spellID>|r   — stop tracking one")
    print("  |cffffd200/ga list|r               — list displays (with x/y/size)")
    print("  |cffffd200/ga pos <spellID> <x> <y>|r — position it (centre = 0 0)")
    print("  |cffffd200/ga size <spellID> <px>|r  — set its size")
    print("  |cffffd200/ga preview|r            — show all displays while you position them")
    print("  |cffffd200/ga test|r               — flash displays for 5s")
    print("  |cffffd200/ga minimap|r            — show/hide the minimap button")
    print("  |cffffd200/ga hidecdm|r            — hide/show Blizzard's Cooldown Manager")
    print("  |cffffd200/ga trace|r              — per-display trigger diagnostic")
    print("  |cffffd200/ga debug|r              — Cooldown Manager diagnostics")
  elseif cmd == "add" then
    AddDisplay(rest)
  elseif cmd == "remove" or cmd == "delete" then
    RemoveDisplay(rest)
  elseif cmd == "list" then
    ListDisplays()
  elseif cmd == "pos" or cmd == "move" then
    PosDisplay(rest)
  elseif cmd == "size" then
    SizeDisplay(rest)
  elseif cmd == "preview" then
    if GA.Displays then GA.Displays:Preview() end
  elseif cmd == "test" then
    if GA.Displays then GA.Displays:Test(5) end
  elseif cmd == "minimap" then
    if GA.ToggleMinimapButton then
      local shown = GA:ToggleMinimapButton()
      msg("minimap button " .. (shown and "|cff55ff55shown|r" or "|cffff5555hidden|r") .. ".")
    end
  elseif cmd == "hidecdm" then
    if GA.CDM and GA.CDM.ToggleBlizzardHide then
      local hidden = GA.CDM:ToggleBlizzardHide()
      msg("Blizzard Cooldown Manager " .. (hidden and "|cffff5555hidden|r" or "|cff55ff55shown|r") ..
          ". (Kept tracking alive — the viewers still update, just invisible.)")
    else
      msg("CDM engine not ready yet.")
    end
  elseif cmd == "charges" then
    if GA.CDM and GA.CDM.ReportCharges then GA.CDM:ReportCharges() else msg("CDM engine not ready yet.") end
  elseif cmd == "trace" then
    if GA.CDM and GA.CDM.Trace then GA.CDM:Trace() else msg("CDM engine not ready yet.") end
  elseif cmd == "debug" then
    if GA.CDM and GA.CDM.Debug then GA.CDM:Debug() else msg("CDM engine not ready yet.") end
  else
    msg("unknown command '" .. cmd .. "'. Try |cffffd200/ga help|r")
  end
end
SLASH_GLOOMSAURAS1 = "/ga"
SlashCmdList["GLOOMSAURAS"] = SlashHandler

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    InitDB()
  elseif event == "PLAYER_LOGIN" then
    if GA.CDM and GA.CDM.Init then GA.CDM:Init() end
    if GA.InitMinimapButton then GA:InitMinimapButton() end
    msg("loaded (v" .. GA:Version() .. "). Type |cffffd200/ga|r for help.")
  end
end)
