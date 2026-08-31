import Foundation

/// The bundle identity shared by the app, staged update manifests, and the replacement
/// helper. Keeping this in the update module means every boundary validates the same value.
public let murmurBundleIdentifier = "ai.pivotstudio.murmur-youtube"

/// A marketing version plus the monotonically increasing build number from Info.plist.
///
/// Marketing versions are compared using their numeric dot-separated components first, then
/// by prerelease identifier (when present), and finally by build number. The comparison is
/// intentionally deterministic for versions produced by Xcode as well as the simple fixture
/// versions used by tests; malformed marketing strings fall back to a lexical comparison.
public struct AppVersion: Codable, Comparable, Equatable, Sendable {
    public let marketing: String
    public let build: Int

    public init(marketing: String, build: Int) {
        self.marketing = marketing
        self.build = build
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let marketingComparison = compareMarketing(lhs.marketing, rhs.marketing)
        if marketingComparison != .orderedSame { return marketingComparison == .orderedAscending }
        return lhs.build < rhs.build
    }

    private static func compareMarketing(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = MarketingVersion(lhs)
        let right = MarketingVersion(rhs)

        guard let left, let right else {
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }

        let componentCount = max(left.numbers.count, right.numbers.count)
        for index in 0..<componentCount {
            let l = index < left.numbers.count ? left.numbers[index] : 0
            let r = index < right.numbers.count ? right.numbers[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }

        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, .some):
            return .orderedDescending
        case (.some, nil):
            return .orderedAscending
        case let (.some(l), .some(r)):
            return comparePrerelease(l, r)
        }
    }

    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for (l, r) in zip(lhs, rhs) {
            if l == r { continue }
            let lNumber = Int(l)
            let rNumber = Int(r)
            switch (lNumber, rNumber) {
            case let (.some(lValue), .some(rValue)):
                return lValue < rValue ? .orderedAscending : .orderedDescending
            case (.some, nil):
                return .orderedAscending
            case (nil, .some):
                return .orderedDescending
            case (nil, nil):
                return l < r ? .orderedAscending : .orderedDescending
            }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    private struct MarketingVersion {
        let numbers: [Int]
        let prerelease: [String]?

        init?(_ raw: String) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
            let versionAndMetadata = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: true)
            guard let core = versionAndMetadata.first, !core.isEmpty else { return nil }
            let coreAndPrerelease = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let numberParts = coreAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
            guard !numberParts.isEmpty,
                  numberParts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else { return nil }
            numbers = numberParts.compactMap { Int($0) }
            if coreAndPrerelease.count == 2 {
                let identifiers = coreAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false)
                guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
                prerelease = identifiers.map(String.init)
            } else {
                prerelease = nil
            }
        }
    }
}

public struct UpdateManifest: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: AppVersion
    public let stagedBundleURL: URL
    public let createdAt: Date

    public init(
        bundleIdentifier: String,
        version: AppVersion,
        stagedBundleURL: URL,
        createdAt: Date = Date()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.stagedBundleURL = stagedBundleURL
        self.createdAt = createdAt
    }
}

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateManifest)
    case installing
    case failed(String)
}

public enum BundleValidationError: Error, Equatable, Sendable {
    case bundleMissing
    case notAnApplicationBundle
    case infoPlistMissing
    case bundleIdentifierMismatch
    case executableMissing
    case invalidVersion
    case invalidBundlePath
}

extension BundleValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bundleMissing: "The application bundle does not exist."
        case .notAnApplicationBundle: "The update is not a macOS application bundle."
        case .infoPlistMissing: "The application bundle is missing Info.plist."
        case .bundleIdentifierMismatch: "The application bundle identifier is not Murmure."
        case .executableMissing: "The application bundle is missing its executable."
        case .invalidVersion: "The application bundle has an invalid version."
        case .invalidBundlePath: "The application bundle path is invalid."
        }
    }
}

