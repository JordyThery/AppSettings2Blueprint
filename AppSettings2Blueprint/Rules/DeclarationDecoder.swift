import Foundation

/// Reads App Settings declarations back into a rule set. Keys it does not
/// understand, and values of an unexpected type, are kept in `preserved` /
/// `extras` and written back unchanged by `DeclarationEncoder`.
nonisolated enum DeclarationDecoder {
    struct Result: Sendable {
        var ruleSet: RuleSet
        /// Things the editor should point out, e.g. both app lists set.
        var notes: [String]
    }

    private static let declarationKeys: Set<String> = ["type", "kind", "channelType", "payload"]

    /// Decodes every `com.apple.configuration.app.settings` declaration in `declarations`.
    /// The platform is inferred from the keys unless `platform` is given.
    static func decode(declarations: [JSONValue], name: String = "Untitled Rule Set", platform: RulePlatform? = nil) -> Result {
        var ruleSet = RuleSet(name: name)
        var notes: [String] = []
        var seenChannels = Set<String>()
        var hasIOSKeys = false
        var hasMacKeys = false
        var privacyChannels = Set<String>()
        var binaryChannels = Set<String>()

        for declaration in declarations where declaration["type"]?.stringValue == DeclarationEncoder.declarationType {
            let channel = declaration["channelType"]?.stringValue ?? DeclarationEncoder.systemChannel
            if !seenChannels.insert(channel).inserted {
                notes.append("More than one \(channel) App Settings declaration was found; their contents were combined.")
            }
            var parts = ruleSet.preserved[channel] ?? PreservedDeclarationParts()
            if let object = declaration.objectValue {
                parts.declaration.object.members += object.members.filter { !declarationKeys.contains($0.key) }
            }
            let payload = declaration["payload"]?.objectValue ?? JSONObject()
            for member in payload.members {
                switch (member.key, member.value) {
                case ("Allowed", .object(let allowed)):
                    let before = ruleSet.allowedBinaries.count + ruleSet.deniedBinaries.count
                    decodeAllowed(allowed, into: &ruleSet, parts: &parts, hasIOSKeys: &hasIOSKeys, hasMacKeys: &hasMacKeys)
                    if ruleSet.allowedBinaries.count + ruleSet.deniedBinaries.count > before { binaryChannels.insert(channel) }
                case ("Privacy", .object(let privacy)):
                    let before = ruleSet.permissionDefaults.count
                    decodePrivacy(privacy, into: &ruleSet, parts: &parts, hasMacKeys: &hasMacKeys)
                    if ruleSet.permissionDefaults.count > before { privacyChannels.insert(channel) }
                default:
                    parts.payload.object.members.append(member)
                }
            }
            if channel == DeclarationEncoder.userChannel { hasMacKeys = true }
            ruleSet.preserved[channel] = parts.isEmpty ? nil : parts
        }

        if let platform {
            ruleSet.platform = platform
        } else if hasIOSKeys && hasMacKeys {
            ruleSet.platform = (ruleSet.allowedBinaries.isEmpty && ruleSet.deniedBinaries.isEmpty) ? .iOS : .macOS
            notes.append("The declaration mixes iOS-only and macOS-only keys. It is opened as \(ruleSet.platform.displayName); fix the keys the editor marks before saving.")
        } else {
            ruleSet.platform = hasMacKeys ? .macOS : .iOS
        }

        let expectedPrivacyChannel = ruleSet.platform == .macOS ? DeclarationEncoder.userChannel : DeclarationEncoder.systemChannel
        if privacyChannels.contains(where: { $0 != expectedPrivacyChannel }) {
            notes.append("Permission defaults were found on a channel other than \(expectedPrivacyChannel). They will be written to the \(expectedPrivacyChannel) declaration.")
        }
        if binaryChannels.contains(where: { $0 != DeclarationEncoder.systemChannel }) {
            notes.append("Binary rules were found outside the SYSTEM channel. They will be written to the SYSTEM declaration.")
        }
        if !ruleSet.allowedApps.isEmpty && !ruleSet.deniedApps.isEmpty {
            notes.append("Both AllowedApps and DeniedApps are set. Both are kept.")
        }
        ruleSet.appListMode = ruleSet.deniedApps.isEmpty && !ruleSet.allowedApps.isEmpty ? .allow : .deny
        return Result(ruleSet: ruleSet, notes: notes)
    }

    // MARK: Allowed

    private static func decodeAllowed(
        _ allowed: JSONObject,
        into ruleSet: inout RuleSet,
        parts: inout PreservedDeclarationParts,
        hasIOSKeys: inout Bool,
        hasMacKeys: inout Bool
    ) {
        for member in allowed.members {
            switch member.key {
            case "AllowedApps", "DeniedApps":
                // Only a non-empty array of strings is interpreted; anything else
                // (including an empty array, which means something different from
                // "not set") is kept verbatim.
                guard let items = member.value.arrayValue, !items.isEmpty,
                      items.allSatisfy({ $0.stringValue != nil }) else {
                    parts.allowed.object.members.append(member)
                    continue
                }
                hasIOSKeys = true
                let apps = items.compactMap(\.stringValue).map { AppRule(bundleID: $0) }
                if member.key == "AllowedApps" { ruleSet.allowedApps += apps } else { ruleSet.deniedApps += apps }
            case "AllowedBinaries", "DeniedBinaries":
                guard let items = member.value.arrayValue, !items.isEmpty,
                      items.allSatisfy({ $0.objectValue != nil }) else {
                    parts.allowed.object.members.append(member)
                    continue
                }
                hasMacKeys = true
                let rules = items.compactMap(\.objectValue).map(binaryRule)
                if member.key == "AllowedBinaries" { ruleSet.allowedBinaries += rules } else { ruleSet.deniedBinaries += rules }
            case "AlwaysAllowManagedApps":
                guard let value = member.value.boolValue else {
                    parts.allowed.object.members.append(member)
                    continue
                }
                hasMacKeys = true
                ruleSet.alwaysAllowManagedApps = value
            default:
                parts.allowed.object.members.append(member)
            }
        }
    }

    static func binaryRule(_ object: JSONObject) -> BinaryRule {
        var rule = BinaryRule()
        for member in object.members {
            guard let text = member.value.stringValue else {
                rule.extras.object.members.append(member)
                continue
            }
            switch member.key {
            case "CDHash": rule.cdHash = text
            case "SigningID": rule.signingID = text
            case "TeamID": rule.teamID = text
            case "PathPrefix": rule.pathPrefix = text
            case "SigningState": rule.signingState = text
            default: rule.extras.object.members.append(member)
            }
        }
        return rule
    }

    // MARK: Privacy

    private static func decodePrivacy(
        _ privacy: JSONObject,
        into ruleSet: inout RuleSet,
        parts: inout PreservedDeclarationParts,
        hasMacKeys: inout Bool
    ) {
        for member in privacy.members {
            guard member.key == "PermissionDefaults", case .object(let defaults) = member.value,
                  defaults.members.allSatisfy({ $0.value.objectValue != nil }) else {
                parts.privacy.object.members.append(member)
                continue
            }
            for entry in defaults.members {
                guard let object = entry.value.objectValue else { continue }
                // A composed identifier ("bundle {requirement}") is the macOS form.
                if entry.key.contains(" {") { hasMacKeys = true }
                ruleSet.permissionDefaults.append(permissionDefault(key: entry.key, object: object))
            }
        }
    }

    static func permissionDefault(key: String, object: JSONObject) -> PermissionDefault {
        var entry = PermissionDefault(appIdentifier: key)
        let permissionKeys = Set(PermissionKey.allCases.map(\.rawValue))
        for member in object.members {
            if member.key == "OrganizationJustification", let text = member.value.stringValue {
                entry.organizationJustification = text
            } else if permissionKeys.contains(member.key), let text = member.value.stringValue {
                entry.values[member.key] = text
            } else {
                entry.extras.object.members.append(member)
            }
        }
        return entry
    }
}
