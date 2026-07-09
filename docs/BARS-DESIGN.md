# Bars — design doc (2026-07-09)

A new **Bar** display type: a StatusBar-shaped display driven by a secret-safe source.
Decided with Jason: **build Duration mode first**; UI polish comes from his Figma pass, so this
doc pins the **data model + engine + behavior** (the parts that don't depend on the final look).

## The one principle
Same as every secret-safe win so far: **feed the widget a secret-safe object/value; never read
or compare the raw value ourselves.** All three modes obey it.

## Modes (the source that drives the fill)
1. **Aura Duration** — a buff/debuff's remaining time (Jason's DoT timers). **← build first.**
2. **Cooldown Duration** — a spell's cooldown remaining.
3. **Stacks** — an aura's application count (Freezing).

## Architecture — a Bar is a new display KIND, not a parallel system
- `cfg.kind = "texture"` (default; every existing display) or `"bar"`.
- A bar **reuses the whole display pipeline**: left-pane list, position/size + drag-to-move, and the
  **Trigger / Visibility / Group / Sound / enable / eye-preview** gates. Nothing there is rebuilt.
- Only the **rendering** (a StatusBar instead of a texture) and a few settings differ.
- `Displays.lua`: the display frame gains a lazily-created `StatusBar` child when `kind=="bar"`;
  `ApplyConfig` branches on `kind` (texture path vs bar path).

## Data model
```
cfg.kind = "bar"
cfg.bar = {
  mode    = "aura_dur" | "cd_dur" | "stacks",
  spellID = <source spell/aura, bound via the existing picker>,
  unit    = "player" | "target" | nil,   -- nil = AUTO (see Unit resolution); manual override allowed
  texture = <LSM statusbar name/path or nil = a bundled default>,
  color   = {r,g,b} or nil,              -- fill colour
  bg      = {r,g,b,a} or nil,            -- track/background
  orientation = "HORIZONTAL" | "VERTICAL",  -- default HORIZONTAL
  reverse = bool,                        -- fill direction
  spark   = bool,                        -- moving edge highlight
  segments = N or nil,                   -- stacks: draw N segments (nil = smooth fill)
  max     = N or nil,                    -- stacks: max value (nil = auto: known cap / GetSpellCharges)
  showValue = bool,                      -- overlay the number (time / count) via the text system
  colorCurve = <later> ,                 -- colour-by-level (deferred; ArcUI-style)
}
-- length/thickness reuse cfg.width / cfg.height.
```

