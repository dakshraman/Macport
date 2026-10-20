# Macport refactor plan — Parallels-class runtime boundaries

**Status** Implemented — Phase 2 core · October 2026
**Companions** `ARCHITECTURE.md` · `docs/FEATURE-PARITY.md` · `docs/UI-SPEC.md` ·
`docs/evidence/parallels-refactor-2026-10-19.md` · `docs/verification/2026-10-20-phase2.md`

> **Implementation note (2026-10-20).** The workstreams in this plan are merged
> into `main`. The live evidence, defects found and unverified paths are in
> `docs/verification/2026-10-20-phase2.md`. Definition-of-done item 8 is met in
> its fallback form: when the driver ISO is absent the UI names the exact paths
> it searched; a live Windows install with Macport Tools is still unverified
> because no `virtio-win.iso` was available. vTPM and bridged QEMU networking
> remain non-goals for this phase, as stated below.
**Goal** Move Macport from a single-VM, in-process demo to a multi-VM runtime with the
same *boundaries* that make Parallels a product: an unprivileged UI, a control plane,
per-VM execution, a self-contained bundle, and a managed guest-tools path.

This plan copies architecture, not code. No Parallels binary, driver, protocol or
licence mechanism is reused.

---

## 0. Executive summary

Six decisions drive the refactor:

1. **The UI never owns a hypervisor.** `Macport.app` becomes a client of a runtime
   registry. It keeps the `VZVirtualMachineView` binding for Linux/macOS guests, but it
   no longer owns QEMU processes or privileged devices.
2. **QEMU gets a per-VM host process.** `MacportVMHost` owns one QEMU process, its
   monitor socket and its lifecycle. It survives the app window closing and gives the
   CLI a control endpoint.
3. **VZ stays in-process, and the plan says so.** Virtualization.framework's display
   object is bound to the process that creates it. A per-VM host for VZ would require a
   frame-transport layer. VZ guests therefore run in the app (or the CLI, headless),
   with an explicit engine capability: `backgroundHosting = false`.
4. **Privilege follows the VM process.** The restricted `vm.networking` /
   `vm.device-access` entitlements move off the GUI. They belong on the per-VM QEMU
   host, matching Parallels' placement. Until Apple grants them, Macport ships NAT-only
   and says so.
5. **State is a registry, not a singleton.** `AppState.runningVMID` becomes
   `[UUID: VMInstance]`, with admission control before every start.
6. **The bundle is the machine.** Config schema v2, qcow2 for QEMU with internal
   snapshots, a lock file, and a runtime state file that lets a new process discover
   a VM that is already up.

This refactor does not add Coherence, DirectX, or a free Windows licence. Those remain
non-goals in `FEATURE-PARITY.md` §5.

---

## 1. What Parallels actually does

Full evidence, hashes and evidence IDs: `docs/evidence/parallels-refactor-2026-10-19.md`.

| Observation | Consequence for Macport |
|---|---|
| The GUI (`prl_client_app`) links Qt and the SDK IPC library, not `Hypervisor.framework`; its signature carries no `vm.networking` or `vm.device-access`. | The UI should be an unprivileged client. Remove restricted entitlements from `Macport.app`. |
| `prl_disp_service` is a dispatcher with a single entitlement, linking the hypervisor and vmnet but holding no restricted grants. | A control plane can be unprivileged; it routes commands, it does not own devices. |
| `prl_vm_app` is one process per VM (`com.parallels.vm`), links `Hypervisor.framework` and `vmnet.framework`, and carries Hypervisor + `vm.networking` + `vm.device-access`. | Put QEMU in a per-VM host process and put restricted entitlements there. |
| `prl_macvm_app` is a separate app for macOS guests and links `Virtualization.framework`. | VZ is a legitimate, separate engine path; it is not "the same engine with a flag". |
| A setuid `Parallels Service` launcher plus a `LaunchDaemon` (`com.parallels.desktop.launchdaemon`, `RunAtLoad`, `Interactive`) handle privileged host work. | Keep a privileged-helper seam, but do not build it until Macport needs vmnet/USB in the shipped build. |
| The only XPC service is `XPCMounter`; VM lifecycle is not XPC. | A small JSON control protocol over a Unix socket is sufficient; XPC is not required. |
| `Parallels VM.app` carries its own `SysBios.bin`/`VgaBios.bin`; a `.pvm` bundle carries `config.pvs`, a `*.hdd` disk directory and an integration `VM.app`. | Firmware and disks belong to the engine/bundle, not to the GUI. The bundle is the unit of portability. |
| Arm64 guest tools are shipped per OS, and `Autounattend_arm64.xml` uses `DriverPaths` → `E:\netkvm\arm64`. | Macport Tools is a first-class install input, not a post-install chore. |

