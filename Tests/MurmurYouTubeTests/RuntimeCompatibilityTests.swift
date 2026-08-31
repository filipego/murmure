import Foundation
import Testing
@testable import MurmurYouTube

@Suite("Modern Mac runtime compatibility")
struct RuntimeCompatibilityTests {
    @Test("Apple Silicon on macOS 26 or newer is supported")
    func supportedRuntime() {
        #expect(RuntimeCompatibilityPolicy.issue(
            architecture: "arm64",
            operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) == nil)
        #expect(RuntimeCompatibilityPolicy.issue(
            architecture: "arm64e",
            operatingSystem: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)
        ) == nil)
    }

    @Test("Intel is not presented as compatible with the modern app")
    func unsupportedArchitecture() {
        #expect(RuntimeCompatibilityPolicy.issue(
            architecture: "x86_64",
            operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) == .unsupportedArchitecture(actual: "x86_64"))
    }

    @Test("older macOS is rejected even on Apple Silicon")
    func unsupportedOperatingSystem() {
        #expect(RuntimeCompatibilityPolicy.issue(
            architecture: "arm64",
            operatingSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 2)
        ) == .unsupportedOperatingSystem(actualMajor: 15))
    }

    @Test("friend-facing requirement copy is exact")
    func requirementCopy() {
        #expect(RuntimeCompatibilityPolicy.requirementsSummary == "Apple Silicon · macOS 26 or later")
    }
}