## Secret-safe mechanics, per mode
- **aura_dur** — resolve the source aura's `auraInstanceID` on `unit` (from the CDM item, re-resolved
  on `PLAYER_TARGET_CHANGED` for target debuffs). `C_UnitAuras.GetAuraDuration(unit, aiid)` → a
  **duration OBJECT** → `StatusBar:SetTimerDuration(durObj, Enum.StatusBarInterpolation.*, dir)`. The
  bar animates itself; we never read the time. **Verified not to throw in combat** (the duration-object
  path, §9.3 + ArcUI's `ArcUI_Display.lua`).
- **cd_dur** — `C_Spell.GetSpellCooldownDuration(spellID, true)` → duration object → `SetTimerDuration`
  (the exact feed we already use for the charge shadows).
- **stacks** — read `applications` from the aura data on `unit`. **PLAIN out of combat, SECRET in
  combat** (proven via `/ga probe`, `7c2c9cd`). Feed it to `SetMinMaxValues(0,max)` + `SetValue(v)` —
  the widget renders it even when secret (ArcUI does exactly this). Segments = N sub-bars filled
  widget-side. Value text via `SetText` (accepts a secret). Re-read on `UNIT_AURA` / target change.
  **NOTE: no "stacks >= X" trigger** — comparing the secret count throws in combat; this is display-only
  (see the §-stacks probe finding). Presence (≥1 stack) is already covered by the `buff_active` trigger.

## Unit resolution (the Freezing/Shatter lesson)
`selfAura=true` does **not** mean the aura is on the player — Freezing (Shatter, 1246769) is
`selfAura=true` yet the debuff lives on the **target** (proven: `aura: player[absent] target[PRESENT]`).
So resolve `unit` by **where the aura instance actually is**: try the target first (does the CDM item's
`auraInstanceID` resolve there?), else player — with an optional manual `cfg.bar.unit` override. Same fix
should correct the picker/trigger **wording** ("on target" vs "on you") — ties into the override-display
backlog item.

## Show / hide
A bar's **source presence** is its natural "active" state (aura up / cd running). Reuse `EvalDisplay`:
the bar shows when its source is active, ANDed with **Group + Visibility** (and a **Trigger** if one is
set) — the same gating model as textures, no new rules. (Mechanically: treat the bar's source like the
display's auto-spell — presence drives show; existing gates apply on top.)

## Rendering / styling
- `StatusBar` + an **LSM statusbar texture** (the "Shared Media (bars)" picker category already exists).
- Fill colour, background, orientation, reverse, optional spark.
- **Segments** (stacks): N sub-bars with small gaps (ArcUI "perStack"); each fills widget-side when the
  value crosses its threshold.
- **Value text**: reuse the text-overlay system. For a **duration countdown number**, overlay a hidden
  `Cooldown` widget with `SetHideCountdownNumbers(false)` fed the same duration object — it renders the
  ticking number secret-safely — rather than trying to read the remaining time.

## Type-aware editor (first step of the UI declutter — Jason's bloat concern)
The right editor pane branches on `cfg.kind`:
- **texture** → today's controls (texture, tint, desaturate, blend, aspect, glow…).
- **bar** → bar controls (mode, source spell, unit, bar texture, colour, orientation, segments, value
  text) + the shared rows (position, size, trigger, visibility, group, sound).
A **"Type: Texture | Bar"** switch at the top picks the kind. The editor shows only what's relevant to the
display's kind — the pattern for the broader reorg. **Jason is designing the polished UI in Figma** (tokens
handed off in the style-guide artifact); this build targets the data model + a functional editor, then we
reconcile with his design.

## Build order (Duration-first)
1. **Bar rendering + Aura-Duration mode** — the StatusBar child, the duration-object feed, unit
   resolution + target-swap, show/hide, basic styling (texture/colour/orientation), value-text countdown.
   **QA on Warlock DoTs.**
2. **Stacks mode** — `applications` feed (secret-safe), segments, count text. **QA on Frost Mage Freezing.**
3. **Cooldown-Duration mode** — cd-duration feed. **QA on any cooldown.**
Each pass ships + QAs on its own.

## Reference code to REUSE (so this is pick-up-and-go, not a re-investigation)
The secret-safe reads a bar needs already exist as working code — don't re-derive them:
- **Per-unit aura reads (verbatim pattern):** the `/ga probe` helpers in `CDM.lua` —
  `unitAura(unit,aiid)` (presence via `GetAuraDataByAuraInstanceID`), `auraDur(unit,aiid)` (the
  **duration OBJECT** via `GetAuraDuration`), `auraStacks(unit,aiid)` (the `applications` count). These
  ARE the aura_dur + stacks reads; lift them out of the probe into shared helpers.
- **Getting a source spell's `auraInstanceID`:** the DoT-tracking code (commit **`bc6cdb0`**, API-NOTES
  **§9.1**) — the CDM item frame carries `frame.auraInstanceID`; `CDM.frameToSpell` maps frame→spellID,
  `CDM.frameKind` the role. Re-resolve on **`PLAYER_TARGET_CHANGED`** (the DoT work already registers it).
- **Cooldown duration object:** `C_Spell.GetSpellCooldownDuration(spellID, true)` — already fed to Cooldown
  widgets in `CDM:FeedChargeShadow` (the charge shadow). Same object works for a bar.
- **Duration → StatusBar:** ArcUI `Bars/ArcUI_Display.lua` (~L3943) does
  `bar:SetTimerDuration(durObj, Enum.StatusBarInterpolation.ExponentialEaseOut, dir)` — copy that call.

## VERIFY-FIRST before building (stated as fact above, but confirm against THIS client)
1. **`StatusBar:SetTimerDuration(durObj, interp, dir)` exists** and animates from a duration object (ArcUI
   uses it, so it should — but confirm the method + the `Enum.StatusBarInterpolation` values on a real bar).
2. **`SetValue`/segments render a SECRET value** in combat (ArcUI's Freezing bar does — confirm by feeding
   the in-combat secret `applications` to a StatusBar and checking it doesn't throw and shows the fill).
3. **Duration-countdown TEXT** — the "hidden Cooldown widget with `SetHideCountdownNumbers(false)`" trick for
   a secret-safe ticking number is a PROPOSAL, not verified. Prototype it, or fall back to bar-only (no number)
   for aura_dur v1.
None of these blocks the design; they're quick confirmations so we build on solid ground, not assumptions.

## Open questions (settle as we build / from Figma)
- Default bar texture + fill colour.
- Value-text placement (inside the bar / above) — Figma will inform.
- Segments: auto from `maxStacks`, or a manual count.
- Do bars reuse `cfg.width/height`, or introduce bar-specific length/thickness?
- Colour-by-level curve: deferred to a later pass (nice-to-have, not v1).
