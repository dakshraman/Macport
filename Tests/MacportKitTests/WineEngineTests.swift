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

    func testWineBottleManagerBuiltInTools() {
        let tools = WineBottleManager.builtInTools
        XCTAssertEqual(tools.count, 6)
        XCTAssertTrue(tools.contains(where: { $0.executable == "winecfg" }))
        XCTAssertTrue(tools.contains(where: { $0.executable == "regedit" }))
        XCTAssertTrue(tools.contains(where: { $0.executable == "taskmgr" }))
        XCTAssertTrue(tools.contains(where: { $0.executable == "cmd.exe" }))
        XCTAssertTrue(tools.contains(where: { $0.executable == "explorer.exe" }))
        XCTAssertTrue(tools.contains(where: { $0.executable == "control.exe" }))
    }

    func testWineBottleManagerPathsAndInitialization() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottleURL = WineBottleManager.bottleURL(for: tempDir)
        let driveCURL = WineBottleManager.driveCURL(for: tempDir)

        XCTAssertEqual(bottleURL.path, tempDir.appendingPathComponent("bottle").path)
        XCTAssertEqual(driveCURL.path, tempDir.appendingPathComponent("bottle/drive_c").path)
        XCTAssertFalse(WineBottleManager.isBottleInitialized(in: tempDir))

        // Create fake drive_c
        try FileManager.default.createDirectory(at: driveCURL, withIntermediateDirectories: true)
        XCTAssertTrue(WineBottleManager.isBottleInitialized(in: tempDir))

        // Write a test file in drive_c and verify calculateBottleSize
        let testFile = driveCURL.appendingPathComponent("test.dat")
        let data = Data(repeating: 0x42, count: 2048)
        try data.write(to: testFile)

        let size = WineBottleManager.calculateBottleSize(in: tempDir)
        XCTAssertGreaterThanOrEqual(size, 2048)
    }

    func testWineBottleManagerShortcutScanning() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let programFiles = WineBottleManager.driveCURL(for: tempDir).appendingPathComponent("Program Files/Steam")
        try FileManager.default.createDirectory(at: programFiles, withIntermediateDirectories: true)

        let fakeSteam = programFiles.appendingPathComponent("steam.exe")
        try "fake binary".write(to: fakeSteam, atomically: true, encoding: .utf8)

        let shortcuts = WineBottleManager.scanInstalledShortcuts(in: tempDir)
        XCTAssertTrue(shortcuts.contains(where: { $0.name == "steam" }))
    }

    func testWineBottleManagerNestedGameScanning() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hoyoGames = WineBottleManager.driveCURL(for: tempDir).appendingPathComponent("Program Files/HoYoPlay/games/ZenlessZoneZero Game")
        try FileManager.default.createDirectory(at: hoyoGames, withIntermediateDirectories: true)

        let fakeZZZ = hoyoGames.appendingPathComponent("ZenlessZoneZero.exe")
        try "fake binary".write(to: fakeZZZ, atomically: true, encoding: .utf8)

        let shortcuts = WineBottleManager.scanInstalledShortcuts(in: tempDir)
        XCTAssertTrue(shortcuts.contains(where: { $0.name == "Zenless Zone Zero" && $0.executable.hasSuffix("ZenlessZoneZero.exe") }))
    }

    func testWineBottleSettingsDefaultsAndSerialization() throws {
        let settings = WineBottleSettings()
        XCTAssertEqual(settings.backend, .auto)
        XCTAssertTrue(settings.msyncEnabled)
        XCTAssertTrue(settings.metalFXEnabled)
        XCTAssertFalse(settings.hudEnabled)
        XCTAssertFalse(settings.retinaMode)

        let config = VMConfiguration(
            name: "GenshinImpact",
            guest: .windowsApp,
            wineSettings: settings
        )
        XCTAssertNotNil(config.wineSettings)
        XCTAssertEqual(config.wineSettings?.backend, .auto)
        XCTAssertTrue(config.wineSettings?.msyncEnabled == true)

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: encoded)
        XCTAssertEqual(decoded.wineSettings?.backend, .auto)
        XCTAssertEqual(decoded.wineSettings?.msyncEnabled, true)
        XCTAssertEqual(decoded.wineSettings?.metalFXEnabled, true)
        XCTAssertEqual(decoded.wineSettings?.bottleTemplate, "win11_64")
    }

    func testCrossOverConfigGeneration() {
        let conf = WineBottleManager.generateCrossOverConfig(
            template: "win11_64",
            wineSettings: WineBottleSettings(backend: .d3dmetal, msyncEnabled: true, metalFXEnabled: true, hudEnabled: true)
        )
        XCTAssertTrue(conf.contains("\"Template\" = \"win11_64\""))
        XCTAssertTrue(conf.contains("\"CX_GRAPHICS_BACKEND\" = \"d3dmetal\""))
        XCTAssertTrue(conf.contains("\"WINEMSYNC\" = \"1\""))
        XCTAssertTrue(conf.contains("\"D3DM_ENABLE_METALFX\" = \"1\""))
        XCTAssertTrue(conf.contains("\"MTL_HUD_ENABLED\" = \"1\""))
        XCTAssertTrue(conf.contains("WINE_WAIT_CHILD_PIPE_IGNORE"))
    }

    func testExistingCrossOverBottlesDiscovery() {
        let bottles = WineRuntime.existingCrossOverBottles()
        // If CrossOver is installed, it should find Genshin bottle
        if FileManager.default.fileExists(atPath: WineRuntime.crossoverBottlesDirectory.path) {
            XCTAssertFalse(bottles.isEmpty)
            XCTAssertTrue(bottles.contains(where: { $0.name == "Genshin" }))
        }
    }

    func testGraphicsBackendDisplayNames() {
        XCTAssertEqual(GraphicsBackend.auto.displayName, "Auto (Recommended)")
        XCTAssertEqual(GraphicsBackend.d3dmetal.displayName, "D3DMetal (Apple GPTK)")
        XCTAssertEqual(GraphicsBackend.dxmt.displayName, "DXMT (Direct3D 11 to Metal)")
        XCTAssertEqual(GraphicsBackend.dxvk.displayName, "DXVK (Direct3D to Vulkan)")
        XCTAssertEqual(GraphicsBackend.wined3d.displayName, "WineD3D (OpenGL Fallback)")
    }

    func testWineRuntimeD3DMetalDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let binDir = tempDir.appendingPathComponent("bin")
        let gptkDir = tempDir.appendingPathComponent("lib64/apple_gptk/external")
        let d3dmetalFwk = gptkDir.appendingPathComponent("D3DMetal.framework")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d3dmetalFwk, withIntermediateDirectories: true)

        let loader = binDir.appendingPathComponent("wineloader")
        let server = binDir.appendingPathComponent("wineserver")
        let shared = gptkDir.appendingPathComponent("libd3dshared.dylib")
        try "#!/bin/sh\nexit 0".write(to: loader, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0".write(to: server, atomically: true, encoding: .utf8)
        try "fake lib".write(to: shared, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        let result = WineRuntime.resolve(environment: ["MACPORT_WINE_DIR": tempDir.path])
        switch result {
        case .success(let loc):
            XCTAssertTrue(loc.hasD3DMetal)
            XCTAssertTrue(loc.hasMetalAcceleration)
            XCTAssertNotNil(loc.d3dsharedPath)
            XCTAssertNotNil(loc.d3dmetalFrameworkPath)
        case .failure(let err):
            XCTFail("Expected success but got \(err)")
        }
    }

    func testParseCommandAndArguments() {
        let (e1, a1) = WineBottleManager.parseCommandAndArguments("C:\\Program Files\\HoYoPlay\\launcher.exe --uninstall_game=nap_global")
        XCTAssertEqual(e1, "C:\\Program Files\\HoYoPlay\\launcher.exe")
        XCTAssertEqual(a1, ["--uninstall_game=nap_global"])

        let (e2, a2) = WineBottleManager.parseCommandAndArguments("\"C:\\Program Files\\Test\\unins000.exe\" /SILENT /NORESTART")
        XCTAssertEqual(e2, "C:\\Program Files\\Test\\unins000.exe")
        XCTAssertEqual(a2, ["/SILENT", "/NORESTART"])

        let (e3, a3) = WineBottleManager.parseCommandAndArguments("str(2):\"MsiExec.exe /I{0591009C-75D7-5F33-B5DF-4F47111155EC}\"")
        XCTAssertEqual(e3, "MsiExec.exe")
        XCTAssertEqual(a3, ["/I{0591009C-75D7-5F33-B5DF-4F47111155EC}"])

        let (e4, a4) = WineBottleManager.parseCommandAndArguments("uninstaller.exe")
        XCTAssertEqual(e4, "uninstaller.exe")
        XCTAssertEqual(a4, [])
    }

    @MainActor
    func testVMStoreRename() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = VMStore(root: tempRoot)
        let config = VMConfiguration(
            name: "Initial Bottle",
            guest: .windowsApp,
            cpuCount: 4,
            memoryBytes: 4 * 1024 * 1024 * 1024,
            diskBytes: 0,
            network: .sharedNAT,
            sharedFolders: [],
            boot: .diskOnly
        )
        try store.save(config)

        let renamed = try store.rename(config, to: "Renamed Bottle")
        XCTAssertEqual(renamed.name, "Renamed Bottle")
        XCTAssertEqual(store.machines.first?.name, "Renamed Bottle")

        // Reload from disk to verify persistence
        let store2 = VMStore(root: tempRoot)
        store2.load()
        XCTAssertEqual(store2.machines.first?.name, "Renamed Bottle")
    }
}
