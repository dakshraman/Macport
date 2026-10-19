# Macport — UI/UX Specification

**Version** 1.0 — design proposal, pre-implementation
**Target** macOS 27 · SwiftUI · native window chrome, both appearances first-class
**Covers** the `Macport.app` experience and how it presents the engine layer. Command-line
parity (`macportctl`) is noted where the two must agree.
**Visual preview** `docs/design/macport-ui.html` (open in a browser; light/dark switch included).

---

## 0. What this document is for

The engine layer is already built and honest: two engines, a declared capability matrix, a
vendored runtime. This document decides what the user *sees* of that, screen by screen, before
a line of view code is written — so that the SwiftUI implementation is transcription, not
invention.

Tokens are in §3. Component inventory is §5. Screens are §6. Everything that is deliberately
not being built is in §12 with its reason.

---

## 1. Principles

1. **The truth is on screen.** Every limit an engine declares — no optical device, no vTPM, no
   snapshots — is visible *before* it can cost the user anything: before the 8 GB download,
   before the install, before the failure. Macport's whole claim is that it does not hide
   hypervisor reality behind a friendly lie.
2. **The engine is a first-class noun.** Routing differs per guest — a Windows guest cannot run
   on Virtualization.framework at all — so the engine gets a name, a version, a chip on every
   row, and its own card in the dashboard. Nobody debugs a virtualisation problem without
   knowing which hypervisor they are on.
3. **Macport owns its dependencies.** QEMU is never the user's problem. It is installed,
   verified and repaired by the app, and it has a home in the interface rather than a
   support article.
4. **Failures live in the product, not in alerts.** An operational error produces a *Problem*
   card carrying the log line that caused it and the action that resolves it. Modal alerts are
   reserved for irreversible choices — nothing else.
5. **Native by construction.** System fonts, system materials, system controls, standard menu
   bar and keyboard shortcuts. No custom chrome, no bespoke scrollbars, no emoji as icons.
6. **Calm density.** This is a professional instrument: 13 pt body, 8 pt grid, compact rows.
   Nothing decorative; everything informative. Motion explains state changes and nothing else.

---

## 2. The product model the UI must express

| Concept | What the user needs to understand | Where it is expressed |
|---|---|---|
| **VM bundle** | A machine is one folder (`.macport`) holding disk, firmware store and config. Portable, self-contained, movable. | Storage card; Reveal in Finder; create flow location row |
| **Engine** | Chosen per guest; each has different capabilities. | Engine chip (everywhere), Engine card, create flow step 1 |
| **Capabilities** | What this engine can and cannot do *for this guest*, and what that means. | Engine card capability chips; create review step |
| **Runtime** | QEMU is a Macport-managed component with a version, a size and a state. | Sidebar footer status; Runtime panel; create/start pre-flight |
| **State** | Off / starting / running / paused / stopping / error — with a reason when it ends badly. | State pill, sidebar dot, toolbar, console bar |
| **One at a time (v1)** | Starting a machine while another runs is a *choice*, not an error. | Start action when busy → "Shut down X and start Y" |

### 2.1 State vocabulary

Use these words consistently in every surface. `VMState` already models all of them except
`off`, which is the user-facing name for `.stopped`.

| `VMState` | Label | Pill tint | Primary action shown |
|---|---|---|---|
| `.stopped` | **Off** | neutral | Start |
| `.starting` | **Starting…** | accent, animated | Cancel |
| `.running` | **Running** | running green | Shut Down *(menu: Force Off, Pause)* |
| `.pausing` / `.paused` | **Paused** | paused amber | Resume |
| `.stopping` | **Stopping…** | accent, animated | Force Off |
| `.error` | **Stopped with errors** | error red | Start; Problem card revealed |

---

## 3. Visual system

Native macOS appearance leads; the palette is a *system-adaptive* set of semantic tokens rather
than fixed colours, so light and dark are both first-class. Values below are the reference
values for the HTML preview and the SwiftUI colour assets.

### 3.1 Colour

Neutral base is slate, not pure grey — it reads as instrumentation rather than stationery. The
accent is a single **harbor teal**; it is deliberately not system blue (so Macport does not look
like a system dialog) and not green/amber/red (those three are load-bearing status colours).

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg.window` | `#ECEDF0` | `#0F1216` | window background behind cards |
| `bg.sidebar` | `rgba(246,246,248,.86)` + blur | `rgba(20,23,28,.80)` + blur | sidebar vibrancy |
| `bg.card` | `#FFFFFF` | `#171B21` | cards, panels |
| `bg.inset` | `#F3F4F7` | `#11151A` | wells: log view, drop zone, thumbnails |
| `border.subtle` | `rgba(0,0,0,.07)` | `rgba(255,255,255,.08)` | card edges, dividers |
| `border.strong` | `rgba(0,0,0,.14)` | `rgba(255,255,255,.16)` | focused wells, table rules |
| `text.primary` | `#1D1D20` | `#EDEFF2` | titles, values |
| `text.secondary` | `#5B5F66` | `#A4ABB6` | labels, descriptions |
| `text.tertiary` | `#8A8F98` | `#6E7681` | hints, disabled, metadata |
| `accent` | `#0E7C86` | `#35C0CC` | primary buttons, selection, focus ring, links |
| `accent.subtle` | `rgba(14,124,134,.12)` | `rgba(53,192,204,.16)` | selected row, accent-tinted chips |
| `state.running` | `#1E9E52` | `#3DDC84` | running dot, pill, capacity fills that are healthy |
| `state.paused` | `#B4690E` | `#E8A33D` | paused pill, warnings |
| `state.error` | `#D32F2F` | `#FF6B6B` | error pill, destructive text |
| `state.off` | `#8A8F98` | `#6E7681` | off dot, neutral pill |
| `danger.solid` | `#D32F2F` | `#E5484D` | destructive buttons (Force Off, Delete) |

