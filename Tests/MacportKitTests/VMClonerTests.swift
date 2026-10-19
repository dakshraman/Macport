import XCTest
import MacportKit

@MainActor
final class VMClonerTests: XCTestCase {

    private func makeStore() throws -> (store: VMStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-clone-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (VMStore(root: root), root)
    }

    private func makeConfig(name: String = "Original") -> VMConfiguration {
        VMConfiguration(
            name: name,
            guest: .linuxARM,
            cpuCount: 2,
            memoryBytes: 2 * 1024 * 1024 * 1024,
            diskBytes: 16 * 1024 * 1024 * 1024
        )
    }

    func testCloneCopiesBundleAndAssignsNewIdentity() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try store.save(makeConfig())
        let bundle = store.bundleURL(for: original)
        let fileManager = FileManager.default

        try Data("disk".utf8).write(to: bundle.appendingPathComponent("disk.img"))
        try fileManager.createDirectory(
            at: bundle.appendingPathComponent("Snapshots", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("runtime.json"))
        try Data("lock".utf8).write(to: bundle.appendingPathComponent(".lock"))
        try Data([0x01]).write(to: bundle.appendingPathComponent("machine-id.bin"))

        let clone = try VMCloner.clone(original, in: store, named: "Clone")

        XCTAssertNotEqual(clone.id, original.id)
        XCTAssertEqual(clone.name, "Clone")
        XCTAssertEqual(clone.guest, original.guest)
        XCTAssertEqual(clone.diskBytes, original.diskBytes)

        let cloneBundle = store.bundleURL(for: clone)
        XCTAssertTrue(fileManager.fileExists(atPath: cloneBundle.appendingPathComponent("disk.img").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: cloneBundle.appendingPathComponent("Snapshots").path
        ), "Snapshots belong to the machine and must come with the clone.")
        XCTAssertFalse(fileManager.fileExists(
            atPath: cloneBundle.appendingPathComponent("runtime.json").path
        ), "A clone must not inherit the original's process state.")
        XCTAssertFalse(fileManager.fileExists(
            atPath: cloneBundle.appendingPathComponent(".lock").path
        ), "A clone must not look locked before it has ever run.")
        XCTAssertFalse(fileManager.fileExists(
            atPath: cloneBundle.appendingPathComponent("machine-id.bin").path
        ), "VZ regenerates the platform identifier so the clone is a distinct machine.")

        let configData = try Data(contentsOf: store.configURL(for: clone))
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: configData)
        XCTAssertEqual(decoded, clone)
        XCTAssertTrue(store.machines.contains { $0.id == clone.id })
        XCTAssertEqual(store.machines.count, 2)
    }

    func testDefaultCloneNameIsACopyName() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try store.save(makeConfig(name: "Ubuntu"))
        let clone = try VMCloner.clone(original, in: store)
        XCTAssertEqual(clone.name, "Ubuntu Copy")
    }

    func testCloneOfMissingBundleThrows() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let orphan = makeConfig(name: "Orphan")
        XCTAssertThrowsError(try VMCloner.clone(orphan, in: store)) { error in
            guard case VMClonerError.sourceMissing = error else {
                return XCTFail("Expected sourceMissing, got \(error)")
            }
        }
    }

    func testCloneOfEmptyNameDoesNotProduceWhitespaceName() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = try store.save(makeConfig(name: "Linux"))
        let clone = try VMCloner.clone(original, in: store, named: "   ")
        XCTAssertEqual(clone.name, "Linux Copy")
    }
}
