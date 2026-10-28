import SwiftUI

struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    /// Newest first.
    private let sortedItems: [TrackerItem]
    @State private var selected: [TrackerItem]
    @State private var selectingImages = false

    init(items newestFirst: [TrackerItem]) {
        self.sortedItems = newestFirst
        if newestFirst.count >= 2 {
            _selected = State(initialValue: [newestFirst[1], newestFirst[0]])
        } else {
            _selected = State(initialValue: [])
        }
    }

    var body: some View {
        VStack {
            if selected.count == 2 {
                // Side by side when the space is wider than tall, stacked
                // otherwise; on the iPhone Duo the split follows the fold.
                ArrangementView {
                    ComparePane(title: "Before", item: selected[0])
                } secondary: {
                    ComparePane(title: "After", item: selected[1])
                }
                .arrangementViewStyle(.split)
            }
        }
        .navigationTitle("Compare")
        // In the bar rather than under the photos, where a centered caption
        // would sit on the Duo's fold.
        .navigationSubtitle(daysApartText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Choose Photos", systemImage: "square.stack") { selectingImages = true }
            }
        }
        .sheet(isPresented: $selectingImages) {
            CompareSelect(items: sortedItems, selected: $selected)
        }
    }

    private var daysApartText: String {
        guard selected.count == 2 else { return "" }
        return "\(selected[0].dateCreated.daysBetween(selected[1].dateCreated)) days apart."
    }
}

private struct ComparePane: View {
    let title: String
    let item: TrackerItem

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            AsyncThumbnail(filename: item.imageFilename, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(item.dateCreated.toMediumString())
                .font(.caption)
        }
        .padding(8)
    }
}
