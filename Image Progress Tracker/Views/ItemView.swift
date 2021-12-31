//
//  ItemView.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 9/22/21.
//

import Foundation
import UIKit
import SwiftUI

struct ItemView: View {
    @EnvironmentObject var db: GroupStore
    var itemId: String
    var groupId: String
    var item: Item {
        let group = db.groups.first(where: { $0.id == groupId })
        let item = group!.items.first(where: { $0.id == itemId })
        return item!
    }
    var body: some View {
        Text(dateToString(date: item.dateCreated))
        GeometryReader { geo in
            Image(uiImage: getImageFromDocumentDirectory(fileName: item.imageFilename))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width)
        }
        Text("Notes: \(item.notes)")
    }
}
