import SwiftUI

/// Top-level destinations: Lookup | Rule Set | Jamf.
enum SidebarItem: Hashable {
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
                Label("App Settings", systemImage: "checklist")
                    .tag(SidebarItem.ruleSet)
            }
            Section("Jamf") {
                Label("Blueprints", systemImage: "square.stack.3d.up")
                    .tag(SidebarItem.blueprints)
            }
        }
    }
}

/// Deployment state of a blueprint as a small colored capsule.
struct DeploymentStateBadge: View {
    let state: DeploymentStateKind

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
