import Foundation
import SwiftData

@Model
final class TrackerGroup {
    var name: String
    var icon: String

    @Relationship(deleteRule: .cascade, inverse: \TrackerItem.group)
    var items: [TrackerItem]

    var id: String

    init(name: String, icon: String, id: String = UUID().uuidString) {
        self.name = name
        self.icon = icon
        self.items = []
        self.id = id
    }
}
