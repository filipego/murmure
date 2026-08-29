import Foundation
import XCTest
@testable import MurmurUpdateCore

final class UpdateCoreTests: XCTestCase {
    func testAppVersionUsesSemanticMarketingVersionBeforeBuild() {
        XCTAssertGreaterThan(
            AppVersion(marketing: "0.10.0", build: 1),
            AppVersion(marketing: "0.9.9", build: 99)
        )
        XCTAssertGreaterThan(
            AppVersion(marketing: "1.2.3", build: 8),
            AppVersion(marketing: "1.2.3", build: 7)
        )
    }

    func testManifestDecodesTheLocalBundleLocation() throws {
        let json = """
        {
          "bundleIdentifier": "ai.pivotstudio.murmur-youtube",
          "version": { "marketing": "0.2.0", "build": 12 },
          "stagedBundleURL": "file:///tmp/Murmur%20YouTube.app",
          "createdAt": "2026-08-28T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(UpdateManifest.self, from: json)

        XCTAssertEqual(manifest.bundleIdentifier, "ai.pivotstudio.murmur-youtube")
        XCTAssertEqual(manifest.version, AppVersion(marketing: "0.2.0", build: 12))
        XCTAssertEqual(manifest.stagedBundleURL.path, "/tmp/Murmur YouTube.app")
    }

    func testBundleValidatorAcceptsOnlyACompleteMurmurBundle() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let app = try root.makeApp(
            identifier: "ai.pivotstudio.murmur-youtube",
            marketing: "0.2.0",
            build: 12
        )

        let version = try BundleValidator.validate(
            bundleURL: app,
            expectedIdentifier: "ai.pivotstudio.murmur-youtube"
        )
        XCTAssertEqual(version, AppVersion(marketing: "0.2.0", build: 12))

        let wrongID = try root.makeApp(
            named: "Wrong.app",
            identifier: "com.example.other",
            marketing: "0.2.0",
            build: 12
        )
        XCTAssertThrowsError(try BundleValidator.validate(
            bundleURL: wrongID,
            expectedIdentifier: "ai.pivotstudio.murmur-youtube"
        )) { error in
            XCTAssertEqual(error as? BundleValidationError, .bundleIdentifierMismatch)
        }

        let traversal = try root.makeApp(
            named: "Traversal.app",
            identifier: "ai.pivotstudio.murmur-youtube",
            marketing: "0.2.0",
            build: 12
        )
        let traversalPlist = traversal.appendingPathComponent("Contents/Info.plist")
        var plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: traversalPlist),
            options: [],
            format: nil
        ) as! [String: Any]
        plist["CFBundleExecutable"] = "../MurmurYouTube"
        let traversalData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try traversalData.write(to: traversalPlist)
        XCTAssertThrowsError(try BundleValidator.validate(
            bundleURL: traversal,
            expectedIdentifier: "ai.pivotstudio.murmur-youtube"
        )) { error in
            XCTAssertEqual(error as? BundleValidationError, .executableMissing)
        }
    }

    func testBundleReplacerPreservesBackupAndIsIdempotent() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let destination = try root.makeApp(
            named: "Installed.app",
            identifier: "ai.pivotstudio.murmur-youtube",
            marketing: "0.1.0",
            build: 1,
            marker: "old"
        )
        let staged = try root.makeApp(
            named: "Staged.app",
            identifier: "ai.pivotstudio.murmur-youtube",
            marketing: "0.2.0",
            build: 2,
            marker: "new"
        )
        let backup = root.url.appendingPathComponent("backup.app")

        let first = try BundleReplacer.replace(
            stagedURL: staged,
            destinationURL: destination,
            backupURL: backup
        )
        XCTAssertEqual(first, .installed)
        XCTAssertEqual(try marker(in: destination), "new")
        XCTAssertEqual(try marker(in: backup), "old")

        let second = try BundleReplacer.replace(
            stagedURL: staged,
            destinationURL: destination,
            backupURL: backup
        )
        XCTAssertEqual(second, .alreadyInstalled)
        XCTAssertEqual(try marker(in: backup), "old")
    }

    func testBundleReplacerRefusesToOverwriteAnExistingBackup() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let destination = try root.makeApp(
            named: "Installed.app",
            identifier: "ai.pivotstudio.murmur-youtube",
            marketing: "0.1.0",
            build: 1,
            marker: "old"
        )
        let staged = try root.makeApp(
            named: "Staged.app",
            identifier: "ai.pivotstudio.murmur-youtube",
            marketing: "0.2.0",
            build: 2,
            marker: "new"
        )
        let backup = try root.makeApp(
            named: "backup.app",
            identifier: "ai.pivotstudio.murmur-youtube",
            marketing: "0.0.1",
            build: 1,
            marker: "keep"
        )

        XCTAssertThrowsError(try BundleReplacer.replace(
            stagedURL: staged,
            destinationURL: destination,
            backupURL: backup
        )) { error in
            XCTAssertEqual(error as? BundleReplacementError, .backupAlreadyExists)
        }
        XCTAssertEqual(try marker(in: destination), "old")
        XCTAssertEqual(try marker(in: backup), "keep")
    }

    private func marker(in app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("marker.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MurmurUpdateCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func makeApp(
        named: String = "Murmur YouTube.app",
        identifier: String,
        marketing: String,
        build: Int,
        marker: String = "fixture"
    ) throws -> URL {
        let app = url.appendingPathComponent(named, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "MurmurYouTube",
            "CFBundleShortVersionString": marketing,
            "CFBundleVersion": String(build)
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let executableURL = macOS.appendingPathComponent("MurmurYouTube")
        try Data("binary".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker.txt"))
        return app
    }
}
