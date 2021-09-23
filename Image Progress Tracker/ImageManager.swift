//
//  ImageManager.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/21/21.
//

import SwiftUI

func documentDirectoryPath() -> URL? {
    let path = FileManager.default.urls(for: .documentDirectory,
                                        in: .userDomainMask)
    return path.first
}

func saveJpg(_ image: UIImage) -> String {
    let filename = generateRandomImageName()
    if let jpgData = image.jpegData(compressionQuality: 0.5),
        let path = documentDirectoryPath()?.appendingPathComponent(filename) {
        try? jpgData.write(to: path)
        return generateRandomImageName()
    }
    return ""
    
}

private func generateRandomImageName() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd hh:mm:ss"
    let now = df.string(from: Date())
    return now + ".jpg"
}

class ImageSaver: NSObject {
    func writeToPhotoAlbum(image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(saveError), nil)
    }

    @objc func saveError(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        print("Save finished!")
    }
}

func getImageFromDocumentDirectory(fileName: String) -> UIImage {
    let data = try? Data(contentsOf: (documentDirectoryPath()?.appendingPathComponent(fileName))!)
    let image = UIImage(data: data!)
    return image!
}
