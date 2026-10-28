// Seeded mutation fuzzer for the PTC v1 reader.
// usage: fuzz <iterations> <seed> <tmpdir> [mode: mixed|raw|struct]
//
// raw    : 1-6 byte-level ops, CRCs NOT fixed. Allowed outcomes: typed error, or acceptance only
//          when the mutated bytes equal the original.
// struct : chunk/field-aware ops (count/length fields set to 0, 1, limit, limit+1, 0xFFFFFFFF ...,
//          chunk insert/delete/duplicate/reorder, type changes, invalid UTF-8, bad dates), then the
//          CRC chain is rebuilt. Allowed outcomes: typed error, or acceptance that passes invariants.
// mixed  : alternates both, plus raw ops followed by the byte-level CRC fixer.
import Foundation

let args = CommandLine.arguments
let iterations = args.count > 1 ? Int(args[1])! : 200_000
let seed = args.count > 2 ? UInt64(args[2])! : 1
let tmp = URL(fileURLWithPath: args.count > 3 ? args[3] : NSTemporaryDirectory()).appendingPathComponent("fuzz-\(getpid())")
let mode = args.count > 4 ? args[4] : "mixed"
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// MARK: Crash capture (async-signal-safe: write(2) of a preallocated buffer)

let inputCap = 1 << 22
let crashBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCap)
var crashLen = 0
var crashIter = 0
let crashPath = strdup(tmp.appendingPathComponent("crash-input.bin").path)!
func setCurrent(_ b: [UInt8], _ i: Int) {
    let n = min(b.count, inputCap)
    b.withUnsafeBufferPointer { crashBuf.update(from: $0.baseAddress!, count: n) }
    crashLen = n
    crashIter = i
}
let handler: @convention(c) (Int32) -> Void = { sig in
    let fd = open(crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 { _ = write(fd, crashBuf, crashLen); close(fd) }
    let msg = "\nFUZZ CRASH: signal caught; input saved to crash-input.bin\n"
    _ = msg.withCString { write(2, $0, strlen($0)) }
    _exit(99)
}
for s in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] { signal(s, handler) }

// MARK: Watchdog (hang detection)

final class Watch: @unchecked Sendable {
    let lock = NSLock()
    var iter = 0
    var started = DispatchTime.now().uptimeNanoseconds
    var maxNanos: UInt64 = 0
    var maxIter = 0
}
let watch = Watch()
let hangLimitNanos: UInt64 = 5_000_000_000
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 0.5)
        watch.lock.lock()
        let elapsed = DispatchTime.now().uptimeNanoseconds - watch.started
        let i = watch.iter
        watch.lock.unlock()
        if elapsed > hangLimitNanos {
            let fd = open(crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 { _ = write(fd, crashBuf, crashLen); close(fd) }
            print("FUZZ HANG: iteration \(i) running for \(elapsed / 1_000_000) ms; input saved")
            exit(98)
        }
    }
}

// MARK: Corpus

func writeVec(_ name: String, _ g: F.GroupMetadata, _ items: [(F.ItemMetadata, Data)], software: String? = "PictureTrack/1.0 (1)") -> [UInt8] {
    let u = tmp.appendingPathComponent(name + ".ptcollection")
    try? FileManager.default.removeItem(at: u)
    let w = try! F.Writer(url: u, group: g, itemCount: items.count, software: software)
    for (m, d) in items { try! w.append(m, imageData: d) }
    try! w.finish()
    return [UInt8](try! Data(contentsOf: u))
}
let D0 = Date(timeIntervalSinceReferenceDate: 1.0)
let two = writeVec("two", F.GroupMetadata(originalID: "00000000-0000-4000-8000-000000000001", name: "Run", icon: "figure.run", exportedAt: D0),
                   [(F.ItemMetadata(originalID: "i1", notes: "a", dateCreated: Date(timeIntervalSinceReferenceDate: 2)), Data([1, 2, 3, 4])),
                    (F.ItemMetadata(originalID: "i2", notes: "b", dateCreated: Date(timeIntervalSinceReferenceDate: 3)), Data([5, 6, 7, 8]))])
