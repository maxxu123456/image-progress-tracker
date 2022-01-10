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
        selectedItems.append(firstTwoImagesByDateDescending[1])
        selectedItems.append(firstTwoImagesByDateDescending[0])
        selected = selectedItems
    }
    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                if(selected.count == 2) {
                    VStack {
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
                        Text(String(daysBetween(start: selected[0].dateCreated,end: selected[1].dateCreated)) + " days apart.").padding(.top)
                    }
                    
                }
                Spacer()
//                Text("1 Year apart")
//                    .padding(.top)
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.navigationBarTrailing) {
                    selectForCompare
                    
                }
            }
            .sheet(isPresented: $selectingImages) {
                CompareSelect(items: Array(group.items), selectedConstant: Array(selected), selected: $selected ).environmentObject(db)
            }
                
            
            
        }
            
    }
    var selectForCompare: some View {
        Button(action: {selectingImages = true}, label: {
            HStack{
                Image(systemName: "square.stack")
            }
        })
    }

}

//struct CompareView_Previews: PreviewProvider {
//    static var previews: some View {
//        CompareView()
//    }
//}
