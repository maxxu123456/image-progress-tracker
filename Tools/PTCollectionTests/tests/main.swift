// PTC v1 codec test suite (macOS executable). Build: see run_tests.sh.
import Foundation
import zlib

// MARK: - Mini framework

struct Check { let group: String; let name: String; let passed: Bool; let detail: String }
var checks: [Check] = []
var currentGroup = ""
var groupNotes: [String: [String]] = [:]

func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    checks.append(Check(group: currentGroup, name: name, passed: cond, detail: cond ? "" : detail()))
    if !cond { print("FAIL [\(currentGroup)] \(name): \(detail())") }
}
func note(_ s: String) { groupNotes[currentGroup, default: []].append(s); print("  note: \(s)") }
func group(_ name: String, _ body: () throws -> Void) {
    currentGroup = name
    let t0 = Date()
    print("== \(name)")
    do { try body() } catch { check("group threw", false, "\(error)") }
    print(String(format: "   (%.2f s)", Date().timeIntervalSince(t0)))
}

func expectError(_ name: String, _ data: Data, _ expected: FE) {
    switch decode(data) {
    case .ok: check(name, false, "accepted; expected \(expected)")
    case .err(let e):
        if let fe = e as? FE, fe == expected { check(name, true) } else { check(name, false, "got \(e), expected \(expected)") }
    }
}
func expectKind(_ name: String, _ data: Data, _ k: String, field: String? = nil) {
    switch decode(data) {
    case .ok: check(name, false, "accepted; expected \(k)")
    case .err(let e):
        let ok = kind(e) == k && (field == nil || errField(e) == field)
        check(name, ok, "got \(e), expected \(k) \(field ?? "")")
    }
}
@discardableResult
func expectAccept(_ name: String, _ data: Data) -> F.Archive? {
    switch decode(data) {
    case .ok(let a): check(name, true); return a
    case .err(let e): check(name, false, "rejected: \(e)"); return nil
    }
}

// MARK: - Helpers

let tmpRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
    .appendingPathComponent("ptc-tests-\(getpid())")
try? FileManager.default.removeItem(at: tmpRoot)
try! FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
var tmpCounter = 0
func tmpURL(_ stem: String = "a") -> URL {
    tmpCounter += 1
    return tmpRoot.appendingPathComponent("\(stem)-\(tmpCounter).ptcollection")
}

func D(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t) }
func canonBits(_ d: Date) -> UInt64 { let t = d.timeIntervalSinceReferenceDate; return (t == 0 ? 0.0 : t).bitPattern }
func dbits(_ d: Date) -> UInt64 { d.timeIntervalSinceReferenceDate.bitPattern }

func gm(_ id: String = "00000000-0000-4000-8000-000000000001", _ name: String = "Run", _ icon: String = "figure.run",
        _ t: Double = 815000000.5) -> F.GroupMetadata {
    F.GroupMetadata(originalID: id, name: name, icon: icon, exportedAt: D(t))
}
func im(_ id: String, _ notes: String, _ t: Double) -> F.ItemMetadata {
    F.ItemMetadata(originalID: id, notes: notes, dateCreated: D(t))
}

@discardableResult
func writeFile(_ url: URL, _ g: F.GroupMetadata, _ items: [(F.ItemMetadata, Data)],
               software: String? = "PictureTrack/1.0 (1)") throws -> Int {
    let w = try F.Writer(url: url, group: g, itemCount: items.count, software: software)
    for (m, d) in items { try w.append(m, imageData: d) }
    try w.finish()
    return w.bytesWritten
}
func fileBytes(_ url: URL) -> [UInt8] { [UInt8]((try? Data(contentsOf: url)) ?? Data()) }
func mapped(_ url: URL) -> Data { try! Data(contentsOf: url, options: .alwaysMapped) }

