import SwiftUI

struct CompareSelect: View {
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    @Environment(\.dismiss) private var dismiss
    var items: [TrackerItem]
    @State var selectedConstant: [TrackerItem]
    @Binding var selected: [TrackerItem]

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    LazyVGrid(columns: columns) {
                        ForEach(items.sorted(by: { $0.dateCreated > $1.dateCreated }), id: \.id) { item in
                            let isSelected = selected.contains(where: { $0.id == item.id })
                            AsyncThumbnail(filename: item.imageFilename, maxDimension: 300)
                                .scaledToFill()
                                .frame(width: geo.size.width / 3.5, height: geo.size.width / 3.5, alignment: .center)
                                .clipped()
                                .cornerRadius(10)
                                .imageSelected(condition: isSelected)
                                .onTapGesture {
                                    if !isSelected && selected.count < 2 {
                                        if selected.isEmpty {
                                            selected.append(item)
                                        } else if item.dateCreated < selected[0].dateCreated {
                                            selected.insert(item, at: 0)
                                        } else {
                                            selected.append(item)
                                        }
                                    } else if isSelected {
                                        selected.removeAll(where: { $0.id == item.id })
                                    }
                                }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Select Two Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        selected = selectedConstant
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        dismiss()
                    }
                    .disabled(selected.count != 2)
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