---

## 2. Where Macport is today

| Area | Current implementation | Gap |
|---|---|---|
| Runtime ownership | `AppState` holds one `engine` and one `runningVMID` (`Macport/App/AppState.swift`) | No multi-VM, no per-VM state, no discovery |
| Engine protocol | `create`/`start`/`stop`/`forceStop` only (`MacportKit/Engine/VMEngine.swift`) | No pause/resume, snapshots, save-state, clone, import |
| QEMU control | HMP text socket for `system_powerdown` and one `sendkey` (`QEMUEngine.swift`) | No QMP, no pause/resume, no snapshots, no structured errors |
| Storage | Raw sparse `disk.img`; `Snapshots/` reserved but unused | Raw disks cannot use `savevm`; no snapshot metadata |
| CLI | `start` blocks in-process; `stop` deliberately fails (`MacportCtl.swift`) | No cross-process control, no `status`, no JSON |
| App/CLI coordination | Both read the same `VMStore`, neither locks or registers | Two starts can race; app cannot see a CLI VM |
| QEMU runtime | Vendored in Application Support; not embedded by `project.yml` | Shipping app has no runtime unless copied by hand |
| Entitlements | GUI declares `vm.networking`, `vm.device-access`, USB | Wrong process; ad-hoc builds do not grant restricted entitlements anyway |
| UI | Single selection, detail pane only | No multi-VM dashboard, settings, snapshots, import, menu bar |
| Guest tools | Answer media only, no drivers | Windows has no network and a fixed 800×600 display |

Baseline verified before this plan: `xcodegen generate` then both schemes build clean
with `CODE_SIGNING_ALLOWED=NO`.

---

## 3. Target architecture

### 3.1 Process model

```
┌──────────────────────────────┐
│ Macport.app (unprivileged)   │
│  SwiftUI views               │
│  AppState / registry client  │
│  VZEngine (in-process)       │
└──────────────┬───────────────┘
               │ Unix socket, NDJSON
               ▼
┌──────────────────────────────┐        ┌─────────────────────┐
│ MacportVMHost (one per QEMU) │───────▶│ qemu-system-aarch64 │
│  QEMUEngine + QMP client     │        │  (child process)    │
│  control server              │        └─────────────────────┘
│  runtime.json                │
└──────────────────────────────┘
               ▲
               │ same protocol
┌──────────────┴───────────────┐
│ macportctl (CLI)             │
└──────────────────────────────┘

Future, not this milestone:
MacportHelper (root LaunchDaemon) for vmnet/USB/installation.
```

- **QEMU**: `MacportVMHost` is a small executable target, one instance per VM. It owns
  the QEMU child, the QMP connection and the control socket. It writes
  `runtime.json` atomically. Closing the app does not stop the VM.
- **VZ**: `VZEngine` stays in the process that has the `VZVirtualMachineView` (the app)
  or in the CLI for headless starts. That process serves the same control protocol for
  the lifetime of the guest. `EngineCapabilities.backgroundHosting` is `false`.
- **UI**: never spawns QEMU directly. It asks `VMRuntimeRegistry`; the registry spawns
  or attaches to a host.
- **CLI**: same registry client. `start` can either spawn a host and return, or run VZ
  in the foreground with `--foreground`.

### 3.2 Privilege model

