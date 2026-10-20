import Foundation

/// The QEMU engine — Macport's path to guests Virtualization.framework cannot host.
///
/// This engine exists because of one measured fact. Apple's framework has no
/// optical device at all (its entire storage menu is virtio-blk, NVMe and USB
/// mass storage), and a Windows 11 installer ISO carries no MBR, no GPT and no FAT
/// ESP — it bootstraps purely through El Torito, which firmware only consults on
/// media it identifies as *optical*. Presented as virtio-blk, as USB mass storage,
/// and as USB mass storage behind an XHCI controller, the installer spins at 100%
/// of one core with guest memory untouched and zero bytes written. Add no TPM
/// device and a fixed virtio device set Windows ships no drivers for and the
/// conclusion is structural, not fixable: UTM, tart and MacDow all reach it too.
///
/// QEMU supplies the missing pieces — a real CD-ROM, a device set with inbox
/// Windows drivers, and (later) a vTPM — while still running *accelerated* on
/// Apple silicon, because `-accel hvf` drives the same Hypervisor.framework that
/// Virtualization.framework uses underneath.
@MainActor
public final class QEMUEngine: NSObject, VMEngine {
    nonisolated public static let identifier = "qemu"
    nonisolated public static let displayName = "QEMU"

    /// One QEMU internal snapshot, as the engine sees it.
    ///
    /// A snapshot's engine-side identity *is* its qcow2 tag; QEMU stores no
    /// separate display name. `name` therefore repeats `id` here, and a pretty
    /// name lives in the bundle's `Snapshots/index.json` from the caller that
    /// created it. This type is deliberately separate from the engine
    /// protocol's `VMSnapshot`; the integration pass maps one onto the other.
    public struct QEMUSnapshot: Codable, Hashable, Identifiable, Sendable {
        /// The engine tag — what a restore or delete names.
        public var id: String
        /// Display name; equals `id` because that is all QEMU stores.
        public var name: String
        public var createdAt: Date
        /// Whether guest RAM was saved alongside the disk (`savevm` includes it
        /// when the machine's devices all support state serialisation).
        public var includesMemory: Bool

