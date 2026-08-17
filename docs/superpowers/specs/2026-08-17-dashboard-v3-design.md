# Cymphony Dashboard v3 — Final Design: "Precision Instrument" (with Emberline grafts)

Date: 2026-08-17. Status: FINAL — implementers follow this document verbatim; every design
decision is resolved here. Scope: full production redesign of the LiveView dashboard.
Files: `priv/static/dashboard.css` (rewrite), `lib/cymphony_elixir_web/live/dashboard_live.ex`
render/1 (surgical restructuring), `lib/cymphony_elixir_web/components/layouts.ex` (small
additions). No new routes, no new deps, no build step, no web fonts, vanilla CSS only.

---

## 0. Verdict and synthesis

Two candidates were produced and judged: **A "Precision Instrument"** (graphite neutrals, one
Signal Cyan accent, engineered data grid) and **B "Emberline"** (warm espresso + copper,
editorial serif voice, rail-as-hero).

**Winner: A.** It wins on ops-legibility over long sessions (color = state only; grayscale
discipline), engineering correctness (its flex-basis session grid survives the hidden-columns
pref, where B's fixed grid tracks misalign when a cell is `display:none`; its `body::after`
scrim actually intercepts clicks, where B's box-shadow scrim lets clicks land on controls
underneath), light-theme correctness (it adds the missing `prefers-color-scheme` block so
"system" mode really follows the OS; B explicitly preserved the current bug), and much lower
test/structural churn.

**Grafted from B** (B was the more beautiful document; these carry its beauty without its risk):

1. **Toast-stack flashes** — flashes leave the document flow into a fixed bottom-right stack;
   today they shift the entire board when they appear (§6.9).
2. **Reconnect note + stale dimming** on transport loss (§8).
3. **Rail vitals** — the nav rail opens with live fleet numerals and the autonomy sentence,
   making the sidebar the hero, without B's risky drawer-relocation (§7.1).
4. **Editorial metric numerals** — the instrument band's values go big and light
   (26px / weight 300 tabular), plus a single accent signature rule under the band. This is
   the largest visual upgrade and is DOM-identical (§6.3).
5. **`RailNav` scroll-spy hook** (optional, additive, ships last) for `aria-current` section
   highlighting in the rail (§7.2).
6. **CSS chevron disclosures** replacing the `▸`/`▾` glyphs (verified: no test pins the
   glyphs in row disclosures; the completions collapse button keeps its JS-written glyph but
   hides it) (§6.6, §7.8).
7. **Empty-state breathing dot**, **completions zebra + ok-dot**, `accent-color` on native
   checkboxes/radios, and the settings console's helper copy explaining refresh-interval vs
   Linear polling (§7.3, §8).

**Rejected from B, with reasons** (do not resurrect):
- Espresso/copper palette: the copper accent (~25° hue from amber) collides with the
  load-bearing `--warn` = retrying/paused semantics of an ops board.
- Serif-italic editorial voice: system serif rendering varies too much across platforms for a
  production tool; the final keeps exactly two voices (sans = language, mono = data).
- Settings panel sliding from the rail's left edge with a box-shadow scrim: pass-through
  clicks; the drawer stays right-side with a real scrim element (§7.3).
- Fixed `grid-template-columns` session rows: breaks `data-hidden-cols` alignment.
- Moving the per-project Pause button into the title block: test churn, no legibility gain.
  The button stays the last child of `.project-section-controls`.

**Adjusted from A**: metric value size 18px → 26px/300 (graft 4); the box-shadow three-bar
brand mark (self-flagged as fragile) is replaced by its own fallback, now primary: a
gradient-stripe mark (§7.2); in-flow flashes → toasts (graft 1).

---

## 1. Compatibility contract (read first — verified against the codebase 2026-08-17)

The redesign **restyles existing class names instead of renaming them**. Class names are the
API between the template, the hooks in `layouts.ex`, the pref CSS, and the test suite.

### 1.1 Selectors/attributes that JS reads — keep exact names

- Hooks (all inline in `layouts.ex`): `LiveClock`, `HarnessTail`, `QueueBoard`,
  `QueueEditPanel`, `Combobox`, `OverlayDismiss`. No renames. New optional `RailNav` is
  additive (§7.2).
- `Combobox.setChrome` toggles `combobox--open` on `.combobox` and `is-combobox-open` on the
  closest `.project-section`, `.session-row`, `.queue-card` — those class names stay on those
  elements.
- `QueueBoard` reads/writes: `article.queue-card`, `data-issue`, `data-rank`, `data-order`,
  `data-project`, `.is-dragging`, `.queue-drag-ghost`, `.is-reduced-motion`,
  `.is-queue-dragging`, body class `queue-board-dragging`, and the interactive-guard selector
  `a, button, input, select, textarea, label, option, .queue-card-edit, .queue-edit-form,
  .combobox`.
- `QueueBoard.tokenMs` / ghost styles read CSS custom properties **by name**: `--dur-flip`,
  `--dur-mid`, `--dur-fast`, `--ease`, `--ease-spring`, `--z-drag`, `--shadow-drag`,
  `--accent-soft`. Values may change; names may not.
- `QueueEditPanel` positions `div.queue-card-edit` (fixed) relative to the closest
  `.queue-card`; the CSS `min-width: 304px` on `.queue-card-edit` is assumed by its placement
  math — keep it.
- `OverlayDismiss.keepOpen` checks `.settings-drawer`, `.queue-card-edit`, `.combobox-list`,
  `.combobox-panel`, `.combobox.combobox--open`, plus `[data-drawer-toggle]` and
  `.queue-card-edit-toggle` special cases.
- `HarnessTail` scrolls `.harness-tail-body` inside `#harness-tail-<id>`; reads `data-follow`.
- Layout script (delegated, survives any number of instances): `[data-theme-set]`,
  `[data-mode-set]`, `[data-drawer-toggle]`, `[data-collapse-toggle]` (JS rewrites its
  textContent to `▸`/`▾` and sets `aria-expanded` — §7.8 hides the glyph, never removes the
  button), `[data-pref]`, `[data-pref-section]`, `[data-pref-col]`, `html[data-drawer="open"]`,
  `html[data-ui-mode]`, `html[data-theme]`, `html[data-density]`, `html[data-hidden-sections]`,
  `html[data-hidden-cols]`, `html[data-collapsed-sections]`, `html[data-expanded-sections]`,
  `html[data-completions-limit]`.
- Clock anchors: `data-clock="countdown|due|elapsed"` + `data-remaining-ms` /
  `data-base-seconds` / `data-rate`. Always amounts, never wall times. JS clock formatting is
  pinned byte-identical by `test/cymphony_elixir/extensions_test.exs`. Any **new**
  time-derived text must carry an anchor or be static. This design adds none.

### 1.2 IDs that must keep working

`#dashboard-root`, `#live-clock`, `#harness-tail-<issue>`, `#queue-board-<project>`,
`#queue-card-<project>-<issue>`, `#queue-edit-<project>-<issue>`, `#agent-<project>`,
`#model-<project>`, `#effort-<project>`, `#providers-<project>`, `#concurrency-<project>`,
`#linear-connect-form`, `#linear-api-key`, `#add-project-form`, `#add-project-slug`,
`#add-project-name`, `#add-project-github`, `#add-project-provider`,
`#drawer-refresh-interval`, `#drawer-global-concurrency`, `#restart-*-<issue>` family.

New ids added by this design: `#dashboard-top` (main column wrapper), `#completions-section`,
`project-<slug>` per project section (§5.2), `#rail-nav` (only if RailNav ships).

### 1.3 Strings pinned by the test suite (keep verbatim, or repin in the same commit)

`extensions_test.exs` asserts the served CSS contains: `:root {`, `.status-badge-live`,
`[data-phx-main].phx-connected .status-badge-transport` and `…-payload`,
`html[data-ui-mode="simple"] .advanced-only`, `.mode-switch-button[data-mode-set="simple"]`,
`html[data-ui-mode="simple"]:not([data-expanded-sections~="completions"])
.section--completions .session-row-list`, `.project-section > .project-section-header`,
`.project-section.is-combobox-open`, `.combobox.combobox--open`, `--z-combobox: 80`,
`z-index: var(--z-combobox)`.

`dashboard_live_test.exs` / `live_e2e_test.exs` pin exact attribute strings in rendered HTML:
`class="metric-pill metric-pill--queue section--queue advanced-only"`,
`class="metric-pill metric-pill--states section--states advanced-only"` and the `--kinds`
twin, `class="chip chip--accent advanced-only"`, `class="chip chip--agent advanced-only"`,
`class="tps"`, `.queue-next-badge` (text "Next"), `.queue-board-list`,
`.project-section-name`, `.model-switcher`, `.status-badge-payload.status-badge-offline`,
`button.queue-card-edit-toggle` (text "Edit"), `a.session-row-link.queue-card-link`,
"Leftmost starts next". One test **refutes** `command-bar-row--ops` — never reintroduce that
class. One test refutes the substring `chip` anywhere inside a rendered
`article.queue-card` — no class containing "chip" inside queue cards.

### 1.4 Behavior contracts the design must not disturb

- Change-only re-render + client-side clocks (CLAUDE.md "Refresh behavior"): nothing may
  require re-assigning `:now` on a timer; nothing new reads `@now` outside the existing
  `@clock_sections` (`[:token_totals, :running, :projects]`). The rail (§7.1) reads only
  `@projects`, `@counts`, `@completions`, `@polling`, `@version` — all existing section
  assigns, no clocks, so `:now` re-anchoring never touches it.
- All `phx-*` event names, `/api/v1/*` routes, and form field names unchanged.
- Simple/Advanced stays CSS-driven via `.simple-only` / `.advanced-only` + `html[data-ui-mode]`.
- Form controls keep stable ids so morphdom preserves focus and the Combobox keep-open path.
  Never embed volatile data (counts, ranks) in an id.
- Never render the raw Linear API key anywhere.
- Delivery: `dashboard.css` is compiled into `StaticAssets` at build (`File.read!` +
  `@external_resource`) and cache-busted with `?v=<version>` in `layouts.ex`. A CSS edit needs
  only a recompile; there is no other cache mechanism.

### 1.5 Retired (safe: no JS or test reads them)

`--grad-1`, `--grad-2`, `--grad-3`, `--gradient-cosmic`, the purple radial body washes, the
pill chrome on `.metric-pill`/`.chip`/buttons, `--glow-bold` usage as card hover. Delete.

---

## 2. Design tokens