| Process | Needs | Entitlement file |
|---|---|---|
| `Macport.app` | VZ guests, display, file pickers | `com.apple.security.virtualization`, network client/server, audio/camera as used |
| `MacportVMHost` | `hvf` acceleration, NAT; optionally vmnet/USB | `com.apple.security.hypervisor`; `com.apple.vm.networking` / `vm.device-access` only when Apple grants them |
| `MacportHelper` (later) | vmnet, USB, privileged install | LaunchDaemon + XPC; not in this milestone |
| `macportctl` | control socket client | none |

Until the restricted entitlements are granted, the host ships user-mode NAT. The UI
already distinguishes NAT from bridged; it must not imply bridged works.

### 3.3 Runtime registry and state

New files under `MacportKit/Runtime/`:

```swift
@MainActor
public final class VMRuntimeRegistry: ObservableObject {
    @Published public private(set) var instances: [UUID: VMInstance] = [:]

    public func start(_ config: VMConfiguration, in store: VMStore) async throws
    public func stop(_ id: UUID, graceful: Bool) async throws
    public func pause(_ id: UUID) async throws
    public func resume(_ id: UUID) async throws
    public func instance(_ id: UUID) -> VMInstance?
    public func state(of id: UUID) -> VMState
    public func refresh()
}

@MainActor
public final class VMInstance: ObservableObject, Identifiable {
    public let id: UUID
    public let config: VMConfiguration
    public let engine: any VMEngine
    public let engineName: String
    @Published public private(set) var state: VMState
    @Published public private(set) var lastError: String?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var runsInExternalWindow: Bool
}
```

- `AppState` keeps its name (minimises UI churn) but becomes a facade over the
  registry: `instances`, `state(for:)`, `isRunning(_:)`, `start`, `stop`, `pause`,
  `resume`. `runningVMID` and `runningEngineName` are removed.
- A 250 ms refresh task copies `engine.state`/`engine.lastError` into `VMInstance`.
  Polling is deliberate: it is engine-agnostic and avoids a second source of truth.
  The control-plane proxy added in workstream C can replace polling for hosted VMs.
- Admission control runs in `VMRuntimeRegistry.start`, not in the UI.

### 3.4 Admission control

`MacportKit/Runtime/AdmissionControl.swift`:

```swift
public struct HostCapacity: Sendable {
    public var physicalMemory: UInt64
    public var processorCount: Int
    public static var current: HostCapacity
    public static func check(
        _ config: VMConfiguration,
        running: [VMConfiguration]
    ) -> Result<Void, EngineError>
}
```

Rules:

- Reserve `max(2 GiB, physicalMemory / 8)` for macOS.
- Sum of running guest memory + requested memory must not exceed `physical - reserve`.
- Sum of vCPUs must not exceed `activeProcessorCount`; leave at least one host core.
- Disk: require `2 GiB + 5% of diskBytes` free on the bundle volume. Sparse disks make
  this a safety floor, not a full allocation.
- Failure returns `.hostResourceUnavailable` with the numbers, so the UI can show a
  capacity bar and a concrete next step.

### 3.5 Control plane

`MacportKit/Control/`:

- **Transport**: Unix domain socket at `$TMPDIR/macport-<uuid8>.control`
  (104-byte `sun_path` limit; same rule as the QEMU monitor).
- **Framing**: one UTF-8 JSON object per line, request then response, connection
  closed. Maximum frame 64 KiB. Version field `v: 1`.
- **Request**:
  ```json
  {"v":1,"id":"<uuid>","command":"snapshot","name":"Before update"}
  ```
- **Commands**: `status`, `stop` (`graceful`), `pause`, `resume`, `snapshot`,
  `snapshots`, `restore`, `deleteSnapshot`, `shutdownHost`.
- **Response**:
  ```json
  {"v":1,"id":"<uuid>","ok":true,"status":{"state":"running","engine":"QEMU","pid":1234}}
  ```
- Errors are `{"ok":false,"error":"..."}` with a stable machine-readable `code`.
- `runtime.json` mirrors the status for discovery when no client is connected:
  `{ "pid", "socket", "state", "engine", "startedAt", "lastError" }`.