        public init(id: String, name: String, createdAt: Date, includesMemory: Bool) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.includesMemory = includesMemory
        }
    }

    /// Block format of the root disk. Only qcow2 can carry snapshots.
    enum DiskFormat: String, Sendable {
        case raw
        case qcow2
    }

    /// The root disk as found on disk, with the format read from its header
    /// rather than assumed from its name.
    struct DiskImage: Equatable {
        var url: URL
        var format: DiskFormat
    }

    nonisolated public static func capabilities(for guest: GuestKind) -> EngineCapabilities {
        EngineCapabilities(
            // Everything reported false here is false because Macport does not wire
            // it up *yet*, not because QEMU cannot do it. QEMU is capable of all of
            // them; claiming them today would be a promise the code does not keep.
            tpm: false,
            // The headline. A genuine CD-ROM device is what makes vendor installer
            // media bootable at all, and it is precisely what Apple's framework
            // cannot provide.
            opticalMedia: true,
            nestedVirtualization: false,
            graphics: .none,
            snapshots: true,
            sharedFolders: false,
            usbPassthrough: false,
            foreignArchitectureEmulation: false,
            // QEMU/QMP support all of these and Workstream B wired the
            // primitives. A raw disk still refuses snapshots at call time with a
            // conversion instruction; the engine-level capability is honest.
            pauseResume: true,
            saveState: true,
            backgroundHosting: true,
            diskImport: true
        )
    }

    nonisolated public static func availability() -> Result<Void, EngineError> {
        guard let tool = QEMURuntime.locate() else {
            return .failure(
                .runtimeMissing(
                    engine: displayName,
                    detail: "Macport can install it for you, or you can point "
                        + "MACPORT_QEMU_DIR at an existing QEMU build."
                )
            )
        }
        guard QEMURuntime.firmware(for: tool) != nil else {
            return .failure(
                .runtimeMissing(
                    engine: displayName,
                    detail: "QEMU is present at \(tool.systemBinary.path) but its UEFI "
                        + "firmware images are missing, so no guest could boot."
                )
            )
        }
        return .success(())
    }

    public private(set) var state: VMState = .stopped
    public private(set) var lastError: String?

    private var process: Process?
    /// Where the running machine's monitor socket lives.
    ///
    /// Recorded at start rather than re-derived, because it deliberately does *not*
    /// live in the VM bundle — see `monitorSocketPath(for:)`.
    private var monitorPath: String?
    /// QEMU's structured control channel, negotiated after launch.
    ///
    /// `nil` when the machine is not running, or when QEMU never listened — in
    /// which case `qmpUnavailableReason` says what happened and the QMP-backed
    /// operations (pause, resume, snapshots) report that reason instead of
    /// failing obscurely. A missing control channel never stops a boot.
    private var qmp: QMPClient?
    /// Why the QMP channel could not be reached, worded for a user.
    private var qmpUnavailableReason: String?
    /// The bundle this machine was created or started in.
    ///
    /// Snapshot commands inspect the disk image inside it, and re-deriving the
    /// path from the configuration would mean re-resolving the store and could
    /// disagree with what was actually booted.
    private var bundlePath: URL?

    public override init() { super.init() }

    // MARK: - Bundle preparation

    public func create(_ config: VMConfiguration, in bundle: URL) async throws {
        let tool = try Self.resolvedTool()
        let firmware = try Self.resolvedFirmware(for: tool)
        let fm = FileManager.default
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        bundlePath = bundle

        // Root disk. Created once and never recreated: the header decides the
        // format from then on, so a bundle made before qcow2 was the default
        // keeps booting exactly as it did.
        if Self.resolveDisk(in: bundle) == nil {
            try await Self.createDisk(for: config, in: bundle, tool: tool)
        }

        // UEFI variable store: a private, writable copy of the firmware template.
        //
        // It has to be per-VM and writable. A read-only store means the firmware
        // cannot record a boot order, so every boot would fall back to the
        // installer and the installed system would never start.
        //
        // It is qcow2, not raw, because a writable pflash device backed by a
        // format without snapshots cannot participate in a VM snapshot. The
        // older `savevm` path failed with "Device 'pflash1' is writable but does
        // not support snapshots"; QMP `snapshot-save` needs a snapshot-capable
        // node too. Existing bundles keep their NVRAM: the raw image is
        // converted, not discarded.
        let vars = bundle.appendingPathComponent(Self.varsFileName)
        if !fm.fileExists(atPath: vars.path) {
            let legacyVars = bundle.appendingPathComponent(Self.legacyVarsFileName)
            if fm.fileExists(atPath: legacyVars.path) {
                try await Self.convertVars(from: legacyVars, to: vars, tool: tool)
                try? fm.removeItem(at: legacyVars)
            } else if let template = firmware.varsTemplate {
                try await Self.convertVars(from: template, to: vars, tool: tool)
            } else if let qemuImg = tool.imageBinary {
                let result = await Self.runOffMainThread {
                    Self.runBlocking(
                        qemuImg,
                        ["create", "-f", "qcow2", vars.path,
                         String(Self.defaultVariableStoreBytes)]
                    )
                }
                guard result.status == 0 else {
                    throw EngineError.operationFailed(
                        "Could not create the EFI variable store at \(vars.path): "
                            + result.output
                    )
                }
            } else {
                // A runtime without qemu-img is unusual. Boot anyway with a raw
                // store rather than refusing the machine; snapshots will report
                // their own actionable error.
                guard fm.createFile(atPath: legacyVars.path, contents: nil) else {
                    throw EngineError.operationFailed("Could not create \(legacyVars.path).")
                }
                let handle = try FileHandle(forWritingTo: legacyVars)
                try handle.truncate(atOffset: Self.defaultVariableStoreBytes)
                try handle.close()
            }
        }

        if case .installMedia(let path) = config.boot {
            guard fm.fileExists(atPath: path) else {
                throw EngineError.installMediaMissing(path)
            }
        }
    }

    // MARK: - Lifecycle

    public func start(_ config: VMConfiguration, in bundle: URL) async throws {
        guard process == nil else {
            throw EngineError.operationFailed("This engine is already running a machine.")
        }
        let tool = try Self.resolvedTool()
        let firmware = try Self.resolvedFirmware(for: tool)

        state = .starting
        lastError = nil
        bundlePath = bundle

        // Stale socket files stop QEMU binding, so clear them before launch.
        // Both channels are re-created by the new process.
        let monitor = Self.monitorSocketPath(for: config.id)
        let qmpPath = Self.qmpSocketPath(for: config.id)
        try? FileManager.default.removeItem(atPath: monitor)
        try? FileManager.default.removeItem(atPath: qmpPath)
        monitorPath = monitor
        qmp?.disconnect()
        qmp = nil
        qmpUnavailableReason = nil

        let logURL = bundle.appendingPathComponent(Self.logFileName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        try log.truncate(atOffset: 0)

        // Macport Tools: the driver disc Windows needs for virtio devices and the
        // only place an Arm64 guest can get them without a second download. It is
        // built once per bundle and reused until the source ISO is replaced.
        //
        // Building it is best-effort. A machine without a driver disc still boots
        // and installs (NVMe is inbox), so failing to make one must not fail the
        // boot; the reason is written next to the bundle so it is discoverable
        // instead of silent.
        var toolsMedia: URL?
        if config.guest == .windowsARM, let toolsSource = MacportTools.resolve() {
            let destination = bundle.appendingPathComponent(Self.toolsMediaFileName)
            do {
                if Self.toolsMediaNeedsBuild(at: destination, source: toolsSource) {
                    let guest = config.guest
                    toolsMedia = try await Task.detached(priority: .userInitiated) {
                        try MacportTools.prepareMedia(
                            for: guest,
                            at: destination,
                            iso: toolsSource
                        )
                    }.value
                } else {
                    toolsMedia = destination
                }
            } catch {
                toolsMedia = nil
                let warning = bundle.appendingPathComponent(Self.toolsWarningFileName)
                try? Data(
                    ("Macport Tools media was not built: \(error.localizedDescription)\n")
                        .utf8
                ).write(to: warning)
            }
        }

        // Windows cannot be installed without a TPM to show it, so an installation has
        // to be handed the answer file that tells Setup to carry on without one.
        //
        // When the Tools disc is present it carries that answer file itself (with
        // the driver paths already pointing at its own `drivers` directory), so a
        // second answer disc would only give Setup two copies to choose between.
        // Without it, the standalone FAT volume is still required.
        var answerMedia: URL?
        if case .installMedia = config.boot,
           UnattendMedia.isNeeded(for: config.guest),
           toolsMedia == nil {
            let url = bundle.appendingPathComponent(Self.answerMediaFileName)
            try UnattendMedia.create(for: config.guest, at: url)
            answerMedia = url
        }

        let task = Process()
        task.executableURL = tool.systemBinary
        task.arguments = Self.arguments(
            for: config,
            bundle: bundle,
            firmware: firmware,
            answerMedia: answerMedia,
            toolsMedia: toolsMedia
        )
        task.standardOutput = log
        task.standardError = log

        do {
            try task.run()
        } catch {
            state = .error
            lastError = error.localizedDescription
            throw EngineError.operationFailed(
                "Could not launch \(tool.systemBinary.lastPathComponent): "
                    + error.localizedDescription
            )
        }

        process = task
        state = .running

        // Installation media waits for a keypress before it will start.
        if case .installMedia = config.boot {
            answerBootPrompt(in: bundle)
        }

        // Negotiate the structured monitor channel. This is best-effort: a
        // machine that boots without it is still a machine, and the operations
        // that need it say so with `qmpUnavailableReason` as the explanation.
        await establishControlChannel(at: qmpPath)

        // Learn about the exit rather than assuming the machine is alive. Without
        // this the engine would report `.running` for a guest that died at boot —
        // the exact bug Virtualization.framework exposed first.
        //
        // `Self.` is avoided deliberately: inside a closure in an instance method
        // it captures `self` strongly to know the dynamic type, which both retains
        // the engine for the process's lifetime and produces a capture-ownership
        // warning. A plain local string sidesteps both.
        let logName = QEMUEngine.logFileName
        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(status: status, logName: logName)
            }
        }
    }

    /// Answer the boot prompt that installation media draws, then stop pressing.
    ///
    /// Windows media draws "Press any key to boot from CD or DVD..." and waits about
    /// five seconds. If nothing arrives, the loader returns to the firmware, which
    /// reports the boot option as failed:
    ///
    ///     BdsDxe: failed to start Boot0001 "UEFI QEMU QEMU USB HARDDRIVE 1": Time out
    ///
    /// The machine then walks the rest of the boot order, which on a fresh machine is
    /// an empty disk and then the network. That window is short, it is often gone
    /// before the screen has even been drawn, and no one should have to win a race
    /// against it to install Windows. So Macport presses the key.
    ///
    /// The moment is *known* rather than guessed at: the firmware announces every
    /// attempt on the console it was given, so this waits for
    ///
    ///     BdsDxe: starting Boot0001 "..."
    ///
    /// and presses as soon as it sees it. Getting the timing right matters in both
    /// directions, and the failure is silent either way. Pressing before the firmware
    /// has finished attaching its keyboard does not merely fail — QEMU queues those
    /// USB reports, and they are delivered minutes later into whatever the installer
    /// is displaying; measured on this machine, a wall of early keypresses opened the
    /// installer's language list and scrolled it, then restarted the machine.
    /// Pressing after the loader has taken over is equally useless. So: wait for the
    /// announcement, press once, stop.
    private func answerBootPrompt(in bundle: URL) {
        guard let monitorPath else { return }
        let console = bundle.appendingPathComponent(Self.consoleFileName)

        Task { [weak self] in
            // Checked four times a second for up to a minute. Firmware reaches its
            // first boot attempt well inside that; the ceiling exists only so a machine
            // that never gets there does not leave this watching forever.
            var reachedBootAttempt = false
            for _ in 0..<Self.bootAttemptPolls {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.state == .running, self.process != nil else { return }
                if Self.firmwareHasStartedABoot(at: console) {
                    reachedBootAttempt = true
                    break
                }
            }
            guard reachedBootAttempt else { return }

            // Windows cdboot.efi takes ~1-2 seconds after BdsDxe starts to display
            // "Press any key to boot from CD or DVD......", then counts down 5 seconds.
            // Pulse the space key during that active window so the prompt is reliably caught.
            for offsetMs in [1000, 2000, 3000] {
                try? await Task.sleep(nanoseconds: UInt64(offsetMs) * 1_000_000)
                guard let self, self.state == .running, self.process != nil else { return }
                Self.sendMonitorCommand("sendkey spc\n", at: monitorPath)
            }
        }
    }

    /// Whether the firmware has begun a boot attempt.
    ///
    /// Answered from the console the firmware is already writing to. That costs no
    /// polling of the process, assumes nothing about how long firmware takes to get
    /// this far, and asks nothing of the guest.
    nonisolated private static func firmwareHasStartedABoot(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("starting Boot")
    }

    /// Reflect a finished process in the engine's published state.
    private func handleTermination(status: Int32, logName: String) {
        process = nil
        monitorPath = nil
        qmp?.disconnect()
        qmp = nil
        if state == .stopping || state == .stopped {
            state = .stopped
        } else if status == 0 {
            state = .stopped
        } else {
            state = .error
            lastError = "QEMU exited with status \(status). See \(logName) in the VM bundle."
        }
    }

    public func stop() async throws {
        guard let process else { return }
        // A paused guest cannot process an ACPI event, so wake it before asking
        // it to shut down; otherwise the request sits unread until the timeout.
        let wasPaused = state == .paused
        state = .stopping

        // An ACPI power-button press, not a kill: `system_powerdown` asks the
        // *guest* to shut down, so Windows flushes its filesystems and closes
        // cleanly instead of losing them to a summary termination.
        //
        // QMP is preferred now that it exists — it is structured, so a failure
        // is a typed error rather than silence — and the HMP socket remains the
        // fallback for a machine whose control channel never came up.
        var requested = false
        if let qmp {
            if wasPaused {
                _ = try? await qmp.execute("cont")
            }
            do {
                _ = try await qmp.execute("system_powerdown")
                requested = true
            } catch {
                requested = false
            }
        }
        if !requested, let monitorPath {
            Self.sendMonitorCommand("system_powerdown\n", at: monitorPath)
        }

        // Give the guest a bounded window to comply, then escalate. A shutdown
        // request that is not honoured still has to leave the machine stopped.
        for _ in 0..<30 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if process.isRunning { process.terminate() }
    }

    public func forceStop() async throws {
        guard let process else { return }
        state = .stopping
        if process.isRunning { process.terminate() }

        // SIGTERM lets QEMU write out its state; SIGKILL is the backstop for a
        // wedged hypervisor that ignores it.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
        monitorPath = nil
        qmp?.disconnect()
        qmp = nil
        state = .stopped
    }

    // MARK: - Machine control (QMP)

    /// Negotiate QMP after launch, retrying while QEMU brings its socket up.
    ///
    /// Failure is recorded, never thrown: the guest is booting and a monitor
    /// channel that is unavailable must not interrupt it. Later operations that
    /// need the channel report `qmpUnavailableReason` as their explanation.
    private func establishControlChannel(at path: String) async {
        let client = QMPClient(path: path)
        let deadline = Date().addingTimeInterval(Self.qmpConnectBudget)
        var lastError: (any Error)?

        // Retries are cheap when the socket file does not exist yet (connect
        // fails immediately with ENOENT) and bounded overall, so a machine that
        // never opens its monitor costs seconds, not the boot.
        while Date() < deadline {
            if process == nil { break }
            do {
                try await client.connect()
                qmp = client
                qmpUnavailableReason = nil
                return
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: Self.qmpConnectRetryDelay)
            }
        }

        client.disconnect()
        qmp = nil
        qmpUnavailableReason = lastError?.localizedDescription
            ?? "QEMU did not open its monitor socket."
    }

    /// Pause the running guest without ending the process — QMP `stop`.
    ///
    /// Not a `VMEngine` requirement yet: the protocol additions (`pause()`,
    /// snapshots) belong to the registry workstream.
    public func pauseMachine() async throws {
        let channel = try controlChannel(for: "Pause")
        _ = try await command("stop", context: "Could not pause the machine", on: channel)
        state = .paused
    }

    /// Resume a paused guest — QMP `cont`.
    public func resumeMachine() async throws {
        let channel = try controlChannel(for: "Resume")
        _ = try await command("cont", context: "Could not resume the machine", on: channel)
        state = .running
    }

    /// The snapshots QEMU holds for this machine's root disk.
    ///
    /// The root node's `query-block` entry is authoritative; the human monitor's
    /// `info snapshots` table is the fallback for builds that do not name the
    /// node the same way.
    public func listMachineSnapshots() async throws -> [QEMUSnapshot] {
        try ensureSnapshotsSupported()
        let channel = try controlChannel(for: "Snapshots")
        return try await Self.listSnapshots(on: channel)
    }

    /// The snapshot table from whichever query this build answers.
    ///
    /// `query-block` is authoritative: it reports the snapshot list of each
    /// block node, so the root disk's table can be read even though the EFI
    /// varstore also carries the same tags. `query-snapshots` was removed from
    /// recent QEMU, and the human monitor's table may describe whichever device
    /// it considers current — neither is a reliable substitute when two
    /// devices are snapshotted together.
    nonisolated private static func listSnapshots(on channel: QMPClient) async throws -> [QEMUSnapshot] {
        if let payload = try? await channel.execute("query-block"),
           let blocks = payload.arrayValue {
            for block in blocks {
                guard let inserted = block["inserted"],
                      inserted["node-name"]?.stringValue == rootNodeName else {
                    continue
                }
                // The root node was found. A missing `snapshots` member means it
                // has none; an unrecognised member shape is not the same thing,
                // and falls through to the human-monitor parse.
                guard let image = inserted["image"] else { return [] }
                guard let snapshots = image["snapshots"] else { return [] }
                if let parsed = parseSnapshotListQMP(snapshots) { return parsed }
                break
            }
        }

        let text = try await humanMonitor("info snapshots", on: channel)
        return parseSnapshotListHMP(text)
    }

    /// Take a snapshot of the machine: RAM and disk, under a stable tag.
    ///
    /// QMP's `snapshot-save` is asynchronous and writes the VM state to an
    /// explicit block node. That explicitness matters here: HMP `savevm` picks
    /// the first writable qcow2 device, which used to be the EFI varstore, so
    /// 2 GiB of guest RAM was compressed into a 64 MiB NVRAM image. The root
    /// disk is named as the state target instead, and both writable qcow2 nodes
    /// are snapshotted together.
    ///
    /// Returns the snapshot as QEMU records it — the caller's display name is
    /// sanitised into the tag, and the pretty name belongs in the bundle index.
    @discardableResult
    public func takeMachineSnapshot(named name: String) async throws -> QEMUSnapshot {
        try ensureSnapshotsSupported()
        let channel = try controlChannel(for: "Snapshots")
        let tag = Self.sanitizeSnapshotName(name)
        let wasRunning = try await machineIsRunning(on: channel)

        let jobID = "macport-save-\(UUID().uuidString)"
        do {
            _ = try await channel.execute(
                "snapshot-save",
                arguments: [
                    "job-id": .string(jobID),
                    "tag": .string(tag),
                    "vmstate": .string(Self.rootNodeName),
                    "devices": .array([
                        .string(Self.rootNodeName),
                        .string(Self.varsNodeName),
                    ]),
                ]
            )
            try await Self.waitForSnapshotJob(jobID, operation: "save", on: channel)
        } catch {
            // Leave the machine as it was found, even though the save failed.
            if wasRunning { _ = try? await channel.execute("cont") }
            throw Self.engineError(from: error, operation: "Could not take the snapshot")
        }

        try await restoreRunState(
            wasRunning: wasRunning,
            channel: channel
        )
        state = wasRunning ? .running : .paused

        let fresh = try await Self.listSnapshots(on: channel)
        guard let match = fresh.first(where: { $0.id == tag }) else {
            throw EngineError.operationFailed(
                "QEMU finished the snapshot job but did not record “\(tag)”."
            )
        }
        return match
    }

    /// Restore the machine to a snapshot's RAM and disk state.
    ///
    /// `snapshot-load` replaces device state as well as memory. QEMU pauses and
    /// resumes the guest itself as part of the job, but the end state is still
    /// corrected explicitly: a machine that was paused before the restore must
    /// not come back running.
    public func restoreMachineSnapshot(id: String) async throws {
        try ensureSnapshotsSupported()
        let channel = try controlChannel(for: "Restore")
        let tag = Self.sanitizeSnapshotName(id)
        let wasRunning = try await machineIsRunning(on: channel)

        let jobID = "macport-load-\(UUID().uuidString)"
        do {
            _ = try await channel.execute(
                "snapshot-load",
                arguments: [
                    "job-id": .string(jobID),
                    "tag": .string(tag),
                    "vmstate": .string(Self.rootNodeName),
                    "devices": .array([
                        .string(Self.rootNodeName),
                        .string(Self.varsNodeName),
                    ]),
                ]
            )
            try await Self.waitForSnapshotJob(jobID, operation: "restore", on: channel)
        } catch {
            if wasRunning { _ = try? await channel.execute("cont") }
            throw Self.engineError(from: error, operation: "Could not restore the snapshot")
        }

        try await restoreRunState(wasRunning: wasRunning, channel: channel)
        state = wasRunning ? .running : .paused
    }

    /// Delete a snapshot from every writable node that carries it.
    ///
    /// Existence is checked against the listing first: a caller deleting a
    /// snapshot the machine does not have gets an error, not a false success.
    public func deleteMachineSnapshot(id: String) async throws {
        try ensureSnapshotsSupported()
        let channel = try controlChannel(for: "Delete snapshot")
        let tag = Self.sanitizeSnapshotName(id)

        let snapshots = try await Self.listSnapshots(on: channel)
        guard snapshots.contains(where: { $0.id == tag }) else {
            throw EngineError.operationFailed("There is no snapshot named “\(tag)” to delete.")
        }

        let jobID = "macport-delete-\(UUID().uuidString)"
        do {
            _ = try await channel.execute(
                "snapshot-delete",
                arguments: [
                    "job-id": .string(jobID),
                    "tag": .string(tag),
                    "devices": .array([
                        .string(Self.rootNodeName),
                        .string(Self.varsNodeName),
                    ]),
                ]
            )
            try await Self.waitForSnapshotJob(jobID, operation: "delete", on: channel)
        } catch {
            throw Self.engineError(from: error, operation: "Could not delete the snapshot")
        }

        let after = try await Self.listSnapshots(on: channel)
        guard !after.contains(where: { $0.id == tag }) else {
            throw EngineError.operationFailed(
                "QEMU reported the delete job finished, but “\(tag)” is still listed."
            )
        }
    }

    /// Wait for a snapshot job to conclude, and surface QEMU's own error.
    ///
    /// Snapshot jobs auto-dismiss on completion in some builds, so a job that
    /// has disappeared is not itself a failure: the caller verifies the
    /// snapshot table afterwards. A `concluded` job carrying an error is a
    /// failure and its text is preserved.
    nonisolated private static func waitForSnapshotJob(
        _ jobID: String,
        operation: String,
        on channel: QMPClient
    ) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let payload = try await channel.execute("query-jobs")
            let jobs = payload.arrayValue ?? []
            guard let job = jobs.first(where: { $0["id"]?.stringValue == jobID }) else {
                return
            }
            let status = job["status"]?.stringValue ?? ""
            if status == "concluded" {
                if let error = job["error"]?.stringValue, !error.isEmpty {
                    throw EngineError.operationFailed(
                        "QEMU could not \(operation) the snapshot: \(error)"
                    )
                }
                _ = try? await channel.execute(
                    "job-dismiss",
                    arguments: ["id": .string(jobID)]
                )
                return
            }
            if status == "null" { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw EngineError.operationFailed(
            "QEMU did not finish the snapshot \(operation) job within two minutes."
        )
    }

    /// Put the guest back into the run state the caller found.
    private func restoreRunState(
        wasRunning: Bool,
        channel: QMPClient
    ) async throws {
        let runningNow = try await machineIsRunning(on: channel)
        if wasRunning && !runningNow {
            _ = try await command(
                "cont",
                context: "Could not resume the machine after a snapshot operation",
                on: channel
            )
        } else if !wasRunning && runningNow {
            _ = try await command(
                "stop",
                context: "Could not pause the machine after a snapshot operation",
                on: channel
            )
        }
    }

    // MARK: - VMEngine v2 bridge

    // Workstream B implemented the QEMU-facing primitives above; these adapters
    // expose them through the engine protocol without duplicating any logic. The
    // split kept B compiling independently of A's protocol addition, and keeps
    // the QMP details out of the registry.

    public func pause() async throws {
        try await pauseMachine()
    }

    public func resume() async throws {
        try await resumeMachine()
    }

    public func listSnapshots() async throws -> [VMSnapshot] {
        try await listMachineSnapshots().map(Self.protocolSnapshot)
    }

    public func takeSnapshot(named name: String) async throws -> VMSnapshot {
        Self.protocolSnapshot(try await takeMachineSnapshot(named: name))
    }

    public func restoreSnapshot(id: String) async throws {
        try await restoreMachineSnapshot(id: id)
    }

    public func deleteSnapshot(id: String) async throws {
        try await deleteMachineSnapshot(id: id)
    }

    private nonisolated static func protocolSnapshot(_ snapshot: QEMUSnapshot) -> VMSnapshot {
        VMSnapshot(
            id: snapshot.id,
            name: snapshot.name,
            createdAt: snapshot.createdAt,
            includesMemory: snapshot.includesMemory
        )
    }

    /// The QMP channel, or a clear error saying why there is none.
    ///
    /// This is the "unavailable" report the plan asks for: a machine whose
    /// control channel never came up keeps booting, and the operations that
    /// needed it explain themselves instead of failing with a socket errno.
    private func controlChannel(for operation: String) throws -> QMPClient {
        guard let qmp else {
            let reason = qmpUnavailableReason ?? "the machine is not running"
            // A dedicated `unsupportedFeature` case lands with the engine
            // protocol work; until then this is the honest wording.
            throw EngineError.operationFailed(
                "\(operation) needs QEMU's control channel (QMP), which is not "
                    + "available here: \(reason)"
            )
        }
        return qmp
    }

    /// Run one QMP command, mapping failures into the engine's error type.
    private func command(
        _ name: String,
        context: String,
        on channel: QMPClient
    ) async throws -> QMPValue {
        do {
            return try await channel.execute(name)
        } catch {
            throw Self.engineError(from: error, operation: context)
        }
    }

    /// Whether the guest is executing, per QEMU's own bookkeeping.
    private func machineIsRunning(on channel: QMPClient) async throws -> Bool {
        let status = try await command(
            "query-status",
            context: "Could not read the machine's state",
            on: channel
        )
        if let running = status["running"]?.boolValue { return running }
        return status["status"]?.stringValue == "running"
    }

    /// Send one human-monitor command over QMP and return its text output.
    ///
    /// HMP has no error channel of its own, so the reply is inspected before it
    /// is treated as success; see `humanMonitorError(in:)`.
    nonisolated private static func humanMonitor(
        _ command: String,
        on channel: QMPClient
    ) async throws -> String {
        let output: String
        do {
            let value = try await channel.execute(
                "human-monitor-command",
                arguments: ["command-line": .string(command)]
            )
            output = value.stringValue ?? ""
        } catch {
            throw engineError(from: error, operation: "QEMU rejected “\(command)”")
        }

        if let failure = humanMonitorError(in: output) {
            throw EngineError.operationFailed("QEMU rejected “\(command)”: \(failure)")
        }
        return output
    }

    /// The failure a human-monitor command reports inside its own output.
    ///
    /// HMP failures are ordinary text: `savevm`, `loadvm` and `delvm` write an
    /// `Error: ...` line and still return a normal QMP reply, and the monitor
    /// answers an unknown command the same way (`unknown command: 'x'`). A
    /// success reply is empty or a table; both known failure spellings start a
    /// line, so a line prefix is the whole test.
    nonisolated static func humanMonitorError(in output: String) -> String? {
        // HMP output is CRLF-terminated; `Character.isNewline` splits both
        // endings (a CRLF grapheme cluster is not matched by "\n").
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Error:") {
                return line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("unknown command:") {
                return line
            }
        }
        return nil
    }

    /// Word a QMP failure the way a user can act on it.
    nonisolated static func engineError(from error: any Error, operation: String) -> EngineError {
        if let engineError = error as? EngineError { return engineError }
        if let qmpError = error as? QMPError {
            if case .commandFailed(_, _, let description) = qmpError, !description.isEmpty {
                return .operationFailed("\(operation): \(description)")
            }
            return .operationFailed("\(operation): \(qmpError.localizedDescription)")
        }
        return .operationFailed("\(operation): \(error.localizedDescription)")
    }

    // MARK: - Snapshot support

    /// Fail early — and actionably — when a snapshot command cannot work.
    ///
    /// The disk is checked before the control channel on purpose. A raw disk is
    /// the common case for machines made before qcow2 was the default, and
    /// "convert it first" is a different, more useful message than "no socket".
    private func ensureSnapshotsSupported() throws {
        guard let bundlePath else {
            throw EngineError.operationFailed(
                "Snapshots need this machine's bundle, and the engine has not "
                    + "been pointed at one yet."
            )
        }
        guard let disk = Self.resolveDisk(in: bundlePath) else {
            throw EngineError.operationFailed("No disk image found in \(bundlePath.path).")
        }
        guard disk.format == .qcow2 else {
            throw Self.snapshotUnsupportedError(diskPath: disk.url.path)
        }
        // The varstore is writable, so leaving it raw makes QEMU fail the
        // snapshot after the user has already waited for the job to start.
        // `create` converts it on the next start; say so here.
        if let vars = Self.resolveVars(in: bundlePath), vars.format != .qcow2 {
            throw EngineError.operationFailed(
                "This machine's EFI variable store is still a raw image, so it "
                    + "cannot be snapshotted. Stop and start the machine once to "
                    + "convert it, then try again."
            )
        }
    }

    /// The error a snapshot attempt on a raw disk produces.
    ///
    /// It names the exact fix: raw images have nowhere to store a snapshot, and
    /// converting to qcow2 is a one-command migration with nothing lost.
    nonisolated static func snapshotUnsupportedError(diskPath: String) -> EngineError {
        .operationFailed(
            "This machine's disk is a raw image, which cannot hold snapshots. "
                + "Convert it first with `macportctl disk convert` "
                + "(a qcow2 disk keeps the same contents; a raw one cannot store a snapshot). "
                + "Disk: \(diskPath)"
        )
    }

    /// The machine's root disk, if one exists.
    ///
    /// Probed by existence, and its *format* is read from the file header —
    /// never guessed from the name, because the name is only a convention and a
    /// wrong guess would hand QEMU the wrong driver.
    nonisolated static func resolveDisk(in bundle: URL) -> DiskImage? {
        let fileManager = FileManager.default
        let qcow = bundle.appendingPathComponent(qcowDiskFileName)
        let raw = bundle.appendingPathComponent(diskFileName)
        let candidate: URL
        if fileManager.fileExists(atPath: qcow.path) {
            candidate = qcow
        } else if fileManager.fileExists(atPath: raw.path) {
            candidate = raw
        } else {
            return nil
        }
        return DiskImage(url: candidate, format: diskFormat(at: candidate) ?? .raw)
    }

    /// The machine's writable EFI variable store, if one exists.
    ///
    /// New bundles use `efi-vars.qcow2`; a bundle that has not been started
    /// since the conversion may still carry the legacy raw file. The format is
    /// read from the header, not guessed from the name.
    nonisolated static func resolveVars(in bundle: URL) -> DiskImage? {
        let fileManager = FileManager.default
        let qcow = bundle.appendingPathComponent(varsFileName)
        let raw = bundle.appendingPathComponent(legacyVarsFileName)
        let candidate: URL
        if fileManager.fileExists(atPath: qcow.path) {
            candidate = qcow
        } else if fileManager.fileExists(atPath: raw.path) {
            candidate = raw
        } else {
            return nil
        }
        return DiskImage(url: candidate, format: diskFormat(at: candidate) ?? .raw)
    }

    /// Read a disk image's format from its first four bytes.
    ///
    /// A qcow2 file starts with the magic `QFI\xfb`; everything else is treated
    /// as raw. Returns `nil` only when the file cannot be read at all.
    nonisolated static func diskFormat(at url: URL) -> DiskFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
        return header == Data([0x51, 0x46, 0x49, 0xFB]) ? .qcow2 : .raw
    }

    /// Create the root disk, preferring qcow2 so the machine can be snapshotted
    /// from its first boot.
    ///
    /// Falls back to a sparse raw file when `qemu-img` is missing: a runtime
    /// without the image tool is unusual, but a machine that boots is worth
    /// more than one that could be snapshotted. Both are sparse — a declared
    /// 80 GB ceiling costs nothing until the guest writes.
    nonisolated private static func createDisk(
        for config: VMConfiguration,
        in bundle: URL,
        tool: QEMURuntime.Tool
    ) async throws {
        if let qemuImg = tool.imageBinary {
            let disk = bundle.appendingPathComponent(qcowDiskFileName)
            let result = await runOffMainThread {
                runBlocking(qemuImg, ["create", "-f", "qcow2", disk.path, String(config.diskBytes)])
            }
            if result.status == 0 { return }
            // A failed create can leave a partial header behind, and the header
            // is what the engine trusts — so remove it before falling back.
            try? FileManager.default.removeItem(at: disk)
        }

        let disk = bundle.appendingPathComponent(diskFileName)
        guard FileManager.default.createFile(atPath: disk.path, contents: nil) else {
            throw EngineError.operationFailed("Could not create \(disk.path).")
        }
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: config.diskBytes)
        try handle.close()
    }

    /// Convert the firmware template or a legacy raw varstore into qcow2.
    ///
    /// pflash is writable, and QEMU will not include a writable device in an
    /// internal snapshot unless its format supports snapshots. qcow2 is that
    /// format (and the only one that lets the varstore participate in rollback
    /// at all). The conversion is a one-time, 64 MiB operation per bundle.
    nonisolated private static func convertVars(
        from source: URL,
        to destination: URL,
        tool: QEMURuntime.Tool
    ) async throws {
        guard let qemuImg = tool.imageBinary else {
            throw EngineError.runtimeMissing(
                engine: "QEMU",
                detail: "qemu-img is needed to prepare the EFI variable store."
            )
        }
        let result = await runOffMainThread {
            runBlocking(
                qemuImg,
                ["convert", "-f", "raw", "-O", "qcow2", source.path, destination.path]
            )
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw EngineError.operationFailed(
                "Could not prepare the EFI variable store at \(destination.path): "
                    + result.output
            )
        }
    }

    /// Run a purely synchronous helper off the main actor.
    nonisolated private static func runOffMainThread<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Run a child process and capture its output. Blocking; call off-main.
    nonisolated private static func runBlocking(
        _ executable: URL,
        _ arguments: [String]
    ) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Drain before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Reduce a display name to a QEMU-safe snapshot tag.
    ///
    /// QEMU tags travel through a human-monitor command line, so a tag cannot
    /// contain whitespace or shell-ish punctuation. Everything outside
    /// `[A-Za-z0-9._-]` becomes `-`, the result is capped at 64 characters and
    /// never empty, and the mapping is deterministic — `restore(id:)` uses the
    /// same rule, so a tag round-trips exactly.
    nonisolated static func sanitizeSnapshotName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var mapped = String(raw.map { allowed.contains($0) ? $0 : "-" })
        if mapped.count > 64 { mapped = String(mapped.prefix(64)) }
        // A name made entirely of separators would be an empty tag.
        let meaningful = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return meaningful.isEmpty ? "snapshot" : mapped
    }

    /// Parse QMP `query-snapshots` output where a build answers it.
    ///
    /// The command is not present in every QEMU, and its payload has varied,
    /// so this is deliberately forgiving: it extracts the fields that identify
    /// a snapshot — tag and time — from whichever spellings a build uses, and
    /// returns `nil` for a shape it does not recognise so the caller falls back
    /// to the human monitor's table.
    nonisolated static func parseSnapshotListQMP(_ payload: QMPValue) -> [QEMUSnapshot]? {
        let entries: [QMPValue]
        if let array = payload.arrayValue {
            entries = array
        } else if let nested = payload["snapshots"]?.arrayValue {
            entries = nested
        } else {
            return nil
        }

        var snapshots: [QEMUSnapshot] = []
        for entry in entries {
            guard let object = entry.objectValue else { return nil }
            let tag = (object["name"] ?? object["tag"] ?? object["id"])?.stringValue
                ?? object["id"]?.intValue.map(String.init)
            guard let tag, !tag.isEmpty else { return nil }

            var created = Date()
            if let seconds = (object["date-sec"] ?? object["date"])?.intValue {
                let nanoseconds = object["date-nsec"]?.intValue ?? 0
                created = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
            }
            let stateBytes = (object["vm-state-size"] ?? object["vm-state-size-bytes"])?.intValue ?? 0
            snapshots.append(
                QEMUSnapshot(
                    id: tag,
                    name: tag,
                    createdAt: created,
                    includesMemory: stateBytes > 0
                )
            )
        }
        return snapshots
    }

    /// Parse the human monitor's `info snapshots` table.
    ///
    /// QEMU 11 prints
    ///
    ///     ID      TAG               VM_SIZE                DATE        VM_CLOCK     ICOUNT
    ///     --      Before update         0 B 2026-10-19 23:05:48  0000:00:00.000          0
    ///
    /// (older builds spell the headers `VM SIZE` / `VM CLOCK` and stop at the
    /// clock). QEMU prints `There is no snapshot available.` when the disk has
    /// none. Column widths differ between versions, so a snapshot row is
    /// recognised by the date column — the one field with an unambiguous shape —
    /// and the tag is whatever sits between the id and the size.
    nonisolated static func parseSnapshotListHMP(_ text: String) -> [QEMUSnapshot] {
        let emptyMarkers = [
            "There is no snapshot available",
            "There are no snapshots",
            "There is no snapshot on",
        ]

        var snapshots: [QEMUSnapshot] = []
        // QEMU terminates HMP lines with CRLF, and Swift treats CRLF as one
        // grapheme cluster — so splitting on "\n" would see the whole table as
        // one line. Split on newline characters instead.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if emptyMarkers.contains(where: { line.hasPrefix($0) }) { continue }
            if line.hasPrefix("ID") && line.contains("TAG") { continue }
            if line.hasPrefix("List of snapshots") { continue }
            if line.hasPrefix("Snapshot list") { continue }

            guard let match = snapshotRow(line) else { continue }
            snapshots.append(match)
        }
        return snapshots
    }

    /// One `info snapshots` row, or `nil` for a line that is not one.
    private nonisolated static func snapshotRow(_ line: String) -> QEMUSnapshot? {
        // Anchored on the date, which is the only column with a fixed shape.
        // ID is a number or `--`; TAG may contain spaces; SIZE is a byte count
        // or `--`/`unavailable`; then date, then clock. QEMU 11's clock hours
        // run to four digits (`0000:00:00.000`) and an ICOUNT column follows
        // the clock, so the match is not anchored at the end.
        let pattern = #"^(--|\d+)\s+(.+?)\s+(\d+(?:\.\d+)?\s*[KMGTP]?i?B|--|unavailable)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+([0-9]+:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?|--)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 6 else { return nil }

        func group(_ index: Int) -> String? {
            guard let groupRange = Range(match.range(at: index), in: line) else { return nil }
            return String(line[groupRange])
        }

        guard let tag = group(2)?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else {
            return nil
        }
        let size = group(3).flatMap(byteCount(from:)) ?? 0
        let created = group(4).flatMap(snapshotDate(from:)) ?? Date()
        return QEMUSnapshot(id: tag, name: tag, createdAt: created, includesMemory: size > 0)
    }

    /// Convert `info snapshots`' human size ("131 MB") into bytes.
    private nonisolated static func byteCount(from text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "--" || trimmed == "unavailable" { return nil }
        let upper = trimmed.uppercased()
        let multipliers: [(String, UInt64)] = [
            ("TIB", 1 << 40), ("GIB", 1 << 30), ("MIB", 1 << 20), ("KIB", 1 << 10),
            ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10),
            ("B", 1),
        ]
        for (suffix, multiplier) in multipliers where upper.hasSuffix(suffix) {
            let number = upper.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(number) else { return nil }
            return UInt64(value * Double(multiplier))
        }
        return UInt64(upper)
    }

    /// Parse the `info snapshots` date (local time, as QEMU prints it).
    private nonisolated static func snapshotDate(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)
    }

    // MARK: - Command line

    nonisolated private static let diskFileName = "disk.img"
    /// The snapshot-capable root disk new machines get, when `qemu-img` can
    /// create one. Old bundles keep `disk.img`; the header, not the name,
    /// decides how either is opened.
    nonisolated private static let qcowDiskFileName = "disk.qcow2"
    nonisolated private static let varsFileName = "efi-vars.qcow2"
    /// Pre-qcow2 bundles stored the variable store raw under this name.
    nonisolated private static let legacyVarsFileName = "efi-vars.fd"
    /// Stable block-node names for QMP's `snapshot-save`/`snapshot-load`.
    ///
    /// These are deliberately not the drive ids: QEMU keeps backend ids and
    /// graph node names in separate namespaces, and snapshot commands address
    /// the graph node. Being explicit keeps the monitor commands independent of
    /// QEMU's `#blockNNN` auto-naming, which changes with topology.
    nonisolated private static let rootNodeName = "macport-root"
    nonisolated private static let varsNodeName = "macport-vars"
    nonisolated private static let logFileName = "qemu.log"
    nonisolated private static let consoleFileName = "console.log"
    /// The removable disk carrying Setup's answer file, when one is needed.
    nonisolated private static let answerMediaFileName = "answer-media.img"
    /// The generated driver disc. Not shipped: built from the user's virtio-win
    /// ISO so Macport never redistributes Microsoft's signed driver package.
    nonisolated private static let toolsMediaFileName = "tools-media.iso"
    /// Why the driver disc could not be built, left where a person will look.
    nonisolated private static let toolsWarningFileName = "tools-media-warning.txt"
    nonisolated private static let defaultVariableStoreBytes: UInt64 = 64 * 1024 * 1024

    /// Whether the cached Tools disc is older than the ISO it was built from.
    ///
    /// Modification time rather than a digest: rebuilding is cheap relative to a
    /// Windows install, and a false positive costs one extra staging pass. A
    /// missing or empty destination always rebuilds.
    nonisolated static func toolsMediaNeedsBuild(at destination: URL, source: URL) -> Bool {
        let fileManager = FileManager.default
        guard
            let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination.path),
            let destinationDate = destinationAttributes[.modificationDate] as? Date,
            let size = destinationAttributes[.size] as? NSNumber,
            size.int64Value > 0,
            let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path),
            let sourceDate = sourceAttributes[.modificationDate] as? Date
        else {
            return true
        }
        return sourceDate > destinationDate
    }

    /// How many quarter-second checks to make while waiting for the firmware to reach
    /// its first boot attempt — one minute's worth.
    nonisolated private static let bootAttemptPolls = 240

    /// How long QMP negotiation may take before the control channel is called
    /// unavailable. Generous, because the price of being late is one line in the
    /// logs and the price of being impatient is a working machine with no pause.
    nonisolated private static let qmpConnectBudget: TimeInterval = 8
    nonisolated private static let qmpConnectRetryDelay: UInt64 = 300_000_000

    /// The kernel's `sun_path` caps a unix socket path at 104 bytes, and a VM
    /// bundle under Application Support passes that the moment the user's account
    /// name is more than a few characters — QEMU then refuses to start with
    /// "UNIX socket path is too long" and nothing else.
    ///
    /// So the monitor sockets live outside the bundle, in a short, per-user
    /// location keyed by the machine's identifier. The bundle keeps the log and the
    /// console, which are ordinary files and have no such limit.
    nonisolated private static let sunPathCapacity = 104

    nonisolated private static func monitorSocketPath(for id: UUID) -> String {
        socketPath(named: "macport-\(id.uuidString.prefix(8)).monitor")
    }

    /// The QMP socket, one per machine, beside the human monitor.
    ///
    /// `.qmp` is appended when the monitor path leaves room; when it does not,
    /// a shorter name in the same directory is used rather than a truncated
    /// path, because a truncated path means QEMU silently binds nothing.
    nonisolated private static func qmpSocketPath(for id: UUID) -> String {
        let derived = monitorSocketPath(for: id) + ".qmp"
        if derived.utf8.count < sunPathCapacity { return derived }
        return socketPath(named: "macport-\(id.uuidString.prefix(8)).qmp")
    }

    /// The VNC framebuffer socket for headless embedded console display.
    public nonisolated static func vncSocketPath(for id: UUID) -> String {
        let derived = monitorSocketPath(for: id) + ".vnc"
        if derived.utf8.count < sunPathCapacity { return derived }
        return socketPath(named: "macport-\(id.uuidString.prefix(8)).vnc")
    }

    /// A socket path in the first per-user location that fits the kernel's limit.
    nonisolated private static func socketPath(named name: String) -> String {
        let candidates = [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: "/tmp", isDirectory: true),
        ]
        for directory in candidates {
            let path = directory.appendingPathComponent(name).path
            if path.utf8.count < sunPathCapacity { return path }
        }
        // Unreachable in practice, but a path that compiles is better than a
        // silently truncated one.
        return "/tmp/\(name)"
    }

    nonisolated private static func resolvedTool() throws -> QEMURuntime.Tool {
        guard let tool = QEMURuntime.locate() else {
            throw EngineError.engineUnavailable("QEMU")
        }
        return tool
    }

    nonisolated private static func resolvedFirmware(
        for tool: QEMURuntime.Tool
    ) throws -> (code: URL, varsTemplate: URL?) {
        guard let firmware = QEMURuntime.firmware(for: tool) else {
            throw EngineError.engineUnavailable("QEMU (UEFI firmware images missing)")
        }
        return firmware
    }

    /// Assemble the QEMU command line.
    ///
    /// Device choices are the substance here, not the plumbing. Each one is picked
    /// for what the *guest* can drive without a driver disk, because a guest that
    /// cannot see its own disk cannot be installed at all.
    nonisolated private static func arguments(
        for config: VMConfiguration,
        bundle: URL,
        firmware: (code: URL, varsTemplate: URL?),
        answerMedia: URL?,
        toolsMedia: URL?
    ) -> [String] {
        var args: [String] = []

        args += ["-name", "Macport: \(config.name)"]

        // Machine and acceleration. `hvf` runs the guest on the real CPU through
        // Hypervisor.framework — the same accelerator Apple's own framework uses,
        // which is why this engine is not a slow emulator.
        args += ["-machine", "virt,highmem=on"]
        args += ["-accel", "hvf"]
        args += ["-cpu", "host"]
        args += ["-smp", String(max(1, config.cpuCount))]
        args += ["-m", String(config.memoryBytes / (1024 * 1024))]
        // Windows reads the RTC as local time; the default would shift its clock.
        args += ["-rtc", "base=localtime,clock=host"]

        // UEFI firmware. Code is read-only and shared; the variable store is this
        // VM's own writable copy. Its format follows what is actually on disk:
        // new bundles convert the template to qcow2 so it can be snapshotted,
        // old bundles keep booting the raw file until `create` migrates them.
        args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(firmware.code.path)"]
        let vars = resolveVars(in: bundle)
        let varsPath = vars?.url ?? bundle.appendingPathComponent(legacyVarsFileName)
        let varsFormat = vars?.format.rawValue ?? DiskFormat.raw.rawValue
        args += [
            "-drive",
            "if=pflash,format=\(varsFormat),node-name=\(varsNodeName),file=\(varsPath.path)",
        ]
        // Point QEMU at its own data directory. A relocated runtime cannot rely on a
        // compiled-in prefix, so without this QEMU would look for firmware, keymaps
        // and BIOS images in paths that do not exist on the machine running it.
        args += ["-L", firmware.code.deletingLastPathComponent().path]

        // User-facing input. Attached to an explicitly named bus: a device attached
        // to a bus that does not exist yet is silently dropped, and naming both ends
        // of the connection makes that impossible to get wrong.
        args += ["-device", "qemu-xhci,id=usb-controller"]
        args += ["-device", "usb-kbd,bus=usb-controller.0"]
        args += ["-device", "usb-tablet,bus=usb-controller.0"]

        // Display.
        //
        // Windows gets `ramfb` and Linux gets `virtio-gpu-pci`, and the reason is worth
        // stating because the obvious choice is the wrong way round. `virtio-gpu-pci`
        // is the better device and takes a resolution, but it only puts anything on
        // screen when its driver tells it to transfer the framebuffer — so an operating
        // system without that driver, which is Windows here, writes into memory nobody
        // is watching and the screen freezes on whatever the firmware last drew.
        // `ramfb` is the opposite: a linear framebuffer in guest RAM that the device
        // scans out directly. No driver, which is exactly why the device exists, and
        // Windows drives it through the graphics protocol the firmware publishes —
        // the same path a physical machine's firmware framebuffer uses.
        //
        // The cost is that `ramfb` takes no resolution parameters at all, so the size
        // is whatever the firmware was compiled with. The prebuilt EDK2 Macport vendors
        // has 800x600 wired into it, and no QEMU-side device can override that:
        // `-device ramfb,xres=...` is rejected, `bochs-display` has no resolution
        // either, and the firmware carries no Bochs driver for it to matter. A larger
        // guest resolution therefore needs firmware of Macport's own — which is the
        // planned fix, and until then `zoom-to-fit` is what keeps the window usable.
        if config.guest == .windowsARM {
            args += ["-device", "ramfb"]
        } else {
            args += ["-device", "virtio-gpu-pci"]
        }

        args += ["-device", "virtio-rng-pci"]

        // Root disk as NVMe. Windows carries `stornvme` in the box as a
        // boot-critical driver, so Setup sees the target disk immediately instead
        // of stopping at "no drives found" — the failure that virtio-blk produces.
        //
        // The format is read from the file header rather than assumed: new
        // machines get qcow2 so they can be snapshotted, bundles from before
        // that carry a raw sparse image, and both boot identically.
        let disk = resolveDisk(in: bundle)
        let diskPath = disk?.url.path ?? bundle.appendingPathComponent(diskFileName).path
        let diskFormat = disk?.format.rawValue ?? DiskFormat.raw.rawValue
        args += ["-device", "nvme,serial=macport,drive=rootdisk"]
        args += [
            "-drive",
            "if=none,id=rootdisk,node-name=\(rootNodeName),format=\(diskFormat),file=\(diskPath)",
        ]

        // Installer media as a **real SCSI CD-ROM carried over USB**.
        //
        // On `virt` there is exactly one transport that satisfies both halves of this
        // problem, and the halves pull in opposite directions:
        //
        //   * the firmware must see a CD-ROM, or it never reads the El Torito boot
        //     record and the installer never starts;
        //   * the guest operating system must see one too, or setup cannot read its
        //     own installation media and Windows stops at "Install driver to show
        //     hardware — a media driver your computer needs is missing".
        //
        // The firmware carries a driver for anything it is handed, so only the second
        // requirement constrains the choice. Measured on this machine, that leaves:
        //
        //   virtio-scsi-pci + scsi-cd  boots, but Windows has no virtio driver, so
        //                              setup cannot read the disc
        //   ich9-ahci + ide-cd         the firmware has no AHCI driver on `virt`, so
        //                              the drive is invisible and no boot option is
        //                              created at all
        //   usb-storage                QEMU materialises it as a scsi-hd — a hard
        //                              disk — which can never be an optical disc
        //   usb-bot + scsi-cd          a genuine SCSI CD-ROM (peripheral type 5)
        //                              behind a bulk-only USB transport: visible to
        //                              the firmware, and driverless in Windows
        //
        // So: USB. It is also why USB is what UTM uses for optical media on Apple
        // silicon, where there is no IDE and virtio has no Windows driver.
        if case .installMedia(let path) = config.boot {
            args += ["-device", "usb-bot,bus=usb-controller.0,id=usbcd"]
            // `file.locking=off` because the medium is read-only and is often mounted
            // on the host at the same time. Leaving locking on refuses to start the
            // machine with an error about a lock, which says nothing about what the
            // user did or how to fix it.
            args += [
                "-drive",
                "if=none,id=cd0,media=cdrom,readonly=on,file.locking=off,file=\(path)",
            ]
            args += ["-device", "scsi-cd,bus=usbcd.0,drive=cd0"]
        }

        // The Macport Tools disc: a second USB CD-ROM carrying the Arm64 virtio
        // drivers and the answer file that points Setup at them.
        //
        // It is a separate device rather than a directory on the installer ISO
        // because the installer ISO is the user's, often read-only and sometimes
        // still mounted; Macport must not rewrite it. Windows assigns the two CDs
        // in attachment order (installer then Tools), which is why the generated
        // answer file uses E: — the assumption is stated in one place
        // (`MacportTools.defaultDriveLetter`) and is the only guest-side path
        // Macport cannot discover from the host.
        if let toolsMedia {
            args += ["-device", "usb-bot,bus=usb-controller.0,id=usbtools"]
            args += [
                "-drive",
                "if=none,id=tools0,media=cdrom,readonly=on,file.locking=off,file=\(toolsMedia.path)",
            ]
            args += ["-device", "scsi-cd,bus=usbtools.0,drive=tools0"]
        }

        // The media carrying Setup's answer file, when the machine needs one.
        //
        // A plain disk rather than a CD, because what Setup wants is a filesystem it
        // can mount and browse — which is what this is. It holds no boot file, so the
        // firmware creates no boot option for it and the boot order is exactly what it
        // would have been without it. `removable=true` is QEMU's default and is passed
        // anyway: Setup looks for the answer file on removable media, and the guest is
        // told the truth about what kind of device this is.
        if let answerMedia {
            args += [
                "-drive",
                "if=none,id=answer,format=raw,readonly=on,file=\(answerMedia.path)",
            ]
            args += [
                "-device",
                "usb-storage,drive=answer,bus=usb-controller.0,removable=true",
            ]
        }

        if config.network == .sharedNAT {
            args += ["-netdev", "user,id=net0"]
            args += ["-device", "virtio-net-pci,netdev=net0"]
        }

        // A human-monitor socket, outside the VM bundle because a unix socket path
        // is length-capped. It is how `stop()` presses the guest's power button
        // when QMP is unavailable, and how the boot prompt is answered with
        // `sendkey` — the one job the text monitor still owns.
        args += [
            "-monitor",
            "unix:\(monitorSocketPath(for: config.id)),server=on,wait=off",
        ]
        // The structured control channel: pause/resume, snapshots, and an
        // answerable powerdown. `wait=off` means a missing client never delays
        // the boot — the machine is not held hostage by its monitor.
        args += [
            "-qmp",
            "unix:\(qmpSocketPath(for: config.id)),server=on,wait=off",
        ]
        // Firmware and kernel console output, appended to a file in the bundle.
        // When a guest will not boot, this is the first place to look, and having
        // it is the difference between diagnosing a boot and guessing at one.
        args += ["-serial", "file:\(bundle.appendingPathComponent(consoleFileName).path)"]

        if Self.displayBackend == "none" {
            let vnc = vncSocketPath(for: config.id)
            unlink(vnc)
            args += ["-display", "none", "-vnc", "unix:\(vnc)"]
        } else {
            args += ["-display", Self.displayBackend]
        }

        return args
    }

    /// The display backend, overridable for headless runs and tests.
    ///
    /// `zoom-to-fit` is the difference between a window that can be enlarged and one
    /// that cannot. Without it the guest's pixels stay at their native size and
    /// resizing the window only crops or letterboxes them, so a display that is the
    /// wrong size for the space available — too small, as here — cannot be made to fit.
    /// With it, dragging the window scales the display to match.
    ///
    /// This matters more than it usually would because the Windows display device takes
    /// no resolution: the guest is 800x600 because the prebuilt firmware is, and there
    /// is no QEMU-side knob to change it. Until Macport ships firmware of its own,
    /// scaling the window is the only way to make a Windows guest fill more of the
    /// screen — so it is on by default rather than left as a menu item to find.
    nonisolated public static var displayBackend: String {
        ProcessInfo.processInfo.environment["MACPORT_QEMU_DISPLAY"] ?? "none"
    }

    // MARK: - Monitor channel

    /// Send one command to QEMU's human monitor over its unix socket.
    ///
    /// The text monitor is now the narrow path, not the main one: QMP owns
    /// pause/resume, snapshots and the structured powerdown, while the HMP
    /// socket answers the boot prompt with `sendkey` — a command QMP has no
    /// equivalent for — and stands in as the powerdown fallback when QMP never
    /// connected.
    nonisolated private static func sendMonitorCommand(_ command: String, at path: String) {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = path.withCString { strncpy(destination, $0, capacity - 1) }
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, length)
            }
        }
        guard connected == 0 else { return }
        _ = command.withCString { write(descriptor, $0, strlen($0)) }
    }
}
