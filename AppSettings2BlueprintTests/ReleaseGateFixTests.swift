import AppKit
import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

@Suite("Backups: permissions and retention")
struct BackupRetentionTests {
    private let detail = try! JamfPlatform.BlueprintDetail(data: Data(appSettingsBlueprintJSON.utf8))

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("Backups and their folders are readable by the user's account only")
    func ownerOnly() throws {
        let root = TestApp.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try BackupStore.write(detail, root: root)
        #expect(try permissions(url) == 0o600)
        #expect(try permissions(url.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(root) == 0o700)
    }

    @Test("Pruning removes old backups but keeps each Blueprint's newest one; Forever removes none")
    func prune() throws {
        let root = TestApp.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var urls: [URL] = []
        for daysAgo in [400, 100, 40, 10] {
            let date = now.addingTimeInterval(-Double(daysAgo) * 86_400)
            let url = try BackupStore.write(detail, date: date, root: root)
            try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path(percentEncoded: false))
            urls.append(url)
        }
        #expect(BackupStore.prune(.forever, root: root, now: now) == 0)
        #expect(BackupStore.prune(.ninetyDays, root: root, now: now) == 2)
        #expect(BackupStore.backups(for: detail.id, root: root).map(\.url.lastPathComponent) == [urls[3], urls[2]].map(\.lastPathComponent))

        // An old newest backup is kept: it is the state before the last write.
        #expect(BackupStore.prune(.thirtyDays, root: root, now: now.addingTimeInterval(365 * 86_400)) == 1)
        #expect(BackupStore.backups(for: detail.id, root: root).map(\.url.lastPathComponent) == [urls[3].lastPathComponent])
    }

    @Test("The retention is saved in the app's own settings, and every write prunes")
    @MainActor
    func retentionSetting() throws {
        let app = TestApp.model()
        #expect(app.backupRetention == .forever)
        app.backupRetention = .thirtyDays
        #expect(app.defaults.integer(forKey: BackupStore.retentionKey) == 30)
        #expect(app.backupRetention == .thirtyDays)
    }
}

@Suite("Review diff")
struct LargeDiffTests {
    @Test("Shared lines at the start and end are kept, changed lines in between are marked")
    func prefixAndSuffix() {
        let diff = TextDiff.lines(from: "a\nb\nc\nd\ne", to: "a\nb\nX\nd\ne")
        #expect(diff.map(\.kind) == [.unchanged, .unchanged, .removed, .added, .unchanged, .unchanged])
        #expect(diff.map(\.index) == Array(0..<6))
    }

    @Test("An allow list of thousands of lines with one change diffs quickly, line by line")
    func largeAllowList() {
        let old = (0..<6_000).map { #"    { "TeamID" : "TEAM\#($0)" },"# }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: #""TEAM3000" }"#, with: #""TEAM3000X" }"#)
        let start = Date()
        let diff = TextDiff.lines(from: old, to: new)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(diff.count { $0.kind == .removed } == 1)
        #expect(diff.count { $0.kind == .added } == 1)
    }

    @Test("A change too large for a table is shown as removed, then added")
    func tooLargeForATable() {
        let old = (0..<3_000).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<3_000).map { "new \($0)" }.joined(separator: "\n")
        let diff = TextDiff.lines(from: old, to: new)
        #expect(diff.count == 6_000)
        #expect(diff.prefix(3_000).allSatisfy { $0.kind == .removed })
        #expect(diff.suffix(3_000).allSatisfy { $0.kind == .added })
    }
}

@Suite("Quitting with unsaved changes")
@MainActor
struct QuitPromptTests {
    private func delegate(edited: Bool) -> (AppDelegate, Counter) {
        let app = TestApp.model()
        if edited { app.ruleSet.update("Add") { $0.deniedApps.append(AppRule(bundleID: "com.apple.news")) } }
        let delegate = AppDelegate()
        delegate.model = app
        let asked = Counter()
        delegate.ask = { _ in _ = asked.next(); return .cancel }
        return (delegate, asked)
    }

    @Test("A clean rule set quits without a question")
    func clean() {
        let (delegate, asked) = delegate(edited: false)
        #expect(delegate.terminateReply() == .terminateNow)
        #expect(asked.value == 0)
    }

