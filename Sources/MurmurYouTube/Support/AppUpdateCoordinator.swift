import AppKit
import Foundation
import MurmurUpdateCore
import Observation

typealias HostedUpdateStager = @Sendable (
    AppVersion,
    URL,
    URL
) async throws -> UpdateManifest?

enum HubSection: String, CaseIterable, Identifiable {
    case home
    case dictionary
    case snippets
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .dictionary: "text.book.closed"
        case .snippets: "text.quote"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// The small, observable adapter used by SwiftUI for verified staged updates.
///
/// Manifest parsing, path containment, and bundle validation live here so views only need to
/// render a state and invoke actions. Hosted transport and archive handling remain inside
/// MurmurUpdateCore; the nested helper receives an argv array and performs the replacement after
/// the parent exits.
@MainActor
@Observable
final class AppUpdateCoordinator {
    private(set) var state: UpdateState = .idle
    let currentVersion: AppVersion

    let inboxURL: URL
    private let bundleURL: URL
    private let expectedIdentifier: String
    private let fileManager: FileManager
    private let helperURLOverride: URL?
    private let hostedUpdateStager: HostedUpdateStager
    private let signatureValidator: (URL, URL) throws -> Void
    private let launchHelper: (URL, [String]) throws -> Void
    private let terminateApplication: () -> Void

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        inboxURL: URL? = nil,
        helperURL: URL? = nil,
        expectedIdentifier: String = murmurBundleIdentifier,
        fileManager: FileManager = .default,
        hostedUpdateStager: @escaping HostedUpdateStager = AppUpdateCoordinator.stageHostedUpdate,
        signatureValidator: @escaping (URL, URL) throws -> Void = ReleaseCodeSignatureValidator.validateReplacement,
        launchHelper: @escaping (URL, [String]) throws -> Void = AppUpdateCoordinator.launch,
        terminateApplication: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.inboxURL = (inboxURL ?? Self.defaultInboxURL(fileManager: fileManager)).standardizedFileURL
        self.helperURLOverride = helperURL?.standardizedFileURL
        self.expectedIdentifier = expectedIdentifier
        self.fileManager = fileManager
        self.hostedUpdateStager = hostedUpdateStager
        self.signatureValidator = signatureValidator
        self.launchHelper = launchHelper
        self.terminateApplication = terminateApplication

        if let version = try? BundleValidator.validate(
            bundleURL: self.bundleURL,
            expectedIdentifier: expectedIdentifier
        ) {
            currentVersion = version
        } else {
            currentVersion = Self.versionFromInfoPlist(
                bundleURL: self.bundleURL,
                fallback: AppVersion(marketing: "0.0.0", build: 0)
            )
        }
    }

    var manifestURL: URL { inboxURL.appendingPathComponent("manifest.json") }

