import AVFoundation
import CryptoKit
import Foundation
import MurmurAudioCore

/// The one place where Murmure decides where user-created data lives.
///
/// The preferred location is a dedicated folder on the operator's mounted external drive.
/// Nothing in this type removes or replaces an existing item: migration copies legacy files
/// when the destination is absent and writes a uniquely named side copy when there is a
/// conflict. The old Application Support folder is deliberately left untouched.
enum MurmureDataStore {
    static let folderName = "Murmure Data"
    static let preferredVolumeURL = URL(fileURLWithPath: "/Volumes/Extreme Pro", isDirectory: true)
    static let externalRootURL = preferredVolumeURL.appendingPathComponent(folderName, isDirectory: true)

    /// The legacy location used by the upstream app. It remains an update inbox, so migration
    /// skips that directory and only copies user-created data.
    static let legacyRootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MurmurYouTube", isDirectory: true)

    private static let bootstrapResult = bootstrap()

    static var rootURL: URL { bootstrapResult.rootURL }
    static var recordingsURL: URL { rootURL.appendingPathComponent("Recordings", isDirectory: true) }
    static var runsURL: URL { rootURL.appendingPathComponent("runs.jsonl") }
    static var dictionaryURL: URL { rootURL.appendingPathComponent("dictionary.txt") }
    static var dashboardURL: URL { rootURL.appendingPathComponent("dashboard.html") }
    static var settingsURL: URL { rootURL.appendingPathComponent("settings.json") }
    static var snippetsURL: URL { rootURL.appendingPathComponent("snippets.json") }

    /// The folder selected during launch. If the preferred drive is not mounted, we keep the
    /// app usable with a clearly surfaced local emergency path rather than silently losing a
    /// transcript. A connected drive is required for the normal path.
    static var usesExternalStorage: Bool { bootstrapResult.usesExternalStorage }

    /// The mount is validated lazily. Touching a removable APFS directory from the main
    /// thread can block while macOS resumes the volume, so launch-time UI treats the configured
    /// volume as ready and all real file operations still fail safely if it is unavailable.
    static var externalDriveConnected: Bool {
        usesExternalStorage
    }

    static var statusTitle: String {
        if usesExternalStorage && externalDriveConnected { return "External storage ready" }
        if usesExternalStorage { return "Reconnect external drive" }
        return "Local emergency storage"
    }

    static var statusDetail: String {
        if usesExternalStorage && externalDriveConnected {
            return "Audio, history, dictionary, and settings save to \(externalRootURL.path)."
        }
        if usesExternalStorage {
            return "Murmure cannot reach \(preferredVolumeURL.path). Reconnect it before recording new audio."
        }
        return "The external drive was unavailable at launch, so new data is temporarily in \(rootURL.path)."
    }

    static var migrationDetail: String { bootstrapResult.migrationDetail }

    /// A relative path is persisted in history so the data folder can be moved as one unit.
    static func relativePath(for url: URL) -> String? {
        let root = rootURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate == root || candidate.hasPrefix(root + "/") else { return nil }
        return String(candidate.dropFirst(root.count + (candidate == root ? 0 : 1)))
    }

