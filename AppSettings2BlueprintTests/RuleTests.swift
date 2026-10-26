import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

private func errors(_ ruleSet: RuleSet) -> [String] {
    RuleValidator.validate(ruleSet).filter { $0.severity == .error }.map(\.message)
}

private func warnings(_ ruleSet: RuleSet) -> [String] {
    RuleValidator.validate(ruleSet).filter { $0.severity == .warning }.map(\.message)
}

private let validCDHash = "a09ef19476472dd66365c3d8e45151c6ab1771e5"

@Suite("RuleValidator")
struct RuleValidatorTests {
    @Test(arguments: [
        (validCDHash, true),
        (String(validCDHash.dropLast()), false),
        (validCDHash + "0", false),
        ("z" + validCDHash.dropFirst(), false),
    ])
    func cdHashMustBe40HexCharacters(cdHash: String, valid: Bool) {
        let issues = RuleValidator.binaryRuleIssues(BinaryRule(cdHash: cdHash), inAllowList: true)
        #expect(issues.isEmpty == valid)
    }

    @Test func allowedBinaryNeedsCDHashOrTeamID() {
        #expect(!RuleValidator.binaryRuleIssues(BinaryRule(signingID: "com.example"), inAllowList: true).isEmpty)
        #expect(!RuleValidator.binaryRuleIssues(BinaryRule(pathPrefix: "/Applications/"), inAllowList: true).isEmpty)
        #expect(RuleValidator.binaryRuleIssues(BinaryRule(teamID: "UBF8T346G9"), inAllowList: true).isEmpty)
        #expect(RuleValidator.binaryRuleIssues(BinaryRule(cdHash: validCDHash), inAllowList: true).isEmpty)
    }

    @Test func deniedBinaryNeedsCDHashTeamIDOrSigningID() {
        #expect(RuleValidator.binaryRuleIssues(BinaryRule(signingID: "com.example"), inAllowList: false).isEmpty)
        #expect(!RuleValidator.binaryRuleIssues(BinaryRule(pathPrefix: "/Applications/", signingState: "All"), inAllowList: false).isEmpty)
        // Whitespace-only values count as missing.
        #expect(!RuleValidator.binaryRuleIssues(BinaryRule(teamID: "  "), inAllowList: false).isEmpty)
    }

    @Test(arguments: SigningStateValue.allCases.map(\.rawValue) + ["Bogus", "apple"])
    func signingStateMustBeAnEnumValue(state: String) {
        let issues = RuleValidator.binaryRuleIssues(BinaryRule(teamID: "ABCDE12345", signingState: state), inAllowList: true)
        #expect(issues.isEmpty == (SigningStateValue(rawValue: state) != nil))
    }

    @Test func organizationJustificationIsRequired() {
        var ruleSet = RuleSet(platform: .iOS)
        ruleSet.permissionDefaults = [PermissionDefault(appIdentifier: "com.example.scanner", values: ["Camera": "Allow"])]
        #expect(errors(ruleSet).contains { $0.contains("OrganizationJustification") })
        ruleSet.permissionDefaults[0].organizationJustification = "Scanning work documents."
        #expect(errors(ruleSet).isEmpty)
    }

    @Test func permissionValuesMustBeEnumValues() {
        var ruleSet = RuleSet(platform: .iOS)
        ruleSet.permissionDefaults = [PermissionDefault(appIdentifier: "com.example", organizationJustification: "x", values: ["Location": "Sometimes"])]
        #expect(errors(ruleSet).contains { $0.contains("Location “Sometimes”") })
    }

