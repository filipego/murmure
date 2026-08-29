import CryptoKit
import Foundation
import Security

public let murmurReleaseCertificateRootSHA1 = "dd1175e05550d5ff2ac47ca8621caf97be7ab707"

public enum ReleaseCodeSignatureValidatorError: Error, Equatable, Sendable {
    case staticCodeUnavailable
    case pinnedRequirementUnavailable
    case installedRequirementUnavailable
    case certificateChainUnavailable
    case certificatePinMismatch
    case signatureRejected
}

extension ReleaseCodeSignatureValidatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .staticCodeUnavailable: "The app code signature could not be read."
        case .pinnedRequirementUnavailable: "The release signing requirement is invalid."
        case .installedRequirementUnavailable: "The installed app signing requirement is unavailable."
        case .certificateChainUnavailable: "The app signing certificate chain is unavailable."
        case .certificatePinMismatch: "The app signing certificate does not match the release pin."
        case .signatureRejected: "The app code signature is invalid."
        }
    }
}

public enum ReleaseCodeSignatureValidator {
    public static func validateReplacement(
        stagedBundleURL: URL,
        installedBundleURL: URL
    ) throws {
        let installedCode = try staticCode(at: installedBundleURL)
        let stagedCode = try staticCode(at: stagedBundleURL)
        let pinnedRequirement = try releaseRequirement()
        let installedRequirement = try designatedRequirement(for: installedCode)

        let installedCertificateMatches = try rootCertificateSHA1(for: installedCode)
            == murmurReleaseCertificateRootSHA1
        let stagedCertificateMatches = try rootCertificateSHA1(for: stagedCode)
            == murmurReleaseCertificateRootSHA1
        guard installedCertificateMatches, stagedCertificateMatches else {
            throw ReleaseCodeSignatureValidatorError.certificatePinMismatch
        }

        let installedPinnedStatus = SecStaticCodeCheckValidity(
            installedCode,
            validationFlags,
            pinnedRequirement
        )
        let installedStatus = SecStaticCodeCheckValidity(installedCode, validationFlags, nil)
        guard acceptsValidationStatus(
            installedStatus,
            pinnedRequirementMatches: isAllowedStatus(installedPinnedStatus),
            certificatePinsMatch: installedCertificateMatches
        ) else {
            throw ReleaseCodeSignatureValidatorError.signatureRejected
        }

        let stagedPinnedStatus = SecStaticCodeCheckValidity(
            stagedCode,
            validationFlags,
            pinnedRequirement
        )
        let stagedInstalledRequirementStatus = SecStaticCodeCheckValidity(
            stagedCode,
            validationFlags,
            installedRequirement
        )
        let stagedStatus = SecStaticCodeCheckValidity(stagedCode, validationFlags, nil)
        guard acceptsValidationStatus(
            stagedStatus,
            pinnedRequirementMatches: isAllowedStatus(stagedPinnedStatus)
                && isAllowedStatus(stagedInstalledRequirementStatus),
            certificatePinsMatch: stagedCertificateMatches
        ) else {
            throw ReleaseCodeSignatureValidatorError.signatureRejected
        }
    }

    package static func acceptsValidationStatus(
        _ status: OSStatus,
        pinnedRequirementMatches: Bool,
        certificatePinsMatch: Bool
    ) -> Bool {
        pinnedRequirementMatches && certificatePinsMatch && isAllowedStatus(status)
    }

    private static func staticCode(at bundleURL: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(rawValue: 0),
            &code
        )
        guard status == errSecSuccess, let code else {
            throw ReleaseCodeSignatureValidatorError.staticCodeUnavailable
        }
        return code
    }

    private static func releaseRequirement() throws -> SecRequirement {
        let text = "identifier \"ai.pivotstudio.murmur-youtube\" and certificate root = H\"\(murmurReleaseCertificateRootSHA1)\""
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            text as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw ReleaseCodeSignatureValidatorError.pinnedRequirementUnavailable
        }
        return requirement
    }

    private static func designatedRequirement(for code: SecStaticCode) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(
            code,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw ReleaseCodeSignatureValidatorError.installedRequirementUnavailable
        }
        return requirement
    }

    private static func rootCertificateSHA1(for code: SecStaticCode) throws -> String {
        var signingInformation: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard status == errSecSuccess,
              let information = signingInformation as? [CFString: Any],
              let certificates = information[kSecCodeInfoCertificates] as? [SecCertificate],
              let rootCertificate = certificates.last else {
            throw ReleaseCodeSignatureValidatorError.certificateChainUnavailable
        }
        let rootDER = SecCertificateCopyData(rootCertificate) as Data
        return Insecure.SHA1.hash(data: rootDER)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isAllowedStatus(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecNotTrusted
    }

    private static let validationFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
            | kSecCSRestrictToAppLike
    )
}
