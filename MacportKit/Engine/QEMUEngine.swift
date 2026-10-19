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
            snapshots: false,
            sharedFolders: false,
            usbPassthrough: false,
            foreignArchitectureEmulation: false,
            // QEMU and QMP can do all of these; Macport wires each one up in
            // workstream B (pause/resume/snapshots) and C (per-VM host process).
            // Reported false until the code actually does it — a capability is a
            // promise, not a possibility.
            pauseResume: false,
            saveState: false,
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
        let vars = bundle.appendingPathComponent(Self.varsFileName)
        if !fm.fileExists(atPath: vars.path) {
            if let template = firmware.varsTemplate {
                try fm.copyItem(at: template, to: vars)
            } else {
                guard fm.createFile(atPath: vars.path, contents: nil) else {
                    throw EngineError.operationFailed("Could not create \(vars.path).")
                }
                // Zero-filled is equivalent to factory-fresh NVRAM.
                let handle = try FileHandle(forWritingTo: vars)
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

        // Windows cannot be installed without a TPM to show it, so an installation has
        // to be handed the answer file that tells Setup to carry on without one.
        //
        // Written before launch, and a failure to write it is *reported* rather than
        // swallowed: the alternative is a machine that starts and then parks on a screen
        // the user cannot pass, with nothing anywhere saying why.
        var answerMedia: URL?
        if case .installMedia = config.boot, UnattendMedia.isNeeded(for: config.guest) {
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
            answerMedia: answerMedia
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

            // Exactly one press, and the count is the point. The firmware queues it, so
            // it is waiting for the prompt to collect even if the prompt has not been
            // drawn yet. But every press the prompt does *not* consume is delivered to
            // the guest instead: QEMU holds keyboard reports until the guest collects
            // them, and Windows collects them minutes later, inside Setup's own dialogs.
            // Measured on this machine, a second press advanced the installer past a
            // question before it had been answered.
            Self.sendMonitorCommand("sendkey spc\n", at: monitorPath)
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

    /// The snapshots QEMU holds for this machine's disk.
    ///
    /// QMP's own `query-snapshots` is tried first; the human monitor's
    /// `info snapshots` table is the fallback, because not every QEMU build
    /// answers the former and every build prints the latter.
    public func listMachineSnapshots() async throws -> [QEMUSnapshot] {
        try ensureSnapshotsSupported()
        let channel = try controlChannel(for: "Snapshots")

        if let payload = try? await channel.execute("query-snapshots"),
           let snapshots = Self.parseSnapshotListQMP(payload) {
            return snapshots
        }

        let text = try await Self.humanMonitor("info snapshots", on: channel)
        return Self.parseSnapshotListHMP(text)
    }

    /// Take a snapshot of the machine: RAM and disk, under a stable tag.
    ///
    /// The guest is paused for the duration. Save-state is written by the same
    /// device-state serialiser a migration uses, and a running guest would race
    /// it — so: stop, `savevm`, cont. A machine that was already paused stays
    /// paused, which is what its owner asked for.
    ///
    /// Returns the snapshot as QEMU records it — the caller's display name is
    /// sanitised into the tag, and the pretty name belongs in the bundle index.
    @discardableResult
    public func takeMachineSnapshot(named name: String) async throws -> QEMUSnapshot {
        try ensureSnapshotsSupported()
        let channel = try controlChannel(for: "Snapshots")
        let tag = Self.sanitizeSnapshotName(name)

        let wasRunning = try await machineIsRunning(on: channel)
        if wasRunning {
            _ = try await command("stop", context: "Could not pause the machine for a snapshot", on: channel)
        }
        do {
            _ = try await Self.humanMonitor("savevm \(tag)", on: channel)
        } catch {
            // Leave the machine as it was found, even though the save failed.
            if wasRunning { _ = try? await channel.execute("cont") }
            throw error
        }
        if wasRunning {
            _ = try await command("cont", context: "Could not resume the machine after a snapshot", on: channel)
        }

        if let fresh = try? await listMachineSnapshots(),
           let match = fresh.first(where: { $0.id == tag }) {
            return match
        }
        // A snapshot that saved without error is real even when the listing
        // has not caught up (some builds lag one poll behind).
        return QEMUSnapshot(id: tag, name: tag, createdAt: Date(), includesMemory: true)
    }

    /// Restore the machine to a snapshot's RAM and disk state.
    ///
    /// `loadvm` replaces device state as well as memory, so the machine is
    /// paused around it and left in the state the caller found it in: running
    /// stays running, paused stays paused. The end state `loadvm` leaves behind
    /// is build-dependent, so it is corrected explicitly rather than trusted.
    public func restoreMachineSnapshot(id: String) async throws {
        try ensureSnapshotsSupported()
        let channel = try controlChannel(for: "Restore")
        let tag = Self.sanitizeSnapshotName(id)

        let wasRunning = try await machineIsRunning(on: channel)
        if wasRunning {
            _ = try await command("stop", context: "Could not pause the machine for a restore", on: channel)
        }
        do {
            _ = try await Self.humanMonitor("loadvm \(tag)", on: channel)
        } catch {
            if wasRunning { _ = try? await channel.execute("cont") }
            throw error
        }

        let runningNow = try await machineIsRunning(on: channel)
        if wasRunning && !runningNow {
            _ = try await command("cont", context: "Could not resume the machine after a restore", on: channel)
        } else if !wasRunning && runningNow {
            _ = try await command("stop", context: "Could not pause the machine after a restore", on: channel)
        }
        state = wasRunning ? .running : .paused
    }

    /// Delete a snapshot. Safe while the guest runs: `delvm` only touches the
    /// image, and QEMU refuses if the snapshot is the machine's current state.
    public func deleteMachineSnapshot(id: String) async throws {
        try ensureSnapshotsSupported()
        let channel = try controlChannel(for: "Delete snapshot")
        let tag = Self.sanitizeSnapshotName(id)
        _ = try await Self.humanMonitor("delvm \(tag)", on: channel)
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
    nonisolated private static func humanMonitor(
        _ command: String,
        on channel: QMPClient
    ) async throws -> String {
        do {
            let value = try await channel.execute(
                "human-monitor-command",
                arguments: ["command-line": .string(command)]
            )
            return value.stringValue ?? ""
        } catch {
            throw engineError(from: error, operation: "QEMU rejected “\(command)”")
        }
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
        }

        let disk = bundle.appendingPathComponent(diskFileName)
        guard FileManager.default.createFile(atPath: disk.path, contents: nil) else {
            throw EngineError.operationFailed("Could not create \(disk.path).")
        }
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: config.diskBytes)
        try handle.close()
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
    /// The header is
    ///
    ///     ID        TAG                     VM SIZE                DATE       VM CLOCK
    ///
    /// and QEMU prints `There is no snapshot available.` when the disk has none.
    /// Column widths differ between versions, so a snapshot row is recognised
    /// by the date column — the one field with an unambiguous shape — and the
    /// tag is whatever sits between the id and the size.
    nonisolated static func parseSnapshotListHMP(_ text: String) -> [QEMUSnapshot] {
        let emptyMarkers = [
            "There is no snapshot available",
            "There are no snapshots",
            "There is no snapshot on",
        ]

        var snapshots: [QEMUSnapshot] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
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
        // or `--`/`unavailable`; then date, then clock.
        let pattern = #"^(--|\d+)\s+(.+?)\s+(\d+(?:\.\d+)?\s*[KMGTP]?i?B|--|unavailable)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+([0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?|--)"#
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
    nonisolated private static let varsFileName = "efi-vars.fd"
    nonisolated private static let logFileName = "qemu.log"
    nonisolated private static let consoleFileName = "console.log"
    /// The removable disk carrying Setup's answer file, when one is needed.
    nonisolated private static let answerMediaFileName = "answer-media.img"
    nonisolated private static let defaultVariableStoreBytes: UInt64 = 64 * 1024 * 1024

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
        answerMedia: URL?
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
        // VM's own writable copy.
        args += ["-drive", "if=pflash,format=raw,readonly=on,file=\(firmware.code.path)"]
        args += [
            "-drive",
            "if=pflash,format=raw,file=\(bundle.appendingPathComponent(varsFileName).path)",
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
            "if=none,id=rootdisk,format=\(diskFormat),file=\(diskPath)",
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
                "if=none,id=answer,format=raw,file=\(answerMedia.path)",
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

        args += ["-display", Self.displayBackend]

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
    nonisolated private static var displayBackend: String {
        ProcessInfo.processInfo.environment["MACPORT_QEMU_DISPLAY"] ?? "cocoa,zoom-to-fit=on"
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
