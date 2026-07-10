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
