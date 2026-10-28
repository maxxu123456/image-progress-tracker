// Shared test support: raw archive builder with a correct CRC chain, a byte-level
// "CRC fixer", vectors from spec section 13, and error classification.
import Foundation
import zlib

typealias F = CollectionArchiveFormat
typealias FE = CollectionArchiveFormat.FormatError

// MARK: Bytes

func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
func rd32(_ d: [UInt8], _ o: Int) -> UInt32 {
    UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
}
func put32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0..<4 { d[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) } }

func zcrc<C: ContiguousBytes>(_ seed: UInt32, _ bytes: C) -> UInt32 {
    bytes.withUnsafeBytes { raw -> UInt32 in
        guard let base = raw.baseAddress, raw.count > 0 else { return seed }
        var crc = seed
        var off = 0
        while off < raw.count {
            let n = min(raw.count - off, 8 << 20)
            crc = UInt32(truncatingIfNeeded: crc32_z(UInt(crc), (base + off).assumingMemoryBound(to: UInt8.self), n))
            off += n
        }
        return crc
    }
}

/// Parses spec-style hex dumps ("0000: 89 50 ...").
func hex(_ text: String) -> [UInt8] {
    var out: [UInt8] = []
    for line in text.split(separator: "\n") {
        var body = Substring(line)
        if let colon = body.firstIndex(of: ":") { body = body[body.index(after: colon)...] }
        for tok in body.split(separator: " ") where !tok.isEmpty {
            out.append(UInt8(tok, radix: 16)!)
        }
    }
    return out
}

let SIG: [UInt8] = [0x89, 0x50, 0x54, 0x43, 0x0D, 0x0A, 0x1A, 0x0A]
let TAIL_MARK: [UInt8] = [0, 0, 0, 0, 0x54, 0x41, 0x49, 0x4C]

func bits(_ d: Double) -> UInt64 { d.bitPattern }
func ubytes(_ s: String) -> [UInt8] { Array(s.utf8) }

// MARK: Raw builder (CRC chain computed correctly)

struct RawChunk {
    var type: [UInt8]
    var payload: Data
    var length: UInt32?
    init(_ type: String, _ payload: Data, length: UInt32? = nil) {
        self.type = Array(type.utf8); self.payload = payload; self.length = length
    }
    init(typeBytes: [UInt8], _ payload: Data, length: UInt32? = nil) {
        self.type = typeBytes; self.payload = payload; self.length = length
    }
}

func strField(_ b: [UInt8]) -> Data { Data(le32(UInt32(b.count)) + b) }

func headPayload(count: UInt32, date: UInt64, gid: [UInt8], name: [UInt8], icon: [UInt8]) -> Data {
    var d = Data(le32(count) + le64(date))
    d.append(strField(gid)); d.append(strField(name)); d.append(strField(icon))
    return d
}

func itemPayload(date: UInt64, id: [UInt8], notes: [UInt8], image: [UInt8]) -> Data {
    var d = Data(le64(date))
    d.append(strField(id)); d.append(strField(notes)); d.append(contentsOf: image)
    return d
}

func buildArchive(major: UInt16 = 1, minor: UInt16 = 0, chunks: [RawChunk], trailing: [UInt8] = []) -> Data {
    var out = Data(SIG + le16(major) + le16(minor))
    var crc = zcrc(0, out)
    out.append(contentsOf: le32(crc))
    for ch in chunks {
        let hdr = le32(ch.length ?? UInt32(ch.payload.count)) + ch.type
        crc = zcrc(crc, hdr)
        crc = zcrc(crc, ch.payload)
        out.append(contentsOf: hdr)
        out.append(ch.payload)
        out.append(contentsOf: le32(crc))
    }
    out.append(contentsOf: trailing)
    return out
}

let GA_ID = ubytes("00000000-0000-4000-8000-000000000001")
let IT_ID = ubytes("00000000-0000-4000-8000-000000000002")
let SOFT10 = ubytes("PictureTrack/1.0 (1)")
let EXPORTED_BITS = bits(815000000.5)
let ITEM_BITS = bits(815000000.25)