    static func url(forRelativePath path: String) -> URL? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
        let root = rootURL.standardizedFileURL.path
        guard candidate.path == root || candidate.path.hasPrefix(root + "/") else { return nil }
        return candidate
    }

    private struct BootstrapResult: Sendable {
        let rootURL: URL
        let usesExternalStorage: Bool
        let migrationDetail: String
    }

    private enum CopyResult {
        case copied
        case alreadyPresent
        case preservedConflict(URL)
        case failed
    }

    private static func bootstrap() -> BootstrapResult {
        let fileManager = FileManager.default

        if createDirectory(externalRootURL, using: fileManager),
           createDirectory(externalRootURL.appendingPathComponent("Recordings", isDirectory: true), using: fileManager) {
            return BootstrapResult(
                rootURL: externalRootURL,
                usesExternalStorage: true,
                migrationDetail: "Legacy migration runs in the background after launch."
            )
        }

        // Emergency fallback is intentionally the old directory, never another volume. This
        // avoids accidentally writing personal data to an unrelated mounted disk.
        _ = createDirectory(legacyRootURL, using: fileManager)
        _ = createDirectory(legacyRootURL.appendingPathComponent("Recordings", isDirectory: true), using: fileManager)
        return BootstrapResult(
            rootURL: legacyRootURL,
            usesExternalStorage: false,
            migrationDetail: "External drive unavailable; no legacy files were moved."
        )
    }

    /// Performs legacy migration away from the launch path. External-volume directory reads
    /// are allowed to take as long as the filesystem needs without freezing the SwiftUI scene.
    static func beginDeferredMigration() {
        guard usesExternalStorage else { return }
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            _ = migrateLegacyData(to: externalRootURL, using: fileManager)
            writeReadmeIfMissing(at: externalRootURL.appendingPathComponent("README.md"), using: fileManager)
        }
    }

    @discardableResult
    private static func createDirectory(_ url: URL, using fileManager: FileManager) -> Bool {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return fileManager.fileExists(atPath: url.path)
        }
    }

    private static func migrateLegacyData(to destinationRoot: URL, using fileManager: FileManager) -> String {
        guard fileManager.fileExists(atPath: legacyRootURL.path),
              legacyRootURL.standardizedFileURL.path != destinationRoot.standardizedFileURL.path,
              let items = try? fileManager.contentsOfDirectory(
                  at: legacyRootURL,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return "No legacy data needed migration."
        }

        var copied = 0
        var conflicts = 0
        var preserved = 0

        for item in items {
            // The update inbox is app machinery, not personal data. Keeping it in its legacy
            // location means the updater can continue to find staged bundles across upgrades.
            if item.lastPathComponent == "Updates" { continue }

            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let destination: URL
            if isDirectory || !Self.userDataFileNames.contains(item.lastPathComponent) {
                let imported = destinationRoot.appendingPathComponent("Imported Local Data", isDirectory: true)
                _ = createDirectory(imported, using: fileManager)
                destination = imported.appendingPathComponent(item.lastPathComponent, isDirectory: isDirectory)
            } else {
                destination = destinationRoot.appendingPathComponent(item.lastPathComponent)
            }

            switch copyPreserving(item, to: destination, using: fileManager) {
            case .copied: copied += 1
            case .preservedConflict: conflicts += 1
            case .alreadyPresent: break
            case .failed: preserved += 1
            }
        }

        var detail = copied == 0 ? "Legacy data was already represented." : "Copied \(copied) legacy item\(copied == 1 ? "" : "s") to the external drive."
        if conflicts > 0 {
            detail += " Preserved \(conflicts) conflicting item\(conflicts == 1 ? "" : "s") as local-copy files."
        }
        if preserved > 0 {
            detail += " \(preserved) item\(preserved == 1 ? " was" : "s were") left in place after a copy error."
        }
        return detail
    }

    private static let userDataFileNames: Set<String> = [
        "runs.jsonl",
        "dictionary.txt",
        "dashboard.html",
        "settings.json"
    ]

    private static func copyPreserving(_ source: URL, to destination: URL, using fileManager: FileManager) -> CopyResult {
        if !fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.copyItem(at: source, to: destination)
                return .copied
            } catch {
                return .failed
            }
        }

        // A generated file such as the dashboard can legitimately differ from the legacy
        // copy on every launch. If we already preserved a conflict, keep it rather than
        // creating another UUID-named duplicate; existing files are never removed. We do not
        // compare file contents here: reading an item on a removable APFS volume can block
        // behind macOS's security-scoped file-open and would prevent the first window from
        // appearing. The source stays untouched, and an existing conflict is enough evidence
        // that this legacy item has already been preserved.
        if matchingConflictExists(for: destination, using: fileManager) {
            return .alreadyPresent
        }

        let conflict = uniqueConflictURL(for: destination)
        do {
            try fileManager.copyItem(at: source, to: conflict)
            return .preservedConflict(conflict)
        } catch {
            return .failed
        }
    }

    private static func matchingConflictExists(for destination: URL, using fileManager: FileManager) -> Bool {
        let stem = destination.deletingPathExtension().lastPathComponent + ".local-copy-"
        let ext = destination.pathExtension
        guard let items = try? fileManager.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        return items.contains { candidate in
            candidate.deletingPathExtension().lastPathComponent.hasPrefix(stem)
                && candidate.pathExtension == ext
        }
    }

    private static func uniqueConflictURL(for destination: URL) -> URL {
        let stem = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        let suffix = ".local-copy-\(UUID().uuidString.lowercased())"
        let name = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
        return destination.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    private static func writeReadmeIfMissing(at url: URL, using fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        let text = """
        # Murmure data

        This folder belongs to Murmure. It contains your local dictionary, transcript history,
        generated dashboard, settings, and microphone recordings. Keep the Extreme Pro drive
        connected before recording so new audio and history remain here.

        Murmure never removes unrelated files from this drive. Legacy files are copied from the
        old Mac-only location without deleting the originals; conflicts are preserved as files
        named `*.local-copy-*`.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Writes the captured PCM buffers as local CAF files after a dictation has finished.
///
/// The relative filename is stored in `DictationRun`, so the audio remains associated with its
/// transcript without embedding a machine-specific absolute path in the history file.
enum AudioHistoryStore {
    static func promoteStagedAudio(from source: URL, id: UUID) async -> AudioPromotionResult {
        await promoteStagedAudio(from: source, id: id, destinationRoot: MurmureDataStore.rootURL)
    }

    static func promoteStagedAudio(
        from source: URL,
        id: UUID,
        destinationRoot: URL
    ) async -> AudioPromotionResult {
        await Task.detached(priority: .utility) {
            do {
                let fileManager = FileManager.default
                let root = destinationRoot.standardizedFileURL
                let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
                let filename = "\(id.uuidString.lowercased()).caf"
                let destination = recordings.appendingPathComponent(filename, isDirectory: false)
                guard let relativePath = relativePath(for: destination, under: root) else {
                    return .failed("The recording destination escaped the data root.")
                }

                guard fileManager.fileExists(atPath: source.path) else {
                    return .failed("Staged audio is missing.")
                }
                try fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)

                if fileManager.fileExists(atPath: destination.path) {
                    return try matchingAudio(source, destination)
                        ? .alreadyPromoted(relativePath: relativePath)
                        : .failed("A different recording already exists at the destination.")
                }

                let temporary = recordings.appendingPathComponent(
                    ".\(filename).promoting-\(UUID().uuidString.lowercased())",
                    isDirectory: false
                )
                defer { try? fileManager.removeItem(at: temporary) }
                try fileManager.copyItem(at: source, to: temporary)
                guard try matchingAudio(source, temporary) else {
                    return .failed("The promoted audio did not match its staged source.")
                }

                do {
                    try fileManager.moveItem(at: temporary, to: destination)
                } catch {
                    if fileManager.fileExists(atPath: destination.path) {
                        return try matchingAudio(source, destination)
                            ? .alreadyPromoted(relativePath: relativePath)
                            : .failed("A different recording won the destination race.")
                    }
                    throw error
                }

                guard try matchingAudio(source, destination) else {
                    return .failed("The final audio did not match its staged source.")
                }
                return .promoted(relativePath: relativePath)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }

    static func save(_ chunks: [AudioChunk], id: UUID) -> String? {
        guard chunks.contains(where: { $0.buffer.frameLength > 0 }) else { return nil }

        let directory = MurmureDataStore.recordingsURL
        let filename = "\(id.uuidString.lowercased()).caf"
        let url = directory.appendingPathComponent(filename)
        let relativePath = MurmureDataStore.relativePath(for: url)

        // Creating an AVAudioFile on a removable drive can wait for the volume to resume.
        // Never make the main actor (and therefore the Record button) wait on that open. A
        // UUID filename is collision-resistant, and the writer itself refuses malformed
        // buffers without a process-fatal precondition.
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmure-\(id.uuidString.lowercased()).caf")
        Task.detached(priority: .utility) {
            do {
                // AVAudioFile can be unusually slow to create a new container directly on a
                // sleeping removable volume. Encode locally first, then perform one ordinary
                // file copy to the external drive; both operations stay off the UI actor.
                try AudioArchiveWriter.write(chunks.map(\.buffer), to: temporaryURL)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: temporaryURL, to: url)
            } catch {
                Log.audio.error("audio history save failed: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        return relativePath
    }

    static func url(for relativePath: String) -> URL? {
        MurmureDataStore.url(forRelativePath: relativePath)
    }

    static func remove(relativePaths: Set<String>) async {
        let urls = relativePaths.compactMap(url(for:))
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for url in urls where fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    Log.audio.error("audio history delete failed: \(error.localizedDescription)")
                }
            }
        }.value
    }

    private static func matchingAudio(_ lhs: URL, _ rhs: URL) throws -> Bool {
        try fingerprint(lhs) == fingerprint(rhs)
    }

    private static func relativePath(for url: URL, under rootURL: URL) -> String? {
        let root = rootURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return nil }
        return String(candidate.dropFirst(root.count + 1))
    }

    private static func fingerprint(_ url: URL) throws -> AudioFingerprint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return AudioFingerprint(size: size, digest: Data(hasher.finalize()))
    }

}

enum AudioPromotionResult: Equatable, Sendable {
    case promoted(relativePath: String)
    case alreadyPromoted(relativePath: String)
    case failed(String)
}

private struct AudioFingerprint: Equatable {
    let size: Int
    let digest: Data
}
