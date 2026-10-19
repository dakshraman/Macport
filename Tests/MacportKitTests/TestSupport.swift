import Foundation
import XCTest

/// Shared plumbing for the media tests.
///
/// Nothing here knows anything about Macport: it makes a private directory, writes
/// files into it, and can ask `hdiutil` what is mounted. Keeping it dumb is what lets
/// the tests say what they mean.

/// A unique directory under the system temporary directory, made for one test.
///
/// Tests remove these themselves with `defer`; a crash leaves one behind rather than
/// deleting something it does not own, which is the right way round.
func makeTemporaryDirectory(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("macportkit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Write `contents` to `root/relativePath`, creating the directories above it.
func write(
    _ relativePath: String,
    _ contents: String,
    in root: URL
) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let there = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return there && isDirectory.boolValue
}

func text(of url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// The message an XML document's first parse error reports, or `nil` when it is well
/// formed. Used where `xmllint` is not available.
func xmlParseError(_ data: Data) -> String? {
    let parser = XMLParser(data: data)
    guard !parser.parse() else { return nil }
    return parser.parserError?.localizedDescription ?? "unknown XML error"
}

/// `hdiutil` is part of macOS, but a CI image or a stripped runner may not have it.
/// Callers skip rather than fail: an ISO can be built only where the tool exists.
func requireHDIUtil() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil") else {
        throw XCTSkip("hdiutil is not available on this machine.")
    }
}

/// Whether an image is still attached, asked of `hdiutil` itself.
///
/// This is the assertion that proves the detach happened *and* that it happened to
/// the right device: the path is unique to one test run.
func isAttached(image: URL) throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["info"]

    let output = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = output
    process.standardError = errorPipe

    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let listing = String(decoding: data, as: UTF8.self)
    return listing.contains(image.path)
}
