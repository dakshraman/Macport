# Macport — Parallels-class capability plan

**Status** Product direction · October 2026
**Companions** `ARCHITECTURE.md` (how the engines work) · `docs/UI-SPEC.md` (what the user sees)
**Position** Macport must match the *workflows* people buy Parallels Desktop for, exceed it where it
counts, and cost nothing.

This is deliberately a capability document, not a wish list. Every row states what exists today,
what the plan is, which engine can actually deliver it, and — where something is not achievable —
why. A feature we cannot deliver honestly is marked as such and stays out of the UI.

---

## 1. What "free" means here

| Claim | Meaning | Cost to the user |
|---|---|---|
| **Free app** | No subscription, no perpetual licence, no trial timer, no account, no sign-in, no telemetry, no licence server. Works offline forever. | $0 |
| **No editions** | No Standard vs Pro split. CPU, memory, snapshots, CLI, automation and multiple machines are all in the same build. Parallels gates CPU/RAM limits and the CLI behind Pro/Business tiers; Macport does not. | $0 |
| **No upsell surfaces** | No “upgrade to unlock”, no feature flags tied to payment, no watermark. | $0 |
| **Guest licences are yours** | Windows 11 still needs a Microsoft licence. macOS guests are permitted only on Apple hardware under Apple's licence. Macport cannot and will not supply those. | User's own |
| **Runtime is free too** | The QEMU runtime Macport vendors is GPLv2 software. We ship it with source availability and notices, so redistribution stays compliant. `swtpm` (planned) is LGPL. EDK2 firmware is BSD-2-Clause. | $0 |
| **Open to audit** | App source published under a permissive licence (MIT/Apache-2.0); the GPL runtime stays a separate, replaceable component with its source offer. | $0 |

**What this is not:** “free” does not mean the guest operating systems are free, and it does not mean
Macport will clone Parallels' proprietary drivers or activation technology. It means the Macport
product itself has no price and no gate.

---

## 2. Where Macport already stands

| Capability | State |
|---|---|
| Two engines, routed per guest | **Working** — Virtualization.framework for Linux/macOS, QEMU for Windows |
| Ubuntu ARM64 boot to desktop | **Working**, console embedded in the app window |
| Windows 11 Setup boot from ISO | **Working** — optical USB transport, firmware boot prompt answered automatically |
| TPM 2.0 compatibility screen bypassed | **Working** — Macport generates the setup answer media itself (no Shift-F10, no registry edit) |
| Vendored, self-managed QEMU runtime | **Working** — 167 MB, re-signed, no Homebrew, no system install |
| Capability truth surfaced in UI | **Designed** — engine chips, capability rows with consequences, problem cards |
| CLI (`macportctl`) | **Working** — list/create/start/stop |
| Single machine at a time | **Deliberate v1 limit** — must be lifted for parity (§7) |

---

## 3. Feature matrix

Legend — **Now** = exists · **Next** = Phase 2 (parity core) · **Later** = Phase 3/4 · **No** = not
achievable with the current platform, with the reason stated · **Engine** = which engine delivers it.

### 3.1 Machines and lifecycle

| Capability | Parallels | Macport | Plan | Engine / note |
|---|---|---|---|---|
| Create a VM from an ISO through a wizard | Yes | Yes (design complete) | Next | Both |
| Start / shut down / force off | Yes | Yes | Now | Both |
| Suspend and resume *in memory* (pause) | Yes | Not yet | **Next** | VZ `pause/resume`; QEMU `stop/cont` via QMP |
| Suspend to disk (save state across app quit) | Yes | Not yet | **Next** | QEMU `savevm` on qcow2 only; VZ has no save-state API — VZ guests get pause, not suspend-to-disk |
| Multiple machines running at once | Yes | No (v1) | **Next** | Requires `AppState` keyed by VM id, one engine instance per VM, memory admission control |
| Clone / duplicate a machine | Yes | No | **Next** | APFS `clonefile` of the bundle when off — instant, copy-on-write, near-zero disk |
| Snapshots with rollback | Yes (Pro) | No | **Next** | QEMU qcow2 internal snapshots (disk + RAM). VZ exposes no snapshot API → VZ guests show “Not available on this engine” |
| Automatic snapshots before risky operations | Yes | No | Later | Policy on top of the QEMU snapshot primitive |
| Import existing VMs (Parallels/VMware/VirtualBox/OVA) | Yes | No | **Next** | Vendored `qemu-img convert` (vmdk/vdi/vhdx/qcow2/ova) → raw for VZ, qcow2 for QEMU; guest inferred from disk labels |
| Headless / background run | Yes | No | Later | QEMU `-display none` + QMP; VZ can run without a view |
| Start at login | Yes | No | Later | `SMAppService` login item + a “start these machines” list |
| Encrypted VM storage | Yes (Pro) | No | Later | qcow2 LUKS for QEMU; APFS-encrypted bundle for VZ is a separate design |