Rules: **neutrals carry the interface** (graphite ramp, no blue/purple cast — a grayscale
screenshot should look nearly identical); **one accent** (Signal Cyan) meaning
interactive / focused / next-to-dispatch, never a data category; **color = state** (green
running, amber retrying/paused/caution, red failed/stalled/destructive); **terminal wells stay
dark in both themes**. The page background is flat — no radial glows, no atmosphere gradients;
the beauty budget is spent on numerals, hairlines, and alignment.

### 2.1 Dark theme (default — `:root` IS dark)

```css
/* ==========================================================================
   Cymphony Observability — "Precision Instrument"
   Graphite/ink neutrals, one Signal Cyan accent, color reserved for state.
   Dark-first: this :root IS the dark theme. Light = :root[data-theme=light]
   plus the prefers-color-scheme media duplicate (§2.2) — edit both together.
   Token NAMES are stable API (JS reads several by name — see §1.1).
   ========================================================================== */
:root {
  color-scheme: dark;

  /* --- Surfaces (graphite ramp) --- */
  --page:         #0C0D0F;
  --surface:      #121316;   /* panels / cards                              */
  --surface-soft: #17191D;   /* raised: hovered rows, queue cards, toolbars */
  --surface-deep: #1C1F24;   /* inset: inputs                               */
  --surface-well: #08090A;   /* terminal wells (harness, logs) — same in light */

  /* --- Ink --- */
  --ink:       #E8EAED;
  --ink-soft:  #A8ADB6;
  --ink-mute:  #7A808A;      /* labels/meta — ≥4.5:1 on --surface           */
  --ink-faint: #565B64;      /* decorative marks only, never body text      */
  --well-ink:  #C9CDD3;      /* text inside wells — same in light           */

  /* --- Hairlines --- */
  --line:        rgba(226, 230, 235, 0.07);
  --line-strong: rgba(226, 230, 235, 0.15);

  /* --- Accent: Signal Cyan (interaction / focus / dispatch head) --- */
  --accent:        #40C2E7;
  --accent-strong: #6FD3F0;
  --accent-soft:   rgba(64, 194, 231, 0.12);    /* JS CONTRACT (drag ghost) */
  --accent-ink:    #06222C;                     /* text on accent fills     */
  --accent-fade:   linear-gradient(90deg, var(--accent), rgba(64, 194, 231, 0)); /* signature rule */
  --focus-ring:    0 0 0 2px rgba(64, 194, 231, 0.55);

  /* --- State --- */
  --ok:     #3DD68C;  --ok-soft:     rgba(61, 214, 140, 0.10);
  --warn:   #E8B33F;  --warn-soft:   rgba(232, 179, 63, 0.10);
  --danger: #F0655A;  --danger-soft: rgba(240, 101, 90, 0.10);

  /* --- Elevation (borders first, shadows last) --- */
  --glow-soft:   0 0 0 1px var(--line), 0 1px 2px rgba(0, 0, 0, 0.40);
  --glow-bold:   0 0 0 1px var(--accent), 0 8px 24px rgba(0, 0, 0, 0.40);
  --shadow-pop:  0 0 0 1px var(--line-strong), 0 16px 40px rgba(0, 0, 0, 0.50);
  --shadow-drag: 0 16px 40px rgba(0, 0, 0, 0.55), 0 0 0 1px var(--accent);  /* JS CONTRACT */

  /* --- Typography (§3) --- */
  --font-sans: system-ui, -apple-system, "SF Pro Text", "Segoe UI Variable Text",
               "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --font-mono: ui-monospace, "SF Mono", SFMono-Regular, "Cascadia Mono", Menlo,
               Consolas, "Liberation Mono", monospace;
  --text-micro:   10px;   --text-caption: 11px;  --text-body-sm: 12px;
  --text-body:    13px;   --text-subhead: 15px;  --text-h2: 17px;  --text-h1: 20px;
  --text-metric:  26px;   /* instrument-band values (graft from B)  */
  --text-vital:   20px;   /* rail vitals numerals                   */
  --tracking-body: 0;  --tracking-label: 0.08em;  --tracking-wide: 0.14em;
  --tracking-h2: -0.01em;  --tracking-h1: -0.02em;  --tracking-metric: -0.015em;

  /* --- Motion (names read by QueueBoard JS; values are the spec §9) --- */
  --ease:        cubic-bezier(0.2, 0, 0, 1);
  --ease-spring: cubic-bezier(0.3, 1.1, 0.3, 1);
  --dur-fast: 120ms;  --dur-mid: 180ms;  --dur-slow: 260ms;  --dur-flip: 240ms;

  /* --- Shape --- */
  --radius-card: 8px;  --radius-row: 6px;  --radius-ctl: 6px;  --radius-tag: 4px;
  --radius-pill: 999px;   /* LEDs/dots only — no pill-shaped UI anywhere */

  /* --- Layout --- */
  --rail-w: 232px;  --rail-w-mid: 64px;  --topbar-h: 48px;
  --shell-max: 1600px;  --gutter: 20px;  --ctl-h: 30px;
  --space-1: 4px;  --space-2: 8px;  --space-3: 12px; --space-4: 16px;
  --space-5: 20px; --space-6: 24px; --space-7: 32px; --space-8: 40px;

  /* --- Stack (--z-combobox: 80 is test-pinned; --z-drag is a JS contract) --- */
  --z-ring: 0;  --z-child: 1;  --z-header: 8;  --z-row-open: 12;  --z-rail: 20;
  --z-section-open: 30;  --z-scrim: 39;  --z-drawer: 40;  --z-popover: 50;
  --z-toast: 70;  --z-combobox: 80;  --z-drag: 90;
}
```

### 2.2 Light theme (`:root[data-theme="light"]` + system media duplicate)

Light is "print": warm-neutral paper, near-black ink, the accent darker-calibrated. Wells stay
dark (`--surface-well` / `--well-ink` values identical) — the flight-deck moment of the light
theme.

```css
:root[data-theme="light"] {
  color-scheme: light;
  --page: #F4F4F2;  --surface: #FFFFFF;  --surface-soft: #F8F8F6;
  --surface-deep: #EEEFEC;  --surface-well: #08090A;
  --ink: #17191C;  --ink-soft: #4A4E55;  --ink-mute: #6E737B;  --ink-faint: #A5A9B0;
  --well-ink: #C9CDD3;
  --line: rgba(23, 25, 28, 0.09);  --line-strong: rgba(23, 25, 28, 0.18);
  --accent: #0E7DA0;  --accent-strong: #0B637F;
  --accent-soft: rgba(14, 125, 160, 0.10);  --accent-ink: #FFFFFF;
  --accent-fade: linear-gradient(90deg, var(--accent), rgba(14, 125, 160, 0));
  --focus-ring: 0 0 0 2px rgba(14, 125, 160, 0.45);
  --ok: #178040;  --ok-soft: rgba(23, 128, 64, 0.10);
  --warn: #9A6700;  --warn-soft: rgba(154, 103, 0, 0.10);
  --danger: #C0362C;  --danger-soft: rgba(192, 54, 44, 0.08);
  --glow-soft:  0 0 0 1px var(--line), 0 1px 2px rgba(23, 25, 28, 0.06);
  --glow-bold:  0 0 0 1px var(--accent), 0 8px 24px rgba(23, 25, 28, 0.10);
  --shadow-pop: 0 0 0 1px var(--line-strong), 0 16px 40px rgba(23, 25, 28, 0.14);
  --shadow-drag: 0 16px 40px rgba(23, 25, 28, 0.18), 0 0 0 1px var(--accent);
}
```

**System mode follows the OS (new — fixes a documented gap).** CLAUDE.md says system mode
"clears the attribute to follow the OS", but the current CSS renders dark regardless. Add,
immediately below the light block, a media duplicate:

```css
/* Keep byte-identical to :root[data-theme="light"] above. Vanilla CSS cannot
   share a declaration between an attribute selector and a media query, so this
   block is a maintained duplicate — edit both together. */
@media (prefers-color-scheme: light) {
  :root:not([data-theme]) { /* …same custom properties as the light block… */ }
}
```

Explicit `data-theme="dark"` still forces dark on a light OS (`:not([data-theme])` guard).

The `select` chevron data-URI fill is `%237A808A` (dark) with a light-theme override rule
using `%236E737B`.

### 2.3 Contrast budget (verify when tuning; `--ink-faint` is decorative only)

| Pair (dark) | Ratio | Pair (light) | Ratio |
|---|---|---|---|
| `--ink` on `--surface` | ~13.5:1 | same | ~15.9:1 |
| `--ink-soft` on `--surface` | ~7.2:1 | same | ~8.4:1 |
| `--ink-mute` on `--surface` | ~4.6:1 | same | ~5.1:1 |
| `--accent` on `--surface` | ~8.7:1 | same | ~5.0:1 |
| `--ok`/`--warn`/`--danger` on `--surface` | ≥5.8:1 | same | ≥4.8:1 |
| `--accent-ink` on `--accent` | ~8:1 | same | ~5:1 |
| `--well-ink` on `--surface-well` | ~11:1 | identical | ~11:1 |

---

## 3. Typography system

- **Two voices only. Sans for language, mono for data.** Titles, labels, copy → `--font-sans`.
  Identifiers, numbers, model names, providers, timestamps, tags, terminal output →
  `--font-mono`. No serif anywhere.
- Every numeric cell carries `.numeric` (`font-variant-numeric: tabular-nums slashed-zero`).
- **Micro-label voice** (the single labeling style everywhere — metric labels, grid headers,
  group titles, stat labels, queue-board label, rail group labels): `--text-micro` or
  `--text-caption`, weight 600, `letter-spacing: var(--tracking-label)`,
  `text-transform: uppercase`, color `--ink-mute`.
- **Metric voice** (instrument band values): `--font-sans` `--text-metric` (26px), weight 300,
  `letter-spacing: var(--tracking-metric)`, tabular-nums, `--ink`, line-height 1.1. Rail
  vitals use the same voice at `--text-vital` (20px). Weight 300 falls back gracefully on
  every system stack; never bold large numerals.
- Scale: 10 / 11 / 12 / 13 / 15 / 17 / 20 / 26. Body line-height 1.5; data rows 1.35;
  wells 1.4. Weights: 400 body, 500 data cells, 600 titles/labels; nothing bolder.
- Base element CSS (replaces the gradient body background — flat page, no glows):

```css
html { background: var(--page); }
body {
  margin: 0; min-height: 100vh;
  background: var(--page); color: var(--ink);
  font-family: var(--font-sans); font-size: var(--text-body); line-height: 1.5;
  -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;
}
```

---

## 4. Spacing / radius / elevation

- 4px spacing grid via `--space-*`. Panel padding `--space-4`; row padding
  `--space-2 --space-3`; band cell padding `--space-3 --space-4`; rail padding `--space-3`.
