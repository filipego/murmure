import Foundation

struct DiagnosticsInput: Sendable {
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let architecture: String
    let microphone: String
    let engine: String
    let language: String
    let modelState: String
    let microphonePermission: String
    let accessibilityPermission: String
    let storageState: String
    let recentOperationFailed: Bool
    /// A test-only canary proves callers cannot accidentally feed private content through.
    /// The collector deliberately has no output field for it.
    let privateContentProbe: String?

    init(
        appVersion: String,
        appBuild: String,
        macOSVersion: String,
        architecture: String,
        microphone: String,
        engine: String,
        language: String,
        modelState: String,
        microphonePermission: String,
        accessibilityPermission: String,
        storageState: String,
        recentOperationFailed: Bool,
        privateContentProbe: String? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.microphone = microphone
        self.engine = engine
        self.language = language
        self.modelState = modelState
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.storageState = storageState
        self.recentOperationFailed = recentOperationFailed
        self.privateContentProbe = privateContentProbe
    }
}

struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    let appVersion: String
    let macOSVersion: String
    let architecture: String
    let microphone: String
    let engine: String
    let language: String
    let modelState: String
    let permissionStates: [String: String]
    let storageState: String
    let lastFailure: String?
}

enum DiagnosticsCollector {
    static func collect(from input: DiagnosticsInput) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "\(input.appVersion) (\(input.appBuild))",
            macOSVersion: input.macOSVersion,
            architecture: input.architecture,
            microphone: input.microphone,
            engine: input.engine,
            language: input.language,
            modelState: input.modelState,
            permissionStates: [
                "Accessibility": input.accessibilityPermission,
                "Microphone": input.microphonePermission
            ],
            storageState: input.storageState,
            lastFailure: input.recentOperationFailed
                ? "A recent local operation failed; see Murmure for its current message."
                : nil
        )
    }

    static func encoded(_ snapshot: DiagnosticsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }
}
