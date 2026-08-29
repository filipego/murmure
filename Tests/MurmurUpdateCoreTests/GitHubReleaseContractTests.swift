import Foundation
import Testing
@testable import MurmurUpdateCore

@Suite("GitHub release contract")
struct GitHubReleaseContractTests {
    @Test("selects the exact signed archive from a newer stable release")
    func selectsNewerRelease() throws {
        let data = Data(Self.releaseJSON(
            tag: "v0.1.12+12",
            assetName: "Murmure.app.zip",
            assetURL: "https://github.com/filipego/murmure/releases/download/v0.1.12+12/Murmure.app.zip",
            size: 12_345,
            digest: "sha256:" + String(repeating: "A", count: 64)
        ).utf8)

        let result = try GitHubReleaseContract.candidate(
            from: data,
            newerThan: AppVersion(marketing: "0.1.11", build: 11)
        )

        #expect(result?.releaseID == 42)
        #expect(result?.tag == "v0.1.12+12")
        #expect(result?.version == AppVersion(marketing: "0.1.12", build: 12))
        #expect(result?.archiveURL == URL(
            string: "https://github.com/filipego/murmure/releases/download/v0.1.12+12/Murmure.app.zip"
        ))
        #expect(result?.archiveSize == 12_345)
        #expect(result?.archiveSHA256 == String(repeating: "a", count: 64))
    }

    @Test("does not download an equal release")
    func ignoresEqualRelease() throws {
        let data = Data(Self.releaseJSON(tag: "v0.1.12+12").utf8)
        #expect(try GitHubReleaseContract.candidate(
            from: data,
            newerThan: AppVersion(marketing: "0.1.12", build: 12)
        ) == nil)
    }

    @Test("rejects a malformed release tag")
    func rejectsMalformedTag() {
        #expect(throws: GitHubReleaseContractError.malformedTag) {
            try Self.candidate(from: Self.releaseJSON(tag: "0.1.12+12"))
        }
    }

    @Test("rejects an overflowing marketing version component")
    func rejectsOverflowingMarketingVersion() {
        #expect(throws: GitHubReleaseContractError.malformedTag) {
            try Self.candidate(from: Self.releaseJSON(
                tag: "v999999999999999999999999+12",
                assetURL: "https://github.com/filipego/murmure/releases/download/v999999999999999999999999+12/Murmure.app.zip"
            ))
        }
    }

    @Test("rejects a draft release")
    func rejectsDraft() {
        #expect(throws: GitHubReleaseContractError.draftRelease) {
            try Self.candidate(from: Self.releaseJSON(draft: true))
        }
    }

    @Test("rejects a prerelease")
    func rejectsPrerelease() {
        #expect(throws: GitHubReleaseContractError.prerelease) {
            try Self.candidate(from: Self.releaseJSON(prerelease: true))
        }
    }

    @Test("rejects a release without the exact archive asset")
    func rejectsMissingAsset() {
        #expect(throws: GitHubReleaseContractError.archiveMissing) {
            try Self.candidate(from: Self.releaseJSON(assetName: "Other.zip"))
        }
    }

    @Test("rejects duplicate exact archive assets")
    func rejectsDuplicateAsset() {
        let asset = Self.assetJSON()
        #expect(throws: GitHubReleaseContractError.archiveAmbiguous) {
            try Self.candidate(from: Self.releaseJSON(assets: [asset, asset]))
        }
    }

    @Test("rejects an archive that is not uploaded")
    func rejectsNonUploadedAsset() {
        #expect(throws: GitHubReleaseContractError.archiveNotUploaded) {
            try Self.candidate(from: Self.releaseJSON(assetState: "open"))
        }
    }

    @Test("rejects a zero-byte archive")
    func rejectsZeroSize() {
        #expect(throws: GitHubReleaseContractError.invalidArchiveSize) {
            try Self.candidate(from: Self.releaseJSON(size: 0))
        }
    }

    @Test("rejects an oversized archive")
    func rejectsOversizedAsset() {
        #expect(throws: GitHubReleaseContractError.invalidArchiveSize) {
            try Self.candidate(from: Self.releaseJSON(size: 536_870_913))
        }
    }

    @Test("rejects an archive without a digest")
    func rejectsMissingDigest() {
        #expect(throws: GitHubReleaseContractError.archiveDigestMissing) {
            try Self.candidate(from: Self.releaseJSON(digest: nil))
        }
    }

    @Test("rejects a malformed archive digest")
    func rejectsMalformedDigest() {
        #expect(throws: GitHubReleaseContractError.archiveDigestMalformed) {
            try Self.candidate(from: Self.releaseJSON(digest: "sha256:not-a-digest"))
        }
    }

    @Test("rejects an HTTP archive URL")
    func rejectsHTTPURL() {
        #expect(throws: GitHubReleaseContractError.archiveURLNotHTTPS) {
            try Self.candidate(from: Self.releaseJSON(
                assetURL: "http://github.com/filipego/murmure/releases/download/v0.1.12+12/Murmure.app.zip"
            ))
        }
    }

    @Test("rejects an archive URL on another host")
    func rejectsWrongHost() {
        #expect(throws: GitHubReleaseContractError.archiveURLHostMismatch) {
            try Self.candidate(from: Self.releaseJSON(
                assetURL: "https://example.com/filipego/murmure/releases/download/v0.1.12+12/Murmure.app.zip"
            ))
        }
    }

    @Test("rejects an archive URL for another repository")
    func rejectsWrongRepositoryPath() {
        #expect(throws: GitHubReleaseContractError.archiveURLRepositoryMismatch) {
            try Self.candidate(from: Self.releaseJSON(
                assetURL: "https://github.com/other/murmure/releases/download/v0.1.12+12/Murmure.app.zip"
            ))
        }
    }

    @Test("rejects a non-exact repository path")
    func rejectsNonExactRepositoryPath() {
        #expect(throws: GitHubReleaseContractError.archiveURLRepositoryMismatch) {
            try Self.candidate(from: Self.releaseJSON(
                assetURL: "https://github.com/filipego//murmure/releases/download/v0.1.12+12/Murmure.app.zip"
            ))
        }
    }

    @Test("rejects an archive URL for another release tag")
    func rejectsWrongTagInPath() {
        #expect(throws: GitHubReleaseContractError.archiveURLTagMismatch) {
            try Self.candidate(from: Self.releaseJSON(
                assetURL: "https://github.com/filipego/murmure/releases/download/v9.9.9+999/Murmure.app.zip"
            ))
        }
    }

    @Test("accepts GitHub percent encoding in the release tag path")
    func acceptsPercentEncodedTagInPath() throws {
        let result = try Self.candidate(from: Self.releaseJSON(
            assetURL: "https://github.com/filipego/murmure/releases/download/v0.1.12%2B12/Murmure.app.zip"
        ))
        #expect(result?.tag == "v0.1.12+12")
    }

    @Test("rejects an archive URL with the wrong filename")
    func rejectsWrongFilename() {
        #expect(throws: GitHubReleaseContractError.archiveURLFilenameMismatch) {
            try Self.candidate(from: Self.releaseJSON(
                assetURL: "https://github.com/filipego/murmure/releases/download/v0.1.12+12/Other.zip"
            ))
        }
    }

    private static func candidate(from json: String) throws -> HostedReleaseCandidate? {
        try GitHubReleaseContract.candidate(
            from: Data(json.utf8),
            newerThan: AppVersion(marketing: "0.1.11", build: 11)
        )
    }

    private static func releaseJSON(
        id: Int64 = 42,
        tag: String = "v0.1.12+12",
        draft: Bool = false,
        prerelease: Bool = false,
        assetName: String = "Murmure.app.zip",
        assetState: String = "uploaded",
        assetURL: String = "https://github.com/filipego/murmure/releases/download/v0.1.12+12/Murmure.app.zip",
        size: Int64 = 12_345,
        digest: String? = "sha256:" + String(repeating: "a", count: 64),
        assets: [String]? = nil
    ) -> String {
        let assetsJSON = assets ?? [assetJSON(
            name: assetName,
            state: assetState,
            url: assetURL,
            size: size,
            digest: digest
        )]
        return """
        {
          "id": \(id),
          "tag_name": "\(tag)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "assets": [\(assetsJSON.joined(separator: ","))]
        }
        """
    }

    private static func assetJSON(
        name: String = "Murmure.app.zip",
        state: String = "uploaded",
        url: String = "https://github.com/filipego/murmure/releases/download/v0.1.12+12/Murmure.app.zip",
        size: Int64 = 12_345,
        digest: String? = "sha256:" + String(repeating: "a", count: 64)
    ) -> String {
        let digestJSON = digest.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "name": "\(name)",
          "state": "\(state)",
          "size": \(size),
          "digest": \(digestJSON),
          "browser_download_url": "\(url)"
        }
        """
    }
}
