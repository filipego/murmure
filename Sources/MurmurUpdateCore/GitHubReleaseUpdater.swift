import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

package struct UpdateHTTPData: Sendable {
    package let data: Data
    package let statusCode: Int
    package let finalURL: URL
}

package struct UpdateHTTPDownload: Sendable {
    package let fileURL: URL
    package let statusCode: Int
    package let finalURL: URL
}

package protocol UpdateTransport: Sendable {
    func data(for request: URLRequest) async throws -> UpdateHTTPData
    func download(for request: URLRequest) async throws -> UpdateHTTPDownload
}

package enum UpdateArchiveEntryKind: Sendable {
    case file
    case directory
    case symlink
}

package struct UpdateArchiveEntry: Sendable {
    package let path: String
    package let kind: UpdateArchiveEntryKind
    package let uncompressedSize: UInt64
}

public enum GitHubReleaseUpdaterError: Error, Equatable, Sendable {
    case invalidHTTPResponse
    case metadataResponseRejected
    case metadataRedirectRejected
    case archiveResponseRejected
    case archiveRedirectRejected
    case downloadedFileInvalid
    case archiveSizeMismatch
    case archiveDigestMismatch
    case archiveInvalid
    case archiveEmpty
    case archiveEntryInvalid
    case archiveEntryLimitExceeded
    case archiveExpandedSizeLimitExceeded
    case stagedBundleInvalid
    case stagedVersionMismatch
    case installedVersionInvalid
}

extension GitHubReleaseUpdaterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse: "The update server returned an invalid response."
        case .metadataResponseRejected: "GitHub release metadata is unavailable."
        case .metadataRedirectRejected: "GitHub release metadata redirected unexpectedly."
        case .archiveResponseRejected: "The release archive could not be downloaded."
        case .archiveRedirectRejected: "The release archive redirected to an untrusted host."
        case .downloadedFileInvalid: "The downloaded release is not a regular file."
        case .archiveSizeMismatch: "The release archive size does not match GitHub metadata."
        case .archiveDigestMismatch: "The release archive checksum does not match GitHub metadata."
        case .archiveInvalid: "The release archive is invalid."
        case .archiveEmpty: "The release archive is empty."
        case .archiveEntryInvalid: "The release archive contains an unsafe entry."
        case .archiveEntryLimitExceeded: "The release archive contains too many entries."
        case .archiveExpandedSizeLimitExceeded: "The expanded release archive is too large."
        case .stagedBundleInvalid: "The release archive does not contain exactly one Murmure app."
        case .stagedVersionMismatch: "The staged app version does not match the GitHub release."
        case .installedVersionInvalid: "The installed Murmure version could not be validated."
        }
    }
}

public struct GitHubReleaseUpdater: Sendable {
    package typealias SignatureValidator = @Sendable (URL, URL) async throws -> Void

    private let transport: any UpdateTransport
    private let signatureValidator: SignatureValidator

    public init() {
        transport = URLSessionUpdateTransport()
        signatureValidator = { stagedBundleURL, installedBundleURL in
            try ReleaseCodeSignatureValidator.validateReplacement(
                stagedBundleURL: stagedBundleURL,
                installedBundleURL: installedBundleURL
            )
        }
    }

    package init(
        transport: any UpdateTransport,
        signatureValidator: @escaping SignatureValidator
    ) {
        self.transport = transport
        self.signatureValidator = signatureValidator
    }

