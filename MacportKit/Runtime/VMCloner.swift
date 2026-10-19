import Darwin
import Foundation

/// Failures a clone can produce, each with a next step a person can take.
public enum VMClonerError: Error, LocalizedError, Sendable {
    /// The source bundle is not where the store says it is.
    case sourceMissing(String)
    /// Something already occupies the destination identity.
    case destinationExists(String)
    /// The destination volume cannot clone (not APFS) and copy fallback was not
    /// authorised. Cloning a 80 GB disk is instant; copying one is not, so the
    /// caller has to mean it.
    case cloneNotSupported(source: String, reason: String)
    /// `clonefile` failed for a reason that is not a volume-capability issue.
    case cloneFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "The machine's bundle is missing at \(path)."
        case .destinationExists(let path):
            return "A bundle already exists at \(path). Delete it or pick another name."
        case .cloneNotSupported(let source, let reason):
            return "This Mac cannot clone \(source) instantly (\(reason)). "
                + "Moving the VM to an APFS volume, or exporting and importing it, "
                + "avoids a full disk copy."
        case .cloneFailed(let path, let reason):
            return "Could not clone \(path): \(reason)"
        }
    }
}

/// Instant, copy-on-write clones of a stopped VM.
///
/// Clone is a bundle operation, not an engine operation: every engine keeps its
/// machine in the same directory shape, so the only engine-specific detail is
/// that a VZ guest's platform identifier must not be shared with its clone. The
/// caller is responsible for stopping the machine first; this type refuses to
/// guess whether a running guest is quiescent.
public enum VMCloner {

    /// Files that describe *this run* rather than the machine, and must never be
    /// inherited by a clone: a stale lock reads as "already running", and a stale
    /// `runtime.json` points the next launch at the original's socket and PID.
    public static let transientFileNames: Set<String> = [
        ".lock", "runtime.json", "qemu.log", "console.log"
    ]

    /// Clone `config`'s bundle into a new bundle owned by a new configuration.
    ///
    /// - Parameters:
    ///   - name: The clone's display name. Empty means "<original> Copy".
    ///   - copyFallback: When `true`, a non-APFS destination falls back to a real
    ///     file copy. Defaults to `false`, because a silent multi-gigabyte copy is
    ///     the kind of surprise that looks like a hang.
    @MainActor
    @discardableResult
    public static func clone(
        _ config: VMConfiguration,
        in store: VMStore,
        named name: String = "",
        copyFallback: Bool = false
    ) throws -> VMConfiguration {
        let fileManager = FileManager.default
        let source = store.bundleURL(for: config)

        guard fileManager.fileExists(atPath: source.path) else {
            throw VMClonerError.sourceMissing(source.path)
        }

        var copy = config
        copy.id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmed.isEmpty
            ? store.uniqueName(basedOn: "\(config.name) Copy")
            : trimmed

        let destination = store.bundleURL(for: copy)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw VMClonerError.destinationExists(destination.path)
        }

        do {
            try cloneTree(
                from: source,
                to: destination,
                copyFallback: copyFallback,
                fileManager: fileManager
            )
        } catch let error as VMClonerError {
            throw error
        } catch {
            throw VMClonerError.cloneFailed(path: source.path, reason: error.localizedDescription)
        }

        for transient in transientFileNames {
            try? fileManager.removeItem(at: destination.appendingPathComponent(transient))
        }

        // VZGenericPlatformConfiguration binds a guest to a machine identifier.
        // Sharing it between original and clone is not supported by the framework;
        // `create` regenerates it on first start.
        try? fileManager.removeItem(at: destination.appendingPathComponent("machine-id.bin"))

        // `save` rewrites config.json with the new identity and publishes the
        // clone in the store, so there is one writer for both.
        return try store.save(copy)
    }

    /// Recursively recreate `source` at `destination`, preferring APFS clones.
    static func cloneTree(
        from source: URL,
        to destination: URL,
        copyFallback: Bool,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            throw VMClonerError.cloneFailed(path: source.path, reason: "Could not read the bundle.")
        }

        let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"

        for case let item as URL in enumerator {
            guard item.path.hasPrefix(prefix) else { continue }
            let relative = String(item.path.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }

            let target = destination.appendingPathComponent(relative)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            if values.isSymbolicLink == true {
                let link = try fileManager.destinationOfSymbolicLink(atPath: item.path)
                try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                continue
            }

            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            if clonefile(item.path, target.path, 0) == 0 { continue }

            let failure = errno
            let fallbackCodes: Set<Int32> = [ENOTSUP, EOPNOTSUPP, EXDEV, EPERM]
            if copyFallback, fallbackCodes.contains(failure) {
                try fileManager.copyItem(at: item, to: target)
                continue
            }
            if fallbackCodes.contains(failure) {
                throw VMClonerError.cloneNotSupported(
                    source: source.path,
                    reason: String(cString: strerror(failure))
                )
            }
            throw VMClonerError.cloneFailed(
                path: item.path,
                reason: String(cString: strerror(failure))
            )
        }
    }
}
