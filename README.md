# Gloom's Auras

A bespoke World of Warcraft **Midnight (12.0)** addon that shows custom textures + sounds
when specific buffs/cooldowns are active — tracked by mirroring the Blizzard **Cooldown
Manager** rather than reading aura data (which Midnight makes "secret" to addons).

Sibling to [Gloom's Build Barn](https://github.com/HandofDevastation/GloomsBuildBarn).

## What it does
- **Track** any buff/cooldown placed in your Cooldown Manager (buff-active, cooldown-ready, …).
- **Design** the display: pick any texture (254 bundled aura shapes, all game icons, or your own
  via LibSharedMedia / StoneTweaks), size/position, tint, desaturate, blend mode, strata, alpha.
- **Trigger** on combined conditions across multiple spells (AND/OR).
- **Visibility** gate by player/game state (in combat, spec, talent known, has target, …).
- **Sound** per display (LibSharedMedia sounds, plays on show).
- Minimap button, movable/skinned options panel.

## Usage
`/ga` opens the options panel. `/ga help` lists commands. Everything is GUI-driven; slash
commands are a back door.

## For developers / next session
Start with **[docs/HANDOFF.md](docs/HANDOFF.md)** — current build state, hard-won learnings,
and next steps — then `docs/API-NOTES.md` (verified Midnight API facts) and `CLAUDE.md`
(conventions). The core architecture (why we mirror the CDM instead of reading auras) is in
API-NOTES.

## Design note
Bundled shape textures are copied from the PowerAuras/WeakAuras family (as ThisWeeksAuras ships
them); fonts are shared with Gloom's Build Barn. Intended for personal/guild use.
