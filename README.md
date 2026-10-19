# Macport

A virtual machine manager for Apple silicon Macs, built on Apple's
Virtualization framework.

Macport runs arm64 guests — Linux, and Windows 11 on Arm — on the metal via the
macOS hypervisor, with virtio devices throughout. No software chipset model, no
emulated NIC, no emulated GPU. That is the whole point: a lighter machine than a
QEMU-based manager, which is what you feel as faster boot and better battery.

---

## What this is, and what it is not

This project exists because the honest answer to *"run Windows apps natively on
my Mac"* is: **you cannot run x86 Windows binaries natively on an arm64 CPU.**
There is no architecture that removes the instruction-set translation step.
Every product in this space — Parallels, VMware Fusion, UTM — either virtualises
Windows on Arm (native CPU speed, x86 apps translated by Microsoft's Prism) or
uses Wine plus Rosetta 2 (a deprecation dead end).

Macport takes the durable path: **virtualise arm64 Windows and arm64 Linux
properly and integrate them tightly with macOS.** It does not and will not
promise native x86 execution.

### You should probably use something else

Being straight about this up front:

| If you want | Use |
| --- | --- |
| Windows apps today, best integration, willing to pay | **Parallels Desktop** (~$100/yr) — Coherence mode |
| Windows apps today, free | **VMware Fusion** (free for personal use) |
| Free, don't mind rough edges | **UTM** (already installed on this Mac) |
| No Windows licence, Wine compatibility | **CrossOver** (~$74/yr) |

Macport is a *building* project, not a "you need this to get work done" project.
If your goal is running a specific Windows program this afternoon, install one of
the above.

---

## Status

Early, and moving. Phase 1 — the engine layer and VM library — works; Phase 2 — the
runtime boundaries that make it a product — is specified in
`docs/REFACTOR-PLAN.md` and under implementation.

| Area | State |
| --- | --- |
| `VMConfiguration` model, `.macport` bundle format | Done |
| Engine protocol + capability model | Done; v2 (pause/resume/snapshots) in progress |
| Virtualization.framework engine (create/start/stop) | Working — Ubuntu 26.04 arm64 boots to desktop |
| QEMU engine (Windows, optical media) | Working — Windows 11 Setup boots and installs |
| Windows TPM bypass via generated answer media | Working — no manual registry edit |
| Multi-VM runtime, control plane, per-VM QEMU host | Phase 2 — see `docs/REFACTOR-PLAN.md` |
| Snapshots, clone, disk import | Phase 2 |
| Macport Tools (guest drivers + agent) | Phase 2/3 |
| SwiftUI interface | Library, creator, live display |
| `macportctl` CLI | `list`, `capabilities`, `create`, `start`; parity in Phase 2 |
| Coherence-style app integration | Not started — see `ARCHITECTURE.md` and the non-goals |

Both schemes build clean from `xcodegen generate`; the QEMU runtime is embedded into
the app bundle at build time when one is present locally.

See `docs/competitive-analysis.md` and `docs/evidence/` for the reverse-engineering
analysis of Parallels Desktop and UTM that informs these design decisions.


## Requirements

- Apple silicon Mac
- macOS 14.0 or later
- Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
cd Macport
xcodegen generate
open Macport.xcodeproj
```

Or from the command line:

```bash
xcodegen generate
xcodebuild -project Macport.xcodeproj -scheme Macport -configuration Debug build
```

## Honest limitations

These are properties of the platform, not bugs waiting to be fixed:

- **No virtual TPM.** Apple's Virtualization framework provides none, and Windows
  11's installer demands TPM 2.0. A stock Windows 11 install therefore needs the
  setup-time registry bypass, or a second engine that can supply a vTPM
  (QEMU + swtpm). Macport surfaces this through `EngineCapabilities.tpm` rather
  than letting you discover it an hour into an install.
- **No foreign-architecture emulation** in this engine. An x86_64 guest requires a
  QEMU-class engine, and will run 10–100× slower than native.
- **No nested virtualisation.** Apple silicon does not expose it to guests.
- **No DirectX 12.** Only a QEMU-class engine with a translation layer (DXMT) has
  a path to it, and even then it is experimental.
- **A Windows VM is not free.** Minimum realistic footprint is ~4 GB RAM and
  ~40 GB disk. No design removes that; a second OS costs what a second OS costs.

## Licence

MIT — see `LICENSE`.