    @Test func iOSOnlyKeysAreErrorsOnMacOSAndNeverWritten() throws {
        var ruleSet = RuleSet(platform: .macOS)
        ruleSet.deniedApps = [AppRule(bundleID: "com.apple.news")]
        ruleSet.permissionDefaults = [PermissionDefault(
            appIdentifier: "com.example {anchor apple}", organizationJustification: "x",
            values: ["LocationAccuracy": "Precise", "Camera": "Allow"]
        )]
        #expect(errors(ruleSet).contains { $0.contains("DeniedApps is not supported on macOS") })
        #expect(errors(ruleSet).contains { $0.contains("LocationAccuracy is not supported on macOS") })
        let json = LosslessJSON.array(DeclarationEncoder.declarations(for: ruleSet)).serializedString()
        #expect(!json.contains("DeniedApps"))
        #expect(!json.contains("LocationAccuracy"))
        #expect(json.contains("Camera"))
    }

    @Test func macOSOnlyKeysAreErrorsOnIOSAndNeverWritten() {
        var ruleSet = RuleSet(platform: .iOS)
        ruleSet.allowedBinaries = [BinaryRule(teamID: "ABCDE12345")]
        ruleSet.alwaysAllowManagedApps = true
        ruleSet.permissionDefaults = [PermissionDefault(appIdentifier: "com.example", organizationJustification: "x", values: ["Accessibility": "Allow"])]
        let messages = errors(ruleSet)
        #expect(messages.contains { $0.contains("AllowedBinaries is macOS only") })
        #expect(messages.contains { $0.contains("AlwaysAllowManagedApps is macOS only") })
        #expect(messages.contains { $0.contains("Accessibility is not supported on iOS") })
        let json = LosslessJSON.array(DeclarationEncoder.declarations(for: ruleSet)).serializedString()
        #expect(!json.contains("Binaries"))
        #expect(!json.contains("AlwaysAllowManagedApps"))
        #expect(!json.contains("Accessibility"))
    }

    @Test func allowListWithoutBaselineWarnsUntilBaselineAdded() {
        var ruleSet = RuleSet(platform: .macOS)
        ruleSet.allowedBinaries = [BinaryRule(teamID: "UBF8T346G9", signingID: "com.microsoft.Outlook")]
        #expect(ruleSet.isMissingAllowListBaseline)
        #expect(warnings(ruleSet).contains { $0.contains("allow list") })
        ruleSet.alwaysAllowManagedApps = true
        #expect(ruleSet.isMissingAllowListBaseline)
        ruleSet.addRecommendedBaseline()
        #expect(!ruleSet.isMissingAllowListBaseline)
        #expect(ruleSet.allowedBinaries.first?.isAppleBaseline == true)
        ruleSet.addRecommendedBaseline()
        #expect(ruleSet.allowedBinaries.filter(\.isAppleBaseline).count == 1)
        #expect(errors(ruleSet).isEmpty)
    }

    @Test func bothAppListsWarnButNothingIsDropped() {
        var ruleSet = RuleSet(platform: .iOS)
        ruleSet.allowedApps = [AppRule(bundleID: "com.apple.mobilesafari")]
        ruleSet.deniedApps = [AppRule(bundleID: "com.apple.news")]
        #expect(warnings(ruleSet).contains { $0.contains("Both AllowedApps and DeniedApps") })
        let json = LosslessJSON.array(DeclarationEncoder.declarations(for: ruleSet)).serializedString()
        #expect(json.contains(#""AllowedApps":["com.apple.mobilesafari"]"#))
        #expect(json.contains(#""DeniedApps":["com.apple.news"]"#))
    }

    @Test func duplicatePermissionKeysAreErrors() {
        var ruleSet = RuleSet(platform: .iOS)
        ruleSet.permissionDefaults = [
            PermissionDefault(appIdentifier: "com.example", organizationJustification: "a"),
            PermissionDefault(appIdentifier: "com.example", organizationJustification: "b"),
        ]
        #expect(errors(ruleSet).contains { $0.contains("more than one entry") })
    }

    @Test func addAppsSkipsDuplicates() {
        var ruleSet = RuleSet(platform: .iOS)
        #expect(ruleSet.addApps([("com.apple.news", "News"), ("com.apple.News", nil), (" ", nil), ("com.apple.stocks", nil)]) == 2)
        #expect(ruleSet.deniedApps.map(\.bundleID) == ["com.apple.news", "com.apple.stocks"])
    }
}

