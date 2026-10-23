import Foundation
import Security

/// The signing state established for one slice. `unknown` is diagnostic only and
/// never written to a declaration.
nonisolated enum DetectedSigningState: String, Hashable, Sendable, CaseIterable {
    case apple = "Apple"
    case developerID = "DeveloperID"
    case appStore = "AppStore"
    case unknown = "Unknown"

    /// The `SigningState` value for a BinaryIdentifier, or nil for `unknown`.
    var declarationValue: String? { self == .unknown ? nil : rawValue }
}

/// Whether the whole signature passed strict validation of every architecture.
nonisolated enum SignatureVerification: Hashable, Sendable {
    case valid
    case unverified(String)

    /// Anthony's CSV values: `Valid` or `Unverified`.
    var csvValue: String {
        if case .valid = self { return "Valid" }
        return "Unverified"
    }
}

/// Signing information for one architecture slice.
nonisolated struct SliceSignature: Hashable, Sendable, Identifiable {
    /// `lipo` name, or `Unknown` when no slice could be read.
    let architecture: String
    let isAppleSilicon: Bool
    /// Lowercase hex, 40 characters.
    let cdHash: String?
    /// As signed, or `*APPLE*` for Apple-anchored code without a team identifier.
    let teamID: String?
    let signingID: String?
    let designatedRequirement: String?
    let signingState: DetectedSigningState

    var id: String { architecture }
}

/// Everything shown for one inspected .app bundle or bare executable.
nonisolated struct InspectedBinary: Hashable, Sendable, Identifiable {
    let name: String
    /// The .app bundle, or the executable itself for a bare Mach-O.
    let path: String
    let isBundle: Bool
    let executablePath: String?
    let bundleID: String?
    let version: String?
    let verification: SignatureVerification
    /// In file order.
    let slices: [SliceSignature]

    var id: String { path }

    /// Slices for the default view: Apple silicon slices when there are any, otherwise all.
    var defaultSlices: [SliceSignature] {
        let arm = slices.filter(\.isAppleSilicon)
        return arm.isEmpty ? slices : arm
    }

    var hasAppleSiliconSlice: Bool { slices.contains(where: \.isAppleSilicon) }

    /// The designated requirement of the preferred slice (arm64e, then arm64, then the first).
    var designatedRequirement: String? {
        (slices.first { $0.architecture == "arm64e" } ?? slices.first { $0.architecture == "arm64" } ?? slices.first)?
            .designatedRequirement
    }

    /// `Bundle-ID {Designated-Requirement}`: the macOS PermissionDefaults key.
    var composedIdentifier: String? {
        CodeSignatureInspector.composedIdentifier(bundleID: bundleID, designatedRequirement: designatedRequirement)
    }

    /// Suggested PathPrefix: the bundle path with a trailing slash, or the binary's path.
    var suggestedPathPrefix: String {
        isBundle ? (path.hasSuffix("/") ? path : path + "/") : path
    }
}