Contrast: `text.primary` on `bg.card` is ≥ 12:1; `text.secondary` ≥ 4.9:1; `accent` on white
4.9:1, on `bg.window` 4.5:1. Status is never colour-only — every status carries a word
(§9).

**Guest identity hue.** Each guest gets one low-saturation hue used *only* in its avatar tile:
Linux `#B4690E` (amber), Windows `#1E5FA8` (blue), macOS `#5B5F66` (graphite). It must never
compete with the status palette, so it appears at ≤ 14 % tint on a neutral tile.

### 3.2 Typography

System stack only — SF Pro for interface, SF Mono for machine text. No bundled fonts.

| Role | Size / line | Weight | Face | Use |
|---|---|---|---|---|
| `display` | 28 / 34 | Semibold | SF Pro Display | VM name in dashboard header |
| `title` | 17 / 22 | Semibold | SF Pro Text | card titles, wizard step titles |
| `body` | 13 / 18 | Regular | SF Pro Text | descriptions, values |
| `label` | 13 / 18 | Medium | SF Pro Text | field labels, capability names |
| `callout` | 12 / 16 | Regular | SF Pro Text | secondary explanations, help text |
| `caption` | 11 / 13 | Regular | SF Pro Text | metadata, pill text, sidebar sub-line |
| `mono` | 12 / 16 | Regular | SF Mono | paths, versions, engine ids, logs, boot stages |
| `mono.small` | 11 / 15 | Regular | SF Mono | log body, manifest counts |

Rules: never below 11 pt. Machine facts (paths, versions, `usb-bot`, ISO names) are always
monospace — it is how the user knows the string is literal and copyable.

### 3.3 Space, radius, elevation, materials

- **Grid** 8 pt. Scale: 4, 8, 12, 16, 20, 24, 32. Card padding 16 (dense) / 20 (standard).
- **Radius** card 12, inset well 8, control 8, pill 999, avatar tile 16, console surface 10.
- **Elevation** two levels only: resting card `0 1px 2px rgba(0,0,0,.06)` (dark: none, border
  instead) and floating console bar `0 8px 24px rgba(0,0,0,.28)`.
- **Materials** sidebar and toolbar use system vibrancy; console overlay bar uses
  `.ultraThinMaterial`; nothing else is translucent. Translucency is reserved for chrome so
  content stays literal.
- **Iconography** SF Symbols only, `.regular` weight, 13–16 pt inline, 20 pt in cards, 28 pt in
  empty states. No symbol is used without either a text label or a `.help()` tooltip and an
  accessibility label.

### 3.4 Motion

| Event | Motion | Duration / curve |
|---|---|---|
| Row selection | background tint fades in | 150 ms ease-out |
| State pill change | crossfade + tint change | 200 ms ease-in-out |
| Running indicator | 2 s opacity pulse 1.0 → 0.55 (disabled under Reduce Motion) | 2 s linear, repeat |
| Card appearance on dashboard | opacity + 4 pt rise, staggered 30 ms | 220 ms ease-out |
| Wizard step change | horizontal slide | 220 ms ease-out (crossfade under Reduce Motion) |
| Console open | crossfade from dashboard | 200 ms |
| Busy actions (start/stop) | button swaps label to ProgressView + stage text | immediate |

No bounce, no spring overshoot, nothing longer than 250 ms except the running pulse.

---

## 4. Windows, navigation, chrome

### 4.1 Window model

| Window | Kind | Purpose |
|---|---|---|
| **Macport** | main window, 1200 × 780 default, min 960 × 620 | library + selected machine dashboard |
| **Console** | same window (detail pane) — *not* a separate window in v1 | live guest display for engines the app can embed (Virtualization.framework) |
| **Settings** | standard `Settings` scene, ⌘, | defaults, runtime, diagnostics |
| **Runtime panel** | sheet from sidebar footer / toolbar chip | install, verify, repair, reveal the vendored runtime |
| **Create / Edit** | sheet, 760 × 620 | four-step wizard (§6.6) |
| **Problem** | sheet | log tail + what happened + what to do |

QEMU-backed guests draw into QEMU's own window (the engine has no embeddable surface yet).
The dashboard shows a *console card* for that case — it names what is on screen, gives
**Bring to Front**, and states plainly that embedding is not available on this engine yet. See §12.

