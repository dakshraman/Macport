import CoreGraphics
import Darwin
import Foundation

/// A high-performance, native Remote Framebuffer (RFB / VNC) client that connects
/// to a local UNIX domain socket and decodes the guest's display frames directly.
///
/// This provides the headless embedded console for Windows and QEMU guests, matching
/// the Parallels Desktop architecture where the VM host daemon runs headless in the
/// background and displays inside the main application window.
public final class RFBDisplayClient: @unchecked Sendable {
    public struct Frame: Sendable {
        public let image: CGImage
        public let width: Int
        public let height: Int
    }

    private let socketPath: String
    private let readQueue = DispatchQueue(label: "com.dakshraman.macport.rfb.read", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "com.dakshraman.macport.rfb.input", qos: .userInteractive)
    private let writeLock = NSLock()
    private var socketFD: Int32 = -1
    private var isRunning = false

    public private(set) var width: Int = 0
    public private(set) var height: Int = 0
    private var framebuffer: [UInt8] = []

    public var onFrame: (@Sendable (Frame) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?
    public var onClipboardTextReceived: (@Sendable (String) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        disconnect()
    }

    public func connect() {
        readQueue.async { [weak self] in
            self?.runLoop()
        }
    }

    public func disconnect() {
        guard isRunning || socketFD >= 0 else { return }
        isRunning = false
        if socketFD >= 0 {
            Darwin.shutdown(socketFD, SHUT_RDWR)
            Darwin.close(socketFD)
            socketFD = -1
        }
        onDisconnect?()
    }

    // MARK: - Input Events

    /// Send a pointer (mouse) event to the guest.
    /// - Parameters:
    ///   - x: Guest X coordinate (0..<width)
    ///   - y: Guest Y coordinate (0..<height)
    ///   - buttonMask: Bitmask of buttons (bit 0 = Left, bit 1 = Middle, bit 2 = Right)
    public func sendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        inputQueue.async { [weak self] in
            guard let self = self, self.isRunning, self.socketFD >= 0 else { return }
            let maxX = self.width > 0 ? UInt16(self.width - 1) : 0
            let maxY = self.height > 0 ? UInt16(self.height - 1) : 0
            let clampedX = max(0, min(maxX, UInt16(x)))
            let clampedY = max(0, min(maxY, UInt16(y)))

            var msg = [UInt8](repeating: 0, count: 6)
            msg[0] = 5 // PointerEvent
            msg[1] = buttonMask
            msg[2] = UInt8(clampedX >> 8)
            msg[3] = UInt8(clampedX & 0xFF)
            msg[4] = UInt8(clampedY >> 8)
            msg[5] = UInt8(clampedY & 0xFF)

            try? self.writeExact(msg)
        }
    }

    /// Send a keyboard event to the guest.
    /// - Parameters:
    ///   - key: X11 keysym
    ///   - isDown: True for key press, false for key release
    public func sendKeyEvent(key: UInt32, isDown: Bool) {
        inputQueue.async { [weak self] in
            guard let self = self, self.isRunning, self.socketFD >= 0 else { return }
            var msg = [UInt8](repeating: 0, count: 8)
            msg[0] = 4 // KeyEvent
            msg[1] = isDown ? 1 : 0
            msg[2] = 0
            msg[3] = 0
            msg[4] = UInt8((key >> 24) & 0xFF)
            msg[5] = UInt8((key >> 16) & 0xFF)
            msg[6] = UInt8((key >> 8) & 0xFF)
            msg[7] = UInt8(key & 0xFF)

            try? self.writeExact(msg)
        }
    }

