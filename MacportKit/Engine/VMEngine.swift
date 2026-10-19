import Foundation

// MARK: - Capabilities

/// Which third-party graphics stack an engine can expose to a guest.
///
/// Kept coarse on purpose. The point is to answer "will my CAD app work?" with
/// an honest yes/no/partly, not to model the whole feature matrix.
public enum GraphicsSupport: String, Codable, Sendable {
    /// No acceleration. CPU-rendered framebuffer only.
    case none
    /// Vendor 2D/3D acceleration, DirectX 11 or OpenGL class.
    case accelerated
    /// Accelerated *and* a DirectX 12 capable path.
    case acceleratedDX12

    public var displayName: String {
        switch self {
        case .none: return "None (software rendering)"
        case .accelerated: return "Accelerated"
        case .acceleratedDX12: return "Accelerated + DirectX 12"
        }
    }
}

/// What an engine can actually do for a given guest.
///
/// This type exists because the honest answer to "can Macport run X?" is
/// "depends which engine, on which guest". Rather than let the UI assume, every
/// engine declares its limits up front and the UI reports them verbatim.
public struct EngineCapabilities: Codable, Hashable, Sendable {
    /// Virtual TPM 2.0 device. Required for a stock Windows 11 install.
    public var tpm: Bool
    /// A CD-ROM device capable of booting vendor installer media.
    ///
    /// This looks like a detail and is not one. Firmware only consults an ISO's
    /// El Torito boot record on media it identifies as *optical*, and
    /// Virtualization.framework exposes no optical device at all — its entire
    /// storage menu is virtio-blk, NVMe and USB mass storage. That single absence
    /// is why no Windows installer can boot there, on any transport.
    public var opticalMedia: Bool
    /// Nested virtualisation — running a hypervisor *inside* the guest.
    ///
    /// Note: this is reported per-engine, but on Apple silicon the host does not
    /// expose nested virtualisation to guests at all. Any engine claiming `true`
    /// here would be wrong; treat `false` as expected rather than a limitation.
    public var nestedVirtualization: Bool
    public var graphics: GraphicsSupport
    public var snapshots: Bool
    public var sharedFolders: Bool
    public var usbPassthrough: Bool
    /// Can the engine emulate a *foreign* CPU architecture (e.g. x86_64 on an
    /// arm64 host)? Emulation is 10-100x slower; only QEMU-class engines can.
    public var foreignArchitectureEmulation: Bool

    public init(
        tpm: Bool = false,
        opticalMedia: Bool = false,
        nestedVirtualization: Bool = false,
        graphics: GraphicsSupport = .none,
        snapshots: Bool = false,
        sharedFolders: Bool = false,
        usbPassthrough: Bool = false,
        foreignArchitectureEmulation: Bool = false
    ) {
        self.tpm = tpm
        self.opticalMedia = opticalMedia
        self.nestedVirtualization = nestedVirtualization
        self.graphics = graphics
        self.snapshots = snapshots
        self.sharedFolders = sharedFolders
        self.usbPassthrough = usbPassthrough
        self.foreignArchitectureEmulation = foreignArchitectureEmulation
    }
}

// MARK: - State

public enum VMState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case pausing
    case paused
    case stopping
    case error

    public var isActive: Bool {
        switch self {
        case .starting, .running, .pausing, .paused, .stopping: return true
        case .stopped, .error: return false
        }
    }
}

// MARK: - Errors

public enum EngineError: Error, LocalizedError, Sendable {
    case engineUnavailable(String)
    /// The engine is fine but the runtime it needs is not installed yet.
    ///
    /// Distinct from `engineUnavailable` because it is *actionable*: the engine can
    /// be made available, and the detail says how.
    case runtimeMissing(engine: String, detail: String)
    case unsupportedGuest(GuestKind, reason: String)
    case invalidConfiguration(String)
    case hostResourceUnavailable(String)
    case operationFailed(String)
    case installMediaMissing(String)

    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let name):
            return "The \(name) engine is not available on this Mac."
        case .runtimeMissing(let engine, let detail):
            return "The \(engine) engine needs a runtime that is not installed. \(detail)"
        case .unsupportedGuest(let guest, let reason):
            return "\(guest.displayName) is not supported: \(reason)"
        case .invalidConfiguration(let detail):
            return "Invalid configuration: \(detail)"
        case .hostResourceUnavailable(let detail):
            return "Host resource unavailable: \(detail)"
        case .operationFailed(let detail):
            return "Operation failed: \(detail)"
        case .installMediaMissing(let path):
            return "Install media not found at \(path)."
        }
    }
}

// MARK: - Engine

/// A hypervisor backend that can own and run a `VMConfiguration`.
///
/// Engines are deliberately pluggable. Virtualization.framework is the first
/// implementation because it is the leanest path on Apple silicon, but it cannot
/// supply a vTPM or foreign-architecture emulation — so a QEMU engine is the
/// expected second implementation, not a rewrite.
@MainActor
public protocol VMEngine: AnyObject, Sendable {
    /// Stable identifier persisted in `VMConfiguration.engineIdentifier`.
    ///
    /// `nonisolated` deliberately: engine identity and capability reporting are
    /// pure static facts. Describing what an engine *can* do must not require a
    /// main actor, or a headless CLI could not report it.
    nonisolated static var identifier: String { get }
    nonisolated static var displayName: String { get }

    /// Engines are created through `EngineRegistry`, which must instantiate
    /// whichever type it selects without knowing the concrete class.
    init()

    /// What this engine can do for `guest`.
    ///
    /// Must be answered without starting a VM — it drives UI decisions such as
    /// whether to offer an install flow at all.
    nonisolated static func capabilities(for guest: GuestKind) -> EngineCapabilities

    /// Engine-wide availability, including any host prerequisite that is missing.
    nonisolated static func availability() -> Result<Void, EngineError>

    var state: VMState { get }

    /// Why the machine last stopped abnormally, if it did.
    ///
    /// Part of the protocol because every engine can fail asynchronously — the
    /// guest can die seconds after a successful `start()` — and a caller that can
    /// only see `.error` has no way to say what went wrong.
    var lastError: String? { get }

    /// Prepare the on-disk bundle: create the disk image, EFI store and any
    /// installer attachments described by `config`.
    func create(_ config: VMConfiguration, in bundle: URL) async throws

    /// Boot the machine described by `config`.
    func start(_ config: VMConfiguration, in bundle: URL) async throws

    /// Request a graceful guest shutdown where the engine supports it.
    func stop() async throws

    /// Force power-off without a guest shutdown handshake.
    func forceStop() async throws
}

extension VMEngine {
    nonisolated public static func availability() -> Result<Void, EngineError> { .success(()) }
}
