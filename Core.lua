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

-- Pre-warm the bundled TTF fonts at login. WoW sometimes hasn't finished loading a
-- runtime custom font on the FIRST login of a session, so any label built in that
-- window (e.g. the options panel on an early /ga) renders BLANK until a /reload
-- caches the font. Drawing + measuring a throwaway string in each face here forces
-- the font into the cache before the panel is ever built, so the glyphs are ready.
-- (The frame is kept alive on GA so the warmed strings aren't garbage-collected.)
local function PreloadFonts()
  local warmer = CreateFrame("Frame", nil, UIParent)
  warmer:SetPoint("TOPLEFT"); warmer:SetSize(1, 1); warmer:SetAlpha(0)
  GA._fontWarmer = warmer
  for _, path in pairs(GA.FONT) do
    local fs = warmer:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("TOPLEFT")
    if fs:SetFont(path, 14, "") then
      fs:SetText(".")
      fs:GetStringWidth()   -- force the face to load + shape now, not on first visible use
    end
  end
end
GA.PreloadFonts = PreloadFonts

-- ---------------------------------------------------------------------------
-- Saved variables. Plain table, schema-versioned, never wiped on upgrade.
--
-- Schema 2 splits the SV into two layers (see docs/GROUPS-PROFILES-DESIGN.md §3):
--   • GA.global = GloomsAurasDB — ACCOUNT-WIDE: profiles, profileKeys (char→profile
--     name), minimap, panelPos.
--   • GA.db     = the ACTIVE PROFILE — displays, groups, seq, groupSeq, hideBlizzardCDM,
--     ungroupedCollapsed. GA.db is REPOINTED on a profile switch, so the many existing
--     GA.db.displays / GA.db.groups call sites keep working untouched.
-- Each character defaults to its own profile ("Name - Realm"); profiles are switchable
-- and shareable across characters (Phase 3B adds the switcher UI).
-- ---------------------------------------------------------------------------
local DB_SCHEMA = 2

-- Account-wide skeleton. Runs at ADDON_LOADED (SavedVariables are available then).
-- Does NOT resolve the active profile yet — that needs the character name, which is
-- only reliable at PLAYER_LOGIN (see SetupActiveProfile).
local function InitGlobal()
  if type(GloomsAurasDB) ~= "table" then GloomsAurasDB = {} end
  local g = GloomsAurasDB
  g.profiles    = g.profiles or {}     -- [profileName] = <profile>
  g.profileKeys = g.profileKeys or {}  -- [charKey] = profileName
  g.minimap     = g.minimap or {}      -- LibDBIcon: { hide, minimapPos } (account-wide)
  -- g.panelPos is set lazily when the panel is first dragged (account-wide window pos).
  GA.global = g
end

-- Per-character key used as the default profile name ("Name - Realm").
local function CharKey()
  local name  = UnitName("player") or "Unknown"
  local realm = GetRealmName() or "Unknown"
  return name .. " - " .. realm
end
GA.CharKey = CharKey

local function NewProfile()
  return { displays = {}, groups = {}, seq = 0, groupSeq = 0 }
end
GA.NewProfile = NewProfile

-- Seed the Trick Shots proof display into an empty profile so nothing regresses.
local function SeedProfile(profile)
  if next(profile.displays) == nil then
    profile.displays[257621] = {
      spellID = 257621, label = "Trick Shots", enabled = true,
      size = 64, point = { "CENTER", 0, 180 }, showLabel = true,
    }
  end
end

-- One-time schema 1 → 2 migration, non-destructive. The old flat top-level
-- displays/groups/seq/... become a profile named after the current character;
-- values are read into the profile BEFORE the old keys are cleared, so no aura or
-- group is lost. (Phase 1 shipped groups/groupSeq at the top level — they move too.)
local function MigrateToProfiles(g, charKey)
  local profile = NewProfile()
  profile.displays           = g.displays or {}
  profile.groups             = g.groups   or {}
  profile.seq                = g.seq      or 0
  profile.groupSeq           = g.groupSeq or 0
  profile.hideBlizzardCDM    = g.hideBlizzardCDM
  profile.ungroupedCollapsed = g.ungroupedCollapsed
  g.profiles[charKey]    = profile
  g.profileKeys[charKey] = charKey
  -- clear the old flat keys now that they live in the profile
  g.displays, g.groups, g.seq, g.groupSeq = nil, nil, nil, nil
  g.hideBlizzardCDM, g.ungroupedCollapsed, g.media = nil, nil, nil
  g.schema = 2
end

-- Resolve which profile this character uses and point GA.db at it. Runs at
-- PLAYER_LOGIN (character name guaranteed available); migrates schema 1 → 2 first.
local function SetupActiveProfile()
  local g = GA.global
  local charKey = CharKey()
  if (g.schema or 1) < 2 and g.displays then
    MigrateToProfiles(g, charKey)   -- flat → profiles, one time
  end
  g.schema = DB_SCHEMA
  local pkey = g.profileKeys[charKey] or charKey   -- default: this char's own profile
  if not g.profiles[pkey] then g.profiles[pkey] = NewProfile() end
  g.profileKeys[charKey] = pkey
  local prof = g.profiles[pkey]
  SeedProfile(prof)
  -- One-time recovery (v2): re-enable every aura. Two reasons: (1) the eye icon used
  -- to (mis)set cfg.enabled=false and now means "preview while editing" (cfg.preview);
  -- (2) an early Disabled switch had a nil-idiom bug that could disable but never
  -- re-enable, stranding auras off. Both are fixed; this un-sticks anything left off.
  -- Visibility → Disabled is the intended way to turn an aura off going forward.
  if prof._eyeFixed ~= 2 then
    for _, cfg in pairs(prof.displays) do if cfg.enabled == false then cfg.enabled = nil end end
    prof._eyeFixed = 2
  end
  GA.activeProfile = pkey
  GA.db = prof
end
GA.SetupActiveProfile = SetupActiveProfile

-- ---------------------------------------------------------------------------
-- Profile management (Phase 3B). Each op repoints GA.db to the active profile,
-- then RefreshForProfile re-syncs the engine (drop the old profile's frames,
-- rediscover) and the options panel. Names are trimmed; blanks/dupes are refused.
-- ---------------------------------------------------------------------------
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, val in pairs(v) do t[k] = deepcopy(val) end
  return t
end

-- Sorted list of all profile names (case-insensitive).
function GA:ProfileNames()
  local names = {}
  local g = GA.global
  if g and g.profiles then for name in pairs(g.profiles) do names[#names + 1] = name end end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  return names
end

function GA:ActiveProfileName() return GA.activeProfile end

-- Re-sync engine + UI after GA.db is repointed. Hides every existing display
-- frame (the OLD profile's auras — Discover only re-shows the new set), then
-- rediscovers and asks the panel to rebuild for the new profile.
local function RefreshForProfile()
  if GA.Displays and GA.Displays.frames then
    for _, f in pairs(GA.Displays.frames) do f:Hide() end
  end
  if GA.CDM and GA.CDM.Discover then GA.CDM:Discover() end
  if GA.Config and GA.Config.OnProfileSwitched then GA.Config:OnProfileSwitched() end
end
GA.RefreshForProfile = RefreshForProfile

-- Switch this character to an existing profile.
function GA:SwitchProfile(name)
  local g = GA.global
  if not (g and g.profiles[name]) then return false end
  g.profileKeys[CharKey()] = name
  GA.activeProfile = name
  GA.db = g.profiles[name]
  RefreshForProfile()
  return true
end

-- Create a new EMPTY profile named `name` and switch to it.
function GA:CreateProfile(name)
  name = trim(name)
  local g = GA.global
  if name == "" or not g then return false end
  if g.profiles[name] then return false, "exists" end
  g.profiles[name] = NewProfile()
  return GA:SwitchProfile(name)
end

-- Copy the ACTIVE profile into a new profile named `name` and switch to it.
function GA:CopyProfile(name)
  name = trim(name)
  local g = GA.global
  if name == "" or not g then return false end
  if g.profiles[name] then return false, "exists" end
  g.profiles[name] = deepcopy(GA.db)
  return GA:SwitchProfile(name)
end

-- Rename the ACTIVE profile (repoints every character that pointed at it).
function GA:RenameActiveProfile(name)
  name = trim(name)
  local g = GA.global
  local old = GA.activeProfile
  if name == "" or not g or not old then return false end
  if name == old then return true end
  if g.profiles[name] then return false, "exists" end
  g.profiles[name] = g.profiles[old]
  g.profiles[old] = nil
  for char, pname in pairs(g.profileKeys) do
    if pname == old then g.profileKeys[char] = name end
  end
  GA.activeProfile = name
  if GA.Config and GA.Config.OnProfileSwitched then GA.Config:OnProfileSwitched() end
  return true
end

-- Delete a profile. Refuses to delete the only one. If it's the active profile,
-- falls back to the first remaining one; characters that pointed at it lose the
-- pointer and re-resolve to their own default next login.
function GA:DeleteProfile(name)
  local g = GA.global
  if not (g and g.profiles[name]) then return false end
  local count = 0; for _ in pairs(g.profiles) do count = count + 1 end
  if count <= 1 then return false, "last" end
  local wasActive = (GA.activeProfile == name)
  g.profiles[name] = nil
  for char, pname in pairs(g.profileKeys) do
    if pname == name then g.profileKeys[char] = nil end
  end
  if wasActive then
    GA:SwitchProfile(GA:ProfileNames()[1])
  elseif GA.Config and GA.Config.OnProfileSwitched then
    GA.Config:OnProfileSwitched()
  end
  return true
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

-- /ga profile [name]  — list profiles (with the active one marked), or switch to one.
local function ProfileCmd(rest)
  rest = rest and rest:match("^%s*(.-)%s*$") or ""
  if rest == "" then
    msg("profiles (active is |cff936bff•|r):")
    for _, name in ipairs(GA:ProfileNames()) do
      local mark = (name == GA:ActiveProfileName()) and "|cff936bff• |r" or "  "
      print("  " .. mark .. name)
    end
    print("  switch with |cffffd200/ga profile <name>|r")
    return
  end
  local g = GA.global
  if g and g.profiles[rest] then
    GA:SwitchProfile(rest)
    msg("switched to profile |cffffffff" .. rest .. "|r.")
  else
    msg("no profile named |cffffffff" .. rest .. "|r. |cffffd200/ga profile|r lists them.")
  end
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
    print("  |cffffd200/ga profile [name]|r    — list profiles, or switch to one")
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
  elseif cmd == "profile" or cmd == "profiles" then
    ProfileCmd(rest)
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
    InitGlobal()
  elseif event == "PLAYER_LOGIN" then
    SetupActiveProfile()   -- migrate schema 1→2 + point GA.db at the active profile, before anything reads it
    PreloadFonts()   -- warm bundled fonts before any panel is built (avoids blank labels)
    if GA.CDM and GA.CDM.Init then GA.CDM:Init() end
    if GA.InitMinimapButton then GA:InitMinimapButton() end
    msg("loaded (v" .. GA:Version() .. "). Type |cffffd200/ga|r for help.")
  end
end)