let rich: [UInt8] = [UInt8](buildArchive(minor: 1, chunks: [
    stdHead(count: 3, name: ubytes("Lifting 🏋️ log"), icon: ubytes("dumbbell")),
    stdSoft,
    RawChunk("tEST", Data([1, 2, 3])),
    stdItem(id: ubytes("a"), notes: ubytes("first é 日本 \u{0}"), image: [UInt8](repeating: 0xAA, count: 40)),
    RawChunk("cROP", Data(repeating: 0, count: 32)),
    stdItem(date: bits(-0.0), id: ubytes("b"), notes: [], image: [0xFF]),
    stdItem(date: 1, id: ubytes("c"), notes: ubytes("x"), image: [UInt8](repeating: 0x11, count: 300)),
    RawChunk("tAGs", Data(le32(1) + le32(3) + ubytes("leg"))),
    tailChunk,
]))
let legacyJSON = ubytes("{\n  \"exportedAt\" : \"2026-10-27T12:00:00Z\",\n  \"group\" : {\"icon\" : \"figure.run\"}\n}")
let bomJSON: [UInt8] = [0xEF, 0xBB, 0xBF, 0x20, 0x0D, 0x0A] + ubytes("{\"items\":[]}")
let corpus: [[UInt8]] = [VEC_A, VEC_B, VEC_C, VEC_D, VEC_E, two, rich, legacyJSON, bomJSON]
let rejectedSeeds: Set<Int> = [4, 7, 8]
for (i, c) in corpus.enumerated() {
    let r = decode(c)
    let expectAccept = !rejectedSeeds.contains(i)
    if case .ok = r, !expectAccept { fatalError("corpus \(i) unexpectedly accepted") }
    if case .err(let e) = r, expectAccept { fatalError("corpus \(i) rejected: \(e)") }
}

// MARK: Mutations

let interesting32: [UInt32] = [0, 1, 2, 3, 4, 7, 8, 11, 12, 16, 24, 30, 127, 128, 129, 255, 256, 257, 1023, 1024, 1025,
                               100_000, 100_001, 1 << 20, (1 << 20) + 1, 1 << 26, (1 << 26) + 1, 1 << 28, (1 << 28) + 1,
                               335_544_320, 335_544_321, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_FFFE, 0xFFFF_FFFF]
let interestingDates: [UInt64] = [0, 0x8000_0000_0000_0000, 1, 0x7FF0_0000_0000_0000, 0xFFF0_0000_0000_0000, 0x7FF8_0000_0000_0000,
                                  0x7FF0_0000_0000_0001, bits(F.Limits.maxDate), bits(F.Limits.maxDate.nextUp), bits(F.Limits.minDate),
                                  bits(F.Limits.minDate.nextDown), bits(815000000.5), 0xFFFF_FFFF_FFFF_FFFF, bits(Double.greatestFiniteMagnitude)]
let badUTF8: [[UInt8]] = [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82], [0x80], [0xFF], [0xF8, 0x88, 0x80, 0x80, 0x80], [0x00]]
let typeChoices: [String] = ["HEAD", "ITEM", "TAIL", "sOFT", "tEST", "XTST", "ITEm", "SOFT", "soft", "zzzz", "cROP", "tAGs", "IREF"]

extension SplitMix64 {
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func chance(_ p: Int) -> Bool { int(p) == 0 }
}

