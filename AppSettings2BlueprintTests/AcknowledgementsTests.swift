import Foundation
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
        let inApp = AcknowledgementsView.licence
        #expect(inApp == fromNotices)
        #expect(inApp.contains("Copyright (c) 2026 Anthony Darlow"))
    }

    @Test func linksPointToTheOriginalProject() {
        let repository = AcknowledgementsView.repositoryURL?.absoluteString
        let post = AcknowledgementsView.blogPostURL?.absoluteString
        #expect(repository == "https://github.com/cantscript/AppSettingsUtility")
        #expect(post == "https://cantscript.com/posts/stop-hunting-for-bundle-ids--cdhashes/")
    }
}