- Radius discipline: panels 8, rows/cards 6, controls 6, tags 4. Pill radius only for
  LEDs/dots. **No pill-shaped buttons, chips, badges, or inputs anywhere.**
- Elevation model:
  - L0 page: flat `--page`.
  - L1 panels (`.project-section`, `.section-card`, `.instrument-band`, top strip, rail):
    `--surface`, 1px `--line` border, `--glow-soft`.
  - L2 raised-in-panel (queue cards, hovered rows, toolbars): `--surface-soft`, 1px `--line`.
  - L3 inset: fields `--surface-deep` + `--line-strong` border; wells `--surface-well`, no
    border inside, 1px `--line` frame outside.
  - L4 overlays (combobox panel, queue edit popover, drawer, toasts): `--surface`,
    `--shadow-pop`.
  - Drag layer: `--shadow-drag` (accent-ringed).
- Focus everywhere: `box-shadow: var(--focus-ring)` (or `outline: 2px solid var(--accent);
  outline-offset: 2px` where box-shadow is occupied). One system, no exceptions.

---

## 5. Layout architecture

Two-column grid: persistent left **nav rail** (sticky, full height) + fluid content column
(slim sticky 48px top strip → instrument band → project sections → completions). Settings
remain a right-side **console** drawer (mechanism unchanged) with a new real scrim.

```
≥1200px
┌────────────┬──────────────────────────────────────────────────────────────┐
│ ▮▮▮CYMPHONY│ TOP STRIP  ● Live · v2.7.1 ·   Refresh · Settings            │ sticky 48px
│  v2.7.1    ├──────────────────────────────────────────────────────────────┤
│ 3 running  │ ┌──────────────────────────────────────────────────────────┐ │
│ 7 queued   │ │ RUN     RETRY   QUEUE   TOKENS      RUNTIME    TPUT      │ │ instrument
│ Automatic  │ │  3        1       7     1,204,332   3h 12m     41.2 ▁▂▅▇ │ │ band, 26px
│ work is on │ │ ─────── hairline cells · states · kinds · poll · limits ─┤ │ numerals
│            │ └━━━━━━━━━ (accent signature rule, bottom-left) ━──────────┘ │
│ FLEET      │ ┌ ● AgentFarm  2/4 running · 7 queued ── cr[4] agent model ┐ │
│ ● Overview │ │ QUEUE 7                                  Leftmost starts │ │
│ ● AgentFarm│ │ [01 LLM-51 ▎NEXT] [02 LLM-12] [03 LLM-13] [04 LLM-19]    │ │
│   2·7      │ │ ISSUE      TITLE               TAGS      TIME    TOKENS  │ │
│ ◐ WebApp   │ │ ▸ ● LLM-48 Fix retry backoff…  claude…   4m 12s  48,211  │ │
│   0·1      │ │ ▸ ● LLM-50 Migrate queue…      codex…    1m 02s   9,410  │ │
│ ○ Docs     │ │ ▎RETRY LLM-31 attempt 2 · due 42s  error…    [Retry now] │ │
│ Completions│ └──────────────────────────────────────────────────────────┘ │
│ ────────── │ ┌ WebApp … ┐                                                 │
│ Simple|Adv │ RECENT COMPLETIONS ▾ (ledger)                                │
│ ☼ ◑ ▣  ⚙ ⟳ │                                              ┌────────────┐  │
└────────────┴──────────────────────────────────────────────│ CONSOLE    │──┘
                                                            │ (settings, │ right drawer
                                                            │ scrimmed)  │ + toasts ↘
                                                            └────────────┘
900–1199px: rail condenses to 64px (brand glyph, project LEDs, foot icons; names tooltip).
<900px:     rail hidden; top strip regains brand + native <details> project-jump menu;
            single column; console full-width sheet; toasts full-width bottom.
```

### 5.1 Shell CSS

```css
.app-shell { max-width: none; margin: 0; padding: 0; }   /* layouts.ex <main> keeps class */
.dashboard-shell {
  display: grid;
  grid-template-columns: var(--rail-w) minmax(0, 1fr);
  min-height: 100vh;
}
.side-rail {
  position: sticky; top: 0; align-self: start; height: 100dvh;
  display: flex; flex-direction: column; gap: var(--space-4);
  padding: var(--space-4) var(--space-3);
  background: var(--surface); border-right: 1px solid var(--line);
  z-index: var(--z-rail); overflow-y: auto; scrollbar-width: thin;
}
.main-col {
  min-width: 0; display: flex; flex-direction: column; gap: var(--space-4);
  padding: 0 var(--gutter) var(--space-8);
  max-width: var(--shell-max); width: 100%;
}
```

The content column is data-dense (`--shell-max: 1600px`), not editorial-narrow.

### 5.2 Template restructure (`dashboard_live.ex` render/1) — HEEx sketch

Wrapper ids/hooks unchanged (`#live-clock` → `#dashboard-root` with `OverlayDismiss`; one
`phx-hook` per element as today). New structure inside `#dashboard-root`:

```heex
<div id="live-clock" phx-hook="LiveClock">
  <section id="dashboard-root" class="dashboard-shell" phx-hook="OverlayDismiss">

    <nav class="side-rail" aria-label="Dashboard">…brand / vitals / fleet nav / foot (§7.1)…</nav>

    <div class="main-col" id="dashboard-top">
      <header class="command-bar">
        <div class="command-bar-row command-bar-row--brand">…top strip (§6.1)…</div>
        <%!-- simple-mode-summary row stays here, markup unchanged --%>
      </header>
      <%!-- instrument band MOVES OUT of <header>, keeps its pinned class tokens --%>
      <div class="instrument-band command-bar-row--metrics section--metrics">…(§6.3)…</div>
      …reconnect-note… …stalled alert… …error card…
      <article class={project_section_class(...)} id={"project-" <> project_dom_id(project.name)}>…</article>
      <section class="section-card section--completions" id="completions-section">…</section>
    </div>

    <aside class="settings-drawer" aria-label="Dashboard settings">…console (§7.3)…</aside>

    <div class="toast-stack" aria-live="polite">…flashes (§6.9)…</div>
  </section>
</div>
```

- The band keeps `command-bar-row--metrics section--metrics` (pref CSS + section-visibility
  key off them) and gains `.instrument-band`; its `unless @payload_error` guard moves with it.
- New helper `defp project_dom_id(name)`: `String.replace(name, non_id_char_regex(), "-")`
  (reuses the existing `non_id_char_regex/0`; no downcasing; private web-module defp — no
  @spec/coverage burden).
- `scroll-margin-top: calc(var(--topbar-h) + var(--space-3))` on `.project-section` and
  `.section--completions`; `html { scroll-behavior: smooth }` with a
  `prefers-reduced-motion: reduce` override to `auto`.

---

## 6. Component specs — Part A surface

### 6.0 Panels (shared)

```css
.project-section, .section-card {
  position: relative;
  background: var(--surface); border: 1px solid var(--line);
  border-radius: var(--radius-card); padding: var(--space-4);
  display: flex; flex-direction: column; gap: var(--space-3);
  box-shadow: var(--glow-soft); isolation: isolate;
}
```

Keep the existing z-index escalation block **verbatim** (test-pinned + combobox correctness):
`.project-section > .project-section-header { z-index: var(--z-header); overflow: visible }`;
`.project-section.is-combobox-open`, `.is-queue-edit-open`, `.is-queue-dragging`,
`:has(.queue-card-edit)`, `:has(.queue-card.is-combobox-open)` → `z-index:
var(--z-section-open)`; plus the row/board/list child layers as today.

Paused state — no opacity wash (illegible). Amber "on hold" edge:

```css
.project-section--paused { border-color: var(--line-strong); }
.project-section--paused > .project-section-header { opacity: 0.85; }
.project-section--paused::before {
  content: ""; position: absolute; inset: 0 auto 0 0; width: 2px;
  background: var(--warn); opacity: 0.6; border-radius: 2px 0 0 2px;
}
```

### 6.1 Top strip (`.command-bar` restyled)

Slim, sticky, quiet: connection status + the two global actions.

```css
.command-bar {
  position: sticky; top: 0; z-index: var(--z-header);
  display: flex; flex-direction: column; gap: 0;
  min-height: var(--topbar-h);
  margin: 0 calc(-1 * var(--gutter)); padding: 0 var(--gutter);
  background: color-mix(in srgb, var(--page) 88%, transparent);
  backdrop-filter: blur(8px);
  border: 0; border-bottom: 1px solid var(--line);
  border-radius: 0; box-shadow: none;
}
@supports not (backdrop-filter: blur(8px)) { .command-bar { background: var(--page); } }
.command-bar-row--brand { min-height: var(--topbar-h); justify-content: space-between; }
@media (min-width: 900px) { .command-bar .command-bar-brand { display: none; } }
```

Contents: `.command-bar-brand` (shown only <900px — the rail owns brand at wide widths);
meta cluster keeps transport/payload `.status-badge` pair (swap rules byte-identical),
`.version-badge` (bare mono `--text-micro` `--ink-mute`, no border; hidden <640px), Refresh
button, Settings `[data-drawer-toggle]` (keep gear geometry `::before`). The mode switch and
theme toggle **move to the rail foot**; the topbar keeps duplicate copies with class
`.topbar-only-narrow` shown only <900px (the delegated layout script already syncs every
instance).

Status badges — classes kept, pill dropped:

```css
.status-badge {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 2px 8px; border: 1px solid var(--line); border-radius: var(--radius-tag);
  background: transparent; color: var(--ink-mute);
  font-size: var(--text-micro); font-weight: 600;
  letter-spacing: var(--tracking-label); text-transform: uppercase;
}
.status-badge-dot { width: 6px; height: 6px; border-radius: var(--radius-pill);
  background: currentColor; }
.status-badge-live { color: var(--ok); border-color: transparent; background: var(--ok-soft); }
.status-badge-live .status-badge-dot { animation: led-breathe 2.4s var(--ease) infinite; }
.status-badge-offline { color: var(--ink-mute); }
@keyframes led-breathe { 0%,100% { opacity: 1 } 50% { opacity: 0.35 } }
```

`.simple-mode-summary` (autonomy row, simple mode): one quiet sentence row under the strip,
no box; indicator dot keeps state colors; markup unchanged.

### 6.2 Brand mark

CSS gradient-stripe level meter (three accent bars, no gradient *colors* — hard stops), the
one place the accent is identity. This replaces the fragile box-shadow trick — this IS the
implementation:

