import Foundation
import XCTest
import MacportKit

/// The answer file is the one artefact Windows Setup reads without being asked, so
/// every property it has to hold is asserted here rather than discovered during an
/// installation.
final class UnattendMediaTests: XCTestCase {

    // MARK: - The TPM bypass

    func testAnswerFileKeepsEveryLabConfigBypass() throws {
        let xml = try text(driverPaths: [])

        for value in [
            "BypassTPMCheck",
            "BypassSecureBootCheck",
            "BypassRAMCheck",
            "BypassStorageCheck",
        ] {
            XCTAssertTrue(
                xml.contains("reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(value)"),
                "The answer file no longer bypasses \(value)."
            )
        }
        XCTAssertTrue(xml.contains("<settings pass=\"windowsPE\">"))
    }

    func testAnswerFileNeedsNoDriverComponentWhenThereAreNoDriverPaths() throws {
        let xml = try text(driverPaths: [])
        XCTAssertFalse(xml.contains("PnpCustomizationsWinPE"))
        XCTAssertEqual(xml.components(separatedBy: "<settings pass=\"windowsPE\">").count - 1, 1)
    }

    // MARK: - Driver paths

    func testAnswerFileAddsOnePathAndCredentialsEntryPerDriverPath() throws {
        let paths = [
            "E:\\drivers\\NetKVM\\arm64",
            "E:\\drivers\\viostor\\arm64",
            "F:\\drivers\\viofs\\arm64",
        ]
        let xml = try text(driverPaths: paths)

        XCTAssertTrue(xml.contains("Microsoft-Windows-PnpCustomizationsWinPE"))
        XCTAssertEqual(
            xml.components(separatedBy: "<PathAndCredentials").count - 1,
            paths.count,
            "One PathAndCredentials entry is needed per driver path."
        )
        for path in paths {
            XCTAssertTrue(xml.contains("<Path>\(path)</Path>"), "Missing path \(path).")
        }
        for key in 1...paths.count {
            XCTAssertTrue(xml.contains("wcm:keyValue=\"\(key)\""), "Missing keyValue \(key).")
        }
        XCTAssertEqual(
            xml.components(separatedBy: "<settings pass=\"windowsPE\">").count - 1,
            2,
            "The driver component lives in its own windowsPE settings block."
        )
    }

    func testDriverComponentCarriesTheArm64ComponentIdentity() throws {
        let xml = try text(driverPaths: ["E:\\drivers\\NetKVM\\arm64"])

        guard let start = xml.range(of: "<component name=\"Microsoft-Windows-PnpCustomizationsWinPE\""),
              let end = xml.range(of: "</component>", range: start.upperBound..<xml.endIndex)
        else {
            return XCTFail("The answer file has no PnpCustomizationsWinPE component.")
        }

        let component = String(xml[start.lowerBound..<end.upperBound])
        XCTAssertTrue(component.contains("processorArchitecture=\"arm64\""))
        XCTAssertTrue(component.contains("publicKeyToken=\"31bf3856ad364e35\""))
        XCTAssertTrue(component.contains("language=\"neutral\""))
        XCTAssertTrue(component.contains("versionScope=\"nonSxS\""))
    }

    func testAnswerFileRejectsPathsThatAreNotDriveLetterPaths() {
        for bad in ["", "   ", "drivers\\NetKVM\\arm64", "E", "E:", "E:drivers", "1:\\drivers", "\\\\server\\share"] {
            XCTAssertThrowsError(try UnattendMedia.answerFileXML(driverPaths: [bad]), "\"\(bad)\"") { error in
                XCTAssertEqual(
                    error as? UnattendMediaError,
                    .invalidDriverPath(bad),
                    "\"\(bad)\" should be refused as a driver path."
                )
            }
        }
    }

    func testAnswerFileDropsDuplicateDriverPaths() throws {
        let duplicated = "E:\\drivers\\NetKVM\\arm64"
        let xml = try text(driverPaths: [duplicated, duplicated])
        XCTAssertEqual(xml.components(separatedBy: "<PathAndCredentials").count - 1, 1)
    }

    // MARK: - Well-formedness

    func testAnswerFileIsWellFormedXML() throws {
        for paths in [[], ["E:\\drivers\\NetKVM\\arm64", "E:\\drivers\\viostor\\arm64"]] {
            let data = try UnattendMedia.answerFileXML(driverPaths: paths)
            XCTAssertNil(xmlParseError(data), "XMLParser rejected the answer file.")
            try validateWithXmllint(data)
        }
    }

    func testAnswerFileValidatesWithXmllintWhenAvailable() throws {
        let data = try UnattendMedia.answerFileXML(driverPaths: ["E:\\drivers\\viogpudo\\arm64"])
        try validateWithXmllint(data)
    }

    // MARK: - Media

    func testIsNeededOnlyForWindows() {
        XCTAssertTrue(UnattendMedia.isNeeded(for: .windowsARM))
        XCTAssertFalse(UnattendMedia.isNeeded(for: .linuxARM))
        XCTAssertFalse(UnattendMedia.isNeeded(for: .macOSGuest))
    }

    func testCreateWritesTheAnswerFileIntoTheVolume() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let media = directory.appendingPathComponent("answer-media.img")
        try UnattendMedia.create(
            for: .windowsARM,
            at: media,
            driverPaths: ["E:\\drivers\\NetKVM\\arm64"]
        )

        let image = try Data(contentsOf: media)
        XCTAssertEqual(image.count, 8 * 1024 * 1024, "The answer volume is a fixed 8 MiB image.")

        // The XML is one file in a FAT16 volume, so it is stored contiguously and can
        // be found in the raw image without parsing the filesystem.
        let contents = String(decoding: image, as: UTF8.self)
        XCTAssertTrue(contents.contains("BypassTPMCheck"))
        XCTAssertTrue(contents.contains("<Path>E:\\drivers\\NetKVM\\arm64</Path>"))
    }

    // MARK: - Helpers

    private func text(driverPaths: [String]) throws -> String {
        String(decoding: try UnattendMedia.answerFileXML(driverPaths: driverPaths), as: UTF8.self)
    }

    private func validateWithXmllint(_ data: Data) throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else {
            // Not every machine carries libxml2's CLI; XMLParser above already
            // covered well-formedness in that case.
            return
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("autounattend.xml")
        try data.write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        process.arguments = ["--noout", file.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "xmllint rejected the answer file: \(String(decoding: errorData, as: UTF8.self))"
        )
    }
}
