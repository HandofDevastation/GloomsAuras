# GloomsAuras — project guide

> **▶ NEW SESSION: read [docs/HANDOFF.md](docs/HANDOFF.md) FIRST.** It has current build
> state, hard-won learnings (walls that must not be relitigated), how Jason works (non-dev,
> one instruction at a time, verify-before-claiming, ask for BugSack), and the next steps.
> Then this file (conventions) + [docs/API-NOTES.md](docs/API-NOTES.md) (verified API facts).

Bespoke WoW addon: shows custom textures + sounds when specific buffs/cooldowns are
active, tracked via the Blizzard **Cooldown Manager** (CDM). Target: **Midnight 12.0.7**
(Interface `120007`), retail only. Sibling to GloomsBuildBarn (same author "Gloom").

## The one idea that matters
Midnight makes combat aura data **secret** — tainted (addon) code throws if it does
arithmetic/comparison/etc. on a secret value. So **GloomsAuras never reads aura data.**
It mirrors the CDM's own state: the CDM computes "is this active?" in Blizzard's *secure*
context and stores a **plain boolean** (`item.isActive`) + shown/hidden frame state. We
hook that. Full rationale + verified API in **[docs/API-NOTES.md](docs/API-NOTES.md)** —
read it before touching CDM/secret-value code.

> **Nuance (VERIFIED 2026-07-08 — see [docs/API-NOTES.md](docs/API-NOTES.md) §9).** "Never reads aura
> data" was too strict. The real rule is "no arithmetic/compare/truth-test on a secret." We MAY read an
> aura's **presence** (the CDM item's `frame.auraInstanceID` — its existence is the signal, secret or not)
> and **duration** (duration objects), choosing the unit from `info.selfAura`. This is the tested path for
> **target DoTs**, which the plain-boolean mirror gets wrong on target swaps. Don't apologize for it.

Load-bearing rules:
- Never do arithmetic/comparison on secret aura values. Match spells by **config** ids only
  (`cooldownInfo.spellID` / `overrideSpellID` / `linkedSpellIDs`), never `GetSpellID()`/
  `GetAuraData()` for matching (those touch secret aura data in combat). Reading aura *presence/
  duration* secret-safely (API-NOTES §9) is allowed.
- Guard every combat-value read with `issecretvalue()` before any operator.
- Hook the **four persistent viewer frame instances** and **individual item frames**, not
  the shared mixin table (`Mixin` copies methods onto frames — a table hook won't reach them).

## Grounding docs (vendored, offline)
`docs/wow-addon-dev/` — the `wow-addon-dev` skill (secret-values, api-migration-12,
common-patterns, widget-framework, toc-structure, + a `secret-aware-addon` template).
`docs/API-NOTES.md` — our curated source of truth (CDM API verified from the client's own
`Blizzard_CooldownViewer` source).

## Conventions
- Namespace `GA` → `_G.GloomsAuras`; SavedVariables `GloomsAurasDB`; slash `/ga`
  (avoid `/glooms` — owned by GloomsBuildBarn).
- Plain frames, plain SavedVariables. **No Ace3** except LibSharedMedia-3.0 (+LibStub,
  CallbackHandler-1.0), embedded in `Libs/` (Phase 3+).
- Match GloomsBuildBarn idioms (colored `PREFIX`, `Media\`, bundled TTF fonts, tokens).

## Files
- `GloomsAuras.toc` — manifest (Interface 120007).
- `Core.lua` — namespace, SavedVariables, `/ga` slash router.
- `CDM.lua` — the Cooldown Manager mirror engine (`GA.CDM`).
- (Phase 3+) `Scanner.lua`, `Displays.lua`, `Sound.lua`, `ReportUI.lua`, `MediaManifest.lua`, `Media/`, `Libs/`.

## Build phases (one session each; see docs/HoDTracker-SPEC intent)
1. **[current] Skeleton + Trick Shots proof** — TOC/Core/CDM; mirror one tracked buff
   (Trick Shots 257622) to one texture + one sound; `/ga debug`, `/ga test`.
2. Scanner + DB — passive aura probe, secrecy classification, `/ga scan`.
3. Displays engine — data-driven displays, `/ga new`, unlock/drag, styling, LSM + custom media.
4. Report UI + export/import strings.

## Testing workflow
The repo root **is** the addon folder. Symlinked into the client at
`/Applications/World of Warcraft/_retail_/Interface/AddOns/GloomsAuras`.
In-game: `/reload`, then `/ga debug` (run once out of combat, once on a training dummy)
and `/ga test`. QA is done by the user (non-developer); provide copy-paste steps.