/// Reads code signatures with the Security framework. Never launches the
/// inspected code and never runs `codesign`.
nonisolated enum CodeSignatureInspector {
    struct InspectionError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Anthony's requirement strings, checked in this order.
    static let appleRequirement = "anchor apple"
    static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    static let appStoreRequirement = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
    static let appleTeamPlaceholder = "*APPLE*"

    // Ported from cantscript/AppSettingsUtility (MIT) — inspect_local_app in appSettingsUtility.sh
    /// Inspects an .app bundle or a bare Mach-O executable.
    static func inspect(_ url: URL) throws -> InspectedBinary {
        let url = url.standardizedFileURL
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw InspectionError(message: "\(path) does not exist.")
        }
        let isBundle = isDirectory.boolValue
        let name = isBundle ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent

        let wholeCode = try staticCode(for: url, slice: nil)
        let baseInfo = signingInformation(wholeCode)

        let plist = (baseInfo?[kSecCodeInfoPList as String] as? [String: Any])
            ?? (isBundle ? Bundle(url: url)?.infoDictionary : nil)
        var executableURL = baseInfo?[kSecCodeInfoMainExecutable as String] as? URL
        if executableURL == nil, isBundle {
            executableURL = Bundle(url: url)?.executableURL
        } else if executableURL == nil {
            executableURL = url
        }
        let bundleID = nonEmpty(plist?["CFBundleIdentifier"] as? String)
        let version = nonEmpty(plist?["CFBundleShortVersionString"] as? String)

        let verification = verify(wholeCode)
        let machOSlices = executableURL.map(MachOSlices.slices(at:)) ?? []

        var slices: [SliceSignature] = []
        if machOSlices.isEmpty {
            // No readable slice: report what the default code object says, without a state.
            slices.append(sliceSignature(code: wholeCode, architecture: "Unknown", isAppleSilicon: false, establishState: false))
        } else {
            // One unreadable slice should not hide the readable ones.
            var sliceErrors: [Error] = []
            for slice in machOSlices {
                do {
                    let code = try staticCode(for: url, slice: slice)
                    slices.append(sliceSignature(
                        code: code,
                        architecture: slice.architecture,
                        isAppleSilicon: slice.isAppleSilicon,
                        establishState: verification == .valid
                    ))
                } catch {
                    sliceErrors.append(error)
                }
            }
            if slices.isEmpty, let first = sliceErrors.first { throw first }
        }

        return InspectedBinary(
            name: name,
            path: path,
            isBundle: isBundle,
            executablePath: executableURL?.standardizedFileURL.path(percentEncoded: false),
            bundleID: bundleID,
            version: version,
            verification: verification,
            slices: slices
        )
    }

    /// `"<bundle id> {<designated requirement>}"`, or nil when either part is missing.
    static func composedIdentifier(bundleID: String?, designatedRequirement: String?) -> String? {
        guard let bundleID = nonEmpty(bundleID), let requirement = nonEmpty(designatedRequirement) else { return nil }
        return "\(bundleID) {\(requirement)}"
    }

    // MARK: Security framework

    private static func staticCode(for url: URL, slice: MachOSlice?) throws -> SecStaticCode {
        var attributes: [String: Any] = [:]
        if let slice {
            attributes[kSecCodeAttributeArchitecture as String] = NSNumber(value: slice.cpuType)
            attributes[kSecCodeAttributeSubarchitecture as String] = NSNumber(value: slice.cpuSubtype)
        }
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes as CFDictionary, &code)
        guard status == errSecSuccess, let code else {
            throw InspectionError(message: "Could not read the code signature of \(url.path(percentEncoded: false)) (\(describe(status))).")
        }
        return code
    }

    private static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }

    /// The equivalent of `codesign --verify --strict --all-architectures`.
    private static func verify(_ code: SecStaticCode) -> SignatureVerification {
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        return status == errSecSuccess ? .valid : .unverified(describe(status))
    }

    private static func sliceSignature(
        code: SecStaticCode,
        architecture: String,
        isAppleSilicon: Bool,
        establishState: Bool
    ) -> SliceSignature {
        let info = signingInformation(code)
        let cdHash = (info?[kSecCodeInfoUnique as String] as? Data).map(hex)
        var teamID = nonEmpty(info?[kSecCodeInfoTeamIdentifier as String] as? String)
        let signingID = nonEmpty(info?[kSecCodeInfoIdentifier as String] as? String)
        var requirementText: String?
        if let value = info?[kSecCodeInfoDesignatedRequirement as String] as CFTypeRef?,
           CFGetTypeID(value) == SecRequirementGetTypeID() {
            let requirement = unsafeDowncast(value, to: SecRequirement.self)
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
                requirementText = nonEmpty(text as String?)
            }
        }

        // Ported from cantscript/AppSettingsUtility (MIT) — inspect_local_app in appSettingsUtility.sh
        // A missing team identifier alone never implies Apple: only the `anchor apple`
        // requirement does, and only for a signature that passed strict validation.
        var state = DetectedSigningState.unknown
        if establishState {
            if satisfies(code, appleRequirement) {
                state = .apple
                if teamID == nil { teamID = appleTeamPlaceholder }
            } else if satisfies(code, developerIDRequirement) {
                state = .developerID
            } else if satisfies(code, appStoreRequirement) {
                state = .appStore
            }
        }

        return SliceSignature(
            architecture: architecture,
            isAppleSilicon: isAppleSilicon,
            cdHash: cdHash,
            teamID: teamID,
            signingID: signingID,
            designatedRequirement: requirementText,
            signingState: state
        )
    }

    private static func satisfies(_ code: SecStaticCode, _ requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error"
        return "\(message), OSStatus \(status)"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
