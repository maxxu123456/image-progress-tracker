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
    var body: some View {
        VStack{
            NavigationView {
                VStack {
                    List {

                        ForEach(db.groups) { group in
                            NavigationLink(destination: ItemsView(groupId: group.id).environmentObject(db)) {
                                Text(group.name)
                            }
                            
                            
                        }
                        
                    }
                    addingGroupButton

                }
                .navigationTitle("Groups")
            }
            
        }
        .sheet(isPresented: $addingGroup) {
            AddingGroupForm().environmentObject(db)
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



struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(db: GroupStore())
    }
}
