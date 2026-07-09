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

-- Presence WITHOUT reading (ArcUI's HasAuraInstanceID, API-NOTES §9.1): nil/0 ⇒ absent;
-- a SECRET id ⇒ PRESENT (can't compare it, but its existence IS the signal); plain non-zero
-- ⇒ present. Never trips the secret-value wall.
local function isPresent(v)
  if v == nil then return false end
  if issecret(v) then return true end
  if type(v) == "number" and v == 0 then return false end
  return true
end

-- The live duration OBJECT for an aura instance on `unit`, or nil. We NEVER read the time —
-- we hand the object to StatusBar:SetTimerDuration (an AllowedWhenUntainted sink, exactly like
-- the charge shadow's SetCooldownFromDurationObject, so a duration OBJECT is tainted-safe even
-- when the underlying value is secret; API-NOTES §9.3). Validate the instance first (a stale id
-- is the real crash risk — matches ArcUI) then return the object. All pcall-guarded: a secret
-- auraInstanceID (possible in instances) makes GetAuraDataByAuraInstanceID throw from tainted
-- code → we degrade to nil (bar shows, just no drain), never a Lua error.
local function GetAuraDurationObject(unit, aiid)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDuration and C_UnitAuras.GetAuraDataByAuraInstanceID) then return nil end
  if not unit or not UnitExists(unit) then return nil end
  if not isPresent(aiid) then return nil end
  local durObj
  pcall(function()
    if C_UnitAuras.GetAuraDataByAuraInstanceID(unit, aiid) then
      durObj = C_UnitAuras.GetAuraDuration(unit, aiid)
    end
  end)
  return durObj
end

local SOUND_ON_SHOW = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
local THROTTLE = 1.0  -- seconds; min gap between sounds per display

CDM.frameToSpell   = {} -- CDM item frame -> spellID (rebuilt on Discover)
CDM.frameKind      = {} -- CDM item frame -> "buff" | "cooldown" (per-FRAME role). A spell placed
                        -- in TWO viewers (e.g. Haunt in Essential AND BuffBar) gets one frame of
                        -- each; routing state by this (not by the per-spell `kind`) stops the
                        -- cooldown frame from clobbering the aura frame's buffActive, and back.
CDM.lastPlay       = {} -- spellID -> GetTime() of last sound
CDM.kind           = {} -- spellID -> "buff" | "cooldown" (per-SPELL; drives only the no-trigger
                        -- AUTO path; aura wins when a spell is enrolled as both)
CDM.available      = {} -- spellID -> bool (cooldown ready?), mirrored from Blizzard
CDM.cdFrameToSpell = {} -- Blizzard cooldown widget -> spellID (rebuilt on Discover)
CDM.cdFrameToItem  = {} -- Blizzard cooldown widget -> CDM item frame (rebuilt on Discover)
CDM.buffActive     = {} -- spellID -> bool (buff up?), mirrored from item:IsActive()
CDM.lastShown      = {} -- display spellID -> bool (was it shown last refresh?) for sound edges
CDM.isCharge       = {} -- spellID -> bool (MULTI-charge spell: availability unreadable in combat)
CDM.maxCharges     = {} -- spellID -> maxCharges (cached when readable OOC; persists across Discover)
CDM.chargeShadow   = {} -- spellID -> hidden shadow Cooldown widget (charge-spell availability, §9.3)
CDM.chargeRecharge = {} -- spellID -> 2nd shadow fed the RECHARGE timer: shown while recharging, hidden AT MAX
CDM.chargesFull    = {} -- spellID -> bool (AT MAX charges? = recharge shadow hidden); nil = unknown
CDM.auraUnit       = {} -- spellID -> "player"|"target" (from the item's non-secret selfAura, at
                        -- Discover). Which unit a Bar display's aura_dur source resolves on.

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
-- Collect every leaf spellID from a condition tree (recurses into groups, which
-- carry `.conditions` instead of a `.spellID`). Missing this = group-nested spells
-- never get mirrored, so grouped triggers silently never fire.
local function CollectCondSpells(conds, set)
  if not conds then return end
  for _, c in ipairs(conds) do
    if c.spellID then set[c.spellID] = true
    elseif c.conditions then CollectCondSpells(c.conditions, set) end
  end
end

function CDM:WatchedSpells()
  local set = {}
  local db = GA.db and GA.db.displays
  if db then
    for _id, cfg in pairs(db) do
      if cfg.enabled ~= false then
        if cfg.spellID then set[cfg.spellID] = true end   -- the display's own tracked spell
        CollectCondSpells(cfg.trigger and cfg.trigger.conditions, set)  -- + all trigger leaves (nested)
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
  elseif state == "charges_max" then
    return self.chargesFull[sid] == true   -- at MAX charges (recharge shadow hidden); unknown = false
  elseif state == "charges_notmax" then
    return self.chargesFull[sid] == false  -- spent >=1 charge / recharging; unknown = false
  end
  return false
end

-- trigger = { logic = "AND"|"OR"|"NONE", conditions = { <node>, ... } } where a node
-- is a leaf ({ spellID, state }) OR a nested group ({ logic, conditions }). AND = all
-- true, OR = any true, NONE = none true (i.e. NOT any — group-level negation). The UI
-- nests one level deep; this recursion handles any depth. Empty sub-groups (eval nil)
-- are skipped so they don't tip AND/NONE. Returns nil only when there's nothing to weigh.
function CDM:EvalTrigger(trigger)
  local conds = trigger and trigger.conditions
  if not conds or #conds == 0 then return nil end
  local logic = trigger.logic or "AND"
  local anyTrue, allTrue = false, true
  for _, c in ipairs(conds) do
    local v
    if c.conditions then v = self:EvalTrigger(c)   -- nested group
    else v = self:EvalCondition(c) end             -- leaf
    if v ~= nil then
      if v then anyTrue = true else allTrue = false end
    end
  end
  if logic == "OR" then return anyTrue
  elseif logic == "NONE" then return not anyTrue
  else return allTrue end   -- AND
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

-- Group gate: a display in a group inherits the group's on/off switch + load rule,
-- ANDed IN FRONT of the display's own visibility + trigger. The group's load rule
-- is just a `visibility` table, so VisibilityGate evaluates it with no new logic
-- (all plain game APIs — no secret aura data). No group / missing group ⇒ pass.
function CDM:GroupGate(cfg)
  local gid = cfg and cfg.group
  if not gid then return true end
  local g = GA.db and GA.db.groups and GA.db.groups[gid]
  if not g then return true end                 -- group deleted → treat as ungrouped
  if g.enabled == false then return false end   -- whole group switched off
  return self:VisibilityGate(g)                 -- reuse the visibility engine on g.visibility
end

-- A tiny throttled poll re-evaluates displays so visibility conditions (combat,
-- target, casting, …) update live. Runs ONLY while some display uses visibility.
function CDM:UpdateVisibilityPoll()
  local uses = false
  local db = GA.db and GA.db.displays
  local groups = GA.db and GA.db.groups
  if db then
    for _, cfg in pairs(db) do
      if cfg.enabled ~= false then
        if HasVisibilityConstraints(cfg.visibility) then uses = true; break end
        -- A group load rule (spec/combat/target/…) also needs the live poll.
        local g = cfg.group and groups and groups[cfg.group]
        if g and HasVisibilityConstraints(g.visibility) then uses = true; break end
      end
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
  if not self:GroupGate(cfg) then return false end       -- group on/off + load rule ANDs first
  if not self:VisibilityGate(cfg) then return false end  -- context gate ANDs with trigger
  local t = cfg.trigger
  if t and t.conditions and #t.conditions > 0 then
    return self:EvalTrigger(t)
  end
  -- No trigger. Two cases:
  --  • the display tracks its OWN spell (legacy) → auto-show on that spell's state.
  --  • the display has NO spell → a pure DECORATION: always show, gated only by the
  --    Group + Visibility checks above (e.g. a graphic shown only out of combat).
  local sid = cfg.spellID
  if not sid then return true end
  if self.kind[sid] == "cooldown" then
    local a = self.available[sid]; if a == nil then a = true end
    return a == true
  end
  return self.buffActive[sid] == true
end

-- Supplement availability from the CDM item's own `isOnActualCooldown` flag. It's
-- computed `not isOnGCD and cooldownIsActive`: readable (plain) OUT of combat and while
-- on the GCD (short-circuits to false), but SECRET in combat when off-GCD — i.e. exactly
-- when the real cooldown matters. So this is an OUT-OF-COMBAT accuracy pass (GCD-correct);
-- in-combat availability comes from the CooldownFrame_Set/Clear widget hooks. Guarded:
-- a secret value is skipped, leaving the last-known (hook-provided) value.
function CDM:SyncCooldowns()
  for frame, sid in pairs(self.frameToSpell) do
    if self.frameKind[frame] == "cooldown" and not self.isCharge[sid] then
      local v = frame.isOnActualCooldown
      if type(v) == "boolean" and not issecret(v) then
        self.available[sid] = not v
      end
    end
  end
end

-- --------------------------------------------------------------------------
-- Bar displays — the duration OBJECT feed (API-NOTES §9, BARS-DESIGN.md).
-- A Bar (cfg.kind=="bar") reuses the whole show/hide pipeline via its cfg.spellID (the
-- auto-path in EvalDisplay drives it from the source aura's buffActive mirror — same proven
-- path the DoT textures use). The ONLY bar-specific work is feeding the source aura's live
-- DURATION OBJECT to the StatusBar so it drains itself, secret-safely. We resolve the aura's
-- native auraInstanceID off its CDM item frame (§9.1) and its unit from selfAura.
-- --------------------------------------------------------------------------

-- Which unit a bar's source aura is actually on. An explicit cfg.bar.unit override wins; else
-- start from the selfAura-derived unit — but selfAura LIES for some auras (Freezing/Shatter is
-- selfAura=true yet the debuff sits on the TARGET, verified probe: player[absent] target[PRESENT]).
-- So: if the aura resolves on the selfAura unit, use it; else — since the item's auraInstanceID IS
-- present somewhere (frame says so) — it must be on the OTHER unit. This auto-corrects the lie
-- without a blind "try both" (which §9.1 warns can false-positive on the wrong unit).
function CDM:ResolveAuraUnit(cfg, sid, aiid)
  local override = cfg.bar and cfg.bar.unit
  if override then return override end
  local primary = self.auraUnit[sid] or "target"
  if UnitExists(primary) and isPresent(aiid) then
    local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, primary, aiid)
    if ok and data ~= nil then return primary end
  end
  return (primary == "player") and "target" or "player"
