import SwiftUI

struct ModuleSwitcher: View {
    @Binding var selection: SemperModule
    let activeModules: Set<SemperModule>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var segmentNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SemperModule.allCases) { module in
                segmentButton(module)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 2)
                .fill(DesignTokens.Colors.nextControlBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 2)
                        .strokeBorder(DesignTokens.Colors.nextControlBorder, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Module")
    }

    @ViewBuilder
    private func segmentButton(_ module: SemperModule) -> some View {
        let isSelected = selection == module
        Button {
            guard selection != module else { return }
            withAnimation(reduceMotion ? nil : DesignTokens.Animation.quick) {
                selection = module
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: module.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(module.displayName)
                    .font(.system(size: 10.5, weight: .semibold))
                if activeModules.contains(module) {
                    Circle()
                        .fill(DesignTokens.Colors.systemGreen)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(
                isSelected
                    ? DesignTokens.Colors.textPrimary
                    : DesignTokens.Colors.textTertiary
            )
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                        .fill(DesignTokens.Colors.glassFillStrong)
                        .matchedGeometryEffect(id: "moduleSegment", in: segmentNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(module.displayName)")
        .accessibilityLabel("\(module.displayName) module")
        .accessibilityValue(activityAccessibilityValue(for: module))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func activityAccessibilityValue(for module: SemperModule) -> String {
        switch module {
        case .awake, .away:
            activeModules.contains(module) ? "On" : "Off"
        case .home, .sound, .displays:
            ""
        }
    }
}

#Preview("Module Switcher") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.lg) {
            ModuleSwitcher(selection: .constant(.sound), activeModules: [])
            ModuleSwitcher(selection: .constant(.awake), activeModules: [.awake])
        }
        .frame(width: 200)
    }
}