@Suite("DeclarationEncoder and DeclarationDecoder")
struct DeclarationCodingTests {
    private func iOSRuleSet() -> RuleSet {
        var ruleSet = RuleSet(name: "iPad apps", platform: .iOS)
        ruleSet.appListMode = .deny
        ruleSet.deniedApps = [AppRule(bundleID: "com.apple.news"), AppRule(bundleID: "com.apple.stocks")]
        ruleSet.permissionDefaults = [PermissionDefault(
            appIdentifier: "com.example.scanner", organizationJustification: "Scanning work documents.",
            values: ["Camera": "Allow", "LocationAccuracy": "Approximate", "Location": "WhileUsing"]
        )]
        return ruleSet
    }

    private func macRuleSet() -> RuleSet {
        var ruleSet = RuleSet(name: "Mac", platform: .macOS)
        ruleSet.addRecommendedBaseline()
        ruleSet.allowedBinaries.append(BinaryRule(teamID: "UBF8T346G9", signingID: "com.microsoft.Outlook"))
        ruleSet.deniedBinaries = [BinaryRule(cdHash: validCDHash, pathPrefix: "/Applications/Safari.app/", signingState: "Apple")]
        ruleSet.permissionDefaults = [PermissionDefault(
            appIdentifier: #"com.microsoft.Outlook {identifier "com.microsoft.Outlook" and anchor apple generic}"#,
            organizationJustification: "Calls and meetings.", values: ["Microphone": "Allow", "Accessibility": "None"]
        )]
        return ruleSet
    }

    @Test func iOSEncodesOneSystemDeclarationInServerOrder() {
        let json = LosslessJSON.array(DeclarationEncoder.declarations(for: iOSRuleSet())).serializedString()
        #expect(json == #"[{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Allowed":{"DeniedApps":["com.apple.news","com.apple.stocks"]},"Privacy":{"PermissionDefaults":{"com.example.scanner":{"OrganizationJustification":"Scanning work documents.","Camera":"Allow","Location":"WhileUsing","LocationAccuracy":"Approximate"}}}},"channelType":"SYSTEM"}]"#)
    }

    @Test func macOSEncodesBinariesOnSystemAndPrivacyOnUser() throws {
        let declarations = DeclarationEncoder.declarations(for: macRuleSet())
        #expect(declarations.count == 2)
        #expect(declarations[0]["channelType"]?.stringValue == "SYSTEM")
        #expect(declarations[0]["payload"]?["Privacy"] == nil)
        #expect(declarations[0]["payload"]?["Allowed"]?.serializedString() == #"{"AllowedBinaries":[{"TeamID":"*APPLE*","SigningState":"Apple"},{"SigningID":"com.microsoft.Outlook","TeamID":"UBF8T346G9"}],"DeniedBinaries":[{"CDHash":"a09ef19476472dd66365c3d8e45151c6ab1771e5","PathPrefix":"/Applications/Safari.app/","SigningState":"Apple"}],"AlwaysAllowManagedApps":true}"#)
        #expect(declarations[1]["channelType"]?.stringValue == "USER")
        #expect(declarations[1]["payload"]?["Allowed"] == nil)
        #expect(declarations[1]["payload"]?["Privacy"]?["PermissionDefaults"]?.objectValue?.keys.first?.hasSuffix("anchor apple generic}") == true)
    }

    @Test func macOSWithOnlyPrivacyHasOnlyAUserDeclaration() {
        var ruleSet = macRuleSet()
        ruleSet.allowedBinaries = []
        ruleSet.deniedBinaries = []
        ruleSet.alwaysAllowManagedApps = nil
        #expect(DeclarationEncoder.channels(for: ruleSet) == ["USER"])
    }

