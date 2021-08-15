//
//  Image_Progress_TrackerApp.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/10/21.
//

import SwiftUI

@main
struct Image_Progress_TrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(db: GroupStore())
        }
    }
}
