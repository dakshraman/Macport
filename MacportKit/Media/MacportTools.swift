import CryptoKit
import Foundation

/// Macport Tools: the media Windows Setup is handed so a fresh Arm64 machine has the
/// devices it was built on.
///
/// Windows ships no driver for virtio anything. Without one, Setup sees no disk to
/// install to, the installed machine sees no network, and the display stays at the
/// firmware's 800x600 — the three gaps `docs/FEATURE-PARITY.md` §3.4 names as the
/// highest-leverage item on the roadmap. The media this type builds closes them by
/// staging Red Hat's redistributable virtio-win drivers and pointing Setup at them
/// through the answer file, which is the same mechanism Parallels' Arm64 media uses.
///
/// The result is one hybrid ISO that:
///
/// - carries `autounattend.xml` at its root, so Setup finds it by browsing media;
/// - carries the Arm64 driver trees under `drivers/<Driver>/arm64/`;
/// - is expected to appear in the guest at a known drive letter (`E:` by default),
///   which is the assumption `docs/REFACTOR-PLAN.md` §3.8 records as one to verify
///   on the next real installation.
///
/// The virtio-win release is **pinned**. A driver pack that decides which virtio
/// devices a guest can see must not change under the product's feet, so the version
/// and URL below name one release, and the downloader will check both a size floor
/// and, when the caller supplies one, a SHA-256 digest.
public enum MacportTools {

    // MARK: - The pinned source

    /// The virtio-win release this build stages drivers from.
    nonisolated public static let version = "0.1.302"

    /// Where that release's ISO comes from.
    ///
    /// Checked live with a `HEAD` request when this was written: `200 OK`,
    /// 877,373,440 bytes, `last-modified 2026-08-27`. The URL is deliberately the
    /// archive path, not `stable-virtio`, so a later release cannot silently become
    /// "the pinned one".
    nonisolated public static let downloadURL: URL = {
        let address = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads"
            + "/archive-virtio/virtio-win-\(version)-1/virtio-win-\(version).iso"
        guard let url = URL(string: address) else {
            preconditionFailure("The pinned virtio-win URL is malformed: \(address)")
        }
        return url
    }()

    /// An explicit ISO override, for development and for a cached copy somewhere
    /// unusual. Checked first, exactly like `MACPORT_QEMU_DIR`.
    nonisolated public static let environmentOverride = "MACPORT_TOOLS_ISO"

    /// The name a cached ISO takes once it is Macport's own.
    nonisolated public static let cachedISOFileName = "virtio-win.iso"

    /// The floor a downloaded ISO has to clear before Macport will use it.
    ///
    /// The pinned release is 836 MiB; half a gigabyte is far below it and far above
    /// any error page or partial transfer that reports success. It is a sanity check
    /// against a truncated download, not a security control.
    nonisolated public static let minimumDownloadBytes: Int64 = 500 * 1_024 * 1_024

    /// The label the media appears under in the guest.
    nonisolated public static let volumeLabel = "MACPORTTOOLS"

    // MARK: - Media layout

    /// The directory inside the media that holds the staged driver trees.
    nonisolated public static let driversDirectoryName = "drivers"

    /// The directory inside each driver that holds this architecture's binaries.
    nonisolated public static let architectureDirectoryName = "arm64"

    /// The drive letter Windows is expected to give the tools media.
    ///
    /// An assumption, not a fact: it follows from attaching the media after the
    /// installation media, and `docs/REFACTOR-PLAN.md` §3.8 records that it has to be
    /// verified on a real install. Everything that consumes it takes it as a
    /// parameter, so a wrong answer is one argument, not one redesign.
    nonisolated public static let defaultDriveLetter = "E:"

    /// The drivers Macport stages, in the order they appear in the answer file.
    ///
    /// Every one of these answers a device a Macport VM actually presents now or will
    /// present in Phase 2: `NetKVM` the network card, `viostor`/`vioscsi` the disk,
    /// `viofs` shared folders, `Balloon` memory reclaim, `vioser` the agent channel,
    /// `viogpudo` the display. Names are the ISO's own directory names.
    nonisolated public static let driverNames = [
        "NetKVM",
        "viostor",
        "vioscsi",
        "viofs",
        "Balloon",
        "vioser",
        "viogpudo",
    ]

