import SwiftUI
import SwiftData

struct ContentView: View {
    @Query(sort: \TrackerGroup.name) private var groups: [TrackerGroup]
    @Environment(\.modelContext) private var modelContext
    /// The open group's id. Scene storage, so the open collection survives the
    /// scene being rebuilt (fold/unfold, multitasking resizes, relaunch).
    @SceneStorage("selectedGroupID") private var selectedGroupID: String?
    @State private var addingGroup = false
    @State private var showingInfo = false
    @State private var showingImporter = false
    @State private var isImportingCollection = false
    /// Files waiting to import; several can arrive at once (AirDrop, or opening
    /// another while one is still importing), and each is imported in turn.
    @State private var pendingImports: [URL] = []
    @State private var showingTransferError = false
    @State private var transferErrorMessage = ""

    private var selectedGroup: TrackerGroup? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.id == selectedGroupID }
    }

    var body: some View {
        // Collapses to a single stack on compact widths (the outer display,
        // other iPhones); shows groups beside the open group on the inner display.
        NavigationSplitView {
            sidebar
        } detail: {
            if let group = selectedGroup {
                NavigationStack {
                    ItemsView(group: group)
                }
                .id(group.id)
            } else if !groups.isEmpty {
                // With no groups at all, the sidebar's own empty state is enough.
                ContentUnavailableView(
                    "No Group Selected",
                    systemImage: "folder",
                    description: Text("Choose a Group to see its photos.")
                )
            }
        }
        .sheet(isPresented: $addingGroup) {
            AddingGroupForm()
        }
        .sheet(isPresented: $showingInfo) {
            Info()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pictureTrackCollection]
        ) { result in
            switch result {
            case .success(let url):
                importCollection(from: url)
            case .failure(let error):
                guard !FileTransferErrorHelper.isUserCancelled(error) else { return }
                transferErrorMessage = error.localizedDescription
                showingTransferError = true
            }
        }
        // Files, AirDrop, Mail: the system hands over a .ptcollection the app owns.
        .onOpenURL { url in
            importCollection(from: url)
        }
        .alert("Collection Transfer", isPresented: $showingTransferError) {
            Button("OK") {}
        } message: {
            Text(transferErrorMessage)
        }
        .overlay {
            if isImportingCollection {
                progressOverlay(title: "Importing Collection…")
            }
        }
        .task {
            await CollectionArchiveService.recoverInterruptedImports(container: modelContext.container)
        }
    }

    private var sidebar: some View {
        VStack {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No Groups",
                    systemImage: "folder.badge.plus",
                    description: Text("Add a Group using the button below.")
                )
            } else {
                List(selection: $selectedGroupID) {
                    ForEach(groups, id: \.id) { group in
                        NavigationLink(value: group.id) {
                            GroupRow(group: group)
                        }
                    }
                    .onDelete(perform: deleteGroups)
                }
            }

            Spacer()

            Button {
                addingGroup = true
            } label: {
                Label("Add Group", systemImage: "folder.badge.plus")
                    .bold()
            }
            .buttonStyle(.glass)
            .padding()
        }
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Information", systemImage: "info.circle") { showingInfo = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import Collection", systemImage: "square.and.arrow.down") {
                    showingImporter = true
                }
                .disabled(isImportingCollection)
            }
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        for index in offsets {
            let group = groups[index]
            let filenames = group.items.map(\.imageFilename)
            if group.id == selectedGroupID {
                selectedGroupID = nil
            }
            modelContext.delete(group)
            do {
                try modelContext.save()
                // Deliberately synchronous: the rows are already gone, so if the
                // process died before a deferred cleanup ran, these files would be
                // orphaned in Documents forever (nothing sweeps for them).
                for filename in filenames {
                    ImageStore.deleteImage(filename: filename)
                }
            } catch {
                // Model delete failed; image files preserved. Undo the pending
                // delete too, or a later save would commit it and orphan them.
                modelContext.rollback()
            }
        }
    }

    private func importCollection(from url: URL) {
        pendingImports.append(url)
        guard !isImportingCollection else { return }
        isImportingCollection = true

        Task { @MainActor in
            // Lets a long import finish if the user switches apps.
            let backgroundActivity = BackgroundActivity(name: "Import Collection")
            defer { backgroundActivity.end() }

            var failures: [String] = []
            while !pendingImports.isEmpty {
                let next = pendingImports.removeFirst()
                do {
                    try await CollectionArchiveService.importCollection(from: next, container: modelContext.container)
                } catch {
                    failures.append(error.localizedDescription)
                }
                // The app does not expose Documents, so an Inbox copy is useless
                // to the user once the import has been attempted either way.
                CollectionArchiveService.removeInboxCopy(at: next)
            }
            isImportingCollection = false
            if !failures.isEmpty {
                transferErrorMessage = failures.joined(separator: "\n\n")
                showingTransferError = true
            }
        }
    }

    @ViewBuilder
    private func progressOverlay(title: String) -> some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()

            // This overlay spans both columns, so on a partly folded iPhone Duo
            // its center is the hinge; keep the card on the leading side.
            GeometryReader { proxy in
                let fold = proxy.reservedRegions(kind: .division).first(where: \.isActive)
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(title)
                        .font(.headline)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .frame(width: fold.map { max($0.frame.minX, 0) } ?? proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// A UIKit background task for the lifetime of some work, ended exactly once
/// (by the caller, or by the system's expiration handler).
@MainActor
private final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// One sidebar row. Reads only its own group's items, so editing a photo's
/// notes in one group does not re-render the whole list.
private struct GroupRow: View {
    let group: TrackerGroup

    var body: some View {
        HStack {
            Image(systemName: group.icon)
            Text(group.name)
            Text(group.items.count == 1 ? "1 item" : "\(group.items.count) items")
                .fontWeight(.light)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
