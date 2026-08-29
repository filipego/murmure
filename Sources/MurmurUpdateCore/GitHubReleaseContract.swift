import Foundation

public struct HostedReleaseCandidate: Equatable, Sendable {
    public let releaseID: Int64
    public let tag: String
    public let version: AppVersion
    public let archiveURL: URL
    public let archiveSize: Int64
    public let archiveSHA256: String
}

public enum GitHubReleaseContractError: Error, Equatable, Sendable {
    case malformedRelease
    case malformedTag
    case draftRelease
    case prerelease
    case archiveMissing
    case archiveAmbiguous
    case archiveNotUploaded
    case invalidArchiveSize
    case archiveDigestMissing
    case archiveDigestMalformed
    case archiveURLMalformed
    case archiveURLNotHTTPS
    case archiveURLHostMismatch
    case archiveURLRepositoryMismatch
    case archiveURLTagMismatch
    case archiveURLFilenameMismatch
}

extension GitHubReleaseContractError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedRelease: "GitHub returned invalid release metadata."
        case .malformedTag: "The release tag is invalid."
        case .draftRelease: "The latest GitHub release is still a draft."
        case .prerelease: "The latest GitHub release is a prerelease."
        case .archiveMissing: "The release archive is missing."
        case .archiveAmbiguous: "The release contains duplicate archives."
        case .archiveNotUploaded: "The release archive is not ready."
        case .invalidArchiveSize: "The release archive size is invalid."
        case .archiveDigestMissing: "The release archive digest is missing."
        case .archiveDigestMalformed: "The release archive digest is invalid."
        case .archiveURLMalformed: "The release archive URL is invalid."
        case .archiveURLNotHTTPS: "The release archive URL is not secure."
        case .archiveURLHostMismatch: "The release archive host is invalid."
        case .archiveURLRepositoryMismatch: "The release archive repository is invalid."
        case .archiveURLTagMismatch: "The release archive tag does not match."
        case .archiveURLFilenameMismatch: "The release archive filename is invalid."
        }
    }
}

public enum GitHubReleaseContract {
    public static func candidate(
        from data: Data,
        newerThan currentVersion: AppVersion
    ) throws -> HostedReleaseCandidate? {
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw GitHubReleaseContractError.malformedRelease
        }

        guard !release.draft else {
            throw GitHubReleaseContractError.draftRelease
        }
        guard !release.prerelease else {
            throw GitHubReleaseContractError.prerelease
        }
        guard let version = version(from: release.tagName) else {
            throw GitHubReleaseContractError.malformedTag
        }

        let matchingAssets = release.assets.filter { $0.name == archiveName }
        guard !matchingAssets.isEmpty else {
            throw GitHubReleaseContractError.archiveMissing
        }
        guard matchingAssets.count == 1, let asset = matchingAssets.first else {
            throw GitHubReleaseContractError.archiveAmbiguous
        }
        guard asset.state == "uploaded" else {
            throw GitHubReleaseContractError.archiveNotUploaded
        }
        guard (1...maximumArchiveSize).contains(asset.size) else {
            throw GitHubReleaseContractError.invalidArchiveSize
        }
        guard let digest = asset.digest else {
            throw GitHubReleaseContractError.archiveDigestMissing
        }
        guard digest.hasPrefix(digestPrefix) else {
            throw GitHubReleaseContractError.archiveDigestMalformed
        }
        let sha256 = String(digest.dropFirst(digestPrefix.count))
        let hexadecimalScalars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard sha256.unicodeScalars.count == 64,
              sha256.unicodeScalars.allSatisfy(hexadecimalScalars.contains) else {
            throw GitHubReleaseContractError.archiveDigestMalformed
        }

        let archiveURL = try validatedArchiveURL(asset.browserDownloadURL, tag: release.tagName)

        guard version > currentVersion else { return nil }
        return HostedReleaseCandidate(
            releaseID: release.id,
            tag: release.tagName,
            version: version,
            archiveURL: archiveURL,
            archiveSize: asset.size,
            archiveSHA256: sha256.lowercased()
        )
    }

    private static func version(from tag: String) -> AppVersion? {
        guard let separator = tag.lastIndex(of: "+") else { return nil }
        var marketing = String(tag[..<separator])
        let buildText = String(tag[tag.index(after: separator)...])
        guard marketing.hasPrefix("v"),
              !marketing.dropFirst().isEmpty,
              !buildText.isEmpty,
              buildText.allSatisfy({ $0.isNumber }),
              let build = Int(buildText),
              build > 0 else { return nil }
        marketing.removeFirst()
        guard isValidMarketingVersion(marketing) else { return nil }
        return AppVersion(marketing: marketing, build: build)
    }

    private static func isValidMarketingVersion(_ marketing: String) -> Bool {
        let versionAndMetadata = marketing.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !versionAndMetadata.isEmpty,
              versionAndMetadata.count <= 2,
              versionAndMetadata.allSatisfy({ !$0.isEmpty }) else { return false }

        let coreAndPrerelease = versionAndMetadata[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let numberParts = coreAndPrerelease[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard !numberParts.isEmpty,
              numberParts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            return false
        }
        if coreAndPrerelease.count == 2 {
            let prereleaseParts = coreAndPrerelease[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard !prereleaseParts.isEmpty,
                  prereleaseParts.allSatisfy({ !$0.isEmpty }) else { return false }
        }
        return true
    }

    private static func validatedArchiveURL(_ rawURL: String, tag: String) throws -> URL {
        guard let components = URLComponents(string: rawURL),
              let url = components.url,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            throw GitHubReleaseContractError.archiveURLMalformed
        }
        guard components.scheme?.lowercased() == "https" else {
            throw GitHubReleaseContractError.archiveURLNotHTTPS
        }
        guard components.host?.lowercased() == "github.com" else {
            throw GitHubReleaseContractError.archiveURLHostMismatch
        }

        let path = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard path.count >= 5,
              Array(path[1...4]) == ["filipego", "murmure", "releases", "download"] else {
            throw GitHubReleaseContractError.archiveURLRepositoryMismatch
        }
        guard path.count >= 6, path[5] == tag else {
            throw GitHubReleaseContractError.archiveURLTagMismatch
        }
        guard path.count == 7, path[6] == archiveName else {
            throw GitHubReleaseContractError.archiveURLFilenameMismatch
        }
        return url
    }

    private static let archiveName = "Murmure.app.zip"
    private static let maximumArchiveSize: Int64 = 536_870_912
    private static let digestPrefix = "sha256:"
}

private struct Release: Decodable {
    let id: Int64
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }
}

private struct ReleaseAsset: Decodable {
    let name: String
    let state: String
    let size: Int64
    let digest: String?
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case state
        case size
        case digest
        case browserDownloadURL = "browser_download_url"
    }
}
