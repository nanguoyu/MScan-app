import Combine
import Foundation
import MScanCore

struct DeviceAnnotation: Equatable {
    var alias = ""
    var comment = ""
    var url = ""
}

// Each field has its own revision so simultaneous name and comment edits on
// two Macs can be merged. Empty values are retained to propagate deletions.
private struct AnnotationField: Codable, Equatable {
    var value = ""
    var revision: UInt64 = 0
    var writer = ""

    mutating func merge(_ incoming: Self) {
        if (revision, writer) < (incoming.revision, incoming.writer) {
            self = incoming
        }
    }
}

private struct AnnotationRecord: Codable, Equatable {
    var alias = AnnotationField()
    var comment = AnnotationField()
    var url = AnnotationField()

    var value: DeviceAnnotation {
        DeviceAnnotation(alias: alias.value, comment: comment.value, url: url.value)
    }

    mutating func merge(_ incoming: Self) {
        alias.merge(incoming.alias)
        comment.merge(incoming.comment)
        url.merge(incoming.url)
    }

    mutating func apply(_ draft: DeviceAnnotation, replacing original: DeviceAnnotation, writer: String) throws {
        let revision = max(alias.revision, comment.revision, url.revision).addingReportingOverflow(1)
        guard !revision.overflow else { throw LibraryProblem.invalidArchive }
        if draft.alias != original.alias {
            alias = AnnotationField(value: draft.alias, revision: revision.partialValue, writer: writer)
        }
        if draft.comment != original.comment {
            comment = AnnotationField(value: draft.comment, revision: revision.partialValue, writer: writer)
        }
        if draft.url != original.url {
            url = AnnotationField(value: draft.url, revision: revision.partialValue, writer: writer)
        }
    }
}

enum AnnotationImportPolicy {
    case keepExisting
    case useBackup
}

private typealias Annotations = [String: AnnotationRecord]

private enum LibraryProblem: LocalizedError {
    case invalidArchive, invalidKey, invalidFolder, invalidDelimiter

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return appText("The annotation file has an unrecognized format or version.")
        case .invalidKey: return appText("The device identifier is empty.")
        case .invalidFolder: return appText("Choose a sync folder you can access.")
        case .invalidDelimiter: return appText("Choose a comma, semicolon, tab, or pipe as the export delimiter.")
        }
    }
}

private struct AnnotationArchive: Codable {
    let version: Int
    var devices: Annotations

    init(_ devices: Annotations) {
        version = 1
        self.devices = devices
    }

    static func read(_ file: URL) throws -> Annotations {
        let archive = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard archive.version == 1, !archive.devices.keys.contains(where: \.isEmpty) else {
            throw LibraryProblem.invalidArchive
        }
        return archive.devices
    }

    static func merge(_ incoming: Annotations, into records: inout Annotations) {
        for (key, update) in incoming {
            records[key, default: AnnotationRecord()].merge(update)
        }
    }

    static func write(_ records: Annotations, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Self(records)).write(to: file, options: .atomic)
    }
}