func rawMutate(_ b: inout [UInt8], _ r: inout SplitMix64) -> String {
    let op = r.int(12)
    switch op {
    case 0: // bit flip
        guard !b.isEmpty else { return "noop" }
        let i = r.int(b.count * 8); b[i >> 3] ^= UInt8(1 << (i & 7)); return "flip"
    case 1: // byte set
        guard !b.isEmpty else { return "noop" }
        b[r.int(b.count)] = r.byte(); return "set"
    case 2: // insert byte(s)
        let n = 1 + r.int(4); let at = r.int(b.count + 1)
        b.insert(contentsOf: (0..<n).map { _ in r.byte() }, at: at); return "insert"
    case 3: // delete byte(s)
        guard !b.isEmpty else { return "noop" }
        let at = r.int(b.count); let n = min(1 + r.int(4), b.count - at)
        b.removeSubrange(at..<(at + n)); return "delete"
    case 4: // overwrite a chunk length field with an interesting value
        let cr = chunkRanges(b)
        guard !cr.isEmpty else { return "noop" }
        let c = cr[r.int(cr.count)]
        put32(&b, c.pos, interesting32[r.int(interesting32.count)]); return "lenfield"
    case 5: // overwrite a random aligned-or-not u32 with an interesting value
        guard b.count >= 4 else { return "noop" }
        put32(&b, r.int(b.count - 3), interesting32[r.int(interesting32.count)]); return "u32"
    case 6: // duplicate a chunk
        let cr = chunkRanges(b)
        guard !cr.isEmpty else { return "noop" }
        let c = cr[r.int(cr.count)]; let bytes = Array(b[c.pos..<(c.pos + 12 + c.len)])
        let dest = cr[r.int(cr.count)].pos
        b.insert(contentsOf: bytes, at: dest); return "dupchunk"
    case 7: // swap two chunks
        let cr = chunkRanges(b)
        guard cr.count >= 2 else { return "noop" }
        var x = r.int(cr.count), y = r.int(cr.count); if x == y { return "noop" }; if x > y { swap(&x, &y) }
        let cx = cr[x], cy = cr[y]
        let rx = cx.pos..<(cx.pos + 12 + cx.len), ry = cy.pos..<(cy.pos + 12 + cy.len)
        b = Array(b[0..<rx.lowerBound]) + Array(b[ry]) + Array(b[rx.upperBound..<ry.lowerBound]) + Array(b[rx]) + Array(b[ry.upperBound...])
        return "swapchunks"
    case 8: // delete a chunk
        let cr = chunkRanges(b)
        guard !cr.isEmpty else { return "noop" }
        let c = cr[r.int(cr.count)]; b.removeSubrange(c.pos..<(c.pos + 12 + c.len)); return "delchunk"
    case 9: // truncate
        b.removeLast(min(b.count, 1 + r.int(32))); return "truncate"
    case 10: // append garbage or a copy
        if r.chance(2) { b += (0..<(1 + r.int(16))).map { _ in r.byte() } } else { b += b.prefix(r.int(b.count + 1)) }
        return "append"
    default: // copy a range over another
        guard b.count >= 2 else { return "noop" }
        let n = 1 + r.int(min(16, b.count - 1)); let src = r.int(b.count - n + 1), dst = r.int(b.count - n + 1)
        let piece = Array(b[src..<(src + n)]); b.replaceSubrange(dst..<(dst + n), with: piece); return "copyrange"
    }
}

/// Parses a well-framed file into (major, minor, chunks); nil if framing is broken.
func parse(_ b: [UInt8]) -> (UInt16, UInt16, [RawChunk])? {
    guard b.count >= 16 else { return nil }
    let major = UInt16(b[8]) | UInt16(b[9]) << 8, minor = UInt16(b[10]) | UInt16(b[11]) << 8
    var out: [RawChunk] = []
    var pos = 16
    while b.count - pos >= 12 {
        let L = Int(rd32(b, pos))
        if L > b.count - pos - 12 { return nil }
        out.append(RawChunk(typeBytes: Array(b[(pos + 4)..<(pos + 8)]), Data(b[(pos + 8)..<(pos + 8 + L)])))
        pos += 12 + L
    }
    return pos == b.count ? (major, minor, out) : nil
}

/// Offsets of str length fields inside a HEAD or ITEM payload (lenient walk).
func strFieldOffsets(_ c: RawChunk) -> [Int] {
    let p = [UInt8](c.payload)
    var offs: [Int] = []
    var at: Int
    var count: Int
    switch String(decoding: c.type, as: UTF8.self) {
    case "HEAD": at = 12; count = 3
    case "ITEM": at = 8; count = 2
    default: return []
    }
    for _ in 0..<count {
        guard at + 4 <= p.count else { break }
        offs.append(at)
        at += 4 + Int(rd32(p, at))
    }
    return offs
}

