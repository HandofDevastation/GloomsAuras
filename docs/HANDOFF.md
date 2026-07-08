# GloomsAuras — Session Handoff  (last updated 2026-07-07)

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

## Files
- `GloomsAuras.toc` — Interface 120007; load order: `Libs\*` → Core → Displays → CDM →
  `Media\TextureManifest.lua` → Config.
- `Core.lua` — namespace `GA` (`_G.GloomsAuras`), SavedVariables `GloomsAurasDB`, `/ga` router,
  **design tokens** `GA.COLOR / GA.FONT / GA.MEDIA` (matched to Build Barn).
- `Displays.lua` — `GA.Displays`: on-screen frames (texture/size/pos/alpha + tint/desaturate/blend/
  strata), drag-to-move while panel open (NOT clamped — auras may go off-screen), Cooldown swipe (OOC).
- `CDM.lua` — `GA.CDM`: the mirror engine — state tracking, trigger evaluation, discovery, hooks.
- `Config.lua` — `GA.Config`: the whole GUI toolkit (`flatButton/flatCheck/flatEditBox/MakeSlider/
  MakeColor/MakeCycle/skinPlate/addEdges`) + two-pane panel + aura picker + **texture picker** +
  trigger editor.
- `Media/TextureManifest.lua` — auto-generated `GA.TextureShapes` (254 aura shapes). Regenerate via
  `scratchpad/gen_manifest.py` if the bundled art changes.
- `Media/` — bundled Khand/GeneralSans fonts, `bg_flame.png`, `minimap.png`, Jason's custom UI icons
  (`lock_locked/unlocked.png`, `triangle.png` = collapse caret, `settings.png` = group gear,
  `hidden/unhidden.png` = per-aura eye), `Textures/` (107 shape files) + `PowerAurasMedia/Auras/`
  (145 curls) — copied from ThisWeeksAuras.
