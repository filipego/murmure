import Foundation
import Observation

@MainActor
@Observable
final class RecoverableRecordingStore {
    static let shared = RecoverableRecordingStore()

    private(set) var recordings: [RecoverableRecording] = []
    @ObservationIgnored
    private let load: (@MainActor @Sendable () async -> [RecoverableRecording])?
    @ObservationIgnored
    private let discard: (@MainActor @Sendable (UUID) async -> Bool)?

    private init() {
        load = nil
        discard = nil
    }

    init(
        load: @escaping @MainActor @Sendable () async -> [RecoverableRecording],
        discard: (@MainActor @Sendable (UUID) async -> Bool)? = nil
    ) {
        self.load = load
        self.discard = discard
    }

    func refresh() async {
        if let load {
            recordings = await load()
        } else {
            recordings = await RecordingSessionRuntime.coordinator.recoverableRecordings()
        }
    }

    func delete(id: UUID) async -> Bool {
        let succeeded = if let discard {
            await discard(id)
        } else {
            await RecordingSessionRuntime.coordinator.discardRecoverableRecording(id: id)
        }
        if succeeded { recordings.removeAll { $0.id == id } }
        return succeeded
    }

    func deleteAll() async -> Bool {
        let ids = recordings.map(\.id)
        var succeeded = true
        for id in ids {
            if !(await delete(id: id)) {
                succeeded = false
            }
        }
        return succeeded
    }
}
