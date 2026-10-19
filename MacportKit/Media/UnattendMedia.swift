import Foundation

/// The removable media Macport hands Windows Setup so a machine without a TPM can
/// still be installed.
///
/// Windows 11 refuses to install on a machine that presents no TPM 2.0 device and no
/// Secure Boot, and neither engine can give it one today: Apple's framework has no
/// virtual TPM anywhere in its device list, and QEMU's TPM support depends on an
/// external `swtpm` process that is not part of the runtime Macport ships. So the
/// check has to be satisfied rather than the device supplied.
///
/// Setup reads an answer file called `autounattend.xml` from the root of any removable
/// media it can mount, and applies that file's `windowsPE` settings *before* it
/// evaluates the machine it is running on. A synchronous command in that pass which
/// writes the documented bypass values into `HKLM\SYSTEM\Setup\LabConfig` is therefore
/// enough to get past the screen — and it is the same mechanism a fully unattended
/// installation is built out of, so this is the first piece of that story rather than
/// a special case bolted on for one dialog.
///
/// The same file also carries the *driver paths* Setup should load from the media.
/// `Microsoft-Windows-PnpCustomizationsWinPE` is the documented way to hand Setup a
/// directory of drivers during the same pass, and it is the mechanism Parallels uses
/// for its own Arm64 media (`Autounattend_arm64.xml` → `E:\netkvm\arm64`). One file
/// therefore does both jobs: it satisfies the machine checks and it makes the virtio
/// devices Windows cannot see on its own visible during installation.
///
/// It is a separate disk rather than a file somewhere in the VM bundle because Setup
/// finds it by browsing media, and Windows only browses what it mounts. The volume
/// carries no boot file, so the firmware creates no boot option for it and the boot
/// order is exactly what it would have been without it.
public enum UnattendMedia {

    /// The name Setup looks for. Fixed by Windows, not by Macport.
    nonisolated public static let fileName = "autounattend.xml"

    /// The label the media appears under in the guest.
    nonisolated public static let volumeLabel = "MACPORT"

    /// Whether a machine for `guest` needs this media to be installable.
    ///
    /// Only Windows, and only because Macport cannot yet present a vTPM. When an
    /// engine can, this returns false and the media disappears from the command line.
    nonisolated public static func isNeeded(for guest: GuestKind) -> Bool {
        guest == .windowsARM
    }

    /// Write the media for `guest` to `url`, replacing whatever is there.
    ///
    /// `driverPaths` are full guest paths to driver directories, as Setup will see
    /// them once the media that carries them is mounted — for example
    /// `E:\drivers\NetKVM\arm64`. Macport does not guess the drive letter: the caller
    /// chooses it, so the answer file and the engine's device attachment cannot drift
    /// apart silently.
    nonisolated public static func create(
        for guest: GuestKind,
        at url: URL,
        driverPaths: [String] = []
    ) throws {
        guard isNeeded(for: guest) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let volume = Fat16Volume(label: volumeLabel, files: [
            Fat16Volume.File(
                name: fileName,
                contents: try answerFileXML(driverPaths: driverPaths)
            ),
        ])
        try volume.write(to: url)
    }

    /// The answer file, in full, as bytes ready to be written to media.
    ///
    /// A function rather than a constant because the driver paths are input, and
    /// because the paths are validated: a relative path or an empty string would
    /// produce an answer file Setup silently ignores, which is the kind of failure
    /// that costs an entire installation to discover.
    nonisolated public static func answerFileXML(driverPaths: [String] = []) throws -> Data {
        Data(try answerFile(driverPaths: driverPaths).utf8)
    }

    /// The answer file, as text. Internal so tests can read it without decoding.
    static func answerFile(driverPaths: [String]) throws -> String {
        let paths = try validated(driverPaths: driverPaths)
        let settings = paths.isEmpty ? "" : driverSettingsXML(driverPaths: paths) + "\n"
        return answerFileTemplate.replacingOccurrences(
            of: driverSettingsPlaceholder,
            with: settings
        )
    }