end

-- Find a bar's source aura on its CDM item frame → returns (unit, auraInstanceID) or nil.
-- Shared by every aura-reading bar mode (aura_dur duration, stacks count).
function CDM:BarSource(cfg)
  local sid = cfg and cfg.spellID
  if not sid then return nil end
  for frame, fsid in pairs(self.frameToSpell) do
    if fsid == sid and self.frameKind[frame] == "buff" then
      local aiid = frame.auraInstanceID
      if isPresent(aiid) then
        return self:ResolveAuraUnit(cfg, sid, aiid), aiid
      end
    end
  end
  return nil
end

-- The live duration object for a bar's source aura (aura_dur mode), or nil.
function CDM:BarDurationObject(cfg)
  local unit, aiid = self:BarSource(cfg)
  if not unit then return nil end
  return GetAuraDurationObject(unit, aiid)
end

-- The source aura's stack count (stacks mode). May be a SECRET number in combat — we NEVER
-- operate on it, just return it for the caller to hand to StatusBar:SetValue / FontString:SetText
-- (both AllowedWhenTainted, so they render a secret). PLAIN out of combat. nil if unresolved.
function CDM:BarStackValue(cfg)
  local unit, aiid = self:BarSource(cfg)
  if not unit or not UnitExists(unit) then return nil end
  local val
  pcall(function()
    local data = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, aiid)
    if data ~= nil and not issecret(data) then val = data.applications end
  end)
  return val
