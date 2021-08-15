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
                
                List {
                    addingGroupButton

                    ForEach(db.groups) { group in
                        NavigationLink(destination: ItemsView(group: group).environmentObject(db)) {
                            Text(group.name)
                        Button(action: {
                            db.deleteGroup(id: group.id)
                        }, label: {
                            Text("Delete")
                        })
                            
                        }
                        
                        
                    }
                    
                }
            }
            
        }
        .sheet(isPresented: $addingGroup) {
            AddingGroupForm().environmentObject(db)
        }
       

    }
    
    var addingGroupButton: some View {
        Button(action: {addingGroup = true}, label: {
            HStack{
                Image(systemName: "plus.circle.fill")
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