func structMutate(_ b: [UInt8], _ r: inout SplitMix64) -> ([UInt8], String) {
    guard var (major, minor, chunks) = parse(b) else { return (b, "unparsable") }
    var label = ""
    for _ in 0..<(1 + r.int(3)) {
        guard !chunks.isEmpty else { break }
        let ci = r.int(chunks.count)
        switch r.int(14) {
        case 13: // group name -> blank (W scalars only) or W around one letter
            if let h = chunks.firstIndex(where: { $0.type == ubytes("HEAD") }) {
                let offs = strFieldOffsets(chunks[h])
                if offs.count >= 2 {
                    var p = [UInt8](chunks[h].payload)
                    let o = offs[1], n = Int(rd32(p, o))
                    if o + 4 + n <= p.count {
                        let ws = ["\u{3000}", " ", "\u{2028}\t", "\u{85}\u{A0}\u{1680}", "\u{200B}", "\u{FEFF}", " a "]
                        let nb = ubytes(ws[r.int(ws.count)])
                        p.replaceSubrange((o + 4)..<(o + 4 + n), with: nb)
                        put32(&p, o, UInt32(nb.count))
                        chunks[h].payload = Data(p); label += "blankname,"
                    }
                }
            }
        case 0: // HEAD itemCount
            if let h = chunks.firstIndex(where: { $0.type == ubytes("HEAD") }), chunks[h].payload.count >= 4 {
                var p = [UInt8](chunks[h].payload)
                put32(&p, 0, interesting32[r.int(interesting32.count)] &+ (r.chance(4) ? UInt32(r.int(5)) : 0))
                chunks[h].payload = Data(p); label += "count,"
            }
        case 1: // a str length field
            let offs = strFieldOffsets(chunks[ci])
            if !offs.isEmpty {
                var p = [UInt8](chunks[ci].payload)
                put32(&p, offs[r.int(offs.count)], interesting32[r.int(interesting32.count)])
                chunks[ci].payload = Data(p); label += "strlen,"
            }
        case 2: // a date field
            let t = String(decoding: chunks[ci].type, as: UTF8.self)
            let off = t == "HEAD" ? 4 : (t == "ITEM" ? 0 : -1)
            if off >= 0, chunks[ci].payload.count >= off + 8 {
                var p = [UInt8](chunks[ci].payload)
                let v = r.chance(3) ? r.next() : interestingDates[r.int(interestingDates.count)]
                p.replaceSubrange(off..<(off + 8), with: le64(v))
                chunks[ci].payload = Data(p); label += "date,"
            }
        case 3: // invalid UTF-8 / NUL inside a string
            let offs = strFieldOffsets(chunks[ci])
            if !offs.isEmpty {
                var p = [UInt8](chunks[ci].payload)
                let o = offs[r.int(offs.count)]
                let n = Int(rd32(p, o))
                if n > 0, o + 4 + n <= p.count {
                    let seq = badUTF8[r.int(badUTF8.count)]
                    let at = o + 4 + r.int(n)
                    for (k, x) in seq.enumerated() where at + k < o + 4 + n { p[at + k] = x }
                    chunks[ci].payload = Data(p); label += "utf8,"
                }
            }
        case 4: // payload byte mutation
            if !chunks[ci].payload.isEmpty {
                var p = [UInt8](chunks[ci].payload)
                for _ in 0..<(1 + r.int(3)) { p[r.int(p.count)] = r.byte() }
                chunks[ci].payload = Data(p); label += "payload,"
            }
        case 5: // payload grow/shrink
            var p = [UInt8](chunks[ci].payload)
            if r.chance(2) || p.isEmpty { p.insert(contentsOf: (0..<(1 + r.int(8))).map { _ in r.byte() }, at: r.int(p.count + 1)) }
            else { let at = r.int(p.count); p.removeSubrange(at..<min(p.count, at + 1 + r.int(8))) }
            chunks[ci].payload = Data(p); label += "resize,"
        case 6: // insert a chunk
            let t = typeChoices[r.int(typeChoices.count)]
            let payload: Data
            switch t {
            case "HEAD": payload = stdHead(count: UInt32(r.int(4))).payload
            case "ITEM": payload = stdItem(image: [UInt8](repeating: r.byte(), count: 1 + r.int(8))).payload
            case "sOFT": payload = Data((0..<r.int(300)).map { _ in UInt8(0x41 + r.int(26)) })
            case "TAIL": payload = r.chance(4) ? Data([1]) : Data()
            default: payload = Data((0..<r.int(20)).map { _ in r.byte() })
            }
            chunks.insert(RawChunk(t, payload), at: r.int(chunks.count + 1)); label += "ins:\(t),"
        case 7: // delete a chunk
            chunks.remove(at: ci); label += "del,"
        case 8: // duplicate a chunk
            chunks.insert(chunks[ci], at: r.int(chunks.count + 1)); label += "dup,"
        case 9: // reorder two chunks
            let cj = r.int(chunks.count); chunks.swapAt(ci, cj); label += "swap,"
        case 10: // change a type: random letters, a known type, or a non-letter
            if r.chance(3) { chunks[ci].type = [r.byte(), r.byte(), r.byte(), r.byte()] }
            else if r.chance(2) { chunks[ci].type = ubytes(typeChoices[r.int(typeChoices.count)]) }
            else { let k = r.int(4); chunks[ci].type[k] ^= 0x20 }
            label += "type,"
        case 11: // declared length != payload length
            chunks[ci].length = r.chance(2) ? interesting32[r.int(interesting32.count)] : UInt32(max(0, chunks[ci].payload.count + r.int(9) - 4))
            label += "L,"
        default: // version fields
            if r.chance(4) { major = UInt16(truncatingIfNeeded: r.next()) } else { minor = UInt16(truncatingIfNeeded: r.next()) }
            label += "ver,"
        }
    }
    return ([UInt8](buildArchive(major: major, minor: minor, chunks: chunks)), label)
}

