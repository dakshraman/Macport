import Foundation

/// A minimal FAT16 volume writer.
///
/// Macport occasionally has to hand a guest a file the *guest* goes looking for: it
/// browses the media it can mount and reads what it finds there. Windows Setup works
/// that way, and the only filesystem that is both small enough to write out by hand
/// and natively readable by every guest Macport can run is FAT. So this writes the
/// subset that needs: a partition table, a boot sector, a root directory and file
/// contents behind them.
///
/// It is not a general-purpose FAT implementation, and should not be allowed to
/// become one. There are no subdirectories, no fragmentation, no clone or lost-cluster
/// handling, and one fixed timestamp for everything. Long-file-name entries are
/// written purely because the name this exists to carry, `autounattend.xml`, does not
/// fit in 8.3 — everything else here is the ordinary short-name path.
struct Fat16Volume {

    /// A file to place in the volume's root directory.
    struct File {
        let name: String
        let contents: Data
    }

    /// The name the volume carries. FAT stores it in an otherwise-unused directory
    /// entry, which is why it is written as part of the root directory rather than in
    /// a header field.
    let label: String
    let files: [File]

    // MARK: - Geometry

    /// Size of the image as a whole. Eight MiB is far more than an answer file needs
    /// and little enough that writing it on every start costs nothing measurable.
    private let totalSectors = 16_384

    /// The partition starts 1 MiB in — the offset every partitioning tool has used
    /// since Vista, and the one that cannot be wrong.
    private let partitionStartSector = 2_048

    /// 512-byte sectors. Not a choice so much as an assumption every FAT driver
    /// makes.
    private let bytesPerSector = 512

    /// 1 KiB clusters, which keeps the cluster count inside FAT16's range without
    /// making the volume large.
    private let sectorsPerCluster = 2

    /// A single reserved sector: FAT's first sector is the boot sector itself.
    private let reservedSectors = 1

    /// Two copies of the allocation table. One is legal and some tools dislike it;
    /// two is what every formatter writes.
    private let numberOfFATs = 2

    /// 512 directory entries, the conventional size. A handful are used.
    private let rootEntryCount = 512

    private var partitionSectors: Int { totalSectors - partitionStartSector }

    private var rootDirectorySectors: Int { rootEntryCount * 32 / bytesPerSector }

    private var clusterBytes: Int { bytesPerSector * sectorsPerCluster }

    /// The allocation table has to hold one entry per cluster, and the cluster count
    /// depends on how much of the volume the table occupies — so the two are solved
    /// together, upward, the way the FAT specification describes. Hard-coding a pair
    /// of numbers here is how you get a volume that mounts until somebody changes its
    /// size.
    private var fatSectors: Int {
        var sectors = 1
        while true {
            let dataSectors = partitionSectors - reservedSectors
                - numberOfFATs * sectors - rootDirectorySectors
            let clusters = dataSectors / sectorsPerCluster
            let needed = ((clusters + 2) * 2 + bytesPerSector - 1) / bytesPerSector
            if needed <= sectors { return sectors }
            sectors = needed
        }
    }

    private var clusterCount: Int {
        (partitionSectors - reservedSectors - numberOfFATs * fatSectors
            - rootDirectorySectors) / sectorsPerCluster
    }

    // MARK: - Writing

    func write(to url: URL) throws {
        precondition(
            clusterCount >= 4_085,
            "A FAT16 volume needs at least 4085 clusters; this geometry has \(clusterCount)."
        )

        var image = Data(count: totalSectors * bytesPerSector)
        let volumeBase = partitionStartSector * bytesPerSector

        writePartitionTable(into: &image)
        writeBootSector(into: &image, at: volumeBase)

        let fatOffset = volumeBase + reservedSectors * bytesPerSector
        let fatBytes = fatSectors * bytesPerSector
        var fat = Data(count: fatBytes)
        // Entry 0 carries the media descriptor and entry 1 is always an end marker;
        // file data begins at cluster 2 because of them.
        put(UInt16(0xFFF8), in: &fat, at: 0)
        put(UInt16(0xFFFF), in: &fat, at: 2)

        var cursor = fatOffset + numberOfFATs * fatBytes
        cursor += writeLabelEntry(into: &image, at: cursor)

        var nextCluster = 2
        for file in files {
            let shortName = Self.shortName(for: file.name)
            for entry in Self.longNameEntries(for: file.name, shortName: shortName) {
                image.replaceSubrange(cursor..<(cursor + 32), with: entry)
                cursor += 32
            }

            let clusterSpan = max(1, (file.contents.count + clusterBytes - 1) / clusterBytes)
            cursor += writeFileEntry(
                into: &image,
                at: cursor,
                shortName: shortName,
                firstCluster: nextCluster,
                size: file.contents.count
            )

            for offset in 0..<clusterSpan {
                let cluster = nextCluster + offset
                let last = offset == clusterSpan - 1
                put(UInt16(last ? 0xFFFF : UInt16(cluster + 1)), in: &fat, at: cluster * 2)

                let start = file.contents.startIndex + offset * clusterBytes
                let end = min(start + clusterBytes, file.contents.endIndex)
                let destination = dataOffset(forCluster: cluster, volumeBase: volumeBase)
                image.replaceSubrange(
                    destination..<(destination + (end - start)),
                    with: file.contents[start..<end]
                )
            }
            nextCluster += clusterSpan
        }

        // Both tables, byte for byte.
        for copy in 0..<numberOfFATs {
            let offset = fatOffset + copy * fatBytes
            image.replaceSubrange(offset..<(offset + fatBytes), with: fat)
        }

        try image.write(to: url)
    }