func sameUTF8(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
func metaEqualCanon(_ got: F.ItemMetadata, _ want: F.ItemMetadata) -> Bool {
    sameUTF8(got.originalID, want.originalID) && sameUTF8(got.notes, want.notes)
        && dbits(got.dateCreated) == canonBits(want.dateCreated)
}
func groupEqualCanon(_ got: F.GroupMetadata, _ want: F.GroupMetadata) -> Bool {
    sameUTF8(got.originalID, want.originalID) && sameUTF8(got.name, want.name) && sameUTF8(got.icon, want.icon)
        && dbits(got.exportedAt) == canonBits(want.exportedAt)
}
func archiveDigest(_ a: F.Archive) -> String {
    var s = "minor=\(a.formatMinor)|\(Array(a.group.originalID.utf8))|\(Array(a.group.name.utf8))|\(Array(a.group.icon.utf8))|\(dbits(a.group.exportedAt))"
    for it in a.items {
        s += "|\(Array(it.metadata.originalID.utf8)):\(it.metadata.notes.utf8.count):\(zcrc(0, Data(it.metadata.notes.utf8))):\(dbits(it.metadata.dateCreated)):\(it.imageData.count):\(zcrc(0, it.imageData))"
    }
    return s
}
func posOf(_ chunks: [RawChunk], _ i: Int) -> Int { 16 + chunks[0..<i].reduce(0) { $0 + 12 + $1.payload.count } }
func arch(_ chunks: [RawChunk], minor: UInt16 = 0) -> Data { buildArchive(minor: minor, chunks: chunks) }
func openFDCount() -> Int { (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }

/// Zero-filled sparse file of `size` bytes, mapped read-only.
func sparseZeros(_ size: Int, stem: String) -> (URL, Data) {
    let url = tmpRoot.appendingPathComponent("\(stem)-\(size).bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fd = open(url.path, O_RDWR)
    precondition(fd >= 0 && ftruncate(fd, off_t(size)) == 0)
    close(fd)
    return (url, mapped(url))
}

let T0 = 815000000.5

// MARK: - 1. CRC primitives

group("crc-primitives") {
    check("crc32_z check value 0xCBF43926", zcrc(0, ubytes("123456789")) == 0xCBF43926)
    check("preamble constant CRC 0xC6D1436C", zcrc(0, Array(VEC_A[0..<12])) == 0xC6D1436C)
    let a = ubytes("hello "), b = ubytes("world")
    check("continuation property", zcrc(zcrc(0, a), b) == zcrc(0, a + b))
    // Residue: CRC of a message followed by its own LE CRC is the constant 0x2144DF1C.
    let m = ubytes("any message at all")
    check("residue 0x2144DF1C", zcrc(0, m + le32(zcrc(0, m))) == 0x2144DF1C)
}

// MARK: - 2. Golden vectors: encode

group("golden-encode") {
    let urlA = tmpURL("A")
    try writeFile(urlA, gm(), [])
    check("writer output == vector A (145 bytes)", fileBytes(urlA) == VEC_A, "got \(fileBytes(urlA).count) bytes")
    let urlB = tmpURL("B")
    try writeFile(urlB, gm(), [(im("00000000-0000-4000-8000-000000000002", "hi é", 815000000.25), Data([0xFF, 0xD8, 0xFF, 0xD9]))])
    check("writer output == vector B (218 bytes)", fileBytes(urlB) == VEC_B, "got \(fileBytes(urlB).count) bytes")
    let urlC = tmpURL("C")
    try writeFile(urlC, gm("g", "R", "x", 0.0), [], software: nil)
    check("writer output == vector C (67 bytes, no sOFT)", fileBytes(urlC) == VEC_C, "got \(fileBytes(urlC).count) bytes")
    let urlC2 = tmpURL("C-negzero")
    try writeFile(urlC2, gm("g", "R", "x", -0.0), [], software: nil)
    check("exportedAt -0.0 is written as +0.0 (== vector C)", fileBytes(urlC2) == VEC_C)
    check("preflight size A == 145", (try? F.preflight(group: gm(), items: [], software: "PictureTrack/1.0 (1)")) == 145)
    check("preflight size B == 218", (try? F.preflight(group: gm(), items: [F.PreflightItem(metadata: im("00000000-0000-4000-8000-000000000002", "hi é", 815000000.25), imageByteCount: 4)], software: "PictureTrack/1.0 (1)")) == 218)
    check("preflight size C == 67", (try? F.preflight(group: gm("g", "R", "x", 0.0), items: [], software: nil)) == 67)
    check("vector E built from D matches spec edits", VEC_E.count == 231 && VEC_E[0xD2] == 0x58)
}

// MARK: - 3. Golden vectors: decode

group("golden-decode") {
    func checkB(_ a: F.Archive?, _ label: String, minor: Int) {
        guard let a else { return }
        check("\(label): formatMinor \(minor)", a.formatMinor == minor)
        check("\(label): group fields", a.group.originalID == "00000000-0000-4000-8000-000000000001" && a.group.name == "Run" && a.group.icon == "figure.run")
        check("\(label): exportedAt bit-exact", dbits(a.group.exportedAt) == EXPORTED_BITS)
        check("\(label): 1 item", a.items.count == 1)
        if let it = a.items.first {
            check("\(label): item id", it.metadata.originalID == "00000000-0000-4000-8000-000000000002")
            check("\(label): notes bytes 68 69 20 c3 a9", Array(it.metadata.notes.utf8) == [0x68, 0x69, 0x20, 0xC3, 0xA9])
            check("\(label): dateCreated bit-exact", dbits(it.metadata.dateCreated) == ITEM_BITS)
            check("\(label): image ff d8 ff d9", [UInt8](it.imageData) == [0xFF, 0xD8, 0xFF, 0xD9])
        }
    }
    if let a = expectAccept("A decodes", Data(VEC_A)) {
        check("A: minor 0, 0 items, fields", a.formatMinor == 0 && a.items.isEmpty && a.group.name == "Run" && dbits(a.group.exportedAt) == EXPORTED_BITS)
    }
    checkB(expectAccept("B decodes", Data(VEC_B)), "B", minor: 0)
    if let c = expectAccept("C decodes", Data(VEC_C)) {
        check("C: g/R/x, exportedAt bits 0, 0 items", c.group.originalID == "g" && c.group.name == "R" && c.group.icon == "x" && dbits(c.group.exportedAt) == 0 && c.items.isEmpty)
    }
    let d = expectAccept("D decodes (unknown ancillary tEST, minor 1)", Data(VEC_D))
    checkB(d, "D", minor: 1)
    if let d, let b = try? F.read(Data(VEC_B)) {
        check("D content == B content (except minor)", archiveDigest(d).dropFirst(7) == archiveDigest(b).dropFirst(7))
    }
    expectError("E -> requiresNewerVersion(XTST, 1) at 0xCE", Data(VEC_E), .requiresNewerVersion(type: "XTST", minor: 1, offset: 0xCE))
    expectError("spec-literal E (only 0xD2 edited, type XEST, CRCs for XTST) -> corrupted(0xCE) [spec erratum]", Data(VEC_E_SPEC_LITERAL), .corrupted(offset: 0xCE))
    check("checkPreamble(D) == minor 1", (try? F.checkPreamble(Data(VEC_D))) == 1)
    check("checkPreamble(first 16 bytes of A) == 0", (try? F.checkPreamble(Data(VEC_A.prefix(16)))) == 0)
    check("checkPreamble(legacy JSON) throws legacyFormat", { do { _ = try F.checkPreamble(Data("{}".utf8)); return false } catch { return (error as? FE) == .legacyFormat } }())
}

// MARK: - 4. Non-zero-based input

group("slice-input") {
    for k in [3, 12_345_677] {
        for (label, vec) in [("A", VEC_A), ("B", VEC_B), ("C", VEC_C), ("D", VEC_D), ("E", VEC_E)] {
            var parent = Data(count: k)
            parent.append(contentsOf: vec)
            parent.append(contentsOf: [0xEE, 0xEE, 0xEE])          // junk after the slice end
            let slice = parent[k..<(k + vec.count)]
            check("\(label)@\(k): startIndex == \(k)", slice.startIndex == k)
            let base = decode(vec), sliced = decode(slice)
            switch (base, sliced) {
            case (.ok(let x), .ok(let y)):
                check("\(label)@\(k): identical result", archiveDigest(x) == archiveDigest(y))
                parent.withUnsafeBytes { p in
                    let lo = p.baseAddress!, hi = p.baseAddress! + p.count
                    for it in y.items {
                        it.imageData.withUnsafeBytes { q in
                            check("\(label)@\(k): image slice inside parent buffer (zero copy)",
                                  q.baseAddress! >= lo && q.baseAddress! + q.count <= hi)
                        }
                    }
                }
            case (.err(let x), .err(let y)):
                check("\(label)@\(k): identical error", (x as? FE) == (y as? FE), "\(x) vs \(y)")
            default:
                check("\(label)@\(k): same verdict", false)
            }
        }
    }
}

// MARK: - 5. Round trips

group("round-trip") {
    for n in [0, 1, 3, 1000] {
        let items = (0..<n).map { i in (im("id-\(i)", i % 2 == 0 ? "" : "note \(i)", 800_000_000 + Double(i) * 0.001), Data([UInt8(i & 0xFF)])) }
        let url = tmpURL("rt\(n)")
        let written = try writeFile(url, gm(), items)
        let a = try F.read(mapped(url))
        check("\(n) items: count", a.items.count == n)
        check("\(n) items: all fields bit-exact", zip(a.items, items).allSatisfy { metaEqualCanon($0.metadata, $1.0) && $0.imageData == $1.1 })
        check("\(n) items: bytesWritten == file size", written == fileBytes(url).count)
    }

    // Strings.
    let notes1M = String(repeating: "日", count: 349_525) + "a"            // exactly 1,048,576 bytes
    let stringCases: [(String, String)] = [
        ("empty notes", ""),
        ("notes exactly 1 MiB (multi-byte)", notes1M),
        ("emoji ZWJ/flags", "👨‍👩‍👧‍👦🏳️‍🌈🇯🇵 done ✅"),
        ("combining marks", "e\u{301}\u{302} a\u{308} Z\u{335}\u{336}\u{337}"),
        ("RTL text", "שלום עולם مرحبا بالعالم \u{202E}rtl override"),
        ("embedded U+0000", "before\u{0}after\u{0}"),
        ("leading U+FEFF", "\u{FEFF}starts with BOM"),
        ("CJK", "日本語 中文 한국어 𠜎𠜱"),
        ("long notes 500 KB mixed", String(repeating: "aé日😀", count: 50_000)),
    ]
    let items = stringCases.enumerated().map { (i, c) in (im("é" + String(repeating: "x", count: 125) + "\(i % 10)", c.1, 1000 + Double(i)), Data([0x42, UInt8(i)])) }
    check("notes1M is exactly 1,048,576 bytes", notes1M.utf8.count == 1 << 20)
    let g = gm(String(repeating: "é", count: 64), "Run e\u{301} 名前 👟", "figure.run.circle.fill", T0)
    let url = tmpURL("strings")
    try writeFile(url, g, items)
    let a = try F.read(mapped(url))
    check("group strings preserved byte-exact (no normalization)", groupEqualCanon(a.group, g))
    check("128-byte non-ASCII groupID round-trips", a.group.originalID.utf8.count == 128)
    for (i, c) in stringCases.enumerated() where i < a.items.count {
        check("notes: \(c.0)", metaEqualCanon(a.items[i].metadata, items[i].0) && a.items[i].imageData == items[i].1)
    }
    check("é vs e+U+0301 stay distinct bytes", Array(a.group.name.utf8) != Array("Run é 名前 👟".utf8) && sameUTF8(a.group.name, g.name))

    // Names: each of the 26 W scalars around one letter.
    let w: [UInt32] = Array(0x09...0x0D) + [0x20, 0x85, 0xA0, 0x1680] + Array(0x2000...0x200B) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
    check("W has 26 scalars", w.count == 26)
    var nameOK = 0
    for v in w {
        let s = String(Unicode.Scalar(v)!)
        let name = s + "A" + s
        let u = tmpURL("w")
        do {
            try writeFile(u, gm("g", name, "x"), [])
            let r = try F.read(mapped(u))
            if sameUTF8(r.group.name, name) { nameOK += 1 } else { check("W name U+\(String(v, radix: 16))", false) }
        } catch { check("W name U+\(String(v, radix: 16)) round-trips", false, "\(error)") }
    }
    check("all 26 W-scalar-wrapped names round-trip untrimmed", nameOK == 26)
    check("CharacterSet.whitespacesAndNewlines agrees with W on this host",
          (0...0x10FFFF).allSatisfy { v in
              guard let sc = Unicode.Scalar(UInt32(v)) else { return true }
              return CharacterSet.whitespacesAndNewlines.contains(sc) == F.isPinnedWhitespace(sc)
          })

    // Dates: specials + 100,000 random values in one 100,000-item archive.
    var rng = SplitMix64(seed: 0xDA7E5)
    var dates: [Double] = [0.0, -0.0, 5e-324, -5e-324, 0.1, Date().timeIntervalSinceReferenceDate,
                           F.Limits.minDate, F.Limits.maxDate, Date.distantPast.timeIntervalSinceReferenceDate,
                           Date.distantFuture.timeIntervalSinceReferenceDate, 1e-300, Double.leastNormalMagnitude,
                           F.Limits.maxDate.nextDown, F.Limits.minDate.nextUp, 815000000.123456789]
    let specialCount = dates.count
    while dates.count < 100_000 {
        if dates.count % 2 == 0 {
            dates.append(Double.random(in: F.Limits.minDate...F.Limits.maxDate, using: &rng))
        } else {
            let v = Double(bitPattern: rng.next())
            if v.isFinite && v >= F.Limits.minDate && v <= F.Limits.maxDate { dates.append(v) }
        }
    }
    check("Date() has a sub-second part", dates[5] != dates[5].rounded())
    let big = dates.enumerated().map { (i, t) in (im("i\(i)", "", t), Data([UInt8(truncatingIfNeeded: i)])) }
    let bigURL = tmpURL("100k")
    let t1 = Date()
    try writeFile(bigURL, gm(), big)
    let t2 = Date()
    let bigA = try F.read(mapped(bigURL))
    let t3 = Date()
    note(String(format: "100,000-item archive: %d bytes, write %.2f s, read %.2f s", fileBytes(bigURL).count, t2.timeIntervalSince(t1), t3.timeIntervalSince(t2)))
    check("100,000 items: count", bigA.items.count == 100_000)
    check("100,000 items: dates bit-exact (-0.0 -> +0.0)", zip(bigA.items, big).allSatisfy { dbits($0.metadata.dateCreated) == canonBits($1.0.dateCreated) })
    check("100,000 items: ids and images exact", zip(bigA.items, big).allSatisfy { sameUTF8($0.metadata.originalID, $1.0.originalID) && $0.imageData == $1.1 })
    check("-0.0 decodes with bits 0", dbits(bigA.items[1].metadata.dateCreated) == 0)
    check("5e-324 subnormal bit-exact", dbits(bigA.items[2].metadata.dateCreated) == bits(5e-324))
    check("distantPast/distantFuture bit-exact", dbits(bigA.items[6].metadata.dateCreated) == bits(F.Limits.minDate) && dbits(bigA.items[7].metadata.dateCreated) == bits(F.Limits.maxDate))
    check("Limits equal Date.distantPast/distantFuture", F.Limits.minDate == Date.distantPast.timeIntervalSinceReferenceDate && F.Limits.maxDate == Date.distantFuture.timeIntervalSinceReferenceDate)
    note("\(specialCount) special dates + \(100_000 - specialCount) random")
}

// MARK: - 6. Exhaustive damage

func twoItemVector() -> [UInt8] {
    let u = tmpURL("two")
    try! writeFile(u, gm(t: 1.0) , [(im("i1", "a", 2.0), Data([1, 2, 3, 4])), (im("i2", "b", 3.0), Data([5, 6, 7, 8]))])
    return fileBytes(u)
}
func gm(t: Double) -> F.GroupMetadata { gm("00000000-0000-4000-8000-000000000001", "Run", "figure.run", t) }

func replaceAll(_ b: [UInt8], _ from: [UInt8], _ to: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []; var i = 0
    while i < b.count {
        if i + from.count <= b.count && Array(b[i..<(i + from.count)]) == from { out += to; i += from.count } else { out.append(b[i]); i += 1 }
    }
    return out
}

group("exhaustive-damage") {
    let two = twoItemVector()
    var total = 0
    var tally: [String: Int] = [:]
    var rng = SplitMix64(seed: 42)
    func mustReject(_ label: String, _ b: [UInt8], _ want: String? = nil) {
        total += 1
        switch decode(b) {
        case .ok: check(label, false, "accepted damaged file")
        case .err(let e):
            let k = kind(e)
            tally[k, default: 0] += 1
            if k.hasPrefix("foreign") { check(label, false, "untyped error \(e)") }
            if let want, k != want { check(label, false, "got \(k), want \(want)") }
        }
    }
    for (label, v) in [("A", VEC_A), ("B", VEC_B), ("C", VEC_C), ("D", VEC_D), ("two", two)] {
        let before = checks.filter { !$0.passed }.count
        if case .err(let e) = decode(v) { check("\(label) baseline accepted", false, "\(e)") }
        for i in 0..<(v.count * 8) {
            var m = v; m[i >> 3] ^= UInt8(1 << (i & 7))
            mustReject("\(label) bit flip \(i)", m)
        }
        for k in 0..<v.count { mustReject("\(label) truncate \(k)", Array(v[0..<k])) }
        for k in 1...16 {
            mustReject("\(label) +\(k) zero bytes", v + [UInt8](repeating: 0, count: k))
            mustReject("\(label) +\(k) random bytes", v + (0..<k).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
        mustReject("\(label) file||file", v + v, "trailingData")
        mustReject("\(label) CRLF->LF", replaceAll(v, [0x0D, 0x0A], [0x0A]), "textModeDamaged")
        mustReject("\(label) LF->CRLF", replaceAll(v, [0x0A], [0x0D, 0x0A]), "textModeDamaged")
        mustReject("\(label) 7-bit strip", v.map { $0 & 0x7F }, "textModeDamaged")
        mustReject("\(label) Latin-1->UTF-8", v.flatMap { $0 < 0x80 ? [$0] : [0xC0 | ($0 >> 6), 0x80 | ($0 & 0x3F)] }, "textModeDamaged")
        mustReject("\(label) UTF-8 replace re-encode", Array(String(decoding: v, as: UTF8.self).utf8), "textModeDamaged")
        // Zero-filled holes (spec 7.3 item 5) at every offset >= 16.
        for hole in [1, 4, 8, 16] {
            for start in stride(from: 16, to: v.count - hole + 1, by: 1) {
                var m = v
                for j in start..<(start + hole) { m[j] = 0 }
                if m != v { mustReject("\(label) zero hole \(hole)@\(start)", m) }
            }
        }
        let after = checks.filter { !$0.passed }.count
        check("vector \(label): every damage case rejected with a typed error", after == before)
    }
    note("damage cases: \(total), all rejected; error classes: \(tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    check("damage case count recorded", total > 8000, "\(total)")
}

// MARK: - 7. Binding and sequence (stored CRCs kept verbatim)

group("binding-sequence") {
    let u = tmpURL("three")
    try writeFile(u, gm(t: 10.0), [(im("i1", "first", 1.0), Data([1, 1, 1, 1])),
                                    (im("i2", "second", 2.0), Data([2, 2, 2, 2])),
                                    (im("i3", "third", 3.0), Data([3, 3, 3, 3]))])
    let v = fileBytes(u)
    let r = chunkRanges(v)
    let items = r.filter { $0.type == "ITEM" }
    check("three-item file has HEAD sOFT ITEM*3 TAIL", r.map { $0.type } == ["HEAD", "sOFT", "ITEM", "ITEM", "ITEM", "TAIL"])
    func range(_ c: (pos: Int, len: Int, type: String)) -> Range<Int> { c.pos..<(c.pos + 12 + c.len) }
    let i0 = range(items[0]), i1 = range(items[1]), i2 = range(items[2])

    var swapped = Array(v[0..<i0.lowerBound]) + Array(v[i1]) + Array(v[i0]) + Array(v[i2.lowerBound...])
    expectKind("swap two ITEM chunks verbatim -> corrupted", Data(swapped), "corrupted")
    var imgSwap = v
    let img0 = (i0.upperBound - 8)..<(i0.upperBound - 4), img1 = (i1.upperBound - 8)..<(i1.upperBound - 4)
    imgSwap.replaceSubrange(img0, with: v[img1]); imgSwap.replaceSubrange(img1, with: v[img0])
    expectKind("swap image bytes of two equal-length items -> corrupted", Data(imgSwap), "corrupted")
    let dup = Array(v[0..<i2.lowerBound]) + Array(v[i1]) + Array(v[i2.lowerBound...])
    expectKind("duplicate an ITEM -> corrupted", Data(dup), "corrupted")
    let drop = Array(v[0..<i1.lowerBound]) + Array(v[i1.upperBound...])
    expectKind("drop an ITEM -> corrupted", Data(drop), "corrupted")
    let u2 = tmpURL("three-other")
    try writeFile(u2, gm(t: 11.0), [(im("i1", "first", 1.0), Data([1, 1, 1, 1])),
                                     (im("i2", "second", 2.0), Data([2, 2, 2, 2])),
                                     (im("i3", "third", 3.0), Data([3, 3, 3, 3]))])
    let other = fileBytes(u2)
    let o1 = range(chunkRanges(other).filter { $0.type == "ITEM" }[1])
    check("other archive's ITEM 1 has the same bytes except CRC", Array(other[o1.lowerBound..<(o1.upperBound - 4)]) == Array(v[i1.lowerBound..<(i1.upperBound - 4)]))
    var spliced = v; spliced.replaceSubrange(i1, with: other[o1])
    expectKind("splice ITEM chunk from a different archive -> corrupted", Data(spliced), "corrupted")

    // Regression: a chain that includes the CRC fields is reset to the residue at every chunk,
    // so a verbatim ITEM swap passes it. Proves the exclusion rule matters.
    func naiveBuild(_ file: [UInt8]) -> [UInt8] {
        var out = Array(file[0..<12]); out += le32(zcrc(0, out))
        for c in chunkRanges(file) {
            out += file[c.pos..<(c.pos + 8 + c.len)]
            out += le32(zcrc(0, out))           // CRC of everything so far, INCLUDING earlier CRC fields
        }
        return out
    }
    func naiveVerify(_ f: [UInt8]) -> (ok: Bool, residues: [UInt32]) {
        guard f.count >= 16, zcrc(0, Array(f[0..<12])) == rd32(f, 12) else { return (false, []) }
        var run = zcrc(0, Array(f[0..<16])); var residues = [run]
        for c in chunkRanges(f) {
            let k = zcrc(run, Array(f[c.pos..<(c.pos + 8 + c.len)]))
            if k != rd32(f, c.pos + 8 + c.len) { return (false, residues) }
            run = zcrc(k, Array(f[(c.pos + 8 + c.len)..<(c.pos + 12 + c.len)]))
            residues.append(run)
        }
        return (true, residues)
    }
    let naive = naiveBuild(v)
    let nv = naiveVerify(naive)
    check("naive chain: original verifies", nv.ok)
    check("naive chain: running value is the residue 0x2144DF1C after every CRC field", nv.residues.allSatisfy { $0 == 0x2144DF1C })
    let nr = chunkRanges(naive).filter { $0.type == "ITEM" }
    let n0 = range(nr[0]), n1 = range(nr[1]), n2 = range(nr[2])
    swapped = Array(naive[0..<n0.lowerBound]) + Array(naive[n1]) + Array(naive[n0]) + Array(naive[n2.lowerBound...])
    check("naive chain ACCEPTS the swapped-ITEM file (the pitfall)", naiveVerify(swapped).ok)
    expectKind("spec chain rejects the naive file", Data(naive), "corrupted")
}

// MARK: - 8. Error precedence

struct LegacyArchive: Codable {
    struct G: Codable { let originalID: String; let name: String; let icon: String }
    struct I: Codable { let originalID: String; let originalFilename: String; let notes: String; let dateCreated: Date; let imageData: Data }
    let schemaVersion: Int; let exportedAt: Date; let group: G; let items: [I]
}

group("error-precedence") {
    expectError("short legacy JSON {} -> legacyFormat", Data("{}".utf8), .legacyFormat)
    expectError("BOM + whitespace + { -> legacyFormat", Data([0xEF, 0xBB, 0xBF, 0x20, 0x0A, 0x09, 0x0D, 0x7B, 0x7D]), .legacyFormat)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let legacy = try enc.encode(LegacyArchive(schemaVersion: 1, exportedAt: Date(), group: .init(originalID: "g", name: "Run", icon: "figure.run"),
                                              items: [.init(originalID: "i", originalFilename: "f", notes: "n", dateCreated: Date(), imageData: Data(repeating: 0xAB, count: 300))]))
    expectError("old exported JSON file -> legacyFormat", legacy, .legacyFormat)
    expectError("64 spaces then { -> notAnArchive (window is 64 bytes)", Data(Array(repeating: 0x20, count: 64) + [0x7B]), .notAnArchive)
    expectError("empty file -> notAnArchive", Data(), .notAnArchive)
    expectError("random text -> notAnArchive", Data("hello world, this is not an archive".utf8), .notAnArchive)
    expectError("first 5 signature bytes -> truncated(0)", Data(SIG.prefix(5)), .truncated(offset: 0))
    expectError("first 1 signature byte -> truncated(0)", Data(SIG.prefix(1)), .truncated(offset: 0))
    expectError("full signature only (8 bytes) -> truncated(0)", Data(SIG), .truncated(offset: 0))
    expectError("15 bytes of a valid preamble -> truncated(0)", Data(VEC_A.prefix(15)), .truncated(offset: 0))
    var flip = VEC_A; flip[8] ^= 0x02
    expectError("flipped major bit -> corrupted(0), not unsupportedVersion", Data(flip), .corrupted(offset: 0))
    var m2 = SIG + le16(2) + le16(0); m2 += le32(zcrc(0, m2))
    expectError("valid preamble, major 2 (16 bytes) -> unsupportedVersion(2,0)", Data(m2), .unsupportedVersion(major: 2, minor: 0))
    var m0 = SIG + le16(0) + le16(7); m0 += le32(zcrc(0, m0))
    expectError("valid preamble, major 0 minor 7 -> unsupportedVersion(0,7)", Data(m0 + [UInt8](repeating: 0, count: 100)), .unsupportedVersion(major: 0, minor: 7))
    let crit: [RawChunk] = [stdHead(count: 2), stdSoft, stdItem(), RawChunk("XTST", Data([1])), tailChunk]
    expectError("unknown critical + itemCount mismatch -> requiresNewerVersion", arch(crit), .requiresNewerVersion(type: "XTST", minor: 0, offset: posOf(crit, 3)))
    let fewer: [RawChunk] = [stdHead(count: 2), stdSoft, stdItem(), tailChunk]
    expectError("itemCount 2 with one ITEM -> malformed (not truncated)", arch(fewer), .malformed(offset: posOf(fewer, 3), reason: "fewer ITEM chunks than itemCount"))
    let tailM: [RawChunk] = [stdHead(count: 0), stdSoft, RawChunk("TAIL", Data(TAIL_MARK))]
    expectError("non-empty TAIL ending in a valid end marker -> malformed", arch(tailM), .malformed(offset: posOf(tailM, 2), reason: "TAIL not empty"))
    let tailX: [RawChunk] = [stdHead(count: 0), stdSoft, RawChunk("TAIL", Data([0x78]))]
    let tx = arch(tailX)
    expectError("non-empty TAIL without end marker -> truncated(size-12)", tx, .truncated(offset: tx.count - 12))
    expectError("66-byte file with valid preamble -> truncated(0) (R5)", Data(VEC_C.prefix(66)), .truncated(offset: 0))
    var noMarker = VEC_A; noMarker[noMarker.count - 6] = 0x41
    expectError("bad end marker -> truncated(size-12) (R6)", Data(noMarker), .truncated(offset: VEC_A.count - 12))
    expectError("PTC at offset 2 -> textModeDamaged", Data([0x00, 0x00, 0x50, 0x54, 0x43]), .textModeDamaged)
}

// MARK: - 9. Deep parser checks (CRC chain rebuilt by the builder)

group("deep-parser") {
    let S = stdSoft, T = tailChunk
    func std(_ head: RawChunk = stdHead(), _ item: RawChunk = stdItem()) -> [RawChunk] { [head, S, item, T] }
    let ip = posOf(std(), 2)   // ITEM position in the standard layout
    var n = 0
    func E(_ name: String, _ chunks: [RawChunk], _ e: FE, minor: UInt16 = 0) { n += 1; expectError(name, arch(chunks, minor: minor), e) }
    func A(_ name: String, _ chunks: [RawChunk], minor: UInt16 = 0) -> F.Archive? { n += 1; return expectAccept(name, arch(chunks, minor: minor)) }

    E("itemCount 100,001", [stdHead(count: 100_001), S, T], .limitExceeded(field: .itemCount, offset: 16, minor: 0))
    E("itemCount 0xFFFFFFFF", [stdHead(count: 0xFFFF_FFFF), S, T], .limitExceeded(field: .itemCount, offset: 16, minor: 0))
    E("itemCount 100,000 with no ITEMs -> malformed fewer", [stdHead(count: 100_000), S, T], .malformed(offset: posOf(std(), 2), reason: "fewer ITEM chunks than itemCount"))
    E("itemCount 0 with an ITEM", std(stdHead(count: 0)), .malformed(offset: ip, reason: "more ITEM chunks than itemCount"))
    for (label, b) in [("NaN", Double.nan.bitPattern), ("signaling NaN", UInt64(0x7FF0_0000_0000_0001)), ("negative NaN", UInt64(0xFFF8_0000_0000_0000)),
                       ("+Inf", Double.infinity.bitPattern), ("-Inf", (-Double.infinity).bitPattern),
                       ("distantFuture+1ulp", F.Limits.maxDate.nextUp.bitPattern), ("distantPast-1ulp", F.Limits.minDate.nextDown.bitPattern)] {
        E("exportedAt \(label)", std(stdHead(date: b)), .invalidDate(field: .exportedAt, offset: 16))
        E("dateCreated \(label)", std(stdHead(), stdItem(date: b)), .invalidDate(field: .dateCreated, offset: ip))
    }
    E("empty groupID", std(stdHead(gid: [])), .malformed(offset: 16, reason: "groupID empty"))
    E("empty name", std(stdHead(name: [])), .malformed(offset: 16, reason: "name empty"))
    E("empty icon", std(stdHead(icon: [])), .malformed(offset: 16, reason: "icon empty"))
    E("empty itemID", std(stdHead(), stdItem(id: [])), .malformed(offset: ip, reason: "itemID empty"))
    E("groupID 129 bytes", std(stdHead(gid: [UInt8](repeating: 0x61, count: 129))), .limitExceeded(field: .groupID, offset: 16, minor: 0))
    E("name 1,025 bytes", std(stdHead(name: [UInt8](repeating: 0x61, count: 1025))), .limitExceeded(field: .name, offset: 16, minor: 0))
    E("icon 129 bytes", std(stdHead(icon: [UInt8](repeating: 0x61, count: 129))), .limitExceeded(field: .icon, offset: 16, minor: 0))
    E("itemID 129 bytes", std(stdHead(), stdItem(id: [UInt8](repeating: 0x61, count: 129))), .limitExceeded(field: .itemID, offset: ip, minor: 0))
    let wAll = Array(([UInt32](0x09...0x0D) + [0x20, 0x85, 0xA0, 0x1680] + [UInt32](0x2000...0x200B) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]).map { String(Unicode.Scalar($0)!) }.joined().utf8)
    E("blank name of all 26 W scalars", std(stdHead(name: wAll)), .invalidGroupName(offset: 16))
    E("blank name single space", std(stdHead(name: [0x20])), .invalidGroupName(offset: 16))
    E("NUL in name", std(stdHead(name: [0x52, 0x00, 0x6E])), .invalidText(field: .name, offset: 16))
    E("NUL in groupID", std(stdHead(gid: [0x00])), .invalidText(field: .groupID, offset: 16))
    E("NUL in icon", std(stdHead(icon: [0x61, 0x00])), .invalidText(field: .icon, offset: 16))
    E("NUL in itemID", std(stdHead(), stdItem(id: [0x00, 0x61])), .invalidText(field: .itemID, offset: ip))
    for (label, seq) in [("overlong C0 80", [UInt8]([0xC0, 0x80])), ("surrogate ED A0 80", [0xED, 0xA0, 0x80]),
                         ("F4 90 80 80 (> U+10FFFF)", [0xF4, 0x90, 0x80, 0x80]), ("truncated E2 82", [0xE2, 0x82]),
                         ("lone continuation 80", [0x80]), ("F5 lead byte", [0xF5, 0x80, 0x80, 0x80])] {
        E("name \(label)", std(stdHead(name: [0x52] + seq)), .invalidText(field: .name, offset: 16))
        E("notes \(label)", std(stdHead(), stdItem(notes: seq + [0x61])), .invalidText(field: .notes, offset: ip))
    }
    var trailingHead = headPayload(count: 1, date: EXPORTED_BITS, gid: GA_ID, name: ubytes("Run"), icon: ubytes("figure.run")); trailingHead.append(0x41)
    E("HEAD trailing byte", std(RawChunk("HEAD", trailingHead)), .malformed(offset: 16, reason: "HEAD has trailing bytes"))
    E("HEAD payload 3 bytes", [RawChunk("HEAD", Data([1, 0, 0])), S, T], .malformed(offset: 16, reason: "HEAD too short"))
    E("HEAD payload only itemCount", [RawChunk("HEAD", Data(le32(0))), S, T], .malformed(offset: 16, reason: "exportedAt missing"))
    E("HEAD payload missing name length", [RawChunk("HEAD", Data(le32(0) + le64(0)) + strField(ubytes("g"))), S, T], .malformed(offset: 16, reason: "name length missing"))
    func headWithNameLen(_ len: UInt32) -> RawChunk {
        var p = Data(le32(1) + le64(EXPORTED_BITS)); p.append(strField(GA_ID)); p.append(contentsOf: le32(len) + ubytes("Run")); p.append(strField(ubytes("figure.run")))
        return RawChunk("HEAD", p)
    }
    E("str length 0xFFFFFFFF (name)", std(headWithNameLen(0xFFFF_FFFF)), .limitExceeded(field: .name, offset: 16, minor: 0))
    E("name length 1,025 that also overruns -> limit first (S3 before S4)", std(headWithNameLen(1025)), .limitExceeded(field: .name, offset: 16, minor: 0))
    E("str overrunning its payload (name len 30)", std(headWithNameLen(30)), .malformed(offset: 16, reason: "name overruns payload"))
    var notesFF = Data(le64(ITEM_BITS)); notesFF.append(strField(IT_ID)); notesFF.append(contentsOf: le32(0xFFFF_FFFF) + [1, 2, 3])
    E("str length 0xFFFFFFFF (notes)", std(stdHead(), RawChunk("ITEM", notesFF)), .limitExceeded(field: .notes, offset: ip, minor: 0))
    E("ITEM with no image", std(stdHead(), stdItem(image: [])), .malformed(offset: ip, reason: "ITEM has no image bytes"))
    E("notes 1 MiB + 1", std(stdHead(), stdItem(notes: [UInt8](repeating: 0x6E, count: (1 << 20) + 1))), .limitExceeded(field: .notes, offset: ip, minor: 0))
    E("ITEM payload 7 bytes", std(stdHead(), RawChunk("ITEM", Data([1, 2, 3, 4, 5, 6, 7]))), .malformed(offset: ip, reason: "dateCreated missing"))
    E("ITEM payload 0 bytes", std(stdHead(), RawChunk("ITEM", Data())), .malformed(offset: ip, reason: "dateCreated missing"))
    E("ITEM missing itemID length", std(stdHead(), RawChunk("ITEM", Data(le64(0) + [1, 2])))  , .malformed(offset: ip, reason: "itemID length missing"))
    if let a = A("NUL in notes accepted", std(stdHead(), stdItem(notes: [0x61, 0x00, 0x62]))) {
        check("NUL in notes preserved", Array(a.items[0].metadata.notes.utf8) == [0x61, 0x00, 0x62])
    }
    if let a = A("-0.0 dates accepted", std(stdHead(date: (-0.0).bitPattern), stdItem(date: (-0.0).bitPattern))) {
        check("-0.0 decodes as +0.0 (bits 0)", dbits(a.group.exportedAt) == 0 && dbits(a.items[0].metadata.dateCreated) == 0)
    }
    if let a = A("subnormal date accepted", std(stdHead(date: 1), stdItem(date: (-5e-324).bitPattern))) {
        check("subnormals bit-exact", dbits(a.group.exportedAt) == 1 && dbits(a.items[0].metadata.dateCreated) == (-5e-324).bitPattern)
    }
    _ = A("distantFuture / distantPast accepted", std(stdHead(date: bits(F.Limits.maxDate)), stdItem(date: bits(F.Limits.minDate))))
    if let a = A("1-byte image accepted", std(stdHead(), stdItem(image: [0x00]))) { check("1-byte image intact", [UInt8](a.items[0].imageData) == [0]) }
    _ = A("groupID/icon/itemID 128 bytes, name 1,024 bytes accepted", std(stdHead(gid: [UInt8](repeating: 0x61, count: 128), name: [UInt8](repeating: 0x62, count: 1024), icon: [UInt8](repeating: 0x63, count: 128)), stdItem(id: [UInt8](repeating: 0x64, count: 128))))
    E("HEAD not first (sOFT first)", [S, stdHead(), stdItem(), T], .malformed(offset: 16, reason: "HEAD must be first"))
    E("HEAD not first (ITEM first)", [stdItem(), stdHead(), T], .malformed(offset: 16, reason: "HEAD must be first"))
    E("HEAD not first (TAIL first)", [T, RawChunk("tEST", Data(repeating: 0, count: 40)), T], .malformed(offset: 16, reason: "HEAD must be first"))
    E("unknown ancillary before HEAD", [RawChunk("tEST", Data([1])), stdHead(), S, stdItem(), T], .malformed(offset: 16, reason: "HEAD must be first"))
    E("unknown critical before HEAD -> malformed", [RawChunk("XTST", Data([1])), stdHead(), S, stdItem(), T], .malformed(offset: 16, reason: "HEAD must be first"))
    let dupH = [stdHead(), stdHead(), S, stdItem(), T]
    E("duplicate HEAD", dupH, .malformed(offset: posOf(dupH, 1), reason: "duplicate HEAD"))
    let softAfter = [stdHead(), stdItem(), S, T]
    E("sOFT after an ITEM", softAfter, .malformed(offset: posOf(softAfter, 2), reason: "sOFT misplaced"))
    let twoSoft = [stdHead(), S, S, stdItem(), T]
    E("two sOFT chunks", twoSoft, .malformed(offset: posOf(twoSoft, 2), reason: "sOFT misplaced"))
    let ancThenSoftTwice = [stdHead(), RawChunk("tEST", Data()), S, RawChunk("tEST", Data()), S, stdItem(), T]
    E("two sOFT separated by ancillary", ancThenSoftTwice, .malformed(offset: posOf(ancThenSoftTwice, 4), reason: "sOFT misplaced"))
    E("empty sOFT", [stdHead(), RawChunk("sOFT", Data()), stdItem(), T], .malformed(offset: posOf(std(), 1), reason: "sOFT empty"))
    E("257-byte sOFT", [stdHead(), RawChunk("sOFT", Data(repeating: 0x61, count: 257)), stdItem(), T], .limitExceeded(field: .software, offset: posOf(std(), 1), minor: 0))
    _ = A("256-byte sOFT accepted", [stdHead(), RawChunk("sOFT", Data(repeating: 0x61, count: 256)), stdItem(), T])
    E("sOFT invalid UTF-8", [stdHead(), RawChunk("sOFT", Data([0x50, 0xC0, 0x80])), stdItem(), T], .invalidText(field: .software, offset: posOf(std(), 1)))
    E("sOFT with NUL", [stdHead(), RawChunk("sOFT", Data([0x50, 0x00])), stdItem(), T], .invalidText(field: .software, offset: posOf(std(), 1)))
    _ = A("missing sOFT accepted", [stdHead(), stdItem(), T])
    _ = A("sOFT after an unknown ancillary (still archive scope) accepted", [stdHead(), RawChunk("tEST", Data([9])), S, stdItem(), T])
    _ = A("unknown ancillary chunks in archive and item scope accepted", [stdHead(), S, RawChunk("tEST", Data([1, 2])), RawChunk("zzzz", Data()), stdItem(), RawChunk("aBcD", Data(repeating: 7, count: 5000)), T])
    _ = A("reserved lowercase byte 2 in an ancillary type accepted", [stdHead(), S, stdItem(), RawChunk("tEsT", Data([1])), T])
    let lowerSoft = [stdHead(), stdItem(), RawChunk("soft", Data([0x00, 0xFF])), T]
    _ = A("'soft' (all lowercase) is an unknown ancillary, skipped anywhere", lowerSoft)
    let upperSoft = [stdHead(), S, RawChunk("SOFT", Data([0x61])), stdItem(), T]
    E("'SOFT' uppercase is an unknown critical", upperSoft, .requiresNewerVersion(type: "SOFT", minor: 0, offset: posOf(upperSoft, 2)))
    let itemLower = [stdHead(), S, RawChunk("ITEm", Data([1])), T]
    E("'ITEm' is an unknown critical (case-sensitive)", itemLower, .requiresNewerVersion(type: "ITEm", minor: 0, offset: posOf(itemLower, 2)))
    E("'HEAd' first -> malformed", [RawChunk("HEAd", Data([1])), stdHead(), T], .malformed(offset: 16, reason: "HEAD must be first"))
    if let a = A("minor 0xFFFF accepted", std(), minor: 0xFFFF) { check("formatMinor 65535 reported", a.formatMinor == 0xFFFF) }
    let ancOnly = [stdHead(count: 0), RawChunk("tEST", Data(repeating: 1, count: 3)), T]
    _ = A("0 items with only an unknown ancillary accepted", ancOnly)
    let critMinor = [stdHead(), S, RawChunk("NEWF", Data([1])), stdItem(), T]
    E("unknown critical carries file minor", critMinor, .requiresNewerVersion(type: "NEWF", minor: 3, offset: posOf(critMinor, 2)), minor: 3)
    E("limit in minor>0 file carries minor", std(stdHead(), stdItem(notes: [UInt8](repeating: 0x6E, count: (1 << 20) + 1))), .limitExceeded(field: .notes, offset: ip, minor: 1), minor: 1)
    note("deep parser cases: \(n)")
}

// MARK: - 10. Framing

group("framing") {
    let base = arch([stdHead(), stdSoft, stdItem(), tailChunk])
    var big = [UInt8](base); put32(&big, 16, UInt32(F.Limits.maxChunkPayload + 1))
    expectError("L = MAX_CHUNK_PAYLOAD+1 -> corrupted (before the remaining-bytes check and any CRC work)", Data(big), .corrupted(offset: 16))
    var maxL = [UInt8](base); put32(&maxL, 16, UInt32(F.Limits.maxChunkPayload))
    expectError("L = MAX_CHUNK_PAYLOAD beyond EOF -> truncated", Data(maxL), .truncated(offset: 16))
    var ff = [UInt8](base); put32(&ff, 16, 0xFFFF_FFFF)
    expectError("L = 0xFFFFFFFF -> corrupted", Data(ff), .corrupted(offset: 16))
    var over = [UInt8](base); put32(&over, 16, UInt32(base.count))
    expectError("L larger than the remaining bytes -> truncated", Data(over), .truncated(offset: 16))
    for bad: UInt8 in [0x00, 0x40, 0x5B, 0x60, 0x7B, 0x31, 0xC8] {
        for idx in 0..<4 {
            var m = [UInt8](base); m[20 + idx] = bad
            expectError("type byte \(idx) = 0x\(String(bad, radix: 16)) -> corrupted", Data(m), .corrupted(offset: 16))
        }
    }
    // Non-letter type combined with an oversized L: the letter check runs first.
    var both = [UInt8](base); both[21] = 0x00; put32(&both, 16, 0xFFFF_FFFF)
    expectError("non-letter type + huge L -> corrupted", Data(both), .corrupted(offset: 16))
    // Mid-file truncation of framing: a chunk header that claims more than remains.
    let r = chunkRanges([UInt8](base))
    var midL = [UInt8](base); put32(&midL, r[2].pos, UInt32(base.count))
    expectError("ITEM L beyond EOF -> truncated(ITEM pos)", Data(midL), .truncated(offset: r[2].pos))

    // Exactly 2^20 chunks accepted, 2^20 + 1 rejected.
    let fillerCount = F.Limits.maxChunks - 2
    var chunks: [RawChunk] = [stdHead(count: 0)]
    chunks.reserveCapacity(fillerCount + 3)
    for _ in 0..<fillerCount { chunks.append(RawChunk("tEST", Data())) }
    chunks.append(tailChunk)
    let maxFile = arch(chunks)
    note("2^20-chunk file: \(maxFile.count) bytes")
    let t0 = Date()
    if let a = expectAccept("exactly 1,048,576 chunks accepted", maxFile) { check("max-chunk file: 0 items", a.items.isEmpty) }
    note(String(format: "decoding 2^20 chunks took %.3f s", Date().timeIntervalSince(t0)))
    chunks.insert(RawChunk("tEST", Data()), at: 1)
    let tooMany = arch(chunks)
    expectError("1,048,577 chunks -> limitExceeded(chunkCount)", tooMany, .limitExceeded(field: .chunkCount, offset: tooMany.count - 12, minor: 0))
}

// MARK: - 11. Limit edges

group("limits") {
    func writerRejects(_ name: String, _ want: FE, _ body: () throws -> Void) {
        do { try body(); check(name, false, "writer accepted") } catch { check(name, (error as? FE) == want, "got \(error), want \(want)") }
    }
    // IDs, icon, name at max via the writer; max+1 rejected by the writer (and by the reader in deep-parser).
    let id128 = String(repeating: "a", count: 128), id129 = String(repeating: "a", count: 129)
    let u1 = tmpURL("lim")
    try writeFile(u1, gm(id128, String(repeating: "名", count: 341) + "a", id128), [(im(id128, "", 1), Data([1]))])
    if let a = expectAccept("writer: IDs/icon 128 bytes, name 1,024 bytes accepted", mapped(u1)) {
        check("name 1,024 bytes preserved", a.group.name.utf8.count == 1024)
    }
    writerRejects("writer: groupID 129 -> limitExceeded", .limitExceeded(field: .groupID, offset: 16, minor: 0)) { try writeFile(tmpURL("x"), gm(id129), []) }
    writerRejects("writer: icon 129 -> limitExceeded", .limitExceeded(field: .icon, offset: 16, minor: 0)) { try writeFile(tmpURL("x"), gm("g", "R", id129), []) }
    writerRejects("writer: name 1,025 -> limitExceeded", .limitExceeded(field: .name, offset: 16, minor: 0)) { try writeFile(tmpURL("x"), gm("g", String(repeating: "b", count: 1025), "x"), []) }
    let notesMax = String(repeating: "n", count: 1 << 20)
    let u2 = tmpURL("notesmax")
    try writeFile(u2, gm(), [(im("i", notesMax, 1), Data([1]))])
    _ = expectAccept("writer: notes 1,048,576 accepted", mapped(u2))
    let headLen = 12 + 24 + 36 + 3 + 10, softLen = 12 + 20
    writerRejects("writer: itemID 129 -> limitExceeded", .limitExceeded(field: .itemID, offset: 16 + headLen + softLen, minor: 0)) { try writeFile(tmpURL("x"), gm(), [(im(id129, "", 1), Data([1]))]) }
    writerRejects("writer: notes 1 MiB + 1 -> limitExceeded", .limitExceeded(field: .notes, offset: 16 + headLen + softLen, minor: 0)) { try writeFile(tmpURL("x"), gm(), [(im("i", notesMax + "n", 1), Data([1]))]) }

    // Total text exactly 2^26 via the writer; +1 via raw builder (and writer/preflight rejection).
    let groupText = 3, idText = 64
    let notesTotal = F.Limits.maxTotalText - groupText - idText
    var textItems: [(F.ItemMetadata, Data)] = []
    for i in 0..<64 {
        let len = i < 63 ? (1 << 20) : notesTotal - 63 * (1 << 20)
        textItems.append((im(String(UnicodeScalar(UInt8(0x41 + i % 26))), String(repeating: "t", count: len), Double(i)), Data([UInt8(i)])))
    }
    let uT = tmpURL("text")
    try writeFile(uT, gm("g", "N", "x"), textItems)
    let textData = mapped(uT)
    if let a = expectAccept("total text exactly 67,108,864 accepted (writer output)", textData) {
        let sum = a.group.originalID.utf8.count + a.group.name.utf8.count + a.group.icon.utf8.count + a.items.reduce(0) { $0 + $1.metadata.originalID.utf8.count + $1.metadata.notes.utf8.count }
        check("decoded counted text == 2^26", sum == 1 << 26, "\(sum)")
    }
    let pf = textItems.map { F.PreflightItem(metadata: $0.0, imageByteCount: $0.1.count) }
    check("preflight accepts exactly 2^26 and predicts the size", (try? F.preflight(group: gm("g", "N", "x"), items: pf, software: "PictureTrack/1.0 (1)")) == textData.count)
    var pfPlus = pf; pfPlus[63].metadata.notes += "t"
    do { _ = try F.preflight(group: gm("g", "N", "x"), items: pfPlus, software: "PictureTrack/1.0 (1)"); check("preflight rejects 2^26+1", false) }
    catch { check("preflight rejects 2^26+1 with limitExceeded(totalText)", kind(error) == "limitExceeded" && errField(error) == "totalText", "\(error)") }
    var plusItems = textItems; plusItems[63].0.notes += "t"
    var item64Offset = 16 + (12 + 24 + 3) + (12 + 20)
    for i in 0..<63 { item64Offset += 12 + 16 + 1 + (1 << 20) + plusItems[i].1.count }
    writerRejects("writer: total text 2^26+1 -> limitExceeded(totalText) at the 64th ITEM",
                  .limitExceeded(field: .totalText, offset: item64Offset, minor: 0)) { try writeFile(tmpURL("x"), gm("g", "N", "x"), plusItems) }
    var rawChunks: [RawChunk] = [RawChunk("HEAD", headPayload(count: 64, date: 0, gid: ubytes("g"), name: ubytes("N"), icon: ubytes("x"))), stdSoft]
    for (i, it) in plusItems.enumerated() { rawChunks.append(RawChunk("ITEM", itemPayload(date: bits(Double(i)), id: ubytes(it.0.originalID), notes: ubytes(it.0.notes), image: [UInt8](it.1)))) }
    rawChunks.append(tailChunk)
    expectError("reader: total text 2^26+1 -> limitExceeded(totalText)", arch(rawChunks), .limitExceeded(field: .totalText, offset: posOf(rawChunks, 65), minor: 0))

    // Image 2^28 via the writer from a zero-filled mapped buffer; 2^28+1 rejected.
    let (_, img28) = sparseZeros(F.Limits.maxImageBytes, stem: "img28")
    let uI = tmpURL("img28")
    try writeFile(uI, gm(), [(im("big", "", 1), img28)])
    let bigData = mapped(uI)
    if let a = expectAccept("image of exactly 268,435,456 bytes accepted", bigData) {
        check("image count 2^28 and zero-copy", a.items[0].imageData.count == 1 << 28)
    }
    let (_, img28p1) = sparseZeros(F.Limits.maxImageBytes + 1, stem: "img28p1")
    writerRejects("writer: image 2^28+1 -> limitExceeded(image)", .limitExceeded(field: .image, offset: 16 + headLen + softLen, minor: 0)) { try writeFile(tmpURL("x"), gm(), [(im("big", "", 1), img28p1)]) }
    writerRejects("writer: empty image -> malformed", .malformed(offset: 16 + headLen + softLen, reason: "ITEM has no image bytes")) { try writeFile(tmpURL("x"), gm(), [(im("i", "", 1), Data())]) }
    var bigPayload = Data(le64(bits(1))); bigPayload.append(strField(ubytes("big"))); bigPayload.append(strField([])); bigPayload.append(img28p1)
    let bigChunks = [stdHead(), stdSoft, RawChunk("ITEM", bigPayload), tailChunk]
    expectError("reader: image 2^28+1 -> limitExceeded(image)", arch(bigChunks), .limitExceeded(field: .image, offset: posOf(bigChunks, 2), minor: 0))

    // itemCount: 100,000 is covered in round-trip; writer rejects 100,001 before creating a file.
    let u5 = tmpURL("count")
    writerRejects("writer: itemCount 100,001 -> limitExceeded(itemCount)", .limitExceeded(field: .itemCount, offset: 16, minor: 0)) { _ = try F.Writer(url: u5, group: gm(), itemCount: 100_001) }
    check("writer: no file created for itemCount 100,001", !FileManager.default.fileExists(atPath: u5.path))
    writerRejects("writer: itemCount -1 -> limitExceeded(itemCount)", .limitExceeded(field: .itemCount, offset: 16, minor: 0)) { _ = try F.Writer(url: tmpURL("x"), group: gm(), itemCount: -1) }

    // Archive size > 2^36 via a sparse file mapped read-only.
    let hugeURL = tmpRoot.appendingPathComponent("huge.bin")
    FileManager.default.createFile(atPath: hugeURL.path, contents: Data(VEC_A.prefix(16)))
    let fd = open(hugeURL.path, O_RDWR)
    precondition(fd >= 0 && ftruncate(fd, off_t(F.Limits.maxArchiveBytes + 1)) == 0)
    close(fd)
    do {
        let huge = try Data(contentsOf: hugeURL, options: .alwaysMapped)
        check("sparse 2^36+1 file mapped (\(huge.count) bytes)", huge.count == F.Limits.maxArchiveBytes + 1)
        expectError("size 2^36+1 -> tooLarge (R5)", huge, .tooLarge)
    } catch { check("map sparse 2^36+1 file", false, "\(error)") }
    do { _ = try F.mapForReading(hugeURL); check("mapForReading 2^36+1 -> tooLarge", false) }
    catch { check("mapForReading 2^36+1 -> tooLarge before mapping", (error as? FE) == .tooLarge, "\(error)") }
    let fd2 = open(hugeURL.path, O_RDWR)
    precondition(fd2 >= 0 && ftruncate(fd2, off_t(F.Limits.maxArchiveBytes)) == 0)
    close(fd2)
    if let exact = try? F.mapForReading(hugeURL) {
        expectError("size exactly 2^36 passes R5 (fails R6 end check instead)", exact, .truncated(offset: F.Limits.maxArchiveBytes - 12))
    } else { check("mapForReading exactly 2^36", false) }
    try? FileManager.default.removeItem(at: hugeURL)
    let emptyURL = tmpRoot.appendingPathComponent("empty.bin")
    FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
    if let e = try? F.mapForReading(emptyURL) { expectError("0-byte file via mapForReading -> notAnArchive (no mmap)", e, .notAnArchive) }

    // Minor > 0 wording.
    let msg = FE.limitExceeded(field: .notes, offset: 0, minor: 1).errorDescription ?? ""
    check("limitExceeded with minor 1 reads 'newer'", msg.contains("newer"), msg)
    let msg0 = FE.limitExceeded(field: .notes, offset: 0, minor: 0).errorDescription ?? ""
    check("limitExceeded with minor 0 does not say 'newer'", !msg0.contains("newer"), msg0)
}

// MARK: - 12. Writer

group("writer") {
    let g = gm()
    var items: [(F.ItemMetadata, Data)] = []
    for i in 0..<20 {
        let n = 1 + i * 97
        var bytes = [UInt8](repeating: 0, count: n)
        for j in 0..<n { bytes[j] = UInt8(truncatingIfNeeded: j &* 31 &+ i) }
        let t: Double = 700_000_000 + Double(i) / 7
        items.append((im("item-\(i)", "note \(i) 😀", t), Data(bytes)))
    }
    let u1 = tmpURL("w1"), u2 = tmpURL("w2")
    let n1 = try writeFile(u1, g, items), n2 = try writeFile(u2, g, items)
    let b1 = fileBytes(u1), b2 = fileBytes(u2)
    check("same snapshot -> identical bytes", b1 == b2 && n1 == n2)
    let framed = 16 + chunkRanges(b1).reduce(0) { $0 + 12 + $1.len }
    check("written == 16 + sum(12 + L) == file size", n1 == framed && framed == b1.count, "\(n1) \(framed) \(b1.count)")
    check("preflight predicts the exact size", (try? F.preflight(group: g, items: items.map { F.PreflightItem(metadata: $0.0, imageByteCount: $0.1.count) }, software: "PictureTrack/1.0 (1)")) == b1.count)
    if let a = try? F.read(mapped(u1)) {
        check("read-back equals the snapshot", groupEqualCanon(a.group, g) && zip(a.items, items).allSatisfy { metaEqualCanon($0.metadata, $1.0) && $0.imageData == $1.1 })
    } else { check("read-back", false) }
    check("chunk order HEAD sOFT ITEM* TAIL", chunkRanges(b1).map { $0.type } == ["HEAD", "sOFT"] + Array(repeating: "ITEM", count: 20) + ["TAIL"])
    // -0.0 item date is stored as +0.0.
    let uz = tmpURL("negzero")
    try writeFile(uz, g, [(im("z", "", -0.0), Data([1]))])
    let bz = fileBytes(uz)
    let itemPos = chunkRanges(bz)[2].pos
    check("-0.0 dateCreated stored as all-zero bits", Array(bz[(itemPos + 8)..<(itemPos + 16)]) == [UInt8](repeating: 0, count: 8))

    // Failure paths: no file created on preflight failures.
    func noFile(_ name: String, _ want: String, _ body: (URL) throws -> Void) {
        let u = tmpURL("fail")
        do { try body(u); check(name, false, "no error") } catch { check(name, kind(error) == want, "got \(error)") }
        check("\(name): no file created", !FileManager.default.fileExists(atPath: u.path))
    }
    noFile("blank name fails in init", "invalidGroupName") { _ = try F.Writer(url: $0, group: gm("g", " \u{3000}\n", "x"), itemCount: 0) }
    noFile("NUL in name fails in init", "invalidText") { _ = try F.Writer(url: $0, group: gm("g", "a\u{0}b", "x"), itemCount: 0) }
    noFile("NaN exportedAt fails in init", "invalidDate") { _ = try F.Writer(url: $0, group: gm(t: .nan), itemCount: 0) }
    noFile("distantFuture+1ulp exportedAt fails in init", "invalidDate") { _ = try F.Writer(url: $0, group: gm(t: F.Limits.maxDate.nextUp), itemCount: 0) }
    noFile("more than 100,000 items fails in init", "limitExceeded") { _ = try F.Writer(url: $0, group: g, itemCount: 100_001) }
    noFile("empty software fails in init", "malformed") { _ = try F.Writer(url: $0, group: g, itemCount: 0, software: "") }
    noFile("257-byte software fails in init", "limitExceeded") { _ = try F.Writer(url: $0, group: g, itemCount: 0, software: String(repeating: "s", count: 257)) }
    noFile("NUL in software fails in init", "invalidText") { _ = try F.Writer(url: $0, group: g, itemCount: 0, software: "a\u{0}") }
    do { _ = try F.preflight(group: g, items: [F.PreflightItem(metadata: im("i", String(repeating: "n", count: (1 << 20) + 1), 1), imageByteCount: 10)]); check("preflight: note over 1 MiB", false) }
    catch { check("preflight: note over 1 MiB -> limitExceeded(notes)", kind(error) == "limitExceeded" && errField(error) == "notes") }
    do { _ = try F.preflight(group: g, items: Array(repeating: F.PreflightItem(metadata: im("i", "", 1), imageByteCount: 1), count: 100_001)); check("preflight: 100,001 items", false) }
    catch { check("preflight: 100,001 items -> limitExceeded(itemCount)", (error as? FE) == .limitExceeded(field: .itemCount, offset: 16, minor: 0)) }
    do { _ = try F.preflight(group: g, items: Array(repeating: F.PreflightItem(metadata: im("i", "", 1), imageByteCount: 1 << 28), count: 257)); check("preflight: > 2^36 bytes", false) }
    catch { check("preflight: archive > 2^36 -> tooLarge", (error as? FE) == .tooLarge, "\(error)") }
    do { _ = try F.preflight(group: g, items: [F.PreflightItem(metadata: im("i", "", .infinity), imageByteCount: 1)]); check("preflight: inf date", false) }
    catch { check("preflight: infinite dateCreated -> invalidDate", kind(error) == "invalidDate") }

    // Existing file is never clobbered.
    let ex = tmpURL("exists")
    FileManager.default.createFile(atPath: ex.path, contents: Data("keep".utf8))
    do { _ = try F.Writer(url: ex, group: g, itemCount: 0); check("existing file: refuses", false) }
    catch { check("existing file: refuses with EEXIST", (error as? POSIXError)?.code == .EEXIST, "\(error)") }
    check("existing file: content untouched", fileBytes(ex) == ubytes("keep"))

    // itemCount enforcement and poisoning.
    let uc = tmpURL("count")
    let w = try F.Writer(url: uc, group: g, itemCount: 1)
    try w.append(im("a", "", 1), imageData: Data([1]))
    do { try w.append(im("b", "", 1), imageData: Data([1])); check("extra append", false) }
    catch { check("extra append -> itemCountMismatch(1, 2)", (error as? FE) == .itemCountMismatch(declared: 1, actual: 2), "\(error)") }
    do { try w.finish(); check("finish after failure", false) }
    catch { check("finish after a failure -> writerNotOpen", (error as? FE) == .writerNotOpen) }
    let us = tmpURL("short")
    let w2 = try F.Writer(url: us, group: g, itemCount: 3)
    try w2.append(im("a", "", 1), imageData: Data([1]))
    do { try w2.finish(); check("short finish", false) }
    catch { check("finish with fewer items -> itemCountMismatch(3, 1)", (error as? FE) == .itemCountMismatch(declared: 3, actual: 1)) }
    let ud = tmpURL("done")
    let w3 = try F.Writer(url: ud, group: g, itemCount: 0)
    try w3.finish()
    do { try w3.append(im("a", "", 1), imageData: Data([1])); check("append after finish", false) }
    catch { check("append after finish -> writerNotOpen", (error as? FE) == .writerNotOpen) }
    do { try w3.finish(); check("double finish", false) } catch { check("double finish -> writerNotOpen", (error as? FE) == .writerNotOpen) }
    let partial = tmpURL("partial")
    let w4 = try F.Writer(url: partial, group: g, itemCount: 2)
    try w4.append(im("a", "", 1), imageData: Data([1]))
    do { try w4.append(im("b", "x\u{0}", .nan), imageData: Data([1])); check("bad item", false) }
    catch { check("bad item date mid-stream -> invalidDate and writer closed", kind(error) == "invalidDate") }
    do { try w4.append(im("c", "", 1), imageData: Data([1])); check("poisoned", false) } catch { check("writer is poisoned after an error", (error as? FE) == .writerNotOpen) }
    switch decode(fileBytes(partial)) {
    case .ok: check("partial file left by a failed writer is rejected by the reader", false)
    case .err(let e): check("partial file left by a failed writer is rejected by the reader (\(kind(e)))", !kind(e).hasPrefix("foreign"))
    }

    // Cancellation.
    let cu = tmpURL("cancel")
    let sem = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var result = ""; var after = "" }
    let box = Box()
    Task.detached {
        do {
            let wc = try F.Writer(url: cu, group: gm(), itemCount: 3)
            try wc.append(im("a", "", 1), imageData: Data([1]))
            withUnsafeCurrentTask { $0?.cancel() }
            do { try wc.append(im("b", "", 1), imageData: Data([1])); box.result = "no error" } catch { box.result = kind(error) }
            do { try wc.finish(); box.after = "no error" } catch { box.after = kind(error) }
        } catch { box.result = "setup \(error)" }
        sem.signal()
    }
    sem.wait()
    check("append in a cancelled task -> CancellationError", box.result == "cancelled", box.result)
    check("writer closed after cancellation", box.after == "writerNotOpen", box.after)

    // Free space.
    do { try F.checkFreeSpace(required: 100, at: tmpRoot, available: 50); check("insufficientSpace", false) }
    catch { check("injected low free space -> insufficientSpace(100, 50)", (error as? FE) == .insufficientSpace(required: 100, available: 50)) }
    check("injected enough free space passes", (try? F.checkFreeSpace(required: 100, at: tmpRoot, available: 100)) != nil)
    check("real volume query: 1 byte fits", (try? F.checkFreeSpace(required: 1, at: tmpRoot)) != nil)
    do { try F.checkFreeSpace(required: Int(Int64.max / 2), at: tmpRoot); check("real volume query huge", false) }
    catch { check("real volume query: 4 EiB -> insufficientSpace", kind(error) == "insufficientSpace") }

    // File descriptors: no leaks across success and failure paths.
    let before = openFDCount()
    for i in 0..<50 {
        let u = tmpURL("fd")
        let wf = try F.Writer(url: u, group: g, itemCount: 1)
        if i % 3 == 0 { try wf.append(im("a", "", 1), imageData: Data([1])); try wf.finish() }
        else if i % 3 == 1 { _ = try? wf.append(im("a", "", .nan), imageData: Data([1])) }
        // i % 3 == 2: abandoned without finish (deinit closes)
    }
    check("no file descriptor leak over 50 writers", openFDCount() == before, "\(before) -> \(openFDCount())")
    check("defaultSoftware is valid (\(F.defaultSoftware))", (try? F.preflight(group: g, items: [], software: F.defaultSoftware)) != nil)
    // exportOrder
    let unsorted = [im("b", "", 2), im("a", "", 2), im("z", "", 1), im("é", "", 2), im("e\u{301}", "", 2)]
    let sorted = unsorted.sorted(by: F.exportOrder)
    check("exportOrder: by date, then ID UTF-8 bytes", sorted.map { Array($0.originalID.utf8) } == [ubytes("z"), ubytes("a"), ubytes("b"), ubytes("e\u{301}"), ubytes("é")])
}

// MARK: - 13. Reader: zero copy, bounded memory, progress, cancellation

group("reader-memory-progress-cancel") {
    // A ~300 MiB archive: one 256 MiB image plus 40 x 1 MiB.
    let (_, img) = sparseZeros(1 << 28, stem: "rm")
    var items: [(F.ItemMetadata, Data)] = [(im("big", "", 1), img)]
    for i in 0..<40 { items.append((im("s\(i)", "", 2 + Double(i)), Data(repeating: UInt8(i), count: 1 << 20))) }
    let u = tmpURL("rm")
    try writeFile(u, gm(), items)
    let data = mapped(u)
    let fp0 = physFootprint()
    var progress: [Int] = []
    let a = try F.read(data) { v, t in progress.append(v); precondition(t == data.count) }
    let fp1 = physFootprint()
    note("decode of \(data.count) bytes: phys_footprint \(fp0 >> 20) -> \(fp1 >> 20) MiB")
    check("decode does not grow phys_footprint by the image bytes (< 16 MiB growth)", fp1 - fp0 < 16 << 20, "\(fp1 - fp0)")
    data.withUnsafeBytes { p in
        let lo = p.baseAddress!, hi = p.baseAddress! + p.count
        let inside = a.items.allSatisfy { it in it.imageData.withUnsafeBytes { q in q.baseAddress! >= lo && q.baseAddress! + q.count <= hi } }
        check("every image slice lies inside the mapping", inside)
    }
    check("progress is strictly increasing", zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 })
    check("progress reaches size", progress.last == data.count)
    check("progress called at least once per 8 MiB", progress.count >= data.count / (8 << 20), "\(progress.count)")

    // Cancel partway through the 256 MiB ITEM chunk.
    final class Box: @unchecked Sendable { var seen: [Int] = []; var cancelAt: Int?; var callsAfterCancel = 0; var result = "" }
    let box = Box()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            _ = try F.read(data) { v, _ in
                if box.cancelAt != nil { box.callsAfterCancel += 1 }
                box.seen.append(v)
                if box.cancelAt == nil && v >= 64 << 20 { box.cancelAt = v; withUnsafeCurrentTask { $0?.cancel() } }
            }
            box.result = "accepted"
        } catch { box.result = kind(error) }
        sem.signal()
    }
    sem.wait()
    check("cancel mid-chunk -> CancellationError", box.result == "cancelled", box.result)
    check("cancel lands inside the 256 MiB chunk", (box.cancelAt ?? 0) < (1 << 28))
    check("no progress after cancel: stopped within one 8 MiB piece", box.callsAfterCancel == 0, "\(box.callsAfterCancel)")
    let box2 = Box()
    Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try F.read(data); box2.result = "accepted" } catch { box2.result = kind(error) }
        sem.signal()
    }
    sem.wait()
    check("pre-cancelled task -> CancellationError", box2.result == "cancelled")
    let box3 = Box()
    Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        do { _ = try F.read(Data(VEC_A)); box3.result = "accepted" } catch { box3.result = kind(error) }
        sem.signal()
    }
    sem.wait()
    check("pre-cancelled task, tiny file -> CancellationError (checked after each piece)", box3.result == "cancelled")
}

