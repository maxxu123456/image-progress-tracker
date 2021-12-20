//
//  ItemsView.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/14/21.
//

import SwiftUI
import Foundation

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
                ScrollView() {
                    if (group.items.count == 0) {
                        Text("Add an Item using the button above.")
                    } else {
                        ForEach(group.items) { item in
                            HStack{
                                Spacer()
                                VStack {
                                    let image = getImageFromDocumentDirectory(fileName: item.imageFilename)
                                    Text(dateToString(date: item.dateCreated))
                                    NavigationLink(destination: ItemView(itemId: item.id, groupId: groupId).environmentObject(db)) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .cornerRadius(10)
                                            .frame(width: 200, height: 200, alignment: .center)
                                            .contextMenu {
                                                Button(action: {
                                                    let imageSaver = ImageSaver()
                                                    imageSaver.writeToPhotoAlbum(image: image)
                                                }) {
                                                    HStack {
                                                        Text("Save Image to Library")
                                                        Image(systemName: "square.and.arrow.down")
                                                    }
                                                    
                                                }
                                                Button(role: .destructive, action: {
                                                    withAnimation {
                                                        db.deleteItem(id: item.id)
                                                    }
                                                }) {
                                                    HStack {
                                                        Text("Delete")
                                                        Image(systemName: "trash")
                                                    }
                                                    
                                                }
                                            }
                                        
                                    }
                                }
                                Spacer()
                            }
                            
                        }
                    }
                    
                }
                .navigationTitle(group.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.navigationBarTrailing) {
                        addingItemButton

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
                Image(systemName: "plus")
            }.foregroundColor(.green)
        }).padding()
    }
}