```css
.brand-mark {
  display: inline-block; width: 16px; height: 14px; border-radius: 2px;
  background:
    linear-gradient(180deg, transparent 42%, var(--accent) 42%) 0    0 / 4px 100% no-repeat,
    linear-gradient(180deg, var(--accent), var(--accent))       6px  0 / 4px 100% no-repeat,
    linear-gradient(180deg, transparent 21%, var(--accent) 21%) 12px 0 / 4px 100% no-repeat;
}
.brand-wordmark { font-size: var(--text-body); font-weight: 600;
  letter-spacing: var(--tracking-wide); color: var(--ink); }
.brand-tagline { font-size: var(--text-micro); font-weight: 600;
  letter-spacing: var(--tracking-label); text-transform: uppercase; color: var(--ink-mute); }
```

(Three 4px bars at heights 58% / 100% / 79% — an equalizer reading "Cymphony".)

### 6.3 Instrument band (metrics) — the headline surface

The pills become **cells in one hairline-divided strip** with big light numerals (graft 4).
All class names kept, including the three pinned `metric-pill--… section--… advanced-only`
attribute strings and the runtime tile's `data-clock="elapsed" data-base-seconds data-rate`
anchor — cell contents are byte-unchanged; only the wrapper class list gains
`.instrument-band` and the block moves out of `<header>` (§5.2).

```css
.instrument-band {
  display: flex; flex-wrap: wrap; align-items: stretch;
  background: var(--surface); border: 1px solid var(--line);
  border-radius: var(--radius-card); box-shadow: var(--glow-soft);
  overflow: hidden; position: relative;
}
.instrument-band::after {              /* signature accent rule, bottom-left (graft) */
  content: ""; position: absolute; left: 0; bottom: 0; height: 2px; width: 160px;
  background: var(--accent-fade);
}
.metric-pill {                          /* name kept; shape is now a cell */
  display: flex; flex-direction: column; justify-content: center; gap: 2px;
  padding: var(--space-3) var(--space-4); min-width: 96px;
  border: 0; border-radius: 0; background: none;
  border-left: 1px solid var(--line);
}
.metric-pill:first-child { border-left: 0; }
.metric-pill:hover { background: var(--surface-soft); }
.metric-pill-label {
  font-size: var(--text-micro); font-weight: 600; color: var(--ink-mute);
  letter-spacing: var(--tracking-label); text-transform: uppercase;
}
.metric-pill-value {
  font-size: var(--text-metric); font-weight: 300; line-height: 1.1;
  letter-spacing: var(--tracking-metric); color: var(--ink);
  font-variant-numeric: tabular-nums;
}
.metric-pill-detail { font-size: var(--text-caption); color: var(--ink-mute);
  font-family: var(--font-mono); }
.metric-pill-spark { font-family: var(--font-mono); font-size: var(--text-caption);
  color: var(--ink-soft); letter-spacing: 0; }   /* sparkline neutral, not accent */
/* Ops / breakdown cells render small values */
.metric-pill--ops .metric-pill-value,
.metric-pill--states .metric-pill-value,
.metric-pill--kinds .metric-pill-value {
  font-size: var(--text-body); font-weight: 500; font-family: var(--font-mono);
  letter-spacing: 0; line-height: 1.4;
}
.ops-pulse { color: var(--warn); padding-left: 0; font-weight: 500; }
.ops-pulse::before { content: none; }
```

Counts stay neutral ink — a nonzero Retry count is **not** colored in the band (the retry
rows below carry the amber); the band stays calm. Poll "Checking…" is server data, not a clock.

### 6.4 Project section header

```css
.project-section-header { display: flex; flex-wrap: wrap; align-items: center;
  gap: var(--space-2) var(--space-4); }
.project-section-name {
  margin: 0; font-size: var(--text-subhead); font-weight: 600;
  letter-spacing: var(--tracking-h2); color: var(--ink);
  display: inline-flex; align-items: center; gap: var(--space-2);
}
.project-section-name::before {         /* project LED */
  content: ""; width: 7px; height: 7px; border-radius: var(--radius-pill);
  background: var(--ink-faint);
}
.project-section:has(.session-row:not(.session-row--completed)) .project-section-name::before {
  background: var(--ok);
}
.project-section--paused .project-section-name::before {
  background: transparent; box-shadow: inset 0 0 0 1.5px var(--warn);
}
.project-section-counts {
  margin: 0; font-family: var(--font-mono); font-size: var(--text-body-sm);
  color: var(--ink-mute); font-variant-numeric: tabular-nums;
}
.project-section-counts .numeric { color: var(--ink); font-weight: 600; }
.project-section-controls { display: flex; align-items: center; flex-wrap: wrap;
  gap: var(--space-2); margin-left: auto; min-width: 0; overflow: visible; }
```

Controls (concurrency, agent/model/effort, providers, Pause/Resume) keep exact markup, ids,
order, and events — the Pause button **stays the last child of `.project-section-controls`**.
`.inline-form` loses its pill chrome (borderless label+field cluster; only the field has
chrome, §7.5).

### 6.5 Queue board

Header: `.queue-board-label` micro-label voice + `.queue-board-count` mono; hint text
("Leftmost starts next") unchanged. List grid columns (1/2/4-up) and the QueueBoard hook
untouched. **Queue cards = tickets**: squared, rank-numbered, accent only on the dispatch
head. No class containing "chip" inside cards (test-refuted).

```css
.queue-card {
  position: relative; display: grid;
  grid-template-columns: minmax(0, 1fr) auto; gap: 4px 10px; align-items: start;
  background: var(--surface-soft); border: 1px solid var(--line);
  border-radius: var(--radius-row); padding: 10px 12px;
  cursor: grab; isolation: isolate; z-index: 0;
  transition: transform var(--dur-flip) var(--ease), opacity var(--dur-mid) var(--ease),
              border-color var(--dur-fast) var(--ease), box-shadow var(--dur-mid) var(--ease);
}
.queue-card::before {                    /* rank numeral, decorative */
  content: attr(data-rank-label);
  position: absolute; top: 8px; right: 10px;
  font-family: var(--font-mono); font-size: var(--text-micro);
  color: var(--ink-faint); letter-spacing: 0.05em;
}
.queue-card--next {
  border-color: color-mix(in srgb, var(--accent) 45%, transparent);
  box-shadow: inset 2px 0 0 0 var(--accent);      /* dispatch-head edge */
}
.queue-next-badge {                       /* class + "Next" text kept (test-pinned) */
  display: inline-flex; align-items: center; padding: 1px 5px;
  border-radius: var(--radius-tag);
  background: var(--accent); color: var(--accent-ink);
  font-size: 9px; font-weight: 700; letter-spacing: var(--tracking-label);
  text-transform: uppercase; line-height: 1.4;
}
.queue-card-id { font-family: var(--font-mono); font-size: var(--text-body-sm);
  font-weight: 600; color: var(--ink); display: flex; align-items: center; gap: 8px; }
.queue-card-title { grid-column: 1 / -1; font-size: var(--text-body-sm);
  color: var(--ink-soft); line-height: 1.4;
  display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2;
  -webkit-box-orient: vertical; overflow: hidden; }
button.queue-card-edit-toggle {
  border: 1px solid var(--line); background: transparent; color: var(--ink-mute);
  font-size: var(--text-micro); font-weight: 600; letter-spacing: var(--tracking-label);
  text-transform: uppercase; padding: 2px 7px; border-radius: var(--radius-tag);
  opacity: 0.55; transition: opacity var(--dur-fast) var(--ease);
}
.queue-card:hover .queue-card-edit-toggle, .queue-card:focus-within .queue-card-edit-toggle,
.queue-card.is-editing .queue-card-edit-toggle { opacity: 1; color: var(--ink); }
```

Template addition: `data-rank-label={String.pad_leading(to_string(rank + 1), 2, "0")}` on the
card article. `data-rank` stays 0-based (hook-owned). After a drag the hook rewrites
`data-rank` but not `data-rank-label`; acceptable — the server reload re-renders ranks within
one refresh. Do **not** make `::before` read `data-rank` and do not touch the hook.

Drag: keep `.is-dragging { opacity: 0.35; cursor: grabbing }` and the JS-owned ghost
(`--shadow-drag` / `--accent-soft` redefined by tokens). Edit popover `.queue-card-edit`:
L4 overlay — `background: var(--surface); border: 1px solid var(--line-strong);
border-radius: var(--radius-card); box-shadow: var(--shadow-pop); padding: var(--space-3);
min-width: 304px;` — keep the `detail-fade` animation name and the reduced-motion opt-out.

### 6.6 Session rows — the data grid

Fixed-width cells so numbers land in the same columns; a header row names them once. Layout
is **flex with fixed flex-basis cells** (not a grid template) so `data-hidden-cols`
`display:none` removes a cell without leaving holes or misaligning tracks.

New template inside the **running** `.session-row-list` (not completions), before the
comprehension — head cells reuse the column classes so the existing
`html[data-hidden-cols~=…]` pref CSS hides header and body cells with zero new selectors:

```heex
<div class="session-grid-head advanced-only" aria-hidden="true">
  <span class="sg-caret"></span>
  <span class="sg-id">Issue</span>
  <span class="session-row-title">Title</span>
  <span class="session-row-chips">Tags</span>
  <span class="session-row-runtime">Time</span>
  <span class="session-row-tokens">Tokens</span>
  <span class="sg-act"></span>
</div>
```

```css
.session-row-list { display: flex; flex-direction: column; }
.session-row { border-top: 1px solid var(--line); border-radius: 0;
  transition: background-color var(--dur-fast) var(--ease); }
.session-row:hover { background: var(--surface-soft); }
.session-row--expanded { background: var(--surface-soft);
  border: 1px solid var(--line-strong); border-radius: var(--radius-row);
  margin: var(--space-1) 0; }
.session-row--expanded + .session-row { border-top-color: transparent; }

.session-grid-head, .session-row-summary {
  display: flex; align-items: center; gap: var(--space-3);
  padding: 6px var(--space-2); font-size: var(--text-body-sm);
}
.session-grid-head {
  border-top: 0; padding-top: 0; padding-bottom: 4px;
  font-size: var(--text-micro); font-weight: 600; color: var(--ink-mute);
  letter-spacing: var(--tracking-label); text-transform: uppercase;
}
.sg-caret, .session-row-disclosure { flex: 0 0 24px; }
.sg-id, .session-row-id { flex: 0 0 96px; min-width: 0;
  font-family: var(--font-mono); font-weight: 600; white-space: nowrap; }
.session-row-title { flex: 1 1 auto; min-width: 0; color: var(--ink-soft);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.session-row-chips { flex: 0 1 auto; display: inline-flex; gap: var(--space-1);
  flex-wrap: wrap; justify-content: flex-end; }
.session-row-runtime { flex: 0 0 64px; text-align: right; }
.session-row-tokens  { flex: 0 0 96px; text-align: right; }
.session-row-runtime, .session-row-tokens {
  font-family: var(--font-mono); color: var(--ink-soft);
  font-variant-numeric: tabular-nums; white-space: nowrap;
}
.session-row-tokens .tps { color: var(--ink-mute); font-size: 0.8em; }
.sg-act, .session-row-summary > .subtle-button { flex: 0 0 auto; margin-left: auto; }
```

