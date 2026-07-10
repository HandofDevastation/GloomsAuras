# UI Redesign — design decisions (2026-07-09, session 8)

**NEXT SESSION'S JOB: build the redesigned options panel PIXEL-PERFECT to Jason's Figma mocks.**
This doc is the decisions locked in a long design conversation so the build starts cold. Read it, then
pull the current Figma selection (the Figma MCP is now wired — see §Figma access) and build to the pixels.

> **Why a redesign:** the panel got bloated ([[avoid-ui-bloat]]). Jason mocked a cleaner IA in Figma.
> **Prototype is DEAD:** an HTML prototype was built this session (artifact `325ae79c`) and REJECTED by
> Jason as a "component dump" — the Aura-Type selector was duplicative and it showed no real workflow.
> Do NOT resurrect it. Build the real addon UI to the Figma, thinking in USE-CASES not control-dumps.

---

## The new information architecture
1. **Landing page ("Default State")** — on open with nothing selected: a big GA logo in the right pane, and
   in the left a set of **creation choices**: **Add Icon Aura**, **Add Texture Aura**, **Add Bar Aura**, plus
   **View All Auras** (de-emphasized, lower). Footer (shared everywhere): **Hide Blizzard's Cooldown Manager**
   CHECKBOX (Jason confirmed a checkbox here, NOT a switch) + **Profile: ‹name›** button.
2. **Pick a type / View All → the editor.** Two-pane: LEFT = grouped aura list (as today) + button stack;
   RIGHT = the selected aura's editor.
3. **The editor is a one-open-at-a-time ACCORDION** of collapsible sections (expanding one auto-collapses the
   others). Orange caret ▶/▼ per header; Khand uppercase header labels.

### Left pane (editor)
Grouped/collapsible list (group headers with caret + kebab ⋮ gear, auras nested, eye toggle) — the machinery
already exists. Button stack at the bottom: **New Aura** (→ returns to the LANDING to pick a type),
**Duplicate Aura**, **Delete Aura**, **Group: ‹name›**. (New + Duplicate were added back per Jason 2026-07-09.)

### The type is chosen on the LANDING — the editor must NOT re-ask it
The prototype's mistake: an Icon/Texture/Bar switch inside Appearance. Redundant. Once you pick "Bar Aura,"
you're editing a bar. Show the type as a fixed label/identity, not a re-picker. (Changing type later = a rare
"convert" action, not a primary control.)

### The editor is TYPE-SPECIFIC — not one accordion reused three ways
Each type has a different **first question** → different sections, order, and default-open section:
- **Icon aura** — "show a spell's icon WHEN something is true." Defining decision = the **Trigger**. Icon
  usually auto-adopts the spell art. → default-open **Aura Trigger(s)**. Sections: Aura Trigger(s) · Appearance,
  Position & Size · Text · Effects & Motion · Sounds · Aura Load Conditions.
- **Texture aura** — often a **decoration** ("pink cat in the corner"): pick a graphic + place it, frequently
  NO trigger. → default-open **Appearance**; don't shove Triggers in the user's face.
- **Bar aura** — "track the duration/stacks of a spell." Defining decision = **what it measures** (source +
  mode). **A bar does NOT use the multi-condition Trigger builder** (see §Bars). Its sections:
  **Bar Type & Source** (Track) · **Appearance, Position & Size** · **Text** · **Effects & Motion** · **Sounds**
  · **Aura Load Conditions**. NO "Aura Trigger(s)" section.

---

## BARS — the crux (most important; Jason has NEW Figma mocks for this)
Jason's mocks in progress: **"aura bar (appearance, position & size)"** + **"bar aura type & source."** Build to them.

### There are exactly TWO bar types (Jason confirmed): **Duration** and **Stacks**
"Cooldown" is NOT a third type — it's a Duration bar reading a different clock. The two kinds:
- **Duration bar** — driven by a *duration object* (a clock). Two required settings:
  - **Track:** this spell's **aura** (DoT/buff time-left) **OR** its **cooldown**. Required — some spells have
    BOTH (Haunt = debuff + cooldown), so the addon can't always guess which clock you mean.
  - **Direction:** **Drain** (full→empty) or **Fill** (empty→full — "counting up to ready," great for cooldowns).
