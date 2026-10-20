import Foundation

/// Failures from inspecting or converting a foreign disk image. Each carries
/// enough of the underlying tool's output to be actionable without a second run.
public enum DiskImporterError: Error, LocalizedError, Sendable {
    /// `qemu-img` is missing, which means the managed runtime is not installed.
    case qemuImageToolUnavailable
    case sourceMissing(String)
    case unsupportedFormat(String)
    case inspectFailed(path: String, reason: String)
    case conversionFailed(path: String, reason: String)
    case ovaUnpackFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .qemuImageToolUnavailable:
            return "Importing needs qemu-img, which comes with Macport's managed "
                + "runtime. Install it from Macport's runtime screen and try again."
        case .sourceMissing(let path):
            return "There is no disk image at \(path)."
        case .unsupportedFormat(let format):
            return "Macport cannot import \(format) images. Supported: "
                + DiskImporter.supportedExtensions.sorted().joined(separator: ", ") + "."
        case .inspectFailed(let path, let reason):
            return "Could not read \(path) as a disk image: \(reason)"
        case .conversionFailed(let path, let reason):
            return "Could not convert \(path): \(reason)"
        case .ovaUnpackFailed(let path, let reason):
            return "Could not unpack \(path) as an OVA: \(reason)"
        }
    }
}

/// Convert an existing disk image into a shape Macport's engines can boot.
///
/// This is deliberately a thin, synchronous wrapper around the `qemu-img` that
/// ships inside Macport's own runtime: the same tool that can read qcow2 can read
/// VMDK, VDI and VHDX, and hiding that behind a private implementation would be
/// re-solving a solved problem. Progress reporting is the caller's job; a long
/// conversion runs off the main thread and the UI shows a spinner.
public enum DiskImporter {

    /// Extensions offered in the import picker. The list is what the UI shows and
    /// what error messages name; `qemu-img` itself auto-detects more.
    public static let supportedExtensions: Set<String> = [
        "qcow2", "img", "raw", "vmdk", "vdi", "vhdx", "ova", "hds"
    ]

    /// The format a converted disk is written in.
    public enum TargetFormat: String, Sendable {
        /// The only format that supports QEMU's `savevm` snapshots.
        case qcow2
        /// What Virtualization.framework uses directly.
        case raw
    }

    public struct DiskInfo: Sendable, Equatable {
        public var source: URL
        /// qemu-img's canonical format name, e.g. `qcow2`, `vmdk`, `raw`.
        public var format: String
        /// The size the guest sees, when qemu-img reports one.
        public var virtualSize: UInt64?
        /// Bytes actually occupied on the host, when qemu-img reports it.
        public var actualSize: UInt64?
    }

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Inspect

    public static func inspect(_ url: URL) throws -> DiskInfo {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw DiskImporterError.sourceMissing(url.path)
        }
        if url.pathExtension.lowercased() == "ova" {
            let unpacked = try unpackOVA(url)
            defer { try? fileManager.removeItem(at: unpacked.directory) }
            return try inspectPlain(unpacked.disk)
        }
        return try inspectPlain(url)
    }

    private static func inspectPlain(_ url: URL) throws -> DiskInfo {
        let tool = try imageTool()
        let result = try run(tool, ["info", "--output=json", url.path])
        guard result.status == 0 else {
            throw DiskImporterError.inspectFailed(
                path: url.path,
                reason: lastLine(of: result.stderr, fallback: "qemu-img exited \(result.status)")
            )
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)),
            let dictionary = object as? [String: Any],
            let format = dictionary["format"] as? String
        else {
            throw DiskImporterError.inspectFailed(path: url.path, reason: "qemu-img returned no format.")
        }
        return DiskInfo(
            source: url,
            format: format,
            virtualSize: (dictionary["virtual-size"] as? NSNumber)?.uint64Value,
            actualSize: (dictionary["actual-size"] as? NSNumber)?.uint64Value
        )
    }

    // MARK: - Convert

    /// Convert `source` into `destination` in `format`.
    ///
    /// The destination is written to a temporary sibling and renamed on success,
    /// so a cancelled or failed conversion can never be mistaken for a finished
    /// disk. The caller owns the destination directory.
    @discardableResult
    public static func convert(
        _ source: URL,
        to destination: URL,
        format: TargetFormat
    ) throws -> DiskInfo {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else {
            throw DiskImporterError.sourceMissing(source.path)
        }
        let tool = try imageTool()

        var effectiveSource = source
        var unpackedDirectory: URL?
        if source.pathExtension.lowercased() == "ova" {
            let unpacked = try unpackOVA(source)
            effectiveSource = unpacked.disk
            unpackedDirectory = unpacked.directory
        }
        defer {
            if let unpackedDirectory {
                try? fileManager.removeItem(at: unpackedDirectory)
            }
        }

        let staged = destination.appendingPathExtension("partial")
        try? fileManager.removeItem(at: staged)

        let result = try run(
            tool,
            ["convert", "-O", format.rawValue, effectiveSource.path, staged.path]
        )
        guard result.status == 0 else {
            try? fileManager.removeItem(at: staged)
            throw DiskImporterError.conversionFailed(
                path: source.path,
                reason: lastLine(of: result.stderr, fallback: "qemu-img exited \(result.status)")
            )
        }

        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staged, to: destination)
        return try inspectPlain(destination)
    }

    // MARK: - OVA

    /// Unpack the first disk member of an OVA tar into a fresh temporary
    /// directory. The caller removes the directory.
    public static func unpackOVA(_ url: URL) throws -> (directory: URL, disk: URL) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("macport-ova-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let listing = try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", url.path])
        guard listing.status == 0 else {
            try? fileManager.removeItem(at: directory)
            throw DiskImporterError.ovaUnpackFailed(
                path: url.path,
                reason: lastLine(of: listing.stderr, fallback: "tar could not list the archive")
            )
        }
        let diskExtensions: Set<String> = ["vmdk", "vhdx", "vdi", "qcow2", "img", "raw"]
        let member = listing.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                diskExtensions.contains((line as NSString).pathExtension.lowercased())
            }
        guard let member else {
            try? fileManager.removeItem(at: directory)
            throw DiskImporterError.ovaUnpackFailed(
                path: url.path,
                reason: "no disk image member was found inside the archive"
            )
        }

        let extraction = try run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xf", url.path, "-C", directory.path, member]
        )
        guard extraction.status == 0 else {
            try? fileManager.removeItem(at: directory)
            throw DiskImporterError.ovaUnpackFailed(
                path: url.path,
                reason: lastLine(of: extraction.stderr, fallback: "tar could not extract the disk")
            )
        }

        let disk = directory.appendingPathComponent(member)
        guard fileManager.fileExists(atPath: disk.path) else {
            try? fileManager.removeItem(at: directory)
            throw DiskImporterError.ovaUnpackFailed(path: url.path, reason: "extraction produced no file")
        }
        return (directory, disk)
    }

    // MARK: - Process plumbing

    private static func imageTool() throws -> URL {
        guard let tool = QEMURuntime.locate()?.imageBinary else {
            throw DiskImporterError.qemuImageToolUnavailable
        }
        return tool
    }

    private static func run(
        _ executable: URL,
        _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read both pipes before waiting, so a tool that writes more than a pipe
        // buffer cannot deadlock against its own exit.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }

    private static func lastLine(of text: String, fallback: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last ?? fallback
    }
}
