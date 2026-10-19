import XCTest
@testable import MacportKit

final class QEMUToolsMediaTests: XCTestCase {

    func testMissingDestinationNeedsABuild() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("virtio-win.iso")
        try Data("source".utf8).write(to: source)

        XCTAssertTrue(
            QEMUEngine.toolsMediaNeedsBuild(
                at: directory.appendingPathComponent("tools-media.iso"),
                source: source
            )
        )
    }

    func testDestinationOlderThanSourceNeedsABuild() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("virtio-win.iso")
        let destination = directory.appendingPathComponent("tools-media.iso")
        try Data("source".utf8).write(to: source)
        try Data("media".utf8).write(to: destination)

        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: destination.path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: source.path)

        XCTAssertTrue(QEMUEngine.toolsMediaNeedsBuild(at: destination, source: source))
    }

    func testDestinationNewerThanSourceIsReused() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("virtio-win.iso")
        let destination = directory.appendingPathComponent("tools-media.iso")
        try Data("source".utf8).write(to: source)
        try Data("media".utf8).write(to: destination)

        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: destination.path)

        XCTAssertFalse(QEMUEngine.toolsMediaNeedsBuild(at: destination, source: source))
    }

    func testEmptyDestinationIsRebuilt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("virtio-win.iso")
        let destination = directory.appendingPathComponent("tools-media.iso")
        try Data("source".utf8).write(to: source)
        try Data().write(to: destination)

        XCTAssertTrue(QEMUEngine.toolsMediaNeedsBuild(at: destination, source: source))
    }
}
