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
}
