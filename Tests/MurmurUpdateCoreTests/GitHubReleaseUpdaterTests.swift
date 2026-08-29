import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import MurmurUpdateCore

@Suite("GitHub release updater")
struct GitHubReleaseUpdaterTests {
    @Test("downloads, verifies, extracts, validates, and publishes a newer release")
    func stagesVerifiedRelease() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }

        let installed = try fixture.makeApp(
            named: "Installed.app",
            marketing: "0.1.11",
            build: 11
        )
        let releaseBundle = try fixture.makeApp(
            named: "Murmure.app",
            marketing: "0.1.12",
            build: 12
        )
        let archive = fixture.root.appendingPathComponent("Murmure.app.zip")
        try FileManager.default.zipItem(
            at: releaseBundle,
            to: archive,
            shouldKeepParent: true,
            compressionMethod: .none
        )
        let archiveData = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        let metadata = Data(Self.releaseJSON(size: archiveData.count, digest: digest).utf8)

        let transport = ScriptedUpdateTransport(
            metadata: UpdateHTTPData(
                data: metadata,
                statusCode: 200,
                finalURL: Self.metadataURL
            ),
            download: UpdateHTTPDownload(
                fileURL: archive,
                statusCode: 200,
                finalURL: Self.archiveURL
            )
        )
        let signatureRecorder = SignatureRecorder()
        let updater = GitHubReleaseUpdater(
            transport: transport,
            signatureValidator: { staged, installed in
                try await signatureRecorder.validate(staged: staged, installed: installed)
            }
        )

        let manifest = try await updater.stageLatestUpdate(
            newerThan: AppVersion(marketing: "0.1.11", build: 11),
            installedBundleURL: installed,
            inboxURL: fixture.inbox
        )

        #expect(manifest?.version == AppVersion(marketing: "0.1.12", build: 12))
        #expect(manifest?.bundleIdentifier == murmurBundleIdentifier)
        #expect(manifest.map { $0.stagedBundleURL.path.hasPrefix(fixture.inbox.path + "/") } == true)
        #expect(await signatureRecorder.calls == 1)
        let metadataRequest = try #require(await transport.dataRequests.first)
        #expect(metadataRequest.url == Self.metadataURL)
        #expect(metadataRequest.httpMethod == "GET")
        #expect(metadataRequest.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(metadataRequest.value(forHTTPHeaderField: "User-Agent") == "Murmure-Updater/1")
        #expect(metadataRequest.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        let publishedData = try Data(contentsOf: fixture.manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(UpdateManifest.self, from: publishedData) == manifest)
    }

    @Test("treats metadata 404 as no release without downloading")
    func metadata404ReturnsNilWithoutDownload() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let scenario = try Self.scenario(
            fixture: fixture,
            installed: installed,
            archive: nil,
            metadataStatus: 404
        )

        let manifest = try await scenario.updater.stageLatestUpdate(
            newerThan: AppVersion(marketing: "0.1.11", build: 11),
            installedBundleURL: installed,
            inboxURL: fixture.inbox
        )

        #expect(manifest == nil)
        #expect(await scenario.transport.downloadCalls == 0)
    }

    @Test("rejects metadata redirected away from the exact API endpoint")
    func rejectsMetadataRedirect() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.12", build: 12)
        let scenario = try Self.scenario(
            fixture: fixture,
            installed: installed,
            archive: archive,
            metadataFinalURL: URL(string: "https://example.com/releases/latest")!
        )

        await #expect(throws: GitHubReleaseUpdaterError.metadataRedirectRejected) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
        #expect(await scenario.transport.downloadCalls == 0)
    }

    @Test("allows an HTTPS GitHub asset redirect")
    func allowsGitHubAssetRedirect() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.12", build: 12)
        let scenario = try Self.scenario(
            fixture: fixture,
            installed: installed,
            archive: archive,
            downloadFinalURL: URL(string: "https://release-assets.githubusercontent.com/signed-object")!
        )

        #expect(try await scenario.stage(installed: installed, inbox: fixture.inbox) != nil)
    }

    @Test("rejects an asset redirect to an unrelated host")
    func rejectsUnrelatedAssetRedirect() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.12", build: 12)
        let scenario = try Self.scenario(
            fixture: fixture,
            installed: installed,
            archive: archive,
            downloadFinalURL: URL(string: "https://example.com/Murmure.app.zip")!
        )

        await #expect(throws: GitHubReleaseUpdaterError.archiveRedirectRejected) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
    }

    @Test("rejects a downloaded symbolic link")
    func rejectsDownloadedSymlink() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.12", build: 12)
        let symlink = fixture.root.appendingPathComponent("download-link.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: archive)
        let scenario = try Self.scenario(fixture: fixture, installed: installed, archive: symlink)

        await #expect(throws: GitHubReleaseUpdaterError.downloadedFileInvalid) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
    }

    @Test("rejects a downloaded directory without moving or removing it")
    func rejectsDownloadedDirectoryWithoutMovingIt() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let sourceDirectory = fixture.root.appendingPathComponent(
            "hostile-download",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let sentinel = sourceDirectory.appendingPathComponent("sentinel.txt")
        try Data("preserve me".utf8).write(to: sentinel)
        let metadata = Data(Self.releaseJSON(
            size: 1,
            digest: String(repeating: "0", count: 64)
        ).utf8)
        let transport = ScriptedUpdateTransport(
            metadata: UpdateHTTPData(
                data: metadata,
                statusCode: 200,
                finalURL: Self.metadataURL
            ),
            download: UpdateHTTPDownload(
                fileURL: sourceDirectory,
                statusCode: 200,
                finalURL: Self.archiveURL
            )
        )
        let updater = GitHubReleaseUpdater(
            transport: transport,
            signatureValidator: { _, _ in }
        )

        await #expect(throws: GitHubReleaseUpdaterError.downloadedFileInvalid) {
            try await updater.stageLatestUpdate(
                newerThan: AppVersion(marketing: "0.1.11", build: 11),
                installedBundleURL: installed,
                inboxURL: fixture.inbox
            )
        }
        #expect(FileManager.default.fileExists(atPath: sourceDirectory.path))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve me")
        #expect(try fixture.transactionDirectories().isEmpty)
    }

    @Test("digest mismatch preserves the existing manifest")
    func digestMismatchPreservesManifest() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let oldManifest = Data("old manifest".utf8)
        try oldManifest.write(to: fixture.manifestURL)
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.12", build: 12)
        let scenario = try Self.scenario(
            fixture: fixture,
            installed: installed,
            archive: archive,
            digest: String(repeating: "0", count: 64)
        )

        await #expect(throws: GitHubReleaseUpdaterError.archiveDigestMismatch) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
        #expect(try Data(contentsOf: fixture.manifestURL) == oldManifest)
        #expect(await scenario.signatureRecorder.calls == 0)
    }

    @Test("size mismatch fails before extraction")
    func sizeMismatchFailsBeforeExtraction() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.12", build: 12)
        let actualSize = try Data(contentsOf: archive).count
        let scenario = try Self.scenario(
            fixture: fixture,
            installed: installed,
            archive: archive,
            advertisedSize: actualSize + 1
        )

        await #expect(throws: GitHubReleaseUpdaterError.archiveSizeMismatch) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
        #expect(await scenario.signatureRecorder.calls == 0)
        #expect(try fixture.transactionDirectories().isEmpty)
    }

    @Test("wrong bundle version fails before signature validation")
    func wrongBundleVersionFailsBeforeSignature() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.13", build: 13)
        let scenario = try Self.scenario(fixture: fixture, installed: installed, archive: archive)

        await #expect(throws: GitHubReleaseUpdaterError.stagedVersionMismatch) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
        #expect(await scenario.signatureRecorder.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.manifestURL.path))
    }

    @Test("signature failure preserves the existing manifest")
    func signatureFailurePreservesManifest() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let oldManifest = Data("old manifest".utf8)
        try oldManifest.write(to: fixture.manifestURL)
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.12", build: 12)
        let scenario = try Self.scenario(
            fixture: fixture,
            installed: installed,
            archive: archive,
            signatureFailure: true
        )

        await #expect(throws: TestSignatureError.rejected) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
        #expect(try Data(contentsOf: fixture.manifestURL) == oldManifest)
    }

    @Test("rejects an empty archive")
    func rejectsEmptyArchive() async throws {
        try await Self.assertArchiveRejected(entries: [], as: .archiveEmpty)
    }

    @Test("rejects an absolute archive path")
    func rejectsAbsolutePath() async throws {
        try await Self.assertArchiveRejected(
            entries: [.file("/Murmure.app/Contents/Info.plist")],
            as: .archiveEntryInvalid
        )
    }

    @Test("rejects parent traversal in an archive path")
    func rejectsParentTraversal() async throws {
        try await Self.assertArchiveRejected(
            entries: [.file("Murmure.app/../escape")],
            as: .archiveEntryInvalid
        )
    }

    @Test("rejects a NUL in an archive path")
    func rejectsNULPath() async throws {
        try await Self.assertArchiveRejected(
            entries: [.file("Murmure.app/Contents/evil\0name")],
            as: .archiveEntryInvalid
        )
    }

    @Test("rejects a symbolic link archive entry")
    func rejectsArchiveSymlink() async throws {
        try await Self.assertArchiveRejected(
            entries: [.symlink("Murmure.app/Contents/link")],
            as: .archiveEntryInvalid
        )
    }

    @Test("rejects an extra top-level archive root")
    func rejectsExtraTopLevelRoot() async throws {
        try await Self.assertArchiveRejected(
            entries: [.file("Other.txt")],
            as: .archiveEntryInvalid
        )
    }

    @Test("rejects more than ten thousand archive entries")
    func rejectsExcessiveEntryCount() throws {
        let entries = (0...10_000).map { index in
            UpdateArchiveEntry(
                path: "Murmure.app/Contents/Resources/\(index)",
                kind: .file,
                uncompressedSize: 0
            )
        }

        #expect(throws: GitHubReleaseUpdaterError.archiveEntryLimitExceeded) {
            try GitHubReleaseUpdater.validateArchiveEntries(entries)
        }
    }

    @Test("rejects an archive whose expanded size exceeds one gibibyte")
    func rejectsExcessiveExpandedSize() throws {
        let entries = [
            UpdateArchiveEntry(
                path: "Murmure.app/Contents/large-a",
                kind: .file,
                uncompressedSize: 1_073_741_824
            ),
            UpdateArchiveEntry(
                path: "Murmure.app/Contents/large-b",
                kind: .file,
                uncompressedSize: 1
            )
        ]

        #expect(throws: GitHubReleaseUpdaterError.archiveExpandedSizeLimitExceeded) {
            try GitHubReleaseUpdater.validateArchiveEntries(entries)
        }
    }

    @Test("failed transaction removes only its UUID directory")
    func failedTransactionCleanupIsScoped() async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let sentinel = fixture.inbox.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeReleaseArchive(marketing: "0.1.12", build: 12)
        let scenario = try Self.scenario(
            fixture: fixture,
            installed: installed,
            archive: archive,
            digest: String(repeating: "0", count: 64)
        )

        await #expect(throws: GitHubReleaseUpdaterError.archiveDigestMismatch) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(try fixture.transactionDirectories().isEmpty)
    }

    private static func assertArchiveRejected(
        entries: [TestArchiveEntry],
        as expectedError: GitHubReleaseUpdaterError
    ) async throws {
        let fixture = try UpdateFixture()
        defer { fixture.remove() }
        let installed = try fixture.makeApp(named: "Installed.app", marketing: "0.1.11", build: 11)
        let archive = try fixture.makeArchive(entries: entries)
        let scenario = try scenario(fixture: fixture, installed: installed, archive: archive)

        await #expect(throws: expectedError) {
            try await scenario.stage(installed: installed, inbox: fixture.inbox)
        }
        #expect(await scenario.signatureRecorder.calls == 0)
    }

    private static func scenario(
        fixture: UpdateFixture,
        installed: URL,
        archive: URL?,
        metadataStatus: Int = 200,
        metadataFinalURL: URL = metadataURL,
        downloadFinalURL: URL = archiveURL,
        advertisedSize: Int? = nil,
        digest: String? = nil,
        signatureFailure: Bool = false
    ) throws -> UpdateScenario {
        let archiveData = try archive.map { try Data(contentsOf: $0) }
        let actualDigest = archiveData.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        let metadata = metadataStatus == 404
            ? Data()
            : Data(releaseJSON(
                size: advertisedSize ?? archiveData?.count ?? 1,
                digest: digest ?? actualDigest ?? String(repeating: "a", count: 64)
            ).utf8)
        let transport = ScriptedUpdateTransport(
            metadata: UpdateHTTPData(
                data: metadata,
                statusCode: metadataStatus,
                finalURL: metadataFinalURL
            ),
            download: archive.map {
                UpdateHTTPDownload(fileURL: $0, statusCode: 200, finalURL: downloadFinalURL)
            }
        )
        let signatureRecorder = SignatureRecorder(shouldFail: signatureFailure)
        let updater = GitHubReleaseUpdater(
            transport: transport,
            signatureValidator: { staged, installed in
                try await signatureRecorder.validate(staged: staged, installed: installed)
            }
        )
        return UpdateScenario(
            updater: updater,
            transport: transport,
            signatureRecorder: signatureRecorder
        )
    }

    private static let metadataURL = URL(
        string: "https://api.github.com/repos/filipego/murmure/releases/latest"
    )!
    private static let archiveURL = URL(
        string: "https://github.com/filipego/murmure/releases/download/v0.1.12+12/Murmure.app.zip"
    )!

    private static func releaseJSON(size: Int, digest: String) -> String {
        """
        {
          "id": 42,
          "tag_name": "v0.1.12+12",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "Murmure.app.zip",
            "state": "uploaded",
            "size": \(size),
            "digest": "sha256:\(digest)",
            "browser_download_url": "\(archiveURL.absoluteString)"
          }]
        }
        """
    }
}