    /// A master boot record holding one partition.
    ///
    /// A volume with no partition table — a "superfloppy", the layout a floppy uses —
    /// is mounted by Windows only on media it classifies as a floppy. A disk needs a
    /// partition table, so it gets one.
    private func writePartitionTable(into image: inout Data) {
        let entry = 446
        // Explicit "use LBA" values in the cylinder/head/sector fields. Nothing on a
        // disk this size reads them, and a plausible-looking invented geometry would
        // be worse than a refusal to answer.
        image[entry + 0] = 0x00                             // not active; nothing boots here
        image[entry + 1] = 0xFE
        image[entry + 2] = 0xFF
        image[entry + 3] = 0xFF
        image[entry + 4] = 0x0E                             // FAT16, LBA-addressed
        image[entry + 5] = 0xFE
        image[entry + 6] = 0xFF
        image[entry + 7] = 0xFF
        put(UInt32(partitionStartSector), in: &image, at: entry + 8)
        put(UInt32(partitionSectors), in: &image, at: entry + 12)
        image[510] = 0x55                                   // the signature a driver checks
        image[511] = 0xAA
    }

    private func writeBootSector(into image: inout Data, at base: Int) {
        // A jump instruction, so the sector would be executable if anything tried; the
        // code after it stays zero because nothing boots this disk.
        image[base + 0] = 0xEB
        image[base + 1] = 0x3C
        image[base + 2] = 0x90
        Self.writeName("MACPORT", width: 8, into: &image, at: base + 3)
        put(UInt16(bytesPerSector), in: &image, at: base + 11)
        image[base + 13] = UInt8(sectorsPerCluster)
        put(UInt16(reservedSectors), in: &image, at: base + 14)
        image[base + 16] = UInt8(numberOfFATs)
        put(UInt16(rootEntryCount), in: &image, at: base + 17)
        put(UInt16(0), in: &image, at: base + 19)           // volumes over 64 KiB use the 32-bit count
        image[base + 21] = 0xF8                             // media descriptor: fixed disk
        put(UInt16(fatSectors), in: &image, at: base + 22)
        put(UInt16(32), in: &image, at: base + 24)          // sectors per track
        put(UInt16(64), in: &image, at: base + 26)          // heads
        put(UInt32(partitionStartSector), in: &image, at: base + 28)
        put(UInt32(partitionSectors), in: &image, at: base + 32)
        image[base + 36] = 0x80                             // drive number
        image[base + 38] = 0x29                             // extended boot signature
        put(UInt32(0x4D41_4350), in: &image, at: base + 39) // "MACP", a volume id
        Self.writeName(label, width: 11, into: &image, at: base + 43)
        Self.writeName("FAT16", width: 8, into: &image, at: base + 54)
        image[base + 510] = 0x55
        image[base + 511] = 0xAA
    }

    /// The volume's name, which FAT stores as a directory entry rather than a header
    /// field. Returns the bytes consumed.
    private func writeLabelEntry(into image: inout Data, at offset: Int) -> Int {
        var entry = Data(count: 32)
        Self.writeName(label, width: 11, into: &entry, at: 0)
        entry[11] = 0x08                                    // volume label
        image.replaceSubrange(offset..<(offset + 32), with: entry)
        return 32
    }

    private func writeFileEntry(
        into image: inout Data,
        at offset: Int,
        shortName: [UInt8],
        firstCluster: Int,
        size: Int
    ) -> Int {
        var entry = Data(count: 32)
        entry.replaceSubrange(0..<11, with: shortName)
        entry[11] = 0x20                                    // archive
        put(Self.timestamp, in: &entry, at: 14)             // created
        put(Self.date, in: &entry, at: 16)
        put(Self.date, in: &entry, at: 18)                  // last accessed
        put(UInt16(0), in: &entry, at: 20)                  // high cluster word: FAT16 has none
        put(Self.timestamp, in: &entry, at: 22)             // last written
        put(Self.date, in: &entry, at: 24)
        put(UInt16(firstCluster), in: &entry, at: 26)
        put(UInt32(size), in: &entry, at: 28)
        image.replaceSubrange(offset..<(offset + 32), with: entry)
        return 32
    }