    public func stageLatestUpdate(
        newerThan currentVersion: AppVersion,
        installedBundleURL: URL,
        inboxURL: URL
    ) async throws -> UpdateManifest? {
        let metadataRequest = Self.metadataRequest()
        let response = try await transport.data(for: metadataRequest)
        guard response.finalURL == Self.metadataURL else {
            throw GitHubReleaseUpdaterError.metadataRedirectRejected
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else {
            throw GitHubReleaseUpdaterError.metadataResponseRejected
        }
        guard let candidate = try GitHubReleaseContract.candidate(
            from: response.data,
            newerThan: currentVersion
        ) else { return nil }

        let fileManager = FileManager.default
        try Self.prepareInbox(inboxURL, fileManager: fileManager)
        let transactionURL = inboxURL.standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: transactionURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let manifest = try await stage(
                candidate: candidate,
                currentVersion: currentVersion,
                installedBundleURL: installedBundleURL,
                inboxURL: inboxURL.standardizedFileURL,
                transactionURL: transactionURL,
                fileManager: fileManager
            )
            return manifest
        } catch {
            try? fileManager.removeItem(at: transactionURL)
            throw error
        }
    }

    private func stage(
        candidate: HostedReleaseCandidate,
        currentVersion: AppVersion,
        installedBundleURL: URL,
        inboxURL: URL,
        transactionURL: URL,
        fileManager: FileManager
    ) async throws -> UpdateManifest {
        var request = URLRequest(url: candidate.archiveURL)
        request.httpMethod = "GET"
        let response = try await transport.download(for: request)
        guard response.statusCode == 200 else {
            throw GitHubReleaseUpdaterError.archiveResponseRejected
        }
        guard Self.isAllowedArchiveResponseURL(response.finalURL) else {
            throw GitHubReleaseUpdaterError.archiveRedirectRejected
        }

        let archiveURL = transactionURL.appendingPathComponent("Murmure.app.zip")
        try fileManager.moveItem(at: response.fileURL, to: archiveURL)
        guard try Self.regularFileSize(at: archiveURL) == candidate.archiveSize else {
            throw GitHubReleaseUpdaterError.archiveSizeMismatch
        }
        guard try Self.sha256(of: archiveURL) == candidate.archiveSHA256 else {
            throw GitHubReleaseUpdaterError.archiveDigestMismatch
        }

        let extractionURL = transactionURL.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: false)
        let stagedBundleURL = try Self.extractArchive(
            archiveURL,
            to: extractionURL,
            fileManager: fileManager
        )

        let installedVersion: AppVersion
        do {
            installedVersion = try BundleValidator.validate(bundleURL: installedBundleURL)
        } catch {
            throw GitHubReleaseUpdaterError.installedVersionInvalid
        }
        let stagedVersion: AppVersion
        do {
            stagedVersion = try BundleValidator.validate(bundleURL: stagedBundleURL)
        } catch {
            throw GitHubReleaseUpdaterError.stagedBundleInvalid
        }
        guard stagedVersion == candidate.version,
              stagedVersion > currentVersion,
              stagedVersion > installedVersion else {
            throw GitHubReleaseUpdaterError.stagedVersionMismatch
        }

        try await signatureValidator(stagedBundleURL, installedBundleURL)

        let manifest = UpdateManifest(
            bundleIdentifier: murmurBundleIdentifier,
            version: stagedVersion,
            stagedBundleURL: stagedBundleURL,
            createdAt: Date(
                timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: inboxURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        return manifest
    }

    private static func metadataRequest() -> URLRequest {
        var request = URLRequest(url: metadataURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Murmure-Updater/1", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private static func prepareInbox(_ inboxURL: URL, fileManager: FileManager) throws {
        let url = inboxURL.standardizedFileURL
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var statBuffer = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return lstat(path, &statBuffer) == 0 && (statBuffer.st_mode & S_IFMT) == S_IFDIR
        }) else {
            throw GitHubReleaseUpdaterError.downloadedFileInvalid
        }
    }

