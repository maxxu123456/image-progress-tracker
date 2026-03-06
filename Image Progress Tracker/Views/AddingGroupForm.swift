import SwiftUI
import SwiftData

struct AddingGroupForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var groupName = ""
    @State private var icon = Symbols.defaultSymbol

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    Spacer()
                    Image(systemName: icon)
                        .font(.largeTitle)
                    Spacer()
                }

                Section("Group Name") {
                    TextField("Enter name", text: $groupName)
                }
                Section("Icon") {
                    SymbolsPicker(icon: $icon)
                }
            }
            .navigationTitle("Add Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let group = TrackerGroup(name: groupName, icon: icon)
                        modelContext.insert(group)
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(groupName.isEmpty)
                }
            }
        }
    }
}
