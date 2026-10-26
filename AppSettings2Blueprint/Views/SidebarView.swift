import JTKit
import SwiftUI

/// Top-level destinations: Lookup | Rule Set | Jamf.
enum SidebarItem: String, Hashable {
    case appStore
    case builtInApps
    case localApps
    case ruleSet
    case blueprints
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Lookup") {
                Label("App Store", systemImage: "bag")
                    .tag(SidebarItem.appStore)
                Label("Apple Built-in Apps", systemImage: "apple.logo")
                    .tag(SidebarItem.builtInApps)
                Label("Local Mac Apps", systemImage: "macwindow")
                    .tag(SidebarItem.localApps)
            }
            Section("Rule Set") {
                RuleSetSidebarRow()
                    .tag(SidebarItem.ruleSet)
            }
            Section("Jamf") {
                Label("Blueprints", systemImage: "square.stack.3d.up")
                    .tag(SidebarItem.blueprints)
            }
        }
    }
}

/// A static "Editor" destination. The open document's name appears beneath it,
/// with an edited dot and an error count, so the row reads as navigation and the
/// name as document state.
private struct RuleSetSidebarRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let document = model.ruleSet
        let errors = document.issues.filter { $0.severity == .error }.count
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Editor")
                    Spacer()
                    if errors > 0 {
                        Text("\(errors)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .background(.red.opacity(0.2), in: Capsule())
                            .foregroundStyle(.red)
                            .help("\(errors) error\(errors == 1 ? "" : "s")")
                    }
                }
                HStack(spacing: 4) {
                    Text(document.ruleSet.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if document.isDirty {
                        Circle().fill(.secondary).frame(width: 6, height: 6)
                            .help("Unsaved changes")
                    }
                }
            }
        } icon: {
            Image(systemName: "checklist")
        }
    }
}

/// Deployment state of a blueprint as a small colored capsule.
struct DeploymentStateBadge: View {
    let state: JamfPlatform.BlueprintState

    var body: some View {
        Text(state.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .deployed: .green
        case .outOfDate: .orange
        case .notDeployed: .secondary
        case .other: .blue
        }
    }
}