**Run LED**: green LED on the id cell of running rows (CSS only, scoped to project sections):
`.project-section .session-row:not(.session-row--completed) .session-row-id::before
{ content: ""; width: 6px; height: 6px; border-radius: var(--radius-pill);
background: var(--ok); display: inline-block; margin-right: 7px; }`. A stalled entry's
`.chip--danger` "Stalled" tag carries the red — no extra LED logic.

**Disclosure chevron (graft 6)**: the running-row disclosure button drops its server-rendered
`▸`/`▾` text nodes from the template (verified un-pinned; keep `phx-click="toggle_logs"`,
`aria-label`); CSS draws it:

```css
.session-row-disclosure { width: 24px; height: 24px; font-size: 0; position: relative;
  appearance: none; background: transparent; border: 0; color: var(--ink-faint);
  cursor: pointer; border-radius: var(--radius-tag); }
.session-row-disclosure::before {
  content: ""; position: absolute; inset: 0; margin: auto; width: 7px; height: 7px;
  border-right: 1.5px solid currentColor; border-bottom: 1.5px solid currentColor;
  transform: rotate(-45deg); transition: transform var(--dur-fast) var(--ease);
}
.session-row-disclosure:hover { color: var(--ink); background: var(--surface-deep); }
.session-row--expanded .session-row-disclosure { color: var(--accent); }
.session-row--expanded .session-row-disclosure::before { transform: rotate(45deg); }
```

Kill button: quiet-destructive `subtle-button danger` (§7.4) — last cell, right-anchored.

### 6.7 Retry rows

Amber is the voice; columns mirror the session grid's head.

```css
.retry-row-list { border-top: 1px dashed var(--line); padding-top: var(--space-3);
  display: flex; flex-direction: column; gap: var(--space-1); }
.subsection-label { margin: 0 0 2px; font-size: var(--text-micro); font-weight: 600;
  letter-spacing: var(--tracking-label); text-transform: uppercase; color: var(--warn); }
.retry-row {
  display: flex; align-items: center; gap: var(--space-3);
  background: transparent; border: 0; border-radius: var(--radius-row);
  padding: 5px var(--space-2); font-size: var(--text-body-sm);
  box-shadow: inset 2px 0 0 0 var(--warn);
}
.retry-row:hover { background: var(--surface-soft); }
.retry-row-id { flex: 0 0 120px; font-family: var(--font-mono); font-weight: 600;
  padding-left: var(--space-2); white-space: nowrap; }
.retry-row-attempt { flex: 0 0 auto; display: inline-flex; gap: 6px; align-items: center;
  font-family: var(--font-mono); color: var(--ink-soft); }
.retry-row-error { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis;
  white-space: nowrap; color: var(--ink-mute); font-family: var(--font-mono);
  font-size: var(--text-caption); }
```

"Attempt N" keeps `.chip.chip--warn` (tag per §7.9); the `due <span data-clock="due">` anchor
and the "held while paused" mute text are untouched.

### 6.8 Alerts / error card

One banner grammar — hairline panel + 2px inset state edge, no tinted washes. The stalled
alert **stays in flow** (it is persistent state, not a notification); its
`data-clock="elapsed"` span is untouched.

```css
.alert-banner {
  display: flex; align-items: center; justify-content: space-between; gap: var(--space-3);
  flex-wrap: wrap; padding: 10px var(--space-4);
  background: var(--surface); border: 1px solid var(--line);
  border-radius: var(--radius-row); box-shadow: inset 2px 0 0 0 var(--warn);
  color: var(--ink); font-size: var(--text-body-sm);
}
.alert-banner strong { color: var(--warn); }
.alert-banner.alert-info  { box-shadow: inset 2px 0 0 0 var(--accent); color: var(--ink); }
.alert-banner.alert-error { box-shadow: inset 2px 0 0 0 var(--danger); color: var(--danger); }

.error-card { background: var(--surface); border: 1px solid var(--line);
  border-radius: var(--radius-card); box-shadow: inset 2px 0 0 0 var(--danger);
  padding: var(--space-4); }
.error-title { margin: 0; color: var(--danger); font-size: var(--text-h2);
  font-weight: 600; letter-spacing: var(--tracking-h2); }
.error-copy { margin: 6px 0 0; color: var(--ink-soft); font-size: var(--text-body-sm);
  font-family: var(--font-mono); }
```

### 6.9 Flash toasts (graft 1 — HEEx move in Part A, styled in Part A)

Flashes leave the document flow (today they shift the whole board). The two `@flash` reads
move from between the drawer and the error card into a fixed stack rendered last inside
`#dashboard-root`:

```heex
<div class="toast-stack" aria-live="polite">
  <%= if info = @flash["info"] do %><div class="alert-banner alert-info"><%= info %></div><% end %>
  <%= if err = @flash["error"] do %><div class="alert-banner alert-error"><%= err %></div><% end %>
</div>
```

```css
.toast-stack { position: fixed; right: var(--space-5); bottom: var(--space-5);
  z-index: var(--z-toast); display: flex; flex-direction: column; gap: var(--space-2);
  max-width: 420px; }
.toast-stack:empty { display: none; }
.toast-stack .alert-banner { box-shadow: var(--shadow-pop),
  inset 2px 0 0 0 var(--accent); animation: toast-in var(--dur-mid) var(--ease) both; }
.toast-stack .alert-error { box-shadow: var(--shadow-pop), inset 2px 0 0 0 var(--danger); }
@keyframes toast-in { from { opacity: 0; transform: translateY(8px); } }
@media (max-width: 640px) { .toast-stack { left: var(--space-3); right: var(--space-3); } }
```

Flash removal just patches away (no exit animation — accepted).

---

## 7. Component specs — Part B surface

### 7.1 Nav rail content (the sidebar — hero element)

Navigation + fleet telemetry, opened by a **vitals block** (graft 3). Server-rendered from
existing section assigns only (`@counts`, `@projects`, `@completions`, `@polling`,
`@version`); presenter already provides per-project `running_count`, `retrying_count`,
`waiting_count`, `paused`, `max_concurrent_agents`. No clocks in the rail. Rendered in both
modes; nothing in the rail carries `.advanced-only` except the meta counts as marked.

```heex
<nav class="side-rail" aria-label="Dashboard">
  <a class="side-rail-brand" href="#dashboard-top">
    <span class="brand-mark" aria-hidden="true"></span>
    <span class="brand-wordmark">CYMPHONY</span>
    <span class="version-badge">v<%= @version %></span>
  </a>

  <%= unless @payload_error do %>
    <div class="rail-vitals">
      <p class="rail-vitals-line">
        <span class="rail-vitals-num numeric"><%= @counts.running %></span>
        <span class="rail-vitals-word">running</span>
        <span class="rail-vitals-num numeric"><%= Map.get(@counts, :waiting, 0) %></span>
        <span class="rail-vitals-word">queued</span>
      </p>
      <p class="rail-vitals-copy">
        <%= case autonomy_state(@projects, @polling) do %>
          <% :on -> %>Automatic work is on.
          <% :paused -> %>Automatic work is paused.
          <% {:partial, a, p} -> %>On for <%= a %> of <%= p %> projects.
          <% :unknown -> %>Checking status…
        <% end %>
      </p>
    </div>
  <% end %>

  <div class="rail-group" aria-label="Fleet" id="rail-nav">   <%!-- + phx-hook="RailNav" when it ships --%>
    <p class="rail-group-label">Fleet</p>
    <a class="rail-link" href="#dashboard-top">
      <span class="rail-led rail-led--idle" aria-hidden="true"></span>
      <span class="rail-link-name">Overview</span>
    </a>
    <%= for project <- @projects do %>
      <a class="rail-link" href={"#project-" <> project_dom_id(project.name)} title={project.name}>
        <span class={"rail-led rail-led--" <> rail_state(project)} aria-hidden="true"></span>
        <span class="rail-link-name"><%= project.name %></span>
        <span class="rail-link-meta numeric advanced-only"><%= Map.get(project, :running_count, length(project.running)) %>·<%= project_waiting_count(project) %></span>
      </a>
    <% end %>
    <%= if @completions != [] do %>
      <a class="rail-link" href="#completions-section">
        <span class="rail-led rail-led--done" aria-hidden="true"></span>
        <span class="rail-link-name">Completions</span>
        <span class="rail-link-meta numeric advanced-only"><%= length(@completions) %></span>
      </a>
    <% end %>
  </div>

  <div class="rail-foot">
    <div class="mode-switch settings-mode-switch" role="group" aria-label="Dashboard mode">
      <button type="button" class="mode-switch-button" data-mode-set="simple" aria-pressed="true">Simple</button>
      <button type="button" class="mode-switch-button" data-mode-set="advanced" aria-pressed="false">Advanced</button>
    </div>
    <div class="theme-toggle" role="group" aria-label="Theme">…existing three buttons…</div>
    <button type="button" class="subtle-button rail-action" data-drawer-toggle aria-label="Settings" title="Settings"></button>
    <button type="button" class="subtle-button rail-action" phx-click="refresh_now">Refresh</button>
  </div>
</nav>
```

New helper `defp rail_state(project)`:
`cond do Map.get(project, :paused, false) -> "paused"; project.retrying != [] -> "retry";
project.running != [] -> "run"; true -> "idle" end`. Private web defp.

