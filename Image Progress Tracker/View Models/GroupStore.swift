//
//  GroupStore.swift
//  Image Progress Tracker
//
//  Created by Max Xu on 8/11/21.
//

import Foundation
import RealmSwift
import SwiftUI

class GroupStore: ObservableObject {
    private var groupResults: Results<Group>
    //Need to create a array copy of taskResults since in a Results collection, realm marks deleted objects as invalid. ForEach maintains the list of object before deleteion in its memeory to make loading easier, but this means it accesses the objet after it is deleted. Thus ForEach must use the Array copy "tasks".
    var groups: [Group] {
        groupResults.map(Group.init)
        
    }
    init() {
        let realm = try! Realm()
        groupResults = realm.objects(Group.self)
    }
    func addGroup(name: String, icon: String) {
        objectWillChange.send()
        let realm = try! Realm()
        try! realm.write {
            realm.add(Group(name: name, icon: icon))
            
        }
    }
    func deleteGroup(id: String) {
        /*
         This needs to use the id since if you pass in a task object as the paramter, realm wont know how to delete it. You have to find the realm object instead using the id. Then realm willl know how to delete that specific realm object
         */
        objectWillChange.send()
        let realm = try! Realm()
        guard let group = realm.object(ofType: Group.self, forPrimaryKey: id)
        else {return}
        try! realm.write {
            realm.delete(group)
        }
    }
    func deleteGroupByIndex(index: Int) {
        /*
         This needs to use the id since if you pass in a task object as the paramter, realm wont know how to delete it. You have to find the realm object instead using the id. Then realm willl know how to delete that specific realm object
         */
        objectWillChange.send()
        let realm = try! Realm()
        guard let group = realm.object(ofType: Group.self, forPrimaryKey: groups[index].id)
        else {return}
        let items = group.items
        try! realm.write {
            realm.delete(items)
            realm.delete(group)
        }
        
    }
    func addItem(notes: String, groupId: String, image: UIImage, date: Date) {
        objectWillChange.send()
        let realm = try! Realm()
        guard let group = realm.object(ofType: Group.self, forPrimaryKey: groupId)
        else {return}
        let item = Item(imageFilename: saveJpg(image), notes: notes, date: date)
        try! realm.write {
            group.items.append(item)
            realm.add(item)
            
        }
    }
    func getItem(id: String) -> Item? {
        objectWillChange.send()
        let realm = try! Realm()
        let item = realm.object(ofType: Item.self, forPrimaryKey: id)
        return item
    }
    func deleteItem(id: String) {
        objectWillChange.send()
        let realm = try! Realm()
        guard let item = realm.object(ofType: Item.self, forPrimaryKey: id)
        else {return}
        try! realm.write {
            realm.delete(item)
        }
    }
    func printRealmDirectory() {
        let realm = try! Realm()
        print(realm.configuration.fileURL!)
    }
    
    func addTestImage(groupId: String, imageName: String, date: Date) {
        addItem(notes: "a;sdlfkdffja;sldkfja;sdlkfj;alskdjf;aklsdjfpaosijefpwqoiefjpqwoiefjqpwoeifjdjfaosidjfaoipsdjfpoaisdjfopajdisjfapoidjsfioajsdfioajsdfpaoisjdfaopisdjfpaoisjdfpaoisdjfaiosjdfpioasdjfpioasdjfpaisdf", groupId: groupId, image: UIImage(named: imageName)!, date: date)
    }
    
}
