import Foundation

// MARK: - Guest kind

/// The guest operating system family a VM is configured to run.
///
/// A guest kind is not a cosmetic label. It is the input to
/// `EngineCapabilities`, and it is what stops the app from promising a feature
/// the hypervisor cannot actually deliver for that guest.
public enum GuestKind: String, Codable, CaseIterable, Sendable {
    /// 64-bit ARM Linux. The best-supported path on Apple silicon: same
    /// instruction set as the host, so it virtualises rather than emulates.
    case linuxARM

    /// Windows 11 on Arm. Runs at native CPU speed, but see
    /// `requiresTPM` — Windows 11's setup demands a TPM 2.0 device.
    case windowsARM

    /// macOS as a guest. Only legal on Apple hardware, per the macOS licence.
    case macOSGuest

    /// Windows Application running via Wine / Metal translation without a virtual machine.
    case windowsApp

    public var displayName: String {
        switch self {
        case .linuxARM: return "Linux (ARM64)"
        case .windowsARM: return "Windows 11 (Arm)"
        case .macOSGuest: return "macOS"
        case .windowsApp: return "Windows App (Translation)"
        }
    }

    /// Windows 11 refuses to install without a TPM 2.0 device present.
    ///
    /// This matters more than it looks: Apple's Virtualization framework does
    /// not provide a virtual TPM. Any engine built on it must therefore either
    /// apply an install-time registry bypass or hand off to an engine that can
    /// supply a vTPM (QEMU + swtpm). `EngineCapabilities.tpm` carries the answer
    /// so the UI can tell the user the truth *before* they spend an hour
    /// downloading an ISO.
    public var requiresTPM: Bool { self == .windowsARM }

    /// Does installing this guest require booting vendor install media?
    ///
    /// This is the requirement that decides which engine a guest is routed to.
    /// Windows installers ship as *pure optical* images — no MBR, no GPT, no FAT
    /// ESP — so they bootstrap through El Torito, and firmware only consults El
    /// Torito on media it identifies as a CD-ROM. Apple's Virtualization framework
    /// has no optical device at all, so a Windows installer cannot boot there on
    /// any transport. Linux ISOs are hybrid images carrying a real GPT and FAT
    /// ESP, so they boot as disks and need no optical device.
    public var requiresOpticalBootMedia: Bool { self == .windowsARM }

    /// Only macOS guests are restore-image (IPSW) based; everything else boots
    /// from install media or an existing disk.
    public var usesIPSWInstall: Bool { self == .macOSGuest }
}

// MARK: - Boot source

public enum BootSource: Codable, Hashable, Sendable {
    /// Boot a kernel directly — typical for Linux ARM cloud images.
    case kernelImage(kernel: String, commandLine: String)
    /// Boot from installer media (ISO) attached as a virtual CD-ROM.
    case installMedia(path: String)
    /// Boot straight from an existing disk with firmware defaults.
    case diskOnly
}

// MARK: - Networking

public enum NetworkMode: String, Codable, CaseIterable, Sendable {
    /// Host-provided NAT. No configuration, outbound only, no guest-to-guest.
    case sharedNAT
    /// Guest is not attached to any network.
    case disconnected

    public var displayName: String {
        switch self {
        case .sharedNAT: return "Shared (NAT)"
        case .disconnected: return "Disconnected"
        }
    }
}

// MARK: - Shared folders

public struct SharedFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var hostPath: String
    /// Read-only by default. Writable shares should be a deliberate choice.
    public var readOnly: Bool

    public init(id: UUID = UUID(), hostPath: String, readOnly: Bool = true) {
        self.id = id
        self.hostPath = hostPath
        self.readOnly = readOnly
    }
}

// MARK: - Wine & Graphics Settings

public enum GraphicsBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case d3dmetal
    case dxmt
    case dxvk
    case wined3d

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto (Recommended)"
        case .d3dmetal: return "D3DMetal (Apple GPTK)"
        case .dxmt: return "DXMT (Direct3D 11 to Metal)"
        case .dxvk: return "DXVK (Direct3D to Vulkan)"
        case .wined3d: return "WineD3D (OpenGL Fallback)"
        }
    }
}

public struct WineBottleSettings: Codable, Hashable, Sendable {
    public var backend: GraphicsBackend
    public var msyncEnabled: Bool
    public var metalFXEnabled: Bool
    public var hudEnabled: Bool
    public var retinaMode: Bool
    public var bottleTemplate: String
    public var linkedCrossOverBottle: String?
    public var primaryExecutable: String?

