import SwiftUI
import SwiftData

@main
struct Image_Progress_TrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [TrackerGroup.self, TrackerItem.self])
    }

    init() {
        // Ensure Application Support directory exists before SwiftData tries
        // to create its SQLite store there. Without this, CoreData falls into
        // a slow recovery path on first launch.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
    }
}