end

-- Re-feed every SHOWN bar's duration object. Called on UNIT_AURA (catches DoT refresh/extension)
-- and PLAYER_TARGET_CHANGED (catches swapping between two DoTted targets, where no active-state
-- transition fires so RefreshDisplays wouldn't run). Cheap: only touches currently-shown bars.
function CDM:RefeedBars()
  if not (GA.Displays and GA.Displays.UpdateBar) then return end
  local db = GA.db and GA.db.displays; if not db then return end
  for id, cfg in pairs(db) do
    if cfg.kind == "bar" and cfg.enabled ~= false and self.lastShown[id] then
      GA.Displays:UpdateBar(id)
    end
  end
end

-- Register UNIT_AURA + PLAYER_TARGET_CHANGED only while at least one bar exists (they fire
-- a lot; no reason to pay for them otherwise). Mirrors the UpdateVisibilityPoll gating idea.
function CDM:UpdateBarEvents()
  if not self._events then return end
  local any = false
  local db = GA.db and GA.db.displays
  if db then
    for _, cfg in pairs(db) do
      if cfg.kind == "bar" and cfg.enabled ~= false then any = true; break end
    end
  end
  if any and not self._barEvents then
    self._barEvents = true
    self._events:RegisterEvent("UNIT_AURA")
    self._events:RegisterEvent("PLAYER_TARGET_CHANGED")
  elseif not any and self._barEvents then
    self._barEvents = false
    self._events:UnregisterEvent("UNIT_AURA")
    self._events:UnregisterEvent("PLAYER_TARGET_CHANGED")
  end
end

-- --------------------------------------------------------------------------
-- Charge-spell availability via a hidden "shadow" Cooldown  (API-NOTES §9.3).
-- The charge COUNT is secret in combat, but "have >=1 charge" is derivable
-- secret-safely: feed the spell's GCD-stripped cooldown DURATION OBJECT into a
-- throwaway Cooldown widget (SetCooldownFromDurationObject does NOT throw for an
-- OBJECT even when the underlying value is secret — verified in combat), then
-- read the widget's shown-state — shown ⇔ the spell is on its real cooldown ⇔
-- 0 charges; hidden ⇔ >=1 charge castable. `mainShown` flips exactly at the
-- 0<->1 charge boundary (= exactly when availability changes), so OnShow/OnHide
-- give us the transition with no polling. Verified on Aimed Shot 2->1->0->1->2.
-- --------------------------------------------------------------------------
local function mkShadowCooldown()
  local cd = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
  if cd.SetDrawSwipe then cd:SetDrawSwipe(false) end
  if cd.SetDrawEdge then cd:SetDrawEdge(false) end
  if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
  return cd
end

function CDM:EnsureChargeShadow(spellID)
  local cd = self.chargeShadow[spellID]
  if cd then return cd end
  -- Shadow A (availability): fed the REAL cooldown duration — present only at 0 charges.
  -- shown => on real cd => 0 charges => unavailable; hidden => >=1 charge castable.
  cd = mkShadowCooldown()
  cd:HookScript("OnShow", function() CDM.available[spellID] = false; CDM:RefreshDisplays() end)
  cd:HookScript("OnHide", function() CDM.available[spellID] = true;  CDM:RefreshDisplays() end)
  self.chargeShadow[spellID] = cd
  -- Shadow B (fullness): fed the RECHARGE duration — present while recharging, absent AT MAX.
  -- shown => recharging => NOT at max; hidden => at max charges. Together with Shadow A this
  -- reads out the count: max = {A hidden, B hidden}; partial = {A hidden, B shown}; 0 =
  -- {A shown, B shown}. Exact for 2-charge spells; full/partial/empty buckets for 3+.
  local rc = mkShadowCooldown()
  rc:HookScript("OnShow", function() CDM.chargesFull[spellID] = false; CDM:RefreshDisplays() end)
  rc:HookScript("OnHide", function() CDM.chargesFull[spellID] = true;  CDM:RefreshDisplays() end)
  self.chargeRecharge[spellID] = rc
  return cd
end

-- (Re)feed a charge spell's shadow from its current cooldown. GetSpellCooldownDuration
-- returns a real object only while the spell itself is on cooldown (0 charges) and nil
-- while a charge is available, so the widget shows/hides to match. `seed` (Discover, out
-- of combat where reads are stable) also syncs availability straight from IsShown() to
-- cover the case where no OnShow/OnHide transition fires (e.g. already at full charges).
-- Feed one shadow widget from a duration function; on `seed`, also read IsShown() straight
-- into `store[spellID]` (true when the widget is HIDDEN — the "good" end for both signals:
-- available = cd not shown, atMax = recharge not shown).
local function feedShadow(cd, durFn, spellID, seed, store)
  if not cd or not durFn then return end
  local ok, dur = pcall(durFn, spellID, true)   -- true = GCD-stripped
  if not ok then return end
  if dur ~= nil then
    if cd.SetCooldownFromDurationObject then pcall(cd.SetCooldownFromDurationObject, cd, dur, true) end
  elseif cd.SetCooldown then
    pcall(cd.SetCooldown, cd, 0, 0)    -- no duration => hide
  end
  if seed and store then
    local shown
    if pcall(function() shown = cd:IsShown() end) then
      store[spellID] = not (shown and true or false)
    end
  end
end

function CDM:FeedChargeShadow(spellID, seed)
  local CS = C_Spell
  if not CS then return end
  -- Shadow A ← real cooldown (present at 0 charges) → availability (>=1 charge).
  feedShadow(self.chargeShadow[spellID],   CS.GetSpellCooldownDuration, spellID, seed, self.available)
  -- Shadow B ← recharge timer (present while recharging) → fullness (at max charges).
  feedShadow(self.chargeRecharge[spellID], CS.GetSpellChargeDuration,   spellID, seed, self.chargesFull)
end

-- Exact charge count when secret-safely derivable: the endpoints (max / 0) are always known;
-- the partial middle is exact only for 2-charge spells. Returns a number, or nil when unknown
-- (untracked, or a 3+ charge spell mid-recharge). Drives the Pass-2 count text overlay.
function CDM:ChargeCount(spellID)
  if not self.isCharge[spellID] then return nil end
  local avail, full = self.available[spellID], self.chargesFull[spellID]
  if full == true then return self.maxCharges[spellID] end   -- at max
  if avail == false then return 0 end                        -- depleted
  if avail == true and full == false then                    -- partial (>=1, <max)
    if self.maxCharges[spellID] == 2 then return 1 end
    return nil                                               -- 3+ charge: exact middle unreadable
  end
  return nil
end

-- Which spell's charge count a display's count-text should show: the display's OWN spell if it
-- uses charges, else the first charge spell among its trigger conditions. nil = nothing to count.
function CDM:DisplayChargeSpell(cfg)
  if not cfg then return nil end
  if cfg.spellID and self.isCharge[cfg.spellID] then return cfg.spellID end
  if cfg.trigger and cfg.trigger.conditions then
    local set = {}
    CollectCondSpells(cfg.trigger.conditions, set)
    for sid in pairs(set) do
      if self.isCharge[sid] then return sid end
    end
  end
  return nil
end

function CDM:FeedAllChargeShadows()
  for spellID in pairs(self.chargeShadow) do
    if self.isCharge[spellID] then self:FeedChargeShadow(spellID) end
  end
end

-- Re-evaluate every display and show/hide it. Sound fires on a hidden->shown
-- edge unless `silent` (used for the initial sync so a reload doesn't blast sound).
function CDM:RefreshDisplays(silent)
  if not GA.Displays then return end
  local db = GA.db and GA.db.displays
  if not db then return end
  self:SyncCooldowns()   -- refresh availability from the CDM's own on-cooldown flag
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
        if cfg.kind == "bar" and GA.Displays.UpdateBar then
          GA.Displays:UpdateBar(sid)   -- feed the source aura's duration object → the bar drains
        end
        if cfg.text and cfg.text.showCount and GA.Displays.RefreshCountText then
          GA.Displays:RefreshCountText(sid)   -- live charge-count update (Pass 2)
        end
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
  -- Route by the FRAME's role, not the spell's. A spell enrolled as BOTH a cooldown
  -- (Essential/Utility) and an aura (Buff/Bar) has two frames both hooked here; only the
  -- AURA frame may drive buffActive. Gating on CDM.kind[spellID] let the cooldown frame's
  -- IsActive (its own recharge state) overwrite the DoT state = the "goes random" bug.
  if not spellID or CDM.frameKind[itemFrame] ~= "buff" then return end
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
  wipe(self.frameKind)
  wipe(self.kind)         -- re-derived below; wiped so a spell that moved viewers/spec re-classifies
  wipe(self.cdFrameToSpell)
  wipe(self.cdFrameToItem)
  wipe(self.isCharge)
  wipe(self.auraUnit)
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
        self.frameKind[frame] = kind                        -- per-FRAME role (unambiguous)
        -- Per-SPELL kind drives only the no-trigger AUTO path. When a spell is enrolled as
        -- BOTH cooldown + aura, let the AURA win so "auto-show on this spell" means its aura.
        if self.kind[spellID] ~= "buff" then self.kind[spellID] = kind end

        -- Hook active-state changes (buff up/down) once per frame object.
        if not frame.__gaHooked and type(frame.OnActiveStateChanged) == "function" then
          frame.__gaHooked = true
          hooksecurefunc(frame, "OnActiveStateChanged", OnItemActiveChanged)
        end

        if kind == "cooldown" then
          -- `info.charges` only says "uses the charge system" — what matters is maxCharges:
          -- **1 = a normal cooldown** (trackable via the sweep, e.g. Kill Shot / Black Arrow),
          -- **>=2 = the unreadable-in-combat wall** (GetSpellCharges is secret then). maxCharges
          -- is readable OUT of combat, so cache it (persists across Discover); until confirmed,
          -- a charge-flagged spell is assumed multi (unreadable) to avoid false "ready".
          pcall(function()
            local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
            if ci and not issecret(ci.maxCharges) and ci.maxCharges then self.maxCharges[spellID] = ci.maxCharges end
          end)
          local mx = self.maxCharges[spellID]
          local charge
          if mx then charge = (mx >= 2)
          elseif info.charges == true and not issecret(info.charges) then charge = true
          else charge = false end
          self.isCharge[spellID] = charge

          if charge then
            -- MULTI-charge spells (Aimed Shot): the charge COUNT is secret in combat
            -- (GetSpellCharges/GetSpellCastCount are SecretWhenCooldownsRestricted; IsSpellUsable
            -- ignores charges), BUT availability ("have >=1 charge") is readable via a hidden
            -- shadow Cooldown fed the GCD-stripped cooldown duration object (API-NOTES §9.3,
            -- verified on Aimed Shot). Default UNKNOWN, then let the shadow derive + seed it.
            self.available[spellID] = nil
            if C_Spell and C_Spell.GetSpellCooldownDuration then
              self:EnsureChargeShadow(spellID)
              self:FeedChargeShadow(spellID, true)   -- feed + seed availability from IsShown()
            end
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
          -- Capture the aura's unit (from non-secret selfAura config) for Bar duration feeds:
          -- selfAura true ⇒ a buff on you, false ⇒ a debuff on your target.
          local sa = info.selfAura
          if sa ~= nil and not issecret(sa) then
            self.auraUnit[spellID] = (sa == true) and "player" or "target"
          end
        end

        if GA.Displays then GA.Displays:SetCooldownEnabled(spellID, false) end
      end)
    end
  end

  -- Frame-independent fallback for CHARGE cooldowns whose Essential item frame is HIDDEN while
  -- idle (`hideWhenInactive` clears the frame's cooldownID → GetCooldownInfo returns nil → the
  -- loop above can't match it → the spell never gets classified). A charge spell's availability
  -- AND fullness come from the shadow widgets (spell-API-fed, NOT the frame), so we can classify
  -- it directly from GetSpellCharges. Without this, an idle-out-of-combat Aimed Shot has no
  -- isCharge/shadow → its charge trigger states + count don't work until its frame happens to show.
  -- (maxCharges is secret in combat but persists cached from any prior out-of-combat read.)
  for spellID in pairs(watch) do
    if self.kind[spellID] == nil and not self.isCharge[spellID] then
      local mx = self.maxCharges[spellID]
      if not mx then
        pcall(function()
          local ci = C_Spell and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(spellID)
          if ci and not issecret(ci.maxCharges) and ci.maxCharges then mx = ci.maxCharges; self.maxCharges[spellID] = mx end
        end)
      end
      if mx and mx >= 2 then
        self.kind[spellID] = "cooldown"
        self.isCharge[spellID] = true
        self.available[spellID] = nil
        if C_Spell and C_Spell.GetSpellCooldownDuration then
          self:EnsureChargeShadow(spellID)
          self:FeedChargeShadow(spellID, true)   -- feed + seed availability + fullness from IsShown()
        end
      end
    end
  end

  self:UpdateVisibilityPoll()  -- enable the visibility poll if any display uses it
  self:UpdateBarEvents()       -- (un)register UNIT_AURA/target events for bar duration feeds
  self:RefreshDisplays(true)   -- silent initial sync (no sound on reload)
  self:ApplyBlizzardHide()     -- re-assert the CDM-hide toggle after any re-pool
  if GA.Displays and GA.Displays.forced and GA.Displays.RefreshForced then
    GA.Displays:RefreshForced()  -- re-assert the editor preview (selected + eye-on) after re-pool
  end
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
  ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "SPELL_UPDATE_COOLDOWN" then
      CDM:FeedAllChargeShadows()   -- re-feed charge shadows → OnShow/OnHide track availability
      CDM:RefreshDisplays()
    elseif event == "PLAYER_REGEN_ENABLED" then
      CDM:SeedAvailability()
      CDM:FeedAllChargeShadows()
      CDM:RefreshDisplays()
    elseif event == "UNIT_AURA" then
      -- Registered only while bars exist (UpdateBarEvents). A DoT refresh/extension fires this
      -- without an active-state transition, so re-feed shown bars to reflect the new duration.
      if arg1 == "target" or arg1 == "player" then CDM:RefeedBars() end
    elseif event == "PLAYER_TARGET_CHANGED" then
      CDM:RefeedBars()             -- new target ⇒ a target-debuff bar points at a new instance
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
        -- Show the OVERRIDE (e.g. Black Arrow replacing Kill Shot via a hero talent).
        local ov, ovtxt = info and info.overrideSpellID, ""
        if ov and not issecret(ov) then
          local ovnm = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(ov)) or ""
          ovtxt = ("  |cffffd200→ override=%s %s|r"):format(tostring(ov), ovnm)
        end
        print(("      id=%s spellID=%s %s%s"):format(tostring(id), fmtBool(sid), nm, ovtxt))
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

-- --------------------------------------------------------------------------
-- /ga probe [filter] — EXHAUSTIVE read-only diagnostic for the "secret-safe
-- signals" investigation (see docs: ArcUI mirrors the same CDM but tracks DoTs
-- via the native frame.auraInstanceID + C_UnitAuras, and charge readiness via a
-- hidden shadow Cooldown fed a duration object). For EVERY item in all four
-- viewers it dumps: the config struct (selfAura/hasAura/charges), which aura-
-- instance hook methods the frame exposes, the native auraInstanceID (value /
-- secret? / present?), a live C_UnitAuras presence + duration probe on BOTH
-- player and target, the item's cooldown fields, and a shadow-Cooldown readiness
-- read. Read-only; every risky read is issecret-guarded or pcall-wrapped so it
-- CANNOT throw in combat. `filter` (spell-name substring or spellID) narrows it.
-- --------------------------------------------------------------------------

