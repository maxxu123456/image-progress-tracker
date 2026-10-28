//
//  CollectionArchiveFormat.swift
//  Image Progress Tracker
//
//  PTC v1.0: the binary `.ptcollection` container (codec only).
//
//  File layout (all integers little-endian, no padding, no alignment):
//
//      preamble(16)  HEAD  *anc  *( ITEM *anc )  TAIL  EOF
//      chunk = u32 L | type[4] | payload[L] | u32 crc
//
//  Every chunk CRC is CRC-32 (zlib) over the chunk's length, type and payload,
//  seeded with the previous CRC field's value (the preamble CRC seeds HEAD).
//  CRC field bytes are never fed into the running CRC.
//
//  This file is Foundation + zlib only (no UIKit, ImageIO, SwiftData or
//  ImageStore) so it builds for iOS and for a macOS test executable. The app
//  layer owns the image allowlist check, the security-scoped copy and the
//  SwiftData import; this codec only guarantees that what `read` returns is a
//  fully validated archive and that what `Writer` produces is conformant.
//

import Foundation
import zlib

enum CollectionArchiveFormat {
    static let fileExtension = "ptcollection"
    static let typeIdentifier = "com.maxxu.picturetrack.collection"
    static let mimeType = "application/vnd.picturetrack.collection"

    /// Major version this codec reads and writes.
    static let formatMajor = 1
    /// Minor version this codec writes.
    static let formatMinor = 0
    /// SUPPORTED_MINOR: the highest minor whose additions this reader knows.
    static let supportedMinor = 0

    // MARK: Limits (spec section 8)

    enum Limits {
        static let minArchiveBytes = 67
        static let maxArchiveBytes = 1 << 36
        static let maxChunkPayload = 335_544_320
        static let maxChunks = 1 << 20
        static let maxItems = 100_000
        static let maxImageBytes = 1 << 28
        static let maxNotesBytes = 1 << 20
        static let maxNameBytes = 1_024
        static let maxIDBytes = 128
        static let maxIconBytes = 128
        static let maxSoftwareBytes = 256
        static let maxTotalText = 1 << 26
        static let minDate: Double = -63_114_076_800.0   // Date.distantPast
        static let maxDate: Double = 63_113_904_000.0    // Date.distantFuture
    }

    /// CRC and write granularity for large spans.
    static let pieceBytes = 8 << 20

    // MARK: Public model

    struct GroupMetadata: Sendable, Equatable {
        var originalID: String
        var name: String
        var icon: String
        var exportedAt: Date
    }

    struct ItemMetadata: Sendable, Equatable {
        var originalID: String
        var notes: String
        var dateCreated: Date
    }

    struct Item: Sendable {
        let metadata: ItemMetadata
        /// Zero-copy slice of the Data passed to `read` (shares its storage or mapping).
        let imageData: Data

        fileprivate init(metadata: ItemMetadata, imageData: Data) {
            self.metadata = metadata
            self.imageData = imageData
        }
    }

    /// Only `read` can create one, so holding an `Archive` means it passed full validation.
    struct Archive: Sendable {
        /// The minor version stored in the file (informational; any minor is accepted).
        let formatMinor: Int
        let group: GroupMetadata
        /// In file order.
        let items: [Item]

        fileprivate init(formatMinor: Int, group: GroupMetadata, items: [Item]) {
            self.formatMinor = formatMinor
            self.group = group
            self.items = items
        }
    }

    /// Input to `preflight`: an item's metadata plus the byte size of its image file.
    struct PreflightItem: Sendable, Equatable {
        var metadata: ItemMetadata
        var imageByteCount: Int
    }

    enum Field: String, Sendable, Equatable {
        case itemCount, exportedAt, groupID, name, icon, dateCreated, itemID, notes, image, software, totalText, chunkCount

        fileprivate var limitPhrase: String {
            switch self {
            case .itemCount: return "a collection can hold at most 100,000 photos"
            case .groupID: return "the collection identifier is longer than 128 bytes"
            case .name: return "the collection name is longer than 1,024 bytes"
            case .icon: return "the collection icon name is longer than 128 bytes"
            case .itemID: return "a photo identifier is longer than 128 bytes"
            case .notes: return "a photo's notes are longer than 1 MB"
            case .image: return "a photo is larger than 256 MB"
            case .software: return "the software tag is longer than 256 bytes"
            case .totalText: return "the text in the collection is larger than 64 MB in total"
            case .chunkCount: return "the file has more than 1,048,576 chunks"
            case .exportedAt, .dateCreated: return "a date is out of range"
            }
        }

        fileprivate var noun: String {
            switch self {
            case .groupID: return "collection identifier"
            case .name: return "collection name"
            case .icon: return "collection icon name"
            case .itemID: return "photo identifier"
            case .notes: return "photo notes"
            case .software: return "software tag"
            case .exportedAt: return "export date"
            case .dateCreated: return "photo date"
            default: return rawValue
            }
        }
    }

    // MARK: Errors (spec section 9.1, plus writer/host-side cases)