- **Stacks bar** — driven by a *count* (aura `applications`). Settings: **Max** (e.g. Freezing = 20) + **Unit**
  (Auto / Player / Target).

### Unit auto-detection (buff-on-self vs debuff-on-target) — AUTOMATIC
Shared resolver `CDM:ResolveAuraUnit` (used by BOTH duration + stacks). It reads the spell's `selfAura` flag as
a HINT, then VERIFIES where the aura instance actually is — if the flag says "you" but the aura's on the target
(and the instance exists), it flips to target. Catches liars like **Freezing** (selfAura=true, actually on
target — PROVEN). So: **default Unit = Auto** (collapsed/advanced); the **Player/Target override** is the escape
hatch for oddballs. Proven: target-DoTs (Agony) + the Freezing liar. A plain self-buff *duration* uses the same
code but wasn't explicitly QA'd — verify when building.

### A bar does NOT need multiple triggers — its SOURCE is its trigger
A bar tracks ONE thing and shows when that thing is active, by definition — so the Match ALL/ANY/NONE
multi-condition builder is an **Icon/Texture** concept, NOT a bar concept. The bar editor has **no "Aura
Trigger(s)" accordion**; its equivalent is the single **Source** picker inside "Bar Type & Source." (Engine can
still layer an exotic extra gate on a bar, but that's a rare advanced case — do NOT lead the design with it.)
Gating "whether it's allowed on screen at all" (in combat / has target / spec / group) = **Aura Load Conditions**
(same section icons use).

### Picker CANNOT pre-filter "no-duration" auras (e.g. Burning Rush toggle)
Asked + answered: the addon can't reliably know at pick-time that a spell has no timed duration — the aura
usually isn't active when browsing, the duration is secret in combat, and there's no static "is-a-toggle" flag.
So the Duration picker just lists trackable auras. A bad pick (a toggle) → the bar shows on presence but **sits
full and never drains** (harmless, not a crash). Optional nicety: a soft "no timed duration" note the one time
we CAN tell (aura active + out of combat + duration reads 0). **Design the picker as "lists trackable auras,"
NOT "only valid durations shown."**

### Bar feature status — the UI must only PROMISE what actually works
| Capability | Status |
|---|---|
| Duration bar (drain), Stacks bar (fill+count number), Cooldown-as-Duration | ✅ BUILT + QA'd |
| **Fill vs Drain** direction (any timer bar) | ✅ BUILT (`cfg.bar.fill`; Enum.StatusBarTimerDirection) |
| **Track: aura vs cooldown** source | ✅ BUILT (aura_dur vs cd_dur modes) |
| Unit Auto-detect + Player/Target override | ✅ BUILT (`CDM:ResolveAuraUnit`; Freezing proven) |
| Max, LSM bar texture, fill color, orientation, reverse, length/thickness, alpha, X/Y | ✅ BUILT (engine) |
| Stacks **count number** on the bar | ✅ BUILT (`SetText` of the secret count) |
| Duration **countdown NUMBER** ("4.2s", 1 decimal, stylable) | ⏳ FEASIBLE, NOT BUILT — hidden Cooldown widget w/ `SetHideCountdownNumbers(false)`; styled via the cooldown's OWN font APIs (`SetCountdownFont`/`SetCountdownFormatter`) — more limited than our FontString text, exact 1-decimal format needs verifying. BUILD + QA before promising it in the UI. |
| Background/track colour control, **spark**, **segments** (stacks), **border** | ⏳ Buildable, not wired |
| Stacks **colour-by-fullness** (in combat) | ⚠️ NEEDS A PROBE — the count is secret; the proven value→colour "curve" trick only exists for DURATION objects, not raw counts. Unverified whether it can be bent to a stack value. May be walled in combat. |
| **Sound at a specific stack level** / "stacks ≥ X" trigger | ❌ WALLED — comparing the secret count throws in combat; no secret-safe "value crossed threshold" signal. Do NOT put this in the UI. |

