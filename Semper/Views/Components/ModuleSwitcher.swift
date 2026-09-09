import SwiftUI

struct ModuleSwitcher: View {
    @Binding var selection: SemperModule
    let isAwakeActive: Bool

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
                if module == .awake && isAwakeActive {
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
        .accessibilityValue(module == .awake ? (isAwakeActive ? "On" : "Off") : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("Module Switcher") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.lg) {
            ModuleSwitcher(selection: .constant(.sound), isAwakeActive: false)
            ModuleSwitcher(selection: .constant(.awake), isAwakeActive: true)
        }
        .frame(width: 200)
    }
}
