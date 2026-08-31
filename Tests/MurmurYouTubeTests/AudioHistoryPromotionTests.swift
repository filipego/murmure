import Foundation
import Testing
@testable import MurmurYouTube

@Suite("Audio history promotion")
struct AudioHistoryPromotionTests {
    @Test("a staged CAF is promoted with matching bytes")
    func promotesMatchingBytes() async throws {
        try await withPromotionFixture { root, staged, id in
            let expected = Data("durable caf bytes".utf8)
            try expected.write(to: staged)

            let result = await AudioHistoryStore.promoteStagedAudio(
                from: staged,
                id: id,
                destinationRoot: root
            )

            let relativePath = "Recordings/\(id.uuidString.lowercased()).caf"
            #expect(result == .promoted(relativePath: relativePath))
            #expect(try Data(contentsOf: root.appendingPathComponent(relativePath)) == expected)
            #expect(FileManager.default.fileExists(atPath: staged.path))
        }
    }

    @Test("repeating promotion with matching bytes is idempotent")
    func repeatedPromotionIsIdempotent() async throws {
        try await withPromotionFixture { root, staged, id in
            try Data("same bytes".utf8).write(to: staged)
            _ = await AudioHistoryStore.promoteStagedAudio(
                from: staged,
                id: id,
                destinationRoot: root
            )

            let result = await AudioHistoryStore.promoteStagedAudio(
                from: staged,
                id: id,
                destinationRoot: root
            )

            #expect(
                result == .alreadyPromoted(
                    relativePath: "Recordings/\(id.uuidString.lowercased()).caf"
                )
            )
        }
    }

    @Test("an existing conflicting destination is never overwritten")
    func conflictIsPreserved() async throws {
        try await withPromotionFixture { root, staged, id in
            let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
            let destination = recordings.appendingPathComponent("\(id.uuidString.lowercased()).caf")
            let existing = Data("existing".utf8)
            try existing.write(to: destination)
            try Data("different".utf8).write(to: staged)

            let result = await AudioHistoryStore.promoteStagedAudio(
                from: staged,
                id: id,
                destinationRoot: root
            )

            guard case .failed = result else {
                Issue.record("Expected a conflict failure, received \(result)")
                return
            }
            #expect(try Data(contentsOf: destination) == existing)
            #expect(FileManager.default.fileExists(atPath: staged.path))
        }
    }

    @Test("a missing staged file reports failure")
    func missingSourceFails() async throws {
        try await withPromotionFixture { root, staged, id in
            let result = await AudioHistoryStore.promoteStagedAudio(
                from: staged,
                id: id,
                destinationRoot: root
            )

            guard case .failed = result else {
                Issue.record("Expected a missing-file failure, received \(result)")
                return
            }
        }
    }
}

private func withPromotionFixture(
    _ body: (URL, URL, UUID) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("murmure-promotion-tests-\(UUID().uuidString)", isDirectory: true)
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root, staging.appendingPathComponent("audio.caf"), UUID())
}
