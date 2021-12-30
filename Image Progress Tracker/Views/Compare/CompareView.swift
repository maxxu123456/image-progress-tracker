//
//  CompareView.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 10/13/21.
//

import SwiftUI

struct CompareView: View {
    var body: some View {
        GeometryReader { geo in
            VStack {
                HStack(spacing:0) {
                    VStack {
                        Text("Before")
                        Image("test1")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width / 2, alignment: .leading)
                        Text("December 1, 2021")
                    }
                    VStack {
                        Text("After")
                        Image("test2")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width / 2, alignment: .trailing )
                        Text("December 2, 2022")
                    }
                    
                }
                .padding(.top, 200)
                Text("1 Year apart")
                    .padding(.top)
            }
                
            
            
        }
        .padding()
            
    }
}

struct CompareView_Previews: PreviewProvider {
    static var previews: some View {
        CompareView()
    }
}