    enum FormatError: Error, Equatable, LocalizedError {
        /// Signature mismatch with no further diagnosis.
        case notAnArchive
        /// An old JSON+base64 export.
        case legacyFormat
        /// Signature mangled by a text-mode transfer or transcoding.
        case textModeDamaged
        /// The file ends early, or the end marker is missing.
        case truncated(offset: Int)
        /// size > MAX_ARCHIVE_BYTES (reader), or the archive would exceed it (writer).
        case tooLarge
        /// CRC mismatch, a non-letter type byte, or L > MAX_CHUNK_PAYLOAD.
        case corrupted(offset: Int)
        /// major != 1 (only after the preamble CRC matched).
        case unsupportedVersion(major: Int, minor: Int)
        /// Unknown critical chunk. `offset` is the chunk's file offset.
        case requiresNewerVersion(type: String, minor: Int, offset: Int)
        /// Any limit exceeded; `minor` lets the message say "newer version" when minor > supportedMinor.
        case limitExceeded(field: Field, offset: Int, minor: Int)
        /// Grammar, exact-length, count or empty-field violation.
        case malformed(offset: Int, reason: String)
        /// NUL where forbidden, or ill-formed UTF-8.
        case invalidText(field: Field, offset: Int)
        /// NaN, infinity, or outside [distantPast, distantFuture].
        case invalidDate(field: Field, offset: Int)
        /// The group name consists only of the pinned whitespace set W.
        case invalidGroupName(offset: Int)
        /// Bytes follow TAIL.
        case trailingData(offset: Int)