- A stale socket is removed only after a connect attempt fails; never unlink a live
  one.

`MacportVMHost` command line:

```
MacportVMHost --vm <uuid> [--socket <path>] [--state <path>]
```

Exit codes: `0` clean stop, `2` config/runtime error, `3` guest error. SIGTERM/SIGINT
perform a graceful stop with a bounded timeout.

### 3.6 Storage, snapshots, clone and import

Bundle schema v2:

```
<uuid>.macport/
  config.json              schemaVersion: 2, diskFormat: raw|qcow2
  disk.img | disk.qcow2
  efi-vars.qcow2 | efi-vars.fd
  machine-id.bin           VZ only
  answer-media.img
  tools-media.iso          generated on demand
  tools-media-warning.txt  why generation was skipped
  runtime.json             present only while hosted
  host.log / qemu.log / console.log
  .lock                    flock target
```

- **QEMU snapshots** require qcow2. New QEMU VMs create `disk.qcow2` and convert
  the writable EFI varstore to `efi-vars.qcow2` on start (legacy raw stores are
  converted in place and kept bootable). Existing raw root disks stay usable; the
  first snapshot returns an actionable error and offers `macportctl disk convert`,
  which runs `qemu-img convert -O qcow2` to a temp file, fsyncs, then atomically
  renames. The old raw file is kept until the converted disk boots.
- **Snapshot semantics**: QMP `snapshot-save` writes VM state explicitly to the
  root disk node and snapshots both writable qcow2 nodes (root disk and EFI vars);
  `snapshot-load` restores them and `snapshot-delete` removes the tag from both.
  Snapshot metadata lives inside the qcow2 images; engine tags are the source of
  truth for existence. The human monitor's implicit `savevm` path is not used.
- **Clone**: offline only; recursive APFS `clonefile(2)` into a new bundle, regenerate
  UUID/name and (for VZ) `machine-id.bin`. If the volume is not APFS or clone fails,
  report the reason; do not silently copy tens of gigabytes.
- **Import**: `qemu-img info --output=json` → `qemu-img convert -p -O qcow2` (QEMU) or
  `-O raw` (VZ). Support qcow2, raw, vmdk, vdi, vhdx; OVA is a tar containing a VMDK,
  extracted to a temp directory first. Guest kind is chosen by the user; Macport does
  not guess from disk labels in this milestone.

### 3.7 Display

- VZ: unchanged, `VZVirtualMachineView` in the detail pane.
- QEMU: unchanged for this milestone — QEMU's Cocoa window, with `zoom-to-fit=on`.
  The host process ownership means the window survives the app. Embedding via VNC is
  Phase 4 research; the UI must keep saying "opens in its own window".
- `MacportVMHost` must not use a display-less backend when the user expects a window.
  Headless mode is an explicit flag, not a default.

### 3.8 Tools media and driver injection

- `MacportTools` (new, `MacportKit/Media/`) resolves a pinned virtio-win ISO:
  1. `MACPORT_TOOLS_ISO` environment variable;
  2. `~/Library/Application Support/Macport/Runtime/Tools/virtio-win.iso`;
  3. optional download from the pinned Fedora URL with size/SHA-256 verification.
- Mount read-only at a private mountpoint, stage the `arm64` driver trees, build a
  hybrid ISO with `hdiutil makehybrid -iso -joliet`, detach only that mountpoint.
- `UnattendMedia` gains `driverPaths: [String]` and `includesTools` options. The
  generated XML adds `Microsoft-Windows-PnpCustomizationsWinPE` → `DriverPaths` →
  `PathAndCredentials` entries.
- QEMU attaches the tools ISO as a second USB CD-ROM after the install media, so the
  expected drive letter is `E:`. This is an assumption to verify on the next Windows
  install; if Setup enumerates differently, the fix is the drive-letter probe script,
  not a hardcoded second guess.

---

## 4. Engine protocol v2

`MacportKit/Engine/VMEngine.swift` gains:

