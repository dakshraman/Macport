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
    nonisolated public static func create(for guest: GuestKind, at url: URL) throws {
        guard isNeeded(for: guest) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let volume = Fat16Volume(label: volumeLabel, files: [
            Fat16Volume.File(name: fileName, contents: Data(answerFile.utf8)),
        ])
        try volume.write(to: url)
    }

    /// The answer file, in full.
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
    nonisolated private static let answerFile = #"""
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
    </unattend>
    """#
}
