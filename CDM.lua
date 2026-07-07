-- CDM.lua — Gloom's Auras: Cooldown Manager mirror engine
--
-- Decides WHEN each display shows by mirroring the Blizzard Cooldown Manager's
-- per-cooldown "active" state (docs/API-NOTES.md §3-4). Displays.lua owns HOW
-- they look. For each configured display (GloomsAurasDB.displays[spellID]) we:
--   1. find its CDM item frame, scanning ALL FOUR viewers and matching by CONFIG
--      ids (spellID / override / linkedSpellIDs) — so it works wherever the user
--      placed the spell (Buff icons vs Bars, Essential vs Utility),
--   2. hooksecurefunc its OnActiveStateChanged and drive the display from
--      item:IsActive() — a plain boolean in combat (confirmed in-game 2026-07-06),
--   3. re-discover when the CDM rebuilds its pooled item frames.

local ADDON_NAME = ...
local GA = _G.GloomsAuras

local CDM = {}
GA.CDM = CDM

local issecret = _G.issecretvalue or function() return false end

local SOUND_ON_SHOW = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
local THROTTLE = 1.0  -- seconds; min gap between sounds per display

CDM.frameToSpell   = {} -- CDM item frame -> spellID (rebuilt on Discover)
CDM.lastPlay       = {} -- spellID -> GetTime() of last sound
CDM.kind           = {} -- spellID -> "buff" | "cooldown"
CDM.available      = {} -- spellID -> bool (cooldown ready?), mirrored from Blizzard
CDM.cdFrameToSpell = {} -- Blizzard cooldown widget -> spellID (rebuilt on Discover)
CDM.cdFrameToItem  = {} -- Blizzard cooldown widget -> CDM item frame (rebuilt on Discover)
CDM.buffActive     = {} -- spellID -> bool (buff up?), mirrored from item:IsActive()
CDM.lastShown      = {} -- display spellID -> bool (was it shown last refresh?) for sound edges
CDM.isCharge       = {} -- spellID -> bool (charge spell: availability via IsSpellUsable, not sweep)

local VIEWER_NAME_BY_CATEGORY = {
  [0] = "EssentialCooldownViewer", [1] = "UtilityCooldownViewer",
  [2] = "BuffIconCooldownViewer",  [3] = "BuffBarCooldownViewer",
}
local function AllViewers()
  return {
    EssentialCooldownViewer, UtilityCooldownViewer,
    BuffIconCooldownViewer, BuffBarCooldownViewer,
  }
end

-- True while Blizzard's Edit Mode is open. We suspend the "hide the CDM" toggle
-- then so the user can still see + drag the viewers. Plain API, no secret data.
local function EditModeActive()
  local em = _G.EditModeManagerFrame
  return (em and em.IsEditModeActive and em:IsEditModeActive()) and true or false
end

-- Secret-safe equality: refuses to compare if either side is secret or nil.
local function plainEq(a, b)
  if a == nil or b == nil then return false end
  if issecret(a) or issecret(b) then return false end
  return a == b
end

-- Does this cached cooldown-info belong to spellID? CONFIG fields only.
local function InfoMatchesSpell(info, spellID)
  if not info then return false end
  if plainEq(info.spellID, spellID) then return true end
  if plainEq(info.overrideSpellID, spellID) then return true end
  if plainEq(info.overrideTooltipSpellID, spellID) then return true end
  local linked = info.linkedSpellIDs
  if type(linked) == "table" then
    for _, sid in ipairs(linked) do
      if plainEq(sid, spellID) then return true end
    end
  end
  return false
end

local function ForEachItem(viewer, fn)
  if not viewer then return end
  local pool = viewer.itemFramePool
  if pool and pool.EnumerateActive then
    for frame in pool:EnumerateActive() do fn(frame) end
  end
end

