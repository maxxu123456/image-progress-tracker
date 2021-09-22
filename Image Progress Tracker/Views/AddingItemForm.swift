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
    @State private var inputImage: UIImage?
    @State private var image: UIImage?
    @State private var showingImagePicker = false
    func loadImage() {
        guard let inputImage = inputImage else {return}
        image = inputImage
    }
    var groupId: String
    var body: some View {
        NavigationView {
            Form {
                
                Section(header: Text("Notes")) {
                    TextField("", text: $notes)
                }
                Section(header: Text("Image")) {
                    VStack {
                        Button(action: {
                            showingImagePicker.toggle()
                        }, label: {
                            Text("Pick Image From Library")
                        })
                        if let validImage = image {
                            Image(uiImage: validImage)
                                .resizable()
                                .frame(width: /*@START_MENU_TOKEN@*/100/*@END_MENU_TOKEN@*/, height: /*@START_MENU_TOKEN@*/100/*@END_MENU_TOKEN@*/)
                        }
                    }
                    
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
                    if let validImage = image {
                        Button(action: {
                            db.addItem(notes: notes, groupId: groupId,image: validImage)
                            notes = ""
                            presentationMode.wrappedValue.dismiss()
                        }, label: {
                            Text("Save")
                        })
                    }
                    
                }
            }
        }
        .sheet(isPresented: $showingImagePicker, onDismiss: loadImage) {
            ImagePicker(image: self.$inputImage)
        }
    }
}