/// Reads just enough of an app bundle to establish that it is a complete Murmure bundle.
public enum BundleValidator {
    public static func validate(
        bundleURL: URL,
        expectedIdentifier: String = murmurBundleIdentifier
    ) throws -> AppVersion {
        let fileManager = FileManager.default
        let url = bundleURL.standardizedFileURL
        guard !url.path.isEmpty else { throw BundleValidationError.invalidBundlePath }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BundleValidationError.bundleMissing
        }
        guard isDirectory.boolValue, url.pathExtension.lowercased() == "app" else {
            throw BundleValidationError.notAnApplicationBundle
        }

        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            throw BundleValidationError.infoPlistMissing
        }

        guard let identifier = plist["CFBundleIdentifier"] as? String,
              identifier == expectedIdentifier else {
            throw BundleValidationError.bundleIdentifierMismatch
        }

        guard let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              !executable.contains("/"),
              !executable.contains("\\"),
              executable != ".",
              executable != ".." else {
            throw BundleValidationError.executableMissing
        }
        let macOSURL = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let executableURL = macOSURL.appendingPathComponent(executable)
        var executableIsDirectory: ObjCBool = false
        guard executableURL.deletingLastPathComponent().standardizedFileURL == macOSURL.standardizedFileURL,
              fileManager.fileExists(atPath: executableURL.path, isDirectory: &executableIsDirectory),
              !executableIsDirectory.boolValue,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw BundleValidationError.executableMissing
        }

        guard let marketing = plist["CFBundleShortVersionString"] as? String,
              !marketing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let buildValue = plist["CFBundleVersion"],
              let build = parseBuild(buildValue),
              build >= 0 else {
            throw BundleValidationError.invalidVersion
        }
        return AppVersion(marketing: marketing, build: build)
    }

    private static func parseBuild(_ value: Any) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

public enum BundleReplacementResult: Equatable, Sendable {
    case installed
    case alreadyInstalled
}

public enum BundleReplacementError: Error, Equatable, Sendable {
    case backupAlreadyExists
}

extension BundleReplacementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .backupAlreadyExists:
            "The update backup path already exists; refusing to overwrite it."
        }
    }
}

/// Replaces a destination app atomically enough for the helper's short-lived update flow.
/// The staged bundle is copied and validated beside the destination before the old bundle moves.
public enum BundleReplacer {
    public static func replace(
        stagedURL: URL,
        destinationURL: URL,
        backupURL: URL,
        expectedIdentifier: String = murmurBundleIdentifier,
        validateCopiedBundle: (URL) throws -> Void = { _ in },
        fileManager: FileManager = .default
    ) throws -> BundleReplacementResult {
        let stagedVersion = try BundleValidator.validate(
            bundleURL: stagedURL,
            expectedIdentifier: expectedIdentifier
        )

        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)
        if destinationExists {
            let destinationVersion = try BundleValidator.validate(
                bundleURL: destinationURL,
                expectedIdentifier: expectedIdentifier
            )
            if destinationVersion >= stagedVersion {
                return .alreadyInstalled
            }
        }

        let destinationParent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let destinationName = destinationURL.deletingPathExtension().lastPathComponent
        let temporaryURL = destinationParent.appendingPathComponent(
            ".\(destinationName).update-\(UUID().uuidString).app",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        var movedDestination = false
        do {
            if destinationExists {
                if fileManager.fileExists(atPath: backupURL.path) {
                    // A supplied backup path is deterministic for tests and for retries. Never
                    // destroy an earlier rollback copy; callers can choose a fresh path instead.
                    throw BundleReplacementError.backupAlreadyExists
                }
            }

            try fileManager.copyItem(at: stagedURL, to: temporaryURL)
            let copiedVersion = try BundleValidator.validate(
                bundleURL: temporaryURL,
                expectedIdentifier: expectedIdentifier
            )
            guard copiedVersion == stagedVersion else {
                throw BundleValidationError.invalidVersion
            }
            try validateCopiedBundle(temporaryURL)

            if destinationExists {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                movedDestination = true
            }

            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            if movedDestination {
                // Installation already succeeded. A cleanup failure must not prevent the new
                // app from relaunching, but the normal path removes the rollback copy at once.
                try? fileManager.removeItem(at: backupURL)
            }
            return .installed
        } catch {
            // Best-effort rollback: an interrupted copy must not leave the app absent.
            if movedDestination,
               !fileManager.fileExists(atPath: destinationURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            throw error
        }
    }
}