    // MARK: - Driver paths

    /// Reject anything that is not a drive-letter path.
    ///
    /// `E:\drivers` and `E:/drivers` are accepted; `drivers`, `\\server\share` and
    /// an empty string are not. UNC paths are deliberately absent: the media Macport
    /// builds is a local CD-ROM, and accepting a shape no caller produces would only
    /// make a typo harder to see.
    nonisolated static func isDriveLetterPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 })
        else { return false }

        let characters = Array(path)
        guard characters.count >= 3 else { return false }
        guard characters[0].isASCII, characters[0].isLetter else { return false }
        guard characters[1] == ":" else { return false }
        guard characters[2] == "\\" || characters[2] == "/" else { return false }
        return !path.trimmingCharacters(in: .whitespaces).isEmpty
            && path == path.trimmingCharacters(in: .whitespaces)
    }

    /// Validate, then drop duplicates while keeping the caller's order.
    private static func validated(driverPaths: [String]) throws -> [String] {
        var paths: [String] = []
        for path in driverPaths {
            guard isDriveLetterPath(path) else {
                throw UnattendMediaError.invalidDriverPath(path)
            }
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// The second `windowsPE` settings block: the driver directories Setup should
    /// load before it looks for a disk.
    private static func driverSettingsXML(driverPaths: [String]) -> String {
        var lines = [
            "  <settings pass=\"windowsPE\">",
            "    <component name=\"Microsoft-Windows-PnpCustomizationsWinPE\"",
            "               processorArchitecture=\"arm64\"",
            "               publicKeyToken=\"31bf3856ad364e35\"",
            "               language=\"neutral\"",
            "               versionScope=\"nonSxS\">",
            "      <DriverPaths>",
        ]
        for (index, path) in driverPaths.enumerated() {
            lines.append(
                "        <PathAndCredentials wcm:keyValue=\"\(index + 1)\" wcm:action=\"add\">"
            )
            lines.append("          <Path>\(escapedXMLText(path))</Path>")
            lines.append("        </PathAndCredentials>")
        }
        lines.append(contentsOf: [
            "      </DriverPaths>",
            "    </component>",
            "  </settings>",
        ])
        return lines.joined(separator: "\n")
    }

    // MARK: - The file itself

    /// The whole document, with a placeholder where the driver settings block goes.
    ///
    /// Two details carry the weight. The pass is `windowsPE`, because that is the pass
    /// Setup processes before it decides whether the machine is fit to install on; a
    /// later pass would run after the screen has already been shown. And the work is
    /// done by `reg add` rather than by the schema's own registry elements, which are
    /// applied at a later pass and would arrive too late for the same reason.
    ///
    /// The remaining commands are there because a machine assembled out of emulated
    /// devices can fail the other scans too — memory, storage — and a check that can
    /// stop an install should not be left to chance.
    private static let driverSettingsPlaceholder = "{{DRIVER_SETTINGS}}"

    private static let answerFileTemplate = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend"
              xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup"
                   processorArchitecture="arm64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Description>TPM 2.0 check</Description>
              <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>2</Order>
              <Description>Secure Boot check</Description>
              <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>3</Order>
              <Description>Memory check</Description>
              <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>4</Order>
              <Description>Storage check</Description>
              <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>
    {{DRIVER_SETTINGS}}</unattend>
    """#

    /// Escape the five characters XML gives special meaning to.
    ///
    /// The ampersand has to go first or the escapes escape themselves; the other four
    /// are here so a path with a quote in it cannot end an attribute or a node early.
    private static func escapedXMLText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// What can go wrong composing the answer file.
public enum UnattendMediaError: LocalizedError, Equatable {

    /// A driver path was empty, relative, or not a drive-letter path.
    case invalidDriverPath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDriverPath(let path):
            let shown = path.isEmpty ? "(empty)" : path
            return """
            "\(shown)" is not a full Windows path. A driver path must name a drive, \
            like E:\\drivers\\NetKVM\\arm64.
            """
        }
    }
}
