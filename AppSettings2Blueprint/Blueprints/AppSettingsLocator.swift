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

// MARK: - Placement

/// Where a rule set's declarations go in a blueprint.
nonisolated enum AppSettingsTarget: Hashable, Sendable {
    /// Replace the App Settings declarations of this com.jamf.ddm-strict component, in place.
    case existingComponent(stepIndex: Int, componentIndex: Int)
    /// Append a new com.jamf.ddm-strict component to this step.
    case newComponent(stepIndex: Int)
    /// Append a new step holding the component.
    case newStep(name: String, activationPredicate: String?)
}

/// The complete new `steps` array for one write, and what changed in it.
nonisolated struct AppSettingsEdit: Sendable {
    /// The complete steps array to PATCH. Everything outside the target component
    /// is the untouched JSON tree of the blueprint as read.
    let steps: JSONValue
    let target: AppSettingsTarget
    /// Path from the blueprint root to the component that was written.
    let componentPath: [JSONPathComponent]
    /// The component before the write (nil when it is new).
    let oldComponent: JSONValue?
    /// The component as written.
    let newComponent: JSONValue
    /// Components the write did not touch.
    let unchangedComponentCount: Int
    /// App Settings declarations elsewhere in the blueprint, left as they are.
    let otherAppSettings: [AppSettingsLocation]
}

