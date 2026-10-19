import Foundation
import XCTest
@testable import MacportKit

/// Tests for the pure parts of `QEMUEngine`'s snapshot support: disk-format
/// detection, name sanitising, and parsing QEMU's two snapshot listings.
///
/// These are deliberately free of a running QEMU — each function takes bytes or
/// text, so the formats can be pinned without a hypervisor.
final class QEMUSnapshotParsingTests: XCTestCase {

    // MARK: - Disk format detection

    func testQcow2MagicIsDetected() throws {
        let url = try temporaryFile(contents: Data([0x51, 0x46, 0x49, 0xFB, 0x00, 0x00, 0x00, 0x03]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(QEMUEngine.diskFormat(at: url), .qcow2)
    }

    func testRawHeaderIsDetected() throws {
        let url = try temporaryFile(contents: Data("this is a raw disk image".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(QEMUEngine.diskFormat(at: url), .raw)
    }

    func testShortFileHasNoReadableFormat() throws {
        let url = try temporaryFile(contents: Data([0x51, 0x46]))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertNil(QEMUEngine.diskFormat(at: url))
    }

    func testMissingFileHasNoFormat() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-missing-\(UUID().uuidString.prefix(8)).img")
        XCTAssertNil(QEMUEngine.diskFormat(at: url))
    }

    func testResolveDiskPrefersQcow2AndReadsItsHeader() throws {
        let bundle = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }

        try Data("raw contents here".utf8).write(to: bundle.appendingPathComponent("disk.img"))
        try Data([0x51, 0x46, 0x49, 0xFB]).write(to: bundle.appendingPathComponent("disk.qcow2"))

        let disk = try XCTUnwrap(QEMUEngine.resolveDisk(in: bundle))
        XCTAssertEqual(disk.url.lastPathComponent, "disk.qcow2")
        XCTAssertEqual(disk.format, .qcow2)
    }

    func testResolveDiskFallsBackToLegacyRawImage() throws {
        let bundle = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }

        try Data("legacy raw".utf8).write(to: bundle.appendingPathComponent("disk.img"))

        let disk = try XCTUnwrap(QEMUEngine.resolveDisk(in: bundle))
        XCTAssertEqual(disk.url.lastPathComponent, "disk.img")
        XCTAssertEqual(disk.format, .raw)
    }

    func testResolveDiskReturnsNilWhenThereIsNoDisk() throws {
        let bundle = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }

        XCTAssertNil(QEMUEngine.resolveDisk(in: bundle))
    }

    // MARK: - Snapshot name sanitising

    func testSanitizeReplacesIllegalCharacters() {
        XCTAssertEqual(QEMUEngine.sanitizeSnapshotName("Before update"), "Before-update")
        XCTAssertEqual(QEMUEngine.sanitizeSnapshotName("a/b:c*d?e"), "a-b-c-d-e")
        XCTAssertEqual(QEMUEngine.sanitizeSnapshotName("keep._-"), "keep._-")
    }

    func testSanitizeIsBoundedAndNeverEmpty() {
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(QEMUEngine.sanitizeSnapshotName(long).count, 64)
        XCTAssertEqual(QEMUEngine.sanitizeSnapshotName("   "), "snapshot")
        XCTAssertEqual(QEMUEngine.sanitizeSnapshotName(""), "snapshot")
        XCTAssertEqual(QEMUEngine.sanitizeSnapshotName("..."), "snapshot")
    }

    func testSanitizeIsStableSoTagsRoundTrip() {
        for name in ["Before update", "a/b:c", String(repeating: "y", count: 200)] {
            let tag = QEMUEngine.sanitizeSnapshotName(name)
            XCTAssertEqual(QEMUEngine.sanitizeSnapshotName(tag), tag)
        }
    }

    // MARK: - HMP `info snapshots`

    func testParsesSnapshotTable() {
        let text = """
        List of snapshots present on all disks:
        ID        TAG                     VM SIZE                DATE       VM CLOCK
        --        Before-update             131 MB 2026-10-19 12:00:00   00:00:01.123
        1         clean                       0 B 2026-10-18 09:30:00   00:00:00.000
        """

        let snapshots = QEMUEngine.parseSnapshotListHMP(text)
        XCTAssertEqual(snapshots.map(\.id), ["Before-update", "clean"])
        XCTAssertTrue(snapshots[0].includesMemory)
        XCTAssertFalse(snapshots[1].includesMemory)
    }