**Verify-first before the UI leans on them:** (1) build the duration **countdown number**; (2) **probe** stacks
colour-by-fullness. Only surface these in the design once confirmed.

---

## Other locked UI decisions (from the four earlier Figma frames)
- **Charge count = a "Show Current Charge Count (if applicable)" SWITCH**, NOT an inline `[charges]` text token.
  Reason (secret-safety): the count is secret in combat; a MIXED string like `"Haunt [charges]"` needs concat on
  the secret → throws. A standalone count via `SetText(secret)` is fine. (Matches the shipped `cfg.text.showCount`.)
- **Trigger accordion (Icon):** Match ALL/ANY/NONE segmented control at top; condition rows `Spell [icon] = STATE`
  with an X; a nested **TRIGGER GROUP** box with its OWN Match ALL/ANY/NONE (one level of nesting — matches our
  `trigger={logic,conditions={leaf|group}}` model); "Add a Trigger" / "Add to Trigger Group"; hint "Shift-click
  multiple spell names to add to group" (Jason's multi-select-to-group, chosen over drag-and-drop).
- **Appearance (Icon):** "Leave blank to adopt the first trigger's icon" (auto-icon backlog item, baked in) +
  Choose; Recolor(check+swatch) + Desaturate; Blend/Strata dropdowns; Alpha; Width/Height (aspect-linked, chain
  icon); X/Y — all reuse shipped controls.
