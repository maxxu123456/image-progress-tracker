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
    var image: UIImage
    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width)
        }

    }
}