    /// Byte offset of a cluster's first sector. Cluster numbering starts at two,
    /// because the first two table entries are reserved.
    private func dataOffset(forCluster cluster: Int, volumeBase: Int) -> Int {
        let sector = reservedSectors + numberOfFATs * fatSectors + rootDirectorySectors
            + (cluster - 2) * sectorsPerCluster
        return volumeBase + sector * bytesPerSector
    }

    // MARK: - Directory entry plumbing

    /// One fixed timestamp for everything in the volume.
    ///
    /// Nothing reads it, and taking the clock would mean two runs that should produce
    /// identical media produce different bytes.
    private static let date: UInt16 = ((2_024 - 1_980) << 9) | (1 << 5) | 1
    private static let timestamp: UInt16 = (12 << 11) | (0 << 5) | 0

    /// Write `text` into a fixed-width name field, space-padded or truncated. Every
    /// name field in a FAT header takes this shape.
    private static func writeName(_ text: String, width: Int, into target: inout Data, at offset: Int) {
        var bytes = Array(text.uppercased().utf8.prefix(width))
        bytes += Array(repeating: UInt8(0x20), count: max(0, width - bytes.count))
        target.replaceSubrange(offset..<(offset + width), with: bytes)
    }

    /// The 8.3 alias for a long name: six characters of the base name, `~1`, and the
    /// extension.
    ///
    /// A real driver generates these with collision handling and a per-directory
    /// counter. Macport writes a couple of known names into an empty directory, so the
    /// naive form is enough — and the alias's only real job here is to be the thing
    /// the long-name checksum is computed from.
    private static func shortName(for name: String) -> [UInt8] {
        let parts = name.uppercased().split(separator: ".", maxSplits: 1)
        let base = String(parts.first ?? "")
        let extension_ = parts.count > 1 ? String(parts[1]) : ""

        var bytes = Array((String(base.prefix(6)) + "~1").utf8.prefix(8))
        bytes += Array(repeating: UInt8(0x20), count: max(0, 8 - bytes.count))

        var suffix = Array(extension_.utf8.prefix(3))
        suffix += Array(repeating: UInt8(0x20), count: max(0, 3 - suffix.count))
        return bytes + suffix
    }

    /// Long-file-name entries for a name that does not fit in 8.3.
    ///
    /// One entry per 13 UTF-16 units, stored in reverse order ahead of the short entry
    /// they belong to, each stamped with a checksum of the short name so a driver can
    /// tell the two together. Windows 95's scheme, unchanged since.
    private static func longNameEntries(for name: String, shortName: [UInt8]) -> [Data] {
        var units = Array(name.utf16)
        // The name is null-terminated unless it ends exactly on a slot boundary, and
        // any remainder of the last slot is filled rather than left as zeros — a zero
        // there would read as a second terminator.
        if units.count % 13 != 0 { units.append(0) }
        while units.count % 13 != 0 { units.append(0xFFFF) }

        let sum = checksum(of: shortName)
        let slots = units.count / 13
        return (0..<slots).reversed().map { slot in
            var entry = Data(count: 32)
            entry[0] = UInt8(slot == slots - 1 ? 0x40 | (slot + 1) : slot + 1)
            entry[11] = 0x0F                                // long name, and no other attribute
            entry[13] = sum
            for index in 0..<13 {
                let unit = units[slot * 13 + index]
                // The thirteen characters are split into runs of five, six and two by
                // the fields the format keeps for its own use.
                let offset = index < 5
                    ? 1 + index * 2
                    : (index < 11 ? 14 + (index - 5) * 2 : 28 + (index - 11) * 2)
                entry[offset] = UInt8(unit & 0xFF)
                entry[offset + 1] = UInt8(unit >> 8)
            }
            return entry
        }
    }

    /// The checksum a long-name entry carries: a shift-and-add over the eleven bytes of
    /// the short name, in the order they appear in its directory entry.
    private static func checksum(of shortName: [UInt8]) -> UInt8 {
        shortName.reduce(UInt8(0)) { sum, byte in
            ((sum & 1) == 1 ? 0x80 : 0) &+ (sum >> 1) &+ byte
        }
    }

    private func put(_ value: UInt16, in target: inout Data, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            target.replaceSubrange(offset..<(offset + 2), with: bytes)
        }
    }

    private func put(_ value: UInt32, in target: inout Data, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            target.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }
}