```swift
public struct VMSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: String          // engine tag
    public var name: String
    public var createdAt: Date
    public var includesMemory: Bool
}

public enum EngineCapabilities {
    // existing fields...
    public var pauseResume: Bool
    public var saveState: Bool
    public var snapshots: Bool
    public var backgroundHosting: Bool
    public var diskImport: Bool
}

public enum EngineError {
    // existing cases...
    case unsupportedFeature(String)
}

@MainActor
public protocol VMEngine {
    // existing...
    func pause() async throws
    func resume() async throws
    func listSnapshots() async throws -> [VMSnapshot]
    func takeSnapshot(named name: String) async throws -> VMSnapshot
    func restoreSnapshot(id: String) async throws
    func deleteSnapshot(id: String) async throws
}

extension VMEngine {
    func pause() async throws { throw EngineError.unsupportedFeature("pause") }
    // ...same for the rest; keeps VZ/QEMU compiling while capabilities say "no"
}
```

Capability truth:

| Capability | VZ | QEMU |
|---|---:|---:|
| pause/resume | **true** | **true** (QMP) |
| snapshots | false | **true** (qcow2) |
| save-state (RAM) | false | **true** (via QMP `snapshot-save`) |
| background hosting | false | **true** (`MacportVMHost`) |
| disk import | false | **true** (`qemu-img`) |

`VZEngine` implements pause/resume using `VZVirtualMachine.pause()` /
`resume()` and maps states. `QEMUEngine` implements the rest via QMP.

---

## 5. Workstreams

Each workstream owns a disjoint set of files. `project.yml` is integrated by the
build/release owner, not by feature workstreams.

### A — Core runtime registry and multi-VM state

**Owns** `MacportKit/Engine/VMEngine.swift`, new `MacportKit/Runtime/*`,
`Macport/App/AppState.swift`, new test files.

**Deliverables**

1. `EngineCapabilities` additions + default protocol methods.
2. `VMRuntimeRegistry`, `VMInstance`, `AdmissionControl`.
3. `AppState` facade with `instances` and per-VM state.
4. Unit tests with a mock engine: two VMs, admission denial, pause/resume flags.
5. No UI redesign; existing detail pane must still build.

**Acceptance** all three schemes build; two mock VMs can be started/stopped;
overcommit is refused with numbers; `VZEngine`/`QEMUEngine` compile unchanged except
capability values.

### B — QEMU QMP, pause/resume, snapshots

**Owns** `MacportKit/Engine/QEMUEngine.swift`, new `MacportKit/Engine/QMPClient.swift`,
new QEMU disk/snapshot tests.

**Deliverables**

1. `QMPClient`: connect, `qmp_capabilities`, JSON command/response, events, timeout.
2. Replace HMP-only lifecycle calls with QMP (`stop`, `cont`, `system_powerdown`,
   `human-monitor-command` fallback).
3. `pause`/`resume`, `listSnapshots`, `takeSnapshot`, `restoreSnapshot`,
   `deleteSnapshot`; clear `unsupportedFeature` errors for raw disks.
4. Snapshot names sanitised and tag-stable; metadata mapping to `VMSnapshot`.
5. Tests: fake QMP server for protocol; optional integration test against the vendored
   `qemu-img`/QEMU for a tiny qcow2.

**Acceptance** pause/resume works on a running Linux QEMU guest; snapshot/restore
works on qcow2; raw disk error names `macportctl disk convert`; no regression to the
existing Windows USB-CD boot path.

### C — MacportVMHost, control plane, CLI parity

**Owns** new `MacportKit/Control/*`, new `MacportVMHost/*`,
`MacportCtl/MacportCtl.swift`, `project.yml` target addition (with build owner).

**Deliverables**

1. NDJSON request/response types, Unix-socket server/client, stale-socket handling.
2. `MacportVMHost` executable: load config, start QEMU, serve control, write
   `runtime.json`, graceful signals, exit codes.
3. `HostedEngineProxy: VMEngine` forwarding to the socket; registry chooses it for
   QEMU.
