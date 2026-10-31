import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

@Suite("HTTP method allow-list")
struct RequestAllowListTests {
    @Test(arguments: [
        ("GET", "/blueprints/v1/blueprints"),
        ("GET", "/blueprints/v1/blueprints/abc/report"),
        ("GET", "/device-groups/v1/device-groups"),
        ("POST", "/auth/token"),
        ("POST", "/blueprints/v1/blueprints"),
        ("PATCH", "/blueprints/v1/blueprints/abc"),
        ("POST", "/blueprints/v1/blueprints/abc/deploy"),
    ])
    func permits(method: String, path: String) {
        #expect(RequestAllowList.isPermitted(method: method, path: path))
    }

    @Test(arguments: [
        ("DELETE", "/blueprints/v1/blueprints/abc"),
        ("POST", "/blueprints/v1/blueprints/abc/undeploy"),
        ("PUT", "/blueprints/v1/blueprints/abc"),
        ("PATCH", "/blueprints/v1/blueprints"),
        ("PATCH", "/device-groups/v1/device-groups/abc"),
        ("POST", "/device-groups/v1/device-groups"),
        ("POST", "/blueprints/v1/blueprints/abc/deploy/extra"),
        ("PATCH", "/blueprints/v1/blueprints/../x"),
        ("POST", "/blueprints/v1/blueprints//deploy"),
        ("GET", "blueprints/v1/blueprints"),
        // Encoded traversal must be judged by the decoded segment.
        ("PATCH", "/blueprints/v1/blueprints/..%2F..%2Fv1%2Fdevices"),
        ("PATCH", "/blueprints/v1/blueprints/%2e%2e"),
        ("POST", "/blueprints/v1/blueprints/a%2Fb/deploy"),
        ("GET", "/blueprints/v1/%2e%2e/other"),
        ("GET", "/blueprints/v1/%zz"),
    ])
    func refuses(method: String, path: String) {
        #expect(!RequestAllowList.isPermitted(method: method, path: path))
    }

    /// Percent-encoding that does not hide a separator stays permitted.
    @Test func permitsHarmlessEncoding() {
        #expect(RequestAllowList.isPermitted(method: "PATCH", path: "/blueprints/v1/blueprints/a%20b"))
    }
}

extension MockNetworkTests {
@Suite("Platform API client")
struct PlatformAPIClientTests {
    private static let environmentID = "e77c1408-10c8-4007-b177-abc9157fbcaa"
    private let credentials = PlatformCredentials(region: .eu, environmentID: environmentID, clientID: "id", clientSecret: "s3cr3t")
    private static let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)

    private func makeClient(sleeps: SleepRecorder = SleepRecorder(), log: ActivityLog? = nil) throws -> JamfPlatform.Client {
        try PlatformAPIClient.make(
            credentials: credentials,
            session: MockURLProtocol.makeSession(),
            log: log,
            sleep: { try await sleeps.sleep($0) }
        )
    }

    private func blueprints(sleeps: SleepRecorder = SleepRecorder(), log: ActivityLog? = nil) throws -> JamfPlatform.Blueprints {
        JamfPlatform.Blueprints(client: try makeClient(sleeps: sleeps, log: log))
    }

    private func apiRequests() -> [RecordedRequest] {
        MockURLProtocol.requests.filter { $0.path != "/auth/token" }
    }

