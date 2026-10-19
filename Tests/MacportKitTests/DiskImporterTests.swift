import XCTest
import MacportKit

final class DiskImporterTests: XCTestCase {

    func testSupportedExtensionsAreHonest() {
        XCTAssertTrue(DiskImporter.isSupported(URL(fileURLWithPath: "/tmp/disk.vmdk")))
        XCTAssertTrue(DiskImporter.isSupported(URL(fileURLWithPath: "/tmp/disk.QCOW2")))
        XCTAssertTrue(DiskImporter.isSupported(URL(fileURLWithPath: "/tmp/appliance.ova")))
        XCTAssertFalse(DiskImporter.isSupported(URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    func testInspectMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).qcow2")
        XCTAssertThrowsError(try DiskImporter.inspect(missing)) { error in
            guard case DiskImporterError.sourceMissing = error else {
                return XCTFail("Expected sourceMissing, got \(error)")
            }
        }
    }

    func testInspectAndConvertRoundTrip() throws {
        guard let imageTool = QEMURuntime.locate()?.imageBinary else {
            throw XCTSkip("Managed QEMU runtime is not installed; qemu-img is required.")
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let qcow = directory.appendingPathComponent("disk.qcow2")
        try runTool(imageTool, ["create", "-f", "qcow2", qcow.path, "8M"])

        let original = try DiskImporter.inspect(qcow)
        XCTAssertEqual(original.format, "qcow2")
        XCTAssertEqual(original.virtualSize, 8 * 1024 * 1024)

        let raw = directory.appendingPathComponent("disk.raw")
        let converted = try DiskImporter.convert(qcow, to: raw, format: .raw)
        XCTAssertEqual(converted.format, "raw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertEqual(converted.virtualSize, 8 * 1024 * 1024)
    }

    func testFailedConversionLeavesNoPartialDisk() throws {
        guard QEMURuntime.locate()?.imageBinary != nil else {
            throw XCTSkip("Managed QEMU runtime is not installed; qemu-img is required.")
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notADisk = directory.appendingPathComponent("garbage.vmdk", isDirectory: true)
        try FileManager.default.createDirectory(at: notADisk, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("converted.qcow2")

        XCTAssertThrowsError(try DiskImporter.convert(notADisk, to: destination, format: .qcow2))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "A failed import must not leave a destination that looks finished."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path),
            "The staged partial file must be cleaned up."
        )
    }

    func testUnpackOVAFindsTheDiskMember() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("not a real vmdk".utf8).write(to: source.appendingPathComponent("disk.vmdk"))
        try Data("<ovf/>".utf8).write(to: source.appendingPathComponent("machine.ovf"))

        let ova = directory.appendingPathComponent("appliance.ova")
        try runTool(URL(fileURLWithPath: "/usr/bin/tar"),
                    ["-cf", ova.path, "-C", source.path, "machine.ovf", "disk.vmdk"])

        let unpacked = try DiskImporter.unpackOVA(ova)
        defer { try? FileManager.default.removeItem(at: unpacked.directory) }
        XCTAssertEqual(unpacked.disk.lastPathComponent, "disk.vmdk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.disk.path))
    }

    private func runTool(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable.lastPathComponent) \(arguments) failed")
    }
}