4. App adopts hosts found via `runtime.json` on launch; app quit leaves QEMU hosts up.
5. CLI: `status [--json]`, `stop`, `pause`, `resume`, `snapshot`, `snapshots`,
   `restore`, `delete-snapshot`; `start` spawns a host and returns unless
   `--foreground`.
6. Per-VM `.lock` with `flock` to prevent double-start.

**Acceptance** `macportctl start win` returns; a second terminal can
`macportctl status win` and `macportctl stop win`; app sees the running host; stopping
the app does not kill it; starting the same VM twice is refused with a clear error.

### D — UI parity surfaces

**Owns** `Macport/Views/*`, `Macport/App/MacportApp.swift` (commands/menu bar).

**Deliverables**

1. Sidebar rows with state dot, engine chip, per-VM spinner/error.
2. Multi-VM toolbar: Start/Stop/Pause/Resume for the selected VM, capacity bar.
3. Machine Settings sheet: General, Hardware, Storage, Network, Shared Folders, Boot;
   "applies after restart" badges.
4. Snapshots timeline in the detail pane: create, restore, delete, size/date.
5. Import wizard using `qemu-img`-backed importer (from C/B).
6. Menu bar extra: running count, start/stop, open window.
7. Keep the existing design tokens and both appearances.

**Acceptance** builds; every action is wired or explicitly disabled with a reason; no
capability is shown as available when the engine says otherwise; UI-SPEC states match.

### E — Tools media and driver injection

**Owns** new `MacportKit/Media/MacportTools.swift`, `MacportKit/Media/UnattendMedia.swift`,
new tools-media tests. Does not edit `QEMUEngine.swift` (B attaches the media).

**Deliverables**

1. `MacportTools.resolve()` with env/cache/download paths and pinned version.
2. Read-only ISO mount/stage/build via `hdiutil`; explicit mountpoint detach only.
3. `ToolsMedia.build(to:)` staging `Autounattend.xml` + selected Arm64 drivers.
4. `UnattendMedia` `DriverPaths` support with configurable drive letters.
5. Tests: synthetic driver tree → ISO contains files; XML validates with `xmllint`.

**Acceptance** a tools ISO can be built from a local virtio-win ISO without touching
unrelated mounted volumes; answer XML contains the expected `DriverPaths`; no driver
binary is committed to the repo.

### F — Build, entitlements, runtime bundling

**Owns** `project.yml`, `MacportVMHost/MacportVMHost.entitlements`,
`Macport/Resources/Macport.entitlements`, new `scripts/*`.

**Deliverables**

1. Move `vm.networking`/`vm.device-access`/USB off the GUI entitlements; add
   `MacportVMHost/MacportVMHost.entitlements` for the host.
2. `scripts/vendor-runtime.sh`: copy the managed QEMU runtime into
   `Macport.app/Contents/Resources/Runtime/QEMU`, re-sign ad-hoc, verify no
   `/opt/homebrew` references.
3. `project.yml` post-compile script for the runtime (idempotent, skippable when the
   runtime is absent).
4. Test target addition after A lands; document `xcodegen generate` + both build
   commands.

**Acceptance** all three schemes build unsigned; built app contains the runtime when
present; `nm -m`/`otool -L` show no Homebrew paths; GUI entitlements contain no
restricted VM networking/device keys.

### G — vTPM (research, not this milestone)

`swtpm` is the right device answer, but building and signing it on macOS is its own
project. Keep the answer-file bypass until a vTPM is proven; do not claim `tpm: true`
in capabilities before then.

---

## 6. Sequencing and subagent allocation

**Wave 1 (parallel worktrees)**

| Worktree | Workstream | Files |
|---|---|---|
| `core-runtime` | A | `VMEngine.swift`, `Runtime/*`, `AppState.swift`, tests |
| `qemu-control` | B | `QEMUEngine.swift`, `QMPClient.swift`, QEMU tests |
| `tools-media` | E | `Media/MacportTools.swift`, `UnattendMedia.swift`, tests |
| `build-release` | F | `project.yml`, entitlements, scripts (assistant-owned) |

**Wave 2 (after A/B merge)**