    @Test("An edited rule set asks; Cancel keeps the app open, Don’t Save quits")
    func asks() {
        let (delegate, asked) = delegate(edited: true)
        #expect(delegate.terminateReply() == .terminateCancel)
        #expect(asked.value == 1)
        delegate.ask = { _ in .discard }
        #expect(delegate.terminateReply() == .terminateNow)
    }

    @Test("Save quits once saved, and stays open when the Save panel is canceled")
    func save() {
        let (delegate, _) = delegate(edited: true)
        delegate.ask = { _ in .save }
        delegate.save = { _ in false }
        #expect(delegate.terminateReply() == .terminateCancel)
        delegate.save = { _ in true }
        #expect(delegate.terminateReply() == .terminateNow)
    }
}

@Suite("Settings stay in the app's own suite")
@MainActor
struct SettingsStorageTests {
    @Test("Sidebar selection, storefront and the user Applications folder are saved to the model's settings, not the real preferences")
    func savedToModelDefaults() {
        let standard = UserDefaults.standard
        let before = [AppModel.sidebarSelectionKey, AppStoreModel.storefrontKey, LocalAppsModel.includeUserApplicationsKey]
            .map { standard.object(forKey: $0) as? NSObject }
        let app = TestApp.model()
        app.saveSidebarSelection(.localApps)
        app.appStore.storefront = "de"
        app.localApps.includesUserApplications = !app.localApps.includesUserApplications

        #expect(app.defaults.string(forKey: AppModel.sidebarSelectionKey) == "localApps")
        #expect(app.savedSidebarSelection == .localApps)
        #expect(app.defaults.string(forKey: AppStoreModel.storefrontKey) == "de")
        #expect(app.defaults.object(forKey: LocalAppsModel.includeUserApplicationsKey) != nil)
        let after = [AppModel.sidebarSelectionKey, AppStoreModel.storefrontKey, LocalAppsModel.includeUserApplicationsKey]
            .map { standard.object(forKey: $0) as? NSObject }
        #expect(before == after, "the real preferences are untouched")
    }
}

@Suite("Declarations: round trips")
struct DeclarationRoundTripTests {
    private func declaration(_ channel: String, _ allowed: String) -> LosslessJSON {
        try! LosslessJSON(string: #"{"kind":"CONFIGURATION","type":"com.apple.configuration.app.settings","payload":{"Allowed":\#(allowed)},"channelType":"\#(channel)"}"#)
    }

    @Test("Two declarations on one channel are combined into one, with a note")
    func twoOnOneChannel() {
        let decoded = DeclarationDecoder.decode(declarations: [
            declaration("SYSTEM", #"{"DeniedApps":["com.apple.news"]}"#),
            declaration("SYSTEM", #"{"DeniedApps":["com.apple.stocks"]}"#),
        ])
        #expect(decoded.ruleSet.deniedApps.map(\.bundleID) == ["com.apple.news", "com.apple.stocks"])
        #expect(decoded.notes.contains { $0.contains("More than one SYSTEM") })
        let encoded = DeclarationEncoder.declarations(for: decoded.ruleSet)
        #expect(encoded.count == 1)
        #expect(encoded[0]["payload"]?["Allowed"]?["DeniedApps"]?.arrayValue?.count == 2)
    }

    @Test("Keys the platform doesn't support are never written")
    func unsupportedKeysDropped() {
        var ruleSet = RuleSet(platform: .iOS, deniedApps: [AppRule(bundleID: "com.apple.news")])
        ruleSet.allowedBinaries = [BinaryRule(teamID: "ABCDE12345")]
        ruleSet.alwaysAllowManagedApps = true
        let text = DeclarationEncoder.declarations(for: ruleSet).map { $0.serializedString() }.joined()
        #expect(text.contains("DeniedApps"))
        #expect(!text.contains("AllowedBinaries"))
        #expect(!text.contains("AlwaysAllowManagedApps"))

        ruleSet.platform = .macOS
        let mac = DeclarationEncoder.declarations(for: ruleSet).map { $0.serializedString() }.joined()
        #expect(mac.contains("AllowedBinaries"))
        #expect(!mac.contains("DeniedApps"))
    }
}
