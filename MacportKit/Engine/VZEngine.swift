import Foundation
import Virtualization

/// Hypervisor engine built on Apple's Virtualization framework.
///
/// This is Macport's primary engine because it is the leanest option on Apple
/// silicon: the guest runs on the metal via the macOS hypervisor with virtio
/// devices, rather than through a software chipset model. That is the difference
/// the user actually feels — boot time and battery.
///
/// Stated limits, so the UI can be honest rather than optimistic:
///   - **No Windows at all.** Not merely "no vTPM". This framework has no optical
///     device, no TPM device, and a fixed virtio device set that Windows ships no
///     drivers for. Each gap independently blocks a Windows 11 Arm install, so
///     Windows guests are refused outright and routed to `QEMUEngine`.
///   - **No virtual TPM.** Windows 11's installer requires a TPM 2.0 device.
///     Apple's framework does not offer one, so `windowsARM` installs need a
///     registry bypass, or must be handed to an engine that supplies a vTPM.
///   - **No foreign-architecture emulation.** This engine runs arm64 guests only.
///     An x86_64 guest needs a QEMU-class engine and will be far slower.
///   - **No nested virtualisation.** The host does not expose it on Apple silicon.
@MainActor
public final class VZEngine: NSObject, VMEngine {
    nonisolated public static let identifier = "vz"
    nonisolated public static let displayName = "Virtualization.framework"

    private var machine: VZVirtualMachine?

    public private(set) var state: VMState = .stopped

    /// Why the machine last stopped abnormally, if it did.
    public private(set) var lastError: String?

    /// Inherits `NSObject` because `VZVirtualMachineDelegate` refines
    /// `NSObjectProtocol` — the framework calls the engine back, so it has to be
    /// an Objective-C object.
    public override init() { super.init() }

    // MARK: - Capabilities

    nonisolated public static func capabilities(for guest: GuestKind) -> EngineCapabilities {
        // Everything this engine does is arm64-native virtio. The guest kind
        // changes almost nothing, which is itself worth knowing: if the engine
        // cannot do it, it cannot do it for *any* guest.
        EngineCapabilities(
            tpm: false,                 // no vTPM in Virtualization.framework
            opticalMedia: false,        // and no CD-ROM device either; see validateGuestSupport
            nestedVirtualization: Self.nestedVirtualizationSupported,
            graphics: .accelerated,     // VZVirtioGraphicsDevice / VZMacGraphicsDevice
            snapshots: false,           // framework exposes no snapshot primitive
            sharedFolders: true,        // virtiofs via VZVirtioFileSystemDevice
            usbPassthrough: guest == .macOSGuest, // USB controllers are macOS-guest only
            foreignArchitectureEmulation: false
        )
    }

    nonisolated public static func availability() -> Result<Void, EngineError> {
        // VZVirtualMachine.isSupported reports whether this host can virtualise
        // at all. A Mac without the hypervisor entitlement or an unsupported
        // host fails here rather than at first boot.
        guard VZVirtualMachine.isSupported else {
            return .failure(.engineUnavailable(displayName))
        }
        return .success(())
    }

    // MARK: - Lifecycle

    public func create(_ config: VMConfiguration, in bundle: URL) async throws {
        try validate(config)

        let fm = FileManager.default
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)

        // Disk: sparse, so a 64 GB ceiling costs only what the guest writes.
        let diskURL = bundle.appendingPathComponent("disk.img")
        if !fm.fileExists(atPath: diskURL.path) {
            try Self.createSparseFile(at: diskURL, size: config.diskBytes)
        }

        // EFI variable store: platform firmware state (boot order, secure boot
        // variables). Must persist across boots or the guest forgets how to boot.
        let efiURL = bundle.appendingPathComponent("efi.variables")
        if !fm.fileExists(atPath: efiURL.path) {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
        }