### 4.2 Main window structure

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ ●●●   [◧]   Macport            ⌕ Search     ● QEMU 11.1.2 ready     [＋ New VM]  │
├──────────────────────┬───────────────────────────────────────────────────────────┤
│ MACHINES             │  Ubuntu Test                            ● Running         │
│  ● Ubuntu Test       │                                                         │
│    Linux (ARM64)     │  [ console surface / poster ]      [Shut Down ▾] [⋯]     │
│  ○ Windows 11        │                                                         │
│    Windows 11 (Arm)  │  ┌─────────────────┐ ┌─────────────────┐               │
│  ○ macOS Ventura     │  │ Hardware        │ │ Engine          │               │
│    macOS             │  │ …capacity bars  │ │ …capability chips│              │
│                      │  └─────────────────┘ └─────────────────┘               │
│ ＋ New Virtual Mach… │  ┌─────────────────┐ ┌─────────────────┐               │
│                      │  │ Storage         │ │ Problem / Log   │               │
│ ──────────────────── │  └─────────────────┘ └─────────────────┘               │
│ ◉ QEMU 11.1.2 ready  │                                                         │
└──────────────────────┴───────────────────────────────────────────────────────────┘
```

### 4.3 Sidebar

- Width: min 232, ideal 268. `List(selection:)` with sidebar style — native selection,
  native drag-to-reorder is *not* offered (order is stable by name).
- Sections: **MACHINES** (all VMs, single flat list — running ones are *not* hoisted to a
  separate section; a jumping list is worse than a stable one, and the running dot plus
  toolbar state already answer "what is up?").
- **Row anatomy** (28 pt + 8 pt vertical padding): 8 pt status dot · name (13 pt, `lineLimit(1)`)
  · second line `Guest · Engine` (11 pt, tertiary, `lineLimit(1)`).
- Running row: dot in `state.running`, name weight unchanged, trailing 11 pt "Running" label in
  `state.running`. Never an animation on the row itself.
- Error row: dot in `state.error`; second line replaced by the short failure ("Stopped —
  firmware did not find bootable media").
- Context menu: Start / Shut Down, Show in Finder, Duplicate, Rename…, **Delete…**
  (Delete disabled while running, with the reason shown in the menu as a disabled item's help).
- Footer, pinned: `◉ QEMU 11.1.2 ready` / `◉ QEMU not installed` / `◉ Runtime needs repair` —
  a single 24 pt row, clickable, opens the Runtime panel. This is the only always-visible
  reference to the engine runtime; it never becomes a banner unless a *selected machine needs
  it*.
- Below footer: a `＋ New Virtual Machine…` row (also in the toolbar) — discoverability beats
  purity here.

### 4.4 Toolbar

Unified titlebar. Items, left to right: sidebar toggle (system) · title · flexible space ·
search field (filters the library by name/guest, ⌘F) · runtime status chip (icon + version,
click → Runtime panel) · primary **New VM**.

When a machine is selected, the toolbar *does not* duplicate dashboard actions (Start/Stop live
in the header where the machine is named). Toolbar carries library-level actions only.

### 4.5 First run with no machines

The empty state is onboarding, not a blank page (§6.1). Three things, in order of likelihood:
drop an ISO, create an empty machine, or check the runtime.

---

## 5. Component inventory

Each component lists anatomy, states, and rules. Names are canonical — use them in code
(`StatusPill`, `EngineChip`, `CapacityBar`, `CapabilityChip`, `InfoCard`, `ProblemCard`,
`RuntimeRow`, `ConsoleBar`, `StepIndicator`, `DropZone`, `KeyValueGrid`, `LogView`,
`ResourceSlider`, `NoticeBanner`, `GuestAvatar`).

### C1 `GuestAvatar`
Rounded 16 square, 44 pt (row: 28 pt). Neutral tile with ≤ 14 % guest hue tint and the guest's
SF Symbol in the hue. Linux `terminal`, Windows `square.grid.2x2`, macOS `apple.logo` — hmm,
use `apple.logo` only for macOS guests. Never a vendor logo image (licensing) and never an emoji.

### C2 `StatusPill`
Capsule, 22 pt tall, 11 pt medium label, tinted background at 12 % of the state colour, text in
the state colour at full strength (dark mode: text at 90 %). Always contains a word
(Off / Starting… / Running / Paused / Stopping… / Stopped with errors). Optional 6 pt leading
dot for `.starting`, `.running`, `.paused`. Never colour-only; never a bare dot.

### C3 `EngineChip`
Capsule, 18 pt tall, 11 pt label, `border.subtle` outline, neutral background, monospace label:
`VZ` or `QEMU`. `.help()` expands to the engine's full name and why it was chosen. Shown in the
library row's sub-line as *text* (not chip) to keep rows calm; shown as a chip in the dashboard
header, the create wizard's guest cards, and the Runtime panel.

### C4 `CapacityBar`
6 pt rounded bar, track `bg.inset`, fill in `accent` (or `state.paused` above 80 % of host,
`state.error` above 95 %). Optional host-share mode: two segments — this VM (accent) and other
VMs (tertiary) — against the host total. Label above: `Processors  6 of 12`; accessible value
"6 of 12 cores, 50 percent".

### C5 `CapabilityChip`
One line per capability, not a grid of icons: 16 pt SF Symbol (`checkmark.circle.fill`
`state.running` / `slash.circle.fill` `text.tertiary` / `exclamationmark.triangle.fill`
`state.paused`) · capability name (13 pt label) · verdict (13 pt secondary: "Supported",
"Not available", "Not exposed by Apple silicon") · optional `ⓘ` with the reason. Never a
checklist of unrelated features: only capabilities that change what the user can do for *this*
guest are listed, and each "Not available" carries a consequence ("Windows setup asks for a
TPM 2.0 device — Macport supplies the answer file automatically", §10).

### C6 `InfoCard`
`bg.card`, radius 12, 1 px `border.subtle`, padding 16, title row (13 pt semibold + optional
trailing action), body. Optional footer row separated by a divider (tertiary 11 pt). No
elevation beyond the resting shadow.

### C7 `ProblemCard`
Variant of `InfoCard` with `state.error` at 10 % background tint, `exclamationmark.triangle.fill`
leading the title, one-sentence summary, the last relevant log line in `mono.small`, and two
actions: **Copy details**, **Open log**. Never dismissible by itself — it disappears when the
condition is resolved.

### C8 `RuntimeRow`
Used in the sidebar footer and the Runtime panel: status dot · component name · version in
mono · trailing size ("167 MB"). States: `ready`, `not installed`, `installing` (with inline
`ProgressView` and current stage line), `needs repair` (verify failed → **Reinstall**).

### C9 `ConsoleBar`
Floating capsule over the console surface, bottom-centre, `.ultraThinMaterial`, appears on hover
and stays while the pointer is within 120 pt of the bottom edge (never auto-hides while
`.starting`). Contents: power menu (Shut Down / Force Off / Restart), pause, Send Ctrl+Alt+Del,
scaling menu (Fit / Actual Size / Zoom), screenshot, pop-out. Every item icon-only **plus**
tooltip and accessibility label.

### C10 `StepIndicator`
Four dots with labels, 11 pt, current step in `accent` with a 2 pt underline, completed steps
with `checkmark`. Fully keyboard reachable (⌘1–4 jumps to a step when its inputs are valid).

### C11 `DropZone`
`bg.inset` well, radius 8, dashed `border.strong` 1 px, 96 pt tall, centered `arrow.down.doc`
20 pt + "Drop an ISO or disk image here" (13 pt) + "or Choose File…" (link). States: idle,
hovering (accent border + 6 % accent fill), invalid (error border + one-line reason in
`state.error`: "That file is not a bootable image — expected .iso, .img, .qcow2 or .raw").

### C12 `KeyValueGrid`
Two-column label/value grid, 13 pt, label `text.secondary`, value `text.primary` (or `mono` for
literal strings), 16 pt column gap, 8 pt row gap. Used for Hardware, Storage, Networking.

### C13 `LogView`
`bg.inset`, radius 8, `mono.small`, 15 lines visible, monospace wrap, severity-coloured
leading markers via text not colour alone (`● ok` `▲ warn` `✕ error` `  info`), auto-scroll
pinned to bottom with a "Jump to end" affordance when the user scrolls up, **Copy** and
**Reveal** actions. No filter UI in v1.

### C14 `ResourceSlider`
Slider with an end-cap value in mono (`4 cores`, `8 GB`) and tick labels at meaningful stops
(cores: 2/4/6/8 = host cores; memory: 2/4/8/16 …). Dragging updates a host-share `CapacityBar`
live and, when the allocation would starve the host (< 2 GB free), shows an inline warning:
"The host would be left with 1.5 GB. macOS needs some too."

### C15 `NoticeBanner`
Full-width row inside the dashboard: 12 % tint, icon, one line of text, one action. Used for
exactly three conditions: runtime missing for the selected machine, VM created but never
started, and engine unavailable on this Mac. Nothing else becomes a banner.

### C16 `Table` (disk/machine lists)
Standard `Table` for the Settings → Advanced diagnostics list and for the review step of the
wizard. Row height 24, alternating background off, column headers 11 pt uppercase tertiary.

---

## 6. Screens

### S1 Library — first run (no machines)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ●●●   [◧]   Macport                    ⌕            ● Runtime not installed  │
├──────────────────────┬───────────────────────────────────────────────────────┤
│ MACHINES             │                                                       │
│                      │        ┌──────────────────────────────────────┐       │
│  (none yet)          │        │        ⤓  Drop an ISO here           │       │
│                      │        │    or  Choose File…                   │       │
│                      │        └──────────────────────────────────────┘       │
│ ＋ New Virtual Mach…  │        Macport runs ARM64 Linux and Windows 11       │
│                      │        on Arm at native CPU speed.                    │
│ ──────────────────── │                                                       │
│ ◉ Runtime not inst…  │        [ Create a machine from scratch ]              │
└──────────────────────┴───────────────────────────────────────────────────────┘
```