- `MinimapButton.lua` — `GA:InitMinimapButton` / `GA:ToggleMinimapButton` (LibDBIcon launcher).
- `Libs/` — embedded LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0,
  LibSharedMedia-3.0 (source: TWA's copies).

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

## Hard-won LEARNINGS (verified — do NOT rediscover)
- **`FontString:SetShadowColor` / `SetShadowOffset` render NOTHING in this client** — a drop shadow via
  the shadow API is invisible at any offset. We dropped the shadow option (outline flags are the text
  styling). If a shadow is ever truly needed, draw it manually (a black text copy offset behind), but
  even a behind-sublevel copy layered awkwardly — not worth it; outline suffices.
- **Lua 5.1 caps a function at 60 UPVALUES (`local`s captured from enclosing scope).** `Config.lua`'s
  giant `Build()` hit exactly 60 after Phase 1; one more (a `DEFAULT_FONT` ref) → `function ... has
  more than 60 upvalues` at LOAD time and the panel wouldn't open. **The local `luac` is 5.5 (limit
  255) so it does NOT catch this** — after adding module-level helpers that `Build` references, count
  by hand (a function's upvalues = every module-scope `local` it or its nested closures reference).
  Fix pattern: extract chunks of `Build` into their own module-level functions (`BuildGroupSection`,
- **Lua 5.1 caps a function at 60 UPVALUES (`local`s captured from enclosing scope).** `Config.lua`'s
  giant `Build()` hit exactly 60 after Phase 1; one more (a `DEFAULT_FONT` ref) → `function ... has
  more than 60 upvalues` at LOAD time and the panel wouldn't open. **The local `luac` is 5.5 (limit
  255) so it does NOT catch this** — after adding module-level helpers that `Build` references, count
  by hand (a function's upvalues = every module-scope `local` it or its nested closures reference).
  Fix pattern: extract chunks of `Build` into their own module-level functions (`BuildGroupSection`,
  `BuildGroupManager`) so each gets its own 60 budget. Build sits ~55 now; keep it there.
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
    So "do I have a charge" is unknowable in combat. Aimed Shot etc. can't do "available."
  - Only partial charge signal: `C_SpellActivationOverlay` detects **procs** — but procs that
    grant a buff (e.g. Lock and Load) are already trackable as a **buff-active** condition, so
    that path is redundant.
- **Placement requirement**: a spell must be placed on a CDM viewer (Edit Mode → Cooldown
  Manager), not merely in the registry, to be tracked. `/ga charges` reports charge status;
  `/ga debug` shows FOUND/NOT FOUND + state.

## Diagnostics / commands
- `/ga` — open the options panel. `/ga help` — list commands.
- `/ga debug` — CDM state dump (availability/kind/charge/IsSpellUsable per display). Ask Jason
  to paste this (or BugSack) when diagnosing.
- `/ga minimap` — show/hide the minimap button (persisted).
- `/ga hidecdm` — hide/show Blizzard's Cooldown Manager (alpha-0, tracking stays live; persisted).
- `/ga charges` — which cooldowns support availability tracking (charge spells flagged). Run OOC.
- `/ga trace` — per-display trigger diagnostic (shown?, buffActive/available mirror, item cooldown
  fields, each condition's eval). Run IN the failing state; makes trigger bugs a 30-sec find.
- `/ga add|remove|list|pos|size|preview|test` — legacy/back-door commands (panel is primary).

## SavedVariables data model  `GloomsAurasDB.displays[<displayID>]`
> **Keying (changed 2026-07-07 for Duplicate):** the table key is now an opaque **display id**, NOT
> the spellID. Originals keep a numeric **spellID** key (so existing data is untouched); **duplicates**
> get a unique `"dN"` **string** key (counter `GloomsAurasDB.seq`). The tracked spell is ALWAYS
> `cfg.spellID`. Rule of thumb: `GA.Displays.frames[]`, `CDM.lastShown[]`, `lastPlay[]`, `selectedID`,
> and every `db.displays` iteration key = **display id**; `CDM.kind/available/buffActive/isCharge[]`,
> `frameToSpell` values, and all `C_Spell.*` calls = **cfg.spellID**. `DisplayList()` sorts by
> `cfg.spellID` then key (never compares number vs string → no error; existing order unchanged).
```
{ spellID, label, enabled=true, width=64, height=64, point={"CENTER",x,y}, alpha=1,
  lockAspect = bool/nil,  aspect = <w/h ratio captured at lock time> or nil,
  showLabel=true, texture = <path/fileID or nil=spell icon>,
  color = {r,g,b} or nil,  desaturate = bool/nil,  blend = <mode or nil=BLEND>,
  strata = <mode or nil=HIGH>,  sound = { file, name, channel } or nil,
  trigger = { logic="AND"|"OR", conditions = { { spellID, state, name }, ... } },
  visibility = { combat="in"|"out"|nil, target="has"|"none"|nil, casting/mounted/vehicle/
    instance/encounter/resting/stealthed/group/raid/warmode/alive = true/nil,
    specs = { [specID]=true } or nil, spellKnown = spellID or nil },
  group = <groupID> or nil,   -- which group this aura belongs to (nil = Ungrouped)
  text = { show=bool, str="custom text"|nil(=aura name), font=path|nil, size=N|nil,
    outline="NONE"|"OUTLINE"|"THICKOUTLINE"|nil, anchor="BOTTOM"|"TOP"|"CENTER"|"LEFT"|"RIGHT"|nil,
    x=N|nil, y=N|nil, color={r,g,b}|nil } }   -- on-screen label; nil ⇒ legacy showLabel+name
```
`GloomsAurasDB.groups[<groupID>] = { id, name, order, enabled (false=off), collapsed (bool),
visibility = <same shape as an aura's visibility> or nil }` and `GloomsAurasDB.groupSeq` (the "gN"
id counter) + `GloomsAurasDB.ungroupedCollapsed` (bool). A grouped aura shows only when its **group
is on AND the group's load rule passes** — ANDed in front of the aura's own Visibility + Trigger.
(Phase 3 moves `groups`/`groupSeq` into the profile; `ungroupedCollapsed` is UI state.)
`GloomsAurasDB.hideBlizzardCDM = true/nil` (global; hides the four Blizzard CDM viewers via alpha-0).
`GloomsAurasDB.minimap = { hide, minimapPos }` (LibDBIcon). Display shows when its **Trigger**
passes AND its **Visibility** gate passes (no visibility set ⇒ always eligible).
`state` ∈ `buff_active | buff_inactive | cd_ready | cd_oncd`. No trigger ⇒ auto-behavior
(display's own spell: buff→active, cooldown→available). Width/Height range 8–8192, offset slider ±2000
(drag/`/ga pos` un-clamped).
`GloomsAurasDB.panelPos` stores the panel location; `db.schema`, `db.media` reserved.

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

### ▶▶ START HERE NEXT SESSION: Groups + Profiles — Phase 3 (Phases 1 & 2 DONE)
**Read [docs/GROUPS-PROFILES-DESIGN.md](GROUPS-PROFILES-DESIGN.md) first — it is the spec.**
Jason approved every recommendation, so all design decisions are RESOLVED (see §6 there).
- **Phase 1 — Groups data + engine.** ✅ **DONE + QA'd 2026-07-07** (see BUILT list). Committed.
- **Phase 2 — Grouped left pane + Manage drawer.** ✅ **DONE + QA'd 2026-07-07** (see BUILT list).
  Grouped/collapsible left pane, gear→Manage drawer (rename/rule/on-off/reorder/delete), group
  settings out of the editor, per-aura eye toggle. Committed as the Phase-2 restore point.
- **Phase 3 — Profiles** (START HERE) (schema-2 migration — **must move `groups`+`groupSeq` into the profile**,
  see design §3; `GA.global`/`GA.db`=active-profile split, switcher UI: switch/new/copy/rename/delete;
  per-character default `"Name - Realm"`). Key trick: `GA.db` repoints to the active profile so most
  existing `GA.db.displays` code is untouched; only `panelPos`+`minimap` move to `GA.global`.
  `hideBlizzardCDM` stays in the profile.

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
- Jason plays **Marksmanship Hunter** (**Dark Ranger** hero talents). Relevant IDs: Trick Shots buff
  **257621**, Rapid Fire **257044** (non-charge cd, works), Aimed Shot **19434** (2 charges — availability
  walled), Precise Shots **260240** (buff), **Kill Shot 53351 → override Black Arrow 466930** (Black Arrow
  replaces Kill Shot; a **1-charge** cd — see the charge learning above; his working aura = "Precise Shots
  active AND Kill Shot cd_ready"). His SavedVariables has displays incl. Trick Shots, Rapid Fire, Kill Shot,
  Aimed Shot, plus experiments. He now also has a **"Marksmanship"** group (load rule = spec) with
  Rapid Fire assigned, from Phase 1 QA.
- **Session end 2026-07-07 (third session):** shipped **Groups Phase 1** (group data + `CDM:GroupGate`
  engine, skinned name dialog) AND **Phase 2** (grouped/collapsible left pane with custom triangle +
  settings-gear icons, gear→Manage Group drawer for rename/rule/on-off/reorder/delete, group settings
  moved out of the aura editor) PLUS a **per-aura eye toggle** (`hidden/unhidden.png`). Hit + fixed the
  **Lua 5.1 60-upvalue limit** on `Build()` (extracted sub-functions). THEN added **aura rename**
  (click-to-edit title + list truncation) and the full **on-screen Text overlay** (Text drawer + font
  picker; dropped shadow — `SetShadow*` renders nothing here). All QA'd, no open bugs. `Build()` at ~57
  upvalues (watch the 60 cap). **Next: Phase 3 — Profiles.**
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