func stdHead(count: UInt32 = 1, date: UInt64 = EXPORTED_BITS, gid: [UInt8] = GA_ID, name: [UInt8] = ubytes("Run"),
             icon: [UInt8] = ubytes("figure.run")) -> RawChunk {
    RawChunk("HEAD", headPayload(count: count, date: date, gid: gid, name: name, icon: icon))
}
func stdItem(date: UInt64 = ITEM_BITS, id: [UInt8] = IT_ID, notes: [UInt8] = ubytes("hi é"),
             image: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]) -> RawChunk {
    RawChunk("ITEM", itemPayload(date: date, id: id, notes: notes, image: image))
}
let stdSoft = RawChunk("sOFT", Data(SOFT10))
let tailChunk = RawChunk("TAIL", Data())

/// Byte-level CRC fixer: recomputes the preamble CRC and every chunk CRC while framing stays in bounds.
func fixChain(_ d: inout [UInt8]) {
    guard d.count >= 16 else { return }
    var crc = zcrc(0, Array(d[0..<12]))
    put32(&d, 12, crc)
    var pos = 16
    while d.count - pos >= 12 {
        let L = Int(rd32(d, pos))
        if L > d.count - pos - 12 { break }
        crc = d.withUnsafeBufferPointer { p -> UInt32 in
            UInt32(truncatingIfNeeded: crc32_z(UInt(crc), p.baseAddress! + pos, 8 + L))
        }
        put32(&d, pos + 8 + L, crc)
        pos += 12 + L
    }
}

/// Splits a well-framed archive into its chunk byte ranges (pos, L).
func chunkRanges(_ d: [UInt8]) -> [(pos: Int, len: Int, type: String)] {
    var out: [(Int, Int, String)] = []
    var pos = 16
    while d.count - pos >= 12 {
        let L = Int(rd32(d, pos))
        if L > d.count - pos - 12 { break }
        out.append((pos, L, String(decoding: d[(pos + 4)..<(pos + 8)], as: UTF8.self)))
        pos += 12 + L
    }
    return out
}

// MARK: Vectors (spec section 13)

let VEC_A = hex("""
0000: 89 50 54 43 0d 0a 1a 0a 01 00 00 00 6c 43 d1 c6
0010: 49 00 00 00 48 45 41 44 00 00 00 00 00 00 40 e0
0020: f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30 30
0030: 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30 2d
0040: 30 30 30 30 30 30 30 30 30 30 30 31 03 00 00 00
0050: 52 75 6e 0a 00 00 00 66 69 67 75 72 65 2e 72 75
0060: 6e 3c 10 a1 03 14 00 00 00 73 4f 46 54 50 69 63
0070: 74 75 72 65 54 72 61 63 6b 2f 31 2e 30 20 28 31
0080: 29 35 57 21 de 00 00 00 00 54 41 49 4c 17 c4 ae
0090: df
""")

let VEC_B = hex("""
0000: 89 50 54 43 0d 0a 1a 0a 01 00 00 00 6c 43 d1 c6
0010: 49 00 00 00 48 45 41 44 01 00 00 00 00 00 40 e0
0020: f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30 30
0030: 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30 2d
0040: 30 30 30 30 30 30 30 30 30 30 30 31 03 00 00 00
0050: 52 75 6e 0a 00 00 00 66 69 67 75 72 65 2e 72 75
0060: 6e 32 4c 6d f4 14 00 00 00 73 4f 46 54 50 69 63
0070: 74 75 72 65 54 72 61 63 6b 2f 31 2e 30 20 28 31
0080: 29 0a 27 ea 50 3d 00 00 00 49 54 45 4d 00 00 20
0090: e0 f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30
00a0: 30 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30
00b0: 2d 30 30 30 30 30 30 30 30 30 30 30 32 05 00 00
00c0: 00 68 69 20 c3 a9 ff d8 ff d9 e1 0a de 95 00 00
00d0: 00 00 54 41 49 4c 12 f6 1c d4
""")

let VEC_C = hex("""
0000: 89 50 54 43 0d 0a 1a 0a 01 00 00 00 6c 43 d1 c6
0010: 1b 00 00 00 48 45 41 44 00 00 00 00 00 00 00 00
0020: 00 00 00 00 01 00 00 00 67 01 00 00 00 52 01 00
0030: 00 00 78 24 c5 b7 8b 00 00 00 00 54 41 49 4c 52
0040: 27 24 2c
""")

