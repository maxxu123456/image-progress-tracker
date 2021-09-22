//
//  DateManager.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 9/22/21.
//

import Foundation

func dateToString(date: Date) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .none
    dateFormatter.locale = Locale(identifier: "en_US")
    return dateFormatter.string(from: date)
}