Rules: dropping an ISO starts the wizard at step 2 with the file already accepted and the guest
inferred from the image's volume label (`WINDOWS` → Windows 11 (Arm), `Ubuntu`/`*linux*` →
Linux ARM64). Inference is a *suggestion* with a visible "Change" affordance, never silent.
Footer line explains the product in one sentence; no feature list, no marketing.

### S2 Library — populated

Sidebar as §4.3; detail pane shows the selected machine's dashboard (§6.3). With nothing
selected, the pane shows the library summary: a compact `Table` of all machines (Name, Guest,
Engine, State, Memory, Disk used) — a pro-tool affordance for people with many VMs, and honest
about "no selection" rather than an illustration.

### S3 VM dashboard (machine off, the default state)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  ▣   Windows 11                     ● Off    QEMU      [   Start   ]  [⋯]    │
│      Windows 11 (Arm) · QEMU 11.1.2                                          │
├──────────────────────────────────────────────────────────────────────────────┤
│  ┌── Hardware ───────────┐ ┌── Engine — QEMU ──────────────────────────┐     │
│  │ Processors  6 of 12   │ │ QEMU 11.1.2 · vendored by Macport         │     │
│  │ ▓▓▓▓▓░░░░░            │ │ ┌ Optical boot media      Supported      │     │
│  │ Memory      6 of 8 GB │ │ └ Virtual TPM 2.0         Not available ⓘ│     │
│  │ ▓▓▓▓▓▓▓░░░            │ │ ┌ Snapshots               Not available  │     │
│  │ Disk        80 GB     │ │ ┌ Shared folders          Not available  │     │
│  │ ▓░░░░░░░░░ 12.4 GB    │ │ └ USB passthrough         Not available  │     │
│  └───────────────────────┘ │ ℹ Windows routes here because only an     │     │
│  ┌── Storage ────────────┐ │   optical device can boot its installer.  │     │
│  │ D2AD8E3C-….macport    │ └──────────────────────────────────────────┘     │
│  │ ~/Library/…/VMs       │ ┌── Install media ─────────────────────────┐     │
│  │ 12.4 GB on disk       │ │ Win11_25H2_…_Arm64_v2.iso  8.0 GB        │     │
│  │ [Reveal] [Show log]   │ │ [Eject]                    [Change…]       │     │
│  └───────────────────────┘ └──────────────────────────────────────────┘     │
│  ┌── Networking ─────────┐ ┌── Last activity ─────────────────────────┐     │
│  │ Shared (NAT)          │ │ ✕ 21:04:12  firmware did not find …      │     │
│  │ Guest IP  not detected│ │   Boot0001 … USB HARDDRIVE                │     │
│  │ [Change…]             │ │ [Copy details]  [Open full log]           │     │
│  └───────────────────────┘ └──────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────────────┘
```

Notes:
- Header: `GuestAvatar` 44 · name (display) · second line `Guest · Engine version` ·
  `StatusPill` · engine chip · primary action button (Start/Shut Down) · overflow `⋯`
  (Duplicate, Rename, Delete…, Copy diagnostics).
- Cards, in priority order: **Hardware** (capacity bars, disk used vs nominal), **Engine**
  (version, capability chips, routing rationale), **Storage** (bundle name, parent folder,
  size on disk, Reveal/Show log), **Install media** (attached ISO, size, Eject/Change — this
  is where the Windows install lives, and it stays visible until the disk boots on its own),
  **Networking**, **Last activity / Problem** (`ProblemCard` when `lastError != nil`, otherwise
  a compact last-3-lines log card).
- Layout: `LazyVGrid(columns: .adaptive(minimum: 340))`, 16 pt gutters, cards in the order
  above, 20 pt pane padding. Reading order is the priority order.
- Disabled-with-reason is a pattern: a disabled control always shows *why* via tooltip and
  inline `caption` (e.g. shared folders on QEMU: "Not available — this engine cannot expose
  host folders to the guest yet").

### S4 Console (running, engine can embed — Virtualization.framework)

The dashboard's header collapses to a 36 pt strip (avatar 20 · name · pill · engine chip ·
Shut Down ▾ · ⋯); the console surface fills the rest with a 1 px border and 10 pt radius, black
letterboxing. `ConsoleBar` floats bottom-centre. Nothing else is drawn over the guest.

States: `starting` shows the same strip with a centered `ProgressView` + stage text
("Waiting for firmware…", §7.2) rather than a blank black pane; `paused` dims the surface to
55 % with a centered "Paused" capsule and a Resume button; `error` returns to the dashboard
with the `ProblemCard` in focus.

### S5 Console (running, engine cannot embed — QEMU)

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  ▣   Windows 11                   ● Running   QEMU    [Shut Down ▾]  [⋯]      │
├──────────────────────────────────────────────────────────────────────────────┤
│      ┌────────────────────────────────────────────────────────────────┐      │
│      │  🖥  QEMU is showing this machine in its own window            │      │
│      │                                                                │      │
│      │  The guest console is drawn by the engine's own window, not    │      │
│      │  inside Macport.                                                │      │
│      │                                                                │      │
│      │  [ Bring to Front ]   [ Embed console — not available ] ⓘ      │      │
│      └────────────────────────────────────────────────────────────────┘      │
│   QEMU 11.1.2 feeds this window the same console a screen recording would see │
└──────────────────────────────────────────────────────────────────────────────┘
```