// MARK: Invariants for accepted inputs

var violations = 0
func violation(_ msg: String, _ input: [UInt8], _ i: Int) {
    violations += 1
    if violations <= 10 {
        print("VIOLATION at iteration \(i): \(msg)")
        try? Data(input).write(to: tmp.appendingPathComponent("violation-\(i).bin"))
    }
}

var roundTrips = 0
func checkAccepted(_ a: F.Archive, _ data: Data, _ input: [UInt8], _ i: Int, rng: inout SplitMix64) {
    // Zero copy: every image slice lies within the input buffer.
    data.withUnsafeBytes { p in
        let lo = p.baseAddress!, hi = p.baseAddress! + p.count
        for it in a.items {
            it.imageData.withUnsafeBytes { q in
                if q.count == 0 || q.baseAddress! < lo || q.baseAddress! + q.count > hi { violation("image slice outside input", input, i) }
            }
        }
    }
    // Field invariants the reader promises.
    if !F.isNonBlankName(a.group.name) { violation("blank name accepted", input, i) }
    for it in a.items {
        let t = it.metadata.dateCreated.timeIntervalSinceReferenceDate
        if !t.isFinite || t < F.Limits.minDate || t > F.Limits.maxDate || t.bitPattern == (-0.0).bitPattern { violation("bad date accepted", input, i) }
        if it.metadata.originalID.utf8.isEmpty || it.metadata.originalID.utf8.count > 128 || it.metadata.originalID.utf8.contains(0) { violation("bad itemID accepted", input, i) }
        if it.imageData.count < 1 || it.imageData.count > F.Limits.maxImageBytes { violation("bad image size accepted", input, i) }
    }
    // Determinism: decoding again gives the same result.
    if let b = try? F.read(data) {
        if b.items.count != a.items.count || !zip(a.items, b.items).allSatisfy({ $0.imageData == $1.imageData && $0.metadata == $1.metadata }) { violation("nondeterministic decode", input, i) }
    } else { violation("second decode failed", input, i) }
    // Occasionally: re-encode with the writer and decode again; content must survive.
    if rng.chance(32) {
        roundTrips += 1
        let u = tmp.appendingPathComponent("rt.ptcollection")
        try? FileManager.default.removeItem(at: u)
        do {
            let w = try F.Writer(url: u, group: a.group, itemCount: a.items.count)
            for it in a.items { try w.append(it.metadata, imageData: it.imageData) }
            try w.finish()
            let c = try F.read(try Data(contentsOf: u))
            let same = c.group == a.group && c.items.count == a.items.count
                && zip(a.items, c.items).allSatisfy { $0.imageData == $1.imageData && $0.metadata.originalID.utf8.elementsEqual($1.metadata.originalID.utf8)
                    && $0.metadata.notes.utf8.elementsEqual($1.metadata.notes.utf8)
                    && $0.metadata.dateCreated.timeIntervalSinceReferenceDate.bitPattern == $1.metadata.dateCreated.timeIntervalSinceReferenceDate.bitPattern }
            if !same { violation("writer round trip changed content", input, i) }
        } catch { violation("writer rejected an accepted archive: \(error)", input, i) }
    }
}

