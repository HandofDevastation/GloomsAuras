# GloomsAuras — API Notes (project source of truth)

Verified grounding for building GloomsAuras against WoW **Midnight 12.0.x** (client
build dated 2026‑04‑29; TOC Interface **120007**). This is *our* curated reference —
distilled from three sources, in order of authority:

1. **The player's own client source** — `_retail_/BlizzardInterfaceCode/Interface/AddOns/Blizzard_CooldownViewer/`
   and `.../Blizzard_APIDocumentationGenerated/CooldownViewer*Documentation.lua`.
   This is exact for this build. Cited below as **[client-src]**.
2. The vendored `wow-addon-dev` skill docs in [docs/wow-addon-dev/](wow-addon-dev/)
   (secret-value system, migration, patterns; dated April 2026). Cited **[skill]**.
3. warcraft.wiki.gg + Gethe/wow-ui-source (cross-check). Cited **[wiki]**.

Confidence tags: **[CONFIRMED]** (read from client source / generated docs),
**[LIKELY]** (authoritative but not read in this exact build), **[PROBE]** (must be
verified live in-game — see §8).

---

## 1. Architecture decision (the whole point)

Midnight makes combat aura data **secret**: tainted (addon) code cannot do arithmetic,
comparison, `#`, string ops, or table-keying on a secret value without throwing an
immediate Lua error [skill]. The old "read `C_UnitAuras` fields and compare" approach
(ThisWeeksAuras/M33kAuras) breaks for exactly this reason.

**GloomsAuras never reads aura data. It mirrors the Blizzard Cooldown Manager's own
UI state.** The CDM already computes "is this buff/cooldown active?" inside Blizzard's
**secure** context and reflects it as the shown/hidden state of a per-cooldown frame.
Frame shown-state is a plain boolean, not a secret (§3.4). We:

- key off the CDM's **config** fields to find the frame for a tracked spell (§3.5),
- **hook that frame's `OnShow`/`OnHide`** to drive our custom texture + sound (§4),
- optionally **read `item:IsShown()` / `item.isActive`** for state (predicted non-secret, §3.4 / PROBE B1).

We do **not**: use CLEU (removed §7), read aura fields for logic, send addon comms in
restricted contexts (§7), or pass secret values into widgets we later read back (§2).

---

## 2. Secret-value rules we code by  [skill]

**Blocked on a secret in tainted code (throws):** arithmetic `+ - * / % ^`, comparison
`< > <= >= == ~=`, boolean truth-test (`if secret then`, `and`/`or`), `#`, `tostring`/
concatenation-for-reading, using a secret as a **table key**, indexing/calling a secret.

**Allowed:** store in a variable / table *value*; pass to whitelisted native setters
(`StatusBar:SetValue`, `Cooldown:SetCooldown*`, etc.); pass to `issecretvalue()`;
`type(secret)` returns the real type.

**Always guard before branching on any combat value:**
```lua
local v = SomeCombatAPI()
if issecretvalue(v) then  -- secret path: native setters only, no operators
else                       -- plain path: normal Lua ok
end
```

