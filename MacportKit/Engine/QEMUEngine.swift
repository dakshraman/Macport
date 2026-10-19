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

    public override init() { super.init() }

    // MARK: - Bundle preparation

    public func create(_ config: VMConfiguration, in bundle: URL) async throws {
        let tool = try Self.resolvedTool()
        let firmware = try Self.resolvedFirmware(for: tool)
        let fm = FileManager.default
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)

        // Root disk. A sparse file: an 80 GB ceiling costs nothing until the guest
        // actually writes, which is what makes declaring generous disk sizes safe.
        let disk = bundle.appendingPathComponent(Self.diskFileName)
        if !fm.fileExists(atPath: disk.path) {
            guard fm.createFile(atPath: disk.path, contents: nil) else {
                throw EngineError.operationFailed("Could not create \(disk.path).")
            }
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: config.diskBytes)
            try handle.close()
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

        // A stale socket file stops QEMU binding, so clear it before launch.
        let monitor = Self.monitorSocketPath(for: config.id)
        try? FileManager.default.removeItem(atPath: monitor)
        monitorPath = monitor

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
        if let monitorPath {
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
        state = .stopped
    }

    // MARK: - Command line

    nonisolated private static let diskFileName = "disk.img"
    nonisolated private static let varsFileName = "efi-vars.fd"
    nonisolated private static let logFileName = "qemu.log"
    nonisolated private static let consoleFileName = "console.log"
    /// The removable disk carrying Setup's answer file, when one is needed.
    nonisolated private static let answerMediaFileName = "answer-media.img"
    nonisolated private static let defaultVariableStoreBytes: UInt64 = 64 * 1024 * 1024

    /// How many quarter-second checks to make while waiting for the firmware to reach
    /// its first boot attempt — one minute's worth.
    nonisolated private static let bootAttemptPolls = 240

    /// The kernel's `sun_path` caps a unix socket path at 104 bytes, and a VM
    /// bundle under Application Support passes that the moment the user's account
    /// name is more than a few characters — QEMU then refuses to start with
    /// "UNIX socket path is too long" and nothing else.
    ///
    /// So the monitor socket lives outside the bundle, in a short, per-user
    /// location keyed by the machine's identifier. The bundle keeps the log and the
    /// console, which are ordinary files and have no such limit.
    nonisolated private static func monitorSocketPath(for id: UUID) -> String {
        let name = "macport-\(id.uuidString.prefix(8)).monitor"
        let candidates = [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: "/tmp", isDirectory: true),
        ]
        for directory in candidates {
            let path = directory.appendingPathComponent(name).path
            if path.utf8.count < 104 { return path }
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
        args += ["-device", "nvme,serial=macport,drive=rootdisk"]
        args += [
            "-drive",
            "if=none,id=rootdisk,format=raw,file=\(bundle.appendingPathComponent(diskFileName).path)",
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
        // is length-capped. It is how `stop()` presses the guest's power button, and
        // it makes the machine inspectable from outside while it runs.
        args += [
            "-monitor",
            "unix:\(monitorSocketPath(for: config.id)),server=on,wait=off",
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
    /// The monitor is a plain-text protocol, which is far less code than a full
    /// QMP client for the one thing needed here: asking the guest to power down.
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
