import Foundation
import MurmurDictionary
import Testing

@testable import MurmurYouTube

@Suite("Correction history")
struct CorrectionHistoryTests {
    @Test("legacy runs decode without a correction record")
    func legacyRunDecoding() throws {
        let json = """
            {
              "id": "CB533D44-B408-4B5D-9327-D687D44E7BC2",
              "date": "2026-08-29T12:00:00Z",
              "engine": "Apple",
              "audioSeconds": 1.5,
              "processSeconds": 0.25,
              "text": "Everything is a lie.",
              "audioFile": "Recordings/original.caf"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let run = try decoder.decode(DictationRun.self, from: Data(json.utf8))

        #expect(run.correction == nil)
        #expect(run.text == "Everything is a lie.")
    }

    @Test("repeated edits preserve the first heard text")
    func firstHeardTextIsStable() {
        let run = sampleRun()

        let first = run.correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: CorrectionRuleSuggestion(hear: "a lie", write: "a line"),
            at: Date(timeIntervalSince1970: 100)
        )
        let second = first.correcting(
            intendedText: "Everything is aligned.",
            inputMethod: .voiceAssisted,
            rememberedRule: nil,
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(second.correction?.heardText == "Everything is a lie.")
        #expect(second.correction?.intendedText == "Everything is aligned.")
        #expect(second.text == "Everything is aligned.")
    }

    @Test("correction retains the original audio path")
    func audioPathIsRetained() {
        let corrected = sampleRun().correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: nil,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(corrected.audioFile == "Recordings/original.caf")
    }

    @Test("history stores a hear-write snapshot without a dictionary UUID")
    func rememberedRuleIsASnapshot() throws {
        let corrected = sampleRun().correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: CorrectionRuleSuggestion(hear: "a lie", write: "a line"),
            at: Date(timeIntervalSince1970: 100)
        )
        let encoded = try JSONEncoder().encode(corrected)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let correction = try #require(object["correction"] as? [String: Any])
        let rule = try #require(correction["rememberedRule"] as? [String: Any])

        #expect(rule["hear"] as? String == "a lie")
        #expect(rule["write"] as? String == "a line")
        #expect(rule["id"] == nil)
    }

    private func sampleRun() -> DictationRun {
        DictationRun(
            id: UUID(uuidString: "CB533D44-B408-4B5D-9327-D687D44E7BC2")!,
            date: Date(timeIntervalSince1970: 50),
            engine: "Apple",
            audioSeconds: 1.5,
            processSeconds: 0.25,
            text: "Everything is a lie.",
            audioFile: "Recordings/original.caf"
        )
    }
}
