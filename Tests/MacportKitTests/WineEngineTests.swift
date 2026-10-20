import XCTest
@testable import MacportKit

final class WineEngineTests: XCTestCase {

    func testWineEngineIdentifierAndDisplayName() {
        XCTAssertEqual(WineEngine.identifier, "wine")
        XCTAssertEqual(WineEngine.displayName, "Wine Translation Engine")
    }

    func testWineEngineCapabilitiesForWindowsApp() {
        let caps = WineEngine.capabilities(for: .windowsApp)
        XCTAssertEqual(caps.graphics, .acceleratedDX12)
        XCTAssertTrue(caps.sharedFolders)
        XCTAssertTrue(caps.foreignArchitectureEmulation)
        XCTAssertTrue(caps.backgroundHosting)
        XCTAssertFalse(caps.tpm)
        XCTAssertFalse(caps.opticalMedia)
        XCTAssertFalse(caps.nestedVirtualization)
    }

    func testWineEngineCapabilitiesForOtherGuestsIsNone() {
        let caps = WineEngine.capabilities(for: .linuxARM)
        XCTAssertEqual(caps.graphics, .none)
        XCTAssertFalse(caps.sharedFolders)
        XCTAssertFalse(caps.backgroundHosting)
    }

    func testGuestKindWindowsAppProperties() {
        let kind = GuestKind.windowsApp
        XCTAssertEqual(kind.displayName, "Windows App (Translation)")
        XCTAssertFalse(kind.requiresTPM)
        XCTAssertFalse(kind.requiresOpticalBootMedia)
        XCTAssertFalse(kind.usesIPSWInstall)
    }

    func testEngineRegistryIncludesWine() {
        XCTAssertTrue(EngineRegistry.all.contains(where: { $0.identifier == "wine" }))
        XCTAssertTrue(EngineRegistry.descriptors.contains(where: { $0.id == "wine" }))
        XCTAssertEqual(EngineRegistry.displayName(forIdentifier: "wine"), "Wine Translation Engine")
    }

    func testEngineRegistryRoutesWindowsAppToWineWhenAvailable() {
        guard EngineRegistry.isAvailable(WineEngine.self) else { return }
        XCTAssertTrue(EngineRegistry.preferredType(for: .windowsApp) == WineEngine.self)

        let config = VMConfiguration(
            name: "AppContainer",
            guest: .windowsApp,
            cpuCount: 2,
            memoryBytes: 2 * 1024 * 1024 * 1024,
            diskBytes: 0,
            network: .sharedNAT,
            sharedFolders: [],
            boot: .diskOnly
        )
        XCTAssertTrue(EngineRegistry.engineType(for: config) == WineEngine.self)
        XCTAssertNotNil(EngineRegistry.rationale(for: config))
    }

    func testWineRuntimeEnvironmentOverride() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create fake wineloader and wineserver
        let binDir = tempDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let loader = binDir.appendingPathComponent("wineloader")
        let server = binDir.appendingPathComponent("wineserver")
        try "#!/bin/sh\nexit 0".write(to: loader, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0".write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        let result = WineRuntime.resolve(environment: ["MACPORT_WINE_DIR": tempDir.path])
        switch result {
        case .success(let loc):
            XCTAssertEqual(loc.root.path, tempDir.path)
            XCTAssertEqual(loc.wineloader.path, loader.path)
            XCTAssertEqual(loc.wineserver.path, server.path)
        case .failure(let err):
            XCTFail("Expected success but got \(err)")
        }
    }

    @MainActor
    func testWineEngineRejectsUnsupportedGuests() async {
        let engine = WineEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = VMConfiguration(
            name: "BadGuest",
            guest: .linuxARM,
            cpuCount: 2,
            memoryBytes: 2 * 1024 * 1024 * 1024,
            diskBytes: 10 * 1024 * 1024 * 1024,
            network: .sharedNAT,
            sharedFolders: [],
            boot: .diskOnly
        )

        do {
            try await engine.create(config, in: tempDir)
            XCTFail("Expected create to throw unsupportedGuest error")
        } catch {
            // Success
        }
    }
}