private actor ScriptedUpdateTransport: UpdateTransport {
    let metadata: UpdateHTTPData
    let download: UpdateHTTPDownload?
    private(set) var dataRequests: [URLRequest] = []
    private(set) var downloadCalls = 0

    init(metadata: UpdateHTTPData, download: UpdateHTTPDownload?) {
        self.metadata = metadata
        self.download = download
    }

    func data(for request: URLRequest) async throws -> UpdateHTTPData {
        dataRequests.append(request)
        return metadata
    }

    func download(for request: URLRequest) async throws -> UpdateHTTPDownload {
        downloadCalls += 1
        guard let download else { throw ScriptedTransportError.unexpectedDownload }
        return download
    }
}

private actor SignatureRecorder {
    private(set) var calls = 0
    let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func validate(staged: URL, installed: URL) throws {
        calls += 1
        if shouldFail { throw TestSignatureError.rejected }
    }
}

private enum ScriptedTransportError: Error {
    case unexpectedDownload
}

private enum TestSignatureError: Error {
    case rejected
}

private struct UpdateScenario {
    let updater: GitHubReleaseUpdater
    let transport: ScriptedUpdateTransport
    let signatureRecorder: SignatureRecorder

    func stage(installed: URL, inbox: URL) async throws -> UpdateManifest? {
        try await updater.stageLatestUpdate(
            newerThan: AppVersion(marketing: "0.1.11", build: 11),
            installedBundleURL: installed,
            inboxURL: inbox
        )
    }
}