    private static func regularFileSize(at url: URL) throws -> Int64 {
        var statBuffer = stat()
        let isRegular = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &statBuffer) == 0 && (statBuffer.st_mode & S_IFMT) == S_IFREG
        }
        guard isRegular, statBuffer.st_size >= 0 else {
            throw GitHubReleaseUpdaterError.downloadedFileInvalid
        }
        return statBuffer.st_size
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extractArchive(
        _ archiveURL: URL,
        to extractionURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw GitHubReleaseUpdaterError.archiveInvalid
        }
        let entries = Array(archive)
        try validateArchiveEntries(entries.map { entry in
            let kind: UpdateArchiveEntryKind = switch entry.type {
            case .file: .file
            case .directory: .directory
            case .symlink: .symlink
            }
            return UpdateArchiveEntry(
                path: entry.path,
                kind: kind,
                uncompressedSize: entry.uncompressedSize
            )
        })

        for entry in entries {
            let destination = extractionURL.appendingPathComponent(entry.path)
            do {
                let checksum = try archive.extract(entry, to: destination)
                guard checksum == entry.checksum else {
                    throw GitHubReleaseUpdaterError.archiveInvalid
                }
            } catch {
                if let updaterError = error as? GitHubReleaseUpdaterError {
                    throw updaterError
                }
                throw GitHubReleaseUpdaterError.archiveInvalid
            }
        }

        let stagedBundleURL = extractionURL.appendingPathComponent("Murmure.app", isDirectory: true)
        var isDirectory: ObjCBool = false
        let topLevelItems = try fileManager.contentsOfDirectory(
            at: extractionURL,
            includingPropertiesForKeys: nil
        )
        guard topLevelItems.count == 1,
              topLevelItems[0].lastPathComponent == "Murmure.app",
              fileManager.fileExists(atPath: stagedBundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitHubReleaseUpdaterError.stagedBundleInvalid
        }
        return stagedBundleURL
    }

    package static func validateArchiveEntries(_ entries: [UpdateArchiveEntry]) throws {
        guard !entries.isEmpty else { throw GitHubReleaseUpdaterError.archiveEmpty }
        guard entries.count <= maximumArchiveEntryCount else {
            throw GitHubReleaseUpdaterError.archiveEntryLimitExceeded
        }

        var expandedSize: UInt64 = 0
        for entry in entries {
            guard entry.kind != .symlink,
                  !entry.path.isEmpty,
                  !entry.path.hasPrefix("/"),
                  !entry.path.contains("\0"),
                  !entry.path.contains("\\") else {
                throw GitHubReleaseUpdaterError.archiveEntryInvalid
            }

            var components = entry.path.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            if entry.kind == .directory {
                guard components.last == "" else {
                    throw GitHubReleaseUpdaterError.archiveEntryInvalid
                }
                components.removeLast()
            } else if components.last == "" {
                throw GitHubReleaseUpdaterError.archiveEntryInvalid
            }
            guard !components.isEmpty,
                  components[0] == "Murmure.app",
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw GitHubReleaseUpdaterError.archiveEntryInvalid
            }

            let (newSize, overflow) = expandedSize.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, newSize <= maximumExpandedArchiveSize else {
                throw GitHubReleaseUpdaterError.archiveExpandedSizeLimitExceeded
            }
            expandedSize = newSize
        }
    }

    private static func isAllowedArchiveResponseURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    private static let metadataURL = URL(
        string: "https://api.github.com/repos/filipego/murmure/releases/latest"
    )!
    private static let maximumArchiveEntryCount = 10_000
    private static let maximumExpandedArchiveSize: UInt64 = 1_073_741_824
}

private struct URLSessionUpdateTransport: UpdateTransport {
    func data(for request: URLRequest) async throws -> UpdateHTTPData {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url else {
            throw GitHubReleaseUpdaterError.invalidHTTPResponse
        }
        return UpdateHTTPData(
            data: data,
            statusCode: response.statusCode,
            finalURL: finalURL
        )
    }

    func download(for request: URLRequest) async throws -> UpdateHTTPDownload {
        let (fileURL, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url else {
            throw GitHubReleaseUpdaterError.invalidHTTPResponse
        }
        return UpdateHTTPDownload(
            fileURL: fileURL,
            statusCode: response.statusCode,
            finalURL: finalURL
        )
    }
}
