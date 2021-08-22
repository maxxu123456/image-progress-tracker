//
//  Item.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/11/21.
//

import Foundation
import RealmSwift

class Item: Object, Identifiable {
    @Persisted var imageFilename: String
    @Persisted var notes: String
    @Persisted(primaryKey: true) var id = UUID().uuidString
//    @Persisted(originProperty: "items") var assignee: LinkingObjects<Group>
    convenience init(imageFilename: String, notes: String) {
        self.init()
        self.imageFilename = imageFilename
        self.notes = notes
        
    }
}