private enum TestArchiveEntry {
    case file(String)
    case directory(String)
    case symlink(String)

    var path: String {
        switch self {
        case let .file(path), let .directory(path), let .symlink(path): path
        }
    }

    var type: Entry.EntryType {
        switch self {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        }
    }

    var data: Data {
        switch self {
        case .file: Data("x".utf8)
        case .directory: Data()
        case .symlink: Data("target".utf8)
        }
    }
}

private struct UpdateFixture {
    let root: URL
    let inbox: URL
    var manifestURL: URL { inbox.appendingPathComponent("manifest.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubReleaseUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeApp(named: String, marketing: String, build: Int) throws -> URL {
        let app = root.appendingPathComponent(named, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": murmurBundleIdentifier,
            "CFBundleExecutable": "Murmure",
            "CFBundleShortVersionString": marketing,
            "CFBundleVersion": String(build)
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = macOS.appendingPathComponent("Murmure")
        try Data("binary".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return app
    }

    func makeReleaseArchive(marketing: String, build: Int) throws -> URL {
        let app = try makeApp(named: "Murmure.app", marketing: marketing, build: build)
        let archive = root.appendingPathComponent("Murmure-\(UUID().uuidString).zip")
        try FileManager.default.zipItem(
            at: app,
            to: archive,
            shouldKeepParent: true,
            compressionMethod: .none
        )
        return archive
    }

    func makeArchive(entries: [TestArchiveEntry]) throws -> URL {
        let url = root.appendingPathComponent("Archive-\(UUID().uuidString).zip")
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            let data = entry.data
            try archive.addEntry(
                with: entry.path,
                type: entry.type,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    let start = min(Int(position), data.count)
                    let end = min(start + size, data.count)
                    return data.subdata(in: start..<end)
                }
            )
        }
        return url
    }

    func transactionDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
