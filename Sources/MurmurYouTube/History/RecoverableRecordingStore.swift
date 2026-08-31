import Observation

@MainActor
@Observable
final class RecoverableRecordingStore {
    static let shared = RecoverableRecordingStore()

    private(set) var recordings: [RecoverableRecording] = []
    @ObservationIgnored
    private let load: (@MainActor @Sendable () async -> [RecoverableRecording])?

    private init() {
        load = nil
    }

    init(load: @escaping @MainActor @Sendable () async -> [RecoverableRecording]) {
        self.load = load
    }

    func refresh() async {
        if let load {
            recordings = await load()
        } else {
            recordings = await RecordingSessionRuntime.coordinator.recoverableRecordings()
        }
    }
}