- **Text:** content field; Show Text + Show Charge Count switches; Font/Text Color; Size; Outline/Anchor; X/Y.
- Section headers uppercase **Khand**; body **General Sans**; carets/checks **orange (#ff7729)**; accents purple
  (#936bff); primary buttons purple; Delete = dark red; Group button = dark green. (Fonts bundled in `Media/fonts/`.)

## Figma access (now working — set up this session)
- The **figma-desktop MCP server** is registered at USER scope + the GloomsAuras project in `~/.claude.json`
  (`{"type":"http","url":"http://127.0.0.1:3845/mcp"}`). It only loads at SESSION START, so a fresh session picks
  it up automatically (Figma Desktop must be running with Dev Mode MCP on). Tools: `get_screenshot`,
  `get_metadata`, `get_design_context`, `get_variable_defs` (pass a nodeId or use the current selection).
- **Workflow:** ask Jason to select the frame(s); `get_metadata` handles multiple (lists node IDs), but
  `get_screenshot`/`get_design_context` need ONE node id at a time — pull each frame by id.
- Four frames from session 8 (icon path, for reference): Default State `395:98`, Aura Trigger OPEN `397:631`,
  New Icon–Appearance Open `399:636`, Icon Aura TEXT OPEN `404:793`. **The NEW bar mocks have their own ids —
  get Jason's current selection next session.**
- For pixel fidelity in any HTML/reference, the real fonts are `Media/fonts/Khand-*.ttf` + `GeneralSans-*.ttf`.

## Build reality — the panel `Build()` refactor
- Today's `Config.lua` panel is **fixed absolute-positioned** two-pane. The redesign needs a **landing state** +
  a **reflowing accordion** (sections change height as they open/close) + **type-specific** section sets. This is
  a real refactor of `Build()`.
- **Lua caps (WATCH):** `Config.lua` chunk **184/200 locals**; `Build` **~56/60 upvalues**. The accordion actually
  RELIEVES pressure IF each section is its own module-level function or a `C:` method (field, not a chunk local) —
  do that. Do NOT pile new sections onto `Build` as inline locals. Reuse existing helpers (flatButton, MakeSlider,
  makeSwitch, MakeDropdown, MakeColor, skinPlate, the pickers, and the `C:` editors) as upvalues.
- Suggested approach: build the new panel behind a flag / new entry first if helpful, but Jason wants it pixel-
  perfect to Figma — align each section's geometry to the mock. Keep all shipped engine/features intact; this is a
  presentation-layer rebuild, not an engine change.

---

# ▶▶ BUILD STATUS & ARCHITECTURE — session 9 (2026-07-09 → 07-10). READ THIS to resume.

The redesign is being built slice-by-slice, **pixel-perfect to Figma, QA'd in-game each slice**.
Everything below is DONE + in `Config.lua`/`Core.lua` unless marked. **The figma-desktop MCP loads at
session start** — pull the exact `get_design_context` per node before building any control. Mock node IDs:
Landing `411:452` · Icon Trigger `411:453` · Icon Appearance `411:454` · Icon Text `404:792` (or `411:455`) ·
Bar Type&Source `411:182` · Bar Appearance `411:448`. There is **no Texture-aura mock** (infer from Icon).

## The redesign CONTROL LANGUAGE (match this for every new control)
- **Pills / steppers / dropdowns / buttons:** heroic `#8031ff` @ **0.5** fill (`flatButton(..,COLOR.heroic..); :SetBase(0.5)`).
- **Input fields / slider value-boxes:** heroic @ **0.08** fill.  **Slider track:** heroic @ **0.2**, 166×6.  **Slider thumb:** PURPLE `#936bff`, 4×20.
- **Check boxes:** white @ 0.1 box, no border, **orange ✓** = `Media/checkmark_white.png` tinted `COLOR.orange` (flatCheck does this).
- **Section headers:** Khand Medium 16 **purple** `#936bff` + **orange caret** = `Media/triangle.png` untinted (already orange), rotated (`CARET_DOWN` = -pi/2 = expanded).
- **Two-weight labels** (Regular prefix + Semibold value, e.g. "Profile: Name", "Blend Mode: Normal"): `twoWeightLabel(parent,size,cc,swap)` — `swap=true` puts the Semibold part first (trigger state pills).
- **On/off toggle** (sliding purple knob on white-10% track): `makeToggle(parent,get,set)`.
- **Nested trigger group accent = ORANGE** (group box `orange@0.1`, group Match pills orange, "TRIGGER GROUP N" orange) vs the purple top level.
- Left-pane buttons: New/Duplicate = heroic@0.5; **Delete = red `#C41E3A`@0.3** (`COLOR.red`, added to Core.lua); **Group = green `#20ba56`@0.3**.

## GAMMA (do not relitigate) — WoW `SetColorTexture` renders ~11/255 DARKER per channel on Jason's display
Figma navy `#060714` was fed to the panel base as **`#12131F`** (`COLOR.dark` in Core.lua) so it renders as `#060714`.
If a dark fill looks too dark, add ~11 per channel. Accent colors (mid-tone) were left as raw hex (Jason approved).

## Panel geometry (Config.lua ~1887)
`PANEL_W=620, PANEL_H=740, PAD_L=30, LIST_W=160, DIVIDER_X=220, EDITOR_X=240, EDITOR_W=360, PANE_H=614, FOOTER_H=86, LIST_ROWS=15, CONTENT_TOP=-40`.

## Lua caps (WATCH — verify with `luac -l -l Config.lua`)
Chunk **194/200 locals**; `Build` dropped to **~35/60 upvalues** (the whole editor moved into `C:` methods). RULE: every new
section/helper is a **`C:` method or a module-level `local function`**, NEVER an inline `Build` local. New module locals cost chunk slots (194→cap 200) — hang state/functions on the `C` table when possible.

## Architecture (all in Config.lua)
- **State machine:** `C:ShowLanding()` / `C:ShowEditor()` / `C:CreateAura(uiType)` / `C:BuildLanding(p)`. `C._landing` = a transparent, mouse-transparent overlay filling the panel (footer + X stay clickable). OnShow → ShowLanding. Landing "Add Icon/Texture/Bar Aura" → `CreateAura`; "View All" → ShowEditor. Left-pane "New Aura" → ShowLanding. `cfg.uiType = "icon"|"texture"|"bar"` marks which editor to show (bar = `kind="bar"`).
- **Accordion:** `C._acc = {editor, sections, top=-54}`. `C:AccordionAddSection(key,title,height,builder)` / `AccordionToggle` (one-open-at-a-time) / `AccordionOpen` / `AccordionLayout` (reflow) / `AccordionSetHeight(key,h)` (dynamic-height sections). `C:BuildEditor(editor)` builds the NAME field (Khand 20, heroic-8% bg, orange "CLICK TO RENAME" via `C:UpdateNameHint`) then adds the sections, default-opens **"trigger"**.
- **Reworked shared helpers:** `MakeSlider` (redesign `[label][−][track][+][value]`, purple thumb, `%` suffix if label has `%`), `MakeDropdown` (28px heroic-50% pill + two-weight label + menu), `MakeColor` (29×20 swatch, no border), `flatCheck` (20px + orange ✓), `makeToggle` (new), `twoWeightLabel` (new). **These are shared** — the un-inlined drawers (Visibility/Sound) still use them, so restyling propagated.
- **Left pane:** `C:BuildLeftButtons(listFrame)` (New/Duplicate/Delete/Group, above the footer divider) + `C:RefreshGroupButton` + `C:OpenGroupAssignMenu`. NOTE the list still shows a **"YOUR AURAS" header** (mock has none — deferred).

## Sections DONE + QA'd
- **Landing (slice 1)** ✅ QA'd. Logo `Media/ga_logo_full.png` (monogram+wordmark, Jason's), 3 create buttons, View All, footer (Hide-CDM checkbox + Profile two-weight button), dividers, small X (kept per Jason).
- **Appearance, Position & Size (slice 2)** ✅ QA'd — `C:BuildAppearanceSection(ct)`: texture field (placeholder "Leave blank to adopt the first trigger's icon") + Choose pill; Recolor(check+swatch)+Desaturate; Blend Mode/Strata pills; Alpha/Width/Height (aspect-linked, **padlock at x≈48 between W/H — mock wants a CHAIN-LINK icon; need a `link` PNG from Jason**)/X/Y sliders.
- **Aura Trigger(s) (slice 3a)** ✅ QA'd (no errors). `C:BuildTriggerSection` + `MakeTrigRow`/`FillTrigRow`/`MakeTrigGroupBox`/`FillTrigGroupBox`/`TrigInlineRender`/`TrigAddToGroup`/`TrigAddToExistingGroup`. Match ALL/ANY/NONE segmented (top logic); bordered box (heroic@0.05 + purple@0.2 border) of right-aligned condition rows `[name][icon]=[STATE pill][X]` (pill cycles state, X removes); nested **orange TRIGGER GROUP** boxes (own Match + rows + **"+ Add to Group"** + group X); **shift-click** top-level rows to select → "Add to Trigger Group" (new group) or a group's "+ Add to Group" (move into existing / pick fresh). **Reuses the trigger engine** (`C:TrigTree/TrigAddLeaf/TrigRemove/TrigCycleState/TrigAddGroup`). Reads are **non-seeding** (viewing never creates `cfg.trigger`). State-pill wording = `TrigPill(state,k)`. The box + accordion reflow via `AccordionSetHeight`.
- **Text (slice 3b)** ✅ QA'd. `C:BuildTextSection(ct)`: content field (heroic-8%, 13px, placeholder=aura name); **Show Text + Show Charge Count** toggles (`makeToggle`); Font pill (opens `OpenFontPicker`); Text Color; **Size 6–300** (raised from 48 per Jason); Outline/Anchor dropdowns; X/Y. Non-seeding reads (`txt()`/`ensure()`). NOTE: mock's toggle row shows ONE toggle between two labels → built TWO toggles; **shortened "Show Current Charge Count (if applicable)" → "Show Charge Count"** to fit the row (confirm with Jason). "Show Text Above" label kept from mock (a bit ambiguous vs Anchor — flag).
- **Effects & Motion (slice 3c)** ⏳ built, PENDING QA. `C:BuildEffectsSection(ct)` — **Glow only** (Type dropdown + Custom Color, reuses cfg.glow engine). **Motion is PARKED** (Jason: super low priority). No dedicated mock — styled to the language.

## NEXT (in order)
1. **QA slice 3c (Glow).** Then **slice 3d — Sounds** section inline (reuse `OpenSoundPicker`; a sound-name pill + Test; `cfg.sound`). No dedicated mock → infer.
2. **Slice 3e — Aura Load Conditions** (visibility) — the BIG remaining icon section. Reuse the visibility engine (`VE_Vis`, the toggles/cycles/spec multiselect in `BuildVisibilityEditor`) rendered inline. Check Figma for an "Aura Load Conditions" open mock; else infer. Many controls — will grow the section a lot (dynamic height ok).
3. **Deferred polish pass:** remove left-pane "YOUR AURAS" header; nudge the whole editor up ~10px (mock content starts ~panel-y 31, currently ~40 — tied to `CONTENT_TOP`, shared with the left pane); swap the aspect **padlock → chain-link** icon (need a `link` PNG); Appearance "few minor things" Jason parked.
4. **Slice 4 — BAR EDITOR** (type-specific; mocks `411:182` + `411:448`). Two bar types **Duration** / **Stacks** (Cooldown = a Duration reading a different clock). Bar has **NO multi-trigger builder** — its source IS its trigger. Wire the landing "Add Bar Aura" (currently makes a blank shell — no source) to: pick source spell (existing two-panel picker → `cfg.spellID`), Duration vs Stacks, Track aura|cooldown, drain|fill, Max/Unit(auto). **⚠ ENGINE-vs-MOCK GAPS to resolve with Jason FIRST:** the Bar Appearance mock shows **Segments / Segment Gap / Continuous|Segmented**, **Border**, and **Bar Color 1 + Bar Color 2** — the engine does NOT do segments/border/2nd-color yet (only orientation, drain/fill, one fill color + bg). Decide: build those engine features, or omit/grey them (the redesign rule = "only promise what works"). Also **bar TEXT features** Jason wants: (a) **style the stack-count text** — FEASIBLE + secret-safe (it's a FontString; not built), (b) **duration countdown NUMBER** — FEASIBLE-unbuilt via a hidden Cooldown widget w/ `SetHideCountdownNumbers(false)` styled by the cooldown's own font API (more limited than a FontString). Bar ENGINE (all 3 modes) is DONE + shipped; back-doors `/ga bar <id>` / `/ga bar cd <id>` / `/ga bar stacks <id> [max]` work NOW.
5. **Slice 5 — Texture editor** (infer from Icon; default-open Appearance, no trigger emphasis; often a decoration).

## Learnings this session (don't rediscover)
- **PIXEL-PERFECT EVERY PASS** — Jason is ruthlessly picky; never reuse an old-styled control or defer polish ("structure now, pixels later" made him angry). Pull the exact design context, apply it, get an in-game screenshot to compare. (memory: pixel-perfect-every-pass.)
- **Non-seeding reads** for section controls that live in the shared `rows` refresh (Trigger, Text): reading `cfg.trigger`/`cfg.text` must NOT create them, or a decoration aura silently gains an (empty) config. Only WRITES seed.
- **Bar "not tracking" was a red herring:** the engine works via `/ga bar`; the landing "Add Bar Aura" makes an unconfigured shell (Slice 4 fixes). Bulletstorm (389019, Tracked Buffs cat=2) probe while ACTIVE showed `auraInstanceID=418, dur player[obj:userdata], stacks player[SECRET(number)]` — duration + stacks both readable on a Tracked-Buffs aura (confirms cat=2 works for bars, like Freezing). Read probes off disk: `WTF/Account/AELWYN/SavedVariables/GloomsAuras.lua` → `probeLog`.
- Assets added by Jason: `Media/ga_logo_full.png`, `Media/checkmark_white.png` (white → tint). Still needed: a **chain-link** PNG for the aspect lock.
- The DoT/bar lag ("stacks bar sort of laggy") is a SEPARATE, un-started investigation Jason flagged — not now.