```css
.side-rail-brand { display: flex; align-items: center; gap: var(--space-2);
  padding: var(--space-1) var(--space-2); text-decoration: none; }
.rail-vitals { padding: var(--space-3) var(--space-2);
  border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
.rail-vitals-line { margin: 0; display: flex; align-items: baseline; column-gap: 6px;
  flex-wrap: wrap; }
.rail-vitals-num { font-size: var(--text-vital); font-weight: 300; color: var(--ink);
  letter-spacing: var(--tracking-metric); font-variant-numeric: tabular-nums; }
.rail-vitals-word { font-size: var(--text-micro); font-weight: 600; color: var(--ink-mute);
  letter-spacing: var(--tracking-label); text-transform: uppercase;
  margin-right: var(--space-2); }
.rail-vitals-copy { margin: var(--space-1) 0 0; font-size: var(--text-body-sm);
  font-style: italic; color: var(--ink-soft); }
.rail-group { display: flex; flex-direction: column; gap: 2px; flex: 1 1 auto; min-height: 0; }
.rail-group-label { margin: 0 0 4px; padding: 0 var(--space-2);
  font-size: var(--text-micro); font-weight: 600; color: var(--ink-mute);
  letter-spacing: var(--tracking-label); text-transform: uppercase; }
.rail-link { display: flex; align-items: center; gap: var(--space-2);
  padding: 6px var(--space-2); border-radius: var(--radius-ctl);
  color: var(--ink-soft); font-size: var(--text-body-sm); font-weight: 500; min-width: 0; }
.rail-link:hover { background: var(--surface-soft); color: var(--ink); }
.rail-link:focus-visible { outline: none; box-shadow: var(--focus-ring); }
.rail-link[aria-current="true"] { background: var(--surface-soft); color: var(--ink);
  box-shadow: inset 2px 0 0 0 var(--accent); }
.rail-link-name { flex: 1 1 auto; min-width: 0; overflow: hidden;
  text-overflow: ellipsis; white-space: nowrap; }
.rail-link-meta { font-family: var(--font-mono); font-size: var(--text-caption);
  color: var(--ink-mute); }
.rail-led { flex: 0 0 7px; width: 7px; height: 7px; border-radius: var(--radius-pill);
  background: var(--ink-faint); }
.rail-led--run   { background: var(--ok); }
.rail-led--retry { background: var(--warn); }
.rail-led--paused{ background: transparent; box-shadow: inset 0 0 0 1.5px var(--warn); }
.rail-led--idle, .rail-led--done { background: var(--ink-faint); }
.rail-foot { margin-top: auto; display: flex; flex-direction: column; gap: var(--space-2);
  border-top: 1px solid var(--line); padding-top: var(--space-3); }
```

Mode switch + theme toggle: keep the existing geometry-based CSS (no emoji), re-skinned as
squared segmented controls (`--radius-ctl`; active segment `background: var(--surface-deep);
color: var(--ink)` — no inverted ink block). The gear geometry on
`[data-drawer-toggle][aria-label="Settings"]` is kept. No `:target`-based highlight CSS —
`aria-current` is owned by RailNav only; without the hook, links simply have no persistent
highlight (accepted).

### 7.2 `RailNav` scroll-spy hook (graft 5 — optional, additive, ships last)

Registered in `layouts.ex` beside the other hooks; mounts on `#rail-nav`
(`phx-hook="RailNav"`). `IntersectionObserver` over `[id^="project-"], #completions-section,
#dashboard-top`; on intersection change set `aria-current="true"` on the `.rail-link` whose
`href` suffix matches, remove it from others; re-apply on `updated()`; disconnect on
`destroyed()`. ~30 lines, no server round-trips. Everything works without it.

### 7.3 Settings console (drawer)

Mechanism unchanged: `.settings-drawer` class, `html[data-drawer="open"]`, right-side slide,
OverlayDismiss outside-click, all form ids/events, group order (Experience → Linear →
Projects → Automation/Orchestrator → Display). New: real scrim + Esc-to-close + titled-card
anatomy.

```css
.settings-drawer {
  position: fixed; top: 0; right: 0; height: 100dvh;
  width: min(408px, 100vw);
  transform: translateX(100%); transition: transform var(--dur-mid) var(--ease);
  z-index: var(--z-drawer); overflow-y: auto;
  padding: 0 var(--space-4) var(--space-6);
  background: var(--surface); border-left: 1px solid var(--line-strong);
  box-shadow: none;
}
html[data-drawer="open"] .settings-drawer { transform: translateX(0);
  box-shadow: var(--shadow-pop); }

/* Scrim: body::after needs no template change and — being a real element box —
   intercepts clicks. The click target becomes <body>, which OverlayDismiss treats
   as "outside": drawer closes, nothing underneath is activated. */
html[data-drawer="open"] body::after {
  content: ""; position: fixed; inset: 0; z-index: var(--z-scrim);
  background: rgba(0, 0, 0, 0.35);
  animation: scrim-in var(--dur-mid) var(--ease) both;
}
@keyframes scrim-in { from { opacity: 0 } to { opacity: 1 } }

.settings-drawer-header {
  position: sticky; top: 0; z-index: 2;
  display: flex; align-items: center; justify-content: space-between;
  margin: 0 calc(-1 * var(--space-4)); padding: var(--space-3) var(--space-4);
  background: var(--surface); border-bottom: 1px solid var(--line);
}
.settings-drawer-title { margin: 0; font-size: var(--text-subhead); font-weight: 600;
  letter-spacing: var(--tracking-h2); }
.settings-group {
  margin-top: var(--space-3); padding: var(--space-3);
  border: 1px solid var(--line); border-radius: var(--radius-row);
  background: var(--surface-soft);
  display: flex; flex-direction: column; gap: var(--space-2);
}
.settings-group--mode { background: none; border: 0; padding: var(--space-3) 0 0; }
.settings-group-title {
  display: flex; align-items: center; flex-wrap: wrap; gap: 6px 8px; margin: 0;
  font-size: var(--text-micro); font-weight: 600; color: var(--ink-mute);
  letter-spacing: var(--tracking-label); text-transform: uppercase;
}
.settings-help { max-width: 46ch; margin: 0; color: var(--ink-mute);
  font-size: var(--text-caption); line-height: 1.5; }
```

Console anatomy:
- **Linear**: `.linear-status--connected` = green tag (`--ok` on `--ok-soft`, `--radius-tag`);
  key mask mono mute. Connect form on one row; Connect = accent button. Never render the raw
  key.
- **Projects**: slug combobox full-width; name/github two-up grid kept; advanced
  agent/model/effort/provider grid kept (`#add-project-provider` visibility assign-driven,
  unchanged); Add project = accent button full-width.
- **Automation/Orchestrator**: Pause all (quiet) / Resume all (accent) first, then
  concurrency and refresh-interval rows, **each with one `.settings-help` line**. Required
  copy under refresh: *"Refresh (s): how often this dashboard re-reads orchestrator state —
  not Linear polling."* (directly answers operator complaint #2's confusion).
- **Display**: density radios, section/column checkboxes, completions-limit select as aligned
  rows; native controls get `accent-color: var(--accent);` (graft). Mechanism untouched.

**Esc closes the console** — small delegated snippet in `layouts.ex` (not a hook):

```js
document.addEventListener('keydown', function(e) {
  if (e.key === 'Escape' &&
      document.documentElement.getAttribute('data-drawer') === 'open') {
    document.documentElement.removeAttribute('data-drawer');
  }
});
```

### 7.4 Button system

`.subtle-button` stays the workhorse; squared, three variants. Base `button` element rule
drops the pill radius too.

```css
button, .subtle-button {
  appearance: none; display: inline-flex; align-items: center; justify-content: center;
  gap: 6px; height: var(--ctl-h); padding: 0 10px;
  background: transparent; border: 1px solid var(--line-strong);
  border-radius: var(--radius-ctl);
  color: var(--ink-soft); font: inherit; font-size: var(--text-body-sm); font-weight: 500;
  cursor: pointer;
  transition: background-color var(--dur-fast) var(--ease),
              border-color var(--dur-fast) var(--ease), color var(--dur-fast) var(--ease),
              box-shadow var(--dur-fast) var(--ease);
}
.subtle-button:hover { background: var(--surface-soft); color: var(--ink); }
.subtle-button:focus-visible { outline: none; box-shadow: var(--focus-ring); }
.subtle-button--accent {      /* Connect, Pin, Resume all, Add project */
  background: var(--accent); border-color: var(--accent); color: var(--accent-ink);
  font-weight: 600;
}
.subtle-button--accent:hover { background: var(--accent-strong);
  border-color: var(--accent-strong); }
.subtle-button.danger {        /* Kill / Stop */
  background: transparent; border-color: color-mix(in srgb, var(--danger) 40%, transparent);
  color: var(--danger);
}
.subtle-button.danger:hover { background: var(--danger-soft); border-color: var(--danger); }
```

Restart submit stays a **quiet** button (it kills a session; not accent). Copy buttons keep
their inline `onclick` clipboard behavior and `data-label`/`data-copy`.

### 7.5 Field system

One field look everywhere (header toolbar, restart form, queue edit, console):

```css
.inline-form { display: inline-flex; align-items: center; gap: 6px;
  padding: 0; background: none; border: 0; border-radius: 0; }
.inline-label { color: var(--ink-mute); font-size: var(--text-micro); font-weight: 600;
  letter-spacing: var(--tracking-label); text-transform: uppercase;
  font-family: var(--font-sans); }
.inline-input, select, .settings-field:not([type="hidden"]) {
  height: var(--ctl-h);
  background: var(--surface-deep); border: 1px solid var(--line-strong);
  border-radius: var(--radius-ctl); color: var(--ink); caret-color: var(--ink);
  font: inherit; font-size: var(--text-body-sm); font-family: var(--font-mono);
  padding: 0 8px;
}
.inline-input--narrow { width: 52px; text-align: center; font-variant-numeric: tabular-nums; }
.inline-input:focus, select:focus, .settings-field:focus {
  outline: none; border-color: var(--accent); box-shadow: var(--focus-ring);
}
select { appearance: none; -webkit-appearance: none;
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='8' height='5' viewBox='0 0 8 5'><path fill='%237A808A' d='M0 0h8L4 5z'/></svg>");
  background-repeat: no-repeat; background-position: right 8px center;
  padding-right: 24px; cursor: pointer; }
```

Delete the old pill `.inline-form` chrome and its `:focus-within` ring — focus lives on the
field. Keep every `input[type=hidden]` suppression rule. Implementer verifies the drawer
selects render the custom arrow correctly in Safari + Chrome.

### 7.6 Combobox

Trigger = field chrome; panel = L4 overlay; options mono. All classes, ARIA, and hidden-input
mechanics untouched; keep `.combobox.combobox--open { z-index: var(--z-combobox); }`
(test-pinned), the `[hidden]` rules, and every contextual sizing rule (drawer vs inline vs
queue-edit) ported to the new chrome.

