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
    @State private var showingCompare = false
    @EnvironmentObject var db: GroupStore
    var groupId: String
    var name: String
    private var group: Group? {
        db.groups.filter { $0.id == groupId }.first
    }
    
    var body: some View {
        if let group = group {
            
            VStack {
                if (group.items.count >= 2) {
                    VStack {
                        Button(action: {showingCompare = true} ) {
                            Label("Before vs. After", systemImage: "square.on.square")
                        }
                        .padding()
                        NavigationLink(destination: CompareView(group: group).environmentObject(db), isActive: $showingCompare) { EmptyView() }
                    }
                    
                }
//                                addTestImage
                //                addTestImage1000
                ScrollView() {
                    if (group.items.count == 0) {
                        Text("Add an Item using the button above.")
                    } else {
                        VStack {

                            LazyVStack {
                                ForEach(group.items.sorted(by: {$0.dateCreated.compare($1.dateCreated) == .orderedDescending})){ item in
                                    HStack{
                                        Spacer()
                                        VStack {
                                            let image = getImageFromDocumentDirectory(fileName: item.imageFilename)
                                            Text(dateToString(date: item.dateCreated))
                                            NavigationLink(destination: ItemView(item: item).environmentObject(db)) {
                                                Image(uiImage: image)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 200, height: 200, alignment: .center)
                                                    .clipped()
                                                    .cornerRadius(10)
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
                                                            withAnimation(.easeOut) {
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
        
    }
    var addingItemButton: some View {
        Button(action: {addingItem = true}, label: {
            HStack{
                Image(systemName: "plus")
            }.foregroundColor(.green)
        }).padding()
    }
    var addTestImage: some View {
        Button(action: {db.addTestImage(groupId: groupId)}, label: {
            HStack{
                Text("Add Test Image")
                    .bold()
            }.foregroundColor(.green)
        }).padding()
    }
    var addTestImage1000: some View {
        Button(action: {for _ in 1...1000 {db.addTestImage(groupId: groupId)}}, label: {
            HStack{
                Text("Add Test Image")
                    .bold()
            }.foregroundColor(.green)
        }).padding()
    }
    
}
