//
//  CompareSelect.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 12/29/21.
//

import SwiftUI

struct CompareSelect: View {
    var columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    var images = ["test1","test2","test3","test4","test5"]
    @State private var selected = ["test1","test2"]
    var body: some View {
        GeometryReader { geo in
            LazyVGrid(columns: columns) {
                ForEach(images, id: \.self) { imageName in
                    Image(imageName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width/3.5, height: geo.size.width/3.5, alignment: .center)
                        .clipped()
                        .cornerRadius(10)
                        .imageSelected(condition: selected.contains(imageName))
                        .onTapGesture {
                            if(!selected.contains(imageName) && selected.count < 2) {
                                selected.append(imageName)
                            } else if(selected.contains(imageName)) {
                                if let index = selected.firstIndex(of: imageName) {
                                    selected.remove(at: index)
                                }
                            }
                        }
                }
            }
        }
        
    }
}

struct CompareSelect_Previews: PreviewProvider {
    static var previews: some View {
        CompareSelect()
    }
}

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