**Secret Aspects (spec principle #3):** passing a secret into a widget setter marks that
widget with a secret *aspect*; its getters then return secrets. `frame:HasSecretValues()`,
`frame:HasSecretAspect("<Aspect>")` inspect this; only `frame:SetToDefaults()` clears it.
Aspect enum includes `Shown=32`, `Text=8`, `BarValue=16384`, `Cooldown=32768`, … If we
ever mirror a secret into our own widget, isolate it to a widget we never read back.

**Sanctioned tools for secret data (only if we ever need them):**
- `issecretvalue(v) → bool` — global, safe on anything incl. nil. **[CONFIRMED wiki]**
- `C_RestrictedActions.IsRestricted() / IsInRestrictedCombat() / IsInRestrictedInstance()` — plain booleans, our load-condition + mode gate. **[LIKELY]**
- `C_Secrets.*` predicates (`IsLessThan/IsGreaterThan/IsEqual/Select`, `ShouldAurasBeSecret`, …) → secret booleans, for logic without reading. **[LIKELY]**
- `C_CurveUtil.CreateCurve/CreateColorCurve` and `C_DurationUtil.CreateDuration` — map/display a secret without reading it (§5). **[LIKELY]**

---

## 3. Cooldown Manager (`C_CooldownViewer`) — verified from client source

### 3.1 Namespace functions  **[CONFIRMED client-src]** (`CooldownViewerDocumentation.lua`)
| Function | Args | Returns |
|---|---|---|
| `GetCooldownViewerCategorySet(category, allowUnlearned=false)` | `CooldownViewerCategory`, bool | `number[]` cooldownIDs |
| `GetCooldownViewerCooldownInfo(cooldownID)` | number | `CooldownViewerCooldown` (may return nothing) |
| `GetLayoutData()` | — | cstring |
| `GetValidAlertTypes(cooldownID)` | number | `CooldownViewerAlertEventType[]` |
| `IsCooldownViewerAvailable()` | — | bool, string |
| `SetLayoutData(data)` | cstring | — |

(`GetGroupBuffItems` is a **12.1.0** addition — NOT in this build.) All data-bearing
functions are tagged `SecretArguments = "AllowedWhenUntainted"` — i.e. results may be
secret when we call them from addon code in a restricted context → guard reads.

### 3.2 Enums  **[CONFIRMED client-src]** (`CooldownViewerConstantsDocumentation.lua`)
- `Enum.CooldownViewerCategory` = `Essential=0, Utility=1, TrackedBuff=2, TrackedBar=3`
- `Enum.CooldownSetSpellFlags` = `HideAura=1, HideByDefault=2`
- `Enum.CooldownViewerAlertEventType` = `Available=1, PandemicTime=2, OnCooldown=3, ChargeGained=4, OnAuraApplied=5, OnAuraRemoved=6`
- Constants: `COOLDOWN_VIEWER_LINKED_SPELLS_SIZE=4`, `COOLDOWN_VIEWER_CATEGORY_SET_SIZE=16`

### 3.3 `CooldownViewerCooldown` struct — exact 11 fields  **[CONFIRMED client-src]**
```
cooldownID:number  spellID:number  overrideSpellID:number?  overrideTooltipSpellID:number?
linkedSpellIDs:number[]  selfAura:bool  hasAura:bool  charges:bool  isKnown:bool
flags:CooldownSetSpellFlags  category:CooldownViewerCategory
```
No `spellCategoryID`/`equipSlot`/`isInvisible` in this build (those are later-patch). No
`targetAura` field — self vs target is derived: `selfAura=true` ⇒ scanned on `player`,
else the item also scans `target` (`GetAuraData` tries `player` then `target`). [client-src]

### 3.4 The four viewer frames + show/hide mechanics  **[CONFIRMED client-src]** (`CooldownViewer.lua`)
Global singleton frames, one per category:
| Global frame | Category | Item mixin |
|---|---|---|
| `EssentialCooldownViewer` | Essential | Cooldown item |
| `UtilityCooldownViewer` | Utility | Cooldown item |
| `BuffIconCooldownViewer` | TrackedBuff | Buff-icon item ← **Trick Shots lives here** |
| `BuffBarCooldownViewer` | TrackedBar | Buff-bar item |

**One pooled item frame per configured cooldownID** (min 2): `GetItemCount()=#cooldownIDs`.
`RefreshLayout()` does `itemFramePool:ReleaseAll()` then `Acquire()` N frames — runs on
**structural** changes only (data loaded, settings/spec/level change, edit-mode, and a
**full** `UNIT_AURA` update). Ordinary buff add/remove just flips one item's state.

**Activation → shown, the load-bearing path:**
```
RefreshActive() → SetIsActive( ShouldBeActive() )   -- ShouldBeActive reads aura & compares
   → self.isActive = <result>                        --   ...but in SECURE code ⇒ plain bool
   → OnActiveStateChanged() → UpdateShownState()
   → ShouldBeShown() (uses self.isActive, hideWhenInactive, IsEditing — all plain)
   → self:SetShown(<plain bool>)
```
⇒ **An inactive tracked buff HIDES; the frame is not destroyed** (stays in the pool,
`IsShown()==false`). ⇒ **`item:IsActive()` is NON-SECRET in combat — CONFIRMED in-game
2026-07-06** (open-world): the addon read it and branched to play a sound while Trick Shots
was active on a dummy; a secret value would have thrown, so the branch (and sound) proves
it is a plain boolean. Matches the source reasoning (secret comparison resolved in secure
code, only the boolean result stored). NOTE: verified for **open-world combat**; instance /
M+ / raid is stricter — the code still falls back to `SetShown(active)` if it is ever secret.

### 3.5 Item mixin methods we use  **[CONFIRMED client-src]** (`CooldownViewerItemData.lua`)
Safe (config / plain): `GetCooldownID()`, `GetCooldownInfo()` (→ the struct + dynamic
`linkedSpellID`), `GetBaseSpellID()` (=`cooldownInfo.spellID`), `IsActive()`, `IsShown()`.

**Spell-matching rule:** to decide "is this the item for spell X", compare X against
`info.spellID`, `info.overrideSpellID`, `info.overrideTooltipSpellID`, and each of
`info.linkedSpellIDs` — all **config values, non-secret**. Do this out of combat when
possible and cache the `cooldownID`.
**Do NOT** use `item:GetSpellID()`, `item:GetAuraData()`, or the built-in
`SpellIDMatchesAnyAssociatedSpellIDs()` for matching — they read `auraSpellID`/aura data
that is **secret in combat** and will throw. [client-src lines ~159, 185, 357]

### 3.6 Namespace events for addon use  **[CONFIRMED client-src]**
`COOLDOWN_VIEWER_DATA_LOADED` (fires when the registry loads/changes — our re-scan
trigger), `COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED` (payload `baseSpellID, overrideSpellID?`),
`COOLDOWN_VIEWER_TABLE_HOTFIXED`. **There are no per-item "state changed" namespace
events** — per-item state surfaces only as the frame's `OnShow`/`OnHide` and the internal
`UpdateShownState`/`RefreshActive` calls.

### 3.7 Native alert system (noted, not used)
The CDM has its own Sound/Visual alert system (`GetValidAlertTypes`, `CanTriggerAlertType`,
`AlertEventType` = Available/OnCooldown/OnAuraApplied/…). We build our own display engine
instead, but this is a fallback signal source if ever needed.

---

## 4. Hook strategy (Phase 1 mirror)

1. **Discover** (login / `COOLDOWN_VIEWER_DATA_LOADED` / out of combat): for each tracked
   spellID, walk the relevant viewer's active item frames via
   `viewer.itemFramePool:EnumerateActive()` (**CONFIRMED works** in-game), match by §3.5
   config rule, remember the frame. **CRITICAL LEARNING (verified 2026-07-06):** a viewer
   only creates item frames for cooldownIDs actually **placed in that viewer's layout**
   (`GetOrderedCooldownIDsForCategory`), NOT the full registry from
   `GetCooldownViewerCategorySet` (which lists all 23 *possible* tracked buffs). So we can
   only mirror a spell the user has **placed in a CDM viewer**, and `WATCH.category` must
   match **where they placed it** (Buff-icon vs Bar are different frames/categories). If the
   user has it in "Tracked Bars", category must be `TrackedBar` (3), not `TrackedBuff` (2).
2. **Hook active-state:** `hooksecurefunc(itemFrame, "OnActiveStateChanged", …)` → read
   `itemFrame:IsActive()` and Show/Hide our overlay (+ sound on show, throttled §6). This
   fires on active transitions **regardless of the viewer's "hide when inactive" setting**
   (frame-visibility mirroring FAILS when that setting is off — the icon stays visible,
   dimmed). IsActive() confirmed non-secret in open-world combat (§3.4); `SetShown(active)`
   fallback if ever secret.
3. **Survive re-pooling:** `hooksecurefunc(<eachViewerFrame>, "RefreshLayout", …)` (hook the
   4 persistent frame instances, NOT the shared mixin table — Mixin copies methods onto
   frames, so a table hook won't reach existing frames) → after a rebuild, re-run discover
   + re-hook new frames (guard each frame with a `frame.__gaHooked` flag).
4. **Initial sync:** on setup, read each tracked `item:IsActive()` and set overlay state
   (guarded; no sound).

---

## 5. Duration / cooldown timers — **BLOCKED for addons in combat**  **[CONFIRMED client-src, 2026-07-06]**
Earlier optimism (and the research report) was WRONG. Read from
`FrameAPICooldownDocumentation.lua` in this client: **every** cooldown setter —
`SetCooldown`, `SetCooldownDuration`, `SetCooldownFromDurationObject`,
`SetCooldownFromExpirationTime`, `SetCooldownUNIX` — carries
`SecretArguments = "AllowedWhenUntainted"`. All `LuaDurationObject` setters and
`C_DurationUtil.CreateDuration` are the same. **Meaning: only untainted (Blizzard) code may
feed a SECRET duration to a timer widget.** From addon (tainted) code:
- PLAIN values (out of combat / non-secret): **work** → sweep + countdown draw fine.
- SECRET values (in combat, restricted spells): **rejected → throws** (guard with
  `issecretvalue` and skip; see `Displays:UpdateCooldown`).
⇒ **An addon cannot draw a custom cooldown timer/sweep for a restricted cooldown in combat.**
Only Blizzard's own Cooldown Manager frame can (it's secure). Confirmed in-game: Rapid Fire
`cd.start secret=false` OOC, `secret=true` in combat. Only the *style* setters
(`SetDrawSwipe`, `SetHideCountdownNumbers`, `SetSwipeColor`, …) are `AllowedWhenTainted`.

Implication for the product: cooldown auras can show an icon + (out-of-combat) sweep, and
buff auras work fully (active-state is a plain bool, §3.4). In-combat cooldown *timers* are
a platform wall, not a fixable bug.

**AVAILABILITY tracking — what actually works (CORRECTED 2026-07-07 after in-game tests):**
- **Non-charge cooldowns → WORKS.** Mirror Blizzard's cooldown transitions: hook the globals
  `CooldownFrame_Set` (→ on cd) / `CooldownFrame_Clear` (→ ready), filtered to the CDM item's
  own cooldown widget (`item:GetCooldownFrame()`), plus `item:OnCooldownDone`. Never reads a
  secret — we record which transition fired. CONFIRMED in combat (Rapid Fire). Seed initial
  state out of combat via `GetSpellCooldown` (readable OOC).
- **`C_Spell.IsSpellUsable` is a TRAP.** Readable in combat, but it **ignores cooldown AND
  charges** (returns true while on cooldown, true at 0 charges — verified in-game). NOT a valid
  availability signal; do not use it.
- **Charge spells (e.g. Aimed Shot) → WALL.** "Have ≥1 charge" is SECRET in combat:
  `GetSpellCharges` AND `GetSpellCastCount` are both `SecretWhenCooldownsRestricted`
  (SpellDocumentation.lua). Every non-secret proxy (IsSpellUsable, the cooldown sweep, icon
  desaturation/color via `RefreshIconColor`/`RefreshIconDesaturation`) reflects the *recharge*
  or ignores charges. So an addon **cannot** know charge-spell castability in combat. Only
  partial signal: `C_SpellActivationOverlay.IsSpellOverlayed(spellID)` + the
  `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE` events detect **procs** (e.g. Lock and Load) —
  non-secret, but only the proc case, not normal charge availability.
  - **⚠ POSSIBLE DOOR (UNVERIFIED, 2026-07-08) — the "shadow cooldown" technique (§9.3).** ArcUI
    DERIVES charge availability without reading the count: feed a duration OBJECT
    (`GetSpellChargeDuration`/`GetSpellCooldownDuration`, GCD-stripped) into a hidden `Cooldown`
    widget via `SetCooldownFromDurationObject`, then read its **`IsShown()`** (a plain bool). In our
    probe this feed ran IN COMBAT without throwing — but **no real charge spell tested**, and it sits
    in tension with §5 above. Must be proven on Aimed Shot before this wall is retired. See §9.3.
- **Compound triggers** ("buff present AND cooldown ready") work when the cooldown is a
  non-charge spell (both halves are plain bools). Charge-spell conditions can't be satisfied
  reliably → treated as unknown (won't falsely fire).

---

## 6. Sound  **[LIKELY wiki]**
`willPlay, handle = PlaySoundFile(pathOrFileID, channel)`; channels `"Master"`(default here),
`"SFX"`,`"Music"`,`"Ambience"`,`"Dialog"`. Custom `.ogg`/`.mp3` files must exist at
login/reload (no mid-session file adds). Not a combat-data API ⇒ expected unaffected by
secrecy; confirm it still fires inside an encounter = **PROBE D1**. Per-display throttle
(default 1s) to avoid flicker spam (spec §2.2).

---

## 7. Hard "don'ts" (confirmed)  [skill/wiki]
- **CLEU removed:** addons can't register `COMBAT_LOG_EVENT[_UNFILTERED]` (fires
  `ADDON_ACTION_FORBIDDEN`). Use `UNIT_*` events. **[CONFIRMED]**
- **Addon comms restricted** in restricted contexts — check
  `C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()` / `IsInRestrictedInstance()`
  before sending; expect failure results. Sharing = user copy/paste strings only. (Exact
  instance rule = **PROBE E1**; either way we don't rely on comms.)
- No party/raid unit tracking, no WeakAuras import, no rotation logic (spec §7).

---

## 8. Open items to confirm live in-game (probes)
- **B1 [critical]** — ✅ RESOLVED for open-world combat: `item:IsActive()` is a real,
  non-secret boolean there (2026-07-06). ⏳ Still worth confirming inside an instance / M+ /
  raid (stricter secrecy); code already falls back to `SetShown(active)` if it turns secret.
- **B2** — is `GetCooldownViewerCooldownInfo(id).spellID` readable (non-secret) in combat,
  or must all matching happen out of combat?
- **Trackability** — is Trick Shots (257622) actually configured in the player's CDM
  Tracked Buffs? (If not, add via Edit Mode → Cooldown Manager; the addon's `/ga debug`
  will report what's found.)
- **Enumerate API** — does `viewer:GetItemFrames()` vs `viewer.itemFramePool:EnumerateActive()` work from addon code?
- **D1** — does custom `PlaySoundFile` fire while in a restricted encounter?
- **AIID-1 [was B1, RESOLVED open-world 2026-07-08]** — DoT-on-target via `frame.auraInstanceID`
  + `C_UnitAuras` on the `selfAura` unit is CORRECT across target swaps (Warlock, 8 `/ga probe`
  captures — §9). ⏳ **STILL UNVERIFIED in instance / M+ / raid** (stricter secrecy — `auraInstanceID`
  may go SECRET there; `present()`=secret⇒present *should* cover it, but the full flow is untested).
- **CHG-1 [charge shadow-cooldown, §9.3]** — verify the 4-state `IsShown()` map with a REAL charge
  spell (Aimed Shot at 2/1/0 charges) on the Hunter, AND resolve the §5 `AllowedWhenUntainted`
  tension. Blocker: Essential/Utility cooldown items returned `GetCooldownInfo=nil` OOC/no-target
  (populated in combat WITH a target) — sort spellID acquisition for cooldown items first.

---

## 9. Secret-safe SIGNALS — reading aura/charge state directly (NOT via IsActive)
**Reframes the "never read aura data" premise. DoT half VERIFIED (Warlock, open-world,
2026-07-08, 8 `/ga probe` captures across target swaps). Charge half FOUND (ArcUI) but UNVERIFIED.**

The founding rule was stricter than the platform requires. The real constraint is ONLY: *never do
arithmetic / comparison / truth-test / `#` / concat on a secret value.* You MAY read an aura's
**presence** and **duration** secret-safely by routing the secret through a native sink that returns
a plain boolean or an opaque object. Reference implementation: **ArcUI** (installed & readable at
`_retail_/Interface/AddOns/ArcUI/` — `ArcUI_Core.lua`, `CDM_Enhance/ArcUI_CooldownState.lua`); it
mirrors the SAME CDM we do, then reads auras directly under 122 `issecretvalue` guards.

### 9.1 DoT / target-debuff presence — VERIFIED WORKS
- CDM item frames carry a native **`frame.auraInstanceID`** (set by the secure scan via
  `SetAuraInstanceInfo`/`OnAuraInstanceInfoSet`). Probe confirmed every viewer item exposes
  `OnAuraInstanceInfoSet` / `OnAuraInstanceInfoCleared` / `RefreshData` / `SetAuraInstanceInfo`.
- **Presence WITHOUT reading** (ArcUI's `HasAuraInstanceID`): `nil`/`0` ⇒ absent; **secret ⇒ PRESENT**
  (can't compare it, but its existence IS the signal); plain non-zero ⇒ present.
- **Pick the unit from `info.selfAura`** (§3.3): `true` ⇒ `"player"` (buff), `false` ⇒ `"target"`
  (debuff). Then `C_UnitAuras.GetAuraDataByAuraInstanceID(unit, aiid)` (non-nil ⇒ present) and
  `C_UnitAuras.GetAuraDuration(unit, aiid)` (returns a duration OBJECT → feed a bar, never read it).
- **CAVEAT — never cross-unit.** auraInstanceIDs are unique per-unit, so querying the WRONG unit can
  false-positive (probe P6/P8: querying `player` for Haunt's TARGET instance returned PRESENT). Query
  ONLY the selfAura unit.
- **Measured (8 captures — Haunt 48181, Agony 980, UA 1259790, Corruption 146739):** DoTs up on target →
  `auraInstanceID` = a plain readable int (15/16/18/20/23…, NOT secret in open-world), `target[PRESENT]`,
  `dur target[obj:userdata]`; swap-away → cleared to `nil`/absent; swap-back → returned. **Correct in
  EVERY state**, unlike our IsActive mirror.
- ⏳ **UNVERIFIED**: instance / M+ / raid (auraInstanceID may be secret there — present()=secret⇒present
  should handle it, untested). And NONE of this is built or QA'd in the addon yet.

### 9.2 Why our current mirror fails on DoTs (root causes — same captures)
1. **No re-eval on target change.** The Bar item's `IsActive()` reads correctly when POLLED, but we only
   re-read on `OnActiveStateChanged`, which does NOT fire on a target swap → stale on screen. Fix: also
   re-evaluate on **`PLAYER_TARGET_CHANGED`**.
2. **spellID-only matching COLLIDES.** A spell enrolled in MULTIPLE viewers (Haunt = Essential `cat=0`
   AND BuffBar `cat=3`) makes `Discover` map BOTH frames to the same spellID; both write the same
   `buffActive/available[spellID]` and fight (the cooldown entry's IsActive stays stuck true on swap
   while the bar entry flips) = the "goes random" symptom. Fix: disambiguate by **cooldownID** (ArcUI
   keys on it) or (spellID + desired category), not spellID alone.

### 9.3 Charge availability — the "shadow cooldown" — FOUND, UNVERIFIED
- ArcUI never reads the charge COUNT. It feeds a **duration object** (`C_Spell.GetSpellChargeDuration(id,
  true)` + `GetSpellCooldownDuration(id,true)`, GCD-stripped) into two hidden `Cooldown` widgets
  (`SetDrawSwipe/Edge(false)`, `SetHideCountdownNumbers(true)`), then reads each widget's **`IsShown()`**
  for a 4-state map: main+charge shown = 0 charges; main hidden + charge shown = 1+ available; main only =
  non-charge on cd; both hidden = ready.
- **Partial evidence (our probe):** the duration-object feed ran IN COMBAT without throwing and gave a
  readable `IsShown()` for a non-charge cd (P3). Encouraging.
- **⚠ UNVERIFIED / open questions:** (a) NO real charge spell tested — the 4-state map is unproven;
  (b) `IsShown()` LAGS one frame after a feed (ArcUI defers 0.1s; our probe captures both immediate + +0.1s);
  (c) it appears to CONTRADICT §5 (`SetCooldownFromDurationObject` = `AllowedWhenUntainted` ⇒ should reject
  a secret duration from tainted code) — either the object isn't secret, or the object path differs from a
  raw secret. **Resolve all three on the Hunter (Aimed Shot 19434) before trusting it.** If it holds it
  RETIRES the charge WALL (§5/§7) for DISPLAY purposes (the readback is a plain bool we own → composable in
  triggers + edge-detectable for sound).

### 9.4 The unifying principle
Both halves are the same move: **you cannot read a secret, but you can route it through a native sink that
exposes a plain boolean** — aura-instance existence (DoTs) or a Cooldown widget's shown-state fed a duration
object (charges). This raises the ceiling; it does NOT change the "no arithmetic/compare on a secret" rule.

---

## 9. Naming / conventions
Addon `GloomsAuras`; namespace `GA` → `_G.GloomsAuras`; SavedVariables `GloomsAurasDB`;
slash `/ga` (avoid `/glooms` — owned by GloomsBuildBarn). Flat file layout, plain frames,
**no Ace3** except LibSharedMedia‑3.0 (+LibStub, CallbackHandler‑1.0) embedded in `Libs/`.
TOC `## Interface: 120007`. Match GloomsBuildBarn idioms (colored PREFIX, `Media\`,
bundled TTF fonts, design-token colors).
