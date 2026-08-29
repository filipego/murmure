import Foundation
import Testing

@testable import MurmurYouTube
import MurmurUpdateCore

@Suite("App update coordinator")
struct AppUpdateCoordinatorTests {
    @Test("hosted check exposes checking before reporting up to date")
    @MainActor
    func hostedCheckReportsUpToDate() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let observation = CoordinatorObservation()
        let coordinator = AppUpdateCoordinator(
            bundleURL: fixture.installedBundle,
            inboxURL: fixture.inbox,
            hostedUpdateStager: { _, _, _ in
                await MainActor.run { observation.recordState() }
                return nil
            }
        )
        observation.coordinator = coordinator

        await coordinator.checkForUpdates()

        #expect(observation.states == [.checking])
        #expect(coordinator.state == .upToDate)
    }

    @Test("hosted check publishes a newer staged manifest")
    @MainActor
    func hostedCheckPublishesAvailableManifest() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let hostedManifest = try fixture.makeManifest(marketing: "0.1.12", build: 12)
        let coordinator = AppUpdateCoordinator(
            bundleURL: fixture.installedBundle,
            inboxURL: fixture.inbox,
            hostedUpdateStager: { _, _, _ in hostedManifest }
        )

        await coordinator.checkForUpdates()

        #expect(coordinator.state == .available(hostedManifest))
    }

    @Test("hosted failure falls back to a valid local staged update")
    @MainActor
    func hostedFailureUsesValidLocalManifest() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let localManifest = try fixture.makeManifest(marketing: "0.1.12", build: 12)
        try fixture.writeManifest(localManifest)
        let coordinator = AppUpdateCoordinator(
            bundleURL: fixture.installedBundle,
            inboxURL: fixture.inbox,
            hostedUpdateStager: { _, _, _ in throw CoordinatorTestError.hostedFailure }
        )

        await coordinator.checkForUpdates()

        #expect(coordinator.state == .available(localManifest))
    }

    @Test("hosted and local failures report failure")
    @MainActor
    func hostedAndLocalFailuresReportFailure() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        try Data("not a manifest".utf8).write(to: fixture.manifestURL)
        let coordinator = AppUpdateCoordinator(
            bundleURL: fixture.installedBundle,
            inboxURL: fixture.inbox,
            hostedUpdateStager: { _, _, _ in throw CoordinatorTestError.hostedFailure }
        )

        await coordinator.checkForUpdates()

        guard case .failed = coordinator.state else {
            Issue.record("Expected failed state, got \(coordinator.state)")
            return
        }
    }

    @Test("install validates signature before helper launch and termination")
    @MainActor
    func installValidatesSignatureBeforeLaunchingHelper() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let manifest = try fixture.makeManifest(marketing: "0.1.12", build: 12)
        try fixture.writeManifest(manifest)
        let helper = try fixture.makeHelper()
        let events = CoordinatorEventRecorder()
        let coordinator = AppUpdateCoordinator(
            bundleURL: fixture.installedBundle,
            inboxURL: fixture.inbox,
            helperURL: helper,
            hostedUpdateStager: { _, _, _ in nil },
            signatureValidator: { staged, installed in
                #expect(staged == manifest.stagedBundleURL)
                #expect(installed == fixture.installedBundle)
                events.append("signature")
            },
            launchHelper: { _, _ in events.append("helper") },
            terminateApplication: { events.append("terminate") }
        )
        coordinator.refreshStagedUpdate()

        coordinator.installAvailableUpdate()

        #expect(events.values == ["signature", "helper", "terminate"])
    }

    @Test("signature failure prevents helper launch and termination")
    @MainActor
    func signatureFailureStopsInstallation() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let manifest = try fixture.makeManifest(marketing: "0.1.12", build: 12)
        try fixture.writeManifest(manifest)
        let helper = try fixture.makeHelper()
        let events = CoordinatorEventRecorder()
        let coordinator = AppUpdateCoordinator(
            bundleURL: fixture.installedBundle,
            inboxURL: fixture.inbox,
            helperURL: helper,
            hostedUpdateStager: { _, _, _ in nil },
            signatureValidator: { _, _ in
                events.append("signature")
                throw CoordinatorTestError.signatureFailure
            },
            launchHelper: { _, _ in events.append("helper") },
            terminateApplication: { events.append("terminate") }
        )
        coordinator.refreshStagedUpdate()

        coordinator.installAvailableUpdate()

        #expect(events.values == ["signature"])
        guard case .failed = coordinator.state else {
            Issue.record("Expected signature failure state")
            return
        }
    }
}

@MainActor
private final class CoordinatorObservation {
    weak var coordinator: AppUpdateCoordinator?
    private(set) var states: [UpdateState] = []

    func recordState() {
        if let coordinator {
            states.append(coordinator.state)
        }
    }
}

private enum CoordinatorTestError: Error {
    case hostedFailure
    case signatureFailure
}

@MainActor
private final class CoordinatorEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private struct CoordinatorFixture {
    let root: URL
    let inbox: URL
    let installedBundle: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdateCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        inbox = root.appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        installedBundle = try Self.makeApp(
            at: root.appendingPathComponent("Installed.app", isDirectory: true),
            marketing: "0.1.11",
            build: 11
        )
    }

    var manifestURL: URL { inbox.appendingPathComponent("manifest.json") }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeManifest(marketing: String, build: Int) throws -> UpdateManifest {
        let bundle = try Self.makeApp(
            at: inbox.appendingPathComponent("staged-\(build)/Murmure.app", isDirectory: true),
            marketing: marketing,
            build: build
        )
        return UpdateManifest(
            bundleIdentifier: murmurBundleIdentifier,
            version: AppVersion(marketing: marketing, build: build),
            stagedBundleURL: bundle,
            createdAt: Date(timeIntervalSince1970: TimeInterval(build))
        )
    }

    func writeManifest(_ manifest: UpdateManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL)
    }

    func makeHelper() throws -> URL {
        let helper = root.appendingPathComponent("MurmurUpdateHelper")
        try Data("fixture".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        return helper
    }

    private static func makeApp(at app: URL, marketing: String, build: Int) throws -> URL {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": murmurBundleIdentifier,
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
        let executable = macOS.appendingPathComponent("MurmurYouTube")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return app
    }
}
