import Foundation
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// Binary container described in CollectionArchiveFormat.swift.
    static let pictureTrackCollection = UTType(exportedAs: "com.maxxu.picturetrack.collection", conformingTo: .data)
}

/// App-side failures; format violations surface as CollectionArchiveFormat.FormatError.
enum CollectionArchiveError: LocalizedError {
    case unreadableFile
    case missingImage(String)
    case invalidImageData(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The selected file could not be read."
        case .missingImage(let filename):
            return "Export failed because image data is missing for \(filename)."
        case .invalidImageData(let identifier):
            return "The collection contains a photo that is not a readable image (\(identifier))."
        }
    }
}

struct CollectionArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pictureTrackCollection] }
    static var writableContentTypes: [UTType] { [.pictureTrackCollection] }

    /// File-backed (mapped) so the archive stays evictable clean pages
    /// rather than dirty heap while the exporter is presented.
    let archiveData: Data

    init(archiveData: Data) {
        self.archiveData = archiveData
    }

    /// The document type is export-only: imports go through
    /// `CollectionArchiveService.importCollection(from:container:)`, which maps
    /// the file instead of reading it into memory like `regularFileContents`.
    init(configuration: ReadConfiguration) throws {
        throw CollectionArchiveError.unreadableFile
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: archiveData)
    }
}

enum CollectionArchiveService {
    struct ExportSnapshot: Sendable {
        let groupID: String
        let name: String
        let icon: String
        let items: [ExportItemSnapshot]
    }

    struct ExportItemSnapshot: Sendable {
        let itemID: String
        let imageFilename: String
        let notes: String
        let dateCreated: Date
    }

    static func defaultFilename(for groupName: String) -> String {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let sanitized = trimmed.components(separatedBy: invalidCharacters).joined(separator: "-")
        return sanitized.isEmpty ? "Collection" : sanitized
    }

