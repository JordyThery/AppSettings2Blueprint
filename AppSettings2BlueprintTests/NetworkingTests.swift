import Foundation
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
    private let credentials = PlatformCredentials(region: .eu, environmentID: "env-1", clientID: "id", clientSecret: "s3cr3t")
    private static let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)

    private func makeClient(sleeps: SleepRecorder = SleepRecorder()) -> PlatformAPIClient {
        PlatformAPIClient(
            credentials: credentials,
            session: MockURLProtocol.makeSession(),
            sleep: { try await sleeps.sleep(.seconds($0)) },
            log: { _ in }
        )
    }

    private func apiRequests() -> [RecordedRequest] {
        MockURLProtocol.requests.filter { $0.path != "/auth/token" }
    }

    @Test func deleteAndUndeployNeverReachTheNetwork() async {
        MockURLProtocol.install { _ in Issue.record("No request may be sent"); return .json(500, "{}") }
        let client = makeClient()
        await #expect(throws: APIError.self) {
            try await client.send(method: "DELETE", path: "/blueprints/v1/blueprints/abc")
        }
        await #expect(throws: APIError.self) {
            try await client.send(method: "POST", path: "/blueprints/v1/blueprints/abc/undeploy")
        }
        #expect(MockURLProtocol.requests.isEmpty)
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
        _ = try await BlueprintService(client: makeClient()).listPage()
        #expect(tokens.value == 2)
        #expect(gets.value == 2)
        let request = try #require(apiRequests().last)
        #expect(request.header("X-Environment-Id") == "env-1")
        #expect(request.header("Authorization") == "Bearer tok")
    }

    @Test func secondConsecutive401IsThrown() async {
        MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(401, "{}") }
        await #expect(throws: APIError.self) { try await BlueprintService(client: makeClient()).listPage() }
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
        _ = try await BlueprintService(client: makeClient(sleeps: sleeps)).listPage()
        #expect(gets.value == 2)
        #expect(sleeps.recorded == [.seconds(7)])
    }

    @Test func deployIsNotRetriedOn5xx() async {
        MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(503, "{}") }
        await #expect(throws: APIError.self) { try await BlueprintService(client: makeClient()).deploy(id: "abc") }
        #expect(apiRequests().count == 1)
        #expect(apiRequests().first?.path == "/blueprints/v1/blueprints/abc/deploy")
    }

    @Test func deployIsRetriedOn429() async throws {
        let posts = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return Self.token }
            return posts.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "1"]) : .json(202, "")
        }
        try await BlueprintService(client: makeClient()).deploy(id: "abc")
        #expect(posts.value == 2)
    }

    @Test func getIsRetriedOn5xx() async throws {
        let gets = Counter()
        MockURLProtocol.install { request in
            if request.path == "/auth/token" { return Self.token }
            return gets.next() == 1 ? .json(502, "{}") : .json(200, #"{"results":[],"totalCount":0}"#)
        }
        _ = try await BlueprintService(client: makeClient()).listPage()
        #expect(gets.value == 2)
    }

    @Test func patchSendsOnlyStepsAsMergePatch() async throws {
        MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : MockResponse(status: 204, body: Data()) }
        let blueprint = try JSONValue(string: appSettingsBlueprintJSON)
        let steps = try #require(blueprint["steps"])
        try await BlueprintService(client: makeClient()).patchSteps(id: "abc", steps: steps)
        let request = try #require(apiRequests().first)
        #expect(request.method == "PATCH")
        #expect(request.header("Content-Type") == "application/merge-patch+json")
        #expect(request.bodyString == #"{"steps":"# + steps.serializedString() + "}")
        #expect(!request.bodyString.contains("divisionId"))
    }

    @Test @MainActor func tokenSecretIsNotLogged() async throws {
        let entries = LogCollector()
        MockURLProtocol.install { $0.path == "/auth/token" ? Self.token : .json(200, #"{"results":[],"totalCount":0}"#) }
        let client = PlatformAPIClient(credentials: credentials, session: MockURLProtocol.makeSession()) { entries.append($0) }
        _ = try await BlueprintService(client: client).listPage()
        let all = entries.all
        #expect(!all.isEmpty)
        let text = all.map { [$0.requestBody ?? "", $0.responseBody ?? "", $0.requestHeaders.map(\.1).joined()].joined() }.joined()
        #expect(!text.contains("s3cr3t"))
        #expect(!text.contains("\"tok\""))
        #expect(!text.contains("Bearer tok"))
    }
}

}

@Suite("Update version comparison")
struct UpdateVersionTests {
    @Test func comparesNumericComponents() {
        #expect(UpdateChecker.isNewer("1.10", than: "1.9"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.1"))
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2"))
    }

    @Test func suffixedTagsCompareByLeadingDigits() {
        #expect(UpdateChecker.isNewer("1.2.1-hotfix", than: "1.2"))
        #expect(!UpdateChecker.isNewer("1.2.0-beta", than: "1.2"))
    }
}

/// Collects log entries delivered on the main actor.
@MainActor
private final class LogCollector {
    private(set) var all: [RequestLogEntry] = []
    func append(_ entry: RequestLogEntry) { all.append(entry) }
}
