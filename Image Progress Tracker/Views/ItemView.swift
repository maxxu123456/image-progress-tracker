//
//  ItemView.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 9/22/21.
//

import Foundation
import UIKit
import SwiftUI

struct ItemView: View {
    @EnvironmentObject var db: GroupStore
    @Environment(\.presentationMode) var presentationMode
    var item: Item
    var body: some View {

            VStack{
                Text(dateToString(date: item.dateCreated))
                GeometryReader { geo in
                    Image(uiImage: getImageFromDocumentDirectory(fileName: item.imageFilename))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width)
                }
                if (item.notes != "") {
                    Text("Notes: \(item.notes)")
                }
            }
            .toolbar {

                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button(action: {
                            let imageSaver = ImageSaver()
                            imageSaver.writeToPhotoAlbum(image: getImageFromDocumentDirectory(fileName: item.imageFilename))
                        }) {
                            Image(systemName: "square.and.arrow.down")

                    }
                        Spacer()
                    }
                    
            }
            
        }
        
        
}
}
