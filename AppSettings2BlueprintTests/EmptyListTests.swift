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