    func testParsesTableRowsWithSpacesInTheTag() {
        let text = """
        List of snapshots present on all disks:
        ID        TAG                     VM SIZE                DATE       VM CLOCK
        2         Before update install     1.5 GB 2026-10-19 12:00:00   00:00:02.500
        """

        let snapshots = QEMUEngine.parseSnapshotListHMP(text)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].id, "Before update install")
        XCTAssertTrue(snapshots[0].includesMemory)
    }

    func testParsesTimestampFromSnapshotTable() throws {
        let text = "1   baseline   64 MB 2026-01-02 03:04:05   00:00:00.500"
        let snapshot = try XCTUnwrap(QEMUEngine.parseSnapshotListHMP(text).first)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: snapshot.createdAt
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 2)
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 4)
        XCTAssertEqual(components.second, 5)
    }

    func testNoSnapshotsTextYieldsAnEmptyList() {
        XCTAssertTrue(QEMUEngine.parseSnapshotListHMP("There is no snapshot available.\n").isEmpty)
        XCTAssertTrue(QEMUEngine.parseSnapshotListHMP("").isEmpty)
        XCTAssertTrue(QEMUEngine.parseSnapshotListHMP("List of snapshots present on all disks:\n").isEmpty)
    }

    func testParsesPerDeviceSnapshotSection() {
        let text = """
        There is no snapshot available on all disks.
        Snapshot devices: ide0-hd0
        Snapshot list (from ide0-hd0):
        ID        TAG                     VM SIZE                DATE       VM CLOCK
        1         baseline                 64 MB 2026-01-02 03:04:05   00:00:00.500
        """

        let snapshots = QEMUEngine.parseSnapshotListHMP(text)
        XCTAssertEqual(snapshots.map(\.id), ["baseline"])
    }

    // MARK: - QMP `query-snapshots`

    func testParsesQMPQuerySnapshotsPayload() throws {
        let payload = QMPValue.array([
            .object([
                "name": .string("Before-update"),
                "date-sec": .int(1_766_000_000),
                "date-nsec": .int(500_000_000),
                "vm-state-size": .int(64 * 1024 * 1024),
            ]),
            .object([
                "tag": .string("clean"),
                "vm-state-size": .int(0),
            ]),
        ])

        let snapshots = try XCTUnwrap(QEMUEngine.parseSnapshotListQMP(payload))
        XCTAssertEqual(snapshots.map(\.id), ["Before-update", "clean"])
        XCTAssertEqual(snapshots[0].createdAt.timeIntervalSince1970, 1_766_000_000.5, accuracy: 0.001)
        XCTAssertTrue(snapshots[0].includesMemory)
        XCTAssertFalse(snapshots[1].includesMemory)
    }

    func testParsesNestedQMPPayload() throws {
        let payload = QMPValue.object([
            "snapshots": .array([
                .object(["id": .int(1), "vm-state-size": .int(1)]),
            ])
        ])

        let snapshots = try XCTUnwrap(QEMUEngine.parseSnapshotListQMP(payload))
        XCTAssertEqual(snapshots.map(\.id), ["1"])
        XCTAssertTrue(snapshots[0].includesMemory)
    }

    func testUnrecognisedQMPShapeReturnsNilSoCallerFallsBack() {
        XCTAssertNil(QEMUEngine.parseSnapshotListQMP(.object(["unexpected": .int(1)])))
        XCTAssertNil(QEMUEngine.parseSnapshotListQMP(.array([.object([:])])))
        XCTAssertNil(QEMUEngine.parseSnapshotListQMP(.string("not a list")))
    }

    func testEmptyQMPListIsRecognised() {
        let snapshots = QEMUEngine.parseSnapshotListQMP(.array([]))
        XCTAssertEqual(snapshots?.count, 0)
    }

    // MARK: - Errors

    func testRawDiskErrorNamesTheConvertCommand() {
        let description = QEMUEngine
            .snapshotUnsupportedError(diskPath: "/tmp/vm.macport/disk.img")
            .localizedDescription

        XCTAssertTrue(description.contains("macportctl disk convert"))
        XCTAssertTrue(description.contains("/tmp/vm.macport/disk.img"))
        XCTAssertTrue(description.contains("raw"))
    }

    func testQMPCommandFailureKeepsQEMUsOwnText() {
        let qmpError = QMPError.commandFailed(
            command: "human-monitor-command",
            errorClass: "GenericError",
            description: "Snapshot 'clean' does not exist"
        )
        let mapped = QEMUEngine.engineError(from: qmpError, operation: "Restore")
        XCTAssertEqual(
            mapped.localizedDescription,
            "Operation failed: Restore: Snapshot 'clean' does not exist"
        )
    }

    // MARK: - Optional integration: qemu-img

    /// Creates a tiny qcow2 with the installed `qemu-img` and proves the engine
    /// detects it. No VM is started and nothing is downloaded; when no QEMU
    /// runtime is present the test skips instead of failing.
    func testQemuImgCreatesADiskTheEngineRecognises() throws {
        guard let tool = QEMURuntime.locate(), let qemuImg = tool.imageBinary else {
            throw XCTSkip("No QEMU runtime with qemu-img is installed on this Mac.")
        }

        let bundle = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: bundle) }

        let disk = bundle.appendingPathComponent("disk.qcow2")
        let process = Process()
        process.executableURL = qemuImg
        process.arguments = ["create", "-f", "qcow2", disk.path, "67108864"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "qemu-img failed: \(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))"
        )
        let resolved = try XCTUnwrap(QEMUEngine.resolveDisk(in: bundle))
        XCTAssertEqual(resolved.url.lastPathComponent, "disk.qcow2")
        XCTAssertEqual(resolved.format, .qcow2)
    }

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryFile(contents: Data) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("disk.img")
        try contents.write(to: url)
        return url
    }
}
