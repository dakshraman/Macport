import XCTest
import MacportKit

/// Admission control has to be testable with numbers a test can dictate, because
/// the rules are the product decision — "the host does not oversubscribe itself"
/// — and the machine running the suite is an implementation detail.
final class AdmissionControlTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024

    // MARK: - Fixtures

    private func capacity(
        memoryGB: UInt64 = 16,
        cpus: Int = 10,
        freeDiskGB: UInt64? = 200
    ) -> HostCapacity {
        HostCapacity(
            physicalMemory: memoryGB * gib,
            processorCount: cpus,
            freeDiskBytes: freeDiskGB.map { $0 * gib }
        )
    }

    private func config(
        name: String = "VM",
        memoryGB: UInt64 = 4,
        cpus: Int = 4,
        diskGB: UInt64 = 64
    ) -> VMConfiguration {
        VMConfiguration(
            name: name,
            guest: .linuxARM,
            cpuCount: cpus,
            memoryBytes: memoryGB * gib,
            diskBytes: diskGB * gib
        )
    }

    private func failure(
        _ result: Result<Void, EngineError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EngineError? {
        switch result {
        case .success:
            XCTFail("Expected admission to be refused", file: file, line: line)
            return nil
        case .failure(let error):
            return error
        }
    }

    // MARK: - Admission

    func testSingleVMWithinCapacityIsAdmitted() {
        let result = AdmissionControl.check(
            config(memoryGB: 4, cpus: 4),
            running: [],
            capacity: capacity()
        )
        XCTAssertNoThrow(try result.get())
    }

    func testTwoVMsWithinCapacityAreAdmitted() {
        let running = [config(name: "A", memoryGB: 4, cpus: 4)]
        let result = AdmissionControl.check(
            config(name: "B", memoryGB: 4, cpus: 4),
            running: running,
            capacity: capacity()
        )
        XCTAssertNoThrow(try result.get())
    }

    // MARK: - Memory

    func testMemoryOvercommitIsRefusedWithNumbers() {
        // 16 GB host: 2 GB reserved, 14 GB usable. 8 + 8 = 16 > 14.
        let error = failure(
            AdmissionControl.check(
                config(name: "B", memoryGB: 8),
                running: [config(name: "A", memoryGB: 8)],
                capacity: capacity(memoryGB: 16)
            )
        )

        guard case .hostResourceUnavailable(let detail)? = error else {
            return XCTFail("Expected a hostResourceUnavailable error, got \(String(describing: error))")
        }
        // The message must let the user act: the total, the limit and the reserve.
        XCTAssertTrue(detail.contains("16 GB"), detail)
        XCTAssertTrue(detail.contains("2 GB"), detail)
        XCTAssertTrue(detail.contains("14 GB"), detail)
        XCTAssertTrue(detail.contains("total of 16 GB"), detail)
    }

    func testReserveScalesWithHostMemory() {
        // A 64 GB host reserves max(2 GB, 8 GB) = 8 GB, leaving 56 GB usable.
        // 30 + 30 = 60 GB must therefore be refused.
        let error = failure(
            AdmissionControl.check(
                config(name: "B", memoryGB: 30),
                running: [config(name: "A", memoryGB: 30)],
                capacity: capacity(memoryGB: 64)
            )
        )

        guard case .hostResourceUnavailable(let detail)? = error else {
            return XCTFail("Expected a hostResourceUnavailable error, got \(String(describing: error))")
        }
        XCTAssertTrue(detail.contains("8 GB"), detail)
        XCTAssertTrue(detail.contains("56 GB"), detail)
    }

    func testMemoryThatFitsTheReserveExactlyIsAdmitted() {
        // 16 GB host, 2 GB reserve: 14 GB usable, exactly.
        let result = AdmissionControl.check(
            config(memoryGB: 14),
            running: [],
            capacity: capacity(memoryGB: 16)
        )
        XCTAssertNoThrow(try result.get())
    }

    // MARK: - Processors

    func testCPUOvercommitIsRefusedWithNumbers() {
        // 10 hosts cores, one kept for macOS: 9 usable. 6 + 4 > 9.
        let error = failure(
            AdmissionControl.check(
                config(name: "B", cpus: 4),
                running: [config(name: "A", cpus: 6)],
                capacity: capacity(cpus: 10)
            )
        )

        guard case .hostResourceUnavailable(let detail)? = error else {
            return XCTFail("Expected a hostResourceUnavailable error, got \(String(describing: error))")
        }
        XCTAssertTrue(detail.contains("10 processors"), detail)
        XCTAssertTrue(detail.contains("leaving 9"), detail)
        XCTAssertTrue(detail.contains("total of 10"), detail)
    }

    func testCPUsThatLeaveOneHostCoreAreAdmitted() {
        let result = AdmissionControl.check(
            config(cpus: 5),
            running: [config(cpus: 4)],
            capacity: capacity(cpus: 10)
        )
        XCTAssertNoThrow(try result.get())
    }

    func testSingleVMRequestingAllUsableHostCPUsIsAdmitted() {
        // A 6-core host leaves 5 for guests. A single VM asking for 5 cpus with 0 running VMs must be admitted.
        let result = AdmissionControl.check(
            config(cpus: 5),
            running: [],
            capacity: capacity(cpus: 6)
        )
        XCTAssertNoThrow(try result.get())
    }


    // MARK: - Disk

    func testDiskFloorIsRefusedWithNumbers() {
        // 64 GB sparse disk: floor = 2 GB + 5% = 5.2 GB. 5 GB free is not enough.
        let error = failure(
            AdmissionControl.check(
                config(diskGB: 64),
                running: [],
                capacity: capacity(freeDiskGB: 5)
            )
        )

        guard case .hostResourceUnavailable(let detail)? = error else {
            return XCTFail("Expected a hostResourceUnavailable error, got \(String(describing: error))")
        }
        XCTAssertTrue(detail.contains("5 GB free"), detail)
        XCTAssertTrue(detail.contains("safety floor"), detail)
        XCTAssertTrue(detail.contains("64 GB"), detail)
    }

    func testDiskFloorIsAdmittedWhenThereIsHeadroom() {
        // 2 GB + 5% of 64 GB = 5.2 GB; 10 GB free passes.
        let result = AdmissionControl.check(
            config(diskGB: 64),
            running: [],
            capacity: capacity(freeDiskGB: 10)
        )
        XCTAssertNoThrow(try result.get())
    }

    func testUnknownFreeSpaceSkipsTheDiskCheck() {
        // No honest free-space figure: refuse everything would be worse than
        // letting the engine report a real write failure.
        let result = AdmissionControl.check(
            config(diskGB: 1024),
            running: [],
            capacity: capacity(freeDiskGB: nil)
        )
        XCTAssertNoThrow(try result.get())
    }

    // MARK: - Host capacity plumbing

    func testCurrentCapacityReportsTheRealHost() {
        let current = HostCapacity.current
        XCTAssertEqual(current.physicalMemory, ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(current.processorCount, ProcessInfo.processInfo.activeProcessorCount)
    }

    func testCapacityProbeFallsBackToAnExistingAncestor() {
        // The VM root may not exist yet on first launch; the probe must walk up
        // rather than report "unknown" and skip the disk check forever.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-does-not-exist-\(UUID().uuidString)")
        XCTAssertNotNil(HostCapacity.current(freeDiskAt: missing).freeDiskBytes)
    }
}
