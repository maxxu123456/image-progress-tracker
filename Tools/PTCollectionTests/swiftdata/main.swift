// SwiftData persistence check (test plan item): import codec-decoded dates into an on-disk store
// using the app's own TrackerGroup/TrackerItem models, fetch in a fresh container, compare bit patterns.
import Foundation
import SwiftData

let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("sd-\(getpid())")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let storeURL = dir.appendingPathComponent("store.sqlite")
var failures = 0
func dbits(_ d: Date) -> UInt64 { d.timeIntervalSinceReferenceDate.bitPattern }
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : ": " + detail)); if !ok { failures += 1 } }

// 1. Build an archive with the special dates plus 2,000 random ones, then decode it.
var rng = SplitMix64(seed: 2008)
var dates: [Double] = [0.0, -0.0, 5e-324, -5e-324, 1e-300, 0.1, Date().timeIntervalSinceReferenceDate, 815000000.25,
                       F.Limits.minDate, F.Limits.maxDate, 1.0, -1.0, 1234567.0]
while dates.count < 2_013 {
    if dates.count % 2 == 0 { dates.append(Double.random(in: F.Limits.minDate...F.Limits.maxDate, using: &rng)) }
    else { let v = Double(bitPattern: rng.next()); if v.isFinite && v >= F.Limits.minDate && v <= F.Limits.maxDate { dates.append(v) } }
}
let url = dir.appendingPathComponent("dates.ptcollection")
let w = try! F.Writer(url: url, group: F.GroupMetadata(originalID: "g", name: "Dates", icon: "calendar", exportedAt: Date()), itemCount: dates.count)
for (i, t) in dates.enumerated() { try! w.append(F.ItemMetadata(originalID: "\(i)", notes: "", dateCreated: Date(timeIntervalSinceReferenceDate: t)), imageData: Data([1])) }
try! w.finish()
let archive = try! F.read(try! F.mapForReading(url))
check("decoded \(archive.items.count) items; -0.0 already canonicalized to +0.0", dbits(archive.items[1].metadata.dateCreated) == 0)

// 2. Import into an on-disk store with the app's models, save once.
do {
    let container = try ModelContainer(for: TrackerGroup.self, TrackerItem.self, configurations: ModelConfiguration(url: storeURL))
    let context = ModelContext(container)
    let group = TrackerGroup(name: archive.group.name, icon: archive.group.icon)
    context.insert(group)
    for it in archive.items {
        let item = TrackerItem(imageFilename: "f", notes: it.metadata.notes, dateCreated: it.metadata.dateCreated, id: it.metadata.originalID)
        item.group = group
        context.insert(item)
    }
    // A control row with a raw -0.0 that did NOT go through the codec (documents the quirk the zero rule avoids).
    let control = TrackerItem(imageFilename: "f", notes: "", dateCreated: Date(timeIntervalSinceReferenceDate: -0.0), id: "control-negzero")
    context.insert(control)
    try context.save()
}

// 3. Fresh container on the same store; compare bit patterns.
do {
    let container = try ModelContainer(for: TrackerGroup.self, TrackerItem.self, configurations: ModelConfiguration(url: storeURL))
    let context = ModelContext(container)
    let fetched = try context.fetch(FetchDescriptor<TrackerItem>())
    var byID: [String: Date] = [:]
    for f in fetched { byID[f.id] = f.dateCreated }
    var mismatches: [(Int, UInt64, UInt64)] = []
    for (i, it) in archive.items.enumerated() {
        guard let d = byID[it.metadata.originalID] else { mismatches.append((i, 0, 0)); continue }
        if dbits(d) != dbits(it.metadata.dateCreated) { mismatches.append((i, dbits(it.metadata.dateCreated), dbits(d))) }
    }
    check("SwiftData on-disk round trip of \(archive.items.count) codec dates is bit-exact", mismatches.isEmpty,
          mismatches.prefix(5).map { "item \($0.0): \(String($0.1, radix: 16)) -> \(String($0.2, radix: 16))" }.joined(separator: ", "))
    if let c = byID["control-negzero"] {
        print("INFO raw -0.0 written straight to SwiftData comes back as \(c.timeIntervalSinceReferenceDate) (bits \(String(dbits(c), radix: 16)))")
    }
}
try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "SWIFTDATA: all passed" : "SWIFTDATA: \(failures) failed")
exit(failures == 0 ? 0 : 1)