    /// Shared iPad writes the same iOS declaration on the USER channel.
    @Test func sharedIPadUsesTheUserChannel() {
        var ruleSet = iOSRuleSet()
        ruleSet.isSharedIPad = true
        #expect(DeclarationEncoder.channels(for: ruleSet) == ["USER"])
        let declarations = DeclarationEncoder.declarations(for: ruleSet)
        #expect(declarations.count == 1)
        #expect(declarations[0]["channelType"]?.stringValue == "USER")
        #expect(declarations[0]["payload"]?["Allowed"]?["DeniedApps"]?.arrayValue?.count == 2)
        #expect(declarations[0]["payload"]?["Privacy"]?["PermissionDefaults"] != nil)
    }

    @Test func sharedIPadDecodesAsIOSAndRoundTrips() {
        var original = iOSRuleSet()
        original.isSharedIPad = true
        let encoded = DeclarationEncoder.declarations(for: original)
        let decoded = DeclarationDecoder.decode(declarations: encoded, name: original.name)
        #expect(decoded.notes.isEmpty)
        #expect(decoded.ruleSet.platform == .iOS)
        #expect(decoded.ruleSet.isSharedIPad)
        #expect(DeclarationEncoder.declarations(for: decoded.ruleSet) == encoded)
    }

    /// Shared iPad only applies to iOS; switching to macOS ignores the flag.
    @Test func sharedIPadIsIgnoredOnMacOS() {
        var ruleSet = macRuleSet()
        ruleSet.sharedIPad = true
        #expect(!ruleSet.isSharedIPad)
        #expect(DeclarationEncoder.channels(for: ruleSet) == ["SYSTEM", "USER"])
    }

    /// Rule set files saved before 1.1 have no sharedIPad key and still open.
    @Test func ruleSetFilesWithoutSharedIPadStillDecode() throws {
        var data = try JSONEncoder().encode(iOSRuleSet())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sharedIPad")
        data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
        #expect(!decoded.isSharedIPad)
    }

    /// A preserved declaration on a channel the platform does not use is still
    /// written back; decode→encode never drops a declaration.
    @Test func preservedForeignChannelsAreWrittenBack() {
        var ruleSet = iOSRuleSet()
        ruleSet.preserved["USER"] = PreservedDeclarationParts(
            payload: PreservedJSON(LosslessJSON.Object(["CustomKey": .bool(true)]))
        )
        #expect(DeclarationEncoder.channels(for: ruleSet) == ["SYSTEM", "USER"])
        let declarations = DeclarationEncoder.declarations(for: ruleSet)
        #expect(declarations.count == 2)
        #expect(declarations[1]["channelType"]?.stringValue == "USER")
        #expect(declarations[1]["payload"]?["CustomKey"]?.boolValue == true)
    }

    @Test(arguments: [true, false])
    func encodingThenDecodingReturnsTheOriginal(mac: Bool) {
        let original = mac ? macRuleSet() : iOSRuleSet()
        let encoded = DeclarationEncoder.declarations(for: original)
        let decoded = DeclarationDecoder.decode(declarations: encoded, name: original.name)
        #expect(decoded.notes.isEmpty)
        let ruleSet = decoded.ruleSet
        #expect(ruleSet.platform == original.platform)
        #expect(ruleSet.appListMode == original.appListMode)
        #expect(ruleSet.allowedApps.map(\.bundleID) == original.allowedApps.map(\.bundleID))
        #expect(ruleSet.deniedApps.map(\.bundleID) == original.deniedApps.map(\.bundleID))
        #expect(ruleSet.allowedBinaries.map(\.matchKey) == original.allowedBinaries.map(\.matchKey))
        #expect(ruleSet.deniedBinaries.map(\.matchKey) == original.deniedBinaries.map(\.matchKey))
        #expect(ruleSet.alwaysAllowManagedApps == original.alwaysAllowManagedApps)
        #expect(ruleSet.permissionDefaults.map(\.appIdentifier) == original.permissionDefaults.map(\.appIdentifier))
        #expect(ruleSet.permissionDefaults.map(\.values) == original.permissionDefaults.map(\.values))
        #expect(ruleSet.permissionDefaults.map(\.organizationJustification) == original.permissionDefaults.map(\.organizationJustification))
        #expect(DeclarationEncoder.declarations(for: ruleSet) == encoded)
    }