@MainActor
final class DeviceLibrary: ObservableObject {
    @Published private(set) var syncDirectory: URL?
    @Published private var syncIssue: Error?
    var syncError: String? { syncIssue.map(L10n.errorDescription) }
    @Published private var records: Annotations = [:]
    private let localFile: URL
    private let writer: String
    private let defaults: UserDefaults
    private var timer: Timer?
    private var scopedDirectory: URL?

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MScan", isDirectory: true)
        localFile = base.appendingPathComponent("annotations.json")
        if let existing = defaults.string(forKey: "annotationWriter"), UUID(uuidString: existing) != nil {
            writer = existing
        } else {
            writer = UUID().uuidString
            defaults.set(writer, forKey: "annotationWriter")
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: localFile.path) {
                records = try AnnotationArchive.read(localFile)
            }
            if let bookmark = defaults.data(forKey: "annotationSyncFolder") {
                var stale = false
                let folder = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil,
                                     bookmarkDataIsStale: &stale)
                try enableSync(in: folder)
            }
        } catch {
            syncIssue = error
        }
    }

    func annotation(for key: String) -> DeviceAnnotation {
        records[key]?.value ?? DeviceAnnotation()
    }

    func save(_ annotation: DeviceAnnotation, for key: String, replacing original: DeviceAnnotation? = nil) throws {
        guard !key.isEmpty else { throw LibraryProblem.invalidKey }
        let original = original ?? self.annotation(for: key)
        guard original != annotation else { return }
        try updateLocal { contents in
            try contents[key, default: AnnotationRecord()].apply(annotation, replacing: original, writer: writer)
        }
        refreshAfterEdit()
    }

    func importAnnotations(from file: URL, policy: AnnotationImportPolicy = .keepExisting) throws {
        let imported = try AnnotationArchive.read(file)
        try updateLocal { local in
            for (key, backup) in imported {
                guard var current = local[key] else {
                    local[key] = backup
                    continue
                }
                let existing = current.value
                var chosen = backup.value
                if policy == .keepExisting {
                    if !existing.alias.isEmpty { chosen.alias = existing.alias }
                    if !existing.comment.isEmpty { chosen.comment = existing.comment }
                    if !existing.url.isEmpty { chosen.url = existing.url }
                }
                // Choose explicitly between the backup and current values, even
                // when we subsequently encounter this backup's revisions in sync.
                current.merge(backup)
                try current.apply(chosen, replacing: current.value, writer: writer)
                local[key] = current
            }
        }
        refreshAfterEdit()
    }

    func exportAnnotations(to file: URL) throws {
        try AnnotationArchive.write(records, to: file)
    }

    func enableSync(in directory: URL) throws {
        let accessing = directory.startAccessingSecurityScopedResource()
        do {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw LibraryProblem.invalidFolder
            }
            let bookmark = try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try sync(with: directory)
            scopedDirectory?.stopAccessingSecurityScopedResource()
            scopedDirectory = accessing ? directory : nil
            syncDirectory = directory
            defaults.set(bookmark, forKey: "annotationSyncFolder")
            syncIssue = nil
            startRefreshTimer()
        } catch {
            if accessing { directory.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func disableSync() {
        timer?.invalidate()
        timer = nil
        scopedDirectory?.stopAccessingSecurityScopedResource()
        scopedDirectory = nil
        syncDirectory = nil
        syncIssue = nil
        defaults.removeObject(forKey: "annotationSyncFolder")
    }

    func refresh() throws {
        do {
            if let syncDirectory {
                try sync(with: syncDirectory)
            } else {
                try updateLocal { _ in }
            }
            syncIssue = nil
        } catch {
            syncIssue = error
            throw error
        }
    }

    private func startRefreshTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                try? self.refresh()
            }
        }
    }

    private func refreshAfterEdit() {
        if syncDirectory != nil { try? refresh() }
    }

    // Every installation owns one replica. A disconnected Mac can update its
    // own file without replacing any other Mac's version of the database.
    private func sync(with directory: URL) throws {
        let manager = FileManager.default
        let shared = directory.appendingPathComponent("MScan Annotations", isDirectory: true)
        try manager.createDirectory(at: shared, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isRegularFileKey]
        let siblings = try manager.contentsOfDirectory(at: shared, includingPropertiesForKeys: Array(keys))
        var incoming: Annotations = [:]
        for file in siblings {
            if file.lastPathComponent.hasPrefix(".replica-"), file.pathExtension == "icloud" {
                let name = String(file.deletingPathExtension().lastPathComponent.dropFirst())
                try manager.startDownloadingUbiquitousItem(at: shared.appendingPathComponent(name))
                continue
            }
            guard file.lastPathComponent.hasPrefix("replica-"), file.pathExtension == "json" else { continue }
            let attributes = try file.resourceValues(forKeys: keys)
            guard attributes.isRegularFile == true else { continue }
            if attributes.ubiquitousItemDownloadingStatus == .notDownloaded {
                try manager.startDownloadingUbiquitousItem(at: file)
                continue
            }
            try Self.coordinatedRead(file) { readable in
                AnnotationArchive.merge(try AnnotationArchive.read(readable), into: &incoming)
            }
        }
        try updateLocal { AnnotationArchive.merge(incoming, into: &$0) }
        let own = shared.appendingPathComponent("replica-\(writer).json")
        try Self.coordinatedWrite(own) { writable in
            var contents: Annotations = [:]
            let exists = manager.fileExists(atPath: writable.path)
            if exists { contents = try AnnotationArchive.read(writable) }
            let before = contents
            AnnotationArchive.merge(records, into: &contents)
            if contents != before || !exists {
                try AnnotationArchive.write(contents, to: writable)
            }
        }
    }

    private func updateLocal(_ edit: (inout Annotations) throws -> Void) throws {
        var committed = records
        try Self.coordinatedWrite(localFile) { writable in
            let exists = FileManager.default.fileExists(atPath: writable.path)
            let disk = exists ? try AnnotationArchive.read(writable) : [:]
            AnnotationArchive.merge(disk, into: &committed)
            try edit(&committed)
            if disk != committed { try AnnotationArchive.write(committed, to: writable) }
        }
        if records != committed { records = committed }
    }

    private static func coordinatedRead(_ file: URL, body: (URL) throws -> Void) throws {
        var error: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &error) { url in
            result = Result { try body(url) }
        }
        if let error { throw error }
        try result?.get()
    }

    private static func coordinatedWrite(_ file: URL, body: (URL) throws -> Void) throws {
        var error: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &error) { url in
            result = Result { try body(url) }
        }
        if let error { throw error }
        try result?.get()
    }
}

enum ScanCSV {
    static func write(headers: [String], rows: [[String]], delimiter: Character, to file: URL) throws {
        guard !rows.isEmpty else { return } // Preserve the last export when a filter hides every result.
        guard [",", ";", "|", "\t"].contains(delimiter) else { throw LibraryProblem.invalidDelimiter }
        let text = ([headers] + rows).map { row in
            row.map { value in
                // Spreadsheet apps may evaluate text supplied by a remote device.
                let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
                let formula = first.map { "=+-@".contains($0) } == true
                let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"" + (formula ? "'" : "") + escaped + "\""
            }.joined(separator: String(delimiter))
        }.joined(separator: "\r\n")
        try Data(("\u{FEFF}" + text + "\r\n").utf8).write(to: file, options: .atomic)
    }
}