### 3.2 Configuration

| Capability | Parallels | Macport | Plan | Engine / note |
|---|---|---|---|---|
| CPU / memory editing after creation | Yes | No (create only) | **Next** | Hot-add where the engine allows; otherwise “shut down to apply” |
| Disk resize (grow) | Yes | No | **Next** | `truncate`/`qemu-img resize` + guest partition guidance |
| Boot order | Yes | No | **Next** | QEMU `-boot order=`; VZ boot loader selection |
| EFI / Secure Boot control | Yes | Partial | Next | EDK2 vars already per-VM; expose Secure Boot toggle where meaningful |
| Virtual TPM 2.0 | Yes | **No** — answer file works around it | **Next** | Vendor `swtpm` (LGPL, ~1 MB) and expose a real vTPM. Removes the setup bypass entirely and enables BitLocker |
| Nested virtualisation | Limited | No | Later | VZ declares it where the host allows; QEMU `-cpu host` needs entitlement work |
| Per-VM display scaling / resolution | Yes | Fixed 800×600 on Windows | **Next** | Install the `virtio-gpu` Arm64 driver from Macport Tools during Setup → dynamic resolution + no custom firmware. VZ Linux already resizes |
| Shared folders | Yes | Engine capability declared, no UI | **Next** | VZ `VZSharedDirectory` (virtiofs) for Linux/macOS; QEMU virtiofs/9p + `viofs` driver for Windows |
| USB passthrough | Yes (USB 3) | Declared unsupported | Later | QEMU `usb-host` if the build has libusb; VZ only exposes USB mass storage |
| Shared clipboard | Yes | No | **Next** | Needs a guest agent (§3.4). VZ has no public clipboard API, so the agent is the portable answer |
| Drag and drop between host and guest | Yes | No | Later | Same agent channel as clipboard |
| Shared camera / printer | Yes | No | No | Requires guest drivers and host device brokering; out of scope until the agent exists |
| Time sync | Yes | Partial (UTC clock) | **Next** | Agent over virtio-serial; QEMU `-rtc base=utc` today |

### 3.3 Display, input and graphics

| Capability | Parallels | Macport | Plan | Engine / note |
|---|---|---|---|---|
| Windowed and full-screen console | Yes | Windowed + QEMU's own window | **Next** | Embedded console for VZ exists; QEMU embedding needs a capture path (VNC/SPICE) — designed as an explicit “not available yet” card |
| Multiple displays | Yes | No | Later | VZ supports multiple display configurations; QEMU ramfb does not |
| Retina-correct scaling | Yes | Yes (zoom-to-fit) | Now | Cocoa display scaling |
| 3D acceleration for Linux guests | Yes | Framework-dependent | Later | VZ exposes accelerated graphics where the guest driver supports it; QEMU would need virtio-gpu Venus |
| 3D / DirectX for Windows guests | Yes (DX11) | **No** | No | Requires a paravirtual GPU driver and host GPU sharing that neither QEMU nor VZ provides for Windows on Arm. Do not promise it |
| Coherence (guest windows appear as Mac windows) | Yes | **No** | No (research only) | Needs kernel-level guest integration plus a Mac-side window compositor. A multi-year driver project; excluded from the roadmap |
| Screenshot of the guest | Yes | Yes (QEMU screendump) | Now | Also used for library thumbnails |
| Seamless keyboard capture/release | Yes | Yes | Now | Esc releases capture; documented in the console bar |

### 3.4 Integration (the guest agent)

Parallels' polish comes from its guest tools. Macport needs the same component — call it **Macport
Tools**: a small, signed agent for Linux and Windows, transported over virtio-serial.

| Function | Without agent | With Macport Tools | Plan |
|---|---|---|---|
| Clipboard (text, then files) | None | Two-way, opt-in per VM | Next |
| Dynamic resolution | Fixed by driver/firmware | Host window resizes guest | Next |
| Shared folders | Driver-only | Mount/unmount without reboot | Next |
| Time sync | UTC only | Continuous | Next |
| Graceful shutdown request | ACPI | ACPI + guest ack | Next |
| Battery / resource reporting | Host-side only | Guest load shown in dashboard | Later |
| Windows drivers (virtio-net, virtio-gpu, viofs, balloon) | Device invisible | Installed from Macport Tools during Setup via `DriverPaths` in the answer file | **Next — highest leverage item** |