    /// Send Ctrl + Alt + Delete sequence to the guest.
    public func sendCtrlAltDel() {
        let ctrl: UInt32 = 0xFFE3
        let alt: UInt32 = 0xFFE9
        let del: UInt32 = 0xFFFF

        sendKeyEvent(key: ctrl, isDown: true)
        sendKeyEvent(key: alt, isDown: true)
        sendKeyEvent(key: del, isDown: true)

        inputQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendKeyEvent(key: del, isDown: false)
            self?.sendKeyEvent(key: alt, isDown: false)
            self?.sendKeyEvent(key: ctrl, isDown: false)
        }
    }

    /// Send clipboard text (ClientCutText) to the guest.
    public func sendClipboardText(_ text: String) {
        inputQueue.async { [weak self] in
            guard let self = self, self.isRunning, self.socketFD >= 0 else { return }
            guard let data = text.data(using: .latin1) ?? text.data(using: .utf8) else { return }
            var msg = [UInt8](repeating: 0, count: 8)
            msg[0] = 6 // ClientCutText
            msg[1] = 0; msg[2] = 0; msg[3] = 0 // padding
            let len = UInt32(data.count)
            msg[4] = UInt8((len >> 24) & 0xFF)
            msg[5] = UInt8((len >> 16) & 0xFF)
            msg[6] = UInt8((len >> 8) & 0xFF)
            msg[7] = UInt8(len & 0xFF)

            var fullMsg = msg
            fullMsg.append(contentsOf: data)
            try? self.writeExact(fullMsg)
        }
    }

    // MARK: - Protocol Loop

    private func runLoop() {
        isRunning = true

        // Retry connecting if QEMU is still initializing the socket
        var attempts = 0
        while isRunning && socketFD < 0 && attempts < 40 {
            socketFD = openUnixSocket(at: socketPath)
            if socketFD < 0 {
                attempts += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        guard isRunning && socketFD >= 0 else {
            disconnect()
            return
        }

        do {
            try performHandshake()
            try sendConfiguration()
            try requestUpdate(incremental: false)

            while isRunning && socketFD >= 0 {
                guard let msgType = readByte() else { break }
                switch msgType {
                case 0: // FramebufferUpdate
                    try handleFramebufferUpdate()
                    try requestUpdate(incremental: true)
                case 1: // SetColourMapEntries
                    try skipColourMapEntries()
                case 2: // Bell
                    break
                case 3: // ServerCutText
                    try handleServerCutText()
                default:
                    break
                }
            }
        } catch {
            // Socket or handshake error
        }

        disconnect()
    }

    private func openUnixSocket(at path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)

        guard path.utf8.count < maxLen else {
            close(fd)
            return -1
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                _ = path.withCString { strncpy(dest, $0, maxLen - 1) }
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }

        if res != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - Handshake

    private func performHandshake() throws {
        // Read 12 bytes version: "RFB 003.008\n"
        let versionBytes = try readExact(count: 12)
        guard versionBytes.count == 12 else { throw NSError(domain: "RFB", code: 1) }

        // Send back same version
        try writeExact(versionBytes)

        // Read security types count and types
        guard let secCount = readByte(), secCount > 0 else { throw NSError(domain: "RFB", code: 2) }
        let secTypes = try readExact(count: Int(secCount))

        // We choose security type 1 (None)
        if secTypes.contains(1) {
            try writeExact([1])
        } else if let first = secTypes.first {
            try writeExact([first])
        } else {
            throw NSError(domain: "RFB", code: 3)
        }

        // Read security result (4 bytes 0 = OK)
        let secResult = try readExact(count: 4)
        guard secResult == [0, 0, 0, 0] else { throw NSError(domain: "RFB", code: 4) }

        // Send ClientInit: shared = 1
        try writeExact([1])

        // Read ServerInit: width (2), height (2), pixel format (16), name_length (4)
        let initHeader = try readExact(count: 24)
        let w = Int(UInt16(initHeader[0]) << 8 | UInt16(initHeader[1]))
        let h = Int(UInt16(initHeader[2]) << 8 | UInt16(initHeader[3]))
        let nameLen = Int(
            UInt32(initHeader[20]) << 24 |
            UInt32(initHeader[21]) << 16 |
            UInt32(initHeader[22]) << 8 |
            UInt32(initHeader[23])
        )

        _ = try readExact(count: nameLen) // discard server name

        self.width = w
        self.height = h
        self.framebuffer = [UInt8](repeating: 0, count: w * h * 4)
    }

    private func sendConfiguration() throws {
        // SetPixelFormat: 32bpp, depth 24, little-endian, true-colour, 8-bit channels
        var pixfmt = [UInt8](repeating: 0, count: 20)
        pixfmt[0] = 0 // SetPixelFormat
        pixfmt[4] = 32 // bits per pixel
        pixfmt[5] = 24 // depth
        pixfmt[6] = 0  // big-endian = false (little-endian)
        pixfmt[7] = 1  // true-colour = true
        pixfmt[8] = 0; pixfmt[9] = 255   // red max
        pixfmt[10] = 0; pixfmt[11] = 255 // green max
        pixfmt[12] = 0; pixfmt[13] = 255 // blue max
        pixfmt[14] = 16 // red shift
        pixfmt[15] = 8  // green shift
        pixfmt[16] = 0  // blue shift
        try writeExact(pixfmt)

        // SetEncodings: Raw (0)
        var enc = [UInt8](repeating: 0, count: 8)
        enc[0] = 2 // SetEncodings
        enc[2] = 0; enc[3] = 1 // count = 1
        enc[4] = 0; enc[5] = 0; enc[6] = 0; enc[7] = 0 // encoding 0 (Raw)
        try writeExact(enc)
    }

    private func requestUpdate(incremental: Bool) throws {
        var req = [UInt8](repeating: 0, count: 10)
        req[0] = 3 // FramebufferUpdateRequest
        req[1] = incremental ? 1 : 0
        req[2] = 0; req[3] = 0 // x = 0
        req[4] = 0; req[5] = 0 // y = 0
        req[6] = UInt8((width >> 8) & 0xFF)
        req[7] = UInt8(width & 0xFF)
        req[8] = UInt8((height >> 8) & 0xFF)
        req[9] = UInt8(height & 0xFF)
        try writeExact(req)
    }

    // MARK: - Frame Updates

    private func handleFramebufferUpdate() throws {
        _ = try readByte() // padding
        let numRectsBytes = try readExact(count: 2)
        let numRects = Int(UInt16(numRectsBytes[0]) << 8 | UInt16(numRectsBytes[1]))

        for _ in 0..<numRects {
            let rectHdr = try readExact(count: 12)
            let rx = Int(UInt16(rectHdr[0]) << 8 | UInt16(rectHdr[1]))
            let ry = Int(UInt16(rectHdr[2]) << 8 | UInt16(rectHdr[3]))
            let rw = Int(UInt16(rectHdr[4]) << 8 | UInt16(rectHdr[5]))
            let rh = Int(UInt16(rectHdr[6]) << 8 | UInt16(rectHdr[7]))
            let encoding = Int32(
                Int32(rectHdr[8]) << 24 |
                Int32(rectHdr[9]) << 16 |
                Int32(rectHdr[10]) << 8 |
                Int32(rectHdr[11])
            )

            if encoding == 0 { // Raw
                let byteCount = rw * rh * 4
                let pixelData = try readExact(count: byteCount)

                // Blit rect into our full framebuffer
                let fbStride = width * 4
                let rectStride = rw * 4
                for row in 0..<rh {
                    let destY = ry + row
                    guard destY < height else { break }
                    let destOffset = destY * fbStride + rx * 4
                    let srcOffset = row * rectStride
                    let copyLen = min(rectStride, fbStride - rx * 4)

                    if destOffset + copyLen <= framebuffer.count && srcOffset + copyLen <= pixelData.count {
                        framebuffer.replaceSubrange(
                            destOffset..<(destOffset + copyLen),
                            with: pixelData[srcOffset..<(srcOffset + copyLen)]
                        )
                    }
                }
            } else if encoding == -223 { // DesktopSize pseudo-encoding
                self.width = rw
                self.height = rh
                self.framebuffer = [UInt8](repeating: 0, count: rw * rh * 4)
            }
        }

        // Deliver rendered frame
        if let cgImage = createCGImage() {
            let frame = Frame(image: cgImage, width: width, height: height)
            onFrame?(frame)
        }
    }

    private func createCGImage() -> CGImage? {
        guard width > 0, height > 0, framebuffer.count >= width * height * 4 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Little endian BGRA format matching QEMU display
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

        guard let provider = CGDataProvider(data: Data(framebuffer) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func skipColourMapEntries() throws {
        _ = try readByte()
        _ = try readExact(count: 2) // first colour
        let nColoursBytes = try readExact(count: 2)
        let nColours = Int(UInt16(nColoursBytes[0]) << 8 | UInt16(nColoursBytes[1]))
        _ = try readExact(count: nColours * 6)
    }

    private func handleServerCutText() throws {
        _ = try readExact(count: 3) // padding
        let lenBytes = try readExact(count: 4)
        let len = Int(
            UInt32(lenBytes[0]) << 24 |
            UInt32(lenBytes[1]) << 16 |
            UInt32(lenBytes[2]) << 8 |
            UInt32(lenBytes[3])
        )
        guard len > 0 else { return }
        let bytes = try readExact(count: len)
        if let string = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) {
            onClipboardTextReceived?(string)
        }
    }

    // MARK: - Low-level I/O

    private func readByte() -> UInt8? {
        var b: UInt8 = 0
        let n = Darwin.read(socketFD, &b, 1)
        return n == 1 ? b : nil
    }

    private func readExact(count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        while totalRead < count && isRunning {
            let n = buf.withUnsafeMutableBytes { ptr in
                Darwin.read(socketFD, ptr.baseAddress! + totalRead, count - totalRead)
            }
            guard n > 0 else { throw NSError(domain: "RFB", code: 5) }
            totalRead += n
        }
        return buf
    }

    private func writeExact(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var totalWritten = 0
        while totalWritten < bytes.count && isRunning && socketFD >= 0 {
            let n = bytes.withUnsafeBytes { ptr in
                Darwin.write(socketFD, ptr.baseAddress! + totalWritten, bytes.count - totalWritten)
            }
            guard n > 0 else { throw NSError(domain: "RFB", code: 6) }
            totalWritten += n
        }
    }
}