let VEC_D = hex("""
0000: 89 50 54 43 0d 0a 1a 0a 01 00 01 00 2d 72 ca df
0010: 49 00 00 00 48 45 41 44 01 00 00 00 00 00 40 e0
0020: f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30 30
0030: 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30 2d
0040: 30 30 30 30 30 30 30 30 30 30 30 31 03 00 00 00
0050: 52 75 6e 0a 00 00 00 66 69 67 75 72 65 2e 72 75
0060: 6e cc 98 12 f2 14 00 00 00 73 4f 46 54 50 69 63
0070: 74 75 72 65 54 72 61 63 6b 2f 31 2e 30 20 28 31
0080: 29 a4 f7 54 c6 3d 00 00 00 49 54 45 4d 00 00 20
0090: e0 f4 49 c8 41 24 00 00 00 30 30 30 30 30 30 30
00a0: 30 2d 30 30 30 30 2d 34 30 30 30 2d 38 30 30 30
00b0: 2d 30 30 30 30 30 30 30 30 30 30 30 32 05 00 00
00c0: 00 68 69 20 c3 a9 ff d8 ff d9 fe 50 6f 4b 01 00
00d0: 00 00 74 45 53 54 78 37 32 6a ac 00 00 00 00 54
00e0: 41 49 4c 28 e9 88 a2
""")

/// Vector E as generated by the reference model: D with the chunk type tEST -> XTST and two CRCs replaced.
/// Spec erratum: section 13 lists only byte 0xD2 = 58; turning "tEST" into "XTST" also needs 0xD3 = 54 ('T').
/// The spec's CRC bytes match the reference model's E, which has both edits.
let VEC_E: [UInt8] = {
    var e = VEC_E_SPEC_LITERAL
    e[0xD3] = 0x54
    return e
}()
/// Vector E exactly as section 13's prose describes it (only 0xD2 changed: type "XEST").
let VEC_E_SPEC_LITERAL: [UInt8] = {
    var e = VEC_D
    e[0xD2] = 0x58
    e.replaceSubrange(0xD7...0xDA, with: [0xc8, 0xc0, 0xfe, 0x40])
    e.replaceSubrange(0xE3...0xE6, with: [0xb5, 0xba, 0xf1, 0x1c])
    return e
}()

// MARK: Error classification

func kind(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    guard let e = error as? FE else { return "foreign(\(error))" }
    switch e {
    case .notAnArchive: return "notAnArchive"
    case .legacyFormat: return "legacyFormat"
    case .textModeDamaged: return "textModeDamaged"
    case .truncated: return "truncated"
    case .tooLarge: return "tooLarge"
    case .corrupted: return "corrupted"
    case .unsupportedVersion: return "unsupportedVersion"
    case .requiresNewerVersion: return "requiresNewerVersion"
    case .limitExceeded: return "limitExceeded"
    case .malformed: return "malformed"
    case .invalidText: return "invalidText"
    case .invalidDate: return "invalidDate"
    case .invalidGroupName: return "invalidGroupName"
    case .trailingData: return "trailingData"
    case .itemCountMismatch: return "itemCountMismatch"
    case .writerNotOpen: return "writerNotOpen"
    case .insufficientSpace: return "insufficientSpace"
    case .writeVerificationFailed: return "writeVerificationFailed"
    case .cannotMapFile: return "cannotMapFile"
    }
}

func errOffset(_ error: Error) -> Int? {
    guard let e = error as? FE else { return nil }
    switch e {
    case .truncated(let o), .corrupted(let o), .invalidGroupName(let o), .trailingData(let o): return o
    case .requiresNewerVersion(_, _, let o): return o
    case .limitExceeded(_, let o, _), .invalidText(_, let o), .invalidDate(_, let o): return o
    case .malformed(let o, _): return o
    case .notAnArchive, .legacyFormat, .textModeDamaged, .tooLarge: return 0
    case .unsupportedVersion: return 8
    default: return nil
    }
}

func errField(_ error: Error) -> String? {
    guard let e = error as? FE else { return nil }
    switch e {
    case .limitExceeded(let f, _, _), .invalidText(let f, _), .invalidDate(let f, _): return f.rawValue
    default: return nil
    }
}

enum Outcome {
    case ok(F.Archive)
    case err(Error)
    var kind: String { switch self { case .ok: return "accepted"; case .err(let e): return codec_kind(e) } }
}
func codec_kind(_ e: Error) -> String { kind(e) }

func decode(_ bytes: [UInt8]) -> Outcome { decode(Data(bytes)) }
func decode(_ data: Data) -> Outcome {
    do { return .ok(try F.read(data)) } catch { return .err(error) }
}

// MARK: Memory

func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

func residentSize() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.resident_size) : -1
}

// MARK: Deterministic RNG (SplitMix64)

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
