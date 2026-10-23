import Foundation

/// Builds the exact JSON written to Jamf from a rule set.
///
/// - iOS / iPadOS: one SYSTEM declaration with Allowed and Privacy.
/// - macOS: a SYSTEM declaration for Allowed (binaries) and a USER declaration for
///   Privacy, because Apple's schema allows binaries only on the system channel
///   and privacy defaults only on the user channel.
///
/// Keys a platform does not support are never written, whatever the model holds.
/// Declaration members follow the server's order: kind, type, payload, channelType.
nonisolated enum DeclarationEncoder {
    static let componentIdentifier = AppSettingsLocator.componentIdentifier
    static let declarationType = AppSettingsLocator.declarationType
    static let systemChannel = "SYSTEM"
    static let userChannel = "USER"

    /// The complete `com.jamf.ddm-strict` component.
    static func component(for ruleSet: RuleSet) -> JSONValue {
        .object(JSONObject([
            "identifier": .string(componentIdentifier),
            "configuration": .object(JSONObject(["declarations": .array(declarations(for: ruleSet))])),
        ]))
    }

    /// One or two declarations, SYSTEM first.
    static func declarations(for ruleSet: RuleSet) -> [JSONValue] {
        channels(for: ruleSet).map { declaration(for: ruleSet, channel: $0) }
    }

    static func channels(for ruleSet: RuleSet) -> [String] {
        guard ruleSet.platform == .macOS else { return [systemChannel] }
        let system = allowed(for: ruleSet, channel: systemChannel) != nil
            || !(ruleSet.preserved[systemChannel]?.isEmpty ?? true)
        let user = !ruleSet.permissionDefaults.isEmpty || !(ruleSet.preserved[userChannel]?.isEmpty ?? true)
        if system && user { return [systemChannel, userChannel] }
        return user ? [userChannel] : [systemChannel]
    }

    static func declaration(for ruleSet: RuleSet, channel: String) -> JSONValue {
        var object = JSONObject([
            "kind": .string("CONFIGURATION"),
            "type": .string(declarationType),
            "payload": .object(payload(for: ruleSet, channel: channel)),
            "channelType": .string(channel),
        ])
        appendExtras(ruleSet.preserved[channel]?.declaration, to: &object)
        return .object(object)
    }

    static func payload(for ruleSet: RuleSet, channel: String) -> JSONObject {
        var payload = JSONObject()
        if let allowed = allowed(for: ruleSet, channel: channel) {
            payload["Allowed"] = .object(allowed)
        }
        if let privacy = privacy(for: ruleSet, channel: channel) {
            payload["Privacy"] = .object(privacy)
        }
        appendExtras(ruleSet.preserved[channel]?.payload, to: &payload)
        return payload
    }

    // MARK: Allowed

    private static func allowed(for ruleSet: RuleSet, channel: String) -> JSONObject? {
        var allowed = JSONObject()
        switch ruleSet.platform {
        case .iOS:
            guard channel == systemChannel else { break }
            let allowedApps = ruleSet.allowedApps.map(\.bundleID).map(trim).filter { !$0.isEmpty }
            let deniedApps = ruleSet.deniedApps.map(\.bundleID).map(trim).filter { !$0.isEmpty }
            if !allowedApps.isEmpty { allowed["AllowedApps"] = .array(allowedApps.map(JSONValue.string)) }
            if !deniedApps.isEmpty { allowed["DeniedApps"] = .array(deniedApps.map(JSONValue.string)) }
        case .macOS:
            guard channel == systemChannel else { break }
            if !ruleSet.allowedBinaries.isEmpty {
                allowed["AllowedBinaries"] = .array(ruleSet.allowedBinaries.map(binaryIdentifier))
            }
            if !ruleSet.deniedBinaries.isEmpty {
                allowed["DeniedBinaries"] = .array(ruleSet.deniedBinaries.map(binaryIdentifier))
            }
            if let always = ruleSet.alwaysAllowManagedApps {
                allowed["AlwaysAllowManagedApps"] = .bool(always)
            }
        }
        appendExtras(ruleSet.preserved[channel]?.allowed, to: &allowed)
        return allowed.isEmpty ? nil : allowed
    }

    /// Only non-empty fields are written, in the schema's order.
    static func binaryIdentifier(_ rule: BinaryRule) -> JSONValue {
        var object = JSONObject()
        for (key, value) in [
            ("CDHash", rule.cdHash), ("SigningID", rule.signingID), ("TeamID", rule.teamID),
            ("PathPrefix", rule.pathPrefix), ("SigningState", rule.signingState),
        ] where !trim(value).isEmpty {
            object[key] = .string(trim(value))
        }
        appendExtras(rule.extras, to: &object)
        return .object(object)
    }

    // MARK: Privacy

    private static func privacy(for ruleSet: RuleSet, channel: String) -> JSONObject? {
        let privacyChannel = ruleSet.platform == .macOS ? userChannel : systemChannel
        var privacy = JSONObject()
        if channel == privacyChannel, !ruleSet.permissionDefaults.isEmpty {
            var defaults = JSONObject()
            for entry in ruleSet.permissionDefaults {
                defaults.members.append(.init(
                    key: trim(entry.appIdentifier),
                    value: .object(permissionEntry(entry, platform: ruleSet.platform))
                ))
            }
            privacy["PermissionDefaults"] = .object(defaults)
        }
        appendExtras(ruleSet.preserved[channel]?.privacy, to: &privacy)
        return privacy.isEmpty ? nil : privacy
    }

    static func permissionEntry(_ entry: PermissionDefault, platform: RulePlatform) -> JSONObject {
        var object = JSONObject(["OrganizationJustification": .string(entry.organizationJustification)])
        for key in PermissionKey.allCases where key.isSupported(on: platform) {
            if let value = entry.value(key) { object[key.rawValue] = .string(value) }
        }
        appendExtras(entry.extras, to: &object)
        return object
    }

    // MARK: Helpers

    /// Appends preserved members whose keys the encoder did not already write.
    private static func appendExtras(_ extras: PreservedJSON?, to object: inout JSONObject) {
        guard let extras else { return }
        let written = Set(object.keys)
        object.members.append(contentsOf: extras.object.members.filter { !written.contains($0.key) })
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
