import SwiftUI
import SwiftData

struct ContentView: View {
    @Query(sort: \TrackerGroup.name) private var groups: [TrackerGroup]
    @Query private var items: [TrackerItem]
    @Environment(\.modelContext) private var modelContext
    @State private var addingGroup = false
    @State private var showingInfo = false
    @State private var showingImporter = false
    @State private var isImportingCollection = false
    @State private var showingTransferError = false
    @State private var transferErrorMessage = ""

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(isImportingCollection)
                }
            }
        }
        .sheet(isPresented: $addingGroup) {
            AddingGroupForm()
        }
        .sheet(isPresented: $showingInfo) {
            Info()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pictureTrackCollection]
        ) { result in
            handleCollectionImport(result: result)
        }
        .alert("Collection Transfer", isPresented: $showingTransferError) {
            Button("OK") {}
        } message: {
            Text(transferErrorMessage)
        }
        .overlay {
            if isImportingCollection {
                progressOverlay(title: "Importing Collection…")
            }
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

    private func handleCollectionImport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            isImportingCollection = true

            Task { @MainActor in
                do {
                    let archive = try await CollectionArchiveService.readArchive(from: url)
                    try CollectionArchiveService.importArchive(archive, into: modelContext)
                    isImportingCollection = false
                } catch {
                    isImportingCollection = false
                    transferErrorMessage = error.localizedDescription
                    showingTransferError = true
                }
            }
        case .failure(let error):
            guard !FileTransferErrorHelper.isUserCancelled(error) else { return }
            transferErrorMessage = error.localizedDescription
            showingTransferError = true
        }
    }

    @ViewBuilder
    private func progressOverlay(title: String) -> some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(.headline)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
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
