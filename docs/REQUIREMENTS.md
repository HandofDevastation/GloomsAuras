# GloomsAuras — Requirements (owner: Jason)

The target is a focused, WeakAuras-style **visual** addon: pick what to track from the
Cooldown Manager, then design how it looks — driven by a GUI, not slash commands.
Everything routes around Midnight secrecy by mirroring CDM state (see API-NOTES.md).

## Feature list + feasibility

Legend: ✅ doable · ⚠️ doable but constrained/needs validation · ⛔ blocked by Midnight secrecy.

| # | Requirement | Verdict | Notes |
|---|---|---|---|
| 1 | Assign any **texture OR icon**, not just the tracked spell's | ✅ | `cfg.texture` = file path or icon fileID; picker UI to browse spell icons + media. |
| 2 | **Browse a list** of trackable auras/cooldowns | ✅ | The CDM registry gives name+icon+spellID per category (already dumped by `/ga debug`). |
| 3 | Pick from the list → **configure the display** (many options) | ✅ | Core of the options panel. |
| 4 | **Progress textures** (radial fill / bar of time left) | OOC ✅ / combat ⛔ | CORRECTED 2026-07-06: cooldown/duration setters are all `AllowedWhenUntainted` (verified in client docs, API-NOTES §5). Addon can draw a sweep with PLAIN values (out of combat) but the game **rejects secret values in combat** — so a restricted cooldown's timer can't be drawn by an addon in combat. Only Blizzard's CDM frame can. |
| 5 | **Numerical countdown** text | OOC ✅ / combat ⛔ | Same wall as #4 — the native countdown is driven by the same blocked setters. Out of combat: works. In combat: not possible for restricted spells. |
| 6 | **Stack / charge counts** as text | ⚠️/⛔ | Aura stacks are secret in combat → can't read to display. Spell **charges** are non-secret for whitelisted spells only. Honest expectation: works for some spells, blocked for many. Not a limitation I can code around — it's Blizzard's secrecy system (same reason the old aura addons broke). |
| 7 | **Text overlays** (e.g. a keybind you type in) | ✅ | Static/manual text isn't combat data — fully fine. |
| 8 | **Full font access** for that text | ✅ | LibSharedMedia fonts (shared with other addons) + custom fonts, via a font picker. |
| 9 | Optionally attach a **sound** to a trigger | ✅ | `PlaySoundFile` + an LSM sound picker, per display, per event (show/hide). |
| 10 | **Conditional combinations** ("aura X active AND ability Y available") | ✅ | Each CDM item's `IsActive()` is a readable plain boolean (confirmed non-secret in combat), so we can AND/OR several into one trigger. |
| 11 | Everything in a **visual UI**, not typed commands | ✅ | Committing fully to the GUI; slash commands become an optional back door. |
| 12 | **Minimap icon** to launch the panel | ✅ | LibDBIcon (same lib GloomsBuildBarn already uses). |

## Proposed build order (each = one testable step)

1. **Foundation** — options panel shell (built) + **minimap button** to open it (LibDBIcon).
2. **Aura picker** — a scrollable list of the CDM registry (icon + name); click to create a display. Removes all spellID typing.
3. **Display options** — texture/icon picker, width/height, X/Y, alpha, color, strata (visual controls).
4. **Text overlays + fonts** — add a text sub-element per display; LSM font picker; manual text (keybind).
5. **Sound** — per-display sound on show/hide; LSM sound picker; throttle.
6. **Conditions** — combine multiple CDM item states (AND/OR) into one display's trigger.
7. **Progress / countdown** — native Cooldown swipe + built-in countdown fed by a Duration object; validate the secrecy-safe path in-game. Set honest expectations on stack/charge text.
8. **Media libraries** — embed LibSharedMedia-3.0 (+LibStub, CallbackHandler) + custom media manifest (`Media/`).

## Non-negotiables (from owner)
- Visual UI, not slash commands.
- "More options = better" on the display side.
- Must be able to decouple the displayed art from the tracked spell.