// MARK: Main loop

var tally: [String: Int] = [:]
var rawAcceptedNoop = 0, structAccepted = 0, opsCount: [String: Int] = [:]
let t0 = Date()
for i in 0..<iterations {
    var r = SplitMix64(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(i))
    let original = corpus[r.int(corpus.count)]
    var m = original
    let strategy: Int
    switch mode {
    case "raw": strategy = 0
    case "struct": strategy = 1
    default: strategy = r.int(3)
    }
    if strategy == 1 {
        let (out, label) = structMutate(m, &r)
        m = out
        if r.chance(4) { _ = rawMutate(&m, &r); fixChain(&m) }
        opsCount["struct", default: 0] += 1
        _ = label
    } else {
        for _ in 0..<(1 + r.int(6)) { let op = rawMutate(&m, &r); opsCount[op, default: 0] += 1 }
        if strategy == 2 { fixChain(&m); opsCount["fixed", default: 0] += 1 }
    }
    setCurrent(m, i)
    watch.lock.lock(); watch.iter = i; let start = DispatchTime.now().uptimeNanoseconds; watch.started = start; watch.lock.unlock()
    let data = Data(m)
    let outcome = decode(data)
    let dt = DispatchTime.now().uptimeNanoseconds - start
    if dt > watch.maxNanos { watch.maxNanos = dt; watch.maxIter = i }
    switch outcome {
    case .ok(let a):
        tally["accepted", default: 0] += 1
        if strategy == 0 {
            if m == original { rawAcceptedNoop += 1 } else { violation("raw mutation accepted but bytes differ from original", m, i) }
        } else {
            structAccepted += 1
            checkAccepted(a, data, m, i, rng: &r)
        }
    case .err(let e):
        let k = kind(e)
        tally[k, default: 0] += 1
        if k.hasPrefix("foreign") || k == "cancelled" { violation("untyped error \(e)", m, i) }
    }
}
let elapsed = Date().timeIntervalSince(t0)
print("FUZZ mode=\(mode) seed=\(seed) iterations=\(iterations) elapsed=\(String(format: "%.1f", elapsed))s rate=\(Int(Double(iterations) / elapsed))/s")
print("outcomes: " + tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
print("raw acceptances (all must be exact no-ops): \(rawAcceptedNoop); structure-aware acceptances: \(structAccepted); writer round trips: \(roundTrips)")
print("ops: " + opsCount.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
print(String(format: "slowest decode: %.3f ms (iteration %d)", Double(watch.maxNanos) / 1e6, watch.maxIter))
print("violations: \(violations)")
try? FileManager.default.removeItem(at: tmp.appendingPathComponent("rt.ptcollection"))
exit(violations == 0 ? 0 : 1)
