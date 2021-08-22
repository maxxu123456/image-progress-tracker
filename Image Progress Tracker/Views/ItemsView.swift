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
                VStack {
                    let data = try? Data(contentsOf: (documentDirectoryPath()?.appendingPathComponent(item.imageFilename))!)
                    let image = UIImage(data: data!)
                    Text(item.notes)
                    Image(uiImage: image!)
                        .resizable()
                        .frame(width: 200, height: 200, alignment: /*@START_MENU_TOKEN@*/.center/*@END_MENU_TOKEN@*/)
                }
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
