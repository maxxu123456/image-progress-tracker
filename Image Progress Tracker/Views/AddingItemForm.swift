//
//  AddingItemForm.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/14/21.
//

import SwiftUI

struct AddingItemForm: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var notes: String = ""
    @EnvironmentObject var db: GroupStore
    var groupId: String
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Notes")) {
                    TextField("", text: $notes)
                }
            }
            .navigationTitle("Add Item")
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
                        db.addItem(notes: notes, groupId: groupId)
                        notes = ""
                        presentationMode.wrappedValue.dismiss()
                    }, label: {
                        Text("Save")
                    })
                }
            }
        }
    }
}