    public init(
        backend: GraphicsBackend = .auto,
        msyncEnabled: Bool = true,
        metalFXEnabled: Bool = true,
        hudEnabled: Bool = false,
        retinaMode: Bool = false,
        bottleTemplate: String = "win11_64",
        linkedCrossOverBottle: String? = nil,
        primaryExecutable: String? = nil
    ) {
        self.backend = backend
        self.msyncEnabled = msyncEnabled
        self.metalFXEnabled = metalFXEnabled
        self.hudEnabled = hudEnabled
        self.retinaMode = retinaMode
        self.bottleTemplate = bottleTemplate
        self.linkedCrossOverBottle = linkedCrossOverBottle
        self.primaryExecutable = primaryExecutable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.backend = try container.decodeIfPresent(GraphicsBackend.self, forKey: .backend) ?? .auto
        self.msyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .msyncEnabled) ?? true
        self.metalFXEnabled = try container.decodeIfPresent(Bool.self, forKey: .metalFXEnabled) ?? true
        self.hudEnabled = try container.decodeIfPresent(Bool.self, forKey: .hudEnabled) ?? false
        self.retinaMode = try container.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false
        self.bottleTemplate = try container.decodeIfPresent(String.self, forKey: .bottleTemplate) ?? "win11_64"
        self.linkedCrossOverBottle = try container.decodeIfPresent(String.self, forKey: .linkedCrossOverBottle)
        self.primaryExecutable = try container.decodeIfPresent(String.self, forKey: .primaryExecutable)
    }
}

// MARK: - Configuration

/// Serializable definition of one virtual machine.
///
/// Persisted as `config.json` inside a `<name>.macport` bundle directory, which
/// also holds the disk image, the EFI variable store and any snapshots. Keeping
/// the VM as a self-contained bundle is what makes it portable between machines.
public struct VMConfiguration: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var guest: GuestKind

    /// Virtual CPU count. One is the sane default; the UI must not hand out more
    /// vCPUs than the host has physical cores, which only degrades performance.
    public var cpuCount: Int
    public var memoryBytes: UInt64

    /// Nominal disk capacity. Backing storage is sparse, so this is a ceiling,
    /// not an allocation.
    public var diskBytes: UInt64

    public var network: NetworkMode
    public var sharedFolders: [SharedFolder]
    public var boot: BootSource

    /// Whether the guest may use a virtual TPM — only honoured by engines whose
    /// capabilities report `tpm == true`.
    public var tpmEnabled: Bool

    /// The value a picker binds to when the user has not pinned an engine.
    ///
    /// A named constant rather than a bare `"auto"` so the UI and the model cannot
    /// drift. It is deliberately *not* the same as `nil`: `nil` is the real "unset"
    /// state persisted on disk, and this is only ever a UI selection.
    public static let automaticEngine = "auto"

    /// Engine that owns this VM. `nil` means "pick the best available".
    public var engineIdentifier: String?

    /// Wine translation bottle settings (active for `windowsApp` guests).
    public var wineSettings: WineBottleSettings?

    public init(
        id: UUID = UUID(),
        name: String,
        guest: GuestKind,
        cpuCount: Int = 4,
        memoryBytes: UInt64 = 4 * 1024 * 1024 * 1024,
        diskBytes: UInt64 = 64 * 1024 * 1024 * 1024,
        network: NetworkMode = .sharedNAT,
        sharedFolders: [SharedFolder] = [],
        boot: BootSource = .diskOnly,
        tpmEnabled: Bool = false,
        engineIdentifier: String? = nil,
        wineSettings: WineBottleSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.guest = guest
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.network = network
        self.sharedFolders = sharedFolders
        self.boot = boot
        self.tpmEnabled = tpmEnabled
        self.engineIdentifier = engineIdentifier
        self.wineSettings = wineSettings ?? (guest == .windowsApp ? WineBottleSettings() : nil)
    }
}

// MARK: - Convenience

extension UInt64 {
    /// Human-readable byte count, e.g. `8 GB`.
    public var gbString: String {
        let gb = Double(self) / (1024 * 1024 * 1024)
        return gb.rounded() == gb
            ? "\(Int(gb)) GB"
            : String(format: "%.1f GB", gb)
    }
}
