import Foundation
import XCTest
import MacportKit

/// Macport Tools is the one place Macport touches the user's mounted volumes, so the
/// tests here are as interested in what it refuses to do — detach something it did not
/// attach, use an ISO that is not there — as in what it builds.
final class MacportToolsTests: XCTestCase {

    // MARK: - Resolution

    func testResolutionPrefersTheEnvironmentOverride() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let override = directory.appendingPathComponent("override.iso")
        let cached = directory.appendingPathComponent("cache.iso")
        try writeContents("x", at: override)
        try writeContents("x", at: cached)

        let resolved = MacportTools.resolve(
            environment: [MacportTools.environmentOverride: override.path],
            cachedISO: cached
        )
        XCTAssertEqual(resolved, override)
    }

    func testResolutionFallsBackToTheCachedISOCheckedByMacport() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cached = directory.appendingPathComponent("cache.iso")
        try writeContents("x", at: cached)

        let resolved = MacportTools.resolve(environment: [:], cachedISO: cached)
        XCTAssertEqual(resolved, cached)
    }

    func testResolutionSkipsAnOverrideThatDoesNotExist() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cached = directory.appendingPathComponent("cache.iso")
        try writeContents("x", at: cached)

        let resolved = MacportTools.resolve(
            environment: [MacportTools.environmentOverride: directory.appendingPathComponent("gone.iso").path],
            cachedISO: cached
        )
        XCTAssertEqual(resolved, cached, "A stale override must not hide a usable cached ISO.")
    }

    func testResolutionReportsNothingWhenThereIsNoISO() {
        XCTAssertNil(MacportTools.resolve(environment: [:], cachedISO: nil))
    }

    func testThePinnedReleaseIsTheOneTheURLNames() {
        XCTAssertTrue(MacportTools.downloadURL.absoluteString.contains(MacportTools.version))
        XCTAssertTrue(MacportTools.downloadURL.absoluteString.hasSuffix("virtio-win-\(MacportTools.version).iso"))
        XCTAssertGreaterThanOrEqual(MacportTools.minimumDownloadBytes, 500 * 1_024 * 1_024)
    }

    func testTheMissingISOErrorIsActionable() {
        let error = MacportToolsError.isoNotAvailable(cachedISO: MacportTools.cachedISOURL)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains(MacportTools.environmentOverride))
        XCTAssertTrue(message.contains(MacportTools.cachedISOURL.path))
        XCTAssertTrue(message.contains(MacportTools.downloadURL.absoluteString))
    }

    // MARK: - Staging without hdiutil

    func testStageDriverTreesCopiesOnlyArm64Trees() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source", isDirectory: true)
        let staging = directory.appendingPathComponent("staging", isDirectory: true)

        // The newest Windows must win when a release carries several ARM64 trees.
        try write("NetKVM/w11/ARM64/netkvm.inf", "w11", in: source)
        try write("NetKVM/w11/ARM64/netkvm.sys", "w11 sys", in: source)
        try write("NetKVM/w11/ARM64/netkvm.cat", "w11 cat", in: source)
        try write("NetKVM/w11/ARM64/support/netkvmco.dll", "w11 dll", in: source)
        try write("NetKVM/w10/ARM64/netkvm.inf", "w10", in: source)
        try write("NetKVM/w11/amd64/netkvm.inf", "amd64", in: source)

        // The two layouts the pinned ISO is known to use, plus the aliases.
        try write("viostor/arm64/viostor.inf", "direct", in: source)
        try write("Balloon/ARM64/balloon.inf", "shouty", in: source)
        try write("vioscsi/w11/amd64/vioscsi.sys", "wrong architecture", in: source)
        try write("vioserial/w11/ARM64/vioser.inf", "alias", in: source)
        try write("viogpu/arm64/viogpudo.inf", "gpu alias", in: source)

        let report = try MacportTools.stageDriverTrees(from: source, into: staging)

        XCTAssertEqual(report.names, ["NetKVM", "viostor", "Balloon", "vioser", "viogpudo"])
        XCTAssertEqual(report.missing, ["vioscsi", "viofs"])

        let drivers = staging.appendingPathComponent("drivers", isDirectory: true)
        XCTAssertEqual(try text(of: drivers.appendingPathComponent("NetKVM/arm64/netkvm.inf")), "w11")
        XCTAssertTrue(exists(drivers.appendingPathComponent("NetKVM/arm64/netkvm.sys")))
        XCTAssertTrue(exists(drivers.appendingPathComponent("NetKVM/arm64/netkvm.cat")))
        XCTAssertTrue(exists(drivers.appendingPathComponent("NetKVM/arm64/support/netkvmco.dll")))
        XCTAssertFalse(exists(drivers.appendingPathComponent("NetKVM/arm64/w10")),
                       "The older Windows tree must not be merged into the media.")
        XCTAssertTrue(exists(drivers.appendingPathComponent("viostor/arm64/viostor.inf")))
        XCTAssertTrue(exists(drivers.appendingPathComponent("Balloon/arm64/balloon.inf")))
        XCTAssertTrue(exists(drivers.appendingPathComponent("vioser/arm64/vioser.inf")))
        XCTAssertTrue(exists(drivers.appendingPathComponent("viogpudo/arm64/viogpudo.inf")))

        let netKVM = try XCTUnwrap(report.staged.first { $0.name == "NetKVM" })
        XCTAssertEqual(netKVM.fileCount, 4)
        XCTAssertEqual(netKVM.directory.lastPathComponent, "arm64")
    }

    func testStageDriverTreesTreatsAnEmptyArm64DirectoryAsMissing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source", isDirectory: true)
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("NetKVM/arm64"),
            withIntermediateDirectories: true
        )

        let report = try MacportTools.stageDriverTrees(
            from: source,
            into: staging,
            drivers: ["NetKVM"]
        )
        XCTAssertTrue(report.staged.isEmpty)
        XCTAssertEqual(report.missing, ["NetKVM"])
        XCTAssertFalse(exists(staging.appendingPathComponent("drivers/NetKVM/arm64")))
    }

    func testStageDriverTreesOnAnEmptySourceReportsEveryDriverMissing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source", isDirectory: true)
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let report = try MacportTools.stageDriverTrees(from: source, into: staging)
        XCTAssertTrue(report.staged.isEmpty)
        XCTAssertEqual(report.missing, MacportTools.driverNames)
    }

    // MARK: - Driver paths

    func testDriverPathsUseTheRequestedDriveLetter() throws {
        XCTAssertEqual(
            try MacportTools.driverPaths(for: ["NetKVM", "viostor"], driveLetter: "E:"),
            ["E:\\drivers\\NetKVM\\arm64", "E:\\drivers\\viostor\\arm64"]
        )
        XCTAssertEqual(
            try MacportTools.driverPaths(for: ["NetKVM"], driveLetter: "f"),
            ["F:\\drivers\\NetKVM\\arm64"]
        )
        XCTAssertEqual(
            try MacportTools.driverPaths(for: ["NetKVM"], driveLetter: "d:"),
            ["D:\\drivers\\NetKVM\\arm64"]
        )
    }

    func testDriverPathsRejectSomethingThatIsNotADriveLetter() {
        for bad in ["", "EE", "1", "E::"] {
            XCTAssertThrowsError(try MacportTools.driverPaths(for: ["NetKVM"], driveLetter: bad), "\"\(bad)\"")
        }
    }

    // MARK: - Building and mounting (needs hdiutil)

    func testBuildMediaWithAnswerFileOnly() throws {
        try requireHDIUtil()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let media = directory.appendingPathComponent("answer-only.iso")
        try MacportTools.buildMedia(
            to: media,
            answerFile: try UnattendMedia.answerFileXML(driverPaths: ["E:\\drivers\\NetKVM\\arm64"])
        )
        XCTAssertTrue(exists(media))

        try MacportTools.withMountedImage(at: media) { root in
            XCTAssertTrue(exists(root.appendingPathComponent("autounattend.xml")))
            XCTAssertTrue(isDirectory(root.appendingPathComponent("drivers")))
            XCTAssertTrue(try text(of: root.appendingPathComponent("autounattend.xml"))
                .contains("BypassTPMCheck"))
        }
        XCTAssertFalse(try isAttached(image: media), "The media must not stay mounted.")
    }

    func testBuildMediaFromAPreparedStagingDirectory() throws {
        try requireHDIUtil()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try write("autounattend.xml", "<unattend/>", in: staging)
        try write("drivers/NetKVM/arm64/netkvm.inf", "driver", in: staging)

        let media = directory.appendingPathComponent("tools.iso")
        try MacportTools.buildMedia(to: media, staging: staging)

        try MacportTools.withMountedImage(at: media) { root in
            XCTAssertEqual(
                try text(of: root.appendingPathComponent("autounattend.xml")),
                "<unattend/>"
            )
            XCTAssertEqual(
                try text(of: root.appendingPathComponent("drivers/NetKVM/arm64/netkvm.inf")),
                "driver"
            )
        }
        XCTAssertFalse(try isAttached(image: media))
    }

    func testMountDetachesWhenTheBodyThrows() throws {
        try requireHDIUtil()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try write("autounattend.xml", "<unattend/>", in: staging)
        let media = directory.appendingPathComponent("tools.iso")
        try MacportTools.buildMedia(to: media, staging: staging)

        struct BodyFailed: Error {}
        XCTAssertThrowsError(
            try MacportTools.withMountedImage(at: media) { _ in throw BodyFailed() }
        )
        XCTAssertFalse(try isAttached(image: media), "A failed body must still detach its mountpoint.")
    }

    func testMountRefusesAnImageThatIsNotThere() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("macport-tools-missing-\(UUID().uuidString).iso")
        XCTAssertThrowsError(try MacportTools.withMountedImage(at: missing) { _ in }) { error in
            guard case .imageNotFound(let url)? = error as? MacportToolsError else {
                return XCTFail("Expected imageNotFound, got \(error).")
            }
            XCTAssertEqual(url, missing)
        }
    }

    // MARK: - The whole pipeline

    func testPrepareMediaStagesDriversFromASyntheticISOAndNamesThemInTheAnswerFile() throws {
        try requireHDIUtil()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A stand-in for the virtio-win ISO: same layout, none of the bytes.
        let sourceStaging = directory.appendingPathComponent("source", isDirectory: true)
        try write("NetKVM/w11/ARM64/netkvm.inf", "netkvm", in: sourceStaging)
        try write("NetKVM/w11/ARM64/netkvm.sys", "netkvm sys", in: sourceStaging)
        try write("viostor/w11/ARM64/viostor.inf", "viostor", in: sourceStaging)
        try write("NetKVM/w11/amd64/netkvm.inf", "amd64", in: sourceStaging)

        let sourceISO = directory.appendingPathComponent("virtio-win-synthetic.iso")
        try MacportTools.buildMedia(to: sourceISO, staging: sourceStaging)

        let media = directory.appendingPathComponent("macport-tools.iso")
        try MacportTools.prepareMedia(for: .windowsARM, at: media, iso: sourceISO)
        XCTAssertTrue(exists(media))

        try MacportTools.withMountedImage(at: media) { root in
            let answer = try text(of: root.appendingPathComponent("autounattend.xml"))
            XCTAssertTrue(answer.contains("BypassTPMCheck"))
            XCTAssertTrue(answer.contains("<Path>E:\\drivers\\NetKVM\\arm64</Path>"))
            XCTAssertTrue(answer.contains("<Path>E:\\drivers\\viostor\\arm64</Path>"))
            XCTAssertFalse(answer.contains("amd64"))

            XCTAssertEqual(
                try text(of: root.appendingPathComponent("drivers/NetKVM/arm64/netkvm.inf")),
                "netkvm"
            )
            XCTAssertTrue(exists(root.appendingPathComponent("drivers/NetKVM/arm64/netkvm.sys")))
            XCTAssertTrue(exists(root.appendingPathComponent("drivers/viostor/arm64/viostor.inf")))
            XCTAssertFalse(exists(root.appendingPathComponent("drivers/viostor/arm64/viostor.w10")))
        }
        XCTAssertFalse(try isAttached(image: media))
    }

    func testPrepareMediaWritesNoAnswerFileForAGuestThatDoesNotNeedOne() throws {
        try requireHDIUtil()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceStaging = directory.appendingPathComponent("source", isDirectory: true)
        try write("NetKVM/w11/ARM64/netkvm.inf", "netkvm", in: sourceStaging)
        let sourceISO = directory.appendingPathComponent("virtio-win-synthetic.iso")
        try MacportTools.buildMedia(to: sourceISO, staging: sourceStaging)

        let media = directory.appendingPathComponent("macport-tools-linux.iso")
        try MacportTools.prepareMedia(for: .linuxARM, at: media, iso: sourceISO)

        try MacportTools.withMountedImage(at: media) { root in
            XCTAssertFalse(exists(root.appendingPathComponent("autounattend.xml")))
            XCTAssertTrue(exists(root.appendingPathComponent("drivers/NetKVM/arm64/netkvm.inf")))
        }
    }

    func testPrepareMediaRefusesAnISOWithoutArm64Drivers() throws {
        try requireHDIUtil()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceStaging = directory.appendingPathComponent("source", isDirectory: true)
        try write("NetKVM/w11/amd64/netkvm.inf", "amd64", in: sourceStaging)
        let sourceISO = directory.appendingPathComponent("virtio-win-amd64-only.iso")
        try MacportTools.buildMedia(to: sourceISO, staging: sourceStaging)

        let media = directory.appendingPathComponent("macport-tools.iso")
        XCTAssertThrowsError(
            try MacportTools.prepareMedia(for: .windowsARM, at: media, iso: sourceISO)
        ) { error in
            guard case .noArm64Drivers(let missing, let iso)? = error as? MacportToolsError else {
                return XCTFail("Expected noArm64Drivers, got \(error).")
            }
            XCTAssertEqual(missing, MacportTools.driverNames)
            XCTAssertEqual(iso, sourceISO)
        }
        XCTAssertFalse(exists(media), "A media with no drivers must not be written.")
    }

    func testPrepareMediaRefusesAnISOThatIsNotThere() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("gone.iso")
        let media = directory.appendingPathComponent("macport-tools.iso")
        XCTAssertThrowsError(
            try MacportTools.prepareMedia(for: .windowsARM, at: media, iso: missing)
        ) { error in
            guard case .imageNotFound(let url)? = error as? MacportToolsError else {
                return XCTFail("Expected imageNotFound, got \(error).")
            }
            XCTAssertEqual(url, missing)
        }
        XCTAssertFalse(exists(media))
    }

    // MARK: - Helpers

    private func writeContents(_ contents: String, at url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }
}
