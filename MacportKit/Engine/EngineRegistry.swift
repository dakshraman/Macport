import Foundation

/// Decides which engine owns a guest.
///
/// This is policy, not a lookup table. The engine that *can* host a guest has to
/// beat the engine that is merely preferred, because getting it wrong does not
/// produce an error — it produces a machine that spins forever. Windows 11 Arm is
/// exactly that case: Virtualization.framework is faster, leaner and would win on
/// every other criterion, and it cannot host Windows at all.
public enum EngineRegistry {
    /// Every engine Macport ships, in order of preference for an ordinary guest.
    nonisolated public static var all: [any VMEngine.Type] {
        [VZEngine.self, QEMUEngine.self, WineEngine.self]
    }

    /// A plain description of an engine, for lists in the UI and the CLI.
    ///
    /// Exists because iterating `[any VMEngine.Type]` in a SwiftUI `ForEach` — a
    /// keypath applied to an existential metatype — crashes `swift-frontend` in
    /// SILGen. Projecting to a concrete `Identifiable` value keeps the UI free of
    /// metatype gymnastics and stays friendly to strict concurrency.
    public struct Descriptor: Identifiable, Hashable, Sendable {
        public let id: String
        public let displayName: String
    }

    nonisolated public static var descriptors: [Descriptor] {
        all.map { Descriptor(id: $0.identifier, displayName: $0.displayName) }
    }

    /// Human-readable name for an engine identifier, for labels and logs.
    nonisolated public static func displayName(forIdentifier identifier: String) -> String {
        all.first { $0.identifier == identifier }?.displayName ?? identifier
    }

    /// The engine that should own `config`.
    nonisolated public static func engineType(for config: VMConfiguration) -> any VMEngine.Type {
        // An explicit choice always wins. A user who pinned an engine meant it,
        // and second-guessing that would make the setting a lie.
        if let pinned = config.engineIdentifier,
           let match = all.first(where: { $0.identifier == pinned }) {
            return match
        }
        return preferredType(for: config.guest)
    }

    /// Choose on the guest's hard requirements first, and only then on speed.
    nonisolated public static func preferredType(for guest: GuestKind) -> any VMEngine.Type {
        if guest == .windowsApp {
            if isAvailable(WineEngine.self) { return WineEngine.self }
        }

        // A guest that needs a device Apple's framework does not have must go to
        // the engine that has it. Only fall back if that engine is not usable here.
        if guest.requiresOpticalBootMedia {
            if let capable = all.first(where: {
                $0.capabilities(for: guest).opticalMedia && isAvailable($0)
            }) {
                return capable
            }
        }

        // Otherwise take the leanest engine that runs the guest on the metal —
        // the same CPU through the same hypervisor, with virtio devices rather
        // than a software chipset model.
        if isAvailable(VZEngine.self) { return VZEngine.self }
        return QEMUEngine.self
    }

    /// Can this engine run at all on this Mac, right now?
    nonisolated public static func isAvailable(_ type: any VMEngine.Type) -> Bool {
        if case .success = type.availability() { return true }
        return false
    }

    /// Instantiate the engine selected for `config`.
    @MainActor public static func makeEngine(for config: VMConfiguration) -> any VMEngine {
        engineType(for: config).init()
    }

    /// A human-readable reason a guest ended up on a particular engine.
    ///
    /// Shown in the UI next to the capability table. Users deserve to know *why*
    /// their Windows machine is not using the fast engine.
    nonisolated public static func rationale(for config: VMConfiguration) -> String? {
        guard config.engineIdentifier == nil else { return nil }
        if config.guest == .windowsApp {
            return "Windows applications run through the Wine translation layer directly on the metal without virtual machine overhead."
        }
        if config.guest.requiresOpticalBootMedia {
            return "\(config.guest.displayName) installs from vendor media that must be "
                + "booted as an optical disc, so it runs on \(QEMUEngine.displayName) "
                + "rather than \(VZEngine.displayName)."
        }
        return nil
    }
}
