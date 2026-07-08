# GloomsAuras — Groups & Profiles design  (APPROVED 2026-07-07 — build next session)

> **Status: APPROVED, no code yet.** Jason reviewed and said "go with all your recommendations"
> — so every §6 open decision is resolved in favor of the proposal (see §6). **Next session
> begins with Phase 1 (Groups).** Build in phases (§7).
> Goal set by Jason: (1) **Groups** of auras with a **group-level visibility/load rule**
> (e.g. a "Marksmanship" group that only activates for that spec); (2) **Profiles** —
> named, switchable configs with a per-character default, so different characters (and
> specs) can run different setups.

---

## 1. Concepts & how they nest

```
Profile  (e.g. "Gloom - Area 52", the active one for this character)
 └── Group  (e.g. "Marksmanship", with a load rule: spec == Marksmanship)
      └── Aura  (a display: texture + trigger + its own visibility)
```

- A **Profile** holds a whole config: all groups + all auras + a few per-profile prefs.
  Each character points at one profile; by default its own, but you can switch/share.
- A **Group** is a named bucket of auras that carries **one Visibility/load rule**.
- An **Aura** (today's "display") belongs to at most one group (or none = Ungrouped).

**One aura = one group** (no multi-group), **flat groups** (no nested groups) for v1.
Both can grow later; the data model won't preclude it.

## 2. How "should this aura show?" composes

Today a display shows when: **Trigger passes AND its own Visibility gate passes.**
Groups add one more AND at the front:

```
show  =  Group.visibility passes            (if the aura is in a group)
   AND  Aura.visibility passes              (unchanged)
   AND  Aura.trigger passes                 (unchanged)
```

The group rule reuses the **exact Visibility engine we already have** — a group's rule
IS a `visibility` table (combat/target/spec/known/… ), so `CDM:VisibilityGate` works on a
group with no new logic. All plain game APIs (spec, combat, zone…), **no secret combat
data** — same secrecy-safety guarantees as the existing per-aura Visibility (see API-NOTES).

## 3. Data model

### Today
`GA.db` **is** the whole SavedVariable `GloomsAurasDB`:
```
GloomsAurasDB = { schema=1, displays={[id]=cfg,…}, seq, hideBlizzardCDM,
                  minimap={…}, panelPos={…}, media={} }
```

### Proposed (schema 2)
Split into **global** (account-wide) and **profiles**. The trick that keeps the refactor
small: **`GA.db` is repointed to the *active profile*** — so the ~15 existing
`GA.db.displays` / `GA.db.seq` / `GA.db.hideBlizzardCDM` call sites keep working unchanged.

```
GloomsAurasDB = {                         -- the raw SV = GA.global
  schema = 2,
  profiles = {                            -- named profiles
    ["Gloom - Area 52"] = <PROFILE>,
    ["Shared - Raid"]   = <PROFILE>, …
  },
  profileKeys = { ["Gloom - Area 52"] = "Gloom - Area 52", … },  -- char → profile name
  minimap  = { hide, minimapPos },        -- account-wide (LibDBIcon)
  panelPos = { x, y },                    -- account-wide window position
}

PROFILE = {                               -- GA.db points HERE (the active one)
  displays = { [displayID] = <AURA_CFG>, … },   -- unchanged shape
  groups   = { [groupID]   = <GROUP>,    … },   -- NEW
  seq = N,                                -- id counter (unchanged, now per-profile)
  hideBlizzardCDM = bool,                 -- per-profile (so you can hide it on one char, not another)
}

GROUP = { id=<groupID>, name="Marksmanship", order=N, collapsed=bool,
          visibility = { … same shape as an aura's visibility … } or nil }

AURA_CFG = { …all existing fields…, group = <groupID> or nil }   -- + one field
```

- `GA.global` = `GloomsAurasDB` (for `minimap`, `panelPos`, profile management).
- `GA.db` = `GloomsAurasDB.profiles[activeName]` (for `displays`, `groups`, `seq`, `hideBlizzardCDM`).
- Only **two** access sites move to `GA.global`: `panelPos` (Config) and `minimap` (MinimapButton).
- `groupID` = a `"gN"` string counter, same pattern as duplicate display ids.

### Migration (schema 1 → 2, non-destructive)
On load, if `schema < 2` and a top-level `displays` exists:
1. Create profile named after the current character (`"Name - Realm"`).
2. Move `displays`, `seq`, `hideBlizzardCDM` into it; add empty `groups = {}`.
3. `profileKeys[char] = that name`; leave `minimap`/`panelPos` at top level.
4. Delete the old top-level `displays`/`seq`/`hideBlizzardCDM`; set `schema = 2`.
Existing auras land in the new profile **Ungrouped** (their `group` is nil) — nothing lost.

## 4. Engine changes (CDM.lua)

- **`CDM:GroupGate(cfg)`** — `if cfg.group then local g = GA.db.groups[cfg.group]; return VisibilityGate(g) end` (nil group ⇒ pass). `VisibilityGate` already reads `.visibility`, so it works on a group as-is.
- **`CDM:EvalDisplay`** — add `if not self:GroupGate(cfg) then return false end` alongside the existing per-aura `VisibilityGate`.
- **Visibility poll** — `UpdateVisibilityPoll` also turns on if any *group* has a live rule (combat/target/casting change second-to-second).
- **Profile switch** — reassign `GA.db`, then `GA.Displays:RefreshAll()` + `CDM:Discover()` + rebuild the panel list. Auras from the old profile are hidden (not in the new `db.displays`).

## 5. UI changes (Config.lua)

### 5a. Left pane → grouped list
- Rows become: **[Group header]** (name · collapse ▸/▾ · load-rule button · rename · delete), then its auras indented beneath, then an **"Ungrouped"** section, then the Add/Duplicate/Remove stack.
- **Create group**: a "+ New Group" control.
- **Assign an aura to a group**: v1 = a **"Group" dropdown** in the aura's editor (simple, reliable). v2 (later) = drag-and-drop between groups.
- **Group load rule**: reuse the **Visibility editor** opened for a group (it edits `group.visibility` instead of `aura.visibility`). One generalized editor, two callers.

### 5b. Profile switcher
- A **Profiles** control (dropdown in the bottom strip, or a small button opening a mini-panel): **switch · new · copy current · rename · delete**. Shows the active profile; switching re-points `GA.db` and refreshes everything.
- "New/Copy" seed a profile; "copy current" duplicates the whole config (deep copy).

### 5c. Group visibility editor
Generalize `OpenVisibilityEditor(target)` where `target` is an aura id **or** a group id; it reads/writes `.visibility` on whichever, and the summary line shows the group's rule.

## 6. Decisions — ALL RESOLVED (Jason approved every recommendation, 2026-07-07)

1. **Settings location:** `hideBlizzardCDM` lives **per-profile**; `panelPos` + `minimap` stay **global** (account-wide). ✅
2. **Deleting a group** with auras → its auras **move to Ungrouped** (never deleted). ✅
3. **Default profile name** = `"Character - Realm"` (per-char default); no separate blank "Default". ✅
4. **Group on/off toggle** — YES, include a quick enable/disable per group, separate from its load rule. ✅
5. **Group ordering** — v1 = creation order + manual **up/down buttons**; drag-and-drop later. ✅
6. **Profiles model** (from the session's AskUserQuestion) — **named, switchable, per-character default** (WeakAuras-style: each char defaults to its own, can create/copy/rename/delete/switch). ✅

## 7. Phased build plan (each phase = its own QA gate)

Designed together (this doc); **built** in value order — groups first so the spec-set need
lands soonest; profiles wrap cleanly around it afterward.

- **Phase 1 — Groups data + engine.** Add `groups`, `cfg.group`, `GroupGate`, poll hook. Aura "Group" dropdown + a minimal "+ New Group". QA: put auras in a group, set the group's rule to a spec, confirm the whole set shows/hides by spec.
- **Phase 2 — Grouped left pane.** Headers, collapse, nesting, Ungrouped section, group rename/delete/reorder, group load-rule button. QA: manage groups from the list.
- **Phase 3 — Profiles.** Schema-2 migration, `GA.global`/`GA.db` split, active-profile selection, profile switcher UI (switch/new/copy/rename/delete). QA: two profiles on one char; a second character defaults to its own; switching swaps the whole set.
- Each phase is committed as a restore point before the next (as we've been doing).

**Interim (works today):** each aura's **Visibility → Specialization** already gates by spec,
so you can spec-gate individual auras right now while Phase 1 is built.
