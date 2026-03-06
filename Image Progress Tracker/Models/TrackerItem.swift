import Foundation
import SwiftData

@Model
final class TrackerItem {
    var imageFilename: String
    var notes: String
    var dateCreated: Date
    var id: String

    var group: TrackerGroup?

    init(imageFilename: String, notes: String, dateCreated: Date, id: String = UUID().uuidString) {
        self.imageFilename = imageFilename
        self.notes = notes
        self.dateCreated = dateCreated
        self.id = id
    }
}
