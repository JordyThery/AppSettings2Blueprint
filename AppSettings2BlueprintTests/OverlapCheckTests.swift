import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import AppSettings2Blueprint

private let targetID = "0a1b2c3d-4444-4444-8444-0123456789ab"
private let otherID = "0a1b2c3d-5555-4555-8555-0123456789ab"

@Suite("Write to Jamf: the overlap check says what it can't see yet")
@MainActor
struct OverlapCheckTests {
    @Test("Blueprints still loading, then failed, are counted; none while the target has no groups")
    func uncheckedBlueprints() async throws {
        let server = MockServer { request in
            if request.path == "/auth/token" { return .json(200, #"{"access_token":"tok","expires_in":900}"#) }
            if request.path.hasSuffix(otherID) { return .json(404, "{}") }
            return .json(200, #"{"totalCount":2,"results":[{"id":"\#(targetID)","name":"Target"},{"id":"\#(otherID)","name":"Other"}]}"#)
        }
        let app = TestApp.model(session: server.session, connected: true)
        app.refresh()
        for _ in 0..<300 where app.overviews.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let model = JamfWriteModel(app: app)
        model.selectedBlueprintID = targetID
        #expect(model.uncheckedForOverlap == (0, 0), "the target isn't loaded: no groups to compare yet")

        app.storeDetail(try JamfPlatform.BlueprintDetail(data: Data(appSettingsBlueprintJSON.utf8)))
        #expect(model.uncheckedForOverlap == (1, 0))

        await app.loadMissingDetails()
        #expect(model.uncheckedForOverlap == (0, 1))
    }
}