    @Test func deleteAndUndeployNeverReachTheNetwork() async throws {
        MockURLProtocol.install { _ in Issue.record("No request may be sent"); return .json(500, "{}") }
        let client = try makeClient()
        await #expect(throws: JamfPlatform.APIError.self) {
            try await client.send(HTTPRequest(method: "DELETE", path: "/blueprints/v1/blueprints/abc"))
        }
        await #expect(throws: JamfPlatform.APIError.self) {
            try await client.send(HTTPRequest(method: "POST", path: "/blueprints/v1/blueprints/abc/undeploy"))
        }
        await #expect(throws: JamfPlatform.APIError.self) { try await blueprints().delete(id: "abc") }
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test func aRefusedRequestSaysWhatTheAppSends() async throws {
        MockURLProtocol.install { _ in .json(500, "{}") }
        let error = await #expect(throws: JamfPlatform.APIError.self) { try await blueprints().delete(id: "abc") }
        #expect(error?.localizedDescription.contains(PlatformAPIClient.refusedHint) == true)
    }

    @Test func anEnvironmentIDThatIsNotAUUIDIsRefusedBeforeSending() {
        MockURLProtocol.install { _ in Issue.record("No request may be sent"); return .json(500, "{}") }
        var bad = credentials
        bad.environmentID = "env-1"
        #expect(throws: JamfPlatform.APIError.self) {
            _ = try PlatformAPIClient.make(credentials: bad, session: MockURLProtocol.makeSession(), log: nil)
        }
    }

    @Test func refreshesTokenOnceAfter401() async throws {
        let tokens = Counter()
        let gets = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" {
                _ = tokens.next()
                return Self.token
            }
            return gets.next() == 1 ? .json(401, "{}") : .json(200, #"{"results":[],"totalCount":0}"#)
        }
        _ = try await blueprints().listPage()
        #expect(tokens.value == 2)
        #expect(gets.value == 2)
        let request = try #require(apiRequests().last)
        #expect(request.url.host() == "eu.api.jamfcloud.com")
        #expect(request.header("X-Environment-Id") == Self.environmentID)
        #expect(request.header("Authorization") == "Bearer tok")
    }

    @Test func secondConsecutive401IsThrown() async throws {
        MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(401, "{}") }
        await #expect(throws: JamfPlatform.APIError.self) { _ = try await blueprints().listPage() }
        #expect(apiRequests().count == 2)
    }

    @Test func honours429RetryAfter() async throws {
        let gets = Counter()
        let sleeps = SleepRecorder()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return Self.token }
            return gets.next() == 1
                ? .json(429, "{}", headers: ["Retry-After": "7"])
                : .json(200, #"{"results":[],"totalCount":0}"#)
        }
        _ = try await blueprints(sleeps: sleeps).listPage()
        #expect(gets.value == 2)
        #expect(sleeps.recorded == [.seconds(7)])
    }

    @Test func deployIsNotRetriedOn5xx() async throws {
        MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(503, "{}") }
        await #expect(throws: JamfPlatform.APIError.self) { try await blueprints().deploy(id: "abc") }
        #expect(apiRequests().count == 1)
        #expect(apiRequests().first?.path == "/blueprints/v1/blueprints/abc/deploy")
    }

    @Test func deployIsRetriedOn429() async throws {
        let posts = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return Self.token }
            return posts.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "1"]) : .json(202, "")
        }
        try await blueprints().deploy(id: "abc")
        #expect(posts.value == 2)
    }

    @Test func getIsRetriedOn5xx() async throws {
        let gets = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return Self.token }
            return gets.next() == 1 ? .json(502, "{}") : .json(200, #"{"results":[],"totalCount":0}"#)
        }
        _ = try await blueprints().listPage()
        #expect(gets.value == 2)
    }

    @Test func patchSendsOnlyStepsAsMergePatch() async throws {
        MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : MockResponse(status: 204, body: Data()) }
        let blueprint = try LosslessJSON(string: appSettingsBlueprintJSON)
        let steps = try #require(blueprint["steps"])
        try await blueprints().patchSteps(id: "abc", steps: steps)
        let request = try #require(apiRequests().first)
        #expect(request.method == "PATCH")
        #expect(request.header("Content-Type") == "application/merge-patch+json")
        #expect(request.bodyString == #"{"steps":"# + steps.serializedString() + "}")
        #expect(!request.bodyString.contains("divisionId"))
    }

    @Test func patchIsRetriedOn5xx() async throws {
        let patches = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return Self.token }
            return patches.next() == 1 ? .json(503, "{}") : MockResponse(status: 204, body: Data())
        }
        try await blueprints().patchScope(id: "abc", deviceGroups: ["g1"])
        #expect(patches.value == 2)
    }

    @Test func failedSignInSaysWhatToCheck() async throws {
        MockURLProtocol.install { _ in .json(401, #"{"error":"invalid_client"}"#) }
        let error = await #expect(throws: JamfPlatform.APIError.self) { try await makeClient().signIn() }
        guard case .signIn(401, _, _)? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
        #expect(error?.localizedDescription.contains("Check the client ID, client secret and region") == true)
    }

    @Test @MainActor func refusedRequestIsLoggedAsWarning() async throws {
        let log = ActivityLog()
        MockURLProtocol.install { _ in Issue.record("No request may be sent"); return .json(500, "{}") }
        let client = try makeClient(log: log)
        await #expect(throws: JamfPlatform.APIError.self) {
            try await client.send(HTTPRequest(method: "DELETE", path: "/blueprints/v1/blueprints/abc"))
        }
        #expect(log.entries.count == 1)
        #expect(log.entries.first?.isWarning == true)
    }

    @Test @MainActor func waitBeforeRetryIsLogged() async throws {
        let log = ActivityLog()
        let gets = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return Self.token }
            return gets.next() == 1
                ? .json(429, "{}", headers: ["Retry-After": "7"])
                : .json(200, #"{"results":[],"totalCount":0}"#)
        }
        _ = try await blueprints(log: log).listPage()
        let wait = try #require(log.entries.first { $0.category == "Retry" })
        #expect(wait.isWarning)
        #expect(wait.note?.contains("waiting 7 s, attempt 2 of 4") == true)
    }

    @Test @MainActor func secretsAndBodiesAreNotLogged() async throws {
        let log = ActivityLog()
        MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : MockResponse(status: 204, body: Data()) }
        let blueprint = try LosslessJSON(string: appSettingsBlueprintJSON)
        let steps = try #require(blueprint["steps"])
        try await blueprints(log: log).patchSteps(id: "abc", steps: steps)
        let entries = log.entries
        #expect(entries.map(\.category) == ["Sign-in", "API"])
        #expect(entries.allSatisfy { $0.service == "Jamf Platform API" })
        let text = entries.compactMap(\.request).map { details in
            [details.url, details.requestBody ?? "", details.responseBody ?? "",
             (details.requestHeaders + details.responseHeaders).map(\.value).joined(separator: " ")].joined(separator: " ")
        }.joined(separator: " ")
        #expect(!text.contains("s3cr3t"))
        #expect(!text.contains("\"tok\""))
        #expect(!text.contains("Bearer tok"))
        // The default bodies rule: the PATCH body is never recorded.
        #expect(entries.allSatisfy { $0.request?.requestBody == nil })
    }
}

}
