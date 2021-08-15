//
//  ItemsView.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/14/21.
//

import SwiftUI

struct ItemsView: View {
    @State private var addingItem = false
    @EnvironmentObject var db: GroupStore
    var group: Group
    var body: some View {
        

        VStack {
            addingItemButton
            ForEach(group.items) { item in
                Text(item.notes)
            }
        }
        .sheet(isPresented: $addingItem, content: {
            AddingItemForm(groupId: group.id).environmentObject(db)
        })
       
    }
    var addingItemButton: some View {
        Button(action: {addingItem = true}, label: {
            HStack{
                Image(systemName: "plus.circle.fill")
                Text("Add Item")
                    .bold()
            }.foregroundColor(.green)
        }).padding()
    }
}
