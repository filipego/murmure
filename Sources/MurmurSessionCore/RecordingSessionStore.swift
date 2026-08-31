import Foundation

public enum RecordingSessionStoreError: Error, Sendable, Equatable {
    case sessionAlreadyExists(UUID)
    case sessionNotFound(UUID)
    case conflictingCompletion(existing: UUID, requested: UUID)
    case sessionIsNotCompleted(UUID)
}

public actor RecordingSessionStore {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func create(_ manifest: RecordingSessionManifest) throws {
        let manifestURL = manifestURL(for: manifest.id)
        guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RecordingSessionStoreError.sessionAlreadyExists(manifest.id)
        }
        try FileManager.default.createDirectory(
            at: sessionDirectoryURL(for: manifest.id),
            withIntermediateDirectories: true
        )
        try persist(manifest)
    }

    public func load(id: UUID) throws -> RecordingSessionManifest {
        let url = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingSessionStoreError.sessionNotFound(id)
        }
        return try decodeManifest(at: url)
    }

    @discardableResult
    public func release(
        id: UUID,
        at date: Date,
        audioFile: String
    ) throws -> RecordingSessionManifest {
        var manifest = try load(id: id)
        try manifest.release(at: date, audioFile: audioFile)
        try persist(manifest)
        return manifest
    }

    @discardableResult
    public func transition(
        id: UUID,
        to status: RecordingSessionStatus
    ) throws -> RecordingSessionManifest {
        var manifest = try load(id: id)
        try manifest.transition(to: status)
        try persist(manifest)
        return manifest
    }

    public func recoverableSessions() throws -> [RecordingSessionManifest] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return directories.compactMap { directory in
            let url = directory.appendingPathComponent("manifest.json", isDirectory: false)
            guard let manifest = try? decodeManifest(at: url) else { return nil }
            switch manifest.status {
            case .completed, .cancelled:
                return nil
            default:
                return manifest
            }
        }
        .sorted {
            if $0.startedAt == $1.startedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startedAt < $1.startedAt
        }
    }

    public func stagedAudioURL(for id: UUID) -> URL {
        sessionDirectoryURL(for: id).appendingPathComponent("audio.caf", isDirectory: false)
    }

    @discardableResult
    public func markCompleted(id: UUID, runID: UUID) throws -> RecordingSessionManifest {
        var manifest = try load(id: id)
        if case let .completed(existingRunID) = manifest.status {
            guard existingRunID == runID else {
                throw RecordingSessionStoreError.conflictingCompletion(
                    existing: existingRunID,
                    requested: runID
                )
            }
            return manifest
        }

        try manifest.transition(to: .completed(runID: runID))
        try persist(manifest)
        return manifest
    }

    public func removeCompletedSession(id: UUID) throws {
        let manifest = try load(id: id)
        guard manifest.status.isCompleted else {
            throw RecordingSessionStoreError.sessionIsNotCompleted(id)
        }
        try FileManager.default.removeItem(at: sessionDirectoryURL(for: id))
    }

    private func sessionDirectoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        sessionDirectoryURL(for: id).appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func persist(_ manifest: RecordingSessionManifest) throws {
        let data = try JSONEncoder.sessionEncoder.encode(manifest)
        try data.write(to: manifestURL(for: manifest.id), options: .atomic)
    }

    private func decodeManifest(at url: URL) throws -> RecordingSessionManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.sessionDecoder.decode(RecordingSessionManifest.self, from: data)
    }
}
