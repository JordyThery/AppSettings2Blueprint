import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

@Suite("Acknowledgements")
struct AcknowledgementsTests {
    /// The licence shown in About must be the one in THIRD-PARTY-NOTICES.md, unchanged.
    @Test func licenceMatchesThirdPartyNotices() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notices = try String(contentsOf: repository.appendingPathComponent("THIRD-PARTY-NOTICES.md"), encoding: .utf8)
        let start = try #require(notices.range(of: "```\nMIT License"))
        let end = try #require(notices.range(of: "\n```", range: start.upperBound..<notices.endIndex))
        let fromNotices = String(notices[notices.index(start.lowerBound, offsetBy: 4)..<end.lowerBound])
        let inApp = try #require(Acknowledgement.appSettingsUtility.license)
        #expect(inApp == fromNotices)
        #expect(inApp.contains("Copyright (c) 2026 Anthony Darlow"))
    }

    @Test func linksPointToTheOriginalProject() {
        let links = Acknowledgement.appSettingsUtility.links.map(\.url.absoluteString)
        #expect(links == [
            "https://github.com/cantscript/AppSettingsUtility",
            "https://cantscript.com/posts/stop-hunting-for-bundle-ids--cdhashes/",
        ])
    }

    @Test func aboutCreditsAppSettingsUtility() {
        let about = AboutConfiguration.appSettings2Blueprint
        #expect(about.acknowledgements == [.appSettingsUtility])
        #expect(Acknowledgement.appSettingsUtility.heading == "App Settings Utility by Anthony Darlow")
        #expect(about.links.map(\.url.absoluteString) == ["https://github.com/JordyThery/AppSettings2Blueprint"])
    }

    /// The line JTKit writes; it matches what NSHumanReadableCopyright said before 0.4.1.
    @Test func aboutShowsTheCopyrightLine() {
        #expect(AboutConfiguration.appSettings2Blueprint.copyright?.text == "© 2026 Jordy Thery. Released under the MIT License.")
    }
}