-- Two reusable invisible Cooldown widgets: feed them a duration OBJECT (secret-
-- safe) and read IsShown() — a plain boolean — to learn cooldown/charge state
-- without ever reading a secret number (the "Aimed Shot" technique).
function CDM:_ProbeShadows()
  if not self._probeMainCD then
    local function mk()
      local cd = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
      if cd.SetDrawSwipe then cd:SetDrawSwipe(false) end
      if cd.SetDrawEdge then cd:SetDrawEdge(false) end
      if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
      return cd
    end
    self._probeMainCD, self._probeChargeCD = mk(), mk()
  end
  return self._probeMainCD, self._probeChargeCD
end

function CDM:Probe(filter)
  local f    = (filter and filter ~= "") and filter:lower() or nil
  local fNum = filter and tonumber(filter) or nil

  -- Format ANY value without tripping the secret-value wall.
  local function pval(v)
    if v == nil then return "nil" end
    if issecret(v) then return "SECRET("..type(v)..")" end
    local t = type(v)
    if t == "string" then return '"'..v..'"' end
    if t == "number" or t == "boolean" then return tostring(v) end
    return "<"..t..">"
  end
  -- ArcUI's HasAuraInstanceID: presence WITHOUT reading (secret non-nil = present).
  local function present(v)
    if v == nil then return false end
    if issecret(v) then return true end
    if type(v) == "number" and v == 0 then return false end
    return true
  end
  local function meth(frame, name) return type(frame[name]) == "function" and "y" or "-" end
  -- Live presence check: is this aura instance on `unit` right now?
  local function unitAura(unit, aiid)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID) then return "noAPI" end
    if not UnitExists(unit) then return "no-"..unit end
    if not present(aiid) then return "noID" end
    local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, aiid)
    if not ok then return "THREW" end
    if data == nil then return "absent" end
    if issecret(data) then return "PRESENT(secretData)" end
    local nm
    pcall(function() if type(data) == "table" and data.name and not issecret(data.name) then nm = data.name end end)
    return "PRESENT"..(nm and (":"..nm) or "")
  end
  local function auraDur(unit, aiid)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDuration) then return "noAPI" end
    if not UnitExists(unit) then return "no-"..unit end
    if not present(aiid) then return "noID" end
    local ok, d = pcall(C_UnitAuras.GetAuraDuration, unit, aiid)
    if not ok then return "THREW" end
    if d == nil then return "nil" end
    return "obj:"..type(d)
  end
  -- STACK COUNT probe (the Freezing/Shatter question): read the aura's `applications` and report
  -- whether it's a PLAIN number (=> comparable => "stacks >= X" triggers possible) or SECRET (=>
  -- display-only, like feeding a bar/text a secret value). This is the whole feasibility question.
  local function auraStacks(unit, aiid)
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID) then return "noAPI" end
    if not UnitExists(unit) then return "no-"..unit end
    if not present(aiid) then return "noID" end
    local ok, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, aiid)
    if not ok then return "THREW" end
    if data == nil then return "absent" end
    if issecret(data) then return "secretData" end
    local ap
    pcall(function() if type(data) == "table" then ap = data.applications end end)
    if ap == nil then return "nil" end
    if issecret(ap) then return "SECRET(number)" end
    return "PLAIN="..tostring(ap)
  end

  local inCombat = InCombatLockdown() and true or false
  local tName = UnitExists("target") and (UnitName("target") or "?") or "<none>"
  local spec = "?"
  pcall(function()
    local i = GetSpecialization and GetSpecialization()
    local _, nm = i and GetSpecializationInfo and GetSpecializationInfo(i)
    if nm then spec = nm end
  end)

  -- Register this capture up-front in the SavedVariables log so the deferred
  -- (+0.1s) shadow lines land in the SAVED copy too. It flushes to disk on
  -- /reload or logout; Claude then reads it straight from the file. Trimmed to
  -- the last 40. `emit` BOTH prints (live view) and appends (for the file).
  local cap = { combat = inCombat, target = tName, spec = spec, filter = filter, gt = GetTime(), lines = {} }
  local root = _G.GloomsAurasDB
  if type(root) == "table" then
    root.probeLog = root.probeLog or {}
    root.probeLog[#root.probeLog + 1] = cap
    while #root.probeLog > 40 do table.remove(root.probeLog, 1) end
    cap.n = #root.probeLog
  end
  local function emit(s) print(s); cap.lines[#cap.lines + 1] = s end

  GA.msg(("=== GA PROBE #%s stored (also saved to SavedVariables) ==="):format(tostring(cap.n or "?")))
  emit(("=== PROBE #%s | combat=%s spec=%s target=%s ==="):format(tostring(cap.n or "?"), tostring(inCombat), spec, tName))
  local UA, CS = C_UnitAuras or {}, C_Spell or {}
  emit(("  API: ByInstanceID=%s GetAuraDuration=%s ChargeDuration=%s CooldownDuration=%s"):format(
    tostring(type(UA.GetAuraDataByAuraInstanceID) == "function"),
    tostring(type(UA.GetAuraDuration) == "function"),
    tostring(type(CS.GetSpellChargeDuration) == "function"),
    tostring(type(CS.GetSpellCooldownDuration) == "function")))
  if filter and filter ~= "" then emit(("  filter: %s"):format(filter)) end

  local main, charge
  pcall(function() main, charge = self:_ProbeShadows() end)

  local viewers = {
    { "Essential", EssentialCooldownViewer }, { "Utility",  UtilityCooldownViewer },
    { "BuffIcon",  BuffIconCooldownViewer },  { "BuffBar",  BuffBarCooldownViewer },
  }
  for _, vv in ipairs(viewers) do
    local vname, viewer = vv[1], vv[2]
    if viewer then
      local n = 0; ForEachItem(viewer, function() n = n + 1 end)
      emit(("|cff936bff[%s]|r %d item(s)"):format(vname, n))
      local k = 0
      ForEachItem(viewer, function(frame)
        k = k + 1
        local info; pcall(function() info = frame.GetCooldownInfo and frame:GetCooldownInfo() end)
        -- Fallback: some cooldown items returned nil GetCooldownInfo (seen OOC on the Warlock).
        -- The registry lookup by cooldownID is reliable, so recover the struct that way.
        if not info and frame.GetCooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
          pcall(function()
            local cid = frame:GetCooldownID()
            if cid ~= nil and not issecret(cid) then info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cid) end
          end)
        end
        local sid = info and info.spellID
        local name = "?"
        if sid and not issecret(sid) and type(sid) == "number" and C_Spell and C_Spell.GetSpellName then
          name = C_Spell.GetSpellName(sid) or "?"
        end

        -- filter: skip unless name-substring or spellID matches
        if f or fNum then
          local hit = false
          if f and type(name) == "string" and name:lower():find(f, 1, true) then hit = true end
          if fNum and type(sid) == "number" and sid == fNum then hit = true end
          if not hit then return end
        end

        local aiid  = frame.auraInstanceID
        local selfA = info and info.selfAura
        local expUnit = "?"
        if selfA ~= nil and not issecret(selfA) then expUnit = (selfA == true) and "player" or "target" end

        emit(("  #%d |cffffd200%s|r (%s) cat=%s"):format(k, tostring(name), pval(sid), pval(info and info.category)))
        emit(("     struct: selfAura=%s hasAura=%s charges=%s isKnown=%s override=%s"):format(
          pval(selfA), pval(info and info.hasAura), pval(info and info.charges),
          pval(info and info.isKnown), pval(info and info.overrideSpellID)))
        emit(("     methods: SetAIInfo=%s AIInfoSet=%s AIInfoCleared=%s RefreshData=%s GetCDFrame=%s IsActive=%s"):format(
          meth(frame, "SetAuraInstanceInfo"), meth(frame, "OnAuraInstanceInfoSet"),
          meth(frame, "OnAuraInstanceInfoCleared"), meth(frame, "RefreshData"),
          meth(frame, "GetCooldownFrame"), meth(frame, "IsActive")))
        local shown, active = "?", "?"
        pcall(function() shown = tostring(frame:IsShown()) end)
        pcall(function() local ok, a = pcall(frame.IsActive, frame); active = ok and pval(a) or "THREW" end)
        emit(("     frame: IsShown=%s IsActive=%s | auraInstanceID=%s present=%s | expUnit=%s"):format(
          shown, active, pval(aiid), tostring(present(aiid)), expUnit))
        emit(("     aura: player[%s] target[%s] | dur player[%s] target[%s]"):format(
          unitAura("player", aiid), unitAura("target", aiid), auraDur("player", aiid), auraDur("target", aiid)))
        emit(("     stacks: player[%s] target[%s]"):format(auraStacks("player", aiid), auraStacks("target", aiid)))
        emit(("     cd: isOnActualCooldown=%s cooldownIsActive=%s isOnGCD=%s startTime=%s"):format(
          pval(frame.isOnActualCooldown), pval(frame.cooldownIsActive),
          pval(frame.isOnGCD), pval(frame.cooldownStartTime)))

        -- shadow readiness (immediate; IsShown may lag one frame — see deferred pass below)
        if sid and not issecret(sid) and type(sid) == "number" and main and charge then
          local function feed(cd, durFn)
            if type(durFn) ~= "function" or not cd then return "noAPI" end
            if cd.SetCooldown then pcall(cd.SetCooldown, cd, 0, 0) end
            local ok, durObj = pcall(durFn, sid, true)
            if not ok then return "THREWget" end
            if durObj == nil then return "noDur" end
            if not cd.SetCooldownFromDurationObject then return "noSetter" end
            if not pcall(cd.SetCooldownFromDurationObject, cd, durObj, true) then return "THREWset" end
            local s = "?"; pcall(function() s = tostring(cd:IsShown()) end)
            return "shown="..s
          end
          emit(("     shadow: mainCD[%s] chargeCD[%s]"):format(
            feed(main, CS.GetSpellCooldownDuration), feed(charge, CS.GetSpellChargeDuration)))
        end

        -- charge-flagged items get a deep test: FRESH shadows + a deferred read
        -- (the +0.1s catches IsShown() lag). On non-charge spells this is skipped.
        if info and info.charges == true and not issecret(info.charges)
           and sid and not issecret(sid) and type(sid) == "number" and CS.GetSpellChargeDuration then
          local fmain = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
          local fchg  = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
          for _, cd in ipairs({ fmain, fchg }) do
            if cd.SetDrawSwipe then cd:SetDrawSwipe(false) end
            if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
          end
          pcall(function()
            local d1 = CS.GetSpellCooldownDuration and CS.GetSpellCooldownDuration(sid, true)
            local d2 = CS.GetSpellChargeDuration(sid, true)
            if d1 and fmain.SetCooldownFromDurationObject then fmain:SetCooldownFromDurationObject(d1, true) end
            if d2 and fchg.SetCooldownFromDurationObject then fchg:SetCooldownFromDurationObject(d2, true) end
          end)
          local nm = name
          -- Ground-truth (secret in combat, readable OOC) to correlate with the shadow map.
          pcall(function()
            local ci = CS.GetSpellCharges and CS.GetSpellCharges(sid)
            if ci then
              emit(("     charges: current=%s max=%s | IsSpellUsable=%s (the TRAP — ignores charges)"):format(
                pval(ci.currentCharges), pval(ci.maxCharges),
                pval(CS.IsSpellUsable and CS.IsSpellUsable(sid))))
            end
          end)
          C_Timer.After(0.1, function()
            local ms, cs2 = "?", "?"
            pcall(function() ms = tostring(fmain:IsShown()) end)
            pcall(function() cs2 = tostring(fchg:IsShown()) end)
            emit(("     |cffffd200shadow(+0.1s) %s: mainShown=%s chargeShown=%s|r  (main+charge shown=0 charges; main hidden+charge shown=1+ available)"):format(
              tostring(nm), ms, cs2))
          end)
        end
      end)
    end
  end
  emit("  Capture 5 states: (1) OOC no target (2) target dummy A, no DoT (3) DoTs on A, in combat (4) swap to dummy B (5) swap back to A. Watch auraInstanceID/present + aura:target across states.")
  if CDM._captureBtn then CDM:_UpdateCaptureButton() end
end

-- --------------------------------------------------------------------------
-- /ga capture — a small movable click button so you can fire a probe at an exact
-- game state (mid-combat, right after a target swap) without typing. Each click
-- runs CDM:Probe() (full dump) → prints + appends to the SavedVariables log.
-- Do all your captures, then /reload once, and the file has every one of them.
-- Styled with our own textures (no Blizzard chrome, per house style).
-- --------------------------------------------------------------------------
function CDM:_UpdateCaptureButton()
  local b = self._captureBtn
  if not b then return end
  local root = _G.GloomsAurasDB
  local count = (type(root) == "table" and type(root.probeLog) == "table") and #root.probeLog or 0
  b.count:SetText(("%d captured"):format(count))
end

function CDM:ToggleCaptureButton()
  local b = self._captureBtn
  if b then
    if b:IsShown() then b:Hide() else b:Show(); self:_UpdateCaptureButton() end
    return b:IsShown()
  end

  b = CreateFrame("Frame", "GloomsAurasCaptureButton", UIParent)
  b:SetSize(150, 70)
  b:SetPoint("CENTER", 0, -120)
  b:SetFrameStrata("DIALOG")
  b:EnableMouse(true)
  b:SetMovable(true)
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnDragStart", b.StartMoving)
  b:SetScript("OnDragStop", b.StopMovingOrSizing)
  local bg = b:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0.04, 0.03, 0.07, 0.92)
  local edge = b:CreateTexture(nil, "BORDER"); edge:SetPoint("TOPLEFT", -1, 1); edge:SetPoint("BOTTOMRIGHT", 1, -1)
  edge:SetColorTexture(0.576, 0.42, 1, 0.5)  -- purple frame accent

  local title = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOP", 0, -6); title:SetText("|cff936bffGA Probe|r  (drag)")

  local hit = CreateFrame("Button", nil, b)
  hit:SetPoint("TOPLEFT", 8, -22); hit:SetPoint("BOTTOMRIGHT", -8, 8)
  local hbg = hit:CreateTexture(nil, "ARTWORK"); hbg:SetAllPoints(); hbg:SetColorTexture(0.576, 0.42, 1, 0.85)
  hit:SetScript("OnEnter", function() hbg:SetColorTexture(0.66, 0.52, 1, 1) end)
  hit:SetScript("OnLeave", function() hbg:SetColorTexture(0.576, 0.42, 1, 0.85) end)
  local lbl = hit:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  lbl:SetPoint("CENTER", 0, 5); lbl:SetText("CAPTURE"); lbl:SetTextColor(0, 0, 0)
  b.count = hit:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.count:SetPoint("CENTER", 0, -11); b.count:SetTextColor(0, 0, 0)
  hit:SetScript("OnClick", function() CDM:Probe() end)

  self._captureBtn = b
  self:_UpdateCaptureButton()
  return true
end
