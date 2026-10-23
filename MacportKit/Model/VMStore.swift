import Foundation

/// On-disk home for `.macport` VM bundles.
///
/// Layout:
/// ```
/// ~/Library/Application Support/Macport/VMs/
///   <uuid>.macport/
///     config.json        VMConfiguration
///     disk.img           sparse root disk
///     efi.variables      EFI variable store (boot order, NVRAM)
///     Snapshots/         reserved; only engines reporting `snapshots` may fill this
/// ```
///
/// A VM is a *directory*, not a bag of loose files, because that is what makes
/// it portable: copy the bundle to another Mac and the machine comes with it.
@MainActor
public final class VMStore: ObservableObject {
    @Published public private(set) var machines: [VMConfiguration] = []
    @Published public private(set) var lastError: String?

    private let root: URL

    /// Default location, overridable so tests and the CLI do not fight the app
    /// over one directory.
    nonisolated public static var defaultRoot: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())

        return base
            .appendingPathComponent("Macport", isDirectory: true)
            .appendingPathComponent("VMs", isDirectory: true)
    }

    public init(root: URL = VMStore.defaultRoot) {
        self.root = root
    }

    // MARK: - Paths

    public func bundleURL(for config: VMConfiguration) -> URL {
        root.appendingPathComponent("\(config.id.uuidString).macport", isDirectory: true)
    }

    public func configURL(for config: VMConfiguration) -> URL {
        bundleURL(for: config).appendingPathComponent("config.json")
    }

    // MARK: - Loading

    public func load() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create VM directory: \(error.localizedDescription)"
            return
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            machines = []
            return
        }

        var found: [VMConfiguration] = []
        for entry in entries where entry.pathExtension == "macport" {
            let configFile = entry.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configFile) else { continue }
            do {
                found.append(try JSONDecoder().decode(VMConfiguration.self, from: data))
            } catch {
                // One unreadable bundle must not hide the rest. Surface it and
                // keep going — a single corrupt config is a survivable event.
                lastError = "Skipped \(entry.lastPathComponent): \(error.localizedDescription)"
            }
        }

        machines = found.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Mutation

    /// Persist a configuration, creating or updating its bundle.
    @discardableResult
    public func save(_ config: VMConfiguration) throws -> VMConfiguration {
        var config = config
        if config.name.trimmingCharacters(in: .whitespaces).isEmpty {
            config.name = "Untitled VM"
        }

        let bundle = bundleURL(for: config)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL(for: config), options: .atomic)

        if let idx = machines.firstIndex(where: { $0.id == config.id }) {
            machines[idx] = config
        } else {
            machines.append(config)
            machines.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return config
    }

    public func delete(_ config: VMConfiguration) throws {
        let bundle = bundleURL(for: config)
        if FileManager.default.fileExists(atPath: bundle.path) {
            try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
        }
        machines.removeAll { $0.id == config.id }
    }

    /// A name that does not collide with an existing VM.
    public func uniqueName(basedOn candidate: String = "New VM") -> String {
        let existing = Set(machines.map(\.name))
        if !existing.contains(candidate) { return candidate }
        var index = 2
        while existing.contains("\(candidate) \(index)") { index += 1 }
        return "\(candidate) \(index)"
    }

    /// Renames a VM configuration and synchronizes underlying storage and bottle metadata.
    @discardableResult
    public func rename(_ config: VMConfiguration, to newName: String) throws -> VMConfiguration {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return config }
        guard trimmed != config.name else { return config }

        var updated = config
        let oldName = config.name

        if config.guest == .windowsApp {
            let bURL = bundleURL(for: config)
            let bottleSymlink = bURL.appendingPathComponent("bottle")
            let fm = FileManager.default

            // If the bottle directory in the bundle is a symlink pointing to CrossOver's Bottles directory:
            if let dest = try? fm.destinationOfSymbolicLink(atPath: bottleSymlink.path) {
                let oldTargetURL = URL(fileURLWithPath: dest, relativeTo: bURL).standardized
                let coBottlesDir = WineRuntime.crossoverBottlesDirectory
                if oldTargetURL.path.hasPrefix(coBottlesDir.path) {
                    let sanitizedNewName = trimmed
                        .replacingOccurrences(of: "/", with: "-")
                        .replacingOccurrences(of: ":", with: "-")
                    let newTargetURL = coBottlesDir.appendingPathComponent(sanitizedNewName, isDirectory: true)
                    if !fm.fileExists(atPath: newTargetURL.path) {
                        try? fm.moveItem(at: oldTargetURL, to: newTargetURL)
                        try? fm.removeItem(at: bottleSymlink)
                        try? fm.createSymbolicLink(at: bottleSymlink, withDestinationURL: newTargetURL)
                    }
                }
            }

            if updated.wineSettings?.linkedCrossOverBottle == oldName {
                updated.wineSettings?.linkedCrossOverBottle = trimmed
            }

            if let primary = updated.wineSettings?.primaryExecutable {
                updated.wineSettings?.primaryExecutable = WineBottleManager.resolveExecutablePath(primary, in: bURL)
            }

            MacportAppPublisher.synchronizeLaunchers(for: config.id, newBottleName: trimmed, bundleURL: bURL)
        }

        updated.name = trimmed
        return try save(updated)
    }
}
