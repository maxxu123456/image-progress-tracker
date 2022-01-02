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
    @State private var icon = Constants.defaultSymbol
    var body: some View {
        NavigationView {
            VStack{

                Form {
                    HStack{
                        Spacer()
                        Image(systemName: icon)
                            .font(.largeTitle)
                        Spacer()
                    }
                    
                    Section(header: Text("Group Name")) {
                        TextField("", text: $groupName)
                    }
                    Section(header: Text("Icon")) {
                        SymbolsPicker(icon: $icon)
                    }
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
                        db.addGroup(name: groupName, icon: icon)
                        groupName = ""
                        presentationMode.wrappedValue.dismiss()
                    }, label: {
                        Text("Save")
                    })
                        .disabled(groupName == "")
                }
            }
        }
    }
}