nonisolated extension AppSettingsLocator {
    static let maxComponentsPerStep = 100
    static let maxDeclarationsPerComponent = 100
    static let maxSteps = 100

    struct PlacementError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The first editable App Settings component, else a new component in the first
    /// step, else a new step.
    static func defaultTarget(in blueprint: JSONValue, newStepName: String = "App Settings") -> AppSettingsTarget {
        if let location = locate(in: blueprint).first(where: \.isStrictComponent) {
            return .existingComponent(stepIndex: location.stepIndex, componentIndex: location.componentIndex)
        }
        if let steps = blueprint["steps"]?.arrayValue, !steps.isEmpty {
            return .newComponent(stepIndex: 0)
        }
        return .newStep(name: newStepName, activationPredicate: nil)
    }

    /// A new com.jamf.ddm-strict component holding `declarations`.
    static func component(declarations: [JSONValue]) -> JSONValue {
        .object(JSONObject([
            "identifier": .string(componentIdentifier),
            "configuration": .object(JSONObject(["declarations": .array(declarations)])),
        ]))
    }

    /// A step in the server's member order: name, components, activationPredicate.
    static func step(name: String, components: [JSONValue], activationPredicate: String?) -> JSONValue {
        .object(JSONObject([
            "name": .string(name),
            "components": .array(components),
            "activationPredicate": activationPredicate.map(JSONValue.string) ?? .null,
        ]))
    }

    /// Builds the new steps array. `declarations` are the rule set's declarations
    /// (SYSTEM and/or USER). Only the target component changes.
    static func edit(blueprint: JSONValue, declarations: [JSONValue], target: AppSettingsTarget) throws -> AppSettingsEdit {
        guard !declarations.isEmpty else { throw PlacementError(message: "The rule set produced no declarations.") }
        var steps = blueprint["steps"]?.arrayValue ?? []
        if blueprint["steps"] != nil, blueprint["steps"]?.arrayValue == nil {
            throw PlacementError(message: "The blueprint's steps are not an array; refusing to write.")
        }
        let totalComponents = steps.reduce(0) { $0 + ($1["components"]?.arrayValue?.count ?? 0) }
        let allAppSettings = locate(in: blueprint)

        switch target {
        case let .existingComponent(stepIndex, componentIndex):
            guard steps.indices.contains(stepIndex),
                  var components = steps[stepIndex]["components"]?.arrayValue,
                  components.indices.contains(componentIndex) else {
                throw PlacementError(message: "Step \(stepIndex + 1), component \(componentIndex + 1) no longer exists.")
            }
            let oldComponent = components[componentIndex]
            guard oldComponent["identifier"]?.stringValue == componentIdentifier,
                  let oldDeclarations = oldComponent["configuration"]?["declarations"]?.arrayValue else {
                throw PlacementError(message: "Step \(stepIndex + 1), component \(componentIndex + 1) is not a \(componentIdentifier) component.")
            }
            let merged = replacingAppSettings(in: oldDeclarations, with: declarations)
            guard merged.count <= maxDeclarationsPerComponent else {
                throw PlacementError(message: "The component would hold \(merged.count) declarations; the limit is \(maxDeclarationsPerComponent).")
            }
            var newComponent = oldComponent
            newComponent.setValue(.array(merged), at: [.key("configuration"), .key("declarations")])
            components[componentIndex] = newComponent
            var step = steps[stepIndex]
            step.setValue(.array(components), at: [.key("components")])
            steps[stepIndex] = step
            return AppSettingsEdit(
                steps: .array(steps), target: target,
                componentPath: [.key("steps"), .index(stepIndex), .key("components"), .index(componentIndex)],
                oldComponent: oldComponent, newComponent: newComponent,
                unchangedComponentCount: totalComponents - 1,
                otherAppSettings: allAppSettings.filter { $0.stepIndex != stepIndex || $0.componentIndex != componentIndex }
            )

        case let .newComponent(stepIndex):
            guard steps.indices.contains(stepIndex), var components = steps[stepIndex]["components"]?.arrayValue else {
                throw PlacementError(message: "Step \(stepIndex + 1) does not exist.")
            }
            guard components.count < maxComponentsPerStep else {
                throw PlacementError(message: "Step \(stepIndex + 1) already has \(components.count) components, the most a step can hold. Choose another step or a new step.")
            }
            let newComponent = component(declarations: declarations)
            components.append(newComponent)
            var step = steps[stepIndex]
            step.setValue(.array(components), at: [.key("components")])
            steps[stepIndex] = step
            return AppSettingsEdit(
                steps: .array(steps), target: target,
                componentPath: [.key("steps"), .index(stepIndex), .key("components"), .index(components.count - 1)],
                oldComponent: nil, newComponent: newComponent,
                unchangedComponentCount: totalComponents, otherAppSettings: allAppSettings
            )

        case let .newStep(name, activationPredicate):
            guard steps.count < maxSteps else {
                throw PlacementError(message: "The blueprint already has \(steps.count) steps, the most it can hold.")
            }
            if let activationPredicate, activationPredicate.count > 10_000 {
                throw PlacementError(message: "The activation predicate is longer than 10,000 characters.")
            }
            let newComponent = component(declarations: declarations)
            steps.append(step(name: name, components: [newComponent], activationPredicate: activationPredicate))
            return AppSettingsEdit(
                steps: .array(steps), target: target,
                componentPath: [.key("steps"), .index(steps.count - 1), .key("components"), .index(0)],
                oldComponent: nil, newComponent: newComponent,
                unchangedComponentCount: totalComponents, otherAppSettings: allAppSettings
            )
        }
    }

    /// Replaces App Settings declarations channel by channel, in place. A channel
    /// the rule set no longer produces is removed; a new one is inserted after the
    /// last App Settings declaration. Other declaration types are untouched.
    static func replacingAppSettings(in old: [JSONValue], with new: [JSONValue]) -> [JSONValue] {
        func channel(_ declaration: JSONValue) -> String {
            declaration["channelType"]?.stringValue ?? DeclarationEncoder.systemChannel
        }
        var unused = new
        var result: [JSONValue] = []
        var insertAt: Int?
        for declaration in old {
            guard declaration["type"]?.stringValue == declarationType else {
                result.append(declaration)
                continue
            }
            if let match = unused.firstIndex(where: { channel($0) == channel(declaration) }) {
                let replacement = unused.remove(at: match)
                // Unchanged content keeps its exact bytes; changed content keeps the
                // old key order, so only what changed differs.
                result.append(replacement.isSemanticallyEqual(to: declaration) ? declaration : replacement.aligned(to: declaration))
            }
            insertAt = result.count
        }
        result.insert(contentsOf: unused, at: insertAt ?? result.count)
        return result
    }
}
