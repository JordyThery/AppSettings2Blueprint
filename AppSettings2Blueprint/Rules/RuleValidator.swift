import Foundation

/// One problem found in a rule set. Errors block saving and writing to Jamf;
/// warnings are shown but do not block.
nonisolated struct ValidationIssue: Identifiable, Hashable, Sendable {
    enum Severity: Hashable, Sendable { case error, warning }
    enum Area: Hashable, Sendable { case apps, binaries, privacy }

    let severity: Severity
    let area: Area
    /// The rule or entry the issue belongs to, if any.
    let itemID: UUID?
    let message: String

    var id: String { "\(area)-\(itemID?.uuidString ?? "-")-\(message)" }
}

/// Checks a rule set against the App Settings declaration schema
/// (apple/device-management app.settings.yaml and the Jamf Blueprints spec).
nonisolated enum RuleValidator {
    static let cdHashLength = 40

    static func validate(_ ruleSet: RuleSet) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        issues += appIssues(ruleSet)
        issues += binaryIssues(ruleSet)
        issues += privacyIssues(ruleSet)
        return issues
    }

    static func hasErrors(_ ruleSet: RuleSet) -> Bool {
        validate(ruleSet).contains { $0.severity == .error }
    }

    // MARK: iOS / iPadOS apps

    private static func appIssues(_ ruleSet: RuleSet) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let lists = [("AllowedApps", ruleSet.allowedApps), ("DeniedApps", ruleSet.deniedApps)]
        if ruleSet.platform == .macOS {
            for (key, list) in lists where !list.isEmpty {
                issues.append(.init(severity: .error, area: .apps, itemID: nil,
                                    message: "\(key) is not supported on macOS. Remove these \(list.count) entries or switch the rule set to iOS / iPadOS."))
            }
            return issues
        }
        if !ruleSet.allowedApps.isEmpty && !ruleSet.deniedApps.isEmpty {
            issues.append(.init(severity: .warning, area: .apps, itemID: nil,
                                message: "Both AllowedApps and DeniedApps are set. With an allow list, only listed apps can be shown or launched, so a deny list on top only matters for apps that are also allowed. Both lists are kept and written."))
        }
        for (key, list) in lists {
            var seen = Set<String>()
            for app in list {
                let bundleID = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                if bundleID.isEmpty {
                    issues.append(.init(severity: .error, area: .apps, itemID: app.id, message: "\(key) has an empty bundle ID."))
                } else if bundleID.contains(where: \.isWhitespace) {
                    issues.append(.init(severity: .error, area: .apps, itemID: app.id, message: "“\(bundleID)” contains spaces; bundle IDs never do."))
                } else if !seen.insert(bundleID.lowercased()).inserted {
                    issues.append(.init(severity: .warning, area: .apps, itemID: app.id, message: "“\(bundleID)” is listed twice in \(key)."))
                }
            }
        }
        return issues
    }

    // MARK: macOS binaries

    private static func binaryIssues(_ ruleSet: RuleSet) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let lists = [("AllowedBinaries", ruleSet.allowedBinaries), ("DeniedBinaries", ruleSet.deniedBinaries)]
        if ruleSet.platform == .iOS {
            for (key, list) in lists where !list.isEmpty {
                issues.append(.init(severity: .error, area: .binaries, itemID: nil,
                                    message: "\(key) is macOS only. Remove these \(list.count) rules or switch the rule set to macOS."))
            }
            if ruleSet.alwaysAllowManagedApps != nil {
                issues.append(.init(severity: .error, area: .binaries, itemID: nil, message: "AlwaysAllowManagedApps is macOS only."))
            }
            return issues
        }
        for (key, list) in lists {
            var seen = Set<[String]>()
            for rule in list {
                issues += binaryRuleIssues(rule, inAllowList: key == "AllowedBinaries")
                if !seen.insert(rule.matchKey).inserted {
                    issues.append(.init(severity: .warning, area: .binaries, itemID: rule.id, message: "This rule is listed twice in \(key)."))
                }
            }
        }
        if ruleSet.alwaysAllowManagedApps == true && ruleSet.allowedBinaries.isEmpty {
            issues.append(.init(severity: .warning, area: .binaries, itemID: nil,
                                message: "AlwaysAllowManagedApps only applies when AllowedBinaries is present."))
        }
        if ruleSet.isMissingAllowListBaseline {
            issues.append(.init(severity: .warning, area: .binaries, itemID: nil,
                                message: "AllowedBinaries is an allow list: anything not listed is blocked. Without AlwaysAllowManagedApps and an Apple-signed baseline ({\"TeamID\":\"*APPLE*\",\"SigningState\":\"Apple\"}), Apple apps and managed apps can be blocked too."))
        }
        return issues
    }

    /// Minimum fields from the schema: AllowedBinaries needs CDHash or TeamID;
    /// DeniedBinaries needs CDHash, TeamID or SigningID.
    static func binaryRuleIssues(_ rule: BinaryRule, inAllowList: Bool) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func error(_ message: String) {
            issues.append(.init(severity: .error, area: .binaries, itemID: rule.id, message: message))
        }
        if inAllowList {
            if !rule.hasCDHash && !rule.hasTeamID { error("An AllowedBinaries entry needs a CDHash or a TeamID.") }
        } else if !rule.hasCDHash && !rule.hasTeamID && !rule.hasSigningID {
            error("A DeniedBinaries entry needs a CDHash, a TeamID or a SigningID.")
        }
        let cdHash = rule.cdHash.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cdHash.isEmpty {
            if cdHash.count != cdHashLength {
                error("CDHash must be exactly \(cdHashLength) characters (this one has \(cdHash.count)).")
            } else if !cdHash.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) {
                // isHexDigit would also accept uppercase and fullwidth digits,
                // which never match the lowercase hash the device computes.
                error("CDHash must be lowercase hexadecimal (0–9, a–f).")
            }
        }
        let state = rule.signingState.trimmingCharacters(in: .whitespacesAndNewlines)
        if !state.isEmpty && SigningStateValue(rawValue: state) == nil {
            error("SigningState “\(state)” is not valid. Use one of: \(SigningStateValue.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        if rule.teamID.trimmingCharacters(in: .whitespacesAndNewlines) == CodeSignatureInspector.appleTeamPlaceholder,
           !state.isEmpty, state != SigningStateValue.apple.rawValue, state != SigningStateValue.all.rawValue {
            issues.append(.init(severity: .warning, area: .binaries, itemID: rule.id,
                                message: "TeamID *APPLE* only matches Apple-signed binaries, so SigningState \(state) will not match anything."))
        }
        return issues
    }

    // MARK: Privacy

    private static func privacyIssues(_ ruleSet: RuleSet) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var seen = Set<String>()
        for entry in ruleSet.permissionDefaults {
            func add(_ severity: ValidationIssue.Severity, _ message: String) {
                issues.append(.init(severity: severity, area: .privacy, itemID: entry.id, message: message))
            }
            let key = entry.appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                add(.error, ruleSet.platform == .macOS
                    ? "An app identifier is required: the composed “Bundle-ID {Designated-Requirement}” identifier."
                    : "An app identifier is required: the app's bundle ID.")
            } else {
                if !seen.insert(key).inserted { add(.error, "“\(key)” has more than one entry; PermissionDefaults keys must be unique.") }
                let isComposed = key.contains(" {") && key.hasSuffix("}")
                if ruleSet.platform == .macOS && !isComposed {
                    add(.warning, "On macOS the key must be the composed identifier “Bundle-ID {Designated-Requirement}”. Inspect the app under Local Mac Apps to get it.")
                } else if ruleSet.platform == .iOS && isComposed {
                    add(.warning, "On iOS the key is the plain bundle ID, not a composed identifier.")
                }
            }
            if entry.organizationJustification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(.error, "OrganizationJustification is required. It is shown to the user in the consent prompt.")
            }
            for permission in PermissionKey.allCases {
                guard let value = entry.value(permission) else { continue }
                if !permission.isSupported(on: ruleSet.platform) {
                    add(.error, "\(permission.rawValue) is not supported on \(ruleSet.platform.displayName).")
                } else if !permission.allowedValues.contains(value) {
                    add(.error, "\(permission.rawValue) “\(value)” is not valid. Use one of: \(permission.allowedValues.joined(separator: ", ")).")
                }
            }
        }
        return issues
    }
}