// MARK: - 14. Error descriptions and API

group("api") {
    let all: [FE] = [.notAnArchive, .legacyFormat, .textModeDamaged, .truncated(offset: 1), .tooLarge, .corrupted(offset: 2),
                     .unsupportedVersion(major: 2, minor: 0), .requiresNewerVersion(type: "XTST", minor: 1, offset: 3),
                     .limitExceeded(field: .image, offset: 4, minor: 0), .malformed(offset: 5, reason: "r"),
                     .invalidText(field: .name, offset: 6), .invalidDate(field: .dateCreated, offset: 7), .invalidGroupName(offset: 8),
                     .trailingData(offset: 9), .itemCountMismatch(declared: 1, actual: 2), .writerNotOpen,
                     .insufficientSpace(required: 10, available: 5), .writeVerificationFailed(expected: 1, actual: 0), .cannotMapFile(errno: 12)]
    check("every FormatError has a non-empty errorDescription", all.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    check("unsupportedVersion message includes major.minor", (FE.unsupportedVersion(major: 2, minor: 3).errorDescription ?? "").contains("2.3"))
    check("requiresNewerVersion message includes 1.minor", (FE.requiresNewerVersion(type: "X", minor: 4, offset: 0).errorDescription ?? "").contains("1.4"))
    check("fileExtension", F.fileExtension == "ptcollection")
    check("isNonBlankName", F.isNonBlankName("a") && !F.isNonBlankName("") && !F.isNonBlankName(" \t\u{3000}\u{200B}") && F.isNonBlankName("\u{200C}"))
}

// MARK: - Summary

try? FileManager.default.removeItem(at: tmpRoot)
var byGroup: [String: (Int, Int)] = [:]
var order: [String] = []
for c in checks {
    if byGroup[c.group] == nil { order.append(c.group) }
    var v = byGroup[c.group] ?? (0, 0)
    if c.passed { v.0 += 1 } else { v.1 += 1 }
    byGroup[c.group] = v
}
print("\nSUMMARY")
for gname in order {
    let (p, f) = byGroup[gname]!
    print("GROUP \(gname): \(p) passed, \(f) failed\((groupNotes[gname] ?? []).map { " | " + $0 }.joined())")
}
let failed = checks.filter { !$0.passed }
print("TOTAL: \(checks.count - failed.count) passed, \(failed.count) failed")
exit(failed.isEmpty ? 0 : 1)