    // MARK: - Locations

    /// Where Macport keeps assets it owns: `~/Library/Application Support/Macport/Runtime`.
    ///
    /// Shared with the QEMU runtime so a user clearing Macport's storage finds
    /// everything in one place.
    nonisolated public static var toolsDirectory: URL {
        VMStore.defaultRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
    }

    /// Where a downloaded or hand-placed ISO is expected to live.
    nonisolated public static var cachedISOURL: URL {
        toolsDirectory.appendingPathComponent(cachedISOFileName)
    }

    /// Find an ISO to stage drivers from, or report that there is none.
    ///
    /// Order is deliberate and matches the QEMU runtime's: an explicit override, then
    /// Macport's own copy, then nothing. "Nothing" is a real answer — the caller tells
    /// the user what to do about it rather than failing somewhere later with an
    /// `hdiutil` message.
    ///
    /// The environment and the cache location are parameters so tests do not have to
    /// mutate the process environment or depend on what is installed on the machine.
    nonisolated public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cachedISO: URL? = MacportTools.cachedISOURL,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment[environmentOverride], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        if let cachedISO, fileManager.fileExists(atPath: cachedISO.path) {
            return cachedISO
        }
        return nil
    }

    // MARK: - Download

    /// Fetch the pinned ISO into `destination`.
    ///
    /// Not called by anything automatically yet: a 836 MiB download is a decision the
    /// user makes, not a side effect of starting a machine. When the UI grows a "get
    /// Macport Tools" button it calls this, which is why the progress callback and the
    /// size floor exist now.
    ///
    /// `expectedSHA256` is checked when supplied. Macport does not invent one: the
    /// digest of the pinned release has to be recorded by whoever pins it, and a
    /// fabricated constant would be worse than an absent check.
    @discardableResult
    nonisolated public static func download(
        to destination: URL = MacportTools.cachedISOURL,
        expectedSHA256: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let reporter = DownloadProgressReporter(progress: progress)
        let (temporary, response) = try await URLSession.shared.download(
            from: downloadURL,
            delegate: reporter
        )

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MacportToolsError.downloadRejected(status: http.statusCode)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: temporary.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= minimumDownloadBytes else {
            throw MacportToolsError.downloadIncomplete(bytes: size, minimum: minimumDownloadBytes)
        }

        if let expected = expectedSHA256, !expected.isEmpty {
            let actual = try sha256(of: temporary)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw MacportToolsError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        return destination
    }

    /// SHA-256 of a file, read in chunks so a gigabyte does not become one allocation.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reports download progress without keeping any state of its own.
    ///
    /// URLSession calls delegate methods on its own queue; the only thing this holds
    /// is the caller's immutable closure, so nothing here is shared mutably across
    /// queues and the `@unchecked` is an accurate statement rather than a bypass.
    private final class DownloadProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let progress: (@Sendable (Double) -> Void)?

        init(progress: (@Sendable (Double) -> Void)?) {
            self.progress = progress
            super.init()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        /// Required by the protocol even though the async download API hands the
        /// caller the temporary file itself, so there is nothing to do here.
        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
    }

    // MARK: - Mounting

    /// Mount an ISO read-only at a mountpoint only Macport knows about, run `body`,
    /// and detach that same mountpoint afterwards — including when `body` throws.
    ///
    /// Two rules matter and both are deliberate. The mount is `-readonly -nobrowse`
    /// so nothing can be written and the volume does not appear in Finder. And the
    /// detach names *the explicit mountpoint*: never `-force`, and never "all". A
    /// stray `hdiutil detach /` or a blanket eject is how a tool takes a user's
    /// external drive with it, and no driver media is worth that risk.
    nonisolated public static func withMountedImage<T>(
        at image: URL,
        _ body: (URL) throws -> T
    ) throws -> T {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: image.path) else {
            throw MacportToolsError.imageNotFound(image)
        }

        let mountpoint = fileManager.temporaryDirectory
            .appendingPathComponent("macport-tools-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountpoint, withIntermediateDirectories: true)

        var attached = false
        defer {
            if attached {
                // Best effort, and only ever this mountpoint: never `-force`, never
                // "all". The success path below reports a failed detach; this exists
                // so a throw from `body` still tries to leave nothing mounted.
                _ = try? run(hdiutil, ["detach", mountpoint.path])
            }
            try? fileManager.removeItem(at: mountpoint)
        }

        _ = try run(hdiutil, [
            "attach", "-readonly", "-nobrowse",
            "-mountpoint", mountpoint.path,
            image.path,
        ])
        attached = true

        let value = try body(mountpoint)

        // The body is done: if the volume will not unmount, that is worth reporting
        // rather than swallowing, because the user has an ISO stuck in their sidebar.
        try run(hdiutil, ["detach", mountpoint.path])
        attached = false
        return value
    }

    // MARK: - Staging drivers

    /// One driver tree staged into the media staging directory.
    public struct StagedDriver: Sendable, Equatable {
        /// The driver's name as it appears on the media, e.g. `NetKVM`.
        public var name: String
        /// `staging/drivers/<name>/arm64`.
        public var directory: URL
        /// How many files the tree contributed. Reported so a caller can tell an empty
        /// directory from a real package.
        public var fileCount: Int
    }

    /// What a staging pass found: what went in, and what was not in the ISO at all.
    public struct StagingReport: Sendable, Equatable {
        public var staged: [StagedDriver]
        public var missing: [String]

        /// The staged driver names, in media order.
        public var names: [String] { staged.map(\.name) }
    }

    /// Mount `isoURL` read-only and stage the Arm64 driver trees into `staging`.
    ///
    /// `staging` is the root of the media being built: this writes
    /// `staging/drivers/<Driver>/arm64/…`, exactly the layout the answer file's
    /// `DriverPaths` entries name.
    @discardableResult
    nonisolated public static func stageDrivers(
        from isoURL: URL,
        into staging: URL,
        drivers: [String] = MacportTools.driverNames
    ) throws -> StagingReport {
        try withMountedImage(at: isoURL) { root in
            try stageDriverTrees(from: root, into: staging, drivers: drivers)
        }
    }

    /// The staging itself, with no `hdiutil` in sight: copy the Arm64 trees found
    /// under `source` into `staging/drivers/<Driver>/arm64`.
    ///
    /// This is the part worth testing, so it is a function that takes an ordinary
    /// directory. `source` is the mounted ISO in production and a synthetic tree in
    /// tests; nothing else differs.
    ///
    /// A driver that is absent is reported, not fatal. Real ISOs gain and lose Arm64
    /// trees between releases (`viofs` in particular), and refusing to build media
    /// that carries six drivers because a seventh moved would trade a working
    /// installation for tidiness. `prepareMedia` turns a report with *nothing* in it
    /// into an error.
    @discardableResult
    nonisolated public static func stageDriverTrees(
        from source: URL,
        into staging: URL,
        drivers: [String] = MacportTools.driverNames
    ) throws -> StagingReport {
        let fileManager = FileManager.default
        let root = staging.appendingPathComponent(driversDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        var staged: [StagedDriver] = []
        var missing: [String] = []

        for requested in drivers {
            guard let spec = DriverSpec.match(requested) else {
                missing.append(requested)
                continue
            }
            if staged.contains(where: { $0.name == spec.name }) { continue }

            guard let driverDirectory = driverDirectory(for: spec, in: source),
                  let arm64 = arm64Tree(in: driverDirectory)
            else {
                missing.append(spec.name)
                continue
            }

            let destination = root
                .appendingPathComponent(spec.name, isDirectory: true)
                .appendingPathComponent(architectureDirectoryName, isDirectory: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let fileCount = try copyTree(from: arm64, to: destination)
            guard fileCount > 0 else {
                // An empty Arm64 directory is an ISO packaging accident, not a
                // driver. Leaving it out lets the caller see it as missing.
                try? fileManager.removeItem(at: destination)
                missing.append(spec.name)
                continue
            }

            staged.append(StagedDriver(name: spec.name, directory: destination, fileCount: fileCount))
        }

        return StagingReport(staged: staged, missing: missing)
    }

    /// The directory in `source` that holds a driver's packages.
    ///
    /// Matched case-insensitively because the ISO's own capitalisation is not a
    /// contract — `NetKVM` and `viostor` sit beside each other on the same disc.
    private static func driverDirectory(for spec: DriverSpec, in source: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let wanted = Set(spec.sourceNames.map { $0.lowercased() })
        let candidates = entries.filter {
            wanted.contains($0.lastPathComponent.lowercased())
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        // An exact-case match wins when both spellings exist, so the canonical ISO
        // layout is preferred over an alias.
        return candidates.first { $0.lastPathComponent == spec.name }
            ?? candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// Find the `arm64` tree inside a driver directory.
    ///
    /// virtio-win lays drivers out per OS and architecture. The shapes seen in the
    /// wild are `<Driver>/arm64` and `<Driver>/<version>/ARM64`, and the version
    /// directory can be several of them (`w10`, `w11`, `2k25`). A Windows 11 Arm
    /// machine wants the newest one, so `w11` outranks `w10`, and the search is
    /// bounded so a packaging accident cannot turn into an unbounded walk of a
    /// mounted volume.
    private static func arm64Tree(in driverDirectory: URL) -> URL? {
        let wanted = architectureDirectoryName.lowercased()
        var candidates: [URL] = []

        func walk(_ directory: URL, depth: Int) {
            guard depth <= 3 else { return }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if entry.lastPathComponent.lowercased() == wanted {
                    candidates.append(entry)
                } else {
                    walk(entry, depth: depth + 1)
                }
            }
        }

        walk(driverDirectory, depth: 1)
        return candidates.sorted { lhs, rhs in
            let lhsRank = versionRank(of: lhs)
            let rhsRank = versionRank(of: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.path < rhs.path
        }.first
    }

    /// Lower is newer. A direct `<Driver>/arm64` beats any versioned tree.
    private static func versionRank(of tree: URL) -> Int {
        let parent = tree.deletingLastPathComponent().lastPathComponent.lowercased()
        if parent == architectureDirectoryName.lowercased() { return 0 }
        if parent.contains("w11") || parent.contains("2k25") { return 1 }
        if parent.contains("w10") || parent.contains("2k22") || parent.contains("2k19") { return 2 }
        return 3
    }

    /// Copy a directory tree as-is. Returns the number of files copied.
    ///
    /// As-is is deliberate. The payload is `.inf`, `.sys`, `.cat` and `.dll`, but a
    /// package is a unit: an INF that names a helper or a symbol file is not wrong
    /// because this function did not expect the extension, and the Arm64 trees are
    /// small enough that filtering would buy nothing but a new way to fail.
    @discardableResult
    private static func copyTree(from source: URL, to destination: URL) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var count = 0
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let target = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: false)
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                count += try copyTree(from: entry, to: target)
            } else {
                try fileManager.copyItem(at: entry, to: target)
                count += 1
            }
        }
        return count
    }

    /// The driver directory names on the virtio-win ISO, plus the aliases newer or
    /// older releases have used for the same device.
    private struct DriverSpec {
        let name: String
        let aliases: [String]

        var sourceNames: [String] { [name] + aliases }

        static let all: [DriverSpec] = [
            DriverSpec(name: "NetKVM", aliases: []),
            DriverSpec(name: "viostor", aliases: []),
            DriverSpec(name: "vioscsi", aliases: []),
            DriverSpec(name: "viofs", aliases: []),
            DriverSpec(name: "Balloon", aliases: []),
            // The ISO directory is `vioser`; the component it carries is `vioserial`.
            DriverSpec(name: "vioser", aliases: ["vioserial"]),
            // `viogpudo` is the WDDM display driver; `viogpu` is how some tooling
            // refers to the same device family.
            DriverSpec(name: "viogpudo", aliases: ["viogpu"]),
        ]

        /// Match a requested name against canonical names and aliases.
        static func match(_ requested: String) -> DriverSpec? {
            let lowered = requested.lowercased()
            return all.first { $0.sourceNames.contains { $0.lowercased() == lowered } }
        }
    }

    // MARK: - Building the media

    /// Build the tools media at `url` with `answerFile` at its root.
    ///
    /// The staging directory is private and short-lived; what survives is the ISO.
    /// `drivers/` is created even when empty so the media has the shape the answer
    /// file describes.
    @discardableResult
    nonisolated public static func buildMedia(to url: URL, answerFile: Data) throws -> URL {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("macport-tools-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try answerFile.write(to: staging.appendingPathComponent(UnattendMedia.fileName))
        try fileManager.createDirectory(
            at: staging.appendingPathComponent(driversDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )

        return try buildMedia(to: url, staging: staging)
    }

    /// Build a hybrid ISO from a staging directory that is already populated.
    ///
    /// Split out because staging drivers and staging an answer file come from
    /// different places, and both have to end up on one disc before it is written.
    /// Joliet is what lets Setup read names like `NetKVM` and `autounattend.xml`
    /// without the 8.3 mangle.
    @discardableResult
    nonisolated public static func buildMedia(to url: URL, staging: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // `makehybrid` refuses to overwrite in some versions; replacing the media is
        // the documented behaviour of everything else in this file, so do it here
        // explicitly rather than discovering the difference on a second build.
        try? fileManager.removeItem(at: url)

        _ = try run(hdiutil, [
            "makehybrid",
            "-o", url.path,
            "-iso",
            "-joliet",
            "-default-volume-name", volumeLabel,
            staging.path,
        ])
        return url
    }

    // MARK: - The whole pipeline

    /// Build a complete Macport Tools media for `guest`: resolve an ISO, stage only
    /// the driver trees, write the answer file that points at them, and make the disc.
    ///
    /// Only drivers are staged. The source ISO also carries an installer, an agent
    /// and drivers for every other Windows release; none of that belongs on media
    /// Setup reads, and none of it is copied.
    ///
    /// `iso` is an explicit override for tests and for callers that already resolved
    /// an ISO. Left `nil`, it resolves through the same order as everywhere else.
    @discardableResult
    nonisolated public static func prepareMedia(
        for guest: GuestKind,
        at url: URL,
        iso: URL? = nil,
        driveLetter: String = MacportTools.defaultDriveLetter
    ) throws -> URL {
        let fileManager = FileManager.default

        let source: URL
        if let iso {
            guard fileManager.fileExists(atPath: iso.path) else {
                throw MacportToolsError.imageNotFound(iso)
            }
            source = iso
        } else if let resolved = resolve() {
            source = resolved
        } else {
            throw MacportToolsError.isoNotAvailable(cachedISO: cachedISOURL)
        }

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("macport-tools-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let report = try stageDrivers(from: source, into: staging)
        guard !report.staged.isEmpty else {
            throw MacportToolsError.noArm64Drivers(missing: report.missing, iso: source)
        }

        if UnattendMedia.isNeeded(for: guest) {
            let paths = try driverPaths(for: report.names, driveLetter: driveLetter)
            try UnattendMedia.answerFileXML(driverPaths: paths)
                .write(to: staging.appendingPathComponent(UnattendMedia.fileName))
        }

        return try buildMedia(to: url, staging: staging)
    }

    /// The guest paths the answer file should hand Setup for `drivers`.
    ///
    /// The staging layout and these paths are two views of one decision, so they are
    /// derived from the same constants.
    nonisolated public static func driverPaths(
        for drivers: [String] = MacportTools.driverNames,
        driveLetter: String = MacportTools.defaultDriveLetter
    ) throws -> [String] {
        let letter = try normalisedDriveLetter(driveLetter)
        return drivers.map {
            "\(letter)\\\(driversDirectoryName)\\\($0)\\\(architectureDirectoryName)"
        }
    }

    /// `E` and `e:` both become `E:`; anything else is refused.
    nonisolated static func normalisedDriveLetter(_ letter: String) throws -> String {
        let trimmed = letter.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        guard characters.count == 1 || (characters.count == 2 && characters[1] == ":"),
              let first = characters.first,
              first.isASCII,
              first.isLetter
        else {
            throw MacportToolsError.invalidDriveLetter(letter)
        }
        return "\(Character(String(first).uppercased())):"
    }

    // MARK: - Running hdiutil

    private static let hdiutil = "/usr/bin/hdiutil"

    /// Run a tool to completion and return its standard output.
    ///
    /// A non-zero status becomes an error carrying the tool's own diagnostics,
    /// because "hdiutil failed" without its message is useless.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MacportToolsError.toolFailed(
                tool: (tool as NSString).lastPathComponent,
                status: process.terminationStatus,
                message: String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What can go wrong building Macport Tools, with enough detail to act on.
public enum MacportToolsError: LocalizedError {

    /// No ISO was found anywhere the resolver looks.
    case isoNotAvailable(cachedISO: URL)
    /// A named ISO does not exist.
    case imageNotFound(URL)
    /// `hdiutil` (or another tool) exited non-zero. Carries its own message.
    case toolFailed(tool: String, status: Int32, message: String)
    /// The ISO mounted, but none of the Arm64 driver trees were found in it.
    case noArm64Drivers(missing: [String], iso: URL)
    /// A download finished smaller than `minimumDownloadBytes`.
    case downloadIncomplete(bytes: Int64, minimum: Int64)
    /// The server answered, but not with a file.
    case downloadRejected(status: Int)
    /// A digest was supplied and the file did not match it.
    case checksumMismatch(expected: String, actual: String)
    /// A drive letter that will not do (`""`, `"EE"`, `"1"`).
    case invalidDriveLetter(String)

    public var errorDescription: String? {
        switch self {
        case .isoNotAvailable(let cachedISO):
            return """
            No virtio-win ISO is available to build Macport Tools from. Set \
            \(MacportTools.environmentOverride) to a virtio-win \
            \(MacportTools.version) ISO, place one at \(cachedISO.path), or run \
            MacportTools.download() to fetch the pinned release \
            (\(MacportTools.downloadURL.absoluteString)).
            """
        case .imageNotFound(let url):
            return "There is no ISO at \(url.path)."
        case .toolFailed(let tool, let status, let message):
            let detail = message.isEmpty ? "no diagnostics on stderr" : message
            return "\(tool) exited with status \(status): \(detail)"
        case .noArm64Drivers(let missing, let iso):
            return """
            The ISO at \(iso.path) mounted, but none of the Arm64 driver \
            directories Macport looks for were found (\(missing.joined(separator: ", "))). \
            A Macport Tools media without drivers cannot help Setup see a disk or a \
            network card, so it is not built at all.
            """
        case .downloadIncomplete(let bytes, let minimum):
            return """
            The download finished at \(bytes) bytes, below the \(minimum)-byte \
            floor, so it is a truncated or error response rather than the \
            virtio-win ISO.
            """
        case .downloadRejected(let status):
            return "The download server answered HTTP \(status) instead of the ISO."
        case .checksumMismatch(let expected, let actual):
            return """
            The downloaded ISO is not the pinned file: expected SHA-256 \(expected), \
            got \(actual).
            """
        case .invalidDriveLetter(let letter):
            let shown = letter.isEmpty ? "(empty)" : letter
            return """
            "\(shown)" is not a drive letter. Use a single letter, optionally \
            followed by a colon — for example E or E:.
            """
        }
    }
}
