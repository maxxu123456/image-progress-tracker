//
//  AddingGroupForm.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/14/21.
//

import SwiftUI

struct AddingGroupForm: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var db: GroupStore
    @State private var groupName: String = ""
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Group Name")) {
                    TextField("", text: $groupName)
                }
            }
            
            .navigationTitle("Add Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }, label: {
                        Text("Exit")
                    })
                }
                ToolbarItem(placement:.navigationBarTrailing) {
                    Button(action: {
                        db.addGroup(name: groupName)
                        groupName = ""
                        presentationMode.wrappedValue.dismiss()
                    }, label: {
                        Text("Save")
                    })
                }
            }
        }
    }
}
