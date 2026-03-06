import SwiftUI
import SwiftData

struct ItemView: View {
    @Bindable var item: TrackerItem
    @Environment(\.modelContext) private var modelContext
    @State private var isEditingNote = false
    @State private var showingSavedPopup = false
    @FocusState private var noteFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(item.dateCreated.toMediumString())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                AsyncThumbnail(filename: item.imageFilename, maxDimension: 1600)
                    .aspectRatio(contentMode: .fit)

                if isEditingNote {
                    TextField("Add a note", text: $item.notes, axis: .vertical)
                        .focused($noteFieldFocused)
                        .padding(12)
                        .background(.fill.tertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.accentColor, lineWidth: 2)
                        )
                        .padding(.horizontal)
                } else if !item.notes.isEmpty {
                    Text(item.notes)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
            }
        }
        .overlay {
            if showingSavedPopup {
                savedPopup
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if isEditingNote {
                        // Finishing edit — save
                        try? modelContext.save()
                    }
                    withAnimation {
                        isEditingNote.toggle()
                    }
                    if isEditingNote {
                        noteFieldFocused = true
                    }
                } label: {
                    Image(systemName: isEditingNote ? "checkmark.circle.fill" : "pencil")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    ImageSaver().saveToPhotoLibrary(filename: item.imageFilename, creationDate: item.dateCreated) { success in
                        guard success else { return }
                        withAnimation { showingSavedPopup = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showingSavedPopup = false }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
            }
        }
    }

    private var savedPopup: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("Saved to Library")
                .font(.subheadline.weight(.medium))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
