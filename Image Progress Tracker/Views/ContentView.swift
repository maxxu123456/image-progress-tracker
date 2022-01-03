//
//  ContentView.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/10/21.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var db: GroupStore
    @State private var addingGroup = false
    
    @State private var groupName: String = ""
    @State private var showingInfo = false
    private func deleteGroup(with indexSet: IndexSet){
        indexSet.forEach ({ index in
            db.deleteGroupByIndex(index: index)
        })
    }
    var body: some View {
        
        VStack{
            NavigationView {
                VStack {
                    VStack {
                        if(db.groups.count == 0) {
                            Text("Add a Group using the button below.")
                            
                        } else {
                            List {
                                
                                ForEach(db.groups) { group in
                                    NavigationLink(destination: ItemsView(groupId: group.id,name: group.name).environmentObject(db)) {
                                        HStack{
                                            let _ = db.printRealmDirectory()
                                            Image(systemName: group.icon)
                                            Text(group.name)
                                            Text(String(group.items.count) + " items")
                                                .fontWeight(.light)
                                                .font(.subheadline)
                                                .foregroundColor(.gray)
                                            
                                        }
                                    }
                                    
                                    
                                }
                                .onDelete(perform: deleteGroup)
                                
                            }
                        }
                        
                        
                    }.navigationTitle("Groups")
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(action: {
                                    showingInfo = true
                                }, label: {
                                    Image(systemName: "info.circle")
                                })
                            }
                        }
                    
                    Spacer()
                    
                    addingGroupButton
                    
                    
                    
                }
            }
            
            
            
            
        }
        .sheet(isPresented: $addingGroup) {
            AddingGroupForm().environmentObject(db)
        }
        .sheet(isPresented: $showingInfo) {
            Info()
        }
        
        
        
        
        
    }
    
    var addingGroupButton: some View {
        Button(action: {addingGroup = true}, label: {
            HStack{
                Image(systemName: "folder.badge.plus")
                Text("Add Group")
                    .bold()
            }.foregroundColor(.green)
        }).padding()
    }
    
    
}
