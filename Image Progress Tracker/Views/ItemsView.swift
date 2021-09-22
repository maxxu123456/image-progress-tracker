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
    var groupId: String
    private var group: Group {
        db.groups.filter { $0.id == groupId }[0]
    }
    var body: some View {

        VStack {
            let _ = print(group.items)
            addingItemButton
            ScrollView() {
                ForEach(group.items) { item in
                    VStack {
                        let data = try? Data(contentsOf: (documentDirectoryPath()?.appendingPathComponent(item.imageFilename))!)
                        let image = UIImage(data: data!)
                        Text(item.notes)
                        Image(uiImage: image!)
                            .resizable()
                            .cornerRadius(10)
                            .frame(width: 200, height: 200, alignment: .center)
                            .contextMenu {
                                Button(action: {
                                    let imageSaver = ImageSaver()
                                    imageSaver.writeToPhotoAlbum(image: image!)
                                }) {
                                    Text("Save Image to Library")
                                }
                            }
                    }
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
