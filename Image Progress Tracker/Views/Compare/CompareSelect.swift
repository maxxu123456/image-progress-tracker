import SwiftUI

struct CompareSelect: View {
    /// Adaptive so the grid keeps a sensible cell size from the Duo's outer
    /// display up to a sheet on the inner display.
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
    @Environment(\.dismiss) private var dismiss
    var items: [TrackerItem]
    @Binding var selected: [TrackerItem]
    /// Edited here and committed only by Save, so Cancel or a swipe-dismiss
    /// leaves the comparison as it was (never with just one photo).
    @State private var draft: [TrackerItem]

    init(items: [TrackerItem], selected: Binding<[TrackerItem]>) {
        self.items = items
        _selected = selected
        _draft = State(initialValue: selected.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items, id: \.id) { item in
                        let isSelected = draft.contains(where: { $0.id == item.id })
                        AsyncThumbnail(filename: item.imageFilename, cornerRadius: 10)
                            .aspectRatio(1, contentMode: .fit)
                            .imageSelected(condition: isSelected)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !isSelected && draft.count < 2 {
                                    if draft.isEmpty {
                                        draft.append(item)
                                    } else if item.dateCreated < draft[0].dateCreated {
                                        draft.insert(item, at: 0)
                                    } else {
                                        draft.append(item)
                                    }
                                } else if isSelected {
                                    draft.removeAll(where: { $0.id == item.id })
                                }
                            }
                    }
                }
                .padding()
            }
            .navigationTitle("Select Two Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        selected = draft
                        dismiss()
                    }
                    .disabled(draft.count != 2)
                }
            }
        }
    }
}

struct SelectImage: ViewModifier {
    var isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 4)
                )
        } else {
            content
        }
    }
}

extension View {
    func imageSelected(condition: Bool) -> some View {
        modifier(SelectImage(isSelected: condition))
    }
}