    /// Refreshes local staged state without making a network request.
    func refreshStagedUpdate() {
        guard state != .checking, state != .installing else { return }

        do {
            if let manifest = try validatedStagedManifest() {
                state = .available(manifest)
            } else {
                state = .idle
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Retained for callers that refresh the local inbox when their view appears.
    func checkForStagedUpdate() {
        refreshStagedUpdate()
    }

    /// Checks GitHub Releases and falls back to a valid local staged update on hosted failure.
    func checkForUpdates() async {
        guard state != .checking, state != .installing else { return }
        state = .checking

        do {
            if let hostedManifest = try await hostedUpdateStager(
                currentVersion,
                bundleURL,
                inboxURL
            ) {
                state = .available(hostedManifest)
                return
            }

            if let localManifest = try validatedStagedManifest() {
                state = .available(localManifest)
            } else {
                state = .upToDate
            }
        } catch {
            let hostedError = error
            do {
                if let localManifest = try validatedStagedManifest() {
                    state = .available(localManifest)
                } else {
                    state = .failed(hostedError.localizedDescription)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Launches the nested helper with structured arguments and asks the app to exit.
    func installAvailableUpdate() {
        guard state != .checking, state != .installing else { return }

        let manifest: UpdateManifest
        if case let .available(value) = state {
            manifest = value
        } else {
            refreshStagedUpdate()
            guard case let .available(value) = state else { return }
            manifest = value
        }

        state = .installing
        do {
            guard isContained(manifest.stagedBundleURL, inside: inboxURL) else {
                throw CoordinatorError.stagedPathOutsideInbox
            }
            _ = try BundleValidator.validate(
                bundleURL: manifest.stagedBundleURL,
                expectedIdentifier: expectedIdentifier
            )
            guard fileManager.fileExists(atPath: bundleURL.path) else {
                throw BundleValidationError.bundleMissing
            }

            try signatureValidator(manifest.stagedBundleURL, bundleURL)
            let helper = try resolvedHelperURL()
            let arguments = [
                "--source", manifest.stagedBundleURL.path,
                "--destination", bundleURL.path,
                "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
            ]
            try launchHelper(helper, arguments)
            terminateApplication()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func validatedStagedManifest() throws -> UpdateManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(UpdateManifest.self, from: data)

        guard manifest.bundleIdentifier == expectedIdentifier else {
            throw CoordinatorError.bundleIdentifierMismatch
        }
        guard isContained(manifest.stagedBundleURL, inside: inboxURL) else {
            throw CoordinatorError.stagedPathOutsideInbox
        }
        let stagedURL = manifest.stagedBundleURL.standardizedFileURL
        let stagedVersion = try BundleValidator.validate(
            bundleURL: stagedURL,
            expectedIdentifier: expectedIdentifier
        )
        guard stagedVersion == manifest.version else {
            throw CoordinatorError.manifestVersionMismatch
        }

        return manifest.version > currentVersion ? manifest : nil
    }

    private func resolvedHelperURL() throws -> URL {
        if let helperURLOverride {
            guard fileManager.isExecutableFile(atPath: helperURLOverride.path) else {
                throw CoordinatorError.helperMissing
            }
            return helperURLOverride
        }

        // Production bundles must carry their own helper. Do not fall back to a sibling or
        // loose executable: that would let a planted binary inherit the updater's trust boundary.
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/MurmurUpdateHelper")
        guard fileManager.isExecutableFile(atPath: helper.path) else {
            throw CoordinatorError.helperMissing
        }
        return helper
    }

    private func isContained(_ candidate: URL, inside root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidatePath != rootPath else { return false }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func defaultInboxURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = appSupport.appendingPathComponent("MurmurYouTube/Updates", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func versionFromInfoPlist(bundleURL: URL, fallback: AppVersion) -> AppVersion {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let marketing = dictionary["CFBundleShortVersionString"] as? String else {
            return fallback
        }
        let build: Int
        if let value = dictionary["CFBundleVersion"] as? Int {
            build = value
        } else if let value = dictionary["CFBundleVersion"] as? NSNumber {
            build = value.intValue
        } else if let value = dictionary["CFBundleVersion"] as? String, let parsed = Int(value) {
            build = parsed
        } else {
            build = fallback.build
        }
        return AppVersion(marketing: marketing, build: build)
    }

    private nonisolated static func launch(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
    }

    private nonisolated static func stageHostedUpdate(
        currentVersion: AppVersion,
        installedBundleURL: URL,
        inboxURL: URL
    ) async throws -> UpdateManifest? {
        try await GitHubReleaseUpdater().stageLatestUpdate(
            newerThan: currentVersion,
            installedBundleURL: installedBundleURL,
            inboxURL: inboxURL
        )
    }
}

private enum CoordinatorError: Error, LocalizedError {
    case bundleIdentifierMismatch
    case stagedPathOutsideInbox
    case manifestVersionMismatch
    case helperMissing

    var errorDescription: String? {
        switch self {
        case .bundleIdentifierMismatch: "The staged update belongs to a different application."
        case .stagedPathOutsideInbox: "The staged update path is outside Murmure's update inbox."
        case .manifestVersionMismatch: "The staged bundle version does not match its manifest."
        case .helperMissing: "The Murmure update helper is missing from this installation."
        }
    }
}
