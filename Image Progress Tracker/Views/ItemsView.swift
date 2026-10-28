import SwiftUI
import SwiftData

struct ItemsView: View {
    @Environment(\.modelContext) private var modelContext
    var group: TrackerGroup
    @State private var addingItem = false
    @State private var showingSavedPopup = false
    @State private var exportDocument: CollectionArchiveDocument?
    @State private var exportFilename = ""
    @State private var showingExporter = false
    @State private var isPreparingExport = false
    @State private var showingTransferError = false
    @State private var transferErrorMessage = ""

    var body: some View {
        GroupItemsList(group: group, showingSavedPopup: $showingSavedPopup)
        .equatable()
        .overlay {
            if showingSavedPopup {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("Saved to Library")
                        .font(.subheadline.weight(.medium))
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Export Collection", systemImage: "square.and.arrow.up") {
                    prepareCollectionExport()
                }
                .disabled(isPreparingExport)

                Button("Add Photo", systemImage: "plus") { addingItem = true }
            }
        }
        .sheet(isPresented: $addingItem) {
            AddingItemForm(group: group)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .pictureTrackCollection,
            defaultFilename: exportFilename
        ) { result in
            handleExportResult(result)
        }
        .alert("Collection Transfer", isPresented: $showingTransferError) {
            Button("OK") {}
        } message: {
            Text(transferErrorMessage)
        }
        .overlay {
            if isPreparingExport {
                ZStack {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Preparing Export…")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
    }

    private func prepareCollectionExport() {
        isPreparingExport = true

        let snapshot = CollectionArchiveService.ExportSnapshot(
            groupID: group.id,
            name: group.name,
            icon: group.icon,
            items: group.items.map { item in
                .init(
                    itemID: item.id,
                    imageFilename: item.imageFilename,
                    notes: item.notes,
                    dateCreated: item.dateCreated
                )
            }
        )
        let defaultFilename = CollectionArchiveService.defaultFilename(for: group.name)

        Task { @MainActor in
            do {
                let document = try await CollectionArchiveService.makeDocument(from: snapshot)
                exportDocument = document
                exportFilename = defaultFilename
                isPreparingExport = false
                showingExporter = true
            } catch {
                isPreparingExport = false
                transferErrorMessage = error.localizedDescription
                showingTransferError = true
            }
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        // Release the mapped archive whether the export finished or was cancelled.
        exportDocument = nil
        switch result {
        case .success:
            break
        case .failure(let error):
            guard !FileTransferErrorHelper.isUserCancelled(error) else { return }
            transferErrorMessage = error.localizedDescription
            showingTransferError = true
        }
    }
}

/// Owns the group-scoped, pre-sorted item query so the grid neither
/// re-sorts on every parent body evaluation nor re-evaluates when
/// export/sheet state toggles in ItemsView (Equatable on the group: a
/// Query rebuilt in init would otherwise always compare as changed).
private struct GroupItemsList: View, Equatable {
    @Environment(\.modelContext) private var modelContext
    let groupID: String
    @Binding var showingSavedPopup: Bool
    @State private var showingCompare = false
    @Query private var items: [TrackerItem]

    /// Adaptive columns: two on compact iPhones and the Duo's outer display,
    /// more as the width grows on the inner display.
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)]

    init(group: TrackerGroup, showingSavedPopup: Binding<Bool>) {
        _showingSavedPopup = showingSavedPopup
        let groupID = group.id
        self.groupID = groupID
        _items = Query(
            filter: #Predicate<TrackerItem> { $0.group?.id == groupID },
            sort: \TrackerItem.dateCreated,
            order: .reverse
        )
    }

    /// The binding points at stable @State in ItemsView, so only the group matters.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groupID == rhs.groupID
    }

    var body: some View {
        VStack {
            if items.count >= 2 {
                Button { showingCompare = true } label: {
                    Label("Before vs. After", systemImage: "square.on.square")
                }
                .buttonStyle(.glass)
                .padding()
            }

            ScrollView {
                if items.isEmpty {
                    // Not "above": on the iPhone Duo the toolbar is a vertical bar beside the content.
                    Text("Add an Item using the + button.")
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(destination: ItemView(item: item)) {
                                VStack(spacing: 6) {
                                    Text(item.dateCreated.toMediumString())
                                        .foregroundStyle(.primary)
                                    AsyncThumbnail(filename: item.imageFilename)
                                        .aspectRatio(1, contentMode: .fit)
                                }
                            }
                            .contextMenu {
                                Button {
                                    ImageSaver().saveToPhotoLibrary(filename: item.imageFilename, creationDate: item.dateCreated) { success in
                                        guard success else { return }
                                        withAnimation { showingSavedPopup = true }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            withAnimation { showingSavedPopup = false }
                                        }
                                    }
                                } label: {
                                    Label("Save Image to Library", systemImage: "arrow.down.circle")
                                }

                                Button(role: .destructive) {
                                    let filename = item.imageFilename
                                    withAnimation(.easeOut) {
                                        modelContext.delete(item)
                                        do {
                                            try modelContext.save()
                                            ImageStore.deleteImage(filename: filename)
                                        } catch {
                                            // Model delete failed; image file preserved. Undo the
                                            // pending delete so a later save cannot orphan it.
                                            modelContext.rollback()
                                        }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        // Full screen so the two photos get the whole display — on the iPhone
        // Duo the split lands on the fold, one photo per half. Reuses this
        // query's newest-first array instead of re-sorting group.items.
        .fullScreenCover(isPresented: $showingCompare) {
            NavigationStack {
                CompareView(items: items)
            }
        }
    }
}
