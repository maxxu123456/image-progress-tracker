import SwiftUI

struct CompareView: View {
    var group: TrackerGroup
    @State private var selected: [TrackerItem]
    @State private var selectingImages = false

    init(group: TrackerGroup) {
        self.group = group
        let sorted = group.items.sorted { $0.dateCreated > $1.dateCreated }
        if sorted.count >= 2 {
            _selected = State(initialValue: [sorted[1], sorted[0]])
        } else {
            _selected = State(initialValue: [])
        }
    }

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                if selected.count == 2 {
                    VStack {
                        HStack(spacing: 0) {
                            VStack {
                                Text("Before")
                                    .font(.headline)
                                AsyncThumbnail(filename: selected[0].imageFilename, maxDimension: 1400)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: geo.size.width / 2, alignment: .leading)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(selected[0].dateCreated.toMediumString())
                                    .font(.caption)
                            }
                            VStack {
                                Text("After")
                                    .font(.headline)
                                AsyncThumbnail(filename: selected[1].imageFilename, maxDimension: 1400)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: geo.size.width / 2, alignment: .trailing)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(selected[1].dateCreated.toMediumString())
                                    .font(.caption)
                            }
                        }
                        Text("\(selected[0].dateCreated.daysBetween(selected[1].dateCreated)) days apart.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top)
                    }
                }
                Spacer()
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { selectingImages = true } label: {
                        Image(systemName: "square.stack")
                    }
                }
            }
            .sheet(isPresented: $selectingImages) {
                CompareSelect(
                    items: group.items,
                    selectedConstant: selected,
                    selected: $selected
                )
            }
        }
    }
}