```css
.combobox-trigger { min-height: var(--ctl-h); width: 100%; padding: 0 26px 0 8px;
  background: var(--surface-deep); border: 1px solid var(--line-strong);
  border-radius: var(--radius-ctl); color: var(--ink);
  font-size: var(--text-body-sm); font-family: var(--font-mono); text-align: left;
  cursor: pointer; }
.combobox-trigger--empty .combobox-trigger-label { color: var(--ink-mute); }
.combobox-trigger:focus-visible, .combobox-trigger:focus { outline: none;
  border-color: var(--accent); box-shadow: var(--focus-ring); }
.combobox-panel { position: absolute; top: calc(100% + 4px); left: 0; right: 0;
  z-index: var(--z-combobox); display: flex; flex-direction: column; gap: 6px; padding: 6px;
  background: var(--surface); border: 1px solid var(--line-strong);
  border-radius: var(--radius-card); box-shadow: var(--shadow-pop); }
.combobox-search { height: var(--ctl-h); background: var(--surface-deep);
  border: 1px solid var(--line-strong); border-radius: var(--radius-ctl);
  padding: 0 8px; font-family: var(--font-mono); font-size: var(--text-body-sm); }
.combobox-list [role="option"] { padding: 6px 8px; border-radius: var(--radius-tag);
  cursor: pointer; font-family: var(--font-mono); font-size: var(--text-body-sm);
  line-height: 1.4; }
.combobox-list [role="option"]:hover,
.combobox-list [role="option"][aria-selected="true"] {
  background: var(--accent-soft); color: var(--ink);
  box-shadow: inset 2px 0 0 0 var(--accent);
}
/* CSS-only "no matches" hint (harmless where :has unsupported) */
.combobox-list:not(:has([role="option"]:not([hidden])))::after {
  content: "no matches"; display: block; padding: 6px 8px;
  color: var(--ink-mute); font-size: var(--text-caption);
}
```

### 7.7 Expanded session detail, harness, log wells

```css
.session-row-detail { border-top: 1px solid var(--line); padding: var(--space-3);
  display: flex; flex-direction: column; gap: var(--space-3);
  animation: detail-fade var(--dur-mid) var(--ease) both; }
@keyframes detail-fade { from { opacity: 0; transform: translateY(-3px) }
                         to   { opacity: 1; transform: translateY(0) } }
.session-row-detail-grid { display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: var(--space-3) var(--space-4); }
.session-stat-label { font-size: var(--text-micro); font-weight: 600;
  color: var(--ink-mute); letter-spacing: var(--tracking-label);
  text-transform: uppercase; }
.session-stat-value { font-size: var(--text-body-sm); color: var(--ink);
  font-family: var(--font-mono); display: flex; flex-wrap: wrap; gap: 6px;
  align-items: center; }
.workspace-path { font-family: var(--font-mono); font-size: var(--text-caption);
  color: var(--ink-soft); word-break: break-all; }
.session-row-activity { display: inline-flex; align-items: center; gap: var(--space-2);
  flex-wrap: wrap; font-size: var(--text-body-sm); padding: var(--space-2) var(--space-3);
  background: var(--surface-deep); border-radius: var(--radius-row); }
.autonomy-note { margin: 0; max-width: 68ch; padding: var(--space-2) var(--space-3);
  border-left: 2px solid var(--ok); border-radius: 0 var(--radius-row) var(--radius-row) 0;
  background: var(--ok-soft); color: var(--ink-soft); font-size: var(--text-body-sm); }
```

Terminal wells (identical in both themes by token construction):

```css
.harness-tail { margin-top: var(--space-2); border: 1px solid var(--line);
  border-radius: var(--radius-row); background: var(--surface-well); overflow: hidden; }
.harness-tail-header { display: flex; justify-content: space-between; align-items: center;
  padding: 4px 8px; background: color-mix(in srgb, var(--surface-well) 70%, #FFFFFF 4%);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06); }
.harness-tail-title { font-size: var(--text-micro); font-weight: 600;
  letter-spacing: var(--tracking-label); text-transform: uppercase; color: var(--well-ink);
  display: inline-flex; align-items: center; gap: 6px; }
.harness-tail-title::before { content: ""; width: 6px; height: 6px;
  border-radius: var(--radius-pill); background: var(--ok); }
.harness-tail[data-follow="false"] .harness-tail-title::before { background: var(--ink-faint); }
.harness-tail-header .subtle-button { height: 22px; padding: 0 8px;
  font-size: var(--text-micro); color: var(--well-ink);
  border-color: rgba(255, 255, 255, 0.14); background: transparent; }
.harness-tail-body { max-height: 20rem; overflow: auto; margin: 0; padding: var(--space-2);
  font-family: var(--font-mono); font-size: 11px; line-height: 1.45;
  white-space: pre-wrap; word-break: break-word; color: var(--well-ink);
  overscroll-behavior: contain;
  scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.18) transparent; }
.harness-tail-body::-webkit-scrollbar { width: 8px; }
.harness-tail-body::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.14);
  border-radius: 4px; }
.log-list { list-style: none; margin: 0; padding: var(--space-2);
  font-family: var(--font-mono); font-size: var(--text-caption);
  background: var(--surface-well); color: var(--well-ink);
  border: 1px solid var(--line); border-radius: var(--radius-row);
  max-height: 18rem; overflow-y: auto;
  scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.18) transparent; }
.log-event { display: grid; grid-template-columns: 158px auto minmax(0, 1fr);
  gap: var(--space-2); align-items: baseline; padding: 2px 0; line-height: 1.5; }
.log-event-at { color: rgba(201, 205, 211, 0.5); white-space: nowrap; }
.log-event-name { border: 0; background: none; padding: 0; border-radius: 0;
  font-size: 10px; font-weight: 600; letter-spacing: var(--tracking-label);
  text-transform: uppercase; color: rgba(201, 205, 211, 0.7); }
.log-event-danger  { color: var(--danger); background: none; border: 0; }
.log-event-success { color: var(--ok); background: none; border: 0; }
.log-event-accent  { color: var(--accent); background: none; border: 0; }
.log-event-message { color: var(--well-ink); word-break: break-word; min-width: 0; }
```

### 7.8 Recent completions — the ledger

`.section-card` panel with `id="completions-section"`. Header micro-label + count; the
collapse toggle keeps the `data-collapse-toggle` mechanism — the layout script rewrites its
textContent to `▸`/`▾` and sets `aria-expanded`, so **hide the glyph and draw the chevron**
(no JS change): `[data-collapse-toggle] { font-size: 0; }` + the §6.6 chevron `::before`,
rotation keyed off `[aria-expanded="false"]`. Rows reuse the session grid; completed variance
(graft 8 — zebra + ok-dot, no ghost rows):

```css
.session-row--completed { opacity: 1; }
.session-row--completed:nth-child(odd) { background: rgba(232, 234, 237, 0.015); }
.session-row--completed .session-row-id { color: var(--ink-soft); }
.session-row--completed .session-row-disclosure { font-size: 0; position: relative;
  pointer-events: none; }
.session-row--completed .session-row-disclosure::before {
  content: ""; position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
  border: 0; width: 6px; height: 6px; border-radius: var(--radius-pill);
  background: var(--ok); opacity: 0.6;
}
.session-row--completed:hover { background: var(--surface-soft); }
```

("✓" span text stays in the template; `font-size: 0` hides it.) The light-theme zebra
override uses `rgba(23, 25, 28, 0.02)`. Ended-at stays static mute mono (no clock anchor —
correct). `data-completions-limit` nth-child rules copied verbatim.

### 7.9 Chips → tags

Flat mono tags — text-colored states, no filled pills. Class names kept (pinned strings
included).

```css
.chip {
  display: inline-flex; align-items: center; gap: 4px;
  padding: 1px 6px; border-radius: var(--radius-tag);
  border: 1px solid var(--line); background: transparent; color: var(--ink-soft);
  font-family: var(--font-mono); font-size: var(--text-micro); font-weight: 600;
  letter-spacing: 0.02em; white-space: nowrap; line-height: 1.5;
}
.chip--ok     { color: var(--ok);     border-color: color-mix(in srgb, var(--ok) 35%, transparent); }
.chip--warn   { color: var(--warn);   border-color: color-mix(in srgb, var(--warn) 35%, transparent); }
.chip--danger { color: var(--danger); border-color: color-mix(in srgb, var(--danger) 40%, transparent);
                background: var(--danger-soft); }   /* Stalled must pop */
.chip--accent { color: var(--ink);    border-color: var(--line-strong); }  /* provider = data: NEUTRAL (resolved) */
.chip--agent  { color: var(--ink);    border-color: var(--line-strong); }
.chip--muted  { color: var(--ink-mute); }
.chip--truncate { max-width: 140px; overflow: hidden; text-overflow: ellipsis; }
```

**Resolved ambiguity**: `.chip--accent` (provider) renders **neutral** — provider is data,
not interaction; visual accent is reserved for the NEXT badge and interactive states. The
class name survives because a test pins the attribute string.

---

## 8. Empty / error / loading / degraded states

