import Foundation

enum RuntimeCompatibilityIssue: Equatable, Sendable {
    case unsupportedArchitecture(actual: String)
    case unsupportedOperatingSystem(actualMajor: Int)

    var message: String {
        switch self {
        case let .unsupportedArchitecture(actual):
            "This modern Murmure build requires Apple Silicon. This Mac reports \(actual). Intel support is still a separate compatibility investigation."
        case let .unsupportedOperatingSystem(actualMajor):
            "This modern Murmure build requires macOS 26 or later. This Mac reports macOS \(actualMajor)."
        }
    }
}

enum RuntimeCompatibilityPolicy {
    static let requirementsSummary = "Apple Silicon · macOS 26 or later"

    static func issue(
        architecture: String,
        operatingSystem: OperatingSystemVersion
    ) -> RuntimeCompatibilityIssue? {
        guard architecture == "arm64" || architecture == "arm64e" else {
            return .unsupportedArchitecture(actual: architecture)
        }
        guard operatingSystem.majorVersion >= 26 else {
            return .unsupportedOperatingSystem(actualMajor: operatingSystem.majorVersion)
        }
        return nil
    }

    static var currentIssue: RuntimeCompatibilityIssue? {
        issue(
            architecture: currentArchitecture,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
