import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pictureTrackCollection = UTType(exportedAs: "com.maxxu.picturetrack.collection", conformingTo: .json)
}

struct CollectionArchive: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAt: Date
    let group: GroupRecord
    let items: [ItemRecord]

    struct GroupRecord: Codable, Sendable {
        let originalID: String
        let name: String
        let icon: String
    }

    struct ItemRecord: Codable, Sendable {
        let originalID: String
        let originalFilename: String
        let notes: String
        let dateCreated: Date
        let imageData: Data
    }

    func validated() throws -> CollectionArchive {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CollectionArchiveError.unsupportedVersion(schemaVersion)
        }

        let trimmedName = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CollectionArchiveError.invalidGroupName
        }

        for item in items {
            guard ImageStore.isValidImageData(item.imageData) else {
                throw CollectionArchiveError.invalidImageData(item.originalFilename)
            }
        }

        return self
    }
}

enum CollectionArchiveError: LocalizedError {
    case invalidFile
    case invalidGroupName
    case unsupportedVersion(Int)
    case missingImage(String)
    case invalidImageData(String)
    case importFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "The selected file is not a valid PictureTrack collection."
        case .invalidGroupName:
            return "The collection file is missing a valid collection name."
        case .unsupportedVersion(let version):
            return "This collection file uses an unsupported format version (\(version))."
        case .missingImage(let filename):
            return "Export failed because image data is missing for \(filename)."
        case .invalidImageData(let filename):
            return "The collection file contains invalid image data for \(filename)."
        case .importFailed:
            return "The collection could not be imported."
        }
    }
}

enum CollectionArchiveCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encode(_ archive: CollectionArchive) throws -> Data {
        try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> CollectionArchive {
        do {
            return try decoder.decode(CollectionArchive.self, from: data).validated()
        } catch let error as CollectionArchiveError {
            throw error
        } catch {
            throw CollectionArchiveError.invalidFile
        }
    }
}

struct CollectionArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pictureTrackCollection] }
    static var writableContentTypes: [UTType] { [.pictureTrackCollection] }

    let archiveData: Data

    init(archive: CollectionArchive) throws {
        archiveData = try CollectionArchiveCodec.encode(archive)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CollectionArchiveError.invalidFile
        }

        _ = try CollectionArchiveCodec.decode(data)
        archiveData = data
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
        let archive = try await Task.detached(priority: .userInitiated) {
            let archivedItems = try snapshot.items.sorted { $0.dateCreated < $1.dateCreated }.map { item in
                guard let imageData = ImageStore.loadImageData(filename: item.imageFilename) else {
                    throw CollectionArchiveError.missingImage(item.imageFilename)
                }

                guard ImageStore.isValidImageData(imageData) else {
                    throw CollectionArchiveError.invalidImageData(item.imageFilename)
                }

                return CollectionArchive.ItemRecord(
                    originalID: item.itemID,
                    originalFilename: item.imageFilename,
                    notes: item.notes,
                    dateCreated: item.dateCreated,
                    imageData: imageData
                )
            }

            return CollectionArchive(
                schemaVersion: CollectionArchive.currentSchemaVersion,
                exportedAt: Date(),
                group: .init(
                    originalID: snapshot.groupID,
                    name: snapshot.name,
                    icon: snapshot.icon
                ),
                items: archivedItems
            )
        }.value

        return try CollectionArchiveDocument(archive: archive)
    }

    static func readArchive(from url: URL) async throws -> CollectionArchive {
        let data = try await Task.detached(priority: .userInitiated) {
            let accessedSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            return try Data(contentsOf: url, options: .mappedIfSafe)
        }.value

        return try CollectionArchiveCodec.decode(data)
    }

    @MainActor
    static func importArchive(_ archive: CollectionArchive, into modelContext: ModelContext) throws {
        let importContext = ModelContext(modelContext.container)
        let group = TrackerGroup(name: archive.group.name, icon: archive.group.icon)
        importContext.insert(group)

        var writtenFilenames: [String] = []

        do {
            for archivedItem in archive.items {
                let filename = try ImageStore.saveImageData(archivedItem.imageData)
                writtenFilenames.append(filename)

                let item = TrackerItem(
                    imageFilename: filename,
                    notes: archivedItem.notes,
                    dateCreated: archivedItem.dateCreated
                )
                item.group = group
                importContext.insert(item)
            }

            try importContext.save()
        } catch {
            for filename in writtenFilenames {
                ImageStore.deleteImage(filename: filename)
            }
            throw error
        }
    }
}

enum FileTransferErrorHelper {
    static func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
