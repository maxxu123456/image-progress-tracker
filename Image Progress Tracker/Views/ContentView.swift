import SwiftUI
import SwiftData

struct ContentView: View {
    @Query(sort: \TrackerGroup.name) private var groups: [TrackerGroup]
    @Query private var items: [TrackerItem]
    @Environment(\.modelContext) private var modelContext
    @State private var addingGroup = false
    @State private var showingInfo = false

    private var itemCountsByGroupID: [String: Int] {
        items.reduce(into: [:]) { counts, item in
            guard let groupID = item.group?.id else { return }
            counts[groupID, default: 0] += 1
        }
    }

    var body: some View {
        NavigationStack {
            VStack {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No Groups",
                        systemImage: "folder.badge.plus",
                        description: Text("Add a Group using the button below.")
                    )
                } else {
                    List {
                        ForEach(groups, id: \.id) { group in
                            NavigationLink(value: group.persistentModelID) {
                                HStack {
                                    Image(systemName: group.icon)
                                    Text(group.name)
                                    Text(itemCountText(for: group))
                                        .fontWeight(.light)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: deleteGroups)
                    }
                }

                Spacer()

                Button {
                    addingGroup = true
                } label: {
                    Label("Add Group", systemImage: "folder.badge.plus")
                        .bold()
                }
                .buttonStyle(.glass)
                .padding()
            }
            .navigationTitle("Groups")
            .navigationDestination(for: PersistentIdentifier.self) { groupID in
                ItemsViewResolver(groupID: groupID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingInfo = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $addingGroup) {
            AddingGroupForm()
        }
        .sheet(isPresented: $showingInfo) {
            Info()
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        for index in offsets {
            let group = groups[index]
            let filenames = group.items.map(\.imageFilename)
            modelContext.delete(group)
            do {
                try modelContext.save()
                for filename in filenames {
                    ImageStore.deleteImage(filename: filename)
                }
            } catch {
                // Model delete failed; image files preserved
            }
        }
    }

    private func itemCountText(for group: TrackerGroup) -> String {
        let count = itemCountsByGroupID[group.id, default: 0]
        return count == 1 ? "1 item" : "\(count) items"
    }
}

/// Resolves a PersistentIdentifier back into a TrackerGroup for navigation.
struct ItemsViewResolver: View {
    let groupID: PersistentIdentifier
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if let group = modelContext.model(for: groupID) as? TrackerGroup {
            ItemsView(group: group)
        } else {
            ContentUnavailableView("Group Not Found", systemImage: "exclamationmark.triangle")
        }
    }
}