-- Sound is OPT-IN per display: nothing plays unless that display has cfg.sound set
-- (a future sound picker fills it in). This keeps auras silent by default.
function CDM:PlaySound(spellID, cfg)
  cfg = cfg or (GA.db and GA.db.displays and GA.db.displays[spellID])
  local snd = cfg and cfg.sound
  if not snd then return end
  if EditModeActive() or self._emSettling then return end  -- never on Edit Mode sample data

  local now = GetTime()
  local last = self.lastPlay[spellID]
  if last and (now - last) < THROTTLE then return end
  self.lastPlay[spellID] = now
  if type(snd) == "table" and snd.file then
    PlaySoundFile(snd.file, snd.channel or "Master")
  elseif type(snd) == "number" then
    PlaySound(snd, "Master")
  end
end

-- ---------------------------------------------------------------------------
-- Trigger evaluation. State per watched spell: buffActive[] (mirrored from
-- item:IsActive) and available[] (mirrored from Blizzard's cooldown transitions).
-- A display shows when its trigger evaluates true; with no trigger it falls back
-- to auto-behavior (its own spell's buff-active / cooldown-ready).
-- ---------------------------------------------------------------------------

-- The set of spellIDs we must track state for = every display's own spell PLUS
-- every spell referenced by any display's trigger conditions.
function CDM:WatchedSpells()
  local set = {}
  local db = GA.db and GA.db.displays
  if db then
    for _id, cfg in pairs(db) do
      if cfg.enabled ~= false then
        if cfg.spellID then set[cfg.spellID] = true end   -- the display's own tracked spell
        local conds = cfg.trigger and cfg.trigger.conditions
        if conds then
          for _, c in ipairs(conds) do if c.spellID then set[c.spellID] = true end end
        end
      end
    end
  end
  return set
end

-- One leaf condition: { spellID = N, state = "buff_active"|"buff_inactive"|"cd_ready"|"cd_oncd" }
function CDM:EvalCondition(cond)
  local sid, state = cond.spellID, cond.state
  if state == "buff_active" then
    return self.buffActive[sid] == true
  elseif state == "buff_inactive" then
    return self.buffActive[sid] ~= true
  elseif state == "cd_ready" then
    -- Match EvalDisplay's auto default: for a NON-charge cooldown we reliably detect
    -- going ON cd (CooldownFrame_Set), but an idle-available spell never fires a
    -- transition and is secret in combat — so unknown ⇒ assume READY. (Charge spells
    -- stay unknown ⇒ not ready, since charge state is genuinely unreadable in combat.)
    local a = self.available[sid]
    if a == nil and not self.isCharge[sid] then return true end
    return a == true
  elseif state == "cd_oncd" then
    return self.available[sid] == false    -- unknown (nil, untracked) = NOT confirmed on-cd
  end
  return false
end

-- trigger = { logic = "AND"|"OR", conditions = { <cond>, ... } }.
-- (Structured so a condition could later itself be a nested group.)
function CDM:EvalTrigger(trigger)
  local conds = trigger and trigger.conditions
  if not conds or #conds == 0 then return nil end
  if (trigger.logic or "AND") == "OR" then
    for _, c in ipairs(conds) do if self:EvalCondition(c) then return true end end
    return false
  else
    for _, c in ipairs(conds) do if not self:EvalCondition(c) then return false end end
    return true
  end
end

-- --------------------------------------------------------------------------
-- Visibility: player/game-state gate that ANDs with the trigger. All plain
-- game APIs (no secret aura data). AND across conditions; a display with no
-- constraints is always eligible. Multi-value specs are OR-within.
-- --------------------------------------------------------------------------
local function HasVisibilityConstraints(v)
  if not v then return false end
  if v.combat or v.target or v.casting or v.mounted or v.vehicle or v.instance
     or v.encounter or v.resting or v.stealthed or v.group or v.raid or v.warmode
     or v.alive or v.spellKnown then return true end
  if v.specs and next(v.specs) then return true end
  return false
end
CDM.HasVisibilityConstraints = HasVisibilityConstraints

function CDM:VisibilityGate(cfg)
  local v = cfg and cfg.visibility
  if not v then return true end
  if v.combat == "in"  and not InCombatLockdown() then return false end
  if v.combat == "out" and InCombatLockdown() then return false end
  if v.target == "has"  and not UnitExists("target") then return false end
  if v.target == "none" and UnitExists("target") then return false end
  if v.casting and not (UnitCastingInfo("player") or UnitChannelInfo("player")) then return false end
  if v.mounted and not IsMounted() then return false end
  if v.vehicle and not (UnitInVehicle("player") or (HasVehicleUI and HasVehicleUI())) then return false end
  if v.instance and not IsInInstance() then return false end
  if v.encounter and not IsEncounterInProgress() then return false end
  if v.resting and not IsResting() then return false end
  if v.stealthed and not IsStealthed() then return false end
  if v.group and not IsInGroup() then return false end
  if v.raid and not IsInRaid() then return false end
  if v.warmode and not (C_PvP and C_PvP.IsWarModeActive and C_PvP.IsWarModeActive()) then return false end
  if v.alive and UnitIsDeadOrGhost("player") then return false end
  if v.specs and next(v.specs) then
    local idx = GetSpecialization and GetSpecialization()
    local specID = idx and GetSpecializationInfo and GetSpecializationInfo(idx)
    if not (specID and v.specs[specID]) then return false end
  end
  if v.spellKnown then
    local id = v.spellKnown
    local known = (IsSpellKnown and IsSpellKnown(id)) or (IsPlayerSpell and IsPlayerSpell(id))
    if not known then return false end
  end
  return true
end

-- A tiny throttled poll re-evaluates displays so visibility conditions (combat,
-- target, casting, …) update live. Runs ONLY while some display uses visibility.
function CDM:UpdateVisibilityPoll()
  local uses = false
  local db = GA.db and GA.db.displays
  if db then
    for _, cfg in pairs(db) do
      if cfg.enabled ~= false and HasVisibilityConstraints(cfg.visibility) then uses = true; break end
    end
  end
  if not self._visFrame then
    local fr = CreateFrame("Frame"); fr._acc = 0
    fr:SetScript("OnUpdate", function(self2, dt)
      self2._acc = self2._acc + dt
      if self2._acc >= 0.2 then self2._acc = 0; CDM:RefreshDisplays() end
    end)
    fr:Hide()
    self._visFrame = fr
  end
  if uses then self._visFrame:Show() else self._visFrame:Hide() end
end

function CDM:EvalDisplay(id, cfg)
  if not self:VisibilityGate(cfg) then return false end  -- context gate ANDs with trigger
  local t = cfg.trigger
  if t and t.conditions and #t.conditions > 0 then
    return self:EvalTrigger(t)
  end
  local sid = cfg.spellID  -- auto-behavior keys off the display's OWN tracked spell
  if self.kind[sid] == "cooldown" then
    local a = self.available[sid]; if a == nil then a = true end
    return a == true
  end
  return self.buffActive[sid] == true
end

-- Re-evaluate every display and show/hide it. Sound fires on a hidden->shown
-- edge unless `silent` (used for the initial sync so a reload doesn't blast sound).
function CDM:RefreshDisplays(silent)
  if not GA.Displays then return end
  local db = GA.db and GA.db.displays
  if not db then return end
  -- While Blizzard Edit Mode is open the CDM shows SAMPLE data (everything looks
  -- active), which our mirror would otherwise reflect as real — flipping auras on
  -- and firing sounds. Freeze display updates then (unless our own config panel is
  -- forcing a positioning preview). `_emSettling` extends the freeze briefly past
  -- Edit Mode EXIT: ExitEditMode() clears editModeActive on its first line, then
  -- tears down the sample data — those teardown transitions would otherwise leak a
  -- stray show/sound. Real state re-syncs via a silent Discover once it settles.
  if (EditModeActive() or self._emSettling) and not GA.Displays.forced then return end
  for sid, cfg in pairs(db) do
    if cfg.enabled ~= false then
      local show = self:EvalDisplay(sid, cfg)
      if show == true then
        if not self.lastShown[sid] and not silent then self:PlaySound(sid, cfg) end
        self.lastShown[sid] = true
        GA.Displays:Show(sid)
      elseif show == false then
        self.lastShown[sid] = false
        GA.Displays:Hide(sid)
      end
      -- nil = unknown (secret): leave the display as-is
    end
  end
end

-- Reseed availability for every tracked NON-charge cooldown from GetSpellCooldown.
-- Only meaningful when the values are readable (out of combat / non-restricted) —
-- guarded so a secret value in combat just leaves the current mirror untouched.
function CDM:SeedAvailability()
  for cdFrame, sid in pairs(self.cdFrameToSpell) do
    if not self.isCharge[sid] then
      pcall(function()
        local cdi = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(sid)
        if cdi and not issecret(cdi.startTime) and not issecret(cdi.duration) then
          local st, du = cdi.startTime, cdi.duration
          local onCd = (st and st > 0 and du and du > 0 and (st + du) > GetTime()) and true or false
          self.available[sid] = not onCd
        end
      end)
    end
  end
end

function CDM:HookCooldownGlobals()
  if self._cdGlobalsHooked then return end
  self._cdGlobalsHooked = true
  if type(CooldownFrame_Set) == "function" then
    hooksecurefunc("CooldownFrame_Set", function(cdFrame)
      local sid = CDM.cdFrameToSpell[cdFrame]
      if not sid then return end
      -- Every spell cast triggers the GLOBAL cooldown, and the CDM re-runs
      -- CooldownFrame_Set on this item's widget to redraw — even though the spell
      -- itself is NOT on its own cooldown. Marking it unavailable then would stick
      -- it "on cooldown" until a real off-cd transition. So skip while on GCD; only
      -- an OFF-GCD Set means the spell actually went on its real cooldown.
      local item = CDM.cdFrameToItem[cdFrame]
      if item then
        local gcd = item.isOnGCD
        if not issecret(gcd) and gcd == true then return end
      end
      CDM.available[sid] = false
      CDM:RefreshDisplays()
    end)
  end
  if type(CooldownFrame_Clear) == "function" then
    hooksecurefunc("CooldownFrame_Clear", function(cdFrame)
      local sid = CDM.cdFrameToSpell[cdFrame]
      if sid then CDM.available[sid] = true; CDM:RefreshDisplays() end
    end)
  end
end


-- Active-state change on a bound CDM item frame -> drive the display.
local function OnItemActiveChanged(itemFrame)
  local spellID = CDM.frameToSpell[itemFrame]
  if not spellID or CDM.kind[spellID] ~= "buff" then return end
  local ok, active = pcall(itemFrame.IsActive, itemFrame)
  if not ok then return end
  if issecret(active) then
    CDM.buffActive[spellID] = nil          -- unknown (secret); leave displays as-is
  else
    CDM.buffActive[spellID] = active and true or false
  end
  CDM:RefreshDisplays()
end

-- (Re)bind every configured display to its CDM item frame + hook + initial sync.
function CDM:Discover()
  wipe(self.frameToSpell)
  wipe(self.cdFrameToSpell)
  wipe(self.cdFrameToItem)
  wipe(self.isCharge)
  if GA.Displays then GA.Displays:RefreshAll() end

  local db = GA.db and GA.db.displays
  if not db then return end
  local watch = self:WatchedSpells()
  local viewers = AllViewers()

  for spellID in pairs(watch) do
    for _, viewer in ipairs(viewers) do
      ForEachItem(viewer, function(frame)
        if not frame.GetCooldownInfo then return end
        local ok, info = pcall(frame.GetCooldownInfo, frame)
        if not ok or not InfoMatchesSpell(info, spellID) then return end

        self.frameToSpell[frame] = spellID

        -- Kind (buff vs cooldown) from the item's category (config, non-secret).
        local kind = "buff"
        local cat = info.category
        if cat ~= nil and not issecret(cat) and (cat == 0 or cat == 1) then kind = "cooldown" end
        self.kind[spellID] = kind

        -- Hook active-state changes (buff up/down) once per frame object.
        if not frame.__gaHooked and type(frame.OnActiveStateChanged) == "function" then
          frame.__gaHooked = true
          hooksecurefunc(frame, "OnActiveStateChanged", OnItemActiveChanged)
        end

        if kind == "cooldown" then
          local charge = false
          if info.charges ~= nil and not issecret(info.charges) then charge = (info.charges == true) end
          self.isCharge[spellID] = charge

          if charge then
            -- Charge spells (Aimed Shot): "have >=1 charge" is SECRET in combat
            -- (GetSpellCharges + GetSpellCastCount are both SecretWhenCooldownsRestricted;
            -- IsSpellUsable ignores charges). No readable signal → leave availability
            -- UNKNOWN so a cd_ready condition on a charge spell won't falsely fire.
            -- (Proc detection via C_SpellActivationOverlay is the only partial signal.)
            self.available[spellID] = nil
          else
            -- Single-cooldown spells (Rapid Fire): mirror Blizzard's cooldown transitions.
            local cdFrame = frame.GetCooldownFrame and frame:GetCooldownFrame()
            if cdFrame then self.cdFrameToSpell[cdFrame] = spellID; self.cdFrameToItem[cdFrame] = frame end
            pcall(function()
              local cdi = C_Spell.GetSpellCooldown(spellID)
              if cdi and not issecret(cdi.startTime) and not issecret(cdi.duration) then
                local st, du = cdi.startTime, cdi.duration
                local onCd = (st and st > 0 and du and du > 0 and (st + du) > GetTime()) and true or false
                self.available[spellID] = not onCd
              end
            end)
            if not frame.__gaCDHooked and type(frame.OnCooldownDone) == "function" then
              frame.__gaCDHooked = true
              hooksecurefunc(frame, "OnCooldownDone", function(self2)
                local sid = CDM.frameToSpell[self2]
                if sid and not CDM.isCharge[sid] then CDM.available[sid] = true; CDM:RefreshDisplays() end
              end)
            end
          end
        else
          -- Buff: capture initial active-state (plain out of combat; confirmed non-secret).
          local ok2, active = pcall(frame.IsActive, frame)
          if ok2 and not issecret(active) then
            self.buffActive[spellID] = active and true or false
          end
        end

        if GA.Displays then GA.Displays:SetCooldownEnabled(spellID, false) end
      end)
    end
  end

  self:UpdateVisibilityPoll()  -- enable the visibility poll if any display uses it
  self:RefreshDisplays(true)   -- silent initial sync (no sound on reload)
  self:ApplyBlizzardHide()     -- re-assert the CDM-hide toggle after any re-pool
end

-- --------------------------------------------------------------------------
-- Hide Blizzard's Cooldown Manager (optional, global). We MIRROR the CDM's
-- state, so the viewers must keep updating — and CooldownViewerMixin:OnHide()
-- unregisters UNIT_AURA/SPELL_UPDATE_COOLDOWN (verified in client source), so a
-- real Hide() would silently break tracking. Instead we drive only ALPHA: 0 to
-- hide, restored to Blizzard's own opacity to show. IsShown() stays true, so the
-- viewers keep firing the transitions our mirror listens to.
--
-- Two things fight a naive SetAlpha(0): (1) each viewer's Edit Mode Opacity
-- setting calls SetAlpha(opacity/100) on every settings re-apply (login, layout,
-- spec change, edit-mode exit) — countered by the UpdateSystemSettingOpacity hook
-- in HookViewers; (2) Edit Mode itself, where the user needs to see the viewer —
-- countered by suspending while EditModeActive().
-- --------------------------------------------------------------------------
function CDM:ApplyBlizzardHide()
  local hide = (GA.db and GA.db.hideBlizzardCDM) and true or false
  local editing = EditModeActive()
  local dim = hide and not editing
  for _, v in ipairs(AllViewers()) do
    if v then
      if dim then
        v:SetAlpha(0)
      elseif self._blizzForced or editing then
        -- Only un-dim if WE dimmed it (or we're entering Edit Mode). Restore via
        -- Blizzard's own opacity apply so a user's custom CDM opacity is preserved.
        local ok = v.UpdateSystemSettingOpacity and pcall(v.UpdateSystemSettingOpacity, v)
        if not ok then v:SetAlpha(1) end
      end
    end
  end
  self._blizzForced = dim
end

-- Flip / set the global "hide Blizzard CDM" toggle. Returns the new state.
function CDM:ToggleBlizzardHide(on)
  if GA.db then
    if on == nil then on = not GA.db.hideBlizzardCDM end
    GA.db.hideBlizzardCDM = on and true or false
  end
  self:ApplyBlizzardHide()
  return GA.db and GA.db.hideBlizzardCDM
end

-- Re-run Discover after the CDM rebuilds its pooled frames. Hook the four
-- persistent viewer frame instances (not the shared mixin table).
function CDM:HookViewers()
  for _, v in ipairs(AllViewers()) do
    if v and v.RefreshLayout and not v.__gaLayoutHooked then
      v.__gaLayoutHooked = true
      hooksecurefunc(v, "RefreshLayout", function()
        C_Timer.After(0, function() CDM:Discover() end)
      end)
    end
    -- Re-assert our hide right after Blizzard re-applies its Opacity setting
    -- (it SetAlpha(opacity/100)s on login, layout apply, spec change, edit exit).
    if v and v.UpdateSystemSettingOpacity and not v.__gaOpacityHooked then
      v.__gaOpacityHooked = true
      hooksecurefunc(v, "UpdateSystemSettingOpacity", function(self2)
        if GA.db and GA.db.hideBlizzardCDM and not EditModeActive() then self2:SetAlpha(0) end
      end)
    end
  end
end

function CDM:Init()
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("PLAYER_ENTERING_WORLD")
  ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
  ev:RegisterEvent("PLAYER_REGEN_ENABLED")   -- left combat: reseed availability (readable OOC)
  ev:RegisterEvent("SPELL_UPDATE_COOLDOWN")
  if C_CooldownViewer then
    ev:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
    ev:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
  end
  ev:SetScript("OnEvent", function(_, event)
    if event == "SPELL_UPDATE_COOLDOWN" then
      CDM:RefreshDisplays()
    elseif event == "PLAYER_REGEN_ENABLED" then
      CDM:SeedAvailability()
      CDM:RefreshDisplays()
    else
      CDM:HookViewers()
      CDM:Discover()
    end
  end)
  self._events = ev

  -- Edit Mode opening/closing flips whether we suspend the CDM-hide (so the user
  -- can see + drag the viewers while arranging their UI).
  if EventRegistry and not self._editModeHooked then
    self._editModeHooked = true
    EventRegistry:RegisterCallback("EditMode.Enter", function()
      CDM._emSettling = false
      CDM:ApplyBlizzardHide()
    end, self)
    EventRegistry:RegisterCallback("EditMode.Exit", function()
      CDM:ApplyBlizzardHide()
      -- Suppress the sample-data teardown transitions, then re-sync to real state.
      CDM._emSettling = true
      C_Timer.After(0.4, function()
        CDM._emSettling = false
        CDM:Discover()   -- Discover ends with a SILENT RefreshDisplays (no sound)
      end)
    end, self)
  end

  self:HookCooldownGlobals()
  self:HookViewers()
  self:Discover()
  self:ApplyBlizzardHide()
end

function CDM:UpdateCooldowns()
  if not GA.Displays then return end
  local db = GA.db and GA.db.displays
  if not db then return end
  for id, cfg in pairs(db) do            -- per DISPLAY (a spell may back several)
    if self.kind[cfg.spellID] == "cooldown" then GA.Displays:UpdateCooldown(id) end
  end
end

-- --------------------------------------------------------------------------
-- /ga debug — diagnostic dump. Secret-safe (never compares a secret).
-- --------------------------------------------------------------------------
local function fmtBool(v)
  if v == nil then return "nil" end
  if issecret(v) then return "SECRET" end
  return tostring(v)
end

function CDM:Debug()
  GA.msg("=== CDM debug ===")

  if C_CooldownViewer and C_CooldownViewer.IsCooldownViewerAvailable then
    local avail, reason = C_CooldownViewer.IsCooldownViewerAvailable()
    print("  CooldownViewer available:", tostring(avail), reason or "")
  else
    print("  C_CooldownViewer: |cffff5555MISSING|r (not Midnight?)")
  end

  if C_RestrictedActions then
    print(("  restricted: any=%s combat=%s instance=%s"):format(
      tostring(C_RestrictedActions.IsRestricted and C_RestrictedActions.IsRestricted()),
      tostring(C_RestrictedActions.IsInRestrictedCombat and C_RestrictedActions.IsInRestrictedCombat()),
      tostring(C_RestrictedActions.IsInRestrictedInstance and C_RestrictedActions.IsInRestrictedInstance())))
  end

  local E = Enum and Enum.CooldownViewerCategory
  local cats = E and {
    { "Essential", E.Essential }, { "Utility", E.Utility },
    { "TrackedBuff", E.TrackedBuff }, { "TrackedBar", E.TrackedBar },
  } or {}
  for _, c in ipairs(cats) do
    local name, cat = c[1], c[2]
    local ids = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
            and C_CooldownViewer.GetCooldownViewerCategorySet(cat)
    local n = (type(ids) == "table") and #ids or 0
    print(("  [%s] %d cooldownID(s)"):format(name, n))
    if type(ids) == "table" then
      for _, id in ipairs(ids) do
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(id)
        local sid = info and info.spellID
        local nm = (sid and not issecret(sid) and C_Spell and C_Spell.GetSpellName)
                   and (C_Spell.GetSpellName(sid) or "") or ""
        print(("      id=%s spellID=%s %s"):format(tostring(id), fmtBool(sid), nm))
      end
    end
  end

  local db = (GA.db and GA.db.displays) or {}
  for _id, cfg in pairs(db) do
    local sid = cfg.spellID
    local frame
    for f, fs in pairs(self.frameToSpell) do
      if fs == sid then frame = f; break end
    end
    if frame then
      local kind = self.kind[sid] or "?"
      local _, active = pcall(frame.IsActive, frame)
      local extra = ""
      if kind == "cooldown" then
        extra = ("  |cffffd200avail=%s charge=%s|r"):format(
          tostring(self.available[sid]), tostring(self.isCharge[sid]))
        pcall(function()
          local u = C_Spell and C_Spell.IsSpellUsable and C_Spell.IsSpellUsable(sid)
          extra = extra .. ("  IsSpellUsable=%s"):format(fmtBool(u))
        end)
        pcall(function()
          local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(sid)
          if ci then extra = extra .. ("  charges=%s/%s"):format(fmtBool(ci.currentCharges), fmtBool(ci.maxCharges)) end
        end)
      end
      print(("  display %s (%s) [%s]: |cff55ff55FOUND|r active=%s (secret %s)%s"):format(
        tostring(sid), cfg.label or "?", kind, fmtBool(active), tostring(issecret(active)), extra))
    else
      print(("  display %s (%s): |cffff5555NOT FOUND|r — is it placed in your Cooldown Manager?"):format(
        tostring(sid), cfg.label or "?"))
    end
  end
end

-- /ga trace — focused per-display diagnostic: is it shown, what are our mirrored
-- trigger inputs (buffActive / available), the item's cached cooldown fields, and
-- how each trigger condition currently evaluates. Run IN the state you're debugging
-- (e.g. in combat with the buff up + cooldown ready). Secret-safe (fmtBool guards).
function CDM:Trace()
  GA.msg("=== trigger trace (run while reproducing the problem) ===")
  local db = (GA.db and GA.db.displays) or {}
  for id, cfg in pairs(db) do
    if cfg.enabled ~= false then
      local sid = cfg.spellID              -- tracked spell (state lookups); id = display key (frame)
      local frame
      for f, fs in pairs(self.frameToSpell) do if fs == sid then frame = f; break end end
      local dispFrame = GA.Displays and GA.Displays.frames and GA.Displays.frames[id]
      local shown = dispFrame and dispFrame:IsShown() and true or false
      print(("|cff936bff%s|r (%s) [%s]  shown=%s%s"):format(
        cfg.label or "?", tostring(sid), self.kind[sid] or "?", tostring(shown),
        frame and "" or "  |cffff5555<item NOT found>|r"))
      print(("   mirror: buffActive=%s  available=%s  charge=%s"):format(
        fmtBool(self.buffActive[sid]), fmtBool(self.available[sid]), tostring(self.isCharge[sid])))
      if frame and self.kind[sid] == "cooldown" then
        print(("   item: isOnActualCooldown=%s cooldownIsActive=%s isOnGCD=%s start=%s"):format(
          fmtBool(frame.isOnActualCooldown), fmtBool(frame.cooldownIsActive),
          fmtBool(frame.isOnGCD), fmtBool(frame.cooldownStartTime)))
      end
      local t = cfg.trigger
      if t and t.conditions and #t.conditions > 0 then
        print(("   trigger %s:"):format(t.logic or "AND"))
        for _, c in ipairs(t.conditions) do
          local nm = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(c.spellID)) or "?"
          print(("      [%s] %s (%s) => %s"):format(c.state, nm, tostring(c.spellID), tostring(self:EvalCondition(c))))
        end
        print(("   => EvalDisplay=%s"):format(tostring(self:EvalDisplay(id, cfg))))
      else
        print("   (no trigger — auto behavior)")
      end
    end
  end
end

-- /ga charges — which cooldowns support "available" tracking (charge spells don't).
-- Run OUT OF COMBAT: charge counts are secret in combat.
function CDM:ReportCharges()
  GA.msg("availability support by ability (run OUT of combat for accurate charge info):")
  local E = Enum and Enum.CooldownViewerCategory
  if not (E and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet) then
    print("  Cooldown Manager unavailable."); return
  end
  for _, c in ipairs({ { "Essential", E.Essential }, { "Utility", E.Utility } }) do
    print(("  |cffffd200%s cooldowns:|r"):format(c[1]))
    local ids = C_CooldownViewer.GetCooldownViewerCategorySet(c[2])
    if type(ids) == "table" then
      for _, id in ipairs(ids) do
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(id)
        local sid = info and info.spellID
        if sid and not issecret(sid) then
          local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(sid)) or ("Spell " .. sid)
          local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(sid)
          local mx = ci and ci.maxCharges
          if mx ~= nil and issecret(mx) then
            print(("      %s — |cff999999? run out of combat|r"):format(name))
          elseif mx and mx > 1 then
            print(("      %s — |cffff5555charges (%d): availability NOT trackable|r"):format(name, mx))
          else
            print(("      %s — |cff55ff55works|r"):format(name))
          end
        end
      end
    end
  end
  print("  |cff55ff55Tracked Buffs / Bars always work|r (via 'buff is active').")
end