        // Writer / host side.
        /// Writer: more appends than declared, or `finish()` before all declared items.
        case itemCountMismatch(declared: Int, actual: Int)
        /// Writer: used after `finish()` or after an earlier error.
        case writerNotOpen
        /// Preflight: the volume does not have room for the archive.
        case insufficientSpace(required: Int, available: Int)
        /// Writer: bytes on disk differ from the bytes the writer produced.
        case writeVerificationFailed(expected: Int, actual: Int)
        /// `mapForReading`: mmap failed (for example, the address space is exhausted).
        case cannotMapFile(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                return "This file is not a PictureTrack collection."
            case .legacyFormat:
                return "This collection was exported by an older version of PictureTrack and can't be imported."
            case .textModeDamaged:
                return "This collection file was damaged by a text-mode transfer."
            case .truncated, .trailingData:
                return "This collection file is incomplete, or has extra bytes at the end."
            case .tooLarge:
                return "This collection file is too large."
            case .corrupted, .malformed:
                return "This collection file is damaged."
            case .unsupportedVersion(let major, let minor):
                return "This collection file was made by a different or newer PictureTrack format (\(major).\(minor))."
            case .requiresNewerVersion(_, let minor, _):
                return "This collection uses a newer feature (format 1.\(minor)). Update PictureTrack to import it."
            case .limitExceeded(let field, _, let minor):
                if minor > CollectionArchiveFormat.supportedMinor {
                    return "This collection was made by a newer PictureTrack (format 1.\(minor)). Update the app to import it."
                }
                return "This collection exceeds a PictureTrack limit: \(field.limitPhrase)."
            case .invalidText(let field, _):
                return "This collection contains invalid text in the \(field.noun)."
            case .invalidDate(let field, _):
                return "This collection contains an invalid \(field.noun)."
            case .invalidGroupName:
                return "This collection is missing a valid collection name."
            case .itemCountMismatch(let declared, let actual):
                return "The collection could not be exported (expected \(declared) photos, got \(actual))."
            case .writerNotOpen:
                return "The collection could not be exported because the export was already closed."
            case .insufficientSpace(let required, _):
                let size = ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .file)
                return "There isn't enough free storage to export this collection (\(size) needed)."
            case .writeVerificationFailed:
                return "The collection could not be exported completely."
            case .cannotMapFile:
                return "This collection is too large to open on this device."
            }
        }
    }

    // MARK: - Shared constants and validators (used by reader, writer and preflight)

    fileprivate static let signature: [UInt8] = [0x89, 0x50, 0x54, 0x43, 0x0D, 0x0A, 0x1A, 0x0A]
    fileprivate static let endMarker: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x54, 0x41, 0x49, 0x4C]

    fileprivate static func fourCC(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        UInt32(a) | UInt32(b) << 8 | UInt32(c) << 16 | UInt32(d) << 24
    }
    fileprivate static let typeHEAD = fourCC(0x48, 0x45, 0x41, 0x44)
    fileprivate static let typeITEM = fourCC(0x49, 0x54, 0x45, 0x4D)
    fileprivate static let typeTAIL = fourCC(0x54, 0x41, 0x49, 0x4C)
    fileprivate static let typeSOFT = fourCC(0x73, 0x4F, 0x46, 0x54)
    fileprivate static let negativeZeroBits: UInt64 = 0x8000_0000_0000_0000

    fileprivate struct StringRule {
        let field: Field
        let min: Int
        let max: Int
        let allowNUL: Bool
        let counted: Bool
    }

    fileprivate static let groupIDRule = StringRule(field: .groupID, min: 1, max: Limits.maxIDBytes, allowNUL: false, counted: true)
    fileprivate static let nameRule = StringRule(field: .name, min: 1, max: Limits.maxNameBytes, allowNUL: false, counted: true)
    fileprivate static let iconRule = StringRule(field: .icon, min: 1, max: Limits.maxIconBytes, allowNUL: false, counted: true)
    fileprivate static let itemIDRule = StringRule(field: .itemID, min: 1, max: Limits.maxIDBytes, allowNUL: false, counted: true)
    fileprivate static let notesRule = StringRule(field: .notes, min: 0, max: Limits.maxNotesBytes, allowNUL: true, counted: true)
    fileprivate static let softwareRule = StringRule(field: .software, min: 1, max: Limits.maxSoftwareBytes, allowNUL: false, counted: false)

    /// Steps S3, S4 (reader only, when `available` is given), S5 and S6 of the string parser.
    fileprivate static func checkStringLength(_ n: Int, _ rule: StringRule, available: Int?, offset: Int,
                                              minor: Int, budget: inout Int) throws {
        if n > rule.max { throw FormatError.limitExceeded(field: rule.field, offset: offset, minor: minor) }
        if let available, n > available {
            throw FormatError.malformed(offset: offset, reason: "\(rule.field.rawValue) overruns payload")
        }
        if n < rule.min { throw FormatError.malformed(offset: offset, reason: "\(rule.field.rawValue) empty") }
        if rule.counted {
            if n > budget { throw FormatError.limitExceeded(field: .totalText, offset: offset, minor: minor) }
            budget -= n
        }
    }

    fileprivate static func containsNUL(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return false }
        return memchr(base, 0, bytes.count) != nil
    }

    /// The pinned whitespace set W (spec 6.2): 26 scalars.
    static func isPinnedWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200B, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// The non-blank predicate for group names (spec 6.2). The add-group UI must use this too.
    static func isNonBlankName(_ name: String) -> Bool {
        name.unicodeScalars.contains { !isPinnedWhitespace($0) }
    }

    /// Validates a date value (spec 6.3) and returns it canonicalized (any zero becomes +0.0).
    fileprivate static func checkDate(_ v: Double, field: Field, offset: Int) throws -> Double {
        guard v.isFinite, v >= Limits.minDate, v <= Limits.maxDate else {
            throw FormatError.invalidDate(field: field, offset: offset)
        }
        return v == 0 ? 0.0 : v
    }

    /// Writer-side string check: same length/budget rules as the reader, plus the NUL rule.
    /// Swift Strings are always well-formed UTF-8, so no UTF-8 check is needed here.
    fileprivate static func checkString(_ s: String, _ rule: StringRule, offset: Int, budget: inout Int) throws -> Int {
        let n = s.utf8.count
        try checkStringLength(n, rule, available: nil, offset: offset, minor: formatMinor, budget: &budget)
        if !rule.allowNUL && s.utf8.contains(0) {
            throw FormatError.invalidText(field: rule.field, offset: offset)
        }
        return n
    }

    fileprivate static func checkImageCount(_ m: Int, offset: Int, minor: Int) throws {
        if m < 1 { throw FormatError.malformed(offset: offset, reason: "ITEM has no image bytes") }
        if m > Limits.maxImageBytes { throw FormatError.limitExceeded(field: .image, offset: offset, minor: minor) }
    }

    fileprivate static func crc32(_ seed: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        // Never pass a nil pointer or an empty piece (zlib returns 0 for a null buffer).
        guard let base = bytes.baseAddress, bytes.count > 0 else { return seed }
        var crc = seed
        var offset = 0
        while offset < bytes.count {
            let n = Swift.min(bytes.count - offset, pieceBytes)
            crc = UInt32(truncatingIfNeeded: crc32_z(UInt(crc), (base + offset).assumingMemoryBound(to: UInt8.self), n))
            offset += n
        }
        return crc
    }

    /// The default sOFT value: "PictureTrack/<CFBundleShortVersionString> (<CFBundleVersion>)", or "PictureTrack".
    static var defaultSoftware: String {
        let info = Bundle.main.infoDictionary
        if let version = info?["CFBundleShortVersionString"] as? String,
           let build = info?["CFBundleVersion"] as? String,
           !version.isEmpty, !build.isEmpty {
            let candidate = "PictureTrack/\(version) (\(build))"
            if candidate.utf8.count <= Limits.maxSoftwareBytes, !candidate.utf8.contains(0) {
                return candidate
            }
        }
        return "PictureTrack"
    }

    /// W1 ordering: ascending by (dateCreated, originalID UTF-8 bytes). Use with a stable sort.
    static func exportOrder(_ lhs: ItemMetadata, _ rhs: ItemMetadata) -> Bool {
        let a = lhs.dateCreated.timeIntervalSinceReferenceDate
        let b = rhs.dateCreated.timeIntervalSinceReferenceDate
        if a != b { return a < b }
        return lhs.originalID.utf8.lexicographicallyPrecedes(rhs.originalID.utf8)
    }

    // MARK: - Preflight (spec W0)

    /// Validates an export with the same rules the reader enforces, before any file exists.
    /// Returns the exact archive size the `Writer` will produce for these inputs.
    @discardableResult
    static func preflight(group: GroupMetadata, items: [PreflightItem],
                          software: String? = CollectionArchiveFormat.defaultSoftware) throws -> Int {
        var budget = Limits.maxTotalText
        let headLength = try checkedHeadPayloadLength(group: group, itemCount: items.count, budget: &budget)
        var size = 16 + 12 + headLength
        if let software {
            size += 12 + (try checkSoftware(software, offset: size))
        }
        for item in items {
            let length = try checkedItemPayloadLength(item.metadata, imageByteCount: item.imageByteCount,
                                                      offset: size, budget: &budget)
            size += 12 + length
            if size > Limits.maxArchiveBytes { throw FormatError.tooLarge }
        }
        size += 12
        if size > Limits.maxArchiveBytes { throw FormatError.tooLarge }
        return size
    }

    /// Throws `insufficientSpace` when `required` bytes do not fit on the volume holding `url`.
    /// `available` overrides the volume query (for tests). An unknown capacity does not throw.
    static func checkFreeSpace(required: Int, at url: URL, available: Int64? = nil) throws {
        var capacity = available
        if capacity == nil {
            capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
        if let capacity, Int64(required) > capacity {
            throw FormatError.insufficientSpace(required: required, available: Int(capacity))
        }
    }

    fileprivate static func checkedHeadPayloadLength(group: GroupMetadata, itemCount: Int, budget: inout Int) throws -> Int {
        let offset = 16
        if itemCount < 0 || itemCount > Limits.maxItems {
            throw FormatError.limitExceeded(field: .itemCount, offset: offset, minor: formatMinor)
        }
        _ = try checkDate(group.exportedAt.timeIntervalSinceReferenceDate, field: .exportedAt, offset: offset)
        let a = try checkString(group.originalID, groupIDRule, offset: offset, budget: &budget)
        let b = try checkString(group.name, nameRule, offset: offset, budget: &budget)
        let c = try checkString(group.icon, iconRule, offset: offset, budget: &budget)
        if !isNonBlankName(group.name) { throw FormatError.invalidGroupName(offset: offset) }
        return 24 + a + b + c
    }

    fileprivate static func checkSoftware(_ software: String, offset: Int) throws -> Int {
        var unused = 0
        return try checkString(software, softwareRule, offset: offset, budget: &unused)
    }

    fileprivate static func checkedItemPayloadLength(_ item: ItemMetadata, imageByteCount: Int, offset: Int,
                                                     budget: inout Int) throws -> Int {
        _ = try checkDate(item.dateCreated.timeIntervalSinceReferenceDate, field: .dateCreated, offset: offset)
        let a = try checkString(item.originalID, itemIDRule, offset: offset, budget: &budget)
        let n = try checkString(item.notes, notesRule, offset: offset, budget: &budget)
        try checkImageCount(imageByteCount, offset: offset, minor: formatMinor)
        return 16 + a + n + imageByteCount
    }

    // MARK: - Reader (spec section 9)

    /// Decodes and fully validates an archive. `data` may be a slice with a nonzero startIndex
    /// (for example a mapped file); image slices share its storage. Pure: no I/O.
    /// `progress(verified, total)` is called with monotonically increasing byte counts and
    /// ends at `total`. Throws `CancellationError` when the current task is cancelled.
    static func read(_ data: Data, progress: ((_ verified: Int, _ total: Int) -> Void)? = nil) throws -> Archive {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Archive in
            var parser = Parser(data: data, raw: raw, progress: progress)
            return try parser.run()
        }
    }

    /// Runs only R1 to R4 (signature, length 16, preamble CRC, major) on the first bytes of a
    /// file and returns the stored minor. For cheap identification (for example in a FileDocument).
    @discardableResult
    static func checkPreamble(_ data: Data) throws -> Int {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Int in
            var parser = Parser(data: data, raw: raw, progress: nil)
            return try parser.preamble().minor
        }
    }

    /// Maps a file read-only (spec 11.1 I2/I3): size gate first, 0 bytes gives an empty Data
    /// without calling mmap, and a failed mmap throws `cannotMapFile` (never a heap read).
    static func mapForReading(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let size = Int64(info.st_size)
        if size > Int64(Limits.maxArchiveBytes) { throw FormatError.tooLarge }
        if size <= 0 { return Data() }
        let count = Int(size)
        guard let pointer = mmap(nil, count, PROT_READ, MAP_PRIVATE, fd, 0),
              pointer != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw FormatError.cannotMapFile(errno: errno)
        }
        _ = madvise(pointer, count, MADV_SEQUENTIAL)
        return Data(bytesNoCopy: pointer, count: count, deallocator: .unmap)
    }

    private struct Parser {
        enum State { case expectHead, archiveScope, itemScope }

        let data: Data
        let raw: UnsafeRawBufferPointer
        let size: Int
        let base: Int
        let progress: ((Int, Int) -> Void)?
        var lastReported = 0
        var minor = 0
        var textBudget = Limits.maxTotalText

        init(data: Data, raw: UnsafeRawBufferPointer, progress: ((Int, Int) -> Void)?) {
            self.data = data
            self.raw = raw
            self.size = raw.count
            self.base = data.startIndex
            self.progress = progress
        }

        // Callers guarantee o + width <= size before every load.
        func u16(_ o: Int) -> UInt16 { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
        func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
        func u64(_ o: Int) -> UInt64 { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }

        func bytesEqual(at offset: Int, _ expected: [UInt8], count: Int) -> Bool {
            guard offset >= 0, count <= expected.count, count <= size - offset else { return false }
            for i in 0..<count where raw[offset + i] != expected[i] { return false }
            return true
        }

        static func isLetter(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }

        mutating func report(_ verified: Int) {
            guard let progress, verified > lastReported else { return }
            if verified - lastReported >= CollectionArchiveFormat.pieceBytes || verified == size {
                lastReported = verified
                progress(verified, size)
            }
        }

        /// R1 to R4. Returns the stored preamble CRC (the chain seed) and the minor.
        mutating func preamble() throws -> (crc: UInt32, minor: Int) {
            let sig = CollectionArchiveFormat.signature
            // R1. Signature.
            if !(size >= 8 && bytesEqual(at: 0, sig, count: 8)) {
                if size >= 1 && size < 8 && bytesEqual(at: 0, sig, count: size) {
                    throw FormatError.truncated(offset: 0)
                }
                for k in 1...3 where bytesEqual(at: k, [0x50, 0x54, 0x43], count: 3) {
                    throw FormatError.textModeDamaged
                }
                let limit = Swift.min(size, 64)
                var i = 0
                if limit >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF { i = 3 }
                while i < limit, raw[i] == 0x09 || raw[i] == 0x0A || raw[i] == 0x0D || raw[i] == 0x20 { i += 1 }
                if i < limit && raw[i] == 0x7B { throw FormatError.legacyFormat }
                throw FormatError.notAnArchive
            }
            // R2.
            if size < 16 { throw FormatError.truncated(offset: 0) }
            // R3. Preamble CRC before acting on the version.
            let stored = u32(12)
            let computed = CollectionArchiveFormat.crc32(0, UnsafeRawBufferPointer(rebasing: raw[0..<12]))
            if computed != stored { throw FormatError.corrupted(offset: 0) }
            // R4.
            let major = Int(u16(8))
            let minor = Int(u16(10))
            if major != CollectionArchiveFormat.formatMajor {
                throw FormatError.unsupportedVersion(major: major, minor: minor)
            }
            return (stored, minor)
        }

        mutating func run() throws -> Archive {
            let (seed, fileMinor) = try preamble()
            minor = fileMinor
            // R5.
            if size < Limits.minArchiveBytes { throw FormatError.truncated(offset: 0) }
            if size > Limits.maxArchiveBytes { throw FormatError.tooLarge }
            // R6. Fast end check (necessary only; R8 is authoritative).
            if !bytesEqual(at: size - 12, CollectionArchiveFormat.endMarker, count: 8) {
                throw FormatError.truncated(offset: size - 12)
            }
            report(16)

            // R7.
            var pos = 16
            var crc = seed
            var state = State.expectHead
            var chunks = 0
            var itemCount = 0
            var items: [Item] = []
            var group: GroupMetadata?
            var seenSOFT = false

            // R8. At most maxChunks + 1 iterations; every iteration advances pos by >= 12.
            while true {
                let rem = size - pos
                if rem < 12 { throw FormatError.truncated(offset: pos) }
                let length = Int(u32(pos))
                let t0 = raw[pos + 4], t1 = raw[pos + 5], t2 = raw[pos + 6], t3 = raw[pos + 7]
                guard Self.isLetter(t0), Self.isLetter(t1), Self.isLetter(t2), Self.isLetter(t3) else {
                    throw FormatError.corrupted(offset: pos)
                }
                if length > Limits.maxChunkPayload { throw FormatError.corrupted(offset: pos) }
                if length > rem - 12 { throw FormatError.truncated(offset: pos) }
                chunks += 1
                if chunks > Limits.maxChunks {
                    throw FormatError.limitExceeded(field: .chunkCount, offset: pos, minor: minor)
                }
                let next = try chainedCRC(seed: crc, start: pos, count: 8 + length)
                if next != u32(pos + 8 + length) { throw FormatError.corrupted(offset: pos) }
                crc = next
                report(pos + 12 + length)

                let type = u32(pos + 4)
                var c = pos + 8
                let e = pos + 8 + length

                if state == .expectHead && type != CollectionArchiveFormat.typeHEAD {
                    throw FormatError.malformed(offset: pos, reason: "HEAD must be first")
                }
                let isCritical = t0 >= 0x41 && t0 <= 0x5A
                if isCritical && type != CollectionArchiveFormat.typeHEAD
                    && type != CollectionArchiveFormat.typeITEM && type != CollectionArchiveFormat.typeTAIL {
                    let name = String(String.UnicodeScalarView([t0, t1, t2, t3].map { Unicode.Scalar($0) }))
                    throw FormatError.requiresNewerVersion(type: name, minor: minor, offset: pos)
                }

                switch type {
                case CollectionArchiveFormat.typeHEAD:
                    if state != .expectHead { throw FormatError.malformed(offset: pos, reason: "duplicate HEAD") }
                    // H1, H2.
                    guard 4 <= e - c else { throw FormatError.malformed(offset: pos, reason: "HEAD too short") }
                    let declared = Int(u32(c))
                    c += 4
                    if declared > Limits.maxItems {
                        throw FormatError.limitExceeded(field: .itemCount, offset: pos, minor: minor)
                    }
                    // H3 to H6.
                    let exportedAt = try date(.exportedAt, &c, e, chunk: pos)
                    let groupID = try string(CollectionArchiveFormat.groupIDRule, &c, e, chunk: pos)
                    let name = try string(CollectionArchiveFormat.nameRule, &c, e, chunk: pos)
                    let icon = try string(CollectionArchiveFormat.iconRule, &c, e, chunk: pos)
                    // H7, H8.
                    if c != e { throw FormatError.malformed(offset: pos, reason: "HEAD has trailing bytes") }
                    if !CollectionArchiveFormat.isNonBlankName(name) { throw FormatError.invalidGroupName(offset: pos) }
                    itemCount = declared
                    // Each ITEM chunk is at least 30 bytes, so this never over-reserves for a tiny file.
                    items.reserveCapacity(Swift.min(declared, (size - (pos + 12 + length)) / 30))
                    group = GroupMetadata(originalID: groupID, name: name, icon: icon, exportedAt: exportedAt)
                    state = .archiveScope

                case CollectionArchiveFormat.typeITEM:
                    if items.count == itemCount {
                        throw FormatError.malformed(offset: pos, reason: "more ITEM chunks than itemCount")
                    }
                    // I1 to I3.
                    let dateCreated = try date(.dateCreated, &c, e, chunk: pos)
                    let itemID = try string(CollectionArchiveFormat.itemIDRule, &c, e, chunk: pos)
                    let notes = try string(CollectionArchiveFormat.notesRule, &c, e, chunk: pos)
                    // I4 to I6. The image is every remaining payload byte; zero-copy slice.
                    try CollectionArchiveFormat.checkImageCount(e - c, offset: pos, minor: minor)
                    let image = data[(base + c)..<(base + e)]
                    items.append(Item(metadata: ItemMetadata(originalID: itemID, notes: notes, dateCreated: dateCreated),
                                      imageData: image))
                    state = .itemScope

                case CollectionArchiveFormat.typeTAIL:
                    if length != 0 { throw FormatError.malformed(offset: pos, reason: "TAIL not empty") }
                    if items.count != itemCount {
                        throw FormatError.malformed(offset: pos, reason: "fewer ITEM chunks than itemCount")
                    }
                    if pos + 12 != size { throw FormatError.trailingData(offset: pos + 12) }
                    guard let group else { throw FormatError.malformed(offset: pos, reason: "HEAD missing") }
                    report(size)
                    return Archive(formatMinor: minor, group: group, items: items)

                case CollectionArchiveFormat.typeSOFT:
                    if state != .archiveScope || seenSOFT {
                        throw FormatError.malformed(offset: pos, reason: "sOFT misplaced")
                    }
                    if length > Limits.maxSoftwareBytes {
                        throw FormatError.limitExceeded(field: .software, offset: pos, minor: minor)
                    }
                    if length < 1 { throw FormatError.malformed(offset: pos, reason: "sOFT empty") }
                    let payload = UnsafeRawBufferPointer(rebasing: raw[c..<e])
                    if CollectionArchiveFormat.containsNUL(payload) || !Self.isWellFormedUTF8(payload) {
                        throw FormatError.invalidText(field: .software, offset: pos)
                    }
                    seenSOFT = true

                default:
                    break // Unknown ancillary chunk: CRC verified above; never interpreted.
                }

                pos += 12 + length
            }
        }

        /// R8 g: CRC of [start, start+count) seeded with `seed`, in pieces of at most 8 MiB,
        /// checking cancellation and reporting progress between pieces.
        mutating func chainedCRC(seed: UInt32, start: Int, count: Int) throws -> UInt32 {
            guard let basePointer = raw.baseAddress else { throw FormatError.truncated(offset: start) }
            var crc = seed
            var offset = start
            let end = start + count
            while offset < end {
                let n = Swift.min(end - offset, CollectionArchiveFormat.pieceBytes)
                crc = UInt32(truncatingIfNeeded: crc32_z(UInt(crc), (basePointer + offset).assumingMemoryBound(to: UInt8.self), n))
                offset += n
                if Task.isCancelled { throw CancellationError() }
                if offset < end { report(offset) }
            }
            return crc
        }

        static func isWellFormedUTF8(_ bytes: UnsafeRawBufferPointer) -> Bool {
            bytes.withMemoryRebound(to: UInt8.self) { String(validating: $0, as: UTF8.self) != nil }
        }

        /// The str parser, S1 to S9.
        mutating func string(_ rule: StringRule, _ c: inout Int, _ e: Int, chunk pos: Int) throws -> String {
            guard 4 <= e - c else {
                throw FormatError.malformed(offset: pos, reason: "\(rule.field.rawValue) length missing")
            }
            let n = Int(u32(c))
            c += 4
            try CollectionArchiveFormat.checkStringLength(n, rule, available: e - c, offset: pos, minor: minor,
                                                          budget: &textBudget)
            let bytes = UnsafeRawBufferPointer(rebasing: raw[c..<(c + n)])
            if !rule.allowNUL && CollectionArchiveFormat.containsNUL(bytes) {
                throw FormatError.invalidText(field: rule.field, offset: pos)
            }
            let value: String? = bytes.withMemoryRebound(to: UInt8.self) { String(validating: $0, as: UTF8.self) }
            guard let value else { throw FormatError.invalidText(field: rule.field, offset: pos) }
            c += n
            return value
        }

        /// The date parser, D1 to D4.
        func date(_ field: Field, _ c: inout Int, _ e: Int, chunk pos: Int) throws -> Date {
            guard 8 <= e - c else { throw FormatError.malformed(offset: pos, reason: "\(field.rawValue) missing") }
            let bits = u64(c)
            c += 8
            let v = bits == CollectionArchiveFormat.negativeZeroBits ? 0.0 : Double(bitPattern: bits)
            return Date(timeIntervalSinceReferenceDate: try CollectionArchiveFormat.checkDate(v, field: field, offset: pos))
        }
    }

    // MARK: - Writer (spec section 10)

    /// Streams a conformant archive to a new file, strictly sequentially (never seeks).
    ///
    /// The file at `url` must not exist yet (it is created with O_EXCL). Items are appended in the order
    /// given (sort them with `exportOrder` first for deterministic output). The writer validates
    /// everything with the reader's rules and enforces `itemCount`. It never retains an image after
    /// `append` returns: images of 64 KiB or more are written straight from the caller's Data in 8 MiB
    /// slices, and smaller pieces (chunk headers, CRCs, small images) are coalesced in a buffer that is
    /// flushed at 1 MiB. After any thrown error the writer is closed and unusable, and the caller deletes
    /// the partial file (an `init` failure removes the file itself).
    final class Writer {
        private enum State { case open, finished, failed }

        /// Bytes produced so far (everything handed to the file, including buffered bytes).
        private(set) var bytesWritten = 0
        /// Items appended so far.
        private(set) var appendedItemCount = 0
        let declaredItemCount: Int

        private let handle: FileHandle
        private var state = State.open
        private var crc: UInt32 = 0
        /// 16 + sum over emitted chunks of (12 + L), computed from the lengths actually used.
        private var framedBytes = 16
        private var textBudget = Limits.maxTotalText
        private var pending = Data()
        private static let directWriteThreshold = 64 << 10
        private static let flushThreshold = 1 << 20

        #if DEBUG
        private let url: URL
        private let group: GroupMetadata
        private var debugItems: [(ItemMetadata, UInt32)] = []
        #endif

        /// - Parameter software: the sOFT payload. Pass nil only to produce reader-valid,
        ///   non-writer-conformant files without sOFT (test vector C).
        init(url: URL, group: GroupMetadata, itemCount: Int,
             software: String? = CollectionArchiveFormat.defaultSoftware) throws {
            // W0: validate everything before the file exists.
            var budget = Limits.maxTotalText
            let headLength = try checkedHeadPayloadLength(group: group, itemCount: itemCount, budget: &budget)
            let softwareLength = try software.map { try checkSoftware($0, offset: 16 + 12 + headLength) }
            let exportedBits = try checkDate(group.exportedAt.timeIntervalSinceReferenceDate,
                                             field: .exportedAt, offset: 16).bitPattern
            declaredItemCount = itemCount
            textBudget = budget

            var head = Data(capacity: 12 + headLength)
            Self.appendU32(&head, UInt32(headLength))
            Self.appendU32(&head, typeHEAD)
            Self.appendU32(&head, UInt32(itemCount))
            Self.appendU64(&head, exportedBits)
            Self.appendString(&head, group.originalID)
            Self.appendString(&head, group.name)
            Self.appendString(&head, group.icon)

            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            #if DEBUG
            self.url = url
            self.group = group
            #endif

            do {
                // W4. Preamble.
                var preamble = Data(CollectionArchiveFormat.signature)
                preamble.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
                try emit(preamble)
                emitCRC()
                // W5. HEAD.
                try emit(head)
                emitCRC()
                framedBytes += 12 + headLength
                // W6. sOFT.
                if let software, let softwareLength {
                    var chunk = Data(capacity: 8 + softwareLength)
                    Self.appendU32(&chunk, UInt32(softwareLength))
                    Self.appendU32(&chunk, typeSOFT)
                    chunk.append(contentsOf: software.utf8)
                    try emit(chunk)
                    emitCRC()
                    framedBytes += 12 + softwareLength
                }
            } catch {
                fail()              // closes the handle once and marks the writer failed (deinit won't re-close)
                unlink(url.path)
                throw error
            }
        }

        deinit {
            if state == .open { try? handle.close() }
        }

        /// W7. Appends one item. `imageData` is read in 8 MiB slices and not retained.
        func append(_ metadata: ItemMetadata, imageData: Data) throws {
            guard state == .open else { throw FormatError.writerNotOpen }
            do {
                try Task.checkCancellation()
                if appendedItemCount >= declaredItemCount {
                    throw FormatError.itemCountMismatch(declared: declaredItemCount, actual: appendedItemCount + 1)
                }
                let offset = framedBytes
                let length = try checkedItemPayloadLength(metadata, imageByteCount: imageData.count, offset: offset,
                                                          budget: &textBudget)
                // The finished file must stay within MAX_ARCHIVE_BYTES (this chunk plus TAIL).
                if length > Limits.maxArchiveBytes - offset - 24 { throw FormatError.tooLarge }
                let dateBits = try checkDate(metadata.dateCreated.timeIntervalSinceReferenceDate,
                                             field: .dateCreated, offset: offset).bitPattern

                var prefix = Data(capacity: length - imageData.count + 8)
                Self.appendU32(&prefix, UInt32(length))
                Self.appendU32(&prefix, typeITEM)
                Self.appendU64(&prefix, dateBits)
                Self.appendString(&prefix, metadata.originalID)
                Self.appendString(&prefix, metadata.notes)
                try emit(prefix)

                var start = imageData.startIndex
                while start < imageData.endIndex {
                    let end = start + Swift.min(imageData.endIndex - start, pieceBytes)
                    try emit(imageData[start..<end])
                    start = end
                }
                emitCRC()
                framedBytes += 12 + length
                appendedItemCount += 1

                #if DEBUG
                let imageCRC = imageData.withUnsafeBytes { CollectionArchiveFormat.crc32(0, $0) }
                var canonical = metadata
                canonical.dateCreated = Date(timeIntervalSinceReferenceDate: Double(bitPattern: dateBits))
                debugItems.append((canonical, imageCRC))
                #endif
            } catch {
                fail()
                throw error
            }
        }

        /// W8, W9. Writes TAIL, closes the file and verifies its size.
        func finish() throws {
            guard state == .open else { throw FormatError.writerNotOpen }
            do {
                if appendedItemCount != declaredItemCount {
                    throw FormatError.itemCountMismatch(declared: declaredItemCount, actual: appendedItemCount)
                }
                try emit(Data(CollectionArchiveFormat.endMarker))
                emitCRC()
                framedBytes += 12
                try flushPending()

                var info = stat()
                let statResult = fstat(handle.fileDescriptor, &info)
                let onDisk = statResult == 0 ? Int(info.st_size) : -1
                state = .finished
                try handle.close()
                if bytesWritten != framedBytes {
                    throw FormatError.writeVerificationFailed(expected: framedBytes, actual: bytesWritten)
                }
                if onDisk != bytesWritten {
                    throw FormatError.writeVerificationFailed(expected: bytesWritten, actual: onDisk)
                }
                #if DEBUG
                try selfCheck()
                #endif
            } catch {
                fail()
                throw error
            }
        }

        private func fail() {
            if state == .open { try? handle.close() }
            state = .failed
            pending = Data()
        }

        #if DEBUG
        /// W10. Decodes the output and compares it field by field (dates bit-exact, image CRCs).
        private func selfCheck() throws {
            let archive = try CollectionArchiveFormat.read(try CollectionArchiveFormat.mapForReading(url))
            let exported = archive.group.exportedAt.timeIntervalSinceReferenceDate.bitPattern
            let expected = (group.exportedAt.timeIntervalSinceReferenceDate == 0 ? 0.0
                            : group.exportedAt.timeIntervalSinceReferenceDate).bitPattern
            func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }   // bytes, not canonical equivalence
            var ok = same(archive.group.originalID, group.originalID) && same(archive.group.name, group.name)
                && same(archive.group.icon, group.icon) && exported == expected
                && archive.items.count == debugItems.count
            if ok {
                for (item, (metadata, imageCRC)) in zip(archive.items, debugItems) {
                    let crc = item.imageData.withUnsafeBytes { CollectionArchiveFormat.crc32(0, $0) }
                    if !same(item.metadata.originalID, metadata.originalID) || !same(item.metadata.notes, metadata.notes)
                        || item.metadata.dateCreated.timeIntervalSinceReferenceDate.bitPattern
                            != metadata.dateCreated.timeIntervalSinceReferenceDate.bitPattern
                        || crc != imageCRC {
                        ok = false
                        break
                    }
                }
            }
            debugItems = []
            if !ok { throw FormatError.writeVerificationFailed(expected: bytesWritten, actual: -1) }
        }
        #endif

        /// W3 emit: every byte except CRC fields goes through here.
        private func emit(_ bytes: Data) throws {
            guard !bytes.isEmpty else { return }
            crc = bytes.withUnsafeBytes { CollectionArchiveFormat.crc32(crc, $0) }
            if bytes.count >= Self.directWriteThreshold {
                try flushPending()
                try handle.write(contentsOf: bytes)
            } else {
                pending.append(bytes)
                if pending.count >= Self.flushThreshold { try flushPending() }
            }
            bytesWritten += bytes.count
        }

        /// W3 emitCRC: writes the running CRC; never feeds it back into the CRC.
        private func emitCRC() {
            Self.appendU32(&pending, crc)
            bytesWritten += 4
        }

        private func flushPending() throws {
            guard !pending.isEmpty else { return }
            try handle.write(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
        }

        private static func appendU32(_ data: inout Data, _ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        private static func appendU64(_ data: inout Data, _ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        /// str: u32 byte count, then the UTF-8 bytes (lengths were validated by the caller).
        private static func appendString(_ data: inout Data, _ string: String) {
            appendU32(&data, UInt32(string.utf8.count))
            data.append(contentsOf: string.utf8)
        }
    }
}

@available(*, unavailable)
extension CollectionArchiveFormat.Writer: Sendable {}
