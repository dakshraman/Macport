import XCTest
import MacportKit

/// Baseline tests for the shared model.
///
/// They deliberately avoid booting anything: this file covers the pieces both the
/// app and the CLI depend on — engine routing, the capability contract and the
/// on-disk configuration format. Engine-specific behaviour is tested beside the
/// workstream that implements it (`docs/REFACTOR-PLAN.md` §5).
final class ModelSmokeTests: XCTestCase {

    private func makeConfig(
        guest: GuestKind,
        engineIdentifier: String? = nil,
        name: String = "Test"
    ) -> VMConfiguration {
        VMConfiguration(
            name: name,
            guest: guest,
            cpuCount: 2,
            memoryBytes: 2 * 1024 * 1024 * 1024,
            diskBytes: 16 * 1024 * 1024 * 1024,
            network: .sharedNAT,
            sharedFolders: [],
            boot: .diskOnly,
            tpmEnabled: guest.requiresTPM,
            engineIdentifier: engineIdentifier
        )
    }

    // MARK: - Engine routing

    func testExplicitEnginePinWins() {
        let pinnedToQEMU = makeConfig(guest: .linuxARM, engineIdentifier: QEMUEngine.identifier)
        XCTAssertTrue(EngineRegistry.engineType(for: pinnedToQEMU) == QEMUEngine.self)

        let pinnedToVZ = makeConfig(guest: .windowsARM, engineIdentifier: VZEngine.identifier)
        XCTAssertTrue(EngineRegistry.engineType(for: pinnedToVZ) == VZEngine.self)
    }

    func testUnknownEnginePinFallsBackToGuestPolicy() {
        // A stale identifier from an older config must not crash and must not
        // return nil-ish behaviour: the guest's requirements decide again.
        let config = makeConfig(guest: .linuxARM, engineIdentifier: "does-not-exist")
        XCTAssertTrue(
            EngineRegistry.engineType(for: config)
                == EngineRegistry.preferredType(for: .linuxARM)
        )
    }

    func testWindowsPrefersAnEngineWithOpticalMedia() throws {
        try XCTSkipUnless(
            EngineRegistry.isAvailable(QEMUEngine.self),
            "QEMU runtime not present; routing falls back by design"
        )
        XCTAssertTrue(EngineRegistry.preferredType(for: .windowsARM) == QEMUEngine.self)
        XCTAssertNotNil(EngineRegistry.rationale(for: makeConfig(guest: .windowsARM)))
    }

    func testLinuxPrefersVirtualizationFramework() throws {
        try XCTSkipUnless(
            EngineRegistry.isAvailable(VZEngine.self),
            "No hypervisor on this host"
        )
        XCTAssertTrue(EngineRegistry.preferredType(for: .linuxARM) == VZEngine.self)
    }

    // MARK: - Capability contract

    func testOpticalMediaIsTruthful() {
        // This single flag is why Windows routes away from VZ. If it ever flips
        // without the device existing, the routing logic starts lying.
        XCTAssertTrue(QEMUEngine.capabilities(for: .windowsARM).opticalMedia)
        XCTAssertFalse(VZEngine.capabilities(for: .windowsARM).opticalMedia)
    }

    func testDescriptorListCoversShippedEngines() {
        let ids = Set(EngineRegistry.descriptors.map(\.id))
        XCTAssertTrue(ids.contains(VZEngine.identifier))
        XCTAssertTrue(ids.contains(QEMUEngine.identifier))
    }

    // MARK: - Model

    func testWindowsRequiresTPMAndOpticalBoot() {
        XCTAssertTrue(GuestKind.windowsARM.requiresTPM)
        XCTAssertTrue(GuestKind.windowsARM.requiresOpticalBootMedia)
        XCTAssertFalse(GuestKind.linuxARM.requiresTPM)
        XCTAssertFalse(GuestKind.linuxARM.requiresOpticalBootMedia)
    }

    func testConfigurationRoundTripsThroughJSON() throws {
        let original = makeConfig(
            guest: .linuxARM,
            engineIdentifier: QEMUEngine.identifier,
            name: "Round Trip"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testGigabyteFormatting() {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        XCTAssertEqual(eightGB.gbString, "8 GB")

        let oneAndAHalfGB: UInt64 = 1024 * 1024 * 1024 + 512 * 1024 * 1024
        XCTAssertEqual(oneAndAHalfGB.gbString, "1.5 GB")
    }
}
