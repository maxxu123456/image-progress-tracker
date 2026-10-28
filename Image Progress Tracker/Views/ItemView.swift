import SwiftUI
import SwiftData

struct ItemView: View {
    let item: TrackerItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var isEditingNote = false
    /// Notes are edited here and written to the model once, so typing does
    /// not re-run every live @Query in the navigation stack per keystroke.
    @State private var noteDraft = ""
    @State private var showingSavedPopup = false
    /// Visible height of the scroll view, so a portrait photo on a short,
    /// wide display (the Duo's open inner screen) fits without scrolling.
    @State private var viewportHeight: CGFloat = 0
    @FocusState private var noteFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(item.dateCreated.toMediumString())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                AsyncThumbnail(filename: item.imageFilename, contentMode: .fit)
                    .frame(maxHeight: viewportHeight > 0 ? viewportHeight * 0.85 : nil)
                    .padding(.horizontal)

                if isEditingNote {
                    TextField("Add a note", text: $noteDraft, axis: .vertical)
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
        .onDisappear(perform: commitNote)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { commitNote() }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, height in
            viewportHeight = height
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
                Button(isEditingNote ? "Done Editing Note" : "Edit Note", systemImage: isEditingNote ? "checkmark.circle.fill" : "pencil") {
                    if isEditingNote {
                        // Finishing edit — save
                        commitNote()
                    } else {
                        noteDraft = item.notes
                    }
                    withAnimation {
                        isEditingNote.toggle()
                    }
                    if isEditingNote {
                        noteFieldFocused = true
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save to Photos", systemImage: "arrow.down.circle") {
                    ImageSaver().saveToPhotoLibrary(filename: item.imageFilename, creationDate: item.dateCreated) { success in
                        guard success else { return }
                        withAnimation { showingSavedPopup = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showingSavedPopup = false }
                        }
                    }
                }
            }
        }
    }

    /// Writes the draft back while editing (checkmark, leaving the screen, or
    /// the app moving to the background).
    private func commitNote() {
        guard isEditingNote, noteDraft != item.notes else { return }
        item.notes = noteDraft
        try? modelContext.save()
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