The driver pack is the single biggest upgrade available: attaching it to the answer media during
Setup gives Windows a network device, a resizable display and shared folders **without** a custom
firmware build and without the user installing anything by hand. Parallels ships the same pattern:
its Arm64 answer file adds `E:\netkvm\arm64` through `DriverPaths` (§9).

### 3.5 Networking

| Capability | Parallels | Macport | Plan | Engine / note |
|---|---|---|---|---|
| Shared (NAT) networking | Yes | Yes for VZ; QEMU device present but Windows lacks a driver | **Next** | virtio-net driver from Macport Tools; QEMU user-mode NAT |
| Bridged networking | Yes | No | Next (VZ) / Later (QEMU) | VZ bridged attachment works for Linux/macOS. QEMU bridged needs `vmnet` + the restricted `com.apple.vm.networking` entitlement, or a privileged helper — designed, not promised |
| Host-only network | Yes | No | Later | VZ host-only; QEMU socket networking |
| Port forwarding | Yes | No | **Next** | QEMU `hostfwd` exposed in the UI; VZ needs a helper/proxy |
| Per-VM MAC / IP visibility | Yes | “Not detected” today | Next | With the agent, report the guest IP instead of guessing |

Parallels links `vmnet.framework`, but none of the checked in-bundle executables carries
`com.apple.vm.networking` (§9). Combined with the setuid `Parallels Service` and the
`/Library/Parallels` daemons documented in `competitive-analysis.md`, its bridged path runs through
a privileged hop rather than an app entitlement. Macport's statement stands: VZ bridged is
available; QEMU bridged is not promised.

### 3.6 Management, automation and data

| Capability | Parallels | Macport | Plan | Engine / note |
|---|---|---|---|---|
| CLI for every operation | Pro only | `macportctl` exists, partial | **Next** | Grow to parity: snapshot, clone, import, config, status JSON |
| Scripting / JSON output | Pro | No | Next | Stable JSON schema, documented |
| Resource monitor (CPU/RAM per VM) | Yes | No | **Next** | `proc_pid_rusage` on the engine process; host counters for the capacity bars |
| Menu bar extra | Yes | No | Later | VM list, start/stop, running count |
| Logs and diagnostics in the UI | Buried | Designed | Now | Problem cards + log sheet are already the design's backbone |
| Time Machine-friendly storage | Yes | Yes | Now | Bundles are ordinary folders; no proprietary container |
| Portable / movable machines | Yes | Yes (by design) | Now | One `.macport` folder holds disk, firmware vars and config |
| Automatic app updates | Yes | No | Later | Sparkle-style feed, free; runtime updates separately versioned |

### 3.7 Guest OS support

| Guest | Parallels | Macport today | Plan |
|---|---|---|---|
| Windows 11 Arm | Full, with tools + DX11 | Setup boots and installs; no networking, fixed 800×600 | Drivers + agent → parity on networking/display/clipboard; no DX11 |
| Linux ARM64 (Ubuntu, Fedora, Debian) | Full | Boots to desktop on VZ | Add shared folders, clipboard, snapshots via agent/tools |
| macOS guest | Supported on Apple silicon | Engine capability declared | Expose the IPSW restore flow; licence-gated |
| x86 / x86_64 guests | **No** (Arm only) | QEMU TCG can emulate (slow) | Optional experimental mode — a genuine “upgraded” capability Parallels does not offer |
| Windows 10 Arm | Limited | Not tested | Test + declare |

---

## 4. What “upgraded” means, concretely

1. **No artificial ceilings.** Parallels Standard caps CPU/RAM per VM; Macport allows up to what the
   host can actually give, with an honest capacity bar and admission control instead of an upsell.
2. **Two engines, one product.** Windows on QEMU, Linux/macOS on Virtualization.framework — routed
   automatically, with the engine named on every machine. Parallels hides its stack; Macport makes
   it a first-class, inspectable object.
3. **Capability truth instead of surprise.** Every engine limit is shown *before* it costs the user
   a download or a failed install. No “why doesn't my network work?” support thread.
4. **The dependency belongs to the app.** QEMU is vendored, signed and repaired by Macport. No
   Homebrew, no terminal, no PATH edits.
5. **Open, portable storage.** Raw/qcow2 disks and plain bundles; import/export with `qemu-img`;
   nothing to “uninstall” and no proprietary format lock-in.
