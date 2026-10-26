import Foundation
import JTKit
import Testing
@testable import AppSettings2Blueprint

@Suite("App Settings discovery")
struct AppSettingsLocatorTests {
    @Test func findsDeclarationInStrictComponent() throws {
        let detail = try JamfPlatform.BlueprintDetail(data: Data(appSettingsBlueprintJSON.utf8))
        #expect(detail.containsAppSettings)
        #expect(detail.appSettingsLocations.count == 1)
        let location = try #require(detail.appSettingsLocations.first)
        #expect(location.path.pathString == "steps[0].components[3].configuration.declarations[1]")
        #expect(location.isStrictComponent)
        #expect(location.channelType == "SYSTEM")
        #expect(location.kind == "CONFIGURATION")
        #expect(location.stepName == "Step 1")
        #expect(detail.json.value(at: location.path)?["payload"]?["Allowed"]?["DeniedApps"]?[0]?.stringValue == "com.apple.news")
    }

    @Test func reportsDeclarationInOtherComponentAsNotStrict() throws {
        let json = #"{"id":"x","steps":[{"components":[{"identifier":"com.jamf.ddm.custom-declarations","configuration":{"declarations":[{"type":"com.apple.configuration.app.settings","channelType":"USER","payload":{}}]}}]}]}"#
        let location = try #require(try JamfPlatform.BlueprintDetail(data: Data(json.utf8)).appSettingsLocations.first)
        #expect(!location.isStrictComponent)
        #expect(location.channelType == "USER")
    }

    @Test func blueprintWithoutAppSettingsIsNotAMatch() throws {
        let json = #"{"id":"x","steps":[{"components":[{"identifier":"com.jamf.ddm-strict","configuration":{"declarations":[{"type":"com.apple.configuration.keyboard.settings","payload":{}}]}}]}]}"#
        #expect(!(try JamfPlatform.BlueprintDetail(data: Data(json.utf8))).containsAppSettings)
    }

    @Test func untouchedStepsRoundTripByteForByte() throws {
        let json = try LosslessJSON(string: appSettingsBlueprintJSON)
        let steps = try #require(json["steps"])
        #expect(appSettingsBlueprintJSON.contains(steps.serializedString()))
    }
}
