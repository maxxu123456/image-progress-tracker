// Decodes the shared corpus and prints one verdict line per case, in the reference model's format.
import Foundation
import zlib
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let corpus = [UInt8](try! Data(contentsOf: dir.appendingPathComponent("corpus.bin")))
var out = ""
var pos = 0
func digest(_ a: F.Archive) -> String {
    var h: [UInt8] = []
    func s(_ x: [UInt8]) { h += le32(UInt32(x.count)) + x }
    s(Array(a.group.originalID.utf8)); s(Array(a.group.name.utf8)); s(Array(a.group.icon.utf8))
    h += le64(a.group.exportedAt.timeIntervalSinceReferenceDate.bitPattern)
    for it in a.items {
        s(Array(it.metadata.originalID.utf8)); s(Array(it.metadata.notes.utf8))
        h += le64(it.metadata.dateCreated.timeIntervalSinceReferenceDate.bitPattern); s([UInt8](it.imageData))
    }
    return String(format: "%08x", zcrc(0, h))
}
while pos + 4 <= corpus.count {
    let n = Int(rd32(corpus, pos)); pos += 4
    let b = Array(corpus[pos..<(pos + n)]); pos += n
    switch decode(b) {
    case .ok(let a): out += "accepted \(a.formatMinor) \(a.items.count) \(digest(a))\n"
    case .err(let e): out += "\(kind(e)) \(errOffset(e) ?? -1) \(errField(e) ?? "")\n"
    }
}
try! out.write(to: dir.appendingPathComponent("actual.txt"), atomically: true, encoding: .utf8)
// Byte-for-byte: reference vectors vs the spec hex and vs this writer.
for (name, v) in [("A", VEC_A), ("B", VEC_B), ("C", VEC_C), ("D", VEC_D), ("E", VEC_E)] {
    let ref = [UInt8](try! Data(contentsOf: dir.appendingPathComponent("vec-\(name).bin")))
    print("vector \(name): reference == spec hex: \(ref == v)")
}
let tmp = dir.appendingPathComponent("two-swift.ptcollection"); try? FileManager.default.removeItem(at: tmp)
let w = try! F.Writer(url: tmp, group: F.GroupMetadata(originalID: "00000000-0000-4000-8000-000000000001", name: "Run", icon: "figure.run", exportedAt: Date(timeIntervalSinceReferenceDate: 1)), itemCount: 2, software: "PictureTrack/1.0 (1)")
try! w.append(F.ItemMetadata(originalID: "i1", notes: "a", dateCreated: Date(timeIntervalSinceReferenceDate: 2)), imageData: Data([1, 2, 3, 4]))
try! w.append(F.ItemMetadata(originalID: "i2", notes: "b", dateCreated: Date(timeIntervalSinceReferenceDate: 3)), imageData: Data([5, 6, 7, 8]))
try! w.finish()
print("two-item: Swift writer == reference encoder: \((try! Data(contentsOf: tmp)) == (try! Data(contentsOf: dir.appendingPathComponent("vec-two.bin"))))")