- **Fleet empty** (`@projects == []`, no `@payload_error`): designed `.fleet-empty
  section-card` — micro-label "NO PROJECTS", one sentence ("Connect Linear and add your first
  project."), and an accent button `[data-drawer-toggle]` labeled "Open settings".
- **Project idle**: existing `.empty-state` copy kept (simple/advanced variants). Restyle
  with a breathing accent dot (graft 7):

```css
.empty-state { margin: var(--space-2) 0 0; color: var(--ink-mute);
  font-size: var(--text-body-sm); display: flex; align-items: center; gap: var(--space-2); }
.empty-state::before { content: ""; flex: 0 0 6px; width: 6px; height: 6px;
  border-radius: var(--radius-pill); background: var(--accent); opacity: 0.5;
  animation: led-breathe 3.2s var(--ease) infinite; }
```

- **Queue empty**: board hidden entirely (contract).
- **Snapshot unavailable**: `.error-card` (§6.8); rail and top strip still render — the shell
  never blanks; the band is inside the `unless @payload_error` guard as today; the rail
  vitals block hides via its own `unless`.
- **Loading**: `@default_payload` zeros render; transport badge reads "Connecting". No
  skeletons.
- **Transport loss (graft 2)**: an always-present `div.reconnect-note` rendered directly
  under `</header>` in `.main-col`:

```heex
<div class="reconnect-note" role="status">Connection lost — reconnecting…</div>
```

```css
.reconnect-note { display: none; }
[data-phx-main].phx-error .reconnect-note {
  display: flex; align-items: center; gap: var(--space-2);
  padding: 6px var(--space-4); background: var(--surface);
  border: 1px solid var(--line); border-radius: var(--radius-row);
  box-shadow: inset 2px 0 0 0 var(--warn);
  color: var(--ink); font-size: var(--text-body-sm);
}
[data-phx-main].phx-error .main-col > :not(.command-bar):not(.reconnect-note) {
  opacity: 0.6; transition: opacity var(--dur-slow) var(--ease) 1s;  /* grace period */
}
```

- **No-JS**: rail anchors work; clocks freeze at server-rendered values; theme/mode/prefs
  inert; drawer cannot open (unchanged); comboboxes degrade to hidden-input + trigger;
  scrim never appears. System-light OS now gets light theme via the §2.2 media block.

---

## 9. Interaction & motion

Principle: **nothing moves unless the operator moved it or the fleet changed state.** An idle
dashboard is a still image (the calm-dashboard contract also demands this at the DOM level).

| Interaction | Motion | Duration/ease |
|---|---|---|
| Hover (rows, cells, links, buttons) | background/color only, no transform | `--dur-fast` / `--ease` |
| Focus | ring appears instantly | none |
| Row expand / queue edit open | `detail-fade` (opacity + 3px rise) | `--dur-mid` / `--ease` |
| Console open/close | slide + scrim fade | `--dur-mid` / `--ease` |
| Combobox panel | none — precision tools snap | — |
| Queue drag pick | ghost scale 1.0→1.02, source dims 0.35 | `--dur-fast` |
| Queue reorder | FLIP translate (hook-owned, reads `--dur-flip`) | `--dur-flip` / `--ease` |
| Queue drop | ghost settles/fades (hook-owned) | `--dur-mid` / `--ease-spring` |
| Live LED / follow LED / empty-state dot | `led-breathe` opacity loop | 2.4s / 3.2s |
| Toast in | translateY(8px) + fade | `--dur-mid` / `--ease` |
| Clock text | textContent swap by LiveClock, no transition | 1s tick |

Reduced motion: keep the existing global kill-switch block verbatim
(`@media (prefers-reduced-motion: reduce) { *, *::before, *::after { … 0.001ms !important … } }`)
— it also stops `led-breathe`, `scrim-in`, `toast-in`; add `html { scroll-behavior: auto }`
inside it; the QueueBoard hook's own reduced-motion path stays.

**Anti-churn rules (operator complaints #1 and #3 — non-negotiable):**
- No CSS `animation` on any element whose text a payload load rewrites; never animate
  width/height/layout of data cells.
- Any new time display must be a `data-clock` span or a static timestamp. This design adds
  none.
- The rail reads only existing per-section assigns and never `@now`.
- Hover/open/active chrome is client-side class toggling or CSS — never a server assign that
  re-renders on payload load.
- Acceptance stays: an idle board ships no per-second DOM diff.

---

## 10. Responsive behavior + density

Breakpoints: **1200 / 900 / 640** (replace the current 960/720/560/1100 set; port every
existing narrow-width rule onto the new set — do not drop any behavior).

- **≥1200**: full rail (232px), band single row, queue 4-up, session grid full.
- **900–1199**: rail condenses to `--rail-w-mid` (64px): hide `.brand-wordmark`,
  `.version-badge`, `.rail-vitals`, `.rail-link-name` (width 0, overflow hidden — the
  `title` attr provides tooltips), `.rail-link-meta`, `.rail-group-label`, mode-switch and
  Refresh text; LEDs and icon-geometry foot buttons remain. Queue 2-up. Band wraps
  naturally (flex-wrap).
- **<900**: `grid-template-columns: 1fr`; `.side-rail { display: none }`; top strip regains
  brand + `.topbar-only-narrow` mode/theme cluster + a native project jump menu:
  `<details class="jump-menu"><summary>Projects</summary><nav>…same anchors…</nav></details>`
  (no JS). Session rows wrap: `[chevron][id][title]` line 1; chips/runtime/tokens flow to
  line 2 (`flex-wrap: wrap`; runtime/tokens lose fixed basis, left-align);
  `.session-grid-head { display: none }`. Queue 1–2-up.
- **<640**: band cells two-up (`.metric-pill { flex: 1 1 45%; border-left: 0 }`); console
  full-width (`width: 100vw`); toolbar forms stack full-width; version badge hidden; toasts
  full-width bottom.

Density (`html[data-density="compact"]`): token override `html[data-density="compact"]
{ --ctl-h: 26px; }` shrinks all controls consistently; row vertical padding 6→3px; band cell
padding to 6px and `.metric-pill-value { font-size: 20px }`; panel padding `--space-3`; queue
card padding 6px; rail link padding 5px.

Hidden sections/columns/completions-limit/collapse: all existing `html[data-hidden-*]`,
`html[data-collapsed-sections]`, `html[data-expanded-sections]`, `html[data-completions-limit]`
rules carry over verbatim (§1.3 pins several); grid-head hiding comes free via shared column
classes (§6.6). The rail is chrome, not a section — it is not hideable.

---

## 11. Accessibility

- Contrast per §2.3; state colors never the sole signal (LED + word, edge + label).
- `--focus-ring` on every interactive element, including queue cards (`tabindex="0"` kept)
  and rail links.
- Landmarks: `nav.side-rail[aria-label]`, `header.command-bar`,
  `aside.settings-drawer[aria-label]`; jump menu is a `nav` inside `details`.
- Keep `aria-live="polite"` on the autonomy row and the toast stack; no live region on the
  band (it would announce every refresh).
- Hit targets ≥30px (26px in compact — operator-chosen density).
- All hook-owned ARIA (`aria-expanded`, `aria-pressed`, `aria-activedescendant`,
  `role=listbox/option/group`) unchanged.

---

## 12. Light theme QA checklist (run in both themes × both densities × both modes)

- [ ] Band values legible; hairline dividers visible but quiet; signature rule visible.
- [ ] Queue NEXT edge + badge visible on `--surface-soft`.
- [ ] Session run-LED green distinguishable from the "Done" tag context.
- [ ] Retry amber edge visible on the white panel.
- [ ] Console groups separate from drawer background; scrim visible.
- [ ] Focus ring visible on every control (full tab pass).
- [ ] `prefers-color-scheme: light` + no `data-theme` renders the light block (new).
- [ ] Explicit `data-theme="dark"` on a light OS stays dark.
- [ ] Wells stay dark in light mode; `--well-ink` legible.
- [ ] Completions zebra visible but subliminal in both themes.

---

## 13. Implementation split — Part A / Part B

Rewrite `priv/static/dashboard.css` as one file with numbered section banners; each part owns
whole sections. Both parts: `make all` green (fmt, credo --strict, specs.check, coverage —
web modules are coverage-ignored; **no new non-web modules**; new defps are private, no
@spec needed — dialyzer). Never delete a failing test — repin it. Regexes via
`Regex.compile!/1` only. Whichever part lands last reconciles CLAUDE.md + SPEC.md.

### Part A — tokens, shell, top strip, band, project/queue/session/retry, toasts

CSS sections: `01-tokens` (complete §2.1 dark + §2.2 light + media duplicate — **both themes
ship in A with final values**), `02-base/reset`, `03-shell` (grid, `.side-rail` container,
`.main-col`), `04-topbar`, `05-instrument-band`, `06-alerts/error/toast/reconnect`,
`07-project-section`, `08-queue-board`, `09-session-grid`, `10-retry-rows`,
`18-responsive-shell`, `19-reduced-motion` (verbatim + scroll-behavior), `20-density`.

Template (`dashboard_live.ex`): shell restructure (§5.2); rail **skeleton** (brand +
`<%!-- PART B: rail vitals --%>` / `<%!-- PART B: rail nav --%>` / `<%!-- PART B: rail foot --%>`
markers); band move out of `<header>` with pinned class strings byte-identical;
`session-grid-head`; disclosure glyph removal (§6.6); `data-rank-label`; project section ids
+ `project_dom_id/1`; `#dashboard-top`; `#completions-section`; `reconnect-note`;
`toast-stack` move (§6.9).

Tests: keep every §1.3 string true (grep before commit); update any `dashboard_live_test.exs`
assertion touched by the flash move / disclosure glyphs; add assertions: `.side-rail`
present, `#dashboard-top`, a project section id, grid head in advanced HTML,
`.toast-stack` contains the flash.

### Part B — rail content, settings console, controls, detail/harness/completions, states

CSS sections: `11-buttons`, `12-fields`, `13-combobox`, `14-chips/tags`, `15-console`
(drawer + scrim + groups), `16-detail/harness/log`, `17-completions`, `21-rail-content`,
`22-polish` (scrollbars, `::selection { background: var(--accent-soft) }`, fleet-empty,
jump-menu, empty-state).

Template: rail vitals + nav + foot (§7.1, `rail_state/1`), narrow-topbar brand/jump-menu +
`.topbar-only-narrow` cluster, console group anatomy + help copy (incl. the refresh-vs-polling
sentence), fleet-empty block, `title` attrs for the condensed rail.

`layouts.ex`: Esc-to-close snippet (§7.3); `RailNav` hook **last** (§7.2) — everything works
without it.

Tests: rail link/LED rendering (running/paused/retrying fixtures), rail vitals numbers,
fleet-empty when no projects, console help copy present, light-theme CSS assertions
(`[data-theme="light"]` and `@media (prefers-color-scheme: light)` present in served CSS).

### Sequencing

A lands first (B's fields/buttons reference A's tokens; A ships final tokens for both
themes). If parallel: B branches from A's `01-tokens` commit; merge conflicts are confined to
the marked rail region of `dashboard_live.ex` and CSS section banners.

---

## 14. Acceptance checklist

- [ ] Zero purple anywhere; a grayscale screenshot is near-identical except LEDs, state
      edges, and the accent (brand mark, NEXT badge, focus, primary buttons, signature rule).
- [ ] Accent appears only on: focus rings, primary buttons, NEXT badge/edge, active/hover
      combobox option, brand mark, expanded-row chevron, `log-event-accent`, empty-state dot,
      band signature rule, rail `aria-current` spine, selection.
- [ ] All §1.1–§1.4 selectors/ids/attribute strings intact (grep before commit); the queue
      card contains no "chip" substring; `command-bar-row--ops` does not exist.
- [ ] Idle dashboard ships no per-second DOM mutations (MutationObserver probe from the
      calm-dashboard spec); combobox stays open across a payload refresh while focused.
- [ ] Every clock span keeps its `data-clock` anchor; no new `@now` readers outside
      `@clock_sections`; the rail renders from section assigns only.
- [ ] Session rows: runtime/tokens right-aligned and vertically aligned across rows; header
      row hides with its columns; hidden-cols leaves no holes.
- [ ] Rail: sticky, scrollable, LEDs correct (run/retry/paused/idle), vitals correct, anchors
      land below the sticky strip; 64px condensed mode usable.
- [ ] Console: scrim + slide + Esc + outside-click all close it; scrim intercepts clicks
      (nothing underneath activates); all forms submit as before.
- [ ] Flashes appear as toasts without shifting the board; stalled alert stays in flow.
- [ ] Both themes, both densities, both modes, 1440/1100/840/390px — no overflow, no clipped
      combobox panels (z-order per pinned rules).
- [ ] Reduced motion: no LED breathing, no FLIP, instant drawer, no smooth scroll.
- [ ] No-JS: readable page (dark, or OS-light via media block), anchors navigate, forms
      render, no scrim.
- [ ] `make all` green; CLAUDE.md "Web Dashboard" + SPEC.md updated for: rail (brand/mode/
      theme at wide widths), instrument band, toasts, reconnect note, console scrim + Esc,
      system theme following the OS, new breakpoints. "Refresh behavior" prose untouched.
