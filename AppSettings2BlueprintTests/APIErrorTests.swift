import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

/// The app's messages on top of JTKit's Platform API errors. (The lossless
/// JSON tests moved to JTKit with the code.)
@Suite("API errors")
struct APIErrorTests {
    private func failure(_ status: Int, _ body: String) -> JamfPlatformError {
        JamfPlatformError(HTTPError.status(HTTPResponse(status: status, headers: ["Content-Type": "application/json"], data: Data(body.utf8)),
                                           method: "PATCH", path: "/blueprints/v1/blueprints/b1", duringSignIn: false))
    }

    @Test func readsTheErrorObjectWithItsTraceID() {
        let error = failure(409, #"{"httpStatus":409,"traceId":"abc-123","errors":{"code":"DIVISION_PATCH_NOT_ALLOWED","field":null,"description":"Assigned to a division"}}"#)
        #expect(error.traceID == "abc-123")
        #expect(error.hasCode(.divisionPatchNotAllowed))
        #expect(error.localizedDescription.hasPrefix("HTTP 409 Conflict\nDIVISION_PATCH_NOT_ALLOWED: Assigned to a division\nTrace ID: abc-123"))
    }

    /// Error messages shown to the user go through JTKit's redaction.
    @Test func errorMessagesAreRedacted() {
        #expect(!failure(400, #"{"message":"bad request","access_token":"tok-123"}"#).localizedDescription.contains("tok-123"))
    }

    /// The Device Groups API's answer for a Jamf School environment (verified live).
    @Test func recognisesJamfSchoolTenantNotFound() {
        let error = failure(404, #"{"httpStatus":404,"traceId":"t","errors":[{"code":"TENANT_NOT_FOUND","description":"No tenant found for environment 'e'."}]}"#)
        #expect(error.hasCode(.tenantNotFound))
    }

    /// A refused request keeps the app's explanation of what it sends.
    @Test func refusedRequestKeepsTheAppsHint() {
        let refused = JamfPlatformError(.refused(method: "DELETE", path: "/blueprints/v1/blueprints/abc"))
        #expect(PlatformAPIClient.hints(for: refused) == [PlatformAPIClient.refusedHint])
        #expect(PlatformAPIClient.hints(for: failure(500, "{}")).isEmpty)
    }

    @Test func missingCredentialsSaysWhatToFillIn() {
        #expect(APIError.missingCredentials.localizedDescription.contains("Open Settings"))
    }
}

@Suite("Test Connection (JTKit's message)")
struct ConnectionTestProblemTests {
    @Test func allowedEverywhereIsNoProblem() {
        #expect(JamfPlatform.PermissionProblem([(.blueprintsRead, .allowed), (.deviceGroupsRead, .allowed)]) == nil)
    }

    @Test func aMissingReadPermissionIsNamedWithWhatToAdd() throws {
        let problem = try #require(JamfPlatform.PermissionProblem([(.blueprintsRead, .allowed), (.deviceGroupsRead, .missingPermission)]))
        #expect(problem.errorDescription == "Signed in, but the API integration is missing a permission: device-groups:read.")
        #expect(problem.failureReason == "Add the “device-groups:read” permission to the API integration in Jamf Account.")
    }

    /// A 404 or a network error isn't counted as a missing permission.
    @Test func whatCouldNotBeCheckedIsSaidSeparately() throws {
        let problem = try #require(JamfPlatform.PermissionProblem([(.blueprintsRead, .unreachable("Network error: offline")), (.deviceGroupsRead, .notFound)]))
        #expect(problem.errorDescription == "Signed in, but not every permission could be checked.")
        #expect(problem.failureReason == "Read Blueprints couldn’t be checked: Network error: offline\nRead device groups couldn’t be checked: not found (HTTP 404)")
    }
}