    @Test func unknownKeysSurviveDecodeAndEncode() throws {
        let input = #"[{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Allowed":{"DeniedApps":["com.apple.news"],"AllowedApps":[],"FutureList":[1.0,2e3],"AllowedBinaries":"not an array"},"Privacy":{"PermissionDefaults":{"com.example":{"OrganizationJustification":"x","Camera":"Allow","Contacts":"Allow","Microphone":true}},"FuturePrivacy":{"a":null}},"FuturePayload":{"keep":"me"}},"channelType":"SYSTEM","identifier":"decl-1","serverToken":12345678901234567890}]"#
        let declarations = try #require(try LosslessJSON(string: input).arrayValue)
        let decoded = DeclarationDecoder.decode(declarations: declarations)
        #expect(decoded.ruleSet.platform == .iOS)
        #expect(decoded.ruleSet.deniedApps.map(\.bundleID) == ["com.apple.news"])
        let output = LosslessJSON.array(DeclarationEncoder.declarations(for: decoded.ruleSet)).serializedString()
        for fragment in [
            #""AllowedApps":[]"#, #""FutureList":[1.0,2e3]"#, #""AllowedBinaries":"not an array""#,
            #""Contacts":"Allow""#, #""Microphone":true"#, #""FuturePrivacy":{"a":null}"#,
            #""FuturePayload":{"keep":"me"}"#, #""identifier":"decl-1""#, #""serverToken":12345678901234567890"#,
        ] {
            #expect(output.contains(fragment), "missing \(fragment)")
        }
        // Encoding the decoded rule set again changes nothing.
        let again = DeclarationDecoder.decode(declarations: DeclarationEncoder.declarations(for: decoded.ruleSet))
        #expect(LosslessJSON.array(DeclarationEncoder.declarations(for: again.ruleSet)).serializedString() == output)
    }

    @Test func jamfUIEmptyDeclarationRoundTripsByteForByte() throws {
        // As read back from a Blueprint created in the Jamf UI (milestone 1).
        let text = #"{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{},"channelType":"SYSTEM"}"#
        let decoded = DeclarationDecoder.decode(declarations: [try LosslessJSON(string: text)])
        #expect(decoded.ruleSet.isEmpty)
        #expect(DeclarationEncoder.declarations(for: decoded.ruleSet).map { $0.serializedString() } == [text])
    }