The disabled "Embed console" button carries a tooltip: "Embedding needs console capture, which
is not implemented for this engine. Tracked in ARCHITECTURE.md." Honest, and it makes the
limitation a visible product decision rather than a surprise. **Bring to Front** is implemented
with `NSRunningApplication`/window activation on the QEMU child process.

### S6 Create machine — four steps

Sheet 760 × 620; `StepIndicator` at top; footer: Cancel · Back · Continue / Create.

**Step 1 — What will you run?** Three selectable cards, each 1/3 width:

```
┌────────────────┐ ┌────────────────┐ ┌────────────────┐
│ ▣  terminal     │ │ ▣  grid        │ │ ▣  apple       │
│ Linux (ARM64)   │ │ Windows 11 Arm │ │ macOS          │
│ Native speed.   │ │ Native speed.  │ │ Apple hardware │
│ Best support.   │ │ Needs QEMU.    │ │ only.          │
│ ── VZ ──        │ │ ── QEMU ──     │ │ ── VZ ──       │
└────────────────┘ └────────────────┘ └────────────────┘
```
Selecting a card updates a one-line consequence sentence below ("Windows 11 (Arm) runs on QEMU
because only an optical device can boot its installer."). macOS shows a hard requirement line:
"Requires an IPSW restore image for this Mac."

**Step 2 — Install source.** `DropZone` + secondary options: "Use an existing disk image…",
"Start empty — I will attach install media later". Chosen file becomes a row: name · size ·
`╳`. If the guest is Windows and the file is not an ISO: error text "Windows installers are
optical images. Choose the .iso." If the guest is Linux and the ISO lacks an EFI System
Partition: warning "This image has no EFI partition; it may not boot — Macport will attach it as
a CD as well."

**Step 3 — Name and resources.** Name (validated: non-empty, unique, filesystem-safe — inline
error under the field), location row (default `~/Library/Application Support/Macport/VMs`,
Change…), `ResourceSlider` ×2, disk size field with unit, network picker
(Shared NAT / Disconnected), then the live host-share `CapacityBar` and, if over-subscribed,
an inline warning.

**Step 4 — Review.** `KeyValueGrid` summary (guest, engine, CPU, memory, disk, network, install
media, location) + **What to expect** — the honesty block:

```
⚠  Windows 11 setup asks for a TPM 2.0 device. Macport supplies the setup answer file
   automatically, so that screen will not stop the install.
⚠  Windows on Arm runs x86 software through Microsoft's Prism translation. Macport
   cannot make those programs native — no architecture can.
◉  QEMU runtime 11.1.2 — not installed. Macport installs it (167 MB) during setup.
```
Primary button: **Create** (or **Create & Start** when the runtime is ready).

### S7 Runtime panel (sheet, 560 × 520)

`RuntimeRow` for the component (QEMU 11.1.2 · 167 MB · Ready / Not installed / Needs repair) ·
`KeyValueGrid` of facts (location in `mono`, contents "2 executables · 28 libraries · 61 data
files", signed "ad-hoc, hypervisor entitlement", source "vendored by Macport — Homebrew not
required") · actions **Install… / Verify / Reinstall… / Reveal** · `LogView` for install output
with progress line while running.

Copy that must appear verbatim in this panel: "Macport installs and manages this runtime itself.
Nothing is installed system-wide, and you do not need Homebrew or any package manager."

### S8 Problem sheet (from `ProblemCard`)

Title "Setup did not find bootable media" (human summary) · "What happened" (one paragraph,
engine-specific and specific: `ArmVirtQemu did not create a boot option for the attached
image` ) · "What to try" (ordered list of 2–3 concrete actions) · `LogView` with the last 200
lines · actions **Copy details**, **Reveal bundle**, **Try again**.

### S9 Settings

- **General** — Default VM folder (path + Change…), Default engine preference (Automatic /
  Virtualization.framework / QEMU), "Check for updates" (deferred in v1, hidden).
- **Runtime** — the S7 panel inline.
- **Advanced** — host diagnostics `Table`: hypervisor available (`kern.hv_support`), nested
  virtualisation, host cores, physical memory, VM count, total disk used; buttons **Copy
  diagnostics**, **Reveal support folder**.
- **About** — version, licence, third-party notices (QEMU/EDK2 licences, required for
  redistribution).

### S10 Delete confirmation

Sheet, not alert, because it carries information: machine name, disk size that will be freed,
and two radio options — **Move to Trash** (default: recoverable) and **Delete immediately**.
Confirmation button disabled until the destructive option is chosen explicitly. Delete is
disabled while the machine is running, with the reason stated inline.

---

## 7. State and feedback model

### 7.1 Action → state transitions the UI must render

| User action | Immediate UI | Engine work | Terminal UI |
|---|---|---|---|
| Start | pill `Starting…`, button → "Cancel", stage text | create answer media, spawn, answer firmware prompt | pill `Running`, console appears |
| Shut Down | pill `Stopping…`, button → "Force Off" | ACPI request | pill `Off` |
| Force Off | pill `Stopping…` | kill | pill `Off` |
| Delete | sheet | trash bundle | row disappears |
| Install runtime | `RuntimeRow` progress + stage line | download, verify, sign | `ready` + notice |

Only one machine runs at a time (v1). Pressing Start on machine B while A runs shows an inline
choice in B's header — "Shut down Ubuntu Test and start this machine?" with [Shut Down & Start]
[Cancel] — never a blocking error alert. The message never says "one at a time" without offering
the action.

### 7.2 Start sequence stages (QEMU is the interesting case)

The engine must report stages, because a QEMU boot is not instant and silence reads as a hang:

| Stage string | When |
|---|---|
| `Preparing answer media…` | generating the FAT16 volume for Windows guests |
| `Starting QEMU 11.1.2…` | process spawn, monitor socket up |
| `Waiting for firmware…` | before the boot attempt appears on the console |
| `Waiting for the guest to boot…` | after the boot prompt has been answered once |
| `Running` | — |

Displayed as: pill label (`Starting…`) + a 13 pt secondary line under the machine name +
(future) inline `ProgressView`. For Virtualization.framework the first three collapse to
`Starting…`.

### 7.3 Error taxonomy → treatment

| `EngineError` | Where it appears | Copy pattern |
|---|---|---|
| `.engineUnavailable` | `NoticeBanner` in dashboard | "Virtualization.framework is not available on this Mac." + action "Choose a different engine…" |
| `.runtimeMissing` | `NoticeBanner` + Start button becomes "Install runtime to start" | name the size and that Macport installs it |
| `.unsupportedGuest` | wizard step 1, on the card | card disabled with reason on the card face |
| `.invalidConfiguration` | inline at the offending field | never a summary-only error |
| `.hostResourceUnavailable` | inline under the resource slider | "+ 1.5 GB more than this Mac has free" |
| `.operationFailed` | `ProblemCard` | what happened + last log line + what to try |
| `.installMediaMissing` | Install media card, `state.paused` tint | "The ISO has moved or been deleted." + [Locate…] [Eject] |

### 7.4 Progress and duration expectations

- Runtime install: indeterminate `ProgressView` + current line in `mono.small` (the installer
  reports text precisely so silence is not read as a hang) + "This takes a few minutes."
- First boot of a guest: a `caption` under the console — "First boot can take several minutes;
  the installer may restart a few times."
- Any operation longer than 2 s shows *something*; anything longer than 30 s shows stage text.

---

## 8. Menus and keyboard

| Menu | Item | Shortcut | Notes |
|---|---|---|---|
| File | New Virtual Machine… | ⌘N | |
| File | Add Existing Machine… | ⇧⌘O | picks a `.macport` bundle, copies or references it |
| File | Open in Finder | ⇧⌘R | selected machine |
| File | Close Window | ⌘W | |
| Edit | Copy / Paste | ⌘C / ⌘V | copy works on paths, log selections, and diagnostics |
| Machine | Start | ⌘R | |
| Machine | Shut Down | ⌘. | |
| Machine | Force Off | ⌥⌘. | destructive styling |
| Machine | Pause / Resume | ⌘P | *needs protocol support — §11* |
| Machine | Restart Guest | ⌃⌘R | |
| Machine | Eject Install Media | ⌘E | |
| Machine | Delete… | ⌫ | |
| View | Show Console | ⌃⌘C | focus the console surface |
| View | Toggle Sidebar | ⌃⌘S | system default |
| View | Fit / Actual Size / Zoom In / Zoom Out | ⌘0 / ⌘1 / ⌘+ / ⌘- | console scaling |
| View | Enter Full Screen | ⌃⌘F | system default |
| Window | Minimise / Zoom | ⌘M / — | system defaults |
| Help | Macport Help | ⌘? | |
| Help | Copy Diagnostics | — | writes a text report to the clipboard |
| Help | Reveal Support Folder | — | |

Keyboard rules: every action in the UI is reachable without a pointer; the console surface
takes keyboard focus only on an explicit click ("Click to capture keyboard" affordance when it
does not have focus), and releases it on ⌃⌘C, Escape, or window deactivation.

---

## 9. Accessibility

- **Not colour alone.** Every status carries a word; every capability carries a verdict word;
  log severity carries a glyph plus a word.
- **Labels.** Icon-only controls (`ConsoleBar` items, sidebar toggle, overflow) get
  `accessibilityLabel` + `.help()`.
- **Values.** `CapacityBar` exposes "6 of 12 cores, 50 percent"; `StatusPill` exposes
  "State: Running"; `RuntimeRow` exposes "QEMU 11.1.2, ready, 167 MB".
- **VoiceOver order.** Dashboard reading order is header → primary action → Hardware → Engine →
  Storage → Install media → Networking → Activity; cards are labelled groups
  (`accessibilityElement(children: .contain)`).
- **Focus.** Visible focus ring on every interactive element (system default, never suppressed);
  the wizard's keyboard flow is ⌘1–4 to jump steps, Tab order within a step matching visual order.
- **Reduce Motion.** Running pulse, card stagger and wizard slide are replaced by static
  equivalents.
- **Contrast.** All text tokens meet ≥ 4.5:1; status text meets 4.5:1 on its 12 % tint
  background in both appearances (verified in the HTML preview).
- **Sizing.** All sizes are the system text sizes; nothing is hard-coded smaller than 11 pt, so
  Dynamic Type / larger system text settings scale the interface rather than clipping it.
- **Targets.** Minimum 24 × 24 pt hit area for any control, 28 pt for console bar items.

---

## 10. Copy and voice

Rules: sentence case; no exclamation marks; no "Oops"/"Something went wrong"; name what
happened and the next step; machine facts in monospace; never market a limitation as a feature.

| Where | Replace this | With this |
|---|---|---|
| Dashboard, Windows | "Windows setup will need its TPM check bypassed — Shift-F10, then the LabConfig registry keys." *(stale: the engine does this itself now)* | "Windows setup asks for a TPM 2.0 device. Macport supplies the setup answer file automatically — that screen will not stop the install." |
| Start, second VM | "Stop the running virtual machine first. Macport runs one at a time." | "Ubuntu Test is running. Shut it down and start Windows 11?" with [Shut Down & Start] |
| Empty state | "No virtual machine selected" | "No machine selected" + library table (S2) or drop zone (S1) |
| Engine unavailable | "The Virtualization.framework engine is not available on this Mac." | "Virtualization.framework is not available on this Mac, so Linux and macOS machines cannot start here." |
| Runtime | "Not installed" alone | "QEMU runtime is not installed. Macport installs it for you — 167 MB, about a minute." |
| Delete | "Delete…" | "Move to Trash" (default) / "Delete immediately" |

Terminology, fixed: **machine** (not "VM") in user-facing copy, **guest** only inside the
capability/engine context, **engine** for VZ/QEMU, **runtime** for the vendored QEMU build,
**bundle** for the `.macport` folder, **console** for the guest display, **install media** for
ISOs. "Shut Down" for graceful, "Force Off" for immediate.

---

## 11. SwiftUI implementation map

| File | Status | Contents |
|---|---|---|
| `App/MacportApp.swift` | change | `NavigationSplitView` window, `Settings` scene, `.commands` from §8, min size 960 × 620 |
| `App/AppState.swift` | change | add `stage: String?` (start sequence), `runningVMID` per machine, `isBusy` → `busyMachine`, runtime status source, `pause/resume` when the protocol gains them |
| `Model/` | add | `RuntimeStatus` (ready / missing / repairing + version + size), `MachineSummary` (disk used on disk), engine version string |
| `Engine/VMEngine.swift` | change | add `pause()/resume()`, `stage` reporting, `logTail(_:)` — all already anticipated by `VMState` |
| `Views/Library/VMLibraryView.swift` | rewrite | sidebar per §4.3 (dot, sub-line, footer runtime row, `＋` row) |
| `Views/Library/LibrarySummaryView.swift` | new | S2 no-selection table |
| `Views/Dashboard/DashboardView.swift` | new | S3 layout, card order, banner logic |
| `Views/Dashboard/Cards/*.swift` | new | Hardware, Engine, Storage, InstallMedia, Networking, Activity |
| `Views/Console/ConsoleView.swift` | new | S4 embedded surface + `ConsoleBar` |
| `Views/Console/ExternalConsoleCard.swift` | new | S5 + Bring to Front |
| `Views/Wizard/CreateMachineSheet.swift` | rewrite of `VMCreateView` | S6, four steps, `StepIndicator`, validation |
| `Views/Runtime/RuntimePanel.swift` | new | S7 |
| `Views/Problem/ProblemSheet.swift` | new | S8 |
| `Views/Settings/*.swift` | new | S9 |
| `Views/Components/*.swift` | new | §5 inventory, one file each |
| `Resources/Colors.xcassets` | new | the §3.1 tokens as asset-catalog colours with both appearances |

Build order (each independently reviewable): components → sidebar + library → dashboard cards →
create wizard → runtime panel → problem sheet → settings → console states.

---

## 12. Deliberately not in v1

| Deferred | Reason |
|---|---|
| Embedded console for QEMU | QEMU draws its own window; embedding needs a capture path (VNC/SPICE or shared-memory display). Designed as S5 with an explicit, tooltipped disabled control so the gap is visible, not hidden. |
| Snapshots UI | No engine reports `snapshots == true` today. The capability chip says "Not available" rather than the feature being absent from the interface. |
| Shared folders UI (QEMU) | Same treatment: chip + disabled "Add folder…" with the reason. |
| USB passthrough | Same. |
| Menu bar extra | Nice, but it duplicates console/power control that already exists in the window; adds a second state surface to keep correct. |
| Multiple simultaneous machines | A deliberate v1 constraint (§7.1); the UI handles the conflict by offering the swap rather than refusing. |
| Per-VM display resolution | Depends on Macport's own firmware build (see ARCHITECTURE.md); the dashboard will host a Display card when it lands. |
| Guest IP detection | Needs a guest agent or ARP/DHCP lease inspection; showing "not detected" is more honest than guessing. |
