//
//  Info.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 1/3/22.
//

import SwiftUI

struct Info: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Support")) {
                    Link("Privacy Policy", destination: URL(string: "https://sites.google.com/view/picturetrack/privacy-policy")!)
                    Link("Contact", destination: URL(string: "https://sites.google.com/view/picturetrack/contact")!)
                    
                }
            }
            .navigationTitle("Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }, label: {
                        Text("Done")
                    })
                }
            }
        }
        
        
    }
    
}