    @Test func notesExplainMovedChannelsAndMixedKeys() throws {
        let systemPrivacy = #"[{"type":"com.apple.configuration.app.settings","channelType":"SYSTEM","payload":{"Allowed":{"AllowedBinaries":[{"TeamID":"ABCDE12345"}]},"Privacy":{"PermissionDefaults":{"com.example {anchor apple}":{"OrganizationJustification":"x"}}}}}]"#
        let decoded = DeclarationDecoder.decode(declarations: try #require(try LosslessJSON(string: systemPrivacy).arrayValue))
        #expect(decoded.ruleSet.platform == .macOS)
        #expect(decoded.notes.contains { $0.contains("written to the USER declaration") })

        let mixed = #"[{"type":"com.apple.configuration.app.settings","channelType":"SYSTEM","payload":{"Allowed":{"DeniedApps":["a"],"DeniedBinaries":[{"SigningID":"b"}]}}}]"#
        let mixedDecoded = DeclarationDecoder.decode(declarations: try #require(try LosslessJSON(string: mixed).arrayValue))
        #expect(mixedDecoded.notes.contains { $0.contains("mixes iOS-only and macOS-only keys") })
        #expect(mixedDecoded.ruleSet.deniedApps.count == 1)
        #expect(mixedDecoded.ruleSet.deniedBinaries.count == 1)
    }

    @Test func ruleSetFileRoundTripKeepsPreservedLiterals() throws {
        var ruleSet = iOSRuleSet()
        ruleSet.preserved["SYSTEM"] = PreservedDeclarationParts(payload: PreservedJSON(LosslessJSON.Object(["Ratio": .number(LosslessJSON.Number(literal: "1.0"))])))
        let data = try JSONEncoder().encode(RuleSetDocument.File(ruleSet: ruleSet))
        let decoded = try JSONDecoder().decode(RuleSetDocument.File.self, from: data)
        #expect(decoded.ruleSet == ruleSet)
        #expect(LosslessJSON.array(DeclarationEncoder.declarations(for: decoded.ruleSet)).serializedString().contains(#""Ratio":1.0"#))
    }

    @Test func strategiesWriteOnlyTheirFields() throws {
        let outlook = try CodeSignatureInspector.inspect(URL(filePath: "/System/Applications/Calculator.app"))
        let app = BinaryMatchStrategy.appFromDeveloper.rules(for: outlook, slices: outlook.defaultSlices)
        #expect(app.count == 1)
        #expect(app[0].hasTeamID && app[0].hasSigningID && !app[0].hasCDHash && app[0].pathPrefix.isEmpty && app[0].signingState.isEmpty)
        let team = BinaryMatchStrategy.developer.rules(for: outlook, slices: outlook.defaultSlices)
        #expect(team.count == 1 && !team[0].hasSigningID)
        let exact = BinaryMatchStrategy.exactBuild.rules(for: outlook, slices: outlook.slices)
        #expect(exact.count == outlook.slices.count)
        #expect(exact.allSatisfy { $0.hasCDHash && !$0.hasTeamID })
    }
}

@Suite("CSV interoperability")
struct CSVTests {
    /// As App Settings Utility writes them: jq @csv quoting, numbers bare, null empty.
    static let bundleIDCSV = #"""
    "App Name","Platform","Bundle ID","App Store ID","Developer","Version","Minimum OS","App Store URL","External Version ID"
    "Microsoft Outlook","iPad, iPhone / iOS","com.microsoft.Office.Outlook",951937596,"Microsoft Corporation","5.2641.0","26.0","https://apps.apple.com/gb/app/microsoft-outlook/id951937596?uo=4",893334590
    "Say ""Hi""","Mac","com.example.hi",123,"Example, Inc.","1.0","14.0","https://apps.apple.com/gb/app/id123?uo=4",""
    "Safari","iPhone / iPad (Apple reference)","com.apple.mobilesafari",,"Apple",,,,""

    """#

    static let localCSV = #"""
    "App Name","App Path","Executable Path","Bundle ID","Version","Composed Identifier","Architecture","CDHash","TeamID","SigningID","Designated Requirement","PathPrefix (suggested)","SigningState","Signature Verification"
    "Safari","/System/Cryptexes/App/System/Applications/Safari.app","/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari","com.apple.Safari","27.0.1","com.apple.Safari {identifier ""com.apple.Safari"" and anchor apple}","x86_64","7f775956ebb423597e2ffe04ab1a24f34f651c5a","*APPLE*","com.apple.Safari","identifier ""com.apple.Safari"" and anchor apple","/System/Cryptexes/App/System/Applications/Safari.app/","Apple","Valid"
    "Safari","/System/Cryptexes/App/System/Applications/Safari.app","/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari","com.apple.Safari","27.0.1","com.apple.Safari {identifier ""com.apple.Safari"" and anchor apple}","arm64e","a09ef19476472dd66365c3d8e45151c6ab1771e5","*APPLE*","com.apple.Safari","identifier ""com.apple.Safari"" and anchor apple","/System/Cryptexes/App/System/Applications/Safari.app/","Apple","Valid"
    "Unsigned","/Applications/Unsigned.app","","","","","Unknown","","","","","/Applications/Unsigned.app/","Unknown","Unverified"

    """#

    @Test(arguments: [bundleIDCSV, localCSV])
    func importThenExportIsIdentical(text: String) throws {
        let document = try CSVImporter.importDocument(text)
        #expect(CSVExporter.export(document) == text)
    }

    @Test func parsesTypedValues() throws {
        guard case .bundleIDLookup(let rows) = try CSVImporter.importDocument(Self.bundleIDCSV) else {
            Issue.record("Expected a BundleID-Lookup file")
            return
        }
        #expect(rows.count == 3)
        #expect(rows[0].platforms == ["iPad", "iPhone / iOS"])
        #expect(rows[1].name == #"Say "Hi""#)
        #expect(rows[2].appStoreID == nil)
        #expect(rows[2].fields[3] == .null)
        #expect(rows[1].fields[8] == .text(""))
    }

    @Test func exportOfInspectedAppReimportsIdentically() throws {
        let inspection = try CodeSignatureInspector.inspect(URL(filePath: "/System/Applications/Calculator.app"))
        let text = CSVExporter.export(.localMacApps(LocalMacAppRow.rows(for: inspection)))
        #expect(text.hasPrefix(#""App Name","App Path","Executable Path""#))
        #expect(CSVExporter.export(try CSVImporter.importDocument(text)) == text)
        guard case .localMacApps(let rows) = try CSVImporter.importDocument(text) else { return }
        #expect(rows.map(\.architecture) == inspection.slices.map(\.architecture))
        #expect(rows.map(\.cdHash) == inspection.slices.map(\.cdHash))
    }

    @Test func appStoreAndAppleRowsMatchAppSettingsUtility() throws {
        let app = AppStoreApp(appStoreID: 951937596, name: "Microsoft Outlook", bundleID: "com.microsoft.Office.Outlook",
                              developer: "Microsoft Corporation", version: "5.2641.0", minimumOS: "26.0",
                              appStoreURL: "https://apps.apple.com/gb/app/microsoft-outlook/id951937596?uo=4",
                              platforms: ["iPad", "iPhone / iOS"])
        var detail = try #require(AppStoreDetail(lookupResponse: try LosslessJSON(string: #"{"results":{"951937596":{"bundleId":"x","offers":[{"version":{"display":"5.2641.0","externalId":893334590}}]}}}"#), appStoreID: 951937596))
        detail.seller = nil
        let safari = AppleBuiltInApps.App(name: "Safari", bundleId: "com.apple.mobilesafari", builtIn: true)
        let lines = CSVExporter.export(.bundleIDLookup([BundleIDLookupRow(app: app, detail: detail), BundleIDLookupRow(appleApp: safari)]))
            .split(separator: "\n").map(String.init)
        let expected = Self.bundleIDCSV.split(separator: "\n").map(String.init)
        #expect(lines == [expected[0], expected[1], expected[3]])
    }

    @Test func rejectsUnknownHeaderAndRaggedRows() {
        #expect(throws: CSVImporter.ImportError.self) { try CSVImporter.importDocument("\"Name\",\"Bundle\"\n") }
        let ragged = Self.bundleIDCSV.replacingOccurrences(of: #","893334590"#, with: "")
            .replacingOccurrences(of: ",893334590", with: "")
        #expect(throws: CSVImporter.ImportError.self) { try CSVImporter.importDocument(ragged) }
    }

    @Test func acceptsCRLFAndMissingFinalNewline() throws {
        // "\r\n" is a single Character in Swift, so dropLast() removes the whole final line break.
        let crlf = Self.bundleIDCSV.replacingOccurrences(of: "\n", with: "\r\n").dropLast()
        #expect(try CSVImporter.importDocument(String(crlf)).rowCount == 3)
    }

    @Test func fileNameFollowsAppSettingsUtility() {
        let date = Date(timeIntervalSince1970: 1_792_738_500)
        let name = CSVFormat.localMacApps.suggestedFileName(date: date)
        #expect(name.hasPrefix("Local-Mac-Apps_2026-10-"))
        #expect(name.wholeMatch(of: /Local-Mac-Apps_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.csv/) != nil)
    }
}

@Suite("RuleSetDocument")
@MainActor
struct RuleSetDocumentTests {
    @Test func editsAreUndoableAndTrackUnsavedChanges() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let document = RuleSetDocument()
        document.undoManager = undo
        #expect(!document.isDirty)

        undo.beginUndoGrouping()
        document.addApps([("com.apple.news", "News")])
        undo.endUndoGrouping()
        #expect(document.isDirty)
        #expect(document.ruleSet.deniedApps.map(\.bundleID) == ["com.apple.news"])

        undo.undo()
        #expect(document.ruleSet.deniedApps.isEmpty)
        #expect(!document.isDirty)
        undo.redo()
        #expect(document.ruleSet.deniedApps.count == 1)
    }

    @Test func emptyRuleSetSwitchesPlatformButNonEmptyOneRefuses() throws {
        let document = RuleSetDocument()
        let calculator = try CodeSignatureInspector.inspect(URL(filePath: "/System/Applications/Calculator.app"))
        let rules = BinaryMatchStrategy.appFromDeveloper.rules(for: calculator, slices: calculator.defaultSlices)
        #expect(document.addBinaryRules(rules, toAllowList: false))
        #expect(document.ruleSet.platform == .macOS)
        // Adding iOS bundle IDs to a non-empty macOS rule set is refused, not mixed in.
        #expect(!document.addApps([("com.apple.news", nil)]))
        #expect(document.ruleSet.deniedApps.isEmpty)
        #expect(document.statusMessage?.contains("targets macOS") == true)
    }

    @Test func saveAndOpenRoundTrip() throws {
        let document = RuleSetDocument()
        document.addApps([("com.apple.news", "News"), ("com.apple.stocks", nil)])
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(RuleSetDocument.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.save(to: url)
        #expect(!document.isDirty)

        let reopened = RuleSetDocument()
        try reopened.open(url)
        #expect(reopened.ruleSet == document.ruleSet)
        #expect(reopened.fileURL == url)
        #expect(!reopened.isDirty)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(RuleSetDocument.File.formatIdentifier))
    }

    @Test func openRejectsOtherJSON() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"hello":"world"}"#.utf8).write(to: url)
        #expect(throws: RuleSetDocument.DocumentError.self) { try RuleSetDocument().open(url) }
    }

    @Test func importsLocalCSVAsRulesWithTheChosenStrategy() throws {
        let csv = try CSVImporter.importDocument(CSVTests.localCSV)
        let perApp = RuleSetDocument()
        #expect(perApp.importCSV(csv, strategy: .appFromDeveloper, toAllowList: true))
        // Safari has two rows (slices) → one TeamID + SigningID rule; the unsigned row adds nothing.
        #expect(perApp.ruleSet.allowedBinaries.map(\.matchKey) == [["", "*APPLE*", "com.apple.Safari", "", ""]])

        let perSlice = RuleSetDocument()
        #expect(perSlice.importCSV(csv, strategy: .exactBuild, toAllowList: false))
        #expect(perSlice.ruleSet.deniedBinaries.map(\.cdHash) == ["7f775956ebb423597e2ffe04ab1a24f34f651c5a", "a09ef19476472dd66365c3d8e45151c6ab1771e5"])
    }

    @Test func importsBundleIDCSVIntoTheAppList() throws {
        let document = RuleSetDocument()
        #expect(document.importCSV(try CSVImporter.importDocument(CSVTests.bundleIDCSV), strategy: .appFromDeveloper, toAllowList: false))
        #expect(document.ruleSet.deniedApps.map(\.bundleID) == ["com.microsoft.Office.Outlook", "com.example.hi", "com.apple.mobilesafari"])
        #expect(document.ruleSet.deniedApps.first?.displayName == "Microsoft Outlook")
    }
}