6. **Automation is free.** CLI and JSON output in the base product, not a Pro SKU.
7. **Self-diagnosis.** Problem cards quote the exact firmware or engine line that failed, with a
   copyable log. This is already the design's centre of gravity.
8. **x86 emulation option (experimental).** QEMU TCG can run guests Parallels structurally cannot.
   Slow, clearly labelled, off by default — but it exists.
9. **Instant clones.** APFS copy-on-write makes duplicating an 80 GB machine near-instant and
   near-free on disk — better than the copy-based clone users expect.
10. **No account, no telemetry, no network requirement.** The app never phones home.

---

## 5. What we will not promise

| Tempting claim | Why not |
|---|---|
| “Coherence mode” | Requires guest kernel drivers plus a Mac window compositor. Not a feature that can be approximated honestly. |
| “DirectX 11/12 in Windows” | No paravirtual GPU driver exists for Windows on Arm under QEMU/VZ. Anything less is software rendering; say so. |
| “Runs any Windows app natively” | Arm Windows runs x86 through Microsoft's Prism translation. Macport cannot change that. |
| “Free Windows” | Microsoft's licence is separate; the UI says “Windows 11 (Arm)” and never implies a licence is included. |
| “Unlimited performance” | The host has 8 GB RAM in this test machine. Admission control and capacity bars exist precisely to avoid lying about it. |
| Bridged networking for QEMU “soon” | Depends on a restricted Apple entitlement or a privileged helper. It is designed, not scheduled. |

---

## 6. Roadmap

### Phase 2 — parity core (the next build)
Ordered by user-visible value per unit of risk.

1. **Windows driver pack + answer-file integration** → network device, resizable display, shared
   folders path. (Removes the two biggest Windows gaps in one stroke.)
2. **Multi-VM runtime** → several machines running, admission control, per-VM engine instances.
3. **Pause/resume + suspend-to-disk where supported** (QEMU), pause for VZ.
4. **Snapshots** (QEMU) with a timeline UI and clone-before-risky-operation prompt.
5. **Clone/duplicate** via APFS clonefile, with an explicit “this is instant because the disk is
   copy-on-write” note.
6. **Machine settings UI** (CPU/RAM/disk/boot/network/devices) with “applies after restart” states.
7. **vTPM via bundled `swtpm`** → Windows 11 without the answer-file bypass; BitLocker becomes possible.
8. **CLI parity + JSON** for every one of the above.
9. **Menu bar extra** and login-item autostart.
10. **Import** (`qemu-img`) for qcow2/vmdk/vdi/vhdx/ova.

### Phase 3 — integration
Macport Tools agent (Linux first, then Windows): clipboard, dynamic resolution, shared folders,
time sync, guest IP and load reporting. Resource monitor. Port forwarding UI. VZ bridged networking.

### Phase 4 — research, explicitly unscheduled
QEMU embedded console (VNC/SPICE capture), Linux 3D via Venus, USB passthrough, encryption at rest,
x86 emulation mode, multiple displays.

### Definition of done for “like Parallels”
A new user can, without a terminal:

- install Windows 11 Arm from an ISO, reach the desktop, have working networking at a usable
  resolution, and copy text both ways;
- install Ubuntu, resize its window, share a folder, snapshot it, clone it, and roll back;
- run two machines at once, watch their CPU/RAM, and script all of it from `macportctl`;
- do all of that without paying, signing in, or granting the app an account.

---

## 7. Risks and how they are handled

| Risk | Handling |
|---|---|
| Windows Arm driver signing / availability | Ship Red Hat's redistributable virtio-win Arm64 pack through Macport Tools; verify each driver's signature; fall back to answer-file bypass + 800×600 if absent |
| QEMU GPL compliance | Ship the exact source tarball (or written offer) beside the runtime; keep QEMU a separate executable; document build flags |
| Memory pressure on 8 GB hosts | Admission control before start; capacity bars; refuse to silently overcommit |
| VZ feature gaps (snapshots, save state, clipboard API) | Declare them per engine in the UI; never fake them with a UI-only button |
| Multi-VM engineering risk | Land it behind the same engine protocol; no UI rewrite — the sidebar already models per-VM state |
| Scope creep toward Coherence/DX11 | Written non-goals (§5) reviewed at every roadmap change |

---

## 8. Immediate next actions

1. Finish the UI design pass so the Phase 2 surfaces (snapshots, settings, multi-VM, import) have a
   home in the interface before the engine work starts. *(in progress)*
