//
//  Group.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/11/21.
//

import Foundation
import RealmSwift

class Group: Object, Identifiable {
    @Persisted var name: String
    @Persisted var icon: String
    @Persisted var items: List<Item> = List<Item>()
    @Persisted(primaryKey: true) var id = UUID().uuidString
    convenience init(name: String, icon: String) {
        self.init()
        self.name = name
        self.icon = icon
    }
}