| Worktree | Workstream | Depends on |
|---|---|---|
| `vm-host` | C | A (registry), B (QMP/snapshots) |
| `ui-parity` | D | A (per-VM state), C (actions) |

**Wave 3**

Integration, full build, boot regression (Ubuntu VZ, Windows QEMU), docs update,
screenshots. Merge in this order: A → B → E → F → C → D. Resolve `project.yml` and
`AppState` conflicts in the integration pass; no workstream edits another's files.

Subagent rules:

- Work only inside the assigned worktree, with absolute paths.
- Do not edit `docs/REFACTOR-PLAN.md`, `docs/FEATURE-PARITY.md`, `docs/UI-SPEC.md`, or
  `project.yml` (except the owner stated above).
- Build with `xcodegen generate` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO`.
- Report: files changed, commands run, build result, tests, known gaps.
- Do not download a 877 MB ISO or start a guest VM unless the task explicitly says so.

---

## 7. Verification matrix

| Check | Method | Pass condition |
|---|---|---|
| Baseline build | `xcodegen` + all three schemes | `BUILD SUCCEEDED` |
| Multi-VM registry | Unit test with mock engine | Two instances, independent states |
| Admission | Unit test with injected capacity | Overcommit refused with numbers |
| QMP handshake | Fake socket test | Capabilities negotiated, commands parsed |
| Pause/resume | QEMU Linux guest | State goes running → paused → running |
| Snapshot | qcow2 VM | Create/list/restore/delete round-trip |
| Raw disk error | Raw VM snapshot | Actionable `disk convert` message |
| Host persistence | Start from CLI, quit app | `status` still running, `stop` works |
| Double start | Two `macportctl start` | Second refused, no orphan QEMU |
| Clone | Offline VM | New bundle, new UUID, boots |
| Import | qcow2/vmdk sample | Converted disk boots |
| Tools media | Synthetic tree | ISO lists `autounattend.xml` + drivers |
| Entitlements | `codesign -d --entitlements` | GUI has no reserved VM networking keys |
| Runtime bundle | `otool -L` / `grep` | No `/opt/homebrew`, runtime present |
| VZ regression | Ubuntu 26.04 arm64 | Boots to desktop |
| Windows regression | Windows 11 arm64 | Setup still boots from USB CD |

---

## 8. Risks and non-goals

| Risk | Handling |
|---|---|
| Restricted entitlements unavailable | NAT-only shipped build; per-VM host ready for the grant; UI states the difference |
| VZ cannot be background-hosted | `backgroundHosting=false`; VZ VMs stop with the app; documented in UI and CLI |
| qcow2 migration loses data | convert to temp, fsync, rename, keep raw until first successful boot |
| 8 GB host | admission control reserves 2 GiB; default 4 GiB guest; capacity bar |
| QEMU Cocoa window owned by host | host is per-VM and survives app quit; embedding is Phase 4 |
| Driver drive-letter drift | tools ISO attached at a known position; verify on next install; probe script is the fallback |
| Scope creep toward Coherence/DX11 | `FEATURE-PARITY.md` §5 remains authoritative |

**Non-goals for this refactor:** Coherence, DirectX 11/12, GPU passthrough, bridged
QEMU networking without entitlement, free Windows licensing, a custom EDK2 build,
embedded QEMU console, vTPM (research only).

---

## 9. Definition of done for this refactor

A user can, without a terminal:

1. Create two VMs and run them at once, or be told exactly why the host cannot.
2. Pause and resume either VM.
3. Snapshot a QEMU VM, change it, and roll back.
4. Clone a stopped VM instantly and boot the clone.
5. Import a disk image and boot it.
6. Quit the app and have QEMU guests keep running; reopen and control them.
7. See per-VM engine, state, and capability truth in the sidebar and detail pane.
8. Install Windows with a network device and the driver media attached, or see a
   precise card explaining which piece is missing.

That is the Phase 2 contract. Everything after it — Macport Tools agent, clipboard,
dynamic resolution, menu bar extra, vTPM — builds on these boundaries rather than
replacing them.
