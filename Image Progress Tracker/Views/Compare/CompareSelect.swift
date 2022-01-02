//
//  CompareSelect.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 12/29/21.
//

import SwiftUI

struct CompareSelect: View {
    var columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    @Environment(\.presentationMode) var presentationMode
    var items: [Item]
    @State var selectedConstant: [Item]
    @Binding var selected: [Item]
    var body: some View {
        NavigationView {
            GeometryReader { geo in
                LazyVGrid(columns: columns) {
                    ForEach(items.sorted(by: {$0.dateCreated.compare($1.dateCreated) == .orderedDescending})) { item in
                        let image = getImageFromDocumentDirectory(fileName: item.imageFilename)
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width/3.5, height: geo.size.width/3.5, alignment: .center)
                            .clipped()
                            .cornerRadius(10)
                            .imageSelected(condition: selected.contains(item))
                            .onTapGesture {
                                if(!selected.contains(item) && selected.count < 2) {
                                    if(selected.count == 0) {
                                        selected.append(item)
                                    } else if(item.dateCreated < selected[0].dateCreated) {
                                        selected.insert(item, at: 0)
                                    } else {
                                        selected.append(item)
                                    }
                                } else if(selected.contains(item)) {
                                    if let index = selected.firstIndex(of: item) {
                                        selected.remove(at: index)
                                    }
                                }
                            }
                    }
                }
            }.padding()
                .navigationTitle("Select Two Photos to compare.")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            selected = selectedConstant
                            presentationMode.wrappedValue.dismiss()
                        }, label: {
                            Text("Exit")
                        })
                    }
                    ToolbarItem(placement:.navigationBarTrailing) {
                        Button(action: {
                            presentationMode.wrappedValue.dismiss()
                        }, label: {
                            Text("Save")
                        })
                            .disabled(selected.count != 2)
                    }
                }
        }





        
        
    }
}

//struct CompareSelect_Previews: PreviewProvider {
//    static var previews: some View {
//        CompareSelect()
//    }
//}

struct SelectImage: ViewModifier {
    var isSelected: Bool
    func body(content: Content) -> some View {
        if(isSelected) {
            content
                .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 4))
        } else {
            content
        }
        
    }
}

extension View {
    func imageSelected(condition: Bool) -> some View {
        modifier(SelectImage(isSelected: condition))
    }
}
