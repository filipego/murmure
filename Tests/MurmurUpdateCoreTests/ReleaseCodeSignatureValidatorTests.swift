import Foundation
import Security
import Testing
@testable import MurmurUpdateCore

@Suite("Release code-signature validator")
struct ReleaseCodeSignatureValidatorTests {
    @Test("accepts a successful validation after pinned comparisons")
    func acceptsSuccess() {
        #expect(ReleaseCodeSignatureValidator.acceptsValidationStatus(
            errSecSuccess,
            pinnedRequirementMatches: true,
            certificatePinsMatch: true
        ))
    }

    @Test("accepts certificate-not-trusted after pinned comparisons")
    func acceptsCertificateNotTrusted() {
        #expect(ReleaseCodeSignatureValidator.acceptsValidationStatus(
            errSecNotTrusted,
            pinnedRequirementMatches: true,
            certificatePinsMatch: true
        ))
    }

    @Test("rejects success when either pinned comparison failed", arguments: [
        (false, true),
        (true, false),
        (false, false)
    ])
    func rejectsSuccessWithPinMismatch(
        pinnedRequirementMatches: Bool,
        certificatePinsMatch: Bool
    ) {
        #expect(!ReleaseCodeSignatureValidator.acceptsValidationStatus(
            errSecSuccess,
            pinnedRequirementMatches: pinnedRequirementMatches,
            certificatePinsMatch: certificatePinsMatch
        ))
    }

    @Test("rejects certificate-not-trusted when either pinned comparison failed", arguments: [
        (false, true),
        (true, false),
        (false, false)
    ])
    func rejectsCertificateNotTrustedWithPinMismatch(
        pinnedRequirementMatches: Bool,
        certificatePinsMatch: Bool
    ) {
        #expect(!ReleaseCodeSignatureValidator.acceptsValidationStatus(
            errSecNotTrusted,
            pinnedRequirementMatches: pinnedRequirementMatches,
            certificatePinsMatch: certificatePinsMatch
        ))
    }

    @Test("rejects every other validation status")
    func rejectsOtherStatus() {
        #expect(!ReleaseCodeSignatureValidator.acceptsValidationStatus(
            errSecCSSignatureFailed,
            pinnedRequirementMatches: true,
            certificatePinsMatch: true
        ))
    }

    @Test(
        "validates a stable installed app against a freshly built signed bundle",
        .disabled(if: stableSignedFixtureUnavailable(), "A stable signed fixture is unavailable")
    )
    func validatesStableSignedFixture() throws {
        let stagedPath = try #require(
            ProcessInfo.processInfo.environment["MURMURE_SIGNED_UPDATE_FIXTURE"]
        )
        try ReleaseCodeSignatureValidator.validateReplacement(
            stagedBundleURL: URL(fileURLWithPath: stagedPath, isDirectory: true),
            installedBundleURL: URL(fileURLWithPath: "/Applications/Murmure.app", isDirectory: true)
        )
    }
}

private func stableSignedFixtureUnavailable() -> Bool {
    guard let stagedPath = ProcessInfo.processInfo.environment["MURMURE_SIGNED_UPDATE_FIXTURE"] else {
        return true
    }
    return !FileManager.default.fileExists(atPath: stagedPath)
        || !FileManager.default.fileExists(atPath: "/Applications/Murmure.app")
}
