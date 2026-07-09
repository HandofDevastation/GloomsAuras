# GloomsAuras — Session Handoff  (last updated 2026-07-08)

**New session: read this file first, then `docs/API-NOTES.md`, then `docs/REQUIREMENTS.md`,
then `CLAUDE.md`.** The vendored WoW skill lives in `docs/wow-addon-dev/`. This file is the
single source of "where we are + what not to relitigate."

---

## How to work with Jason (the owner) — READ THIS
- **Non-developer.** He sets requirements, answers domain questions, and does in-game QA.
  Claude writes all code and does its own research. Don't ask him to read Lua.
- **ONE instruction at a time** for testing. Never hand him a batch of commands — he tunes
  out. State the single next action + what to look for, then stop.
- **VERIFY before claiming.** Never say "it works" until confirmed in the API docs AND
  in-game. Frame builds as "the source says this should work — test it," not as done. (This
  rule exists because repeated over-claims eroded trust; see the walls below.)
- **He runs BugGrabber/BugSack.** When something misbehaves, ASK FOR THE ERROR TEXT FIRST —
  WoW hides Lua errors, so silent throws look like "nothing happens." A `StopMovingAndSizing`
  typo cost hours because I didn't ask for the error early.
- These are also saved as memories (jason-non-developer, one-instruction-at-a-time,
  enable-lua-errors-during-qa, verify-before-claiming).

## Project & environment
- **GloomsAuras**: bespoke WoW **Midnight (Interface 120007)** addon — custom textures/sounds
  that trigger on Cooldown Manager state. Sibling to GloomsBuildBarn (same author "Gloom",
  guild Hand of Devastation). Spec origin: `~/Downloads/HoDTracker-SPEC.md` (ignore the name).
- **Repo root = addon folder**: `/Users/jasonstone/GloomsAuras` (the primary cwd).
- **Live in client via symlink**: `/Applications/World of Warcraft/_retail_/Interface/AddOns/GloomsAuras`
  → repo root. Edits are live; Jason just `/reload`s. No copy step.
- **Blizzard source on disk** for verifying APIs: `_retail_/BlizzardInterfaceCode/Interface/AddOns/`
  (esp. `Blizzard_CooldownViewer/` and `Blizzard_APIDocumentationGenerated/`). USE IT.
- **Always `luac -p <file>`** before handing code to Jason.

## The core idea (do NOT relitigate)
Midnight makes combat aura/cooldown data **secret** (`issecretvalue`); tainted addon code
throws if it does arithmetic/compare/etc. on a secret. **GloomsAuras never reads that data —
it MIRRORS the Blizzard Cooldown Manager**, whose state is computed in Blizzard's *secure*
context and exposed as plain frame state / transitions we can hook. **Only spells actually
PLACED in a CDM viewer are trackable** (registry ≠ placed).

> **UPDATE 2026-07-08 (VERIFIED — the rule was too strict; stop apologizing for "breaking" it).**
> The real constraint is ONLY "no arithmetic/compare/truth-test on a secret." We MAY read an aura's
> **presence** (via the CDM item's native `frame.auraInstanceID` — secret or not, its *existence* is
> the signal) and **duration** (via `C_UnitAuras.GetAuraDuration` duration OBJECTS), choosing the unit
> from `info.selfAura`. This is **PROVEN for target DoTs** (Warlock, open-world, 8 `/ga probe` captures
> across target swaps) and is how we'll fix DoT tracking — the pure `IsActive()` mirror gets target
> swaps WRONG. Mirroring is still correct for buffs/cooldowns; this just adds a sanctioned, tested path
> for auras the mirror can't handle. A charge variant (shadow-cooldown) is FOUND but UNVERIFIED. Full
> write-up + verification status: **API-NOTES §9**. Reference impl: **ArcUI** (installed, readable).

## Files
- `GloomsAuras.toc` — Interface 120007; load order: `Libs\*` → Core → Displays → CDM →
  `Media\TextureManifest.lua` → Config.
- `Core.lua` — namespace `GA` (`_G.GloomsAuras`), SavedVariables `GloomsAurasDB`, `/ga` router,
  **design tokens** `GA.COLOR / GA.FONT / GA.MEDIA` (matched to Build Barn).
- `Displays.lua` — `GA.Displays`: on-screen frames (texture/size/pos/alpha + tint/desaturate/blend/
  strata), **glow** (`ApplyGlow` via LibCustomGlow, OnShow/OnHide-driven), drag-to-move while panel open
  (NOT clamped), Cooldown swipe (OOC), **`RefreshForced`** (editor preview = selected + eye-on only).
- `CDM.lua` — `GA.CDM`: the mirror engine — state tracking, **recursive grouped trigger eval** (AND/OR/
  NONE), discovery, hooks.
- `Config.lua` — `GA.Config`: the whole GUI toolkit (`flatButton/flatCheck/flatEditBox/MakeSlider/
  MakeColor/MakeCycle/makeSwitch/MakeDropdown/skinPlate/addEdges`) + two-pane panel + aura picker +
  **texture picker** + **grouped trigger tree editor** (`C._trig`) + visibility/sound/text/**glow**/profile
  drawers. Much drawer/editor state hangs on the `C` table (chunk-local cap).
- `Media/TextureManifest.lua` — auto-generated `GA.TextureShapes` (254 aura shapes). Regenerate via
  `scratchpad/gen_manifest.py` if the bundled art changes.
- `Media/` — bundled Khand/GeneralSans fonts, `bg_flame.png`, `minimap.png`, Jason's custom UI icons
  (`lock_locked/unlocked.png`, `triangle.png` = collapse caret, `settings.png` = group gear,
  `hidden/unhidden.png` = per-aura eye), `Textures/` (107 shape files) + `PowerAurasMedia/Auras/`
  (145 curls) — copied from ThisWeeksAuras.
- `MinimapButton.lua` — `GA:InitMinimapButton` / `GA:ToggleMinimapButton` (LibDBIcon launcher).
- `Libs/` — embedded LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0,
  LibSharedMedia-3.0, **LibCustomGlow-1.0** (aura glow effects) — source: TWA's copies. `Libs/` is
  gitignored (packager fetches all libs at release); the local working copy keeps them.

## What's BUILT + QA status
- ✅ **QA'd** Buff mirror — Trick Shots texture shows while buff active (in combat).
- ✅ **QA'd** Options panel — texture path, width/height, X/Y, alpha; each control = slider +
  −/+ steppers + numeric box; movable window; remembers position.
- ✅ **QA'd** Aura picker — "Browse auras" scroll list of the CDM registry (icon+name), click to add.
- ✅ **QA'd** Drag-to-position auras (while panel open), synced with the X/Y numbers.
- ✅ **QA'd** Cooldown availability mirror for **non-charge** cooldowns (Rapid Fire) — shows when
  ready, hides on cooldown, in combat.
- ✅ **QA'd** Conditions/Trigger system — per-display trigger: conditions on any spells, combined
  AND/OR; Trigger editor UI (Edit Trigger… button → editor window). Full sweep passed 2026-07-07:
  all four leaf types (buff_active, buff_inactive, cd_ready, cd_oncd) + both AND and OR logic, in
  combat. Data structured so it can grow to nested/mixed groups later.
- ✅ **QA'd** Panel restyle (2026-07-07) — two-pane layout: LEFT = scrollable list of created
  displays (replaces the old `< prev / next >` scrubber), RIGHT = the settings editor. Skinned
  to match GloomsBuildBarn (navy plate, purple accents, bundled Khand/GeneralSans fonts in
  `Media/`, flat buttons). Picker + trigger-editor windows reskinned to match.
- ✅ **QA'd** Display render options (2026-07-07) — Tint (opens ColorPickerFrame), Desaturate,
  Blend Mode (Blend/Add/Modulate/Alpha Key/Opaque), Frame Strata. All pure rendering.
- ✅ **QA'd** Texture picker (2026-07-07) — "Choose…" button → window with a category dropdown +
  search + scrollable grid + live preview swatch. Categories: **254 bundled aura shapes** (Shapes,
  PowerAuras Heads-Up/Icons/Separated/Words, Beams, Sparks, Runes), **Game Icons** (all game icons
  via `GetMacroIcons`/`GetLooseMacroIcons`), **StoneTweaks Graphics** (read from `StoneTweaksDB`,
  by path), **Shared Media (bars)** (LibSharedMedia — bar textures only).
- ✅ **QA'd** Flat input styling (no `InputBoxTemplate`), size cap raised **512 → 8192**, display
  frames **un-clamped** so auras can sit partially/fully off-screen. X/Y offset **slider** range is
  **±2000** (narrowed from ±4000 on 2026-07-07 — ±4000 made the slider too coarse; drag-to-move and
  `/ga pos` stay un-clamped for bigger moves).
- ✅ **QA'd 2026-07-07** — **Custom flat sliders** (dropped `OptionsSliderTemplate` for a
  plain Slider: dark track = input-field fill, no border, bright-purple vertical marker thumb) +
  **aspect-ratio lock** on Width/Height (thin 1px purple bracket in the right margin joining the two
  boxes; when engaged, scaling one scales the other by `cfg.aspect`, the w/h ratio captured at lock
  time). Lock icon = Jason's custom 24×24 PNGs `Media/lock_locked.png` / `Media/lock_unlocked.png`
  (colors baked in → shown **untinted**, `SetVertexColor(1,1,1,1)`; state = which texture, not tint).
  **Texture facts (verified this client):** PNG loads fine AND non-power-of-two is fine — `Media/
  bg_flame.png` is 5000×4107 and renders. SVG unsupported.
