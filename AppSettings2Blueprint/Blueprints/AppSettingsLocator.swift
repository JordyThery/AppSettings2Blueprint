import Foundation

/// Where one `com.apple.configuration.app.settings` declaration sits inside a
/// blueprint's `steps`.
nonisolated struct AppSettingsLocation: Hashable, Sendable, Identifiable {
    let stepIndex: Int
    let componentIndex: Int
    let declarationIndex: Int
    /// The component's `identifier`. Only `com.jamf.ddm-strict` is edited by this app;
    /// matches in other components are reported but read-only.
    let componentIdentifier: String
    let channelType: String?
    let kind: String?
    let stepName: String?

    var id: [JSONPathComponent] { path }

    var isStrictComponent: Bool { componentIdentifier == AppSettingsLocator.componentIdentifier }

    var componentPath: [JSONPathComponent] {
        [.key("steps"), .index(stepIndex), .key("components"), .index(componentIndex)]
    }

    /// Path from the blueprint root to the declaration object.
    var path: [JSONPathComponent] {
        componentPath + [.key("configuration"), .key("declarations"), .index(declarationIndex)]
    }
}

/// Finds App Settings declarations inside a blueprint.
nonisolated enum AppSettingsLocator {
    static let componentIdentifier = "com.jamf.ddm-strict"
    static let declarationType = "com.apple.configuration.app.settings"

    /// Every App Settings declaration in `steps[].components[].configuration.declarations[]`,
    /// in document order, whatever the component identifier.
    static func locate(in blueprint: JSONValue) -> [AppSettingsLocation] {
        guard let steps = blueprint["steps"]?.arrayValue else { return [] }
        var results: [AppSettingsLocation] = []
        for (stepIndex, step) in steps.enumerated() {
            guard let components = step["components"]?.arrayValue else { continue }
            for (componentIndex, component) in components.enumerated() {
                guard let declarations = component["configuration"]?["declarations"]?.arrayValue else { continue }
                for (declarationIndex, declaration) in declarations.enumerated()
                where declaration["type"]?.stringValue == declarationType {
                    results.append(AppSettingsLocation(
                        stepIndex: stepIndex,
                        componentIndex: componentIndex,
                        declarationIndex: declarationIndex,
                        componentIdentifier: component["identifier"]?.stringValue ?? "",
                        channelType: declaration["channelType"]?.stringValue,
                        kind: declaration["kind"]?.stringValue,
                        stepName: step["name"]?.stringValue
                    ))
                }
            }
        }
        return results
    }
}
