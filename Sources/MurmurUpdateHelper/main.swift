import AppKit
import Darwin
import Foundation
import MurmurUpdateCore

/// The update helper is deliberately a tiny argv-only executable. It receives paths as
/// structured Process arguments, never through a shell command, and performs all validation
/// before it touches the installed bundle.
struct MurmurUpdateHelper {
    private static let defaultParentWait: TimeInterval = 30

    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(Options.usage)
                return
            }

            let source = try options.requiredURL(for: .source)
            let destination = try options.requiredURL(for: .destination)
            let parentPID = options.parentPID
            let backup = options.backupURL ?? makeBackupURL(for: destination)

            // Validate both bundles while the old app is still running. This helper is only an
            // in-place updater; refusing a missing destination prevents a malformed invocation
            // from turning it into a generic arbitrary-app installer.
            _ = try BundleValidator.validate(bundleURL: source)
            guard Foundation.FileManager().fileExists(atPath: destination.path) else {
                throw HelperError.destinationMissing
            }
            _ = try BundleValidator.validate(bundleURL: destination)
            try ReleaseCodeSignatureValidator.validateReplacement(
                stagedBundleURL: source,
                installedBundleURL: destination
            )

            if let parentPID, parentPID > 0 {
                try waitForParentExit(parentPID, timeout: options.timeout ?? defaultParentWait)
            }

            let result = try BundleReplacer.replace(
                stagedURL: source,
                destinationURL: destination,
                backupURL: backup,
                validateCopiedBundle: { copiedBundle in
                    try ReleaseCodeSignatureValidator.validateReplacement(
                        stagedBundleURL: copiedBundle,
                        installedBundleURL: destination
                    )
                }
            )
            print(result == .installed ? "Murmure update installed." : "Murmure update already installed.")

            if !options.noRelaunch {
                guard NSWorkspace.shared.open(destination) else {
                    throw HelperError.relaunchFailed
                }
            }
        } catch {
            writeError(error.localizedDescription)
            exit(1)
        }
    }

    private static func writeError(_ message: String) {
        let text = "MurmurUpdateHelper: \(message)\n"
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func makeBackupURL(for destination: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        let name = destination.deletingPathExtension().lastPathComponent
        return destination.deletingLastPathComponent()
            .appendingPathComponent("\(name).backup-\(stamp).app")
    }

    private static func waitForParentExit(_ pid: pid_t, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            if !isProcessAlive(pid) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if isProcessAlive(pid) {
            throw HelperError.parentStillRunning
        }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

private enum HelperError: Error, LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case destinationMissing
    case parentStillRunning
    case relaunchFailed

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name): "Missing required argument: \(name)"
        case let .invalidArgument(value): "Invalid argument: \(value)"
        case .destinationMissing: "The installed Murmure application bundle does not exist."
        case .parentStillRunning: "The parent application did not exit before the timeout."
        case .relaunchFailed: "The updated application could not be relaunched."
        }
    }
}

private struct Options {
    enum Key: String {
        case source
        case destination
        case backup
        case parentPID = "parent-pid"
        case timeout
    }

    static let usage = """
    Usage: MurmurUpdateHelper --source <Murmure.app> --destination <installed.app> [options]

      --source <path>       Staged Murmure bundle to install (required)
      --destination <path>  Installed Murmure bundle (required)
      --backup <path>       Optional backup bundle path
      --parent-pid <pid>    Wait for the launching app to exit
      --timeout <seconds>   Parent wait timeout (default: 30)
      --no-relaunch         Install without opening the destination bundle
      --help                Show this help
    """

    var values: [Key: String] = [:]
    var noRelaunch = false
    var help = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--no-relaunch" {
                noRelaunch = true
                index += 1
                continue
            }
            if argument == "--help" || argument == "-h" {
                help = true
                index += 1
                continue
            }
            guard argument.hasPrefix("--") else {
                throw HelperError.invalidArgument(argument)
            }

            let withoutPrefix = String(argument.dropFirst(2))
            let parts = withoutPrefix.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard let parsedKey = Key(rawValue: key) else {
                throw HelperError.invalidArgument(argument)
            }

            let value: String
            if parts.count == 2 {
                value = String(parts[1])
            } else {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw HelperError.missingArgument("--\(key)")
                }
                value = arguments[index]
            }
            values[parsedKey] = value
            index += 1
        }

        if let raw = values[.parentPID], (Int32(raw) ?? 0) <= 0 {
            throw HelperError.invalidArgument(raw)
        }
        if let raw = values[.timeout],
           let value = Double(raw),
           value.isFinite,
           value >= 0 {
            // Valid timeout; the computed property below can safely unwrap it.
        } else if let raw = values[.timeout] {
            throw HelperError.invalidArgument(raw)
        }
    }

    func requiredURL(for key: Key) throws -> URL {
        guard let raw = values[key], !raw.isEmpty else {
            throw HelperError.missingArgument("--\(key.rawValue)")
        }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw HelperError.invalidArgument(raw)
        }
        return url
    }

    var backupURL: URL? {
        guard let raw = values[.backup], !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL
    }

    var parentPID: pid_t? {
        guard let raw = values[.parentPID], let value = Int32(raw), value > 0 else { return nil }
        return pid_t(value)
    }

    var timeout: TimeInterval? {
        guard let raw = values[.timeout], let value = Double(raw), value >= 0 else { return nil }
        return value
    }
}

MurmurUpdateHelper.main()