    static func makeDocument(from snapshot: ExportSnapshot) async throws -> CollectionArchiveDocument {
        try await Task.detached(priority: .userInitiated) {
            let group = CollectionArchiveFormat.GroupMetadata(
                originalID: snapshot.groupID, name: snapshot.name, icon: snapshot.icon, exportedAt: Date()
            )
            // Deterministic output order (date, then id); a stable sort.
            let items = snapshot.items
                .map { item in
                    (item, CollectionArchiveFormat.ItemMetadata(originalID: item.itemID, notes: item.notes, dateCreated: item.dateCreated))
                }
                .enumerated()
                .sorted { lhs, rhs in
                    if CollectionArchiveFormat.exportOrder(lhs.element.1, rhs.element.1) { return true }
                    if CollectionArchiveFormat.exportOrder(rhs.element.1, lhs.element.1) { return false }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)

            // Every format rule and the free space are checked before a byte is written.
            let preflightItems = try items.map { item, metadata in
                let url = ImageStore.documentsDirectory.appendingPathComponent(item.imageFilename)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    throw CollectionArchiveError.missingImage(item.imageFilename)
                }
                return CollectionArchiveFormat.PreflightItem(metadata: metadata, imageByteCount: size)
            }
            let archiveSize = try CollectionArchiveFormat.preflight(group: group, items: preflightItems)
            try CollectionArchiveFormat.checkFreeSpace(required: archiveSize, at: FileManager.default.temporaryDirectory)

            // Stream the archive into a temp file one photo at a time, then hand
            // out a mapped Data: the archive lives as evictable file-backed pages
            // instead of heap for as long as the exporter sheet is up. The file is
            // unlinked right away — the mapping keeps the pages valid until the
            // Data is released, and the kernel reclaims the space even on crash.
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let writer = try CollectionArchiveFormat.Writer(url: tempURL, group: group, itemCount: items.count)
            for (item, metadata) in items {
                try Task.checkCancellation()
                guard let imageData = ImageStore.loadImageData(filename: item.imageFilename) else {
                    throw CollectionArchiveError.missingImage(item.imageFilename)
                }
                // Same check import applies, so an unimportable photo fails here instead.
                guard ImageStore.isTransferableImageData(imageData) else {
                    throw CollectionArchiveError.invalidImageData(item.imageFilename)
                }
                try writer.append(metadata, imageData: imageData)
            }
            try writer.finish()

            return CollectionArchiveDocument(archiveData: try CollectionArchiveFormat.mapForReading(tempURL))
        }.value
    }

    /// Reads, fully validates, and imports a collection file. Nothing is written
    /// unless the whole file checks out; a failure part-way through the writes
    /// removes every image already copied, and an import cut short by the
    /// process dying is cleaned up by `recoverInterruptedImports` next launch.
    static func importCollection(from url: URL, container: ModelContainer) async throws {
        try await Task.detached(priority: .userInitiated) {
            // Everything up to the first write is side-effect free: copy, map,
            // verify every byte, check every photo.
            let data = try mapPrivateCopy(of: url)
            let archive = try CollectionArchiveFormat.read(data)
            for item in archive.items where !ImageStore.isTransferableImageData(item.imageData) {
                throw CollectionArchiveError.invalidImageData(item.metadata.originalID)
            }

            let importContext = ModelContext(container)
            let icon = UIImage(systemName: archive.group.icon) == nil ? Symbols.defaultSymbol : archive.group.icon
            let group = TrackerGroup(name: archive.group.name, icon: icon)
            importContext.insert(group)

            // Record the files about to be written before writing any of them.
            let filenames = archive.items.map { _ in UUID().uuidString }
            let journal = try ImportJournal.begin(filenames: filenames)

            var writtenFilenames: [String] = []
            do {
                for (archivedItem, filename) in zip(archive.items, filenames) {
                    try ImageStore.saveImageData(archivedItem.imageData, filename: filename)
                    writtenFilenames.append(filename)

                    let item = TrackerItem(
                        imageFilename: filename,
                        notes: archivedItem.metadata.notes,
                        dateCreated: archivedItem.metadata.dateCreated
                    )
                    item.group = group
                    importContext.insert(item)
                }
                try importContext.save()
                journal.finish()
            } catch {
                for filename in writtenFilenames {
                    ImageStore.deleteFile(filename: filename)
                }
                journal.finish()
                throw error
            }
        }.value
    }

    /// Deletes photos left behind by an import that never reached its save
    /// (the process was killed or crashed part-way through). Run at launch.
    static func recoverInterruptedImports(container: ModelContainer) async {
        await Task.detached(priority: .utility) {
            for journal in ImportJournal.leftovers() {
                let names = journal.filenames
                let context = ModelContext(container)
                let referenced = (try? context.fetch(FetchDescriptor<TrackerItem>(
                    predicate: #Predicate { names.contains($0.imageFilename) }
                )))?.map(\.imageFilename)
                // If the store cannot be read, keep the files and the record for next time.
                guard let referenced else { continue }
                let kept = Set(referenced)
                for filename in names where !kept.contains(filename) {
                    ImageStore.deleteFile(filename: filename)
                }
                journal.finish()
            }
        }.value
    }

    /// Returns the picked file as a read-only memory map of a private copy.
    ///
    /// The coordinated read makes iCloud/File Provider items download first.
    /// Copying (an APFS clone when possible) means the bytes cannot change, or
    /// the file be truncated under the mapping (SIGBUS), between verification
    /// and import. The copy is unlinked right away; the mapping keeps it alive.
    /// mapForReading calls mmap directly because `.alwaysMapped` is only a hint
    /// and may silently read a multi-GB archive into the heap.
    private static func mapPrivateCopy(of url: URL) throws -> Data {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copyURL = stagingDirectory.appendingPathComponent("import.ptcollection")
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        var coordinationError: NSError?
        var copyError: Swift.Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            do {
                try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: readURL, to: copyURL)
            } catch {
                copyError = error
            }
        }
        guard coordinationError == nil, copyError == nil else {
            throw CollectionArchiveError.unreadableFile
        }

        do {
            return try CollectionArchiveFormat.mapForReading(copyURL)
        } catch let error as CollectionArchiveFormat.FormatError {
            throw error
        } catch {
            throw CollectionArchiveError.unreadableFile
        }
    }

    /// "Open in PictureTrack" (Files, AirDrop, Mail) copies the file into
    /// Documents/Inbox; remove that copy once the import has been attempted.
    static func removeInboxCopy(at url: URL) {
        let inbox = ImageStore.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        guard url.standardizedFileURL.deletingLastPathComponent().path == inbox else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The filenames an import is about to write, recorded in Application Support
/// before the first write and removed once the rows are saved or the files
/// rolled back. A record that outlives its process names files that may have
/// no row. Plain text, one UUID filename per line.
private struct ImportJournal {
    let url: URL
    let filenames: [String]

    private static let directory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportJournals", isDirectory: true)
    }()

    /// Records made by this process carry its id, so launch recovery never
    /// touches an import that is still running.
    private static let processID = UUID().uuidString

    static func begin(filenames: [String]) throws -> ImportJournal {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(processID)_\(UUID().uuidString).txt")
        try filenames.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return ImportJournal(url: url, filenames: filenames)
    }

    static func leftovers() -> [ImportJournal] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "txt" && !$0.lastPathComponent.hasPrefix(processID) }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                // Only well-formed UUID names, so a damaged record can never name another path.
                let names = text.split(separator: "\n").map(String.init).filter { UUID(uuidString: $0) != nil }
                return ImportJournal(url: url, filenames: names)
            }
    }

    func finish() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum FileTransferErrorHelper {
    static func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
