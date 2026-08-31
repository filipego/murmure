import Foundation
import Speech

private struct ProbeReport: Codable {
    let architecture: String
    let operatingSystem: String
    let locale: String
    let recognizerAvailable: Bool
    let supportsOnDeviceRecognition: Bool
    let authorization: String
    let elapsedSeconds: Double?
    let transcript: String?
    let error: String?
}

private final class RecognitionResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var transcript: String?
    private var error: String?

    func finish(transcript: String? = nil, error: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        self.transcript = transcript
        self.error = error
        return true
    }

    func snapshot() -> (transcript: String?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (transcript, error)
    }
}

private final class AuthorizationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: SFSpeechRecognizerAuthorizationStatus

    init(_ status: SFSpeechRecognizerAuthorizationStatus) {
        self.status = status
    }

    func set(_ status: SFSpeechRecognizerAuthorizationStatus) {
        lock.lock()
        self.status = status
        lock.unlock()
    }

    func get() -> SFSpeechRecognizerAuthorizationStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}

@main
private enum IntelSpeechProbe {
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            writeError("Usage: MurmureIntelSpeechProbe <audio-file> [locale]\n")
            exit(64)
        }

        let audioURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            writeError("Audio file does not exist: \(audioURL.path)\n")
            exit(66)
        }

        let localeIdentifier = CommandLine.arguments.count >= 3
            ? CommandLine.arguments[2]
            : Locale.current.identifier
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            emit(ProbeReport(
                architecture: architecture,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                locale: localeIdentifier,
                recognizerAvailable: false,
                supportsOnDeviceRecognition: false,
                authorization: authorizationLabel(SFSpeechRecognizer.authorizationStatus()),
                elapsedSeconds: nil,
                transcript: nil,
                error: "No speech recognizer exists for this locale."
            ))
            exit(2)
        }

        let authorization = requestAuthorization()
        guard authorization == .authorized else {
            emit(ProbeReport(
                architecture: architecture,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                locale: localeIdentifier,
                recognizerAvailable: recognizer.isAvailable,
                supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
                authorization: authorizationLabel(authorization),
                elapsedSeconds: nil,
                transcript: nil,
                error: "Speech recognition permission was not granted."
            ))
            exit(3)
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let resultBox = RecognitionResultBox()
        let completion = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let error, resultBox.finish(error: error.localizedDescription) {
                completion.signal()
                return
            }
            if let result, result.isFinal,
               resultBox.finish(transcript: result.bestTranscription.formattedString) {
                completion.signal()
            }
        }

        let timedOut = completion.wait(timeout: .now() + 120) == .timedOut
        if timedOut {
            _ = resultBox.finish(error: "Recognition timed out after 120 seconds.")
            task.cancel()
        }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        let result = resultBox.snapshot()
        emit(ProbeReport(
            architecture: architecture,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            locale: localeIdentifier,
            recognizerAvailable: recognizer.isAvailable,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
            authorization: authorizationLabel(authorization),
            elapsedSeconds: seconds,
            transcript: result.transcript,
            error: result.error
        ))
        if result.error != nil { exit(4) }
    }

    private static func requestAuthorization() -> SFSpeechRecognizerAuthorizationStatus {
        let completion = DispatchSemaphore(value: 0)
        let status = AuthorizationBox(SFSpeechRecognizer.authorizationStatus())
        SFSpeechRecognizer.requestAuthorization {
            status.set($0)
            completion.signal()
        }
        completion.wait()
        return status.get()
    }

    private static func authorizationLabel(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    private static var architecture: String {
        #if arch(x86_64)
        "x86_64"
        #elseif arch(arm64)
        "arm64"
        #else
        "unknown"
        #endif
    }

    private static func emit(_ report: ProbeReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { exit(70) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