        // Machine identifier. VZGenericPlatformConfiguration.machineIdentifier is
        // a non-null `copy` property, so leaving it unset fails validate() before
        // the VM ever starts. It must also survive a reboot — the framework header
        // is explicit that a VM restored from disk needs the *same* identifier — so
        // it is persisted next to the firmware rather than regenerated per launch.
        let idURL = bundle.appendingPathComponent("machine-id.bin")
        if !fm.fileExists(atPath: idURL.path) {
            let identifier = VZGenericMachineIdentifier()
            try identifier.dataRepresentation.write(to: idURL, options: .atomic)
        }
    }

    public func start(_ config: VMConfiguration, in bundle: URL) async throws {
        guard state == .stopped || state == .error else {
            throw EngineError.operationFailed("VM is already \(state.rawValue).")
        }
        try validate(config)
        state = .starting

        do {
            let vzConfig = try buildConfiguration(config, bundle: bundle)
            try vzConfig.validate()

            // No custom queue — deliberately.
            //
            // VZVirtualMachine asserts that every one of its methods runs on the
            // queue it was constructed with. This engine is @MainActor throughout,
            // and VZVirtualMachineView is an AppKit view bound to the main thread,
            // so the framework's default (main) queue is the only choice that does
            // not fight either of them.
            //
            // Constructing with a private serial queue and then calling start()
            // from the main actor traps inside dispatch_assert_queue. That is not a
            // precaution — it is SIGTRAP, and it took a crash report to find.
            let vm = VZVirtualMachine(configuration: vzConfig)
            // Without a delegate there is no way to learn that a guest stopped or
            // died. The engine would go on reporting `.running` for a machine that
            // powered off seconds after boot — which is precisely what it did
            // before this line existed.
            vm.delegate = self
            self.machine = vm
            try await vm.start()
            state = Self.map(vm.state)
        } catch {
            state = .error
            lastError = error.localizedDescription
            throw EngineError.operationFailed(error.localizedDescription)
        }
    }

    public func stop() async throws {
        guard let machine else { return }
        state = .stopping
        // requestStop() is the graceful path — it asks the guest to shut itself
        // down. Per VZVirtualMachine.h it is `requestStopWithError:`, i.e. a
        // synchronous, throwing request that reports delivery failure
        // immediately rather than awaiting the guest's shutdown.
        try machine.requestStop()
        state = .stopped
        self.machine = nil
    }

    public func forceStop() async throws {
        guard let machine else { return }
        state = .stopping
        try await machine.stop()
        state = .stopped
        self.machine = nil
    }

    /// The live machine, for embedding in a `VZVirtualMachineView`.
    ///
    /// Exposed rather than wrapped so the SwiftUI layer owns view construction —
    /// the engine has no business knowing about AppKit.
    public var virtualMachine: VZVirtualMachine? { machine }

    // MARK: - Configuration assembly

    private func buildConfiguration(
        _ config: VMConfiguration,
        bundle: URL
    ) throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()

        vz.cpuCount = max(1, min(config.cpuCount, Self.maximumRecommendedCPUs))
        vz.memorySize = max(
            Self.minimumMemoryBytes,
            min(config.memoryBytes, Self.maximumRecommendedMemory)
        )

        // Firmware: EFI boot straight into the attached disk or install media.
        // VZEFIVariableStore(url:) neither throws nor returns nil, so the
        // missing-store case has to be detected on the filesystem.
        let efiURL = bundle.appendingPathComponent("efi.variables")
        guard FileManager.default.fileExists(atPath: efiURL.path) else {
            throw EngineError.invalidConfiguration(
                "EFI variable store missing at \(efiURL.path). Run create first."
            )
        }
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: efiURL)
        vz.bootLoader = bootLoader

        // Platform: generic for Linux. macOS guests need VZMacPlatformConfiguration
        // with a hardware model and machine identifier, which is not wired up yet.
        // Guest-kind support is enforced up front in `validateGuestSupport`, so
        // `create` refuses as well — there is no point writing a VM bundle for a
        // guest this engine can never boot.
        let platform = VZGenericPlatformConfiguration()
        let idURL = bundle.appendingPathComponent("machine-id.bin")
        guard let idData = try? Data(contentsOf: idURL),
              let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: idData)
        else {
            throw EngineError.invalidConfiguration(
                "Machine identifier missing or unreadable at \(idURL.path). Run create first."
            )
        }
        platform.machineIdentifier = machineIdentifier
        vz.platform = platform

        // Storage. The *device type* matters more than it looks: it is the single
        // decision that determines whether a Windows install can see a disk at all.
        //
        // Windows 11 on Arm ships no virtio drivers. Attach the root disk as
        // virtio-blk and Setup boots, then reports zero drives and stops. NVMe is
        // the fix — Windows carries `stornvme` in the box as a boot-critical
        // driver, so an NVMe controller is visible immediately with no driver disk.
        // Linux has an inbox NVMe driver too, so this is one path for both guests.
        //
        // The header is explicit that the main storage device must be first in
        // this array, so the root disk is appended before any install media.
        var storage: [VZStorageDeviceConfiguration] = []

        let diskURL = bundle.appendingPathComponent("disk.img")
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: diskURL,
            readOnly: false
        )
        storage.append(
            VZNVMExpressControllerDeviceConfiguration(attachment: diskAttachment)
        )

        if case .installMedia(let isoPath) = config.boot {
            let isoURL = URL(fileURLWithPath: isoPath)
            guard FileManager.default.fileExists(atPath: isoURL.path) else {
                throw EngineError.installMediaMissing(isoPath)
            }
            let iso = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)

            // A read-only virtio-blk device is how this framework presents an
            // optical image — it has no CD-ROM device type at all. That is enough
            // for Linux, whose ISO is a *hybrid* image carrying a real GPT and a
            // FAT ESP, so the firmware mounts it as a disk and boots it. Verified:
            // Ubuntu 26.04 arm64 boots this way.
            //
            // Windows installers are a different shape, and the difference decides
            // everything: no MBR, no GPT, no FAT ESP, bootstrapped purely through
            // El Torito — which a firmware only consults on media it identifies as
            // optical. There is no optical device here, so no transport boots it.
            // Measured: virtio-blk, USB mass storage, and USB mass storage behind an
            // XHCI controller each spin at 100% of one core with guest memory
            // untouched and zero bytes written. Windows guests are refused earlier,
            // in buildConfiguration, rather than left to fail confusingly here.
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: iso))
        }
        vz.storageDevices = storage

        // Network.
        vz.networkDevices = config.network == .sharedNAT ? [Self.natNetworkDevice()] : []

        // Entropy, balloon and console — cheap to add, and guests misbehave
        // without them (notably: entropy starvation makes SSH keygen crawl).
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        vz.serialPorts = [console]

        // Display: virtio GPU for Linux guests.
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)
        ]
        vz.graphicsDevices = [graphics]

        vz.audioDevices = [VZVirtioSoundDeviceConfiguration()]

        // Shared folders via virtiofs — the single most useful host/guest bridge.
        vz.directorySharingDevices = config.sharedFolders.compactMap { folder in
            Self.directorySharingDevice(for: folder)
        }

        return vz
    }

    // MARK: - Helpers

    private func validate(_ config: VMConfiguration) throws {
        guard !config.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw EngineError.invalidConfiguration("VM name must not be empty.")
        }
        guard config.cpuCount >= 1 else {
            throw EngineError.invalidConfiguration("At least one vCPU is required.")
        }
        try Self.validateGuestSupport(for: config.guest)
        if config.guest.requiresTPM && config.tpmEnabled {
            throw EngineError.unsupportedGuest(
                config.guest,
                reason: "this engine cannot provide a virtual TPM, so tpmEnabled must be false."
            )
        }
    }

    /// Which guest families this engine will host, and precisely why not for the
    /// rest.
    ///
    /// Enforced in `validate` rather than at boot, so both `create` and `start`
    /// fail before anything is written to disk.
    nonisolated static func validateGuestSupport(for guest: GuestKind) throws {
        if guest == .macOSGuest {
            throw EngineError.unsupportedGuest(
                guest,
                reason: "macOS guests need a platform configuration with an "
                    + "IPSW-restored hardware model, which is not wired up yet."
            )
        }

        // Windows is refused outright, and this is the most important thing this
        // engine has to say about itself.
        //
        // It is not a gap a later pass could fill in. Four independent framework
        // shortcomings each block a Windows 11 Arm install on their own, so no
        // amount of wiring here would produce a working guest:
        //
        //   1. There is no TPM device, and Setup requires TPM 2.0.
        //   2. There is no optical device. A Windows installer ISO carries no MBR,
        //      no GPT and no FAT ESP — it bootstraps through El Torito, which
        //      firmware only consults on media it identifies as optical. Measured
        //      on this machine: virtio-blk, USB mass storage, and USB mass storage
        //      behind an XHCI controller each spin at 100% of one core for four
        //      minutes, guest memory never touched, zero bytes written.
        //   3. The device set is fixed and virtio-based, and Windows ships no virtio
        //      storage, network or graphics drivers.
        //   4. No UEFI Secure Boot variable handling for the Windows boot chain.
        //
        // Every shipping product reaches the same conclusion, so this is a property
        // of the framework rather than a shortcut taken here: UTM runs Windows on
        // its QEMU backend, tart documents Windows on Arm as unsupported, and
        // MacDow uses QEMU+HVF for Windows while keeping Virtualization for macOS.
        // Refusing with a precise reason beats four minutes of silent spinning.
        if guest == .windowsARM {
            throw EngineError.unsupportedGuest(
                guest,
                reason: """
                Virtualization.framework cannot host Windows: it has no TPM \
                device, no optical device, and a fixed virtio device set that \
                Windows has no drivers for. Use the QEMU engine.
                """
            )
        }
    }

    private static func natNetworkDevice() -> VZNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return device
    }

    private static func directorySharingDevice(
        for folder: SharedFolder
    ) -> VZDirectorySharingDeviceConfiguration? {
        let url = URL(fileURLWithPath: folder.hostPath)

        // Non-failable and non-throwing in the SDK: a non-existent host path is
        // not rejected here, so existence is checked explicitly below.
        guard FileManager.default.fileExists(atPath: folder.hostPath) else {
            return nil
        }

        let device = VZVirtioFileSystemDeviceConfiguration(tag: "macport-share")
        // VZSharedDirectory describes one directory; the device wants a
        // VZDirectoryShare, so it is wrapped as a single-directory share.
        device.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: url, readOnly: folder.readOnly)
        )
        return device
    }

    /// Create a sparse file of `size` bytes without writing them.
    ///
    /// A naive `write(Data(count:))` would actually materialise N gigabytes.
    /// `ftruncate` creates the length with no allocated blocks.
    static func createSparseFile(at url: URL, size: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw EngineError.operationFailed("Could not create disk image at \(url.path).")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    // MARK: - Host limits

    /// Never hand the guest more vCPUs than the host has performance cores;
    /// oversubscription makes the *host* slower, not the guest faster.
    static var maximumRecommendedCPUs: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Whether this host can expose virtualisation extensions to a guest.
    ///
    /// Reported rather than hardcoded to `false`. The framework gained this in
    /// macOS 15 and it depends on the chip, so "not available" is a fact about
    /// this Mac rather than a property of the engine — and the user is entitled to
    /// the distinction.
    nonisolated static var nestedVirtualizationSupported: Bool {
        if #available(macOS 15.0, *) {
            return VZGenericPlatformConfiguration.isNestedVirtualizationSupported
        }
        return false
    }

    static var minimumMemoryBytes: UInt64 { 512 * 1024 * 1024 }

    /// Leave headroom for macOS itself. Handing a guest every byte is how you
    /// get a swap-thrashing Mac.
    static var maximumRecommendedMemory: UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        return physical > 8 * 1024 * 1024 * 1024
            ? physical - 8 * 1024 * 1024 * 1024
            : physical / 2
    }
}

// MARK: - State observation

extension VZEngine {
    /// Translate the framework's own state rather than tracking a parallel one.
    ///
    /// Two sources of truth for "is this machine running" is one too many, and the
    /// engine's copy is the one that drifts.
    static func map(_ state: VZVirtualMachine.State) -> VMState {
        switch state {
        case .stopped: return .stopped
        case .running: return .running
        case .paused: return .paused
        case .error: return .error
        case .starting: return .starting
        case .pausing: return .pausing
        case .resuming: return .starting
        case .stopping: return .stopping
        case .restoring: return .starting
        case .saving: return .stopping
        @unknown default: return .error
        }
    }
}

/// The engine is *told* when a guest stops, instead of inferring it.
///
/// Both callbacks are `nonisolated` because `VZVirtualMachineDelegate` is an
/// Objective-C protocol the compiler cannot prove is main-thread, then hop to the
/// main actor explicitly. Assuming isolation here would be the thing that breaks
/// the day the framework changes its delivery queue.
extension VZEngine: VZVirtualMachineDelegate {
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor [weak self] in
            self?.state = .stopped
            self?.machine = nil
        }
    }

    nonisolated public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.lastError = error.localizedDescription
            self?.state = .error
            self?.machine = nil
        }
    }
}