2. Build the Macport Tools ISO skeleton: virtio-win Arm64 drivers + `DriverPaths` answer-file entry.
3. Refactor `AppState` from a single running VM to a registry keyed by machine id; add admission
   control.
4. Add `pause/resume` and snapshot primitives to `VMEngine`, with capability flags per engine.
5. Vendor `swtpm` and wire it into `QEMUEngine` behind a capability flag.

Each step is independently shippable and reviewable. The first one that changes a user's day is
step 2: Windows with a network and a real display.

---

## 9. Evidence appendix — what Parallels Desktop 27.0.3 actually ships

Analysed with REA 6.7.0 (artifact graph, code signature, Mach-O metadata, and shipped XML) on
**Parallels Desktop 27.0.3**, bundle `com.parallels.desktop.console`, main executable
`prl_client_app` (arm64) SHA-256
`8aafd57766594be4120607f69e795966cd5615f02d0cd79563e05b57ef49527f`.

**Scope boundary.** Only package structure, metadata, entitlements, linked libraries and shipped
configuration were read. No proprietary code was decompiled, and no licence or activation logic was
inspected. Parallels' drivers are not copied; Macport ships redistributable virtio-win instead.

| Observation | Evidence | Implication for Macport |
|---|---|---|
| Arm64 guest media is shipped per guest OS: `prl-tools-win-arm.iso` (980 KB), `prl-tools-lin-arm.iso` (3.1 MB), `prl-tools-mac-arm.iso` (1.2 MB), plus `prl-tools-win.tar.gz` (14 MB) | `Contents/Resources/Tools` listing; artifact inventory `ev_47db4a19…` | The per-OS tools-media model is the shipped pattern. Macport Tools should be split the same way and carry the Arm64 Windows drivers. |
| `Autounattend_arm64.xml` declares `<DriverPaths>` → `E:\netkvm\arm64`; `netkvm/arm64` and `prl_tg/arm64` sit beside it | Shipped XML read directly; Tools listing | Confirms the exact mechanism Macport plans: driver injection through the answer file. The difference is the driver source (Red Hat virtio-win, not Parallels'). |
| The answer-file family includes `Autounattend_assist_arm64.xml`, `_sysprep_arm64.xml`, and zero-touch PowerShell scripts | Tools listing | Parallels automates install **and** OOBE. Macport can stay narrower: unattended Setup plus a clean first boot. |
| The main app and service signatures carry `com.apple.security.virtualization`; neither carries `com.apple.security.hypervisor`; the app is unsandboxed | Code-signature evidence `ev_2e0854c1…` | Entitlements alone do not identify the VMM. Linkage does: Parallels' Arm monitor uses Hypervisor.framework, and only the macOS-guest path links Virtualization.framework (competitive analysis, Finding 3). The lesson is per-guest engine routing, not “VZ everywhere”. |
| No `com.apple.vm.networking` on checked in-bundle binaries; `prl_disp_service` links `/System/Library/Frameworks/vmnet.framework/…` | Mach-O evidence `ev_090b460e…` | Bridged networking uses vmnet without an app-level entitlement, consistent with the setuid/LaunchDaemon privilege path in Finding 4. It does not establish how that hop is authorised; keep QEMU bridged unscheduled (§5). |
| `Parallels Mac VM.app` (`prl_macvm_app`) alongside the virtualization entitlement | Bundle inventory | macOS guests via VZ is a real shipping architecture and matches Macport's engine split. |
| Coherence is a constellation, not a toggle: `Parallels Link.app` (`prl_sharedapp_link`), `libprl_shared_apps`, `ExeQLPlugin`, `OpenInIE`, `ParallelsMail`, `coherence.mp4` | Bundle inventory | Supports the non-goal in §5. Reaching parity here means building several integration components, not flipping a setting. |
| UI is Qt 5/QtQuick plus `PDCocoaKit`/`PDControlCenter`; VM plumbing is `ParallelsVirtualizationSDK.framework`; graphics includes `libmetalirconverter` and `libOSMesa` | Bundle inventory | There is no small open component to adopt. Macport's native SwiftUI + protocol engines is a clean-room equivalent, not a port. |
| Disk lifecycle is its own subsystem: `Parallels Mounter.app`, `prl_disk_tool`, `prl_osimage_tool`, `libwimlib` | Bundle inventory | Import, mount and image handling deserve first-class treatment, as Phase 2's import step assumes. |

*Evidence IDs were recorded inline during the REA session; the artifact session was closed after
capture, so the retained records are not replayable from this document. Re-running is one
`open_binary` + `inspect_artifact` on the installed app.*
