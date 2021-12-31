//
//  CompareView.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 10/13/21.
//

import SwiftUI

struct CompareView: View {
    @State private var selectingImages = false
    @EnvironmentObject var db: GroupStore
    @State private var selected: [Item]
    var group: Group
    
    init(group: Group) {
        self.group = group
        //Assigns first most recent two images to be default for selected
        let firstTwoImagesByDateDescending = self.group.items.sorted(by: {$0.dateCreated.compare($1.dateCreated) == .orderedDescending})[0...1]
        var selectedItems: [Item] = []
        selectedItems.append(firstTwoImagesByDateDescending[0])
        selectedItems.append(firstTwoImagesByDateDescending[1])
        selected = selectedItems
    }
    var body: some View {
        GeometryReader { geo in
            VStack {
                selectForCompare
                if(selected.count == 2) {
                    HStack(spacing:0) {
                        VStack {
                            let image = getImageFromDocumentDirectory(fileName: selected[0].imageFilename)

                            Text("Before")
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geo.size.width / 2, alignment: .leading)
                            Text(dateToString(date: selected[0].dateCreated))
                        }
                        VStack {
                            let image = getImageFromDocumentDirectory(fileName: selected[1].imageFilename)
                            Text("After")
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geo.size.width / 2, alignment: .trailing )
                            Text(dateToString(date: selected[1].dateCreated))
                        }
                        
                    }
                    .padding(.top, 200)
                }
                
//                Text("1 Year apart")
//                    .padding(.top)
            }
            .sheet(isPresented: $selectingImages) {
                CompareSelect(items: Array(group.items), selectedConstant: Array(selected), selected: $selected ).environmentObject(db)
            }
                
            
            
        }
        .padding()
            
    }
    var selectForCompare: some View {
        Button(action: {selectingImages = true}, label: {
            HStack{
                Text("Select Images for Compare")
                    .bold()
            }
        })
    }
}

//struct CompareView_Previews: PreviewProvider {
//    static var previews: some View {
//        CompareView()
//    }
//}
