import SwiftUI

struct Info: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Support") {
                    if let privacyURL = URL(string: "https://sites.google.com/view/picturetrack/privacy-policy") {
                        Link("Privacy Policy", destination: privacyURL)
                    }
                    if let contactURL = URL(string: "https://sites.google.com/view/picturetrack/contact") {
                        Link("Contact", destination: contactURL)
                    }
                }

                Section("Developer") {
                    if let githubURL = URL(string: "https://github.com/maxxu123456/image-progress-tracker") {
                        Link("Source Code", destination: githubURL)
                    }
                    if let linkedinURL = URL(string: "https://www.linkedin.com/in/maxxu123456/") {
                        Link("LinkedIn", destination: linkedinURL)
                    }
                }

                Section("Getting Started") {
                    instructionRow(
                        title: "Add a collection",
                        detail: "Tap Add Group at the bottom of the Groups screen."
                    )
                    instructionRow(
                        title: "Add a photo",
                        detail: "Open a collection and tap the + button in the top-right corner."
                    )
                    instructionRow(
                        title: "Edit notes",
                        detail: "Open a photo, tap the pencil button, then tap the checkmark to save."
                    )
                }

                Section("Import and Export") {
                    instructionRow(
                        title: "Import a collection",
                        detail: "On the Groups screen, use the top-right import button and choose a .ptcollection file."
                    )
                    instructionRow(
                        title: "Export current collection",
                        detail: "Inside a collection, use the top-right export button to export the collection you are viewing."
                    )
                }

                Section("Delete and Compare") {
                    instructionRow(
                        title: "Delete a collection",
                        detail: "Swipe left on a collection in the Groups list."
                    )
                    instructionRow(
                        title: "Delete a photo",
                        detail: "Inside a collection, long-press a photo and choose Delete."
                    )
                    instructionRow(
                        title: "Compare progress",
                        detail: "When a collection has at least two photos, use the Before vs. After button."
                    )
                }

                Section("Other Features") {
                    instructionRow(
                        title: "Save to Photos",
                        detail: "Long-press a photo in a collection, or open it and tap the download button."
                    )
                    instructionRow(
                        title: "Dates",
                        detail: "Imported photos try to use the original library date. You can adjust the date before saving a new item."
                    )
                }
            }
            .navigationTitle("Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func instructionRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