- ✅ **Panel tweaks (QA'd 2026-07-07)** — **Remove** button moved from the editor pane to the
  LEFT pane; all button labels to **Title Case**. Left pane now stacks **Add / Duplicate / Remove**
  (`LIST_ROWS` → 17).
- ✅ **Duplicate Aura (QA'd 2026-07-07, REGRESSION-SENSITIVE)** — "Duplicate Aura" button makes
  an exact copy of the selected aura, INCLUDING on the same spell. Required re-keying `db.displays`
  from spellID → display id (see data-model note above); done backward-compatibly (originals keep
  their spellID key + `cfg.spellID`, so existing auras behave identically). Copy is deep-copied
  (independent trigger/visibility/sound), labelled "… (copy)", nudged +24/−24 so it doesn't overlap.
  **Restore point before this work: commit `248a9a7`** (`git reset --hard 248a9a7` to undo). QA order:
  FIRST confirm existing auras still show/hide + render exactly as before, THEN test Duplicate.
  - **Drag = selected only (2026-07-07):** with the panel open, only the aura selected in the left
    list is mouse-draggable on screen (others are visible but click-through) — so overlapping
    duplicates don't fight for the cursor. `D.selectedID` + `D:ApplyInteractivity`; Config sets it in
    `SetSelected` and clears it on panel close (nil ⇒ `/ga preview` back-door still drags all).
- ✅ **QA'd 2026-07-07 — Docked side-panel (drawer)** — the Trigger/Visibility/Sound/Texture editors
  attach flush to the main panel's RIGHT edge (parented to it → follows on drag, closes with it),
  flipping LEFT if they'd run off-screen. One at a time (`CloseSubWindows`/`DockRight`). Drag disabled
  when docked (`SetMovable(false)` + `if f:IsMovable()` guards on each titlebar). The aura picker stays
  floating (it can overlay the Trigger editor when adding a condition).
- ✅ **QA'd 2026-07-07 — UI cleanup batch** — borderless text inputs (focus brightens the fill);
  lighter button font (GeneralSans-Medium); **Blend + Strata are dropdown menus** (`MakeDropdown`),
  Blend trimmed to Blend/Add(glow)/Modulate; "Choose…" inline with the path field (no preview swatch);
  Game-Icons texture search is a **"Spell ID"** lookup (icons are nameless fileIDs); Title Case labels;
  X/Y offset slider ±2000; Trigger editor footer width-capped so it stops overrunning the frame.
- ✅ **QA'd** Per-display sound picker (2026-07-07) — "Sound" button → picker window (LibSharedMedia
  sounds + None, click-to-preview, draggable scrollbar) + a Test button. `cfg.sound = {file,name,
  channel}`; fires on hidden→shown via `CDM:PlaySound` (throttled). NOTE: **no per-sound volume** —
  `PlaySoundFile` takes only (file, channel); the only volume lever is WoW's global channel sliders.
- ✅ **QA'd** Minimap button (2026-07-07) — `MinimapButton.lua` via LibDBIcon/LibDataBroker (embedded),
  uses `Media/minimap.png` (Jason's 256×256 icon; also wired as `## IconTexture`). Left-click opens
  the panel; `/ga minimap` toggles; pos+hide saved in `db.minimap`. Self-contained fallback if libs absent.
- ✅ **QA'd** Visibility system (2026-07-07) — per-display player/game-state gate that **ANDs with the
  Trigger**. "Visibility…" editor: Combat/Target 3-way, toggles (casting, mounted, vehicle, instance,
  encounter, resting, stealthed, group, raid, warmode, alive), **Specialization** multi-select,
  **Spell/Talent known**. Engine = `CDM:VisibilityGate` + a 0.2s poll (`UpdateVisibilityPoll`) that
  runs only while some display uses visibility. All plain game APIs (no secret data). See learnings.
- ✅ **QA'd — Hide Blizzard's Cooldown Manager** (global toggle): checkbox in the panel's bottom strip +
  `/ga hidecdm`. Drives the four viewers' **alpha** only (0 = hidden), NEVER `Hide()` — because
  `CooldownViewerMixin:OnHide()` unregisters UNIT_AURA/SPELL_UPDATE_COOLDOWN (client source), so a real
  hide would silently break our mirror. `IsShown()` stays true → tracking keeps running. Suspended while
  Edit Mode is open (so the viewers stay visible/movable); re-asserts alpha-0 after Blizzard re-applies
  its own Opacity setting via a per-viewer `hooksecurefunc(v,"UpdateSystemSettingOpacity")`. Engine:
  `CDM:ApplyBlizzardHide` / `ToggleBlizzardHide` + `EditMode.Enter`/`Exit` callbacks. Global `db.hideBlizzardCDM`.
  - ✅ **QA'd 2026-07-07**: `/ga hidecdm` hides the CDM icons AND tracking still fires (Rapid Fire aura
    confirmed working with the CDM invisible — proves alpha-0 keeps the mirror alive). Edit Mode
    round-trip confirmed: CDM reappears + movable while editing, re-hides on exit.
  - **LEARNING (Edit Mode = sample data):** entering Edit Mode makes the CDM display SAMPLE/preview
    state (all items look active) — our mirror faithfully reflected it, so auras flipped on + sounds
    fired. `RefreshDisplays`/`PlaySound` now bail while suppressed. **Subtle bug (fixed 2026-07-07):**
    the sound leaked on Edit Mode *EXIT*, not enter — `EditModeManagerFrame:ExitEditMode()` clears
    `editModeActive` on its FIRST line, THEN tears down the sample data, so those teardown transitions
    saw `EditModeActive()==false` and slipped a stray show/sound through. Fix: a `CDM._emSettling`
    window (set on `EditMode.Exit`, cleared after 0.4s) extends the freeze past exit, then a silent
    `Discover` re-syncs. ✅ QA'd — no sound on EM enter OR exit.
  - ✅ **QA'd**: the panel checkbox reflects/toggles state; persists across `/reload`.

- ✅ **QA'd 2026-07-07 — Groups Phase 1 (data + engine)** — auras can be bucketed into named
  **groups**, each carrying one **load rule** (a `visibility` table) + an **OFF/ON switch** that
  gate ALL the group's auras at once, ANDed **in front of** each aura's own visibility+trigger.
  Engine: `CDM:GroupGate(cfg)` (reuses `VisibilityGate` on `group.visibility` — zero new logic,
  no secret data) called first in `EvalDisplay`; `UpdateVisibilityPoll` also turns on for a live
  group rule. UI: new **GROUP** section in the aura editor — group dropdown (assign / "+ New
  Group…"), **Load Rule…** (opens the now group-aware Visibility editor via `OpenGroupVisibilityEditor`),
  an OFF/ON **switch** (`makeSwitch`, ported from GloomsBuildBarn — Jason prefers sliding switches
  over checkboxes for on/off), and **Delete Group** (members fall back to Ungrouped; auras never
  deleted). Group naming uses a **skinned** `OpenNameDialog` (NOT StaticPopup — see learning).
  Data at `GA.db.groups[gid]` + `db.groupSeq` (top level under schema 1; **Phase 3 migration must
  move them into the profile** — noted in the design doc). Panel grew (628→704h, LIST_ROWS 17→20)
  to fit the section. **Gating only applies with the panel CLOSED** (auras are force-shown while
  it's open — same as trigger/visibility), so QA it on a dummy in combat. QA passed: spec load-rule
  gates the whole set both ways; on/off switch hides/shows the set; create/delete/name all clean.
- ✅ **QA'd 2026-07-07 — Groups Phase 2 (grouped left pane + Manage drawer)** — the LEFT pane now
  renders **group headers** (custom triangle caret `Media/triangle.png`, rotated 90° for expanded;
  a **settings gear** `Media/settings.png` on the right) with their auras nested beneath, then an
  **Ungrouped** section, then the Add/Duplicate/Remove stack. Clicking a header collapses/expands
  (`group.collapsed`; Ungrouped uses `db.ungroupedCollapsed`). The gear opens a docked **Manage
  Group drawer** (`OpenGroupManager`) — **Rename** (reuses `OpenNameDialog`), **Load Rule…**
  (`OpenGroupVisibilityEditor`), an OFF/ON **switch**, **Move Up/Down** (`MoveGroup`, normalizes
  `group.order` then swaps), **Delete Group** (`DeleteGroup` → members to Ungrouped). The aura
  editor's GROUP section shrank to just the **assign dropdown + hint** (group settings moved to the
  drawer). Render model = `BuildLeftPaneEntries()` (typed rows: group / aura / ungrouped) fed to a
  reused row pool in `RefreshList`. QA passed: collapse, gear→drawer, rename, load rule, on/off,
  reorder, delete all clean.
- ✅ **QA'd 2026-07-07 — Per-aura eye toggle** (Jason-requested) — each aura row has an **eye icon**
  on its right (`Media/unhidden.png` = shown, `Media/hidden.png` = disabled) that toggles
  `cfg.enabled`. Disabling greys the row + hides the aura (via `CDM:Discover`, which excludes
  disabled auras from the watch set and hides their frames even while the panel forces others shown).
- ✅ **QA'd 2026-07-07 — Aura rename** — the aura-name title at the top of the editor is a click-to-edit
  EditBox (faint fill + "click to rename" hint); Enter renames `cfg.label` (list name), independent of
  the tracked spell + the on-screen text. Left-pane list rows use `SetWordWrap(false)` so long names
  truncate on one line instead of wrapping.
- ✅ **QA'd 2026-07-07 — On-screen Text overlay** (the label under each aura, fully configurable) —
  `cfg.text = { show, str, font, size, outline, anchor, x, y, color }`. Opened via **Text…** on the
  editor's "Sound & Text" row → a docked **Text drawer**: Show OFF/ON, content box (blank = the aura's
  name — a SEPARATE field from the list name, Jason's choice), **Font** (a picker previewing bundled
  GeneralSans/Khand + LSM fonts in their own typeface), Size, **Outline** (None/Outline/Thick), Color
  (Tint), **Anchor** (Below/Above/On aura/Left/Right via `Displays.LABEL_ANCHOR`), X/Y offset. The
  on-screen label in `Displays:ApplyConfig` is now fully data-driven (bundled font + outline, NOT the
  old `GameFontNormal`); no `cfg.text` ⇒ legacy `showLabel` + name (backward-compatible). Drawer follows
  the panel selection (`C.RefreshTextEditor`, self-guards to when open so it doesn't seed `text` on every
  select). This closes the deferred "Text overlays + LSM font picker" item.
- ✅ **QA'd 2026-07-08 — Profiles (Groups+Profiles Phase 3), the whole feature.** Named, switchable configs
  with a per-character default (WeakAuras-style). Shipped in two committed sub-steps:
  - **3A — data foundation** (`fc41649`): schema 1→2 migration + a `GA.global` (account-wide) / `GA.db`
    (active profile) split. `GA.db` is REPOINTED to the active profile, so the ~40 existing
    `GA.db.displays`/`groups`/`seq` call sites are untouched (the `DB()`/`Groups()` accessors already
    indirect through `GA.db`). Migration runs at **PLAYER_LOGIN** (char name reliable then, NOT
    ADDON_LOADED): the old flat top-level keys (`displays/groups/seq/groupSeq/hideBlizzardCDM/
    ungroupedCollapsed`) MOVE into a profile named `"Name - Realm"` before being cleared. `panelPos` +
    `minimap` moved to `GA.global` (account-wide). QA'd: existing auras + the Marksmanship group survived.
  - **3B — switcher UI** (`6deae65`): a bottom-right **"Profile: ‹name›"** button opens a docked **Profiles
    drawer** — a click-to-switch profile list + **New / Copy Current / Rename / Delete** (Delete confirms via
    a small skinned `C:OpenConfirm`, and refuses to delete the only profile). Core API in `Core.lua`
    (`GA:SwitchProfile/CreateProfile/CopyProfile/RenameActiveProfile/DeleteProfile/ProfileNames/
    ActiveProfileName`); each repoints `GA.db` then `GA.RefreshForProfile` (hide the old profile's frames →
    `CDM:Discover` → `C:OnProfileSwitched` rebuilds the panel + re-shows the new set). `/ga profile [name]`
    back-door. QA sweep passed: create+switch both ways, delete+fallback+confirm, and **copy independence**
    (deep-copied — editing the copy left the original untouched). Deleting the ACTIVE profile falls back to
    the first remaining one; chars pointing at a deleted profile re-resolve to their own default next login.
- ✅ **QA'd 2026-07-08 — Slider thumbs recolored** purple → **orange `#FF7729`** (`COLOR.orange`) on the
  Alpha/Width/Height/X/Y sliders (Jason request). Scrollbar thumbs stay purple. `MakeSlider` only.
- ✅ **QA'd 2026-07-08 — Appearance-first aura creation + DECORATION auras** (`bcb1912`). Scope had
  outgrown "pick a spell first": **`+ Add Aura` now makes a BLANK aura** (placeholder `Circle_Smooth`
  graphic, name "New Aura", `showLabel=false`), selected in the editor — NO picker popup. **Spells enter
  ONLY via the Trigger** now (the picker still backs "Edit Trigger… → + Add Condition"; the "Track a
  Spell" shortcut Jason briefly considered was dropped as redundant with triggers). `cfg.spellID` is now
  **optional**. `EvalDisplay` has THREE cases after the Group+Visibility gates: (1) has a Trigger → trigger
  decides; (2) no trigger + has `spellID` → auto-show on that spell's state (**legacy back-compat, no
  migration**); (3) no trigger + no `spellID` → **pure decoration, always shown** (e.g. a graphic gated to
  out-of-combat via Visibility — Jason's "pink cat in the corner" case). Trigger summary now says which:
  "always shown (decoration)" vs "shows on its own spell's state". QA'd: blank create, decoration persists
  when panel closed, Visibility(Out-of-Combat) hides/shows it on a dummy. **The engine already watched
  trigger-condition spells (`WatchedSpells`) and already treated the Trigger as the sole source of truth
  when present — this change just made that the primary model + allowed no-spell auras.**
- ✅ **QA'd 2026-07-08 — Glow effects (LibCustomGlow)** (`fa12820`). New **"Effects"** section at the
  bottom of the editor with a **"Glow…"** button → docked **glow drawer**: Type (None / Autocast Shine /
  Pixel Glow / Proc Glow / Action Button Glow) + optional **Custom Color**. `cfg.glow = { type,
  customColor, color }`. Engine in `Displays.lua`: `StartGlow`/`StopGlow`/`ApplyGlow` (all **pcall-guarded**
  → a bad arg degrades to "no glow", never a Lua error); the glow follows the frame's shown state via
  **OnShow/OnHide hooks** (starts on show, stops on hide, no per-poll churn since those fire only on real
  transitions) and re-applies on any config change (`ApplyConfig` calls `ApplyGlow`). **Pure rendering, no
  aura data.** LibCustomGlow-1.0 embedded like our other libs (TOC loads it after LibStub; `.pkgmeta`
  fetches it — URL flagged to confirm before first release). Panel grew 704→740 / `PANE_H` 600→636 for the
  Effects row; `MakeColor` gained an optional label (reused as "Custom Color"); glow UI state on `C._glow`.
  **KNOWN + inherent:** the glow traces the aura's **frame rectangle** (bounding box), NOT the texture's
  alpha shape — so it looks best on square-ish icons and boxy on non-square/irregular art. Not fixable
  (LibCustomGlow limitation); crop-to-fit (Frame & Shaping roadmap) is the mitigation for non-square icons.
- ✅ **QA'd 2026-07-08 — One-level GROUPED trigger logic (AND/OR/NONE)** (`1294c8f`). A trigger condition
  can now be a **group** (`{logic, conditions={leaf,…}}`) alongside leaves, so `(X OR Y) AND Z` etc. are
  expressible. `EvalTrigger` recurses + supports **NONE** (NOR = NOT any, group-level negation);
  `WatchedSpells` recurses (`CollectCondSpells`) so group-nested spells get mirrored. Backward-compatible
  (flat triggers = a top group of leaves). Editor rewritten as a scrolling tree: top logic + leaf rows +
  group headers (own AND/OR/NONE) + indented conditions + a purple **"+ Add to group" text link** +
  "+ Add Condition" / "+ Add Group". State on `C._trig`. **Per-condition NOT** already exists via the
  inverse states (Buff Inactive / CD On Cooldown). **⚠ Flat triggers verified in combat (auras show); a
  trigger with an actual GROUP has NOT been end-to-end QA'd in combat yet — do that next session.**
- ✅ **QA'd 2026-07-08 — Eye = editor preview + Disabled toggle** (`3e5d34a`). The eye icon was RE-scoped
  (Jason clarified it never meant enable/disable): it now = **"show THIS aura on screen while the panel is
  open"** (`cfg.preview`, default off), purely an editor convenience. While the panel is open the preview
  shows only the **selected aura + eye-on auras** (`Displays:RefreshForced`) instead of all at once — fixes
  the "every aura visible while editing" clutter. In-game (panel closed) is unchanged. **Enable/disable**
  moved to a **"Disabled | Enabled" switch** at the bottom of the Visibility editor — drives `cfg.enabled`
  for an aura, or `group.enabled` in a group's **Load Rule** (both places). Greys the list row when off.
  A one-time **v2 migration** (`prof._eyeFixed=2`) re-enables every aura to recover from (a) the old eye
  mis-setting `enabled=false` and (b) an interim switch's Lua-idiom bug (see LEARNINGS).
- ✅ **QA'd 2026-07-08 — Target-DoT / debuff tracking** (`bc6cdb0`). DoT auras now follow the current target
  (verified Warlock: single-target, target-swap, multi-target Agony; Hunter: no regression). Route CDM state
  by a per-FRAME role (`CDM.frameKind`) so a spell in two viewers stops clobbering its own state. See ACTIVE
  THREAD + API-NOTES §9. ⏳ instance/raid unverified.
- ✅ **QA'd 2026-07-08 — Aimed Shot / charge-spell availability** (`74a6ae0`). Hidden shadow `Cooldown` fed a
  duration OBJECT → `IsShown()` gives ≥1-charge-castable secret-safely; flows into `cd_ready`. Verified over a
  full charge cycle incl. procs/reset. API-NOTES §9.3. ⏳ instance/raid unverified; exact count = backlog.
- ✅ **QA'd 2026-07-08 — Two-panel trigger picker** (`e98d706`). Cooldowns | Buffs & Debuffs columns + search;
  `selfAura` (Buff/Debuff) labels + unit-aware wording; sourced from live frames (only lists trackable spells).
- ✅ **QA'd 2026-07-08 — `/ga probe` + `/ga capture`** — read-only secret-safe-signal diagnostics that log to
  `GloomsAurasDB.probeLog` (Claude reads it off disk after `/reload`). Keep until the CDM-tracking thread closes.

## Hard-won LEARNINGS (verified — do NOT rediscover)
- **The `a and b or c` idiom BREAKS when `b` is `nil`/`false` — never use it to assign nil.** A "Disabled"
  switch set `cfg.enabled = v and nil or false`: for `v==true` that's `(true and nil)`→nil→`(nil or false)`→
  **false**, so it evaluated `false` in BOTH directions — could disable an aura but never re-enable it, which
  looked like "auras don't show in combat" (they were stranded off). Use an explicit `if v then x=nil else
  x=false end`. Lesson: for any assignment whose "true" value is `nil` or `false`, write the `if`, not the
  ternary. (2026-07-08; also mirrored a symptom into a scary-looking display bug — always suspect data state
  before the render path.)
- **`FontString:SetShadowColor` / `SetShadowOffset` render NOTHING in this client** — a drop shadow via
  the shadow API is invisible at any offset. We dropped the shadow option (outline flags are the text
  styling). If a shadow is ever truly needed, draw it manually (a black text copy offset behind), but
  even a behind-sublevel copy layered awkwardly — not worth it; outline suffices.
- **Lua 5.1 caps a function at 60 UPVALUES (`local`s captured from enclosing scope).** `Config.lua`'s
  giant `Build()` hit exactly 60 after Phase 1; one more (a `DEFAULT_FONT` ref) → `function ... has
  more than 60 upvalues` at LOAD time and the panel wouldn't open. luac 5.5's `-p` does NOT enforce the
  60 cap, **but `luac -l -l Config.lua` prints each function's `N upvalues` count** — subtract 1 for
  `_ENV` (5.5 has it, 5.1 doesn't) to get the 5.1 number. Build's prototype count = every module-scope
  `local` referenced by Build OR any closure nested in it. Fix pattern: extract chunks of `Build` into
  their own module-level functions (`BuildGroupSection`, `BuildGroupManager`) so each gets its own 60
  budget — OR hang new state/helpers on the `C` table (a field access, not an upvalue). **Build sits at
  57 (Lua 5.1) after Phase 3; keep it there.**
- **Lua caps a function at 200 LOCALS too — and the file CHUNK (top-level) counts (hit 2026-07-08).**
  Every module-scope `local` (constants, `local function` helpers, forward-decls) counts toward the main
  chunk's 200. Phase-3B's first draft added ~11 module locals and overflowed: `luac -p` → `too many
  local variables (limit is 200) in main function`. **Unlike the 60-upvalue cap, luac 5.5's `-p` DOES
  catch this** (same limit). `Config.lua`'s chunk is at **198/200** — essentially full. Fix pattern used:
  put ALL new profile state + UI functions on the **`C` table** (`C._prof`, `function C:OpenProfileManager`…)
  instead of module locals → zero new chunk locals. Do the same for any future Config.lua feature.
- **Game fonts lack the ▼/▶ unicode triangles → they render as a tofu box.** Don't use unicode
  glyphs (or native Blizzard textures — Jason's rule) for UI marks. Use Jason's bundled PNG icons in
  `Media/` shown untinted (`SetVertexColor(1,1,1,1)`): `triangle.png` (collapse caret, rotated via
  `Texture:SetRotation` — right=collapsed, -pi/2=down=expanded), `settings.png` (gear), `hidden/
  unhidden.png` (eye), `lock_locked/unlocked.png`. Ask Jason to make an icon rather than reaching for
  a glyph or Blizzard art.
- **StaticPopup edit box is `dialog.EditBox` (PascalCase) in Midnight, NOT `dialog.editBox`** — the
  lowercase alias is GONE (GameDialog.xml system), so `OnShow`/`OnAccept` referencing `self.editBox`
  throw `attempt to index field 'editBox' (a nil value)`. We sidestepped StaticPopup entirely with a
  small **skinned** `OpenNameDialog` (flatEditBox + OK/Cancel) — nicer chrome AND no client-field
  fragility. If StaticPopup is ever needed, use `dialog.EditBox or dialog.editBox`.
- **1-charge spells are NORMAL cooldowns, not the "unreadable charge" wall (fixed 2026-07-07):**
  `cooldownInfo.charges` just means "uses the charge system". What matters is **maxCharges**:
  **1 ⇒ track like any cooldown** (Kill Shot, most executes); **≥2 ⇒ genuinely unreadable in combat**
  (Aimed Shot). We were bucketing *any* charge flag as unreadable, so a 1-charge cd's availability
  stayed `nil` forever and never wired into the cooldown-widget hook path → `cd_ready` was stuck.
  Fix: read `GetSpellCharges().maxCharges` (readable OOC), cache it in `CDM.maxCharges` (persists
  across Discover), classify `isCharge = maxCharges>=2`. **This also transparently handles spell
  OVERRIDES** (Black Arrow replacing Kill Shot via a hero talent): the CDM item's cooldown widget
  reflects the override, and we match the item by base spellID (`InfoMatchesSpell` checks
  spellID/override/linked), so tracking Kill Shot mirrors Black Arrow with no override-specific code.
- **`item.isOnActualCooldown` is SECRET in combat when off-GCD (verified via /ga trace 2026-07-07):**
  it's `not isOnGCD and cooldownIsActive`; on the GCD it short-circuits to a plain `false`, but OFF
  the GCD it evaluates `cooldownIsActive` (a secret in combat) → returns SECRET *exactly when the real
  cooldown matters*. So it is NOT a combat availability source (unlike `item:IsActive()` for buffs).
  `CDM:SyncCooldowns` uses it only as an OUT-OF-COMBAT accuracy pass; **in-combat availability comes
  from the `CooldownFrame_Set/Clear` widget hooks.** TRADE-OFF still stands: right after casting the
  tracked cd spell, during its ~1.5s GCD the hook skips (isOnGCD) so it briefly reads "available".
- **Blank labels on the FIRST login of a session (2026-07-07):** WoW sometimes hasn't finished
  loading a bundled runtime TTF when the panel is built on an early `/ga`, so *some* labels render
  BLANK (button backgrounds fine, glyphs missing) until a `/reload` caches the font. `setFont`'s
  fallback only catches an *invalid* path, not "valid path, glyphs not ready yet". Fix: `GA.PreloadFonts`
  in Core.lua draws+measures a throwaway string in each `GA.FONT` face at `PLAYER_LOGIN`, warming the
  cache before any panel builds. Only reproduces on a true fresh login (a `/reload` already has the
  fonts cached), so verify by logging out to char-select and back in, then opening `/ga` immediately.
- The frame method is **`StopMovingOrSizing`**, NOT `StopMovingAndSizing` (nonexistent). The
  typo made every drag "stick to the cursor." Cross-check method names against GloomsBuildBarn.
- **Create frames HIDDEN** (`f:Hide()` at end of build) so the first `:Show()` actually
  transitions and fires `OnShow` — otherwise "have to open it twice to populate" bugs.
- `Button:SetScript("OnClick", fn)` calls `fn(button, ...)` — passing a bare function whose
  first param means something else gets the button as that arg (caused the OpenPicker crash).
  Wrap: `function() fn() end`.
- **Buff active-state**: `item:IsActive()` is a **plain bool in open-world combat** (confirmed).
  Mirror via `hooksecurefunc(itemFrame, "OnActiveStateChanged", …)`.
- **Non-charge cooldown availability WORKS**: hook globals `CooldownFrame_Set`/`CooldownFrame_Clear`
  filtered to `item:GetCooldownFrame()`, plus `item:OnCooldownDone`. Seed initial state OOC via
  `GetSpellCooldown`. Never reads a secret.
- **DoTs / target debuffs — the `IsActive()` mirror is NOT enough (VERIFIED 2026-07-08, Warlock, 8
  captures):** the Tracked-Bar `IsActive()` reads correctly when POLLED, but (1) nothing re-polls it on
  a target SWAP (no `OnActiveStateChanged` fires) → it goes stale on screen, and (2) a spell enrolled in
  TWO viewers (Haunt in Essential `cat=0` + BuffBar `cat=3`) makes `Discover` map both frames to one
  spellID → they fight over the shared `buffActive/available[]` var = the "goes random" symptom. The
  proven fix: read `frame.auraInstanceID` + `C_UnitAuras` on the `selfAura` unit, re-eval on
  `PLAYER_TARGET_CHANGED`, and disambiguate matching by cooldownID. **Proven correct across 8 target-swap
  captures; NOT yet built or QA'd. UNVERIFIED in instance/M+/raid.** Detail: API-NOTES §9.
- **Trigger `nil`-availability default (fixed 2026-07-07):** an idle-available cooldown never fires
  a transition and is secret in combat, so `available[sid]` stays **nil**. `EvalDisplay` (auto,
  no-trigger) already defaulted nil→ready, but `EvalCondition` (cd_ready as a trigger condition)
  defaulted nil→NOT-ready — same value, opposite meaning. Compound "RF cd_ready AND …" silently
  failed. Fix: `cd_ready` now defaults nil→READY **for non-charge only** (charge stays nil→not-ready,
  since charges are genuinely unreadable). Lesson: the two eval paths must agree on unknown-state.
- **GCD false-positive on `CooldownFrame_Set` (fixed 2026-07-07):** every cast triggers the global
  cooldown, and the CDM re-runs `CooldownFrame_Set` on each item's widget to redraw — even for a
  spell NOT on its own cd. The hook was marking it unavailable, sticking it "on cooldown" until a
  real off-cd transition (this is why casting Aimed Shot/Multi-Shot broke Rapid Fire's condition).
  Fix: the Set hook now **skips while `item.isOnGCD == true`** (plain bool, guarded), keyed via a
  new `cdFrameToItem` map. Also reseed availability on `PLAYER_REGEN_ENABLED`. TRADE-OFF: casting
  the tracked cd spell *itself* now leaves its aura lit ~1.5s (the GCD) before it flips to on-cd.
- **`/ga trace`** (new): focused per-display dump — shown?, our `buffActive`/`available` mirror,
  the item's cached `isOnGCD`/`isOnActualCooldown`/`cooldownIsActive`, and each trigger condition's
  evaluated result. Ask Jason to run it IN the failing state — it makes trigger bugs a 30-sec find.
- **WALLS (confirmed from client docs — cannot out-code):**
  - **Cooldown timers in combat**: every `SetCooldown*` is `AllowedWhenUntainted` → an addon
    can't feed a secret duration to a timer widget. Works out of combat only.
  - **Charge-spell availability**: `GetSpellCharges` AND `GetSpellCastCount` are both
    `SecretWhenCooldownsRestricted`; `IsSpellUsable` ignores cooldown AND charges (always true).
    So directly READING "do I have a charge" is unknowable in combat. **✅ BUT (2026-07-08) the DOOR is
    CONFIRMED — the "shadow cooldown" technique: route a duration OBJECT through a hidden Cooldown widget
    and read its `IsShown()` to DERIVE availability without reading the count. VERIFIED on Aimed Shot
    (2→1→0→1→2): `mainShown==false` ⇔ ≥1 charge castable; the object feed does NOT throw in combat. This
    RETIRES the wall for AVAILABILITY (gives "≥1", not exact count). Details: API-NOTES §9.3. NOT yet
    built into the addon.**
  - Only partial charge signal: `C_SpellActivationOverlay` detects **procs** — but procs that
    grant a buff (e.g. Lock and Load) are already trackable as a **buff-active** condition, so
    that path is redundant.
- **Placement requirement (CONFIRMED from CDM source 2026-07-08)**: a spell must be in a TRACKED CDM
  section — Essential / Utility / Tracked Buffs / Tracked Bars — to be tracked. "Not Displayed" items get
  moved to a separate **Hidden** category (`HiddenSpell`/`HiddenAura`, via a `HideByDefault` flag + saved
  layout — `CooldownViewerSettingsDataProvider.lua`), so they have **no item frame** and GloomsAuras can't
  hook them. `/ga debug` = "verify tracking" (FOUND/NOT FOUND per display); `/ga charges`
  reports charge status. (Bonus source find: `CooldownViewerMixin:RefreshActiveFramesForTargetChange` — the
  CDM DOES re-scan on target change; relevant to the DoT reappear-lag known issue.)
- **Trigger picker MUST source from the data provider — NOT live frames, NOT the raw category set (VERIFIED
  2026-07-08, sixth session; three approaches tried, do NOT relitigate).** The trigger picker (`BuildAuraLists`
  in Config.lua) lists trackable spells; the ONLY correct source is
  `CooldownViewerSettings:GetDataProvider():GetOrderedCooldownIDsForCategory(cat, false)` +
  `:GetCooldownInfoForID(id)` — the exact ordered set each viewer lays out (CooldownViewer.lua RefreshLayout).
  Why the other two FAIL: **(a) live item frames** — a frame clears its cooldownID the instant it's
  released/hidden (Blizzard's itemFramePool reset callback → `ClearCooldownID` → `cooldownInfo=nil`), and the
  Essential viewer HIDES items while inactive (`hideWhenInactive`), so out of combat every READY Essential
  cooldown (Rapid Fire, Aimed Shot…) reports no spellID and silently vanished from the picker. **(b) raw
  `GetCooldownViewerCategorySet(cat, …)`** — returns raw PRE-remap IDs + flags: it under-returns Tracked Buffs
  AND, paired with a manual HideByDefault filter, DROPS known buffs the user actually displays (Lock and Load,
  Trueshot, Aspects — HideByDefault-by-default but placed into a tracked category). The data-provider list is
  frame-independent, respects the saved layout + HideByDefault remap + `isKnown`, so it lists exactly what's
  displayed. Fallback to the raw set (with our own isKnown + HideByDefault filter) only if the provider is nil.

## Diagnostics / commands
- `/ga` — open the options panel. `/ga help` — list commands.
- `/ga debug` — CDM state dump (availability/kind/charge/IsSpellUsable per display). Ask Jason
  to paste this (or BugSack) when diagnosing.
- `/ga profile [name]` — list profiles (active marked), or switch to one. Panel is primary.
- `/ga minimap` — show/hide the minimap button (persisted).
- `/ga hidecdm` — hide/show Blizzard's Cooldown Manager (alpha-0, tracking stays live; persisted).
- `/ga charges` — which cooldowns support availability tracking (charge spells flagged). Run OOC.
- `/ga trace` — per-display trigger diagnostic (shown?, buffActive/available mirror, item cooldown
  fields, each condition's eval). Run IN the failing state; makes trigger bugs a 30-sec find.
- `/ga probe [filter]` — EXHAUSTIVE read-only secret-safe-signals dump (per CDM item: `selfAura`,
  `auraInstanceID` present?, `C_UnitAuras` player/target presence + duration, which hook methods the
  frame exposes, shadow-cooldown readiness). **Writes each capture to the SavedVariables file**
  (`WTF/Account/AELWYN/SavedVariables/GloomsAuras.lua` → `GloomsAurasDB.probeLog`, last 40) so Claude
  reads it straight off disk after a `/reload` — no transcription, and captures can be taken at exact
  states. `/ga probe clear` wipes the log.
- `/ga capture` — a movable **CAPTURE button**: click it at each game state (mid-combat, right after a
  target swap) to fire a probe without typing. Built for the §9 investigation.
- `/ga add|remove|list|pos|size|preview|test` — legacy/back-door commands (panel is primary).

## SavedVariables data model  (schema 2 — profiles, since 2026-07-08)
> **Two layers (Phase 3).** `GA.global` = the raw SV `GloomsAurasDB`; `GA.db` = the ACTIVE PROFILE
> `GloomsAurasDB.profiles[activeName]`, REPOINTED on a switch. So `GA.db.displays/groups/seq/groupSeq/
> hideBlizzardCDM/ungroupedCollapsed` all read the active profile; only `panelPos` + `minimap` live on
> `GA.global` (account-wide). Active profile resolved at **PLAYER_LOGIN** (`GA.SetupActiveProfile`), which
> also runs the one-time schema 1→2 migration. Profile ops are `GA:SwitchProfile/Create/Copy/
> RenameActive/Delete/ProfileNames/ActiveProfileName` in `Core.lua`.
```
GloomsAurasDB = {                                     -- = GA.global (account-wide)
  schema = 2,
  profiles    = { ["Name - Realm"] = <PROFILE>, … },  -- GA.db points at the active one
  profileKeys = { ["Name - Realm"] = "profileName" }, -- which profile each character uses
  minimap  = { hide, minimapPos },                    -- LibDBIcon (account-wide)
  panelPos = { x, y },                                -- panel window position (account-wide)
}
PROFILE = { displays = { [id]=<AURA_CFG> }, groups = { [gid]=<GROUP> }, seq, groupSeq,
            hideBlizzardCDM = bool/nil, ungroupedCollapsed = bool/nil }   -- = GA.db
```
> **Keying (unchanged from 2026-07-07 Duplicate work):** each profile's `displays` key is an opaque
> **display id**, NOT
> the spellID. Originals keep a numeric **spellID** key (so existing data is untouched); **duplicates**
> get a unique `"dN"` **string** key (counter `GloomsAurasDB.seq`). The tracked spell is ALWAYS
> `cfg.spellID`. Rule of thumb: `GA.Displays.frames[]`, `CDM.lastShown[]`, `lastPlay[]`, `selectedID`,
> and every `db.displays` iteration key = **display id**; `CDM.kind/available/buffActive/isCharge[]`,
> `frameToSpell` values, and all `C_Spell.*` calls = **cfg.spellID**. `DisplayList()` sorts by
> `cfg.spellID` then key (never compares number vs string → no error; existing order unchanged).
```
{ spellID = <tracked spell or NIL — optional since 2026-07-08; nil = decoration>, label,
  enabled = true (false ⇒ "Disabled" in gameplay, set via Visibility editor; greys the list row),
  preview = bool/nil (the EYE icon: show this aura on screen while the panel is open — editor only),
  width=64, height=64, point={"CENTER",x,y}, alpha=1,
  lockAspect = bool/nil,  aspect = <w/h ratio captured at lock time> or nil,
  showLabel=true, texture = <path/fileID or nil=spell icon>,
  color = {r,g,b} or nil,  desaturate = bool/nil,  blend = <mode or nil=BLEND>,
  strata = <mode or nil=HIGH>,  sound = { file, name, channel } or nil,
  trigger = { logic="AND"|"OR"|"NONE", conditions = { <leaf> | <group>, ... } },  -- one-level groups
    -- leaf = { spellID, state, name };  group = { logic="AND"|"OR"|"NONE", conditions={ <leaf>,... } }
    -- AND=all, OR=any, NONE=nor(NOT any). EvalTrigger recurses; WatchedSpells recurses (CollectCondSpells).
  visibility = { combat="in"|"out"|nil, target="has"|"none"|nil, casting/mounted/vehicle/
    instance/encounter/resting/stealthed/group/raid/warmode/alive = true/nil,
    specs = { [specID]=true } or nil, spellKnown = spellID or nil },
  group = <groupID> or nil,   -- which group this aura belongs to (nil = Ungrouped)
  text = { show=bool, str="custom text"|nil(=aura name), font=path|nil, size=N|nil,
    outline="NONE"|"OUTLINE"|"THICKOUTLINE"|nil, anchor="BOTTOM"|"TOP"|"CENTER"|"LEFT"|"RIGHT"|nil,
    x=N|nil, y=N|nil, color={r,g,b}|nil },   -- on-screen label; nil ⇒ legacy showLabel+name
  glow = { type="autocast"|"pixel"|"proc"|"button"|nil(=none), customColor=bool|nil,
    color={r,g,b}|nil } }   -- LibCustomGlow effect; active while the frame is shown
```
`GA.db.groups[<groupID>] = { id, name, order, enabled (false=off), collapsed (bool),
visibility = <same shape as an aura's visibility> or nil }` and `GA.db.groupSeq` (the "gN"
id counter) + `GA.db.ungroupedCollapsed` (bool) — all now PER-PROFILE (moved off the top level in the
schema-2 migration). A grouped aura shows only when its **group is on AND the group's load rule passes**
— ANDed in front of the aura's own Visibility + Trigger.
`GA.db.hideBlizzardCDM = true/nil` (PER-PROFILE; hides the four Blizzard CDM viewers via alpha-0).
`GA.global.minimap = { hide, minimapPos }` (LibDBIcon, account-wide). Display shows when its **Trigger**
passes AND its **Visibility** gate passes (no visibility set ⇒ always eligible); an `enabled=false`
(Disabled) aura never shows/tracks. **Editor preview:** while the panel is open, `Displays:RefreshForced`
shows ONLY the selected aura + `preview`-on (eye) auras — NOT all of them (was "all enabled" before 2026-07-08).
`state` ∈ `buff_active | buff_inactive | cd_ready | cd_oncd`. **No trigger** (after Group+Visibility pass):
if `cfg.spellID` set ⇒ auto-behavior (its own spell: buff→active, cooldown→available); if NO `spellID` ⇒
**decoration, always shown**. New auras (`+ Add Aura`) are blank/decoration; spells are added via the
Trigger only. Width/Height range 8–8192, offset slider ±2000 (drag/`/ga pos` un-clamped).
`GA.global.panelPos` stores the panel location (account-wide); `GA.global.schema = 2`. (The old
top-level `displays/groups/seq/groupSeq/hideBlizzardCDM/ungroupedCollapsed/media` keys are removed by the
migration.)

## Texture picker sourcing (verified 2026-07-07 — do NOT relitigate)
- **Game icons** are enumerable from the client: `GetMacroIcons`/`GetLooseMacroIcons`(+Item variants)
  fill a table with fileIDs + loose `Interface\ICONS\<name>` strings (Blizzard's own IconDataProvider
  pattern). No names to search by → browse-only.
- **The pretty aura shapes are NOT game files** — they're bundled inside WeakAuras/PowerAuras/TWA.
  We bundled them (copied TWA's `Media/Textures` + `PowerAurasMedia/Auras`, generated the manifest
  from TWA's `Private.texture_types`, rewrote paths TWA→GloomsAuras). No-extension `.tga` paths
  render fine in this client (mirrors TWA's working setup verbatim).
- **LibSharedMedia only carries bar/border/background textures**, not aura shapes — so its category
  is bar textures. StoneTweaks registers its *Textures* there as `statusbar`.
- **StoneTweaks Graphics** (the useful custom art) are NOT in LSM; they're files listed in
  `StoneTweaksDB.graphics` = array of `{name,file}`, path `Interface\AddOns\StoneTweaks\Graphics\<file>`.
  We read that table live at picker-open (reading another addon's SavedVariables global is fine).

## NEXT / pending

### ▶ ACTIVE THREAD (2026-07-08) — secret-safe DoT tracking (Jason's Affliction Warlock)
**DoT approach VERIFIED (API-NOTES §9). Step 1 SHIPPED + QA'd — and it fixed the target-swap for FREE.**
Root-cause bugs (§9.2) were (1) no re-eval on target change and (2) spellID-only matching COLLIDING when a
spell sits in two viewers (Haunt = Essential `cat=0` + BuffBar `cat=3`). **Jason wants to test EVERYTHING —
one step per QA pass; never declare done before he confirms in-game.**

- **Step 1 (frameKind disambiguation) — DONE + COMMITTED, QA'd on Warlock AND Hunter.** Route state by a
  per-FRAME role (`CDM.frameKind`) so a spell's cooldown entry can't clobber its aura entry's `buffActive`
  (and vice-versa); aura wins for the per-spell `kind` (auto path). Fixed the "goes random" flicker.
  **SURPRISE (verified): it ALSO fixed the target-swap** — once the cooldown entry stopped stomping it, the
  BAR entry's own `OnActiveStateChanged` (fires when the DoT leaves the current target) drives hide/show
  correctly. So the planned "Step 2" (`PLAYER_TARGET_CHANGED` + `auraInstanceID`) turned out **UNNECESSARY
  for correctness**. QA'd on Warlock: aura follows current target — shows on the DoTted dummy, hides on a
  clean one, returns on swap-back, hides on expiry; no errors, no flicker.
- **KNOWN ISSUE (minor; Jason deferred it) — reappear LAG.** Swapping BACK to a DoTted target occasionally
  lags ~0.5s before the aura returns (sometimes instant). Root cause = the CDM's target re-scan latency (it
  only knows the DoT is on the new target after its `UNIT_AURA`-driven rescan; we update exactly then).
  Re-polling the CDM's own state CAN'T beat this (its flag flips + fires its event simultaneously). The ONLY
  lever = scan the target OURSELVES on `PLAYER_TARGET_CHANGED` via `C_UnitAuras` (by spellID), independent of
  the CDM — UNVERIFIED (secret-safety in combat) → needs a probe first. Not worth derailing; revisit later.
  (ArcUI has the same constraint; its "High Frequency Updates" toggle is its mitigation.)
- **QA STATUS:**
  1. **Hunter regression — ✅ PASSED (2026-07-08).** Existing auras unchanged (Rapid Fire cd, Trick Shots
     buff, "Precise Shots active AND Kill Shot cd_ready" combo).
  2. **Multi-target DoT — ✅ PASSED (2026-07-08).** Agony on 2 dummies, swapping between them: stays shown on
     both, hides on a clean target. Semantic confirmed: tracks "on my CURRENT target," NOT any-enemy/count.
  3. **Instance check — ✅ GOOD ENOUGH (2026-07-08, sixth session; follower dungeon, Gloomwick).** Ran 7 `/ga
     probe` captures dotting two targets in a follower dungeon; all four DoTs (Haunt/Agony/UA/Corruption) read
     **present on target** with plain-int auraInstanceIDs + duration objects, and followed the target across
     captures. **KEY (verify-before-claiming):** under the hood the follower dungeon was **identical to open-world
     combat** — cooldown fields came back `SECRET(boolean)` (normal in ANY combat), but **auraInstanceID stayed a
     plain readable int, never secret**. So it did NOT exercise the feared "auras go secret in group content" path;
     it's the same difficulty as the open-world test. The truly-stricter tier (real M+/raid) was NOT tested — Jason
     called it: he judges the secret-value rules don't vary by content tier (a global anti-automation gate, not
     difficulty-gated), and the captures show no content-based aura secrecy. Banked as sufficient; the
     `secret⇒present` fallback remains reasoned-but-unexercised. Bonus: the charge **shadow** readback returned a
     clean value even while raw cooldown fields were secret — confirms that mechanism survives combat secrecy.
  4. **Deathblow / proc (`hasAura=false`) tracking — ✅ PASSED (2026-07-09, sixth session; Hunter/dummy).**
     Made a "Deathblow — buff is active" aura, fished the proc off Aimed Shot/Rapid Fire — it **lights up** on
     the proc and hides when consumed. So a `hasAura=false` activation-driven proc DOES register through our
     normal buff mirror (`item:IsActive()` / `OnActiveStateChanged`); **no separate activation-overlay path
     (§9.1) is needed.** The `hasAura` flag matters only for picker LABELING (already dropped as unreliable),
     not for whether the buff tracks.
- **Charge "shadow cooldown" (Aimed Shot) — ✅ BUILT + QA'd + committed (Hunter, 2026-07-08).**
  `CDM.chargeShadow[sid]` = a hidden `Cooldown` fed the GCD-stripped `GetSpellCooldownDuration`; its
  `OnShow → available=false` / `OnHide → available=true` fire exactly at the 0↔1-charge boundary; re-fed on
  `SPELL_UPDATE_COOLDOWN` + `PLAYER_REGEN_ENABLED`; seeded from `IsShown()` at Discover (`FeedChargeShadow`
  `seed=true`). Flows into the existing `cd_ready` machinery — **no new trigger types.** QA'd flawless over a
  couple minutes incl. natural regens, **procs, and shortened cooldowns**. Isolated to the `if charge` branch,
  so DoT / non-charge paths are structurally untouched. API-NOTES §9.3. **LIMIT: "≥1 available", not exact
  count** (that's the next revisit — see pending; 2-charge spells CAN get exact count via the charge shadow).
- **Optional payoff:** a real **duration countdown** on auras (`GetAuraDuration` → duration object → bar).
- **Tooling:** `/ga probe [filter]` + `/ga capture`; captures land in `probeLog` (read off disk). Don't
  delete/rewrite the probe code until this thread closes.

### Groups + Profiles — ALL THREE PHASES DONE ✅ (spec: [docs/GROUPS-PROFILES-DESIGN.md](GROUPS-PROFILES-DESIGN.md))
- **Phase 1 — Groups data + engine.** ✅ **DONE + QA'd 2026-07-07** (see BUILT list). Committed.
- **Phase 2 — Grouped left pane + Manage drawer.** ✅ **DONE + QA'd 2026-07-07** (see BUILT list).
- **Phase 3 — Profiles.** ✅ **DONE + QA'd 2026-07-08** (see BUILT list): schema-2 migration + `GA.global`/
  `GA.db` split (`fc41649`), switcher UI (`6deae65`). Feature complete; nothing left open here.

### ▶▶ START HERE NEXT SESSION
**Fifth session (2026-07-08) shipped the big secret-safe wins — DoT/target-debuff tracking, Aimed Shot charge
availability, and the two-panel trigger picker — all committed + pushed (see ACTIVE THREAD + fifth-session
note).** Highest-priority OPEN items:

**A. Finish verifying the CDM-tracking work (ACTIVE THREAD above has full detail):**
- ~~**Instance / M+ / raid check**~~ ✅ **BANKED (2026-07-08, sixth session)** — follower dungeon passed; behaved
  identically to open-world combat (auras readable, cooldowns secret-in-combat as always). Jason's call: rules
  don't vary by content tier, so sufficient. See QA STATUS #3.
- ~~**Deathblow / proc (`hasAura=false`) tracking**~~ ✅ **PASSED (2026-07-09, sixth session)** — proc buff
  lights up through the normal buff mirror; no separate activation path needed. See QA STATUS #4.
- **Exact charge COUNT** — revisit (2-charge spells can derive it from the charge shadow; backlog item below).
  **← the only Track-A item left; everything else here is verified.**

**B. Then resume the EFFECTS/appearance push** (Glow ✅ + grouped triggers ✅ + eye-preview/Disabled ✅ shipped):
0. ~~**⚠ QA a GROUPED trigger IN COMBAT first.**~~ ✅ **DONE + QA'd (2026-07-08, sixth session; Hunter/dummy).**
   Built `(Rapid Fire ready OR Aimed Shot ready) AND Precise Shots active` and drove it through all states in
   combat — the nested OR group holds while one leaf is true, the whole group correctly goes false only when
   BOTH leaves are false, and it ANDs with the top-level Precise Shots leaf. Grouped triggers work end-to-end.
   (NONE-group test was set up as a quick follow-on but not run — low risk; the recursion + NONE path is the
   same code the AND/OR path exercised.)
1. **Motion** — animate auras via native WoW **AnimationGroups** (pure rendering, no lib, no secret data):
   presets Pulse (scale) / Spin (rotation) / Bounce/Drift (translate) / Fade (alpha) / Orbit, each with
   speed + amount, plus a one-shot "pop/flash on show". Build as a **"Motion…"** button on the existing
   **Effects** row → its own docked drawer (mirror the glow drawer). Start/stop the AnimationGroup on the
   frame's OnShow/OnHide (same hook points glow uses).
2. **Frame & Shaping** — colored **border** (TWA "Add Border"; we bundle ring/border textures) + **crop-to-fit
   / zoom** for non-square icons (`SetTexCoord` to crop instead of stretch — ALSO the mitigation for the
   boxy-glow-on-non-square-art issue) + **rounded-corner presets** via `MaskTexture` (Square/Rounded/More/
   Circle — radius is baked into the mask, NOT a free px slider; verify masks work in Midnight first).
- **Dynamic group layout** — backburnered (Jason's call: "can of worms").
- Then **Export/import strings** (a `PROFILE` or single aura is one serializable table now).
- Watch the two Config.lua limits (60 upvalues on `Build` = 56 now; 200 chunk locals = **187 now** after
  moving trigger state to `C._trig` — see LEARNINGS): put new drawer state/functions on the `C` table,
  controls as Build-locals.

### Exact charge COUNT (Jason-requested revisit, after charge-availability build)
The shadow build gives "≥1 available." Getting the EXACT count is PARTLY possible, secret-safely:
- **2-charge spells (Aimed Shot):** the TWO shadows already distinguish all three states — 2=`main F,charge F`;
  1=`main F,charge T`; 0=`main T,charge T`. So exact count (0/1/2) is DERIVABLE for free from what we build.
- **3+ charge spells:** middle counts COLLAPSE (1 and 2 both read `main F, charge T` = "available, recharging"),
  so exact count is NOT derivable — best is full / partial / empty buckets. (`GetSpellCharges().currentCharges`
  and `GetSpellCastCount` are both SECRET in combat — confirmed in probe — so no direct read.)
Revisit: expose a charge-count signal (works fully for 2-charge, degrades to buckets for 3+). Explore
`C_Secrets` predicates only if buckets aren't enough (they return SECRET booleans → need a widget sink).

### Trigger-chooser UX — ✅ DONE + QA'd (2026-07-08). Two-panel picker (Config.lua).
Rewrote the condition picker (`BuildAuraLists` + BuildPicker/RefreshPicker on `C._pick`): **two columns** —
Cooldowns (Essential/Utility) | Buffs & Debuffs (TrackedBuff/Bar) — each independently scrolled, with a
shared **search** box on top (padding: search at y-46, headers at -84, rows at -104). Labels come from
`selfAura`: **(Buff)** = on you, **(Debuff)** = on target; the condition rows + wording follow via
`StateLabel(state, k)` → "buff is active (on you)" / "debuff is active (on target)" / "cooldown is ready".
Picking from a column sets the right default state (`TrigAddLeaf(item, ti)` carries `item.state` + `item.k`);
the state click now toggles within its family (active↔inactive / ready↔on-cd), not all four. **The picker
sources from the LIVE item frames** (not the category set), so it only ever lists spells with a trackable
frame (see Placement note). A **(Proc)** tag was tried via `hasAura=false` but DROPPED — `hasAura` also flags
cooldown-granted buffs (Aspect of the Turtle), so it's not a reliable proc signal. Future proc-detection: a
real proc is **aura-only (no matching cooldown entry)**; a cooldown-buff appears in both columns.

### Other pending / deferred
- **Override display polish (optional, offered, Jason didn't decide):** show a spell's **override** name+
  icon in the picker/list when `info.overrideSpellID ~= spellID` (e.g. "Black Arrow" not "Kill Shot"),
  storing the **base** spellID for stable matching. Cosmetic — tracking already follows overrides.
- **Deferred texture transforms** — Mirror, Rotation, Texture Wrap (SetRotation interacts with SetTexCoord).
- **Visibility Phase 2** — rarer load conditions (Race/Faction/Level, Zone/Instance/difficulty, M+ affix,
  Equipment, Spec Role, PvP talent). Dropped Skyriding (no reliable "am I skyriding now" API).
- ~~Text overlays + LSM font picker~~ ✅ DONE 2026-07-07 (see BUILT list — on-screen Text overlay).
- **Export/import** strings for sharing (later; naturally follows Profiles).

## Current in-game context
- **Jason's MAIN this season is Affliction Warlock** (added 2026-07-08) — char **"Gloomwick - Stormrage"**
  (CORRECTED 2026-07-08 sixth session — the handoff previously said "Gloomvale"; that's actually his HUNTER.
  Confirmed from SavedVariables: the **Gloomwick** profile holds the Warlock DoT auras, the **Gloomvale** profile
  holds the Hunter auras), account `AELWYN`. His CDM **Tracked Bars** hold Haunt (48181), Corruption (146739), Agony (980), Unstable
  Affliction (1259790), Seed of Corruption (27243) + the Curses; **Tracked Buffs** incl. Nightfall (264571);
  Burning Rush (111400, a self-buff that sits in BuffBar → `selfAura=true`). He also runs **ArcUI**, which
  tracks these DoTs correctly — the reference implementation for the §9 approach. The Hunter below is still
  relevant for the charge (Aimed Shot) work. **QA discipline reminder: he wants to be thorough; frame every
  build as a hypothesis to verify in-game, never as done.**
- Jason plays **Marksmanship Hunter** (**Dark Ranger** hero talents) on char **"Gloomvale - Stormrage"** (its
  profile holds the Hunter auras). Relevant IDs: Trick Shots buff
  **257621**, Rapid Fire **257044** (non-charge cd, works), Aimed Shot **19434** (2 charges — availability
  walled), Precise Shots **260240** (buff), **Kill Shot 53351 → override Black Arrow 466930** (Black Arrow
  replaces Kill Shot; a **1-charge** cd — see the charge learning above; his working aura = "Precise Shots
  active AND Kill Shot cd_ready"). His SavedVariables has displays incl. Trick Shots, Rapid Fire, Kill Shot,
  Aimed Shot, plus experiments. He now also has an **"MM Hunter"** group (load rule = spec).
- His Warlock (main) character/profile is **"Gloomwick - Stormrage"**; his Hunter is **"Gloomvale - Stormrage"**
  (account folder `AELWYN`; both profiles exist and are correctly populated). After Phase-3 QA he may have
  leftover test profiles (e.g. "Copy Test") — harmless; deletable from the Profiles drawer.
- **Session end 2026-07-09 (sixth session) — verification + a picker regression fix.** (1) **Instance check
  banked** — follower dungeon on Gloomwick (Warlock); DoT tracking works, but the follower dungeon behaved
  identically to open-world combat (auras readable, cooldowns secret-in-combat as always), so it did NOT
  exercise the feared "auras go secret in group content" path; Jason called it sufficient (rules don't vary by
  content tier). (2) **Grouped triggers verified in combat** — `(RF ready OR Aimed ready) AND Precise active`
  on the Hunter, all states correct → closes the ⚠ item. (3) **Fixed a trigger-picker regression** (Config.lua
  `BuildAuraLists`): the fifth session's "source from live frames" approach silently dropped ready-OOC Essential
  cooldowns (Rapid Fire) because hidden frames clear their cooldownID; an interim "raw category set + HideByDefault
  filter" fix then dropped 18 known Tracked Buffs (Lock and Load, Trueshot…). Final correct source = the settings
  **data provider** `GetOrderedCooldownIDsForCategory` (see the picker LEARNING above). Both columns QA'd correct.
  (4) **Deathblow / proc verified** — a `hasAura=false` activation proc DOES light up through the normal buff
  mirror; no separate activation path needed (QA STATUS #4). (5) **Doc fix:** the Warlock is **Gloomwick**, the
  Hunter is **Gloomvale** (handoff had them swapped). Only Track-A item left = exact charge COUNT (a backlog
  build, not a correctness gap). No open bugs. Config.lua chunk 184/200 locals.
- **Session end 2026-07-08 (fifth session) — the "secret-safe signals" session. BIG.** Reverse-engineered
  **ArcUI** (installed, readable) and cracked two things we'd previously called walls. Built a read-only
  probe (`/ga probe` + a movable `/ga capture` button, logging to `probeLog` → Claude reads it off disk) and
  used it to VERIFY, then SHIP:
  1. **DoT / target-debuff tracking** (`bc6cdb0`) — Haunt & co. now follow the current target. Root cause: a
     spell in TWO viewers (Haunt = Essential cooldown + BuffBar aura) had both frames writing one `buffActive`
     var and fighting. Fix = route state by a per-FRAME role (`CDM.frameKind`). Fixed the flicker AND the
     target-swap for free. QA'd Warlock (single/swap/multi-target) + Hunter (no regression).
  2. **Aimed Shot charge availability** (`74a6ae0`) — the charge WALL is RETIRED. Can't read the count
     (secret), but a hidden shadow `Cooldown` fed the GCD-stripped duration OBJECT (which does NOT throw in
     combat) exposes `IsShown()` = a plain bool: `mainShown==false` ⇔ ≥1 charge castable. Verified on Aimed
     Shot 2→1→0→1→2. Flows into existing `cd_ready`. (§9.3.)
  3. **Two-panel trigger picker** (`e98d706`) — Cooldowns | Buffs & Debuffs, search, `selfAura`-based
     (Buff)/(Debuff) labels + unit-aware wording, sourced from LIVE frames so it only lists trackable spells.
  Also **corrected the core premise**: "GloomsAuras never reads aura data" was too strict — the real rule is
  "no arithmetic/compare on a secret." Reading aura PRESENCE (`auraInstanceID` existence) + DURATION (duration
  objects), unit from `selfAura`, is sanctioned + verified (API-NOTES §9, CLAUDE.md nuance note). **Do NOT
  re-apologize for it.** OPEN: instance/raid verification, Deathblow/proc tracking, exact charge count (see
  START HERE). All committed + pushed. No open bugs.
- **Session end 2026-07-07 (third session):** shipped **Groups Phase 1** (group data + `CDM:GroupGate`
  engine, skinned name dialog) AND **Phase 2** (grouped/collapsible left pane with custom triangle +
  settings-gear icons, gear→Manage Group drawer for rename/rule/on-off/reorder/delete, group settings
  moved out of the aura editor) PLUS a **per-aura eye toggle** (`hidden/unhidden.png`). Hit + fixed the
  **Lua 5.1 60-upvalue limit** on `Build()` (extracted sub-functions). THEN added **aura rename**
  (click-to-edit title + list truncation) and the full **on-screen Text overlay** (Text drawer + font
  picker; dropped shadow — `SetShadow*` renders nothing here). All QA'd, no open bugs. `Build()` at ~57
  upvalues (watch the 60 cap). **Next: Phase 3 — Profiles.**
- **Session end 2026-07-08 (fourth session):** shipped **Profiles (Phase 3)** end to end — schema 1→2
  migration + `GA.global`/`GA.db` split (`fc41649`), then the switcher UI: bottom-strip "Profile: ‹name›"
  button → docked **Profiles drawer** (switch/new/copy/rename/delete, skinned confirm) with the full Core
  profile API (`6deae65`). Also recolored slider thumbs purple→**orange `#FF7729`** and fixed the drawer
  footer overlapping its buttons. Hit a NEW wall — the **200-locals-per-chunk** cap in `Config.lua` (chunk
  is at 198/200); worked around by hanging all profile state on the `C` table (see LEARNINGS). All QA'd
  (create/switch/delete+fallback/copy-independence), committed. THEN reworked **aura creation**: dropped
  the "pick a spell first" entry point for **appearance-first** creation — `+ Add Aura` makes a blank
  aura, spells enter via the Trigger only, and a **no-trigger aura is a decoration that's always shown**
  (Visibility-gated). All QA'd. THEN the **effects push**: fixed the **list-row mini-icon** (preview the
  aura's texture, not the tracked-spell icon), shipped **Glow** (LibCustomGlow embedded, `fa12820`), then
  **one-level grouped trigger logic** AND/OR/NONE (`1294c8f`), then re-scoped the **eye → editor preview**
  + a **Disabled/Enabled toggle** for auras & groups (`3e5d34a`) — fixing an ugly `v and nil or false`
  Lua trap along the way (see LEARNINGS) that had stranded auras disabled. Chunk 187/200 locals, `Build`
  56 upvalues. **No open bugs.** **Pushed to origin/main at session end.**
  **▶ Next: (1) QA a GROUPED trigger in combat — only flat triggers were verified. (2) Motion. (3) Frame
  & Shaping.**
- **Session end 2026-07-07 (second session):** shipped the **Hide-Blizzard-CDM toggle**, **aspect-ratio
  lock** (custom lock PNGs), **custom flat sliders**, **Duplicate Aura** (multi-per-spell via display-id
  re-key), **drag-selected-only**, **font preload** (first-login blank-label fix), a **UI-cleanup batch**
  (borderless inputs, lighter button font, Blend/Strata **dropdowns**, inline Choose, Spell-ID icon search,
  Title Case), the **docked side-panel drawer** for the editors, and fixed the **Black Arrow / 1-charge
  cooldown** tracking bug. All QA'd, committed, pushed. **No open bugs.** Next: Groups + Profiles Phase 1.

## Git / packaging
Now a **git repo** (initialized 2026-07-07). Mirrors GloomsBuildBarn's setup:
- `.gitignore` excludes `.DS_Store`, `/.release/`, `Libs/` (see below), `.claude/settings.local.json`.
- `.pkgmeta` (BigWigs packager) `package-as: GloomsAuras`; **`Libs/` is NOT committed** — the packager
  fetches LibStub/CallbackHandler/LibDataBroker/LibDBIcon/LibSharedMedia into `Libs/` at release time.
  Jason's live working copy keeps its `Libs/` (gitignore doesn't delete), so nothing breaks locally.
- **Committed** bundled art: `Media/` (fonts, `bg_flame.png`, `minimap.png`, `Textures/`,
  `TextureManifest.lua`) + `PowerAurasMedia/Auras/`. These are ours, not packager-fetched.
- **Push status:** LIVE on GitHub — https://github.com/HandofDevastation/GloomsAuras (created + pushed
  at the end of the 2026-07-07 session, after the handoff was first written). `origin` is
  `https://github.com/HandofDevastation/GloomsAuras.git`, tracking `main`. NOTE before making it public/
  wide: the repo bundles WeakAuras/PowerAuras textures (GPL-family) — fine for guild use, worth a
  license glance if published widely.
