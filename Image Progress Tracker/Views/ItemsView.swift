import SwiftUI
import SwiftData

struct ItemsView: View {
    @Environment(\.modelContext) private var modelContext
    var group: TrackerGroup
    @State private var addingItem = false
    @State private var showingCompare = false
    @State private var showingSavedPopup = false
    @State private var exportDocument: CollectionArchiveDocument?
    @State private var exportFilename = ""
    @State private var showingExporter = false
    @State private var isPreparingExport = false
    @State private var showingTransferError = false
    @State private var transferErrorMessage = ""

    private var sortedItems: [TrackerItem] {
        group.items.sorted { $0.dateCreated > $1.dateCreated }
    }

    var body: some View {
        VStack {
            if group.items.count >= 2 {
                Button { showingCompare = true } label: {
                    Label("Before vs. After", systemImage: "square.on.square")
                }
                .buttonStyle(.glass)
                .padding()
            }

            ScrollView {
                if group.items.isEmpty {
                    Text("Add an Item using the button above.")
                        .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(sortedItems, id: \.id) { item in
                            NavigationLink(destination: ItemView(item: item)) {
                                VStack {
                                    Text(item.dateCreated.toMediumString())
                                        .foregroundStyle(.primary)
                                    AsyncThumbnail(filename: item.imageFilename, maxDimension: 400)
                                        .scaledToFill()
                                        .frame(width: 200, height: 200, alignment: .center)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                                            // Model delete failed; image file preserved
                                        }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
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
                Button {
                    prepareCollectionExport()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(isPreparingExport)

                Button { addingItem = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $addingItem) {
            AddingItemForm(group: group)
        }
        .sheet(isPresented: $showingCompare) {
            NavigationStack {
                CompareView(group: group)
            }
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
        switch result {
        case .success:
            exportDocument = nil
        case .failure(let error):
            guard !FileTransferErrorHelper.isUserCancelled(error) else { return }
            transferErrorMessage = error.localizedDescription
            showingTransferError = true
        }
    }
}
