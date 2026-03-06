import SwiftUI
import SwiftData

struct ItemsView: View {
    @Environment(\.modelContext) private var modelContext
    var group: TrackerGroup
    @State private var addingItem = false
    @State private var showingCompare = false
    @State private var showingSavedPopup = false

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
            ToolbarItem(placement: .topBarTrailing) {
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
    }
}
