import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

private func declaration(_ allowed: String, channel: String = "SYSTEM") throws -> LosslessJSON {
    try LosslessJSON(string: #"{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Allowed":\#(allowed)},"channelType":"\#(channel)"}"#)
}

@Suite("Empty app and binary lists")
struct EmptyListTests {
    @Test("An empty AllowedBinaries opens as macOS, is pointed out and counts as an allow list without the baseline")
    func emptyAllowedBinaries() throws {
        let decoded = DeclarationDecoder.decode(declarations: [try declaration(#"{"AllowedBinaries":[]}"#)])
        let ruleSet = decoded.ruleSet
        #expect(ruleSet.platform == .macOS)
        #expect(ruleSet.hasEmptyList("AllowedBinaries"))
        #expect(ruleSet.isMissingAllowListBaseline)
        #expect(decoded.notes.contains { $0.contains("AllowedBinaries is an empty list") })
        #expect(RuleValidator.validate(ruleSet).contains { $0.message.contains("AllowedBinaries is an allow list") })
        // Written back as it was.
        let written = DeclarationEncoder.declarations(for: ruleSet)
        #expect(written[0]["payload"]?["Allowed"]?["AllowedBinaries"]?.arrayValue?.isEmpty == true)
    }

    @Test("Removing the empty list stops writing it; adding a rule replaces it, never a key twice")
    func removeOrReplace() throws {
        let ruleSet = DeclarationDecoder.decode(declarations: [try declaration(#"{"AllowedBinaries":[],"DeniedBinaries":[{"TeamID":"ABCDE12345"}]}"#)]).ruleSet

        var removed = ruleSet
        removed.removeEmptyList("AllowedBinaries")
        #expect(!removed.hasEmptyList("AllowedBinaries"))
        #expect(!removed.isMissingAllowListBaseline)
        #expect(DeclarationEncoder.declarations(for: removed)[0]["payload"]?["Allowed"]?["AllowedBinaries"] == nil)

        var added = ruleSet
        added.allowedBinaries = [BinaryRule(teamID: "ABCDE12345")]
        #expect(!added.hasEmptyList("AllowedBinaries"))
        let allowed = try #require(DeclarationEncoder.declarations(for: added)[0]["payload"]?["Allowed"]?.objectValue)
        #expect(allowed.members.filter { $0.key == "AllowedBinaries" }.count == 1)
        #expect(allowed["AllowedBinaries"]?.arrayValue?.count == 1)
    }

    @Test("Mixed keys: an empty AllowedBinaries still makes it macOS, and deploying asks the extra confirmation")
    func mixedKeysWithEmptyBinaries() throws {
        let decoded = DeclarationDecoder.decode(declarations: [try declaration(#"{"AllowedApps":["com.example.app"],"AllowedBinaries":[]}"#)])
        #expect(decoded.ruleSet.platform == .macOS)
        #expect(decoded.ruleSet.isMissingAllowListBaseline)
    }

    @Test("Combined declarations with AllowedBinaries entries and an empty AllowedBinaries: pointed out, and deploying warns")
    func entriesAndEmptyAllowList() throws {
        let declarations = [try declaration(#"{"AllowedBinaries":[{"TeamID":"*APPLE*","SigningState":"Apple"}],"AlwaysAllowManagedApps":true}"#),
                            try declaration(#"{"AllowedBinaries":[]}"#)]
        let decoded = DeclarationDecoder.decode(declarations: declarations)
        #expect(decoded.droppedEmptyLists == ["AllowedBinaries"])
        #expect(decoded.notes.contains { $0.contains("together they allowed nothing") })
        #expect(!decoded.ruleSet.keepsEmptyArray("AllowedBinaries"))
        #expect(!decoded.ruleSet.isMissingAllowListBaseline, "the editor's rule set has the baseline")
    }

    @Test("An empty AllowedApps opens as iOS in allow mode and is pointed out")
    func emptyAllowedApps() throws {
        let decoded = DeclarationDecoder.decode(declarations: [try declaration(#"{"AllowedApps":[]}"#)])
        #expect(decoded.ruleSet.platform == .iOS)
        #expect(decoded.ruleSet.appListMode == .allow)
        #expect(decoded.ruleSet.hasEmptyList("AllowedApps"))
        #expect(decoded.notes.contains { $0.contains("AllowedApps is an empty list") })
    }

    @Test("A list with entries isn't an empty list")
    func listWithEntries() throws {
        let ruleSet = DeclarationDecoder.decode(declarations: [try declaration(#"{"DeniedApps":["com.example.app"]}"#)]).ruleSet
        #expect(!ruleSet.hasEmptyList("DeniedApps"))
        #expect(RuleSet.listKeys.allSatisfy { !ruleSet.hasEmptyList($0) })
    }
}

@Suite("Combined declarations")
struct CombinedDeclarationTests {
    @Test("Two SYSTEM declarations with the same unknown key keep the first value, once, and say so")
    func duplicateUnknownKey() throws {
        let first = try LosslessJSON(string: #"{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Foo":1,"Allowed":{"DeniedApps":["com.example.a"],"Bar":true}},"channelType":"SYSTEM"}"#)
        let second = try LosslessJSON(string: #"{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Foo":2,"Allowed":{"DeniedApps":["com.example.b"],"Bar":false}},"channelType":"SYSTEM"}"#)
        let decoded = DeclarationDecoder.decode(declarations: [first, second])
        #expect(decoded.ruleSet.deniedApps.map(\.bundleID) == ["com.example.a", "com.example.b"])
        #expect(decoded.notes.contains { $0.contains("“Bar”, “Foo”") && $0.contains("first value is kept") })

        let written = DeclarationEncoder.declarations(for: decoded.ruleSet)
        #expect(written.count == 1)
        let payload = try #require(written[0]["payload"]?.objectValue)
        #expect(payload.keys.filter { $0 == "Foo" }.count == 1)
        #expect(payload["Foo"]?.serializedString() == "1")
        let allowed = try #require(payload["Allowed"]?.objectValue)
        #expect(allowed.keys.filter { $0 == "Bar" }.count == 1)
        #expect(allowed["Bar"]?.boolValue == true)
    }
}
